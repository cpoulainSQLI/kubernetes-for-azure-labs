<#
.SYNOPSIS
Chapter 0 readiness report. Read-only: it changes nothing in Azure or on the lab VM.

.DESCRIPTION
Run it on your own computer, from the course folder:
  .\chapters\00-lab-setup\lab\validate.ps1
Prints PASS, FAIL or WARN for each check. Exit code 0 when no check fails, 1 otherwise.
The bash version, validate.sh, runs the same checks on macOS and Linux.
#>
[CmdletBinding()]
param()

. (Join-Path $PSScriptRoot '../../../scripts/lib.ps1')

$Chapter = '00'

Read-CourseSetting
Assert-Command 'az' 'Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli'
Assert-Command 'ssh' 'Install the OpenSSH client.'

Write-Info ("Chapter {0} readiness report, {1} UTC" -f $Chapter, (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm', $Invariant))

# ---------------------------------------------------------------------------
Write-Step 'Azure CLI and subscription'
# check: cli-signed-in
if (-not (Test-AzSignedIn)) {
    Add-Fail 'The Azure CLI is not signed in.' 'Run: az login'
    Complete-CheckRun
}
Add-Pass 'The Azure CLI is signed in.'

$account = Get-AzJson @('account', 'show')
$subId = Get-Prop $account 'id'
$subName = Get-Prop $account 'name'
$subState = Get-Prop $account 'state'
# check: subscription-match
if ($Config.AZURE_SUBSCRIPTION -and $Config.AZURE_SUBSCRIPTION -ne $subName -and $Config.AZURE_SUBSCRIPTION -ne $subId) {
    Add-Fail "The CLI points at '$subName', not at AZURE_SUBSCRIPTION from .env." 'Run: az account set --subscription "<value of AZURE_SUBSCRIPTION>"'
}
else {
    Add-Pass "Subscription in use: $subName."
}
# check: subscription-state
if ($subState -eq 'Enabled') {
    Add-Pass 'The subscription is Enabled.'
}
else {
    Add-Fail "The subscription is $subState." 'A spent credit disables the subscription until the next billing period.'
}

# check: spending-limit
$subscription = Get-AzJson @('rest', '--method', 'get', '--url', "https://management.azure.com/subscriptions/${subId}?api-version=2022-12-01")
$spendingLimit = Get-Prop $subscription 'subscriptionPolicies.spendingLimit'
$quotaId = Get-Prop $subscription 'subscriptionPolicies.quotaId'
if (-not $quotaId) { $quotaId = 'unknown' }
switch ($spendingLimit) {
    'On' { Add-Pass "The spending limit is on (offer: $quotaId)." }
    'Off' { Add-Warn "The spending limit is off (offer: $quotaId)." 'Charges continue past the credit amount. Rely on the budget alerts and stop resources quickly.' }
    default { Add-Warn "Could not read the spending limit (offer: $quotaId)." 'Check it in the portal under Subscriptions, Overview.' }
}

# ---------------------------------------------------------------------------
Write-Step "Region $($Config.REGION)"
# check: region-vm-size
$skus = @(Get-AzJson @('vm', 'list-skus', '--location', $Config.REGION, '--size', $Config.VM_SIZE, '--resource-type', 'virtualMachines'))
$sku = $skus | Where-Object { $null -ne $_ -and $_.name -eq $Config.VM_SIZE } | Select-Object -First 1
$restrictions = @(Get-Prop $sku 'restrictions') | Where-Object { $null -ne $_ }
if (-not $sku) {
    Add-Fail "$($Config.VM_SIZE) is not offered in $($Config.REGION)." 'Pick another REGION or VM_SIZE in .env.'
}
elseif (@($restrictions).Count -gt 0) {
    Add-Fail "$($Config.VM_SIZE) is restricted for this subscription in $($Config.REGION) ($((@($restrictions) | ForEach-Object { $_.reasonCode }) -join ', '))." 'Pick another REGION or VM_SIZE in .env.'
}
else {
    Add-Pass "$($Config.VM_SIZE) is available in $($Config.REGION)."
}

# check: region-aks-aro
$regionDisplay = Get-AzValue @('account', 'list-locations', '--query', "[?name=='$($Config.REGION)'].displayName | [0]")
$offers = @(
    @{ Namespace = 'Microsoft.ContainerService'; Type = 'managedClusters'; Label = 'AKS (chapter 6)' },
    @{ Namespace = 'Microsoft.RedHatOpenShift'; Type = 'OpenShiftClusters'; Label = 'ARO (chapters 8 and 9)' }
)
foreach ($offer in $offers) {
    $provider = Get-AzJson @('provider', 'show', '--namespace', $offer.Namespace)
    $type = @(Get-Prop $provider 'resourceTypes') | Where-Object { $null -ne $_ -and $_.resourceType -eq $offer.Type } | Select-Object -First 1
    $locations = @(Get-Prop $type 'locations')
    if ($regionDisplay -and ($locations | Where-Object { $_ -eq $regionDisplay })) {
        Add-Pass "$($offer.Label) is offered in $regionDisplay."
    }
    else {
        Add-Warn "$($offer.Label) does not list $($Config.REGION) as a location." 'Choose a region that offers it before that chapter.'
    }
}

# ---------------------------------------------------------------------------
Write-Step 'Resource providers'
# check: providers-now
foreach ($namespace in @('Microsoft.Compute', 'Microsoft.Network', 'Microsoft.Storage', 'Microsoft.DevTestLab', 'Microsoft.ContainerRegistry', 'Microsoft.Consumption')) {
    $state = Get-AzValue @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState')
    if (-not $state) { $state = 'Unknown' }
    if ($state -eq 'Registered') { Add-Pass "$namespace is registered (needed now)." }
    else { Add-Fail "$namespace is $state (needed now)." "Run chapter 0 setup again, or: az provider register --namespace $namespace" }
}
# check: providers-later
foreach ($namespace in @('Microsoft.ContainerService', 'Microsoft.RedHatOpenShift', 'Microsoft.Authorization', 'Microsoft.ManagedIdentity', 'Microsoft.OperationalInsights')) {
    $state = Get-AzValue @('provider', 'show', '--namespace', $namespace, '--query', 'registrationState')
    if (-not $state) { $state = 'Unknown' }
    if ($state -eq 'Registered') { Add-Pass "$namespace is registered (needed later)." }
    else { Add-Warn "$namespace is $state (needed later)." "Register it before the chapter that uses it: az provider register --namespace $namespace" }
}

# ---------------------------------------------------------------------------
Write-Step "vCPU quotas in $($Config.REGION)"
$usage = @(Get-AzJson @('vm', 'list-usage', '--location', $Config.REGION)) | Where-Object { $null -ne $_ }
function Get-Quota([string]$Name) {
    $line = $usage | Where-Object { (Get-Prop $_ 'name.value') -eq $Name } | Select-Object -First 1
    if (-not $line) { return $null }
    return [pscustomobject]@{ Used = [int]$line.currentValue; Limit = [int]$line.limit }
}
$regional = Get-Quota 'cores'
$dasv5 = Get-Quota 'standardDASv5Family'
$dsv5 = Get-Quota 'standardDSv5Family'

# check: quota-regional
# check: quota-regional-aro
if (-not $regional) {
    Add-Fail 'Could not read the regional vCPU quota.' "Run: az vm list-usage --location $($Config.REGION) --output table"
}
else {
    if ($regional.Limit -ge 2) { Add-Pass "Total regional vCPUs: $($regional.Used) used of $($regional.Limit) (the lab VM needs 2)." }
    else { Add-Fail "Total regional vCPUs: limit $($regional.Limit), the lab VM needs 2." 'Request an increase under Quotas in the portal.' }
    if ($regional.Limit -lt 46) {
        Add-Warn "Total regional vCPU limit is $($regional.Limit). ARO needs 44 vCPUs at install time, plus 2 for the lab VM." 'Request 46 or more before chapter 8. Credit-based subscriptions may not get it, see the course page on quotas (azure-limits.html).'
    }
    else { Add-Pass "Total regional vCPU limit $($regional.Limit) covers ARO (44) and the lab VM (2)." }
}
# check: quota-dasv5
if (-not $dasv5) { Add-Warn 'Could not read the DASv5 family quota.' "Run: az vm list-usage --location $($Config.REGION) --output table" }
elseif ($dasv5.Limit -ge 2) { Add-Pass "DASv5 family vCPUs: $($dasv5.Used) used of $($dasv5.Limit) (lab VM size)." }
else { Add-Fail "DASv5 family vCPU limit is $($dasv5.Limit), the lab VM needs 2." 'Request an increase for Standard DASv5 Family vCPUs.' }
# check: quota-dsv5
if (-not $dsv5) { Add-Warn 'Could not read the DSv5 family quota.' "Run: az vm list-usage --location $($Config.REGION) --output table" }
elseif ($dsv5.Limit -ge 44) { Add-Pass "DSv5 family vCPUs: $($dsv5.Used) used of $($dsv5.Limit), enough for the default ARO node sizes (44 at install time)." }
else { Add-Warn "DSv5 family vCPU limit is $($dsv5.Limit). The default ARO node sizes need 44 at install time." 'Request an increase for Standard DSv5 Family vCPUs before chapter 8.' }

# ---------------------------------------------------------------------------
Write-Step 'Terraform and its state'
# check: terraform-cli
$tfVersion = ''
if (Test-Command 'terraform') { $tfVersion = Get-TerraformVersion }
if (-not $tfVersion) { Add-Fail 'Terraform is not installed on this computer.' 'Install it: https://developer.hashicorp.com/terraform/install' }
elseif ([version]$tfVersion -ge [version]$TerraformMinVersion) { Add-Pass "Terraform $tfVersion is installed." }
else { Add-Fail "Terraform $tfVersion is installed, the course needs $TerraformMinVersion or later." 'Install a newer version: https://developer.hashicorp.com/terraform/install' }

# check: tfstate-storage
$stateAccount = Get-StateAccountName $subId
$stateInfo = Get-AzJson @('storage', 'account', 'show', '--resource-group', (Get-StateRgName), '--name', $stateAccount)
if (-not $stateInfo) { Add-Fail "No Terraform state storage account $stateAccount in $(Get-StateRgName)." 'Run chapter 0 setup.' }
elseif ((Get-Prop $stateInfo 'tags.course') -eq $CourseTagValue -and (Get-Prop $stateInfo 'tags.chapter') -eq $Chapter -and (Get-Prop $stateInfo 'allowSharedKeyAccess') -eq $false) {
    Add-Pass "State storage account $stateAccount has the course tags and refuses account keys."
}
else { Add-Warn "State storage account $stateAccount is missing the course tags or accepts account keys." 'Run chapter 0 setup again.' }

# check: tfstate-blob
$blobExists = ''
if ($stateInfo) {
    $blobExists = Get-AzValue @('storage', 'blob', 'exists', '--account-name', $stateAccount, '--container-name', $StateContainer,
        '--name', '00-lab-setup.tfstate', '--auth-mode', 'login', '--query', 'exists')
}
if ($blobExists -eq 'true') { Add-Pass "The state of chapter 0 is in $stateAccount/$StateContainer, and your account can read it." }
else { Add-Fail 'The state of chapter 0 is missing, or your account cannot read it.' 'Run chapter 0 setup. A new role can take up to 10 minutes to apply.' }

# ---------------------------------------------------------------------------
Write-Step 'Budget'
# check: budget-exists
# check: budget-amount
# check: budget-alerts
# check: budget-forecast
$budget = Get-AzJson @('rest', '--method', 'get', '--url', (Get-BudgetUrl $subId))
if (-not $budget) {
    Add-Fail "Budget $(Get-BudgetName) not found." 'Run chapter 0 setup.'
}
else {
    $amount = [int][double](Get-Prop $budget 'properties.amount')
    if ($amount -eq [int]$Config.BUDGET_AMOUNT) { Add-Pass "Budget $(Get-BudgetName): $($Config.BUDGET_AMOUNT) $($Config.CURRENCY), $(Get-Prop $budget 'properties.timeGrain')." }
    else { Add-Warn "Budget amount is $amount, .env says $($Config.BUDGET_AMOUNT)." 'Run chapter 0 setup to apply the amount from .env.' }
    $notifications = Get-Prop $budget 'properties.notifications'
    $alerts = @()
    if ($notifications) { $alerts = @($notifications.PSObject.Properties | ForEach-Object { $_.Value }) }
    if ($alerts.Count -ge 1) { Add-Pass "The budget has $($alerts.Count) alerts." }
    else { Add-Fail 'The budget has no alerts.' 'Run chapter 0 setup again.' }
    if (@($alerts | Where-Object { (Get-Prop $_ 'thresholdType') -eq 'Forecasted' }).Count -ge 1) { Add-Pass 'The budget has a forecast alert.' }
    else { Add-Warn 'The budget has no forecast alert.' 'Forecast alerts warn you before the money is spent.' }
}

# ---------------------------------------------------------------------------
Write-Step 'Lab resources and tags'
$rg = Get-RgName
$vm = Get-VmName
# check: rg-tags
$group = Get-AzJson @('group', 'show', '--name', $rg)
if (-not $group) {
    Add-Fail "Resource group $rg not found." 'Run chapter 0 setup.'
    Complete-CheckRun
}
if ((Get-Prop $group 'tags.course') -eq $CourseTagValue -and (Get-Prop $group 'tags.chapter') -eq $Chapter) {
    Add-Pass "Resource group $rg has the tags $CourseTagKey=$CourseTagValue and chapter=$Chapter."
}
else {
    Add-Fail "Resource group $rg is missing the course tags." 'Run chapter 0 setup again.'
}

# check: vm-tags
# check: vm-size
$vmInfo = Get-AzJson @('vm', 'show', '--resource-group', $rg, '--name', $vm)
if (-not $vmInfo) {
    Add-Fail "Lab VM $vm not found." 'Run chapter 0 setup.'
    Complete-CheckRun
}
if ((Get-Prop $vmInfo 'tags.course') -eq $CourseTagValue -and (Get-Prop $vmInfo 'tags.chapter') -eq $Chapter) { Add-Pass "Lab VM $vm has the course tags." }
else { Add-Fail "Lab VM $vm is missing the course tags." 'Run chapter 0 setup again.' }
$vmSize = Get-Prop $vmInfo 'hardwareProfile.vmSize'
if ($vmSize -eq $Config.VM_SIZE) { Add-Pass "Lab VM size is $vmSize." }
else { Add-Warn "Lab VM size is $vmSize, .env says $($Config.VM_SIZE)." 'Run chapter 0 setup again to align them.' }

# check: untagged
$untagged = @(@(Get-AzJson @('resource', 'list', '--resource-group', $rg)) | Where-Object {
        $null -ne $_ -and (Get-Prop $_ 'tags.course') -ne $CourseTagValue -and $_.type -ne 'Microsoft.Compute/disks'
    } | ForEach-Object { $_.name })
if ($untagged.Count -eq 0) { Add-Pass "Every resource in $rg carries the course tag (the OS disk is checked through the VM)." }
else { Add-Warn "Resources without the course tag in ${rg}: $($untagged -join ' ')" 'Tag them or delete them, so teardown can find them.' }

# check: auto-shutdown
$shutdown = Get-AzJson @('resource', 'show', '--resource-group', $rg, '--resource-type', 'Microsoft.DevTestLab/schedules', '--name', "shutdown-computevm-$vm")
if (-not $shutdown) { Add-Fail "No auto-shutdown schedule on $vm." 'Run chapter 0 setup again.' }
elseif ((Get-Prop $shutdown 'properties.status') -eq 'Enabled') {
    Add-Pass "Auto-shutdown is enabled at $(Get-Prop $shutdown 'properties.dailyRecurrence.time') ($(Get-Prop $shutdown 'properties.timeZoneId'))."
}
else { Add-Fail "Auto-shutdown is $(Get-Prop $shutdown 'properties.status')." 'Run chapter 0 setup again.' }

# check: nsg
$rules = @(@(Get-AzJson @('network', 'nsg', 'rule', 'list', '--resource-group', $rg, '--nsg-name', "$vm-nsg")) | Where-Object {
        $null -ne $_ -and $_.direction -eq 'Inbound' -and $_.access -eq 'Allow'
    })
$sshRules = @($rules | Where-Object { $_.destinationPortRange -eq '22' })
if ($rules.Count -eq 1 -and $sshRules.Count -eq 1 -and $sshRules[0].sourceAddressPrefix -eq "$($Config.LEARNER_IP)/32") {
    Add-Pass 'The NSG allows SSH (port 22) from LEARNER_IP only.'
}
elseif ($sshRules.Count -ge 1) {
    Add-Fail 'The NSG inbound rules do not match LEARNER_IP from .env, or allow more than SSH.' 'If your IP changed, update LEARNER_IP in .env and run chapter 0 setup again.'
}
else { Add-Fail 'No NSG rule allows SSH to the lab VM.' 'Run chapter 0 setup again.' }

# check: identity-roles
$principalId = Get-Prop $vmInfo 'identity.principalId'
if ($principalId) {
    $roles = @(@(Get-AzJson @('role', 'assignment', 'list', '--assignee', $principalId, '--scope', (Get-Prop $group 'id'))) | Where-Object { $null -ne $_ } | ForEach-Object { $_.roleDefinitionName })
    $stateRoles = @()
    if ($stateInfo) {
        $stateRoles = @(@(Get-AzJson @('role', 'assignment', 'list', '--assignee', $principalId, '--scope', (Get-Prop $stateInfo 'id'))) | Where-Object { $null -ne $_ } | ForEach-Object { $_.roleDefinitionName })
    }
    if ($roles -contains 'Contributor' -and $roles -contains 'AcrPush' -and $stateRoles -contains 'Storage Blob Data Contributor') {
        Add-Pass "The VM managed identity has Contributor and AcrPush on $rg, and Storage Blob Data Contributor on the state storage."
    }
    else { Add-Fail "The VM managed identity lacks Contributor or AcrPush on $rg, or Storage Blob Data Contributor on the state storage." 'Run chapter 0 setup again. Role assignments can take up to 10 minutes to appear.' }
}
else {
    Add-Fail 'The lab VM has no managed identity.' 'Run chapter 0 setup again.'
}

# ---------------------------------------------------------------------------
Write-Step 'Tools on the lab VM'
# check: vm-running
$powerState = Get-PowerState
if ($powerState -ne 'PowerState/running') {
    Add-Warn "The lab VM is $($powerState -replace 'PowerState/', ''), so the tool checks were skipped." 'Start it with: .\scripts\lab-vm.ps1 start, then run this report again.'
    Complete-CheckRun
}
Add-Pass 'The lab VM is running.'

# check: vm-ssh
$remoteScript = @'
set -u
printf 'marker=%s\n' "$(test -f /etc/aro-k8s/tools-ready && echo yes || echo no)"
printf 'cloudinit=%s\n' "$(cloud-init status 2>/dev/null | awk '{print $2}')"
printf 'docker=%s\n' "$(docker version --format '{{.Server.Version}}' 2>/dev/null || echo missing)"
printf 'kind=%s\n' "$(kind version 2>/dev/null | awk '{print $2}' || echo missing)"
printf 'kubectl=%s\n' "$(kubectl version --client -o json 2>/dev/null | jq -r '.clientVersion.gitVersion' 2>/dev/null || echo missing)"
printf 'az=%s\n' "$(az version --query '"azure-cli"' --output tsv 2>/dev/null || echo missing)"
printf 'git=%s\n' "$(git --version 2>/dev/null | awk '{print $3}' || echo missing)"
printf 'jq=%s\n' "$(jq --version 2>/dev/null || echo missing)"
printf 'terraform=%s\n' "$(terraform version 2>/dev/null | sed -n '1s/^Terraform v//p' || echo missing)"
printf 'watches=%s\n' "$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
printf 'course=%s\n' "$(test -f ~/aro-k8s-course/.env && echo yes || echo no)"
exit 0
'@
$report = Get-LabSshOutput -RemoteCommand 'bash -s' -InputText $remoteScript
if (-not $report) {
    Add-Fail 'Could not connect to the lab VM over SSH.' 'Check LEARNER_IP in .env against your current public IP, then run chapter 0 setup again.'
    Complete-CheckRun
}
$values = @{}
foreach ($line in $report -split "`n") {
    if ($line -match '^([a-z]+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
}
function Get-VmValue([string]$Key) { if ($values.ContainsKey($Key)) { return $values[$Key] } return '' }

# check: tools-cloud-init
if ((Get-VmValue 'marker') -eq 'yes') { Add-Pass "cloud-init finished installing the tools ($(Get-VmValue 'cloudinit'))." }
else { Add-Fail "cloud-init has not finished installing the tools (status: $(Get-VmValue 'cloudinit'))." 'On the VM: sudo tail -n 50 /var/log/aro-k8s-install.log' }
# check: tools-docker
$dockerVersion = Get-VmValue 'docker'
if ($dockerVersion -and $dockerVersion -ne 'missing') { Add-Pass "Docker Engine $dockerVersion answers without sudo." }
else { Add-Fail "Docker does not answer for $($Config.ADMIN_USERNAME) without sudo." 'Reconnect to the VM (group membership applies to new sessions) or read the install log.' }
# check: tools-kind
$kindVersion = Get-VmValue 'kind'
if ($kindVersion -eq $PinnedKindVersion) { Add-Pass "kind $kindVersion is installed." }
elseif (-not $kindVersion -or $kindVersion -eq 'missing') { Add-Fail 'kind is missing.' 'Read the install log on the VM.' }
else { Add-Warn "kind $kindVersion is installed, the course expects $PinnedKindVersion." 'Chapter 2 may behave differently.' }
# check: tools-kubectl
$kubectlVersion = Get-VmValue 'kubectl'
if ($kubectlVersion.StartsWith("$PinnedKubectlMinor.")) { Add-Pass "kubectl $kubectlVersion is installed." }
elseif (-not $kubectlVersion -or $kubectlVersion -eq 'missing') { Add-Fail 'kubectl is missing.' 'Read the install log on the VM.' }
else { Add-Warn "kubectl $kubectlVersion is installed, the course expects $PinnedKubectlMinor.x." 'kubectl works with clusters one minor version older or newer.' }
# check: tools-terraform
$terraformVmVersion = Get-VmValue 'terraform'
if ($terraformVmVersion -eq $PinnedTerraformVersion) { Add-Pass "Terraform $terraformVmVersion is installed." }
elseif (-not $terraformVmVersion -or $terraformVmVersion -eq 'missing') { Add-Fail 'Terraform is missing on the lab VM.' 'Read the install log on the VM.' }
else { Add-Warn "Terraform $terraformVmVersion is installed, the course expects $PinnedTerraformVersion." 'Later chapters may behave differently.' }
# check: tools-other
foreach ($tool in @('az', 'git', 'jq')) {
    $toolVersion = Get-VmValue $tool
    if ($toolVersion -and $toolVersion -ne 'missing') { Add-Pass "$tool $toolVersion is installed." }
    else { Add-Fail "$tool is missing on the lab VM." 'Read the install log on the VM.' }
}
# check: inotify
$watches = 0
[void][int]::TryParse((Get-VmValue 'watches'), [ref]$watches)
if ($watches -ge 524288) { Add-Pass 'inotify limits are raised for kind.' }
else { Add-Warn 'inotify limits are at the Ubuntu default.' 'On the VM: sudo sysctl --system' }
# check: course-files
if ((Get-VmValue 'course') -eq 'yes') { Add-Pass "The course files and .env are on the lab VM in ~/$VmCourseDir." }
else { Add-Fail 'The course files are not on the lab VM.' 'Run: .\scripts\lab-vm.ps1 sync' }

Complete-CheckRun
