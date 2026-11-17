<#
.SYNOPSIS
The course command for PowerShell: manages the lab environment from your own computer.

.DESCRIPTION
Run it from the kit folder:
  .\course.ps1 up [-Yes] [-Apply]   create the lab environment, or start the lab VM if it exists.
                                    -Apply also applies a change made to .env. Safe to run twice.
  .\course.ps1 connect              open an SSH session on the lab VM (type exit to leave)
  .\course.ps1 status               show the power state, the IP address and the shutdown time
  .\course.ps1 check                readiness report of the lab environment. Changes nothing.
  .\course.ps1 stop                 deallocate the lab VM. Your work on it is kept.
  .\course.ps1 destroy [-Yes]       delete the lab environment and the Terraform state
  .\course.ps1 update               update the kit here (git pull), and on the lab VM if it runs
On the lab VM, the bash course command runs the labs: connect, then run course help.
The bash version, course, does the same on macOS and Linux.

.PARAMETER Command
up, connect, status, check, stop, destroy, update or help.

.PARAMETER Yes
Do not ask for confirmation.

.PARAMETER Apply
With up: run Terraform even when the lab VM exists, to apply a change made to .env.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'connect', 'status', 'check', 'stop', 'destroy', 'update', 'help', 'start', 'break', 'solution', 'clean')]
    [string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest,
    [switch]$Yes,
    [switch]$Apply
)

. (Join-Path $PSScriptRoot 'lib/lib.ps1')
$Watch = [System.Diagnostics.Stopwatch]::StartNew()

