<#
.SYNOPSIS
Readiness report of the environment of the course on Windows. Read-only: it changes nothing.

.DESCRIPTION
Run it from the kit folder: .\course.ps1 check
It checks WSL and the course's WSL distribution from Windows, then reads the tools, the registry, the kit and
the cluster inside the distribution. setup/check.sh runs the same checks inside the environment, with the same IDs.
Exit code 0 when no check fails, 1 otherwise.
#>
[CmdletBinding()]
param()

. (Join-Path (Join-Path $PSScriptRoot '..') 'lib/lib.ps1')

Write-Info ("Readiness report, {0} UTC" -f (Get-Date).ToUniversalTime().ToString('yyyy-MM-dd HH:mm'))

Write-Step 'Platform'
# check: platform
$wslVersion = Invoke-Wsl @('--version')
if (-not (Test-Command 'wsl.exe') -or $wslVersion.ExitCode -ne 0) {
    Add-Fail 'WSL is not installed, or too old to report its version.' 'From an administrator PowerShell: wsl --install, then restart Windows. An old WSL updates with: wsl --update'
    Complete-CheckRun
}
Add-Pass "Windows $([Environment]::OSVersion.Version), $(($wslVersion.Output -split "`n")[0])."

# check: environment
$state = Get-DistroState
if (-not $state) {
    Add-Fail "The WSL distribution $DistroName does not exist." 'Create it with: .\course.ps1 up'
    Complete-CheckRun
}
if ((Get-DistroWslVersion) -ne '2') {
    Add-Fail "The distribution $DistroName runs on WSL 1. kind needs WSL 2." "Convert it with: wsl --set-version $DistroName 2"
    Complete-CheckRun
}
if ($state -ne 'Running') { Write-Info "The distribution is $state. The report starts it, as a terminal would." }

# Everything inside the distribution, read in one call, one key=value per line.
$probe = @'
source ~/__KIT_NAME__/lib/lib.sh 2>/dev/null || { echo kit_lib=missing; exit 0; }
echo "user=$(id -un)"
echo "marker=$(in_course_wsl && echo yes || echo no)"
echo "pid1=$(ps -p 1 -o comm= 2>/dev/null)"
echo "docker_cli=$(command -v docker >/dev/null 2>&1 && echo yes || echo no)"
echo "docker_ok=$(docker info >/dev/null 2>&1 && echo yes || echo no)"
echo "docker_version=$(docker_version)"
echo "docker_os=$(docker info --format '{{.OperatingSystem}}' 2>/dev/null)"
echo "kind=$(kind_version)"
echo "kubectl=$(kubectl_version)"
missing=""
for tool in git curl jq python3; do command -v "$tool" >/dev/null 2>&1 || missing="$missing $tool"; done
python3 -c 'import yaml' 2>/dev/null || missing="$missing python3-yaml"
echo "missing=${missing# }"
echo "inotify=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
echo "registry=$(registry_state)"
echo "registry_http=$(curl -fsS --max-time 5 "http://${REGISTRY_HOST}/v2/" >/dev/null 2>&1 && echo yes || echo no)"
echo "registry_volume=$(docker container inspect --format '{{range .Mounts}}{{.Name}} {{end}}' "$REGISTRY_NAME" 2>/dev/null | grep -qw "$REGISTRY_VOLUME" && echo yes || echo no)"
echo "kit=$(git -C ~/__KIT_NAME__ rev-parse --short HEAD 2>/dev/null)"
echo "course_cmd=$(command -v course)"
if cluster_exists; then
  echo "cluster=yes"
  echo "cluster_lab=$(cluster_lab)"
  echo "stopped=$(cluster_nodes_state | awk '$2 != "running" {print $1}' | tr '\n' ' ')"
  echo "api=$(kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1 && echo yes || echo no)"
else
  echo "cluster=no"
fi
'@
$values = @{}
foreach ($line in (Invoke-InDistroScript $probe.Replace('__KIT_NAME__', $KitName)).Output -split "`n") {
    if ($line -match '^([a-z_0-9]+)=(.*)$') { $values[$Matches[1]] = $Matches[2].Trim() }
}
function Get-Value([string]$Key) { if ($values.ContainsKey($Key)) { return $values[$Key] } return '' }

if ((Get-Value 'kit_lib') -eq 'missing') {
    Add-Fail "The kit is missing in $DistroName (~/$KitName)." "Read the install log: wsl -d $DistroName -u root -- tail -n 50 /var/log/$KitName-install.log"
    Complete-CheckRun
}
if ((Get-Value 'user') -eq $LinuxUser -and (Get-Value 'marker') -eq 'yes') {
    Add-Pass "The distribution $DistroName runs on WSL 2, and you log in as $LinuxUser."
}
else {
    Add-Fail "The distribution $DistroName logs in as '$(Get-Value 'user')', or was not built by course up." "Stop it with .\course.ps1 stop and run .\course.ps1 up. If that does not help: .\course.ps1 destroy, then .\course.ps1 up"
}
# check: systemd
if ((Get-Value 'pid1') -eq 'systemd') { Add-Pass 'systemd runs, so Docker Engine starts with the distribution.' }
else { Add-Warn 'systemd does not run in the distribution, so nothing starts Docker Engine by itself.' 'Stop the distribution with .\course.ps1 stop, then connect again.' }

