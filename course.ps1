<#
.SYNOPSIS
The course command for PowerShell: builds and manages the course's WSL distribution on Windows.

.DESCRIPTION
Run it from the kit folder:
  .\course.ps1 up [-Yes]        create the WSL distribution of the course with its tools. Safe to run twice.
  .\course.ps1 connect          open a terminal in the distribution (type exit to leave)
  .\course.ps1 status           show the distribution, and inside it the tools, the registry and the cluster
  .\course.ps1 check            readiness report of the environment. Changes nothing.
  .\course.ps1 stop             stop the distribution. Your work and your cluster are kept.
  .\course.ps1 destroy [-Yes]   delete the distribution, with everything in it, ~/work included
  .\course.ps1 update           update the kit here and in the distribution (git pull)
The labs run inside the distribution: connect, then run course help.

.PARAMETER Command
up, connect, status, check, stop, destroy, update or help.

.PARAMETER Yes
Do not ask for confirmation.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('up', 'connect', 'status', 'check', 'stop', 'destroy', 'update', 'help', 'start', 'break', 'solution', 'clean')]
    [string]$Command = 'help',
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)][string[]]$Rest,
    [switch]$Yes
)

. (Join-Path $PSScriptRoot 'lib/lib.ps1')
$Watch = [System.Diagnostics.Stopwatch]::StartNew()

function Show-Usage {
    Write-Info 'Usage on Windows, from the kit folder:'
    Write-Info '  .\course.ps1 up [-Yes]        create the WSL distribution of the course with its tools. Safe to run twice.'
    Write-Info '  .\course.ps1 connect          open a terminal in the distribution (type exit to leave)'
    Write-Info '  .\course.ps1 status           show the distribution, and inside it the tools, the registry and the cluster'
    Write-Info '  .\course.ps1 check            readiness report of the environment. Changes nothing.'
    Write-Info '  .\course.ps1 stop             stop the distribution. Your work and your cluster are kept.'
    Write-Info '  .\course.ps1 destroy [-Yes]   delete the distribution, with everything in it, ~/work included'
    Write-Info '  .\course.ps1 update           update the kit here and in the distribution (git pull)'
    Write-Info 'The labs run inside the distribution: .\course.ps1 connect, then course start 01. Run course help there.'
}

function Assert-Wsl {
    Assert-Command 'wsl.exe' 'Install WSL from an administrator PowerShell with: wsl --install, then restart Windows.'
    if ((Invoke-Wsl @('--status')).ExitCode -ne 0) {
        Exit-WithError 'WSL does not answer. Install it from an administrator PowerShell with: wsl --install, then restart Windows and run .\course.ps1 up again.'
    }
}

function Assert-Distro {
    Assert-Wsl
    if (-not (Get-DistroState)) { Exit-WithError "The WSL distribution $DistroName does not exist. Create it with: .\course.ps1 up" }
}

# ---------------------------------------------------------------------------
# up
# ---------------------------------------------------------------------------

