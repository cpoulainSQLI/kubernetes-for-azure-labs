# Shared helpers for course.ps1 and setup/check.ps1 (Windows PowerShell 5.1 and PowerShell 7).
# Dot-source this file from a script. Do not run it on its own.
# lib.sh, the bash course command and setup/check.sh do the same work on macOS and Linux:
# keep them in line (tools/check-kit.py compares their check and step IDs).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$CourseTagKey = 'course'
$CourseTagValue = 'aro-k8s'
$CourseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$VmCourseDir = 'aro-k8s-course'
$KnownHostsOption = 'UserKnownHostsFile=~/.ssh/aro-k8s_known_hosts'

# Tool versions installed by cloud-init on the lab VM. Keep them in line with lib/lib.sh.
$PinnedKindVersion = 'v0.33.0'
$PinnedKubectlMinor = 'v1.37'
# Terraform. The lab VM gets $PinnedTerraformVersion from cloud-init. On your own computer, any
# version from $TerraformMinVersion up works. Keep both in line with lib/lib.sh.
$TerraformMinVersion = '1.17.0'
$PinnedTerraformVersion = '1.17.2'
# Blob container that holds the Terraform state of the setup and of every lab, one blob each.
$StateContainer = 'tfstate'
# Name of the setup in the state container and in TF_DATA_DIR, and the chapter tag of its resources.
$SetupFolder = 'setup'
$SetupChapter = '00'

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0
$script:Config = @{}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose 'Console encoding unchanged.' }
if ($PSVersionTable.PSVersion.Major -lt 6) {
    # Windows PowerShell 5.1 may default to old TLS versions for web requests.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

$Invariant = [System.Globalization.CultureInfo]::InvariantCulture

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

function Write-Info([string]$Message) {
    Write-Host $Message
}

function Write-Step([string]$Message) {
    Write-Host ''
    Write-Host "==> $Message" -ForegroundColor Cyan
}

function Exit-WithError([string]$Message) {
    Write-Host 'ERROR ' -ForegroundColor Red -NoNewline
    Write-Host $Message
    exit 1
}

function Add-Pass([string]$Message) {
    $script:PassCount++
    Write-Host '[PASS]' -ForegroundColor Green -NoNewline
    Write-Host " $Message"
}

function Add-Fail([string]$Message, [string]$Hint = '') {
    $script:FailCount++
    Write-Host '[FAIL]' -ForegroundColor Red -NoNewline
    Write-Host " $Message"
    if ($Hint) { Write-Host "       hint: $Hint" }
}

function Add-Warn([string]$Message, [string]$Hint = '') {
    $script:WarnCount++
    Write-Host '[WARN]' -ForegroundColor Yellow -NoNewline
    Write-Host " $Message"
    if ($Hint) { Write-Host "       hint: $Hint" }
}

# Prints the totals and ends the script: exit code 0 when nothing failed, 1 otherwise.
function Complete-CheckRun {
    Write-Host ''
    Write-Host ("Summary: {0} PASS, {1} FAIL, {2} WARN" -f $script:PassCount, $script:FailCount, $script:WarnCount)
    if ($script:FailCount -gt 0) {
        Write-Host 'Result: FAIL. Fix the failed checks and run the validation again.'
        exit 1
    }
    Write-Host 'Result: PASS.'
    exit 0
}

function Confirm-Action([string]$Question, [bool]$AssumeYes) {
    if ($AssumeYes) { return $true }
    $answer = Read-Host "$Question [y/N]"
    return ($answer -match '^[Yy]$')
}

function Format-Number([double]$Value) {
    return $Value.ToString('0.00', $Invariant)
}

# Reads a nested property of an object built from JSON, or $null when any part is missing.
function Get-Prop($Object, [string]$Path) {
    $current = $Object
    foreach ($part in $Path.Split('.')) {
        if ($null -eq $current) { return $null }
        $property = $current.PSObject.Properties[$part]
        if ($null -eq $property) { return $null }
        $current = $property.Value
    }
    return $current
}

# ---------------------------------------------------------------------------
# Native commands
# ---------------------------------------------------------------------------

# Runs a native program, hides its error stream and returns its exit code and output.
function Invoke-Native {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $output = & $FilePath @Arguments 2>$null
        $code = $LASTEXITCODE
    }
    catch {
        $output = @()
        $code = 127
    }
    finally {
        $ErrorActionPreference = $previous
    }
    $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ ExitCode = $code; Output = ($text -replace "`r", '').Trim() }
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-Command([string]$Name, [string]$Hint) {
    if (-not (Test-Command $Name)) { Exit-WithError "The command '$Name' is missing. $Hint" }
}

