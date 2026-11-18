# Shared helpers for course.ps1 and setup/check.ps1 (Windows PowerShell 5.1 and PowerShell 7).
# Dot-source this file from a script. Do not run it on its own.
# lib.sh, the bash course command and setup/check.sh do the same work on Linux and inside the WSL distribution:
# keep them in line (tools/check-kit.py compares their check and step IDs).

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Every name derives from the name of the kit, as in lib.sh: the WSL distribution, the clone in it, the cluster.
$KitName = 'kubernetes-labs'
$CourseName = 'Containers and Kubernetes'
$DistroName = $KitName
$LinuxUser = 'learner'
$RegistryName = "$KitName-registry"
$RegistryPort = '5001'
$CourseRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path

# Tool versions that setup/install-tools.sh installs. Keep them in line with lib/lib.sh.
$PinnedKindVersion = 'v0.33.0'
$PinnedKubectlMinor = 'v1.37'

$script:PassCount = 0
$script:FailCount = 0
$script:WarnCount = 0
$script:Config = @{}

try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch { Write-Verbose 'Console encoding unchanged.' }

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
        Write-Host 'Result: FAIL. Fix the failed checks and run the report again.'
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
    # wsl.exe writes some of its own messages in UTF-16, which PowerShell reads with a NUL after each letter.
    $text = (@($output) | ForEach-Object { "$_" }) -join "`n"
    return [pscustomobject]@{ ExitCode = $code; Output = ($text -replace "`r", '' -replace "`0", '').Trim() }
}