function Invoke-Up([bool]$AssumeYes) {
    # step: preflight
    Assert-Wsl
    Assert-Command 'git' 'Install Git: https://git-scm.com/downloads'
    Read-CourseSetting
    $kitUrl = Get-KitRepoUrl
    if (-not $kitUrl) {
        Exit-WithError 'Could not work out where the distribution clones the kit from. Clone the kit with Git, or set KIT_REPO in .env to its HTTPS URL.'
    }

    # step: tools
    Write-Step "The WSL distribution $DistroName"
    if (Get-DistroState) {
        Write-Info "The distribution $DistroName exists."
    }
    else {
        $userData = Get-UserDataPath
        Write-Info "This creates a WSL distribution named $DistroName from $($Config.WSL_SOURCE), kept for the course. At its first start, cloud-init:"
        Write-Info "  - creates the Linux user $LinuxUser, with sudo and no password,"
        Write-Info "  - installs Docker Engine, kubectl $PinnedKubectlMinor, kind $PinnedKindVersion, git, curl, jq and python3-yaml (setup/install-tools.sh),"
        Write-Info "  - clones the kit from $kitUrl into ~/$KitName and puts the course command on its PATH."
        Write-Info "It writes the instructions for cloud-init to $userData."
        Write-Info 'It takes a few minutes and about 8 GB of disk. Nothing changes on Windows itself, and Docker Desktop is not needed.'
        if (-not (Confirm-Action "Create the distribution ${DistroName}?" $AssumeYes)) {
            Write-Info 'Nothing changed.'
            exit 0
        }
        $written = Write-UserData $kitUrl
        Write-Info "Wrote $written."
        Write-Step "Creating the distribution (about a minute)"
        $env:WSL_UTF8 = '1'
        & wsl.exe --install $Config.WSL_SOURCE --name $DistroName --no-launch | Out-Host
        if ($LASTEXITCODE -ne 0 -or -not (Get-DistroState)) {
            Exit-WithError "wsl --install did not create $DistroName. Read the message above. If WSL itself is missing, run wsl --install in an administrator PowerShell, restart Windows, then run .\course.ps1 up again."
        }
        Write-Step 'Installing the tools with cloud-init (2 to 5 minutes)'
        Invoke-InDistro -Root -Command 'cloud-init status --wait >/dev/null 2>&1 || true' | Out-Null
        # WSL applies the default user of /etc/wsl.conf from the next start, so the distribution restarts once.
        Invoke-Wsl @('--terminate', $DistroName) | Out-Null
    }
    $ready = Invoke-InDistro -Root -Capture -Command "cat /etc/$KitName/tools-ready"
    if ($ready.ExitCode -ne 0) {
        Exit-WithError ("The installation in $DistroName did not finish. Read its log with: wsl -d $DistroName -u root -- tail -n 50 /var/log/$KitName-install.log. " +
            "To start again from scratch: .\course.ps1 destroy, then .\course.ps1 up")
    }
    Write-Info $ready.Output

    # step: docker-access
    $user = Invoke-InDistro -Capture -Command 'id -un'
    if ($user.Output -ne $LinuxUser) {
        Exit-WithError "The distribution logs in as '$($user.Output)', not as $LinuxUser. Stop it with .\course.ps1 stop, then run .\course.ps1 up again."
    }
    if ((Invoke-InDistro -Capture -Command 'docker info').ExitCode -ne 0) {
        Exit-WithError "Docker Engine does not answer in $DistroName. Stop the distribution with .\course.ps1 stop, then run .\course.ps1 up again."
    }

    # step: registry
    Write-Step 'Registry'
    if ((Invoke-InDistro -Command "source ~/$KitName/lib/lib.sh && ensure_registry") -ne 0) {
        Exit-WithError 'The registry could not be created. Read the message above, then run .\course.ps1 up again.'
    }

    # step: launcher
    if ((Invoke-InDistro -Capture -Command "command -v course && test -d ~/$KitName/.git && test -d ~/work").ExitCode -ne 0) {
        Exit-WithError "The kit, the course command or ~/work is missing in $DistroName. Read the log with: wsl -d $DistroName -u root -- tail -n 50 /var/log/$KitName-install.log"
    }
    Write-Info "The kit is cloned in ~/$KitName, the course command is on the PATH, and your work goes in ~/work."

    # step: done
    Write-Step 'Done'
    Write-Info ('This run took {0} s.' -f [int]$Watch.Elapsed.TotalSeconds)
    $versions = Invoke-InDistro -Capture -Command "source ~/$KitName/lib/lib.sh && echo Docker Engine `$(docker_version), kind `$(kind_version), kubectl `$(kubectl_version)"
    Write-Info $versions.Output
    Write-Info 'Closing the last terminal of the distribution stops it after a few seconds. Your work and your cluster are kept,'
    Write-Info 'and course start NN brings a lab back. Next: the readiness report, then a terminal in the distribution.'
    Write-Info '  .\course.ps1 check'
    Write-Info '  .\course.ps1 connect'
    Write-Info '  course start 01      (in the distribution)'
}