Write-Step 'Tools'
# check: docker
if ((Get-Value 'docker_cli') -ne 'yes') {
    Add-Fail "Docker is not installed in $DistroName." 'Run: .\course.ps1 up'
}
elseif ((Get-Value 'docker_ok') -ne 'yes') {
    Add-Fail "Docker Engine does not answer in $DistroName." 'Stop the distribution with .\course.ps1 stop, then run .\course.ps1 check again.'
}
else {
    Add-Pass "Docker Engine $(Get-Value 'docker_version') answers. The course does not pin its version."
    # check: docker-engine
    if ((Get-Value 'docker_os') -like '*Docker Desktop*') {
        Add-Warn 'The docker command reaches Docker Desktop, not the own Docker Engine of the distribution.' "In Docker Desktop, open Settings, Resources, WSL integration, and turn it off for $DistroName."
    }
    else { Add-Pass "Docker runs on $(Get-Value 'docker_os')." }
}
# check: kind
$found = Get-Value 'kind'
if ($found -eq $PinnedKindVersion) { Add-Pass "kind $found." }
elseif ($found) { Add-Warn "kind $found, and the course pins $PinnedKindVersion." 'Run: .\course.ps1 destroy, then .\course.ps1 up' }
else { Add-Fail 'kind is not installed.' 'Run: .\course.ps1 up' }
# check: kubectl
$found = Get-Value 'kubectl'
if ($found -like "$PinnedKubectlMinor.*") { Add-Pass "kubectl $found." }
elseif ($found) { Add-Warn "kubectl $found, and the course pins $PinnedKubectlMinor." 'Run: .\course.ps1 destroy, then .\course.ps1 up' }
else { Add-Fail 'kubectl is not installed.' 'Run: .\course.ps1 up' }
# check: tools-other
if (-not (Get-Value 'missing')) { Add-Pass 'git, curl, jq and the YAML module of Python are installed.' }
else { Add-Fail "Missing in ${DistroName}: $(Get-Value 'missing')." 'Run: .\course.ps1 up' }
# check: inotify
$watches = 0
[void][int]::TryParse((Get-Value 'inotify'), [ref]$watches)
if ($watches -ge 524288) { Add-Pass "inotify allows $watches watches, enough for a kind cluster of three nodes." }
else { Add-Warn "inotify allows $watches watches. A kind cluster of three nodes may fail to start." 'Run: .\course.ps1 destroy, then .\course.ps1 up' }

Write-Step 'Registry, kit and cluster'
# check: registry
$registry = Get-Value 'registry'
if ($registry -eq 'running' -and (Get-Value 'registry_http') -eq 'yes') {
    if ((Get-Value 'registry_volume') -eq 'yes') { Add-Pass "The registry $RegistryName answers on localhost:$RegistryPort, with its data in its volume." }
    else { Add-Warn "The registry $RegistryName answers on localhost:$RegistryPort, but keeps its data outside its volume." "In the distribution: docker rm --force $RegistryName, then course up. The images you pushed are lost." }
}
elseif ($registry) { Add-Fail "The registry $RegistryName is $registry, or does not answer on localhost:$RegistryPort." 'Run: .\course.ps1 up. It starts the registry.' }
else { Add-Fail "The registry $RegistryName does not exist." 'Run: .\course.ps1 up' }
# check: kit
if ((Get-Value 'kit') -and (Get-Value 'course_cmd')) { Add-Pass "The kit is cloned in ~/$KitName (commit $(Get-Value 'kit')), and course is on the PATH of the distribution." }
else { Add-Fail "The kit or the course command is missing in $DistroName." "Read the install log: wsl -d $DistroName -u root -- tail -n 50 /var/log/$KitName-install.log" }
# check: cluster
if ((Get-Value 'cluster') -ne 'yes') {
    Add-Pass 'No kind cluster runs now. A lab that needs one creates it with course start NN.'
}
else {
    $lab = Get-Value 'cluster_lab'
    if (-not $lab) { $lab = 'NN' }
    if ((Get-Value 'stopped')) { Add-Warn "The cluster of lab $lab has stopped nodes: $(Get-Value 'stopped')." "In the distribution, bring it back with: course start $lab" }
    elseif ((Get-Value 'api') -eq 'yes') { Add-Pass "The cluster of lab $lab runs." }
    else { Add-Warn "The cluster of lab $lab does not answer yet." "In the distribution, run: course start $lab" }
}

Complete-CheckRun