# az with JSON output, converted to objects. Returns $null when the command fails.
function Get-AzJson([string[]]$Arguments) {
    $result = Invoke-Native -FilePath 'az' -Arguments ($Arguments + @('--output', 'json', '--only-show-errors'))
    if ($result.ExitCode -ne 0 -or -not $result.Output) { return $null }
    return ($result.Output | ConvertFrom-Json)
}

# az with tsv output. Returns an empty string when the command fails.
function Get-AzValue([string[]]$Arguments) {
    $result = Invoke-Native -FilePath 'az' -Arguments ($Arguments + @('--output', 'tsv', '--only-show-errors'))
    if ($result.ExitCode -ne 0) { return '' }
    return $result.Output
}

# az for commands that change something. Stops the script when the command fails.
function Invoke-AzChange([string[]]$Arguments, [string]$What) {
    & az @($Arguments + @('--only-show-errors', '--output', 'none'))
    if ($LASTEXITCODE -ne 0) { Exit-WithError "$What failed. Read the message above, fix the cause and run the script again." }
}

function Test-AzSignedIn {
    return ((Invoke-Native -FilePath 'az' -Arguments @('account', 'show', '--output', 'none')).ExitCode -eq 0)
}

function Assert-AzSignedIn {
    if (-not (Test-AzSignedIn)) { Exit-WithError 'The Azure CLI is not signed in. Run: az login' }
}