function Show-Usage {
    Write-Info 'Usage on your own computer, from the kit folder:'
    Write-Info '  .\course.ps1 up [-Yes] [-Apply]   create the lab environment, or start the lab VM if it exists.'
    Write-Info '                                    -Apply also applies a change made to .env. Safe to run twice.'
    Write-Info '  .\course.ps1 connect              open an SSH session on the lab VM (type exit to leave)'
    Write-Info '  .\course.ps1 status               show the power state, the IP address and the shutdown time'
    Write-Info '  .\course.ps1 check                readiness report of the lab environment. Changes nothing.'
    Write-Info '  .\course.ps1 stop                 deallocate the lab VM. Your work on it is kept.'
    Write-Info '  .\course.ps1 destroy [-Yes]       delete the lab environment and the Terraform state'
    Write-Info '  .\course.ps1 update               update the kit here (git pull), and on the lab VM if it runs'
    Write-Info 'On the lab VM, course start, check, break, solution and clean run the labs: connect, then run course help.'
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Initialize-Laptop {
    Read-CourseSetting
    Assert-Command 'az' 'Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli'
    Assert-AzSignedIn
    Assert-ExpectedSubscription
}

# Brings the clone of the kit up to date with git pull.
function Invoke-KitUpdate {
    Assert-Command 'git' 'Install Git: https://git-scm.com/downloads'
    if ((Invoke-Native -FilePath 'git' -Arguments @('-C', $CourseRoot, 'rev-parse', '--git-dir')).ExitCode -ne 0) {
        Exit-WithError "$CourseRoot is not a Git clone, so it cannot be updated. Clone the kit with Git."
    }
    Write-Step "Updating the kit in $CourseRoot"
    & git -C $CourseRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { Exit-WithError "git pull failed. If you changed files of the kit, list them with: git -C `"$CourseRoot`" status" }
}

# ---------------------------------------------------------------------------
# up
# ---------------------------------------------------------------------------

# Creates or updates the lab environment with Terraform: the state storage first, then the configuration in setup/infra.
function Invoke-UpWithTerraform([string]$SshPublicKey, [string]$KitUrl, [bool]$AssumeYes) {
    Assert-Terraform

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
    if ($Config.VM_IMAGE.Split(':').Count -ne 4) { Exit-WithError 'VM_IMAGE must have the form publisher:offer:sku:version.' }
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
        $vmPrice = [double]::Parse($vmHour, $Invariant)
        $disk = [double]::Parse($diskMonth, $Invariant)
        $ip = [double]::Parse($ipHour, $Invariant)
        Write-Info "About $(Format-Number ($vmPrice * 60 + $disk + $ip * 730)) $($Config.CURRENCY) per month if the VM runs 2 hours a day (60 hours)."
        Write-Info "About $(Format-Number ($disk / 30.4 + $ip * 24)) $($Config.CURRENCY) per day while the VM is stopped (disk and IP address)."
    }
    Write-Info "Budget: $($Config.BUDGET_AMOUNT) $($Config.CURRENCY) per month for the whole subscription, with alerts."

    # step: confirm
    if (-not (Confirm-Action "Create or update the lab environment in $($Config.REGION)?" $AssumeYes)) {
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
    Invoke-AzChange @('group', 'create', '--tags', "$CourseTagKey=$CourseTagValue", "chapter=$SetupChapter", '--name', $stateRg, '--location', $Config.REGION) 'Creating the state resource group'
    if ((Invoke-Native -FilePath 'az' -Arguments @('storage', 'account', 'show', '--resource-group', $stateRg, '--name', $stateAccount, '--output', 'none')).ExitCode -eq 0) {
        Write-Info "Storage account $stateAccount already exists."
    }
    else {
        Write-Info "Creating storage account $stateAccount in $stateRg. Access needs Microsoft Entra ID, never an account key."
        Invoke-AzChange @('storage', 'account', 'create', '--tags', "$CourseTagKey=$CourseTagValue", "chapter=$SetupChapter",
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
    if (-not $accountId -or -not $userId) { Exit-WithError 'Could not read the state storage account or your account in Microsoft Entra ID. Run az login, then .\course.ps1 up again.' }
    # az is a batch file on Windows, and cmd.exe rejects a query such as length(@), so the script lists the IDs and
    # counts them. A failed lookup stops the script here, instead of skipping the grant and waiting 10 minutes for nothing.
    $roleCheck = Invoke-Native -FilePath 'az' -Arguments @('role', 'assignment', 'list', '--assignee', $userId, '--scope', $accountId,
        '--role', 'Storage Blob Data Contributor', '--query', '[].id', '--output', 'tsv', '--only-show-errors')
    if ($roleCheck.ExitCode -ne 0) { Exit-WithError 'Could not read the role assignments of the state storage account. Run az login, then .\course.ps1 up again.' }
    if (-not $roleCheck.Output) {
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
    if (-not $ready) { Exit-WithError 'Your account still cannot read the state container after 10 minutes. Wait a few minutes and run .\course.ps1 up again.' }
    Write-Info "OK: the state of the setup goes to $stateAccount/$StateContainer/$SetupFolder.tfstate."

    # step: plan
    Write-Step 'Planning the lab environment with Terraform'
    $contactEmail = $Config.BUDGET_CONTACT_EMAIL
    if (-not $contactEmail) { $contactEmail = Get-Prop $account 'user.name' }
    if ("$contactEmail" -notmatch '@') { Exit-WithError 'No e-mail address for budget alerts. Set BUDGET_CONTACT_EMAIL in .env.' }
    $infraDir = Join-Path (Join-Path $CourseRoot 'setup') 'infra'
    Initialize-TerraformEnvironment $SetupFolder $subId
    # Values go through TF_VAR_ environment variables, never through JSON on a command line.
    Export-SetupTerraformVariable $stateAccount $contactEmail $SshPublicKey $KitUrl
    $planFile = Join-Path $env:TF_DATA_DIR 'lab.tfplan'
    if ((Invoke-Terraform $infraDir (Get-TerraformInitArgument $stateAccount "$SetupFolder.tfstate")) -ne 0) {
        Exit-WithError 'terraform init failed. Read the message above, fix the cause and run .\course.ps1 up again.'
    }
    if ((Invoke-Terraform $infraDir @('plan', "-out=$planFile")) -ne 0) {
        Exit-WithError 'terraform plan failed. Read the message above, fix the cause and run .\course.ps1 up again.'
    }

    # step: apply
    if (-not (Confirm-Action 'Apply this plan?' $AssumeYes)) {
        Clear-TerraformEnvironment
        Write-Info 'The lab environment is unchanged. The state storage stays for the next run.'
        exit 0
    }
    Write-Step 'Applying the plan (about 3 minutes)'
    $applyCode = Invoke-Terraform $infraDir @('apply', $planFile)
    Remove-Item -LiteralPath $planFile -Force -ErrorAction SilentlyContinue
    Clear-TerraformEnvironment
    if ($applyCode -ne 0) { Exit-WithError 'terraform apply failed. Read the message above, fix the cause and run .\course.ps1 up again.' }
    Write-Info 'Terraform finished.'
}

function Invoke-Up([bool]$AssumeYes, [bool]$ApplyChanges) {
    # step: preflight
    Initialize-Laptop
    Assert-Command 'ssh' 'Install the OpenSSH client.'
    Assert-Command 'scp' 'Install the OpenSSH client.'
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

    # step: kit-url
    $kitUrl = Get-KitRepoUrl
    if (-not $kitUrl) {
        Exit-WithError 'Could not work out where the lab VM clones the kit from. Clone the kit with Git, or set KIT_REPO in .env to its HTTPS URL.'
    }
    Write-Info "The lab VM clones the kit from $kitUrl"

    # step: existing
    $rg = Get-RgName
    $vm = Get-VmName
    $vmExisted = (Invoke-Native -FilePath 'az' -Arguments @('vm', 'show', '--resource-group', $rg, '--name', $vm, '--output', 'none')).ExitCode -eq 0
    $nsgSource = Get-AzValue @('network', 'nsg', 'rule', 'show', '--resource-group', $rg, '--nsg-name', "$vm-nsg", '--name', 'allow-ssh-from-learner', '--query', 'sourceAddressPrefix')
    if ($vmExisted -and $nsgSource -eq "$($Config.LEARNER_IP)/32" -and -not $ApplyChanges) {
        Write-Info 'The lab environment exists. To apply a change made to .env, run: .\course.ps1 up -Apply'
    }
    else {
        if ($vmExisted -and $nsgSource -ne "$($Config.LEARNER_IP)/32") {
            $shown = $nsgSource
            if (-not $shown) { $shown = 'no address' }
            Write-Info "The lab VM accepts SSH from $shown, and LEARNER_IP in .env is $($Config.LEARNER_IP). Terraform updates the rule."
        }
        Invoke-UpWithTerraform -SshPublicKey $sshPublicKey -KitUrl $kitUrl -AssumeYes $AssumeYes
    }

    # step: start-vm
    $powerState = Get-PowerState
    if ($powerState -ne 'PowerState/running') {
        Write-Info "The lab VM is $($powerState -replace 'PowerState/', ''). Starting it (about a minute)."
        Invoke-AzChange @('vm', 'start', '--resource-group', $rg, '--name', $vm) 'Starting the lab VM'
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
        Exit-WithError 'SSH did not answer after 5 minutes. Check that LEARNER_IP in .env is still your public IP, then run: .\course.ps1 up'
    }

    # step: wait-cloud-init
    Write-Step 'Waiting for cloud-init to install the tools (5 to 10 minutes on the first run)'
    if ((Invoke-LabSsh 'cloud-init status --wait > /dev/null 2>&1; test -f /etc/aro-k8s/tools-ready') -ne 0) {
        Exit-WithError 'The tool installation did not finish. Connect with .\course.ps1 connect, then read the log: sudo tail -n 50 /var/log/aro-k8s-install.log'
    }
    Invoke-LabSsh 'cat /etc/aro-k8s/tools-ready' | Out-Null

    # step: kit-on-vm
    Write-Step 'The kit on the lab VM'
    Install-KitOnVm $kitUrl

    # step: done
    Write-Step 'Done'
    Write-Info ('This run took {0} min.' -f [int][math]::Round($Watch.Elapsed.TotalMinutes))
    Write-Info "Lab VM: $vm in $rg, at $vmIp, reachable from $($Config.LEARNER_IP) only."
    Write-Info "It shuts down every day at $($Config.AUTO_SHUTDOWN_TIME) ($($Config.AUTO_SHUTDOWN_TIMEZONE)). Stop it yourself when you finish: .\course.ps1 stop"
    Write-Info 'Next: the readiness report, then a session on the lab VM.'
    Write-Info '  .\course.ps1 check'
    Write-Info '  .\course.ps1 connect'
}

# ---------------------------------------------------------------------------
# connect, status, stop
# ---------------------------------------------------------------------------

function Invoke-Connect {
    # step: cmd-connect
    Initialize-Laptop
    Assert-Command 'ssh' 'Install the OpenSSH client.'
    if ((Get-PowerState) -ne 'PowerState/running') { Exit-WithError 'The lab VM is not running. Start it with: .\course.ps1 up' }
    Enter-LabSsh
}

function Invoke-Status {
    # step: cmd-status
    Initialize-Laptop
    $state = Get-PowerState
    if (-not $state) { $state = 'not found' }
    Write-Info "Lab VM: $(Get-VmName) in $(Get-RgName)"
    Write-Info "Power state: $state"
    Write-Info "Public IP: $(Get-VmPublicIp)"
    Write-Info "Auto-shutdown: $($Config.AUTO_SHUTDOWN_TIME) ($($Config.AUTO_SHUTDOWN_TIMEZONE))"
}

function Invoke-Stop {
    # step: stop
    Initialize-Laptop
    Write-Step 'Stopping (deallocating) the lab VM'
    $powerState = Get-PowerState
    if (-not $powerState) {
        Write-Info 'No lab VM found. Nothing to stop.'
    }
    elseif ($powerState -eq 'PowerState/deallocated') {
        Write-Info 'The lab VM is already deallocated.'
    }
    else {
        Invoke-AzChange @('vm', 'deallocate', '--resource-group', (Get-RgName), '--name', (Get-VmName)) 'Deallocating the lab VM'
        Write-Info 'The lab VM is deallocated. Compute charges have stopped.'
    }
    Write-Info "Still charged while stopped: the OS disk ($(Get-PriceDiskMonth) $($Config.CURRENCY) per month) and the public IP address ($(Get-PricePublicIpHour) $($Config.CURRENCY) per hour)."
    Write-Info 'Start the VM again with: .\course.ps1 up'
    # step: list
    Show-CourseResource
}

# ---------------------------------------------------------------------------
# destroy
# ---------------------------------------------------------------------------

function Invoke-Destroy([bool]$AssumeYes) {
    Initialize-Laptop
    $rg = Get-RgName
    $stateRg = Get-StateRgName

    # step: destroy-confirm
    Write-Step 'Destroying the lab environment'
    Write-Info "This deletes resource group $rg with everything in it, budget $(Get-BudgetName),"
    Write-Info "and resource group $stateRg with the Terraform state of the setup and of every lab."
    Write-Info 'Your work on the lab VM is lost. Copy anything you want to keep first.'
    if (-not $AssumeYes) {
        $typed = Read-Host "Type the prefix '$($Config.PREFIX)' to confirm"
        if ($typed -cne $Config.PREFIX) {
            Write-Info 'Nothing deleted.'
            exit 0
        }
    }

    # step: destroy-terraform
    Write-Step 'Destroying the lab with Terraform'
    $subId = Get-AzValue @('account', 'show', '--query', 'id')
    $stateAccount = Get-StateAccountName $subId
    $infraDir = Join-Path (Join-Path $CourseRoot 'setup') 'infra'
    if (-not (Test-Command 'terraform')) {
        Write-Info 'Terraform is not installed. The steps below delete the lab with the Azure CLI.'
    }
    elseif ((Invoke-Native -FilePath 'az' -Arguments @('storage', 'account', 'show', '--resource-group', $stateRg, '--name', $stateAccount, '--output', 'none')).ExitCode -ne 0) {
        Write-Info 'No Terraform state storage found. The steps below delete the lab with the Azure CLI.'
    }
    else {
        # terraform destroy needs a value for every variable, even those it does not use.
        $contactEmail = $Config.BUDGET_CONTACT_EMAIL
        if (-not $contactEmail) { $contactEmail = Get-AzValue @('account', 'show', '--query', 'user.name') }
        $sshPublicKey = 'not-needed-to-destroy'
        $keyFile = "$(Get-SshKeyFile).pub"
        if (Test-Path -LiteralPath $keyFile) { $sshPublicKey = (Get-Content -LiteralPath $keyFile -Raw).Trim() }
        $kitUrl = Get-KitRepoUrl
        if (-not $kitUrl) { $kitUrl = 'https://example.invalid/not-needed-to-destroy' }
        Initialize-TerraformEnvironment $SetupFolder $subId
        Export-SetupTerraformVariable $stateAccount $contactEmail $sshPublicKey $kitUrl
        $destroyed = ((Invoke-Terraform $infraDir (Get-TerraformInitArgument $stateAccount "$SetupFolder.tfstate")) -eq 0) -and
            ((Invoke-Terraform $infraDir @('destroy', '-auto-approve')) -eq 0)
        Clear-TerraformEnvironment
        if ($destroyed) { Write-Info 'Terraform destroyed the lab environment.' }
        else { Write-Info 'Terraform could not destroy everything. The steps below delete what is left with the Azure CLI.' }
    }

    # step: destroy-rg
    if ((Invoke-Native -FilePath 'az' -Arguments @('group', 'show', '--name', $rg, '--output', 'none')).ExitCode -eq 0) {
        Write-Info "Deleting resource group $rg (5 to 10 minutes)."
        Invoke-AzChange @('group', 'delete', '--name', $rg, '--yes') 'Deleting the resource group'
        Write-Info 'Resource group deleted.'
    }
    else {
        Write-Info "Resource group $rg does not exist."
    }

    # step: destroy-budget
    $budgetUrl = Get-BudgetUrl $subId
    if (Get-AzJson @('rest', '--method', 'get', '--url', $budgetUrl)) {
        Invoke-AzChange @('rest', '--method', 'delete', '--url', $budgetUrl) 'Deleting the budget'
        Write-Info "Budget $(Get-BudgetName) deleted."
    }
    else {
        Write-Info "Budget $(Get-BudgetName) does not exist."
    }

    # step: destroy-state
    if ((Invoke-Native -FilePath 'az' -Arguments @('group', 'show', '--name', $stateRg, '--output', 'none')).ExitCode -eq 0) {
        Write-Info "Deleting resource group $stateRg with the Terraform state (a few minutes)."
        Invoke-AzChange @('group', 'delete', '--name', $stateRg, '--yes') 'Deleting the state resource group'
        Write-Info 'Resource group deleted.'
    }
    else {
        Write-Info "Resource group $stateRg does not exist."
    }
    Remove-Item -LiteralPath (Join-Path (Join-Path (Join-Path $HOME '.aro-k8s') 'terraform') $SetupFolder) -Recurse -Force -ErrorAction SilentlyContinue

    # step: destroy-known-hosts
    Remove-Item -LiteralPath (Join-Path (Join-Path $HOME '.ssh') 'aro-k8s_known_hosts') -Force -ErrorAction SilentlyContinue
    Write-Info 'Azure may have created a resource group named NetworkWatcherRG when the network was created. It costs nothing on its own and you can keep it.'

    # step: list
    Show-CourseResource
}

# ---------------------------------------------------------------------------
# update
# ---------------------------------------------------------------------------

function Invoke-Update {
    # step: update-kit
    Invoke-KitUpdate
    # step: update-vm
    Read-CourseSetting
    if (-not (Test-Command 'az') -or -not (Test-AzSignedIn)) {
        Write-Info 'The Azure CLI is not signed in here, so the kit on the lab VM was not updated. On the lab VM, run: course update'
        return
    }
    Assert-ExpectedSubscription
    if ((Get-PowerState) -ne 'PowerState/running') {
        Write-Info 'The lab VM is not running. Once it runs, update its kit from here with .\course.ps1 update, or on the lab VM with: course update'
        return
    }
    Write-Step 'Updating the kit on the lab VM'
    if ((Invoke-LabSsh "git -C ~/$VmCourseDir pull --ff-only") -ne 0) {
        Exit-WithError "git pull failed on the lab VM. Connect with .\course.ps1 connect and look at: git -C ~/$VmCourseDir status"
    }
    Copy-ToLabVm (Join-Path $CourseRoot '.env') "$VmCourseDir/.env"
    Write-Info "Copied .env to ~/$VmCourseDir on the lab VM. Your work in ~/work was not touched."
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

switch ($Command) {
    'up' { Invoke-Up $Yes.IsPresent $Apply.IsPresent }
    'connect' { Invoke-Connect }
    'status' { Invoke-Status }
    'check' {
        # step: cmd-check
        & (Join-Path (Join-Path $CourseRoot 'setup') 'check.ps1')
        exit $LASTEXITCODE
    }
    'stop' { Invoke-Stop }
    'destroy' { Invoke-Destroy $Yes.IsPresent }
    'update' { Invoke-Update }
    'help' { Show-Usage }
    default { Exit-WithError "course $(@($Command) + @($Rest) -join ' ') runs on the lab VM. Connect first with: .\course.ps1 connect" }
}
