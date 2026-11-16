<#
.SYNOPSIS
Chapter 0 setup. Creates the storage for the Terraform state, then creates or updates the lab
resource group, the monthly budget and the lab VM with Terraform.

.DESCRIPTION
Run it on your own computer, from the course folder:
  .\chapters\00-lab-setup\lab\setup.ps1 [-Yes]
Safe to run again: it updates what exists and creates what is missing.
The bash version, setup.sh, does the same on macOS and Linux.

.PARAMETER Yes
Do not ask for confirmation.
#>
[CmdletBinding()]
param([switch]$Yes)

. (Join-Path $PSScriptRoot '../../../scripts/lib.ps1')
$SetupWatch = [System.Diagnostics.Stopwatch]::StartNew()

$Chapter = '00'

# step: preflight
Read-CourseSetting
Assert-Command 'az' 'Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli'
Assert-Command 'ssh' 'Install the OpenSSH client.'
Assert-Command 'scp' 'Install the OpenSSH client.'
Assert-Command 'tar' 'Windows 10 and 11 include tar. On other systems, install it.'
Assert-Terraform
Assert-AzSignedIn
Assert-ExpectedSubscription

if (-not $Config.LEARNER_IP) { Exit-WithError 'Set LEARNER_IP in .env to your public IPv4 address.' }
if ($Config.LEARNER_IP -notmatch '^([0-9]{1,3}\.){3}[0-9]{1,3}$') { Exit-WithError 'LEARNER_IP must be a plain IPv4 address, without /32.' }

