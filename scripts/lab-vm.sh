#!/usr/bin/env bash
# Everyday helper for the lab VM. Run it on your own computer, from the course folder.
#   scripts/lab-vm.sh start     start the VM and print how to connect
#   scripts/lab-vm.sh connect   open an SSH session on the VM
#   scripts/lab-vm.sh sync      copy the course files and .env to ~/aro-k8s-course on the VM
#   scripts/lab-vm.sh status    show the power state, the IP address and the shutdown time
#   scripts/lab-vm.sh stop      same as: chapters/00-lab-setup/lab/teardown.sh stop
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "${SCRIPT_DIR}/lib.sh"

usage() {
  sed -n '2,7p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

command_name="${1:-}"
if [[ -z "$command_name" || "$command_name" == "-h" || "$command_name" == "--help" ]]; then
  usage
  exit 0
fi

require_laptop
load_env
require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
require_az_login
require_expected_subscription

rg="$(rg_name)"
vm="$(vm_name)"

power_state() {
  az vm get-instance-view --resource-group "$rg" --name "$vm" \
    --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv 2>/dev/null || true
}

case "$command_name" in
  start)
    # step: cmd-start
    state="$(power_state)"
    if [[ -z "$state" ]]; then
      die "No lab VM found. Run chapters/00-lab-setup/lab/setup.sh first."
    fi
    if [[ "$state" != "PowerState/running" ]]; then
      info "Starting ${vm} (about a minute)."
      az vm start --resource-group "$rg" --name "$vm" --output none
    fi
    info "The lab VM is running at $(vm_public_ip). Connect with: scripts/lab-vm.sh connect"
    info "It shuts down at ${AUTO_SHUTDOWN_TIME} (${AUTO_SHUTDOWN_TIMEZONE}). Stop it earlier with: scripts/lab-vm.sh stop"
    ;;
  connect)
    # step: cmd-connect
    require_cmd ssh "Install an OpenSSH client."
    if [[ "$(power_state)" != "PowerState/running" ]]; then
      die "The lab VM is not running. Start it with: scripts/lab-vm.sh start"
    fi
    lab_ssh
    ;;
  sync)
    # step: cmd-sync
    require_cmd ssh "Install an OpenSSH client."
    require_cmd tar "Install tar (Git Bash on Windows includes it)."
    if [[ "$(power_state)" != "PowerState/running" ]]; then
      die "The lab VM is not running. Start it with: scripts/lab-vm.sh start"
    fi
    sync_course_to_vm
    info "Done. Your own files in ~/work on the VM were not touched."
    ;;
  status)
    # step: cmd-status
    state="$(power_state)"
    info "Lab VM: ${vm} in ${rg}"
    info "Power state: ${state:-not found}"
    info "Public IP: $(vm_public_ip)"
    info "Auto-shutdown: ${AUTO_SHUTDOWN_TIME} (${AUTO_SHUTDOWN_TIMEZONE})"
    ;;
  stop)
    # step: cmd-stop
    exec "${COURSE_ROOT}/chapters/00-lab-setup/lab/teardown.sh" stop
    ;;
  *)
    usage
    exit 1
    ;;
esac