function Test-Command([string]$Name) {
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Assert-Command([string]$Name, [string]$Hint) {
    if (-not (Test-Command $Name)) { Exit-WithError "The command '$Name' is missing. $Hint" }
}

# ---------------------------------------------------------------------------
# Settings from .env
# ---------------------------------------------------------------------------

# Reads optional KEY=VALUE lines from .env without executing anything. The course runs without .env.
function Read-CourseSetting {
    $values = @{}
    $envFile = Join-Path $CourseRoot '.env'
    if (Test-Path -LiteralPath $envFile) {
        foreach ($line in Get-Content -LiteralPath $envFile) {
            if ($line -match '^([A-Z][A-Z0-9_]*)=(.*)$') {
                $value = $Matches[2].Trim()
                if ($value -match '^"(.*)"$' -or $value -match "^'(.*)'$") { $value = $Matches[1] }
                $values[$Matches[1]] = $value
            }
        }
    }
    $defaults = [ordered]@{ KIT_REPO = ''; WSL_SOURCE = 'Ubuntu-26.04' }
    foreach ($key in $defaults.Keys) {
        if (-not $values.ContainsKey($key) -or [string]::IsNullOrEmpty($values[$key])) { $values[$key] = $defaults[$key] }
    }
    if ($values.WSL_SOURCE -notmatch '^[A-Za-z0-9._-]+$') { Exit-WithError 'WSL_SOURCE must be the name of a distribution, as wsl --list --online shows it, for example Ubuntu-26.04.' }
    $script:Config = $values
}

# The HTTPS URL that the WSL distribution clones the kit from: KIT_REPO from .env, or else the origin of this
# clone (git remote get-url origin) converted to HTTPS. An empty string when no usable URL is found.
# git@host:owner/repo.git and ssh://git@host/owner/repo.git become https://host/owner/repo.git, and a user
# name or token in an HTTPS URL is dropped, so that no credential reaches the distribution.
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

# ---------------------------------------------------------------------------
# WSL
# ---------------------------------------------------------------------------

# Runs wsl.exe and returns its exit code and output. WSL_UTF8 asks it to write UTF-8 rather than UTF-16.
function Invoke-Wsl([string[]]$Arguments) {
    $env:WSL_UTF8 = '1'
    return Invoke-Native -FilePath 'wsl.exe' -Arguments $Arguments
}

# State of the course's distribution: Running, Stopped, Installing, or an empty string when it does not exist.
function Get-DistroState {
    $list = Invoke-Wsl @('--list', '--verbose')
    if ($list.ExitCode -ne 0) { return '' }
    foreach ($line in $list.Output -split "`n") {
        $fields = @(($line -replace '^\s*\*', '').Trim() -split '\s+')
        if ($fields.Count -ge 3 -and $fields[0] -eq $DistroName) { return $fields[1] }
    }
    return ''
}

# WSL version of the course's distribution (1 or 2), or an empty string.
function Get-DistroWslVersion {
    $list = Invoke-Wsl @('--list', '--verbose')
    foreach ($line in $list.Output -split "`n") {
        $fields = @(($line -replace '^\s*\*', '').Trim() -split '\s+')
        if ($fields.Count -ge 3 -and $fields[0] -eq $DistroName) { return $fields[2] }
    }
    return ''
}

# Runs a bash command in the course's distribution, as the user of the course or as root, and returns its exit
# code and output. Without -Capture the output goes to the screen and only the exit code comes back.
# --exec runs bash directly, with no shell of the distribution in between, so $ and ~ reach bash as they are.
# The command must not contain double quotes: Windows PowerShell 5.1 drops them. Use Invoke-InDistroScript.
function Invoke-InDistro {
    param([string]$Command, [switch]$Root, [switch]$Capture)
    $arguments = @('-d', $DistroName)
    if ($Root) { $arguments += @('-u', 'root') }
    $arguments += @('--cd', '~', '--exec', 'bash', '-lc', $Command)
    if ($Capture) { return Invoke-Wsl $arguments }
    $env:WSL_UTF8 = '1'
    & wsl.exe @arguments | Out-Host
    return $LASTEXITCODE
}

# Runs a bash script in the course's distribution and returns its exit code and output. The script travels
# base64-encoded, so that no quote or line ending changes on the way: Windows PowerShell 5.1 drops the double
# quotes inside the arguments of a native program.
function Invoke-InDistroScript([string]$Script) {
    $encoded = [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes(($Script -replace "`r", '')))
    return Invoke-InDistro -Capture -Command "echo $encoded | base64 -d | bash"
}

function Get-UserDataPath {
    return Join-Path (Join-Path $HOME '.cloud-init') "$DistroName.user-data"
}

# A file of the kit as base64, with Unix line endings, for the user data of cloud-init.
function ConvertTo-Base64Script([string]$Path) {
    $text = (Get-Content -LiteralPath $Path -Raw) -replace "`r", ''
    return [Convert]::ToBase64String((New-Object System.Text.UTF8Encoding($false)).GetBytes($text))
}

# The branch or tag that this clone is on, when the remote at $KitUrl has it, so that the distribution clones the
# same version of the kit. An empty string means the default branch of the remote.
function Get-KitRef([string]$KitUrl) {
    $ref = (Invoke-Native -FilePath 'git' -Arguments @('-C', $CourseRoot, 'symbolic-ref', '--short', '-q', 'HEAD')).Output
    $kind = 'heads'
    if (-not $ref) {
        $ref = (Invoke-Native -FilePath 'git' -Arguments @('-C', $CourseRoot, 'describe', '--tags', '--exact-match')).Output
        $kind = 'tags'
    }
    if (-not $ref -or $ref -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$' -or $ref.Contains('..')) { return '' }
    $found = Invoke-Native -FilePath 'git' -Arguments @('ls-remote', '--exit-code', $KitUrl, "refs/$kind/$ref")
    if ($found.ExitCode -ne 0) { return '' }
    return $ref
}

# Writes the user data that cloud-init reads at the first start of the distribution, from setup/cloud-init.yaml.
function Write-UserData([string]$KitUrl, [string]$KitRef) {
    $setup = Join-Path $CourseRoot 'setup'
    $text = (Get-Content -LiteralPath (Join-Path $setup 'cloud-init.yaml') -Raw) -replace "`r", ''
    $text = $text.Replace('__INSTALL_TOOLS_B64__', (ConvertTo-Base64Script (Join-Path $setup 'install-tools.sh')))
    $text = $text.Replace('__WSL_ENVIRONMENT_B64__', (ConvertTo-Base64Script (Join-Path $setup 'wsl-environment.sh')))
    $text = $text.Replace('__USER__', $LinuxUser).Replace('__KIT_NAME__', $KitName).Replace('__KIT_REPO__', $KitUrl).Replace('__KIT_REF__', $KitRef)
    $path = Get-UserDataPath
    New-Item -ItemType Directory -Force -Path (Split-Path $path) | Out-Null
    [System.IO.File]::WriteAllText($path, $text, (New-Object System.Text.UTF8Encoding($false)))
    return $path
}