$keyFile = Get-SshKeyFile
if (-not (Test-Path -LiteralPath $keyFile) -or -not (Test-Path -LiteralPath "$keyFile.pub")) {
    Exit-WithError "No SSH key pair at $($Config.SSH_KEY_PATH). Create it with: ssh-keygen -t ed25519 -f `"$keyFile`" -C aro-k8s-lab"
}
$sshPublicKey = (Get-Content -LiteralPath "$keyFile.pub" -Raw).Trim()
if (-not ($sshPublicKey.StartsWith('ssh-ed25519') -or $sshPublicKey.StartsWith('ssh-rsa'))) {
    Exit-WithError "$($Config.SSH_KEY_PATH).pub is not an Ed25519 or RSA public key."
}

# step: subscription
Write-Step 'Subscription'
$account = Get-AzJson @('account', 'show')
$subId = Get-Prop $account 'id'
$subscription = Get-AzJson @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/${subId}?api-version=2022-12-01")
$spendingLimit = Get-Prop $subscription 'subscriptionPolicies.spendingLimit'
if (-not $spendingLimit) { $spendingLimit = 'unknown' }
Write-Info "Subscription: $(Get-Prop $account 'name') ($(Get-Prop $account 'state')), spending limit: $spendingLimit"
if ((Get-Prop $account 'state') -ne 'Enabled') {
    Exit-WithError "The subscription is $(Get-Prop $account 'state'). Wait for the next billing period or pick another subscription."
}
if ($spendingLimit -eq 'Off') {
    Write-Info 'Warning: the spending limit is off, so nothing stops charges at the credit amount. The budget alerts still work.'
}

# step: region
Write-Step 'Checking the region, the VM size and the image'
$skus = @(Get-AzJson @('vm', 'list-skus', '--location', $Config.REGION, '--size', $Config.VM_SIZE, '--resource-type', 'virtualMachines'))
$sku = $skus | Where-Object { $null -ne $_ -and $_.name -eq $Config.VM_SIZE } | Select-Object -First 1
if (-not $sku) { Exit-WithError "$($Config.VM_SIZE) is not offered in $($Config.REGION). Pick another REGION or VM_SIZE in .env." }
$restrictions = @(Get-Prop $sku 'restrictions') | Where-Object { $null -ne $_ }
if (@($restrictions).Count -gt 0) {
    Exit-WithError "$($Config.VM_SIZE) is restricted for this subscription in $($Config.REGION) ($((@($restrictions) | ForEach-Object { $_.reasonCode }) -join ', ')). Pick another REGION or VM_SIZE in .env."
}
if ((Invoke-Native -FilePath 'az' -Arguments @('vm', 'image', 'show', '--urn', $Config.VM_IMAGE, '--location', $Config.REGION, '--output', 'none')).ExitCode -ne 0) {
    Exit-WithError "The image $($Config.VM_IMAGE) is not available in $($Config.REGION). List the options with: az vm image list --publisher Canonical --offer ubuntu-26_04-lts --location $($Config.REGION) --all --output table"
}
$imageParts = $Config.VM_IMAGE.Split(':')
if ($imageParts.Count -ne 4) { Exit-WithError 'VM_IMAGE must have the form publisher:offer:sku:version.' }
Write-Info "OK: $($Config.VM_SIZE) and $($Config.VM_IMAGE) are available in $($Config.REGION)."

# step: cost
Write-Step "Estimated cost (Azure Retail Prices API, $($Config.CURRENCY), pay-as-you-go)"
$vmHour = Get-PriceVmHour
$diskMonth = Get-PriceDiskMonth
$ipHour = Get-PricePublicIpHour
Write-Info "Lab VM $($Config.VM_SIZE): $vmHour per hour, only while it runs."
Write-Info "OS disk $($Config.OS_DISK_GB) GiB Standard SSD: $diskMonth per month, even while the VM is stopped."
Write-Info "Public IPv4 address: $ipHour per hour, even while the VM is stopped."
Write-Info "Terraform state storage: $(Get-PriceBlobGbMonth) per GB per month. The state takes a few kilobytes."
if ($vmHour -ne 'n/a' -and $diskMonth -ne 'n/a' -and $ipHour -ne 'n/a') {
    $vm = [double]::Parse($vmHour, $Invariant)
    $disk = [double]::Parse($diskMonth, $Invariant)
    $ip = [double]::Parse($ipHour, $Invariant)
    Write-Info "About $(Format-Number ($vm * 60 + $disk + $ip * 730)) $($Config.CURRENCY) per month if the VM runs 2 hours a day (60 hours)."
    Write-Info "About $(Format-Number ($disk / 30.4 + $ip * 24)) $($Config.CURRENCY) per day while the VM is stopped (disk and IP address)."
}
Write-Info "Budget: $($Config.BUDGET_AMOUNT) $($Config.CURRENCY) per month for the whole subscription, with alerts."

# step: confirm
if (-not (Confirm-Action "Create or update the lab environment in $($Config.REGION)?" $Yes)) {
    Write-Info 'Nothing changed.'
    exit 0
}

# step: providers
Write-Step 'Registering the resource providers used by the course'
$namespaces = @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.DevTestLab',
    'Microsoft.ContainerRegistry', 'Microsoft.Consumption', 'Microsoft.ContainerService', 'Microsoft.RedHatOpenShift',
    'Microsoft.ManagedIdentity', 'Microsoft.OperationalInsights')
foreach ($namespace in $namespaces) {
    $state = Get-AzValue @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState')
    if ($state -eq 'Registered') {
        Write-Info "${namespace}: already registered"
    }
    else {
        Write-Info "${namespace}: registering (this can take a few minutes)"
        Invoke-AzChange @('provider', 'register', '--namespace', $namespace, '--wait') "Registering $namespace"
    }
}

# step: state
Write-Step 'Storage for the Terraform state'
$stateRg = Get-StateRgName
$stateAccount = Get-StateAccountName $subId
Invoke-AzChange @('group', 'create', '--tags', "$CourseTagKey=$CourseTagValue", "chapter=$Chapter", '--name', $stateRg, '--location', $Config.REGION) 'Creating the state resource group'
if ((Invoke-Native -FilePath 'az' -Arguments @('storage', 'account', 'show', '--resource-group', $stateRg, '--name', $stateAccount, '--output', 'none')).ExitCode -eq 0) {
    Write-Info "Storage account $stateAccount already exists."
}
else {
    Write-Info "Creating storage account $stateAccount in $stateRg. Access needs Microsoft Entra ID, never an account key."
    Invoke-AzChange @('storage', 'account', 'create', '--tags', "$CourseTagKey=$CourseTagValue", "chapter=$Chapter",
        '--resource-group', $stateRg, '--name', $stateAccount, '--location', $Config.REGION,
        '--sku', 'Standard_LRS', '--kind', 'StorageV2', '--min-tls-version', 'TLS1_2', '--https-only', 'true',
        '--allow-blob-public-access', 'false', '--allow-shared-key-access', 'false') 'Creating the state storage account'
}
# Blob versioning keeps the earlier versions of the state, so a damaged state can be restored.
Invoke-AzChange @('storage', 'account', 'blob-service-properties', 'update', '--resource-group', $stateRg, '--account-name', $stateAccount,
    '--enable-versioning', 'true') 'Turning on blob versioning'
$containerExists = Get-AzValue @('storage', 'container-rm', 'exists', '--resource-group', $stateRg, '--storage-account', $stateAccount, '--name', $StateContainer, '--query', 'exists')
if ($containerExists -ne 'true') {
    Invoke-AzChange @('storage', 'container-rm', 'create', '--resource-group', $stateRg, '--storage-account', $stateAccount, '--name', $StateContainer) 'Creating the state container'
}
$accountId = Get-AzValue @('storage', 'account', 'show', '--resource-group', $stateRg, '--name', $stateAccount, '--query', 'id')
$userId = Get-AzValue @('ad', 'signed-in-user', 'show', '--query', 'id')
$roleCount = Get-AzValue @('role', 'assignment', 'list', '--assignee', $userId, '--scope', $accountId, '--role', 'Storage Blob Data Contributor', '--query', 'length(@)')
if ($roleCount -eq '0') {
    Write-Info "Giving your account the Storage Blob Data Contributor role on $stateAccount."
    Invoke-AzChange @('role', 'assignment', 'create', '--assignee-object-id', $userId, '--assignee-principal-type', 'User',
        '--role', 'Storage Blob Data Contributor', '--scope', $accountId) 'Giving your account access to the state'
}
Write-Info 'Waiting until your account can read the state container (a new role can take up to 10 minutes to apply).'
$ready = $false
for ($attempt = 1; $attempt -le 60; $attempt++) {
    $probe = Invoke-Native -FilePath 'az' -Arguments @('storage', 'blob', 'list', '--account-name', $stateAccount, '--container-name', $StateContainer,
        '--auth-mode', 'login', '--num-results', '1', '--output', 'none')
    if ($probe.ExitCode -eq 0) { $ready = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $ready) { Exit-WithError 'Your account still cannot read the state container after 10 minutes. Wait a few minutes and run setup again.' }
Write-Info "OK: the state of chapter 0 goes to $stateAccount/$StateContainer/00-lab-setup.tfstate."

# step: plan
Write-Step 'Planning the lab environment with Terraform'
$contactEmail = $Config.BUDGET_CONTACT_EMAIL
if (-not $contactEmail) { $contactEmail = Get-Prop $account 'user.name' }
if ("$contactEmail" -notmatch '@') { Exit-WithError 'No e-mail address for budget alerts. Set BUDGET_CONTACT_EMAIL in .env.' }
$vmExisted = (Invoke-Native -FilePath 'az' -Arguments @('vm', 'show', '--resource-group', (Get-RgName), '--name', (Get-VmName), '--output', 'none')).ExitCode -eq 0
$infraDir = Join-Path $PSScriptRoot 'infra'
Initialize-TerraformEnvironment '00-lab-setup' $subId
# Values go through TF_VAR_ environment variables, never through JSON on a command line.
Export-LabTerraformVariable $stateAccount $contactEmail $sshPublicKey
$planFile = Join-Path $env:TF_DATA_DIR 'lab.tfplan'
if ((Invoke-Terraform $infraDir (Get-TerraformInitArgument $stateAccount '00-lab-setup.tfstate')) -ne 0) {
    Exit-WithError 'terraform init failed. Read the message above, fix the cause and run setup again.'
}
if ((Invoke-Terraform $infraDir @('plan', "-out=$planFile")) -ne 0) {
    Exit-WithError 'terraform plan failed. Read the message above, fix the cause and run setup again.'
}

# step: apply
if (-not (Confirm-Action 'Apply this plan?' $Yes)) {
    Clear-TerraformEnvironment
    Write-Info 'The lab environment is unchanged. The state storage stays for the next run.'
    exit 0
}
Write-Step 'Applying the plan (about 3 minutes)'
$applyCode = Invoke-Terraform $infraDir @('apply', $planFile)
Remove-Item -LiteralPath $planFile -Force -ErrorAction SilentlyContinue
Clear-TerraformEnvironment
if ($applyCode -ne 0) { Exit-WithError 'terraform apply failed. Read the message above, fix the cause and run setup again.' }
Write-Info 'Terraform finished.'

# step: start-vm
$powerState = Get-PowerState
if ($powerState -ne 'PowerState/running') {
    Write-Info "The lab VM is $($powerState -replace 'PowerState/', ''). Starting it."
    Invoke-AzChange @('vm', 'start', '--resource-group', (Get-RgName), '--name', (Get-VmName)) 'Starting the lab VM'
}

$vmIp = Get-VmPublicIp
if (-not $vmExisted) {
    # A new VM can reuse an old IP address with a new host key: forget the old key.
    $knownHosts = Join-Path (Join-Path $HOME '.ssh') 'aro-k8s_known_hosts'
    if (Test-Path -LiteralPath $knownHosts) { Invoke-Native -FilePath 'ssh-keygen' -Arguments @('-R', $vmIp, '-f', $knownHosts) | Out-Null }
}

# step: wait-ssh
Write-Step "Waiting for SSH on $vmIp"
$ready = $false
for ($attempt = 1; $attempt -le 30; $attempt++) {
    if (Test-TcpPort $vmIp 22) { $ready = $true; break }
    Start-Sleep -Seconds 10
}
if (-not $ready) {
    Exit-WithError 'SSH did not answer after 5 minutes. Check that LEARNER_IP in .env is still your public IP, then run setup again.'
}

# step: wait-cloud-init
Write-Step 'Waiting for cloud-init to install the tools (5 to 10 minutes on the first run)'
if ((Invoke-LabSsh 'cloud-init status --wait > /dev/null 2>&1; test -f /etc/aro-k8s/tools-ready') -ne 0) {
    Exit-WithError 'The tool installation did not finish. Connect with .\scripts\lab-vm.ps1 connect, then read the log: sudo tail -n 50 /var/log/aro-k8s-install.log'
}
Invoke-LabSsh 'cat /etc/aro-k8s/tools-ready' | Out-Null

# step: sync
Write-Step 'Copying the course files to the lab VM'
Sync-CourseToVm

# step: done
Write-Step 'Done'
Write-Info ('Setup took {0} min.' -f [int][math]::Round($SetupWatch.Elapsed.TotalMinutes))
Write-Info "Lab VM: $(Get-VmName) in $(Get-RgName), reachable from $($Config.LEARNER_IP) only."
Write-Info "It shuts down every day at $($Config.AUTO_SHUTDOWN_TIME) ($($Config.AUTO_SHUTDOWN_TIMEZONE)). Stop it yourself when you finish:"
Write-Info '  .\chapters\00-lab-setup\lab\teardown.ps1 stop'
Write-Info 'Next: run the readiness report.'
Write-Info '  .\chapters\00-lab-setup\lab\validate.ps1'
