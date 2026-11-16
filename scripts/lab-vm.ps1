<#
.SYNOPSIS
Everyday helper for the lab VM. Run it on your own computer, from the course folder.

.DESCRIPTION
  .\scripts\lab-vm.ps1 start     start the VM and print how to connect
  .\scripts\lab-vm.ps1 connect   open an SSH session on the VM
  .\scripts\lab-vm.ps1 sync      copy the course files and .env to ~/aro-k8s-course on the VM
  .\scripts\lab-vm.ps1 status    show the power state, the IP address and the shutdown time
  .\scripts\lab-vm.ps1 stop      same as: .\chapters\00-lab-setup\lab\teardown.ps1 stop
The bash version, lab-vm.sh, does the same on macOS and Linux.

.PARAMETER Command
start, connect, sync, status or stop.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)][ValidateSet('start', 'connect', 'sync', 'status', 'stop')][string]$Command
)

. (Join-Path $PSScriptRoot 'lib.ps1')

if (-not $Command) {
    Write-Info 'Usage: .\scripts\lab-vm.ps1 start|connect|sync|status|stop'
    Write-Info '  start     start the VM and print how to connect'
    Write-Info '  connect   open an SSH session on the VM'
    Write-Info '  sync      copy the course files and .env to ~/aro-k8s-course on the VM'
    Write-Info '  status    show the power state, the IP address and the shutdown time'
    Write-Info '  stop      same as: .\chapters\00-lab-setup\lab\teardown.ps1 stop'
    exit 0
}

Read-CourseSetting
Assert-Command 'az' 'Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli'
Assert-AzSignedIn
Assert-ExpectedSubscription

$rg = Get-RgName
$vm = Get-VmName

switch ($Command) {
    'start' {
        # step: cmd-start
        $state = Get-PowerState
        if (-not $state) { Exit-WithError 'No lab VM found. Run .\chapters\00-lab-setup\lab\setup.ps1 first.' }
        if ($state -ne 'PowerState/running') {
            Write-Info "Starting $vm (about a minute)."
            Invoke-AzChange @('vm', 'start', '--resource-group', $rg, '--name', $vm) 'Starting the lab VM'
        }
        Write-Info "The lab VM is running at $(Get-VmPublicIp). Connect with: .\scripts\lab-vm.ps1 connect"
        Write-Info "It shuts down at $($Config.AUTO_SHUTDOWN_TIME) ($($Config.AUTO_SHUTDOWN_TIMEZONE)). Stop it earlier with: .\scripts\lab-vm.ps1 stop"
    }
    'connect' {
        # step: cmd-connect
        Assert-Command 'ssh' 'Install the OpenSSH client.'
        if ((Get-PowerState) -ne 'PowerState/running') { Exit-WithError 'The lab VM is not running. Start it with: .\scripts\lab-vm.ps1 start' }
        Enter-LabSsh
    }
    'sync' {
        # step: cmd-sync
        if ((Get-PowerState) -ne 'PowerState/running') { Exit-WithError 'The lab VM is not running. Start it with: .\scripts\lab-vm.ps1 start' }
        Sync-CourseToVm
        Write-Info 'Done. Your own files in ~/work on the VM were not touched.'
    }
    'status' {
        # step: cmd-status
        $state = Get-PowerState
        if (-not $state) { $state = 'not found' }
        Write-Info "Lab VM: $vm in $rg"
        Write-Info "Power state: $state"
        Write-Info "Public IP: $(Get-VmPublicIp)"
        Write-Info "Auto-shutdown: $($Config.AUTO_SHUTDOWN_TIME) ($($Config.AUTO_SHUTDOWN_TIMEZONE))"
    }
    'stop' {
        # step: cmd-stop
        & (Join-Path $CourseRoot 'chapters/00-lab-setup/lab/teardown.ps1') stop
        exit $LASTEXITCODE
    }
}