function Assert-ExpectedSubscription {
    $expected = $script:Config.AZURE_SUBSCRIPTION
    if (-not $expected) { return }
    $account = Get-AzJson @('account', 'show')
    if ($expected -ne (Get-Prop $account 'name') -and $expected -ne (Get-Prop $account 'id')) {
        Exit-WithError "The Azure CLI points at '$(Get-Prop $account 'name')', not at AZURE_SUBSCRIPTION. Run: az account set --subscription `"<value of AZURE_SUBSCRIPTION>`""
    }
}

# ---------------------------------------------------------------------------
# Settings from .env
# ---------------------------------------------------------------------------

# Reads KEY=VALUE lines from .env without executing anything.
function Read-CourseSetting {
    $envFile = Join-Path $CourseRoot '.env'
    if (-not (Test-Path -LiteralPath $envFile)) {
        Exit-WithError "No .env file at $envFile. Copy .env.example to .env and fill it in."
    }
    $values = @{}
    foreach ($line in Get-Content -LiteralPath $envFile) {
        if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
            $value = $Matches[2].Trim()
            if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
            $values[$Matches[1]] = $value
        }
    }
    $defaults = [ordered]@{
        PREFIX = 'arok8s'; REGION = 'swedencentral'; CURRENCY = 'EUR'; BUDGET_AMOUNT = '30'
        BUDGET_CONTACT_EMAIL = ''; AZURE_SUBSCRIPTION = ''; LEARNER_IP = ''; SSH_KEY_PATH = '~/.ssh/aro-k8s-lab'
        ADMIN_USERNAME = 'azureuser'; VM_SIZE = 'Standard_D2as_v5'; VM_IMAGE = 'Canonical:ubuntu-26_04-lts:server:latest'
        OS_DISK_GB = '64'; AUTO_SHUTDOWN_TIME = '1900'; AUTO_SHUTDOWN_TIMEZONE = 'UTC'; KIT_REPO = ''
    }
    foreach ($key in $defaults.Keys) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrEmpty($values[$key])) { $values[$key] = $defaults[$key] }
    }
    if ($values.PREFIX -cnotmatch '^[a-z][a-z0-9]{2,11}$') { Exit-WithError 'PREFIX must be 3 to 12 lowercase letters or digits and start with a letter.' }
    if ($values.BUDGET_AMOUNT -notmatch '^[0-9]+$') { Exit-WithError 'BUDGET_AMOUNT must be a whole number, for example 30.' }
    if (@('32', '64', '128') -notcontains $values.OS_DISK_GB) { Exit-WithError 'OS_DISK_GB must be 32, 64 or 128.' }
    if ($values.AUTO_SHUTDOWN_TIME -notmatch '^[0-2][0-9][0-5][0-9]$') { Exit-WithError 'AUTO_SHUTDOWN_TIME must use the hhmm format, for example 1900.' }
    $script:Config = $values
}

# ---------------------------------------------------------------------------
# Names
# ---------------------------------------------------------------------------

function Get-RgName { return "$($script:Config.PREFIX)-lab-rg" }
function Get-VmName { return "$($script:Config.PREFIX)-lab-vm" }
function Get-BudgetName { return "$($script:Config.PREFIX)-monthly-budget" }
function Get-StateRgName { return "$($script:Config.PREFIX)-tfstate-rg" }

# Name of the storage account that holds the Terraform state, from the subscription ID.
# Account names are unique across Azure, so the name ends with 8 characters of a SHA-256 hash of
# the subscription ID. state_account_name in lib.sh must give the same name.
function Get-StateAccountName([string]$SubscriptionId) {
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($SubscriptionId.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    $hash = -join ($bytes[0..3] | ForEach-Object { $_.ToString('x2') })
    return "$($script:Config.PREFIX)tf$hash"
}

function Get-OsDiskTier {
    switch ($script:Config.OS_DISK_GB) {
        '32' { return 'E4' }
        '128' { return 'E10' }
        default { return 'E6' }
    }
}

function Get-BudgetUrl([string]$SubscriptionId) {
    return "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Consumption/budgets/$(Get-BudgetName)?api-version=2023-05-01"
}

function Get-PowerState {
    $view = Get-AzJson @('vm', 'get-instance-view', '--resource-group', (Get-RgName), '--name', (Get-VmName))
    if (-not $view) { return '' }
    $state = @(Get-Prop $view 'instanceView.statuses') | Where-Object { $null -ne $_ -and $_.code -like 'PowerState/*' } | Select-Object -First 1
    if ($state) { return $state.code }
    return ''
}

# ---------------------------------------------------------------------------
# Prices from the Azure Retail Prices API (no sign-in needed)
# ---------------------------------------------------------------------------

# Returns the first pay-as-you-go Linux price for a filter, or 'n/a' when the lookup fails.
function Get-RetailPrice([string]$Filter) {
    try {
        $uri = "https://prices.azure.com/api/retail/prices?currencyCode='$($script:Config.CURRENCY)'&`$filter=" + [uri]::EscapeDataString($Filter)
        $response = Invoke-RestMethod -Uri $uri -TimeoutSec 20 -UseBasicParsing
        $items = @($response.Items | Where-Object {
                $_.type -eq 'Consumption' -and $_.productName -notmatch 'Windows' -and $_.skuName -notmatch 'Spot|Low Priority'
            })
        if ($items.Count -gt 0) { return ([double]$items[0].retailPrice).ToString($Invariant) }
    }
    catch {
        Write-Verbose "Price lookup failed: $($_.Exception.Message)"
    }
    return 'n/a'
}

function Get-PriceVmHour {
    return Get-RetailPrice "serviceName eq 'Virtual Machines' and armRegionName eq '$($script:Config.REGION)' and armSkuName eq '$($script:Config.VM_SIZE)'"
}

function Get-PriceDiskMonth {
    return Get-RetailPrice "armRegionName eq '$($script:Config.REGION)' and productName eq 'Standard SSD Managed Disks' and meterName eq '$(Get-OsDiskTier) LRS Disk'"
}

function Get-PricePublicIpHour {
    return Get-RetailPrice "armRegionName eq '$($script:Config.REGION)' and productName eq 'IP Addresses' and meterName eq 'Standard IPv4 Static Public IP'"
}