# ---------------------------------------------------------------------------
# connect, status, stop
# ---------------------------------------------------------------------------

function Invoke-Connect {
    # step: cmd-connect
    Assert-Distro
    $env:WSL_UTF8 = '1'
    & wsl.exe -d $DistroName --cd '~'
}

function Invoke-Status {
    # step: cmd-status
    Assert-Wsl
    $state = Get-DistroState
    if (-not $state) {
        Write-Info "The WSL distribution $DistroName does not exist. Create it with: .\course.ps1 up"
        return
    }
    Write-Info "WSL distribution $DistroName`: $state"
    if ($state -ne 'Running') {
        Write-Info 'It starts with .\course.ps1 connect. Then course start NN brings your lab back.'
        return
    }
    Invoke-InDistro -Command 'course status' | Out-Null
}

function Invoke-Stop {
    # step: stop
    Assert-Wsl
    $state = Get-DistroState
    if (-not $state) { Write-Info "The WSL distribution $DistroName does not exist. Nothing to stop."; return }
    if ($state -ne 'Running') { Write-Info "The WSL distribution $DistroName is already $state."; return }
    Invoke-Wsl @('--terminate', $DistroName) | Out-Null
    Write-Info "Stopped $DistroName. Your work in ~/work, the registry and your cluster are kept."
    Write-Info 'Next time: .\course.ps1 connect, then course start NN brings your lab back.'
}

# ---------------------------------------------------------------------------
# destroy and update
# ---------------------------------------------------------------------------

function Invoke-Destroy([bool]$AssumeYes) {
    # step: destroy-confirm
    Assert-Wsl
    if (-not (Get-DistroState)) {
        Write-Info "The WSL distribution $DistroName does not exist. Nothing to delete."
        return
    }
    Write-Step "Deleting the WSL distribution $DistroName"
    Write-Info 'This deletes the distribution with everything in it: your work in ~/work goes with it,'
    Write-Info 'and so do the cluster, the registry with the images you pushed, and the clone of the kit.'
    Write-Info 'Copy what you want to keep first, for example to \\wsl.localhost\kubernetes-labs\home\learner\work from Windows.'
    if (-not $AssumeYes) {
        $typed = Read-Host "Type the name '$DistroName' to confirm"
        if ($typed -cne $DistroName) {
            Write-Info 'Nothing deleted.'
            exit 0
        }
    }
    # step: destroy
    $result = Invoke-Wsl @('--unregister', $DistroName)
    if ($result.ExitCode -ne 0) { Exit-WithError "wsl --unregister $DistroName failed: $($result.Output)" }
    Remove-Item -LiteralPath (Get-UserDataPath) -Force -ErrorAction SilentlyContinue
    Write-Info "Deleted $DistroName and its cloud-init file. .\course.ps1 up creates it again."
}

function Invoke-Update {
    # step: update-kit
    Assert-Command 'git' 'Install Git: https://git-scm.com/downloads'
    Write-Step "Updating the kit in $CourseRoot"
    & git -C $CourseRoot pull --ff-only
    if ($LASTEXITCODE -ne 0) { Exit-WithError "git pull failed. If you changed files of the kit, list them with: git -C `"$CourseRoot`" status" }
    if ((Get-DistroState) -eq 'Running') {
        if ((Invoke-InDistro -Command 'course update') -ne 0) { Exit-WithError "The update failed in $DistroName. Read the message above." }
    }
    else {
        Write-Info "The kit in $DistroName updates when it runs: .\course.ps1 connect, then course update."
    }
}

# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

Write-Info "$CourseName, lab kit $KitName"
switch ($Command) {
    'up' { Invoke-Up $Yes.IsPresent }
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
    default { Exit-WithError "course $(@($Command) + @($Rest) -join ' ') runs in the WSL distribution of the course. Open it with .\course.ps1 connect, then run the command there." }
}