function Get-PriceBlobGbMonth {
    return Get-RetailPrice "armRegionName eq '$($script:Config.REGION)' and productName eq 'General Block Blob v2' and meterName eq 'Hot LRS Data Stored'"
}

# ---------------------------------------------------------------------------
# Terraform
# ---------------------------------------------------------------------------

# Version of the installed terraform, for example 1.17.2, or an empty string.
function Get-TerraformVersion {
    $result = Invoke-Native -FilePath 'terraform' -Arguments @('version')
    if ($result.ExitCode -ne 0 -or $result.Output -notmatch '^Terraform v([0-9]+\.[0-9]+\.[0-9]+)') { return '' }
    return $Matches[1]
}

function Assert-Terraform {
    Assert-Command 'terraform' "Install Terraform $TerraformMinVersion or later: https://developer.hashicorp.com/terraform/install"
    $version = Get-TerraformVersion
    if (-not $version -or [version]$version -lt [version]$TerraformMinVersion) {
        Exit-WithError "Terraform $version is installed. The course needs $TerraformMinVersion or later."
    }
}

# Prepares a Terraform run for the setup or for one lab. Terraform keeps its working files (the provider,
# the plan) in ~/.aro-k8s/terraform/<folder>, outside the kit folder, so they never end up in a commit.
function Initialize-TerraformEnvironment([string]$Folder, [string]$SubscriptionId) {
    $dir = Join-Path (Join-Path (Join-Path $HOME '.aro-k8s') 'terraform') $Folder
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $env:TF_DATA_DIR = $dir
    $env:ARM_SUBSCRIPTION_ID = $SubscriptionId
    $env:TF_IN_AUTOMATION = '1'
    $env:TF_INPUT = '0'
}

# Passes the settings of .env to the configuration in setup/infra as TF_VAR_ environment variables.
# course up and course destroy both need them.
function Export-SetupTerraformVariable([string]$StateAccount, [string]$AlertEmail, [string]$SshPublicKey, [string]$KitUrl) {
    $values = [ordered]@{
        prefix = $script:Config.PREFIX; location = $script:Config.REGION; chapter = $SetupChapter
        budget_amount = $script:Config.BUDGET_AMOUNT
        budget_start_date = (Get-Date).ToUniversalTime().ToString('yyyy-MM-01', $Invariant)
        alert_email = $AlertEmail; learner_ip = $script:Config.LEARNER_IP; ssh_public_key = $SshPublicKey
        admin_username = $script:Config.ADMIN_USERNAME; vm_size = $script:Config.VM_SIZE; vm_image = $script:Config.VM_IMAGE
        os_disk_size_gb = $script:Config.OS_DISK_GB; auto_shutdown_time = $script:Config.AUTO_SHUTDOWN_TIME
        auto_shutdown_timezone = $script:Config.AUTO_SHUTDOWN_TIMEZONE
        state_resource_group_name = (Get-StateRgName); state_storage_account_name = $StateAccount
        kit_repo_url = $KitUrl
    }
    foreach ($name in $values.Keys) { Set-Item -LiteralPath "Env:TF_VAR_$name" -Value "$($values[$name])" }
}

# Removes the variables set for Terraform from this PowerShell session.
function Clear-TerraformEnvironment {
    Get-ChildItem Env: | Where-Object { $_.Name -like 'TF_VAR_*' } | ForEach-Object { Remove-Item -LiteralPath "Env:$($_.Name)" }
    foreach ($name in @('TF_DATA_DIR', 'ARM_SUBSCRIPTION_ID', 'TF_IN_AUTOMATION', 'TF_INPUT')) {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction SilentlyContinue
    }
}

# Runs terraform on the configuration in a folder and returns its exit code.
function Invoke-Terraform([string]$Dir, [string[]]$Arguments) {
    & terraform @(@("-chdir=$Dir") + $Arguments) | Out-Host
    return $LASTEXITCODE
}

# Arguments of terraform init that connect a configuration to its state: the blob $Key in the
# state container of storage account $Account, reached with Microsoft Entra ID through the Azure CLI.
function Get-TerraformInitArgument([string]$Account, [string]$Key) {
    return @('init', '-reconfigure',
        "-backend-config=storage_account_name=$Account",
        "-backend-config=container_name=$StateContainer",
        "-backend-config=key=$Key",
        '-backend-config=use_azuread_auth=true',
        '-backend-config=use_cli=true')
}

# ---------------------------------------------------------------------------
# Lab VM access
# ---------------------------------------------------------------------------

function Get-SshKeyFile {
    $path = $script:Config.SSH_KEY_PATH
    if ($path -eq '~') { return $HOME }
    if ($path.StartsWith('~/') -or $path.StartsWith('~\')) { $path = Join-Path $HOME $path.Substring(2) }
    return $path
}

function Get-VmPublicIp {
    return Get-AzValue @('network', 'public-ip', 'show', '--resource-group', (Get-RgName), '--name', "$(Get-VmName)-pip", '--query', 'ipAddress')
}

function Get-SshArgument([string]$Ip) {
    return @('-i', (Get-SshKeyFile), '-o', 'StrictHostKeyChecking=accept-new', '-o', $KnownHostsOption, '-o', 'ConnectTimeout=10', "$($script:Config.ADMIN_USERNAME)@$Ip")
}

# Opens an interactive SSH session on the lab VM.
function Enter-LabSsh {
    $ip = Get-VmPublicIp
    if (-not $ip) { Exit-WithError 'No public IP found for the lab VM. Create it first with: .\course.ps1 up' }
    $sshArgs = Get-SshArgument $ip
    & ssh @sshArgs
}

# Runs a command on the lab VM, shows its output and returns its exit code.
function Invoke-LabSsh([string]$RemoteCommand) {
    $ip = Get-VmPublicIp
    if (-not $ip) { Exit-WithError 'No public IP found for the lab VM. Create it first with: .\course.ps1 up' }
    $sshArgs = (Get-SshArgument $ip) + @($RemoteCommand)
    & ssh @sshArgs | Out-Host
    return $LASTEXITCODE
}

# Like Invoke-LabSsh, but captures the output and hides errors. Used by read-only checks.
function Get-LabSshOutput {
    param([string]$RemoteCommand, [string]$InputText = $null)
    $ip = Get-VmPublicIp
    if (-not $ip) { return '' }
    $sshArgs = (Get-SshArgument $ip) + @($RemoteCommand)
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        if ($null -ne $InputText) { $output = ($InputText -replace "`r", '') | & ssh @sshArgs 2>$null }
        else { $output = & ssh @sshArgs 2>$null }
    }
    finally { $ErrorActionPreference = $previous }
    return ((@($output) | ForEach-Object { "$_" }) -join "`n") -replace "`r", ''
}

function Test-TcpPort([string]$HostName, [int]$Port, [int]$TimeoutMs = 5000) {
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $task = $client.ConnectAsync($HostName, $Port)
        return ($task.Wait($TimeoutMs) -and $client.Connected)
    }
    catch { return $false }
    finally { $client.Dispose() }
}

# Copies a file from your computer to the lab VM, for example: Copy-ToLabVm .env aro-k8s-course/.env
function Copy-ToLabVm([string]$Source, [string]$Destination) {
    Assert-Command 'scp' 'Install the OpenSSH client.'
    $ip = Get-VmPublicIp
    if (-not $ip) { Exit-WithError 'No public IP found for the lab VM. Create it first with: .\course.ps1 up' }
    $scpArgs = @('-q', '-i', (Get-SshKeyFile), '-o', 'StrictHostKeyChecking=accept-new', '-o', $KnownHostsOption, '-o', 'ConnectTimeout=10',
        $Source, "$($script:Config.ADMIN_USERNAME)@${ip}:$Destination")
    & scp @scpArgs
    if ($LASTEXITCODE -ne 0) { Exit-WithError "Could not copy $Source to the lab VM." }
}

# Runs a bash script of the kit on the lab VM with one argument, and returns its exit code. The script travels
# base64-encoded on the SSH command line, so no line ending or quote can change it on the way.
# The argument must not contain a single quote. lab_run_script in lib.sh does the same.
function Invoke-LabScript([string]$Path, [string]$Argument) {
    $text = (Get-Content -LiteralPath $Path -Raw) -replace "`r", ''
    $encoded = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
    return Invoke-LabSsh "printf '%s' '$encoded' | base64 -d | bash -s -- '$Argument'"
}

# ---------------------------------------------------------------------------
# The kit on the lab VM
# ---------------------------------------------------------------------------

# The HTTPS URL that the lab VM clones the kit from: KIT_REPO from .env, or else the origin of this clone
# (git remote get-url origin) converted to HTTPS. An empty string when no usable URL is found.
# git@host:owner/repo.git and ssh://git@host/owner/repo.git become https://host/owner/repo.git, and a user
# name or token in an HTTPS URL is dropped, so that no credential reaches the lab VM. kit_repo_url in lib.sh does the same.
function Get-KitRepoUrl {
    $url = $script:Config.KIT_REPO
    if (-not $url) {
        $result = Invoke-Native -FilePath 'git' -Arguments @('-C', $CourseRoot, 'remote', 'get-url', 'origin')
        if ($result.ExitCode -eq 0) { $url = $result.Output }
    }
    $url = "$url".Trim()
    if ($url -match '^git@([^:]+):(.+)$') {
        $hostName = $Matches[1]
        $path = $Matches[2]
    }
    elseif ($url -match '^ssh://([^/]+)/(.+)$') {
        $hostName = (($Matches[1] -split '@')[-1] -split ':')[0]
        $path = $Matches[2]
    }
    elseif ($url -match '^https://([^/]+)/(.+)$') {
        $hostName = ($Matches[1] -split '@')[-1]
        $path = $Matches[2]
    }
    else { return '' }
    $url = "https://$hostName/$($path.TrimStart('/'))"
    if ($url -cmatch '^https://[A-Za-z0-9.-]+(:[0-9]+)?/[A-Za-z0-9._~/-]+$') { return $url }
    return ''
}

# Makes sure that the kit is cloned in ~/aro-k8s-course on the lab VM and that the course command is on its
# PATH (setup/kit-on-vm.sh), then copies .env, and only .env, next to it. It never pulls: course update does that.
function Install-KitOnVm([string]$KitUrl) {
    $code = Invoke-LabScript (Join-Path (Join-Path $CourseRoot 'setup') 'kit-on-vm.sh') $KitUrl
    if ($code -ne 0) { Exit-WithError "Could not clone the kit on the lab VM from $KitUrl. A fork must be public, or set KIT_REPO in .env." }
    Copy-ToLabVm (Join-Path $CourseRoot '.env') "$VmCourseDir/.env"
    if ((Invoke-LabSsh "chmod 600 ~/$VmCourseDir/.env") -ne 0) { Exit-WithError 'Could not restrict the access rights of .env on the lab VM.' }
    Write-Info "Copied .env to ~/$VmCourseDir on the lab VM."
}

# ---------------------------------------------------------------------------
# Clean-up report
# ---------------------------------------------------------------------------

function Show-CourseResource {
    Write-Step "Azure resources still tagged $CourseTagKey=$CourseTagValue"
    $groups = @(Get-AzJson @('group', 'list', '--tag', "$CourseTagKey=$CourseTagValue"))
    $resources = @(Get-AzJson @('resource', 'list', '--tag', "$CourseTagKey=$CourseTagValue"))
    $groups = @($groups | Where-Object { $null -ne $_ })
    $resources = @($resources | Where-Object { $null -ne $_ })
    if ($groups.Count -eq 0 -and $resources.Count -eq 0) {
        Write-Info 'Nothing found. No course resource is left in this subscription.'
        return
    }
    if ($groups.Count -gt 0) {
        Write-Info 'Resource groups:'
        $groups | ForEach-Object { Write-Info ("  {0} (chapter {1})" -f $_.name, (Get-Prop $_ 'tags.chapter')) }
    }
    if ($resources.Count -gt 0) {
        Write-Info 'Resources:'
        $resources | ForEach-Object { Write-Info ("  {0} [{1}] in {2} (chapter {3})" -f $_.name, $_.type, $_.resourceGroup, (Get-Prop $_ 'tags.chapter')) }
    }
}
