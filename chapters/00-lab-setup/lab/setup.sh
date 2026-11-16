#!/usr/bin/env bash
# Chapter 0 setup. Creates the storage for the Terraform state, then creates or updates the lab
# resource group, the monthly budget and the lab VM with Terraform.
# Run it on your own computer, from the course folder:
#   chapters/00-lab-setup/lab/setup.sh [--yes]
# Safe to run again: it updates what exists and creates what is missing.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/lib.sh
source "${SCRIPT_DIR}/../../../scripts/lib.sh"

CHAPTER="00"

usage() {
  cat <<'EOF'
Usage: chapters/00-lab-setup/lab/setup.sh [--yes]

Creates or updates the chapter 0 lab environment in Azure:
  - resource group <PREFIX>-tfstate-rg with the storage account that holds the Terraform state
  - resource group <PREFIX>-lab-rg
  - monthly budget <PREFIX>-monthly-budget with alerts
  - lab VM <PREFIX>-lab-vm with daily auto-shutdown, reachable over SSH from LEARNER_IP only

Options:
  --yes   do not ask for confirmation
EOF
}

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

# step: preflight
require_laptop
load_env
require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
require_cmd ssh "Install an OpenSSH client."
require_cmd tar "Install tar (Git Bash on Windows includes it)."
require_terraform
require_az_login
require_expected_subscription

if [[ -z "$LEARNER_IP" ]]; then
  die "Set LEARNER_IP in .env to your public IPv4 address."
fi
if [[ ! "$LEARNER_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
  die "LEARNER_IP must be a plain IPv4 address, without /32."
fi

key_file="$(ssh_key_file)"
if [[ ! -f "$key_file" || ! -f "${key_file}.pub" ]]; then
  die "No SSH key pair at ${SSH_KEY_PATH}. Create it with: ssh-keygen -t ed25519 -f ${SSH_KEY_PATH} -C aro-k8s-lab"
fi
ssh_public_key="$(tr -d '\r\n' <"${key_file}.pub")"
if [[ "$ssh_public_key" != ssh-ed25519* && "$ssh_public_key" != ssh-rsa* ]]; then
  die "${SSH_KEY_PATH}.pub is not an Ed25519 or RSA public key."
fi

# step: subscription
step "Subscription"
sub_id="$(az account show --query id --output tsv)"
sub_name="$(az account show --query name --output tsv)"
sub_state="$(az account show --query state --output tsv)"
spending_limit="$(az rest --method get \
  --url "https://management.azure.com/subscriptions/${sub_id}?api-version=2022-12-01" \
  --query subscriptionPolicies.spendingLimit --output tsv 2>/dev/null || echo "unknown")"
info "Subscription: ${sub_name} (${sub_state}), spending limit: ${spending_limit}"
if [[ "$sub_state" != "Enabled" ]]; then
  die "The subscription is ${sub_state}. Wait for the next billing period or pick another subscription."
fi
if [[ "$spending_limit" == "Off" ]]; then
  info "Warning: the spending limit is off, so nothing stops charges at the credit amount. The budget alerts still work."
fi

# step: region
step "Checking the region, the VM size and the image"
size_found="$(az vm list-skus --location "$REGION" --size "$VM_SIZE" --resource-type virtualMachines \
  --query "[?name=='${VM_SIZE}'] | length(@)" --output tsv)"
if [[ "$size_found" == "0" ]]; then
  die "${VM_SIZE} is not offered in ${REGION}. Pick another REGION or VM_SIZE in .env."
fi
size_restrictions="$(az vm list-skus --location "$REGION" --size "$VM_SIZE" --resource-type virtualMachines \
  --query "[?name=='${VM_SIZE}'].restrictions[].reasonCode" --output tsv)"
if [[ -n "$size_restrictions" ]]; then
  die "${VM_SIZE} is restricted for this subscription in ${REGION} (${size_restrictions}). Pick another REGION or VM_SIZE in .env."
fi
if ! az vm image show --urn "$VM_IMAGE" --location "$REGION" --output none 2>/dev/null; then
  die "The image ${VM_IMAGE} is not available in ${REGION}. List the options with: az vm image list --publisher Canonical --offer ubuntu-26_04-lts --location ${REGION} --all --output table"
fi
info "OK: ${VM_SIZE} and ${VM_IMAGE} are available in ${REGION}."

# step: cost
step "Estimated cost (Azure Retail Prices API, ${CURRENCY}, pay-as-you-go)"
vm_hour="$(price_vm_hour)"
disk_month="$(price_disk_month)"
ip_hour="$(price_public_ip_hour)"
info "Lab VM ${VM_SIZE}: ${vm_hour} per hour, only while it runs."
info "OS disk ${OS_DISK_GB} GiB Standard SSD: ${disk_month} per month, even while the VM is stopped."
info "Public IPv4 address: ${ip_hour} per hour, even while the VM is stopped."
info "Terraform state storage: $(price_blob_gb_month) per GB per month. The state takes a few kilobytes."
if [[ "$vm_hour" != "n/a" && "$disk_month" != "n/a" && "$ip_hour" != "n/a" ]]; then
  awk -v vm="$vm_hour" -v disk="$disk_month" -v ip="$ip_hour" -v cur="$CURRENCY" 'BEGIN {
    printf "About %.2f %s per month if the VM runs 2 hours a day (60 hours).\n", vm * 60 + disk + ip * 730, cur
    printf "About %.2f %s per day while the VM is stopped (disk and IP address).\n", disk / 30.4 + ip * 24, cur
  }'
fi
info "Budget: ${BUDGET_AMOUNT} ${CURRENCY} per month for the whole subscription, with alerts."

# step: confirm
if ! confirm "Create or update the lab environment in ${REGION}?"; then
  info "Nothing changed."
  exit 0
fi

# step: providers
step "Registering the resource providers used by the course"
for namespace in Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.DevTestLab \
  Microsoft.ContainerRegistry Microsoft.Consumption Microsoft.ContainerService Microsoft.RedHatOpenShift \
  Microsoft.ManagedIdentity Microsoft.OperationalInsights; do
  state="$(az provider show --namespace "$namespace" --query registrationState --output tsv 2>/dev/null || echo "NotRegistered")"
  if [[ "$state" == "Registered" ]]; then
    info "${namespace}: already registered"
  else
    info "${namespace}: registering (this can take a few minutes)"
    az provider register --namespace "$namespace" --wait --output none
  fi
done

# step: state
step "Storage for the Terraform state"
state_rg="$(state_rg_name)"
state_account="$(state_account_name "$sub_id")"
az group create --tags "${COURSE_TAG_KEY}=${COURSE_TAG_VALUE}" "chapter=${CHAPTER}" --name "$state_rg" --location "$REGION" --output none
if az storage account show --resource-group "$state_rg" --name "$state_account" --output none 2>/dev/null; then
  info "Storage account ${state_account} already exists."
else
  info "Creating storage account ${state_account} in ${state_rg}. Access needs Microsoft Entra ID, never an account key."
  az storage account create --tags "${COURSE_TAG_KEY}=${COURSE_TAG_VALUE}" "chapter=${CHAPTER}" \
    --resource-group "$state_rg" --name "$state_account" --location "$REGION" \
    --sku Standard_LRS --kind StorageV2 --min-tls-version TLS1_2 --https-only true \
    --allow-blob-public-access false --allow-shared-key-access false --output none
fi
# Blob versioning keeps the earlier versions of the state, so a damaged state can be restored.
az storage account blob-service-properties update --resource-group "$state_rg" --account-name "$state_account" \
  --enable-versioning true --output none
if [[ "$(az storage container-rm exists --resource-group "$state_rg" --storage-account "$state_account" \
  --name "$STATE_CONTAINER" --query exists --output tsv)" != "true" ]]; then
  az storage container-rm create --resource-group "$state_rg" --storage-account "$state_account" \
    --name "$STATE_CONTAINER" --output none
fi
account_id="$(az storage account show --resource-group "$state_rg" --name "$state_account" --query id --output tsv)"
user_id="$(az ad signed-in-user show --query id --output tsv)"
role_count="$(az role assignment list --assignee "$user_id" --scope "$account_id" \
  --role "Storage Blob Data Contributor" --query "length(@)" --output tsv)"
if [[ "$role_count" == "0" ]]; then
  info "Giving your account the Storage Blob Data Contributor role on ${state_account}."
  az role assignment create --assignee-object-id "$user_id" --assignee-principal-type User \
    --role "Storage Blob Data Contributor" --scope "$account_id" --output none
fi
info "Waiting until your account can read the state container (a new role can take up to 10 minutes to apply)."
ready="false"
for _ in $(seq 1 60); do
  if az storage blob list --account-name "$state_account" --container-name "$STATE_CONTAINER" \
    --auth-mode login --num-results 1 --output none 2>/dev/null; then
    ready="true"
    break
  fi
  sleep 10
done
if [[ "$ready" != "true" ]]; then
  die "Your account still cannot read the state container after 10 minutes. Wait a few minutes and run setup again."
fi
info "OK: the state of chapter 0 goes to ${state_account}/${STATE_CONTAINER}/00-lab-setup.tfstate."

# step: plan
step "Planning the lab environment with Terraform"
contact_email="${BUDGET_CONTACT_EMAIL:-$(az account show --query user.name --output tsv)}"
if [[ "$contact_email" != *@* ]]; then
  die "No e-mail address for budget alerts. Set BUDGET_CONTACT_EMAIL in .env."
fi
vm_existed="false"
if az vm show --resource-group "$(rg_name)" --name "$(vm_name)" --output none 2>/dev/null; then
  vm_existed="true"
fi
infra_dir="${SCRIPT_DIR}/infra"
terraform_env "00-lab-setup" "$sub_id"
export_lab_tf_vars "$state_account" "$contact_email" "$ssh_public_key"
plan_file="${TF_DATA_DIR}/lab.tfplan"
if ! terraform_init "$infra_dir" "$state_account" "00-lab-setup.tfstate"; then
  die "terraform init failed. Read the message above, fix the cause and run setup again."
fi
if ! terraform_in "$infra_dir" plan -out="$plan_file"; then
  die "terraform plan failed. Read the message above, fix the cause and run setup again."
fi

# step: apply
if ! confirm "Apply this plan?"; then
  info "The lab environment is unchanged. The state storage stays for the next run."
  exit 0
fi
step "Applying the plan (about 3 minutes)"
if ! terraform_in "$infra_dir" apply "$plan_file"; then
  die "terraform apply failed. Read the message above, fix the cause and run setup again."
fi
rm -f "$plan_file"
info "Terraform finished."

# step: start-vm
power_state="$(az vm get-instance-view --resource-group "$(rg_name)" --name "$(vm_name)" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv)"
if [[ "$power_state" != "PowerState/running" ]]; then
  info "The lab VM is ${power_state#PowerState/}. Starting it."
  az vm start --resource-group "$(rg_name)" --name "$(vm_name)" --output none
fi

vm_ip="$(vm_public_ip)"
if [[ "$vm_existed" == "false" ]]; then
  # A new VM can reuse an old IP address with a new host key: forget the old key.
  ssh-keygen -R "$vm_ip" -f "$(known_hosts_file)" >/dev/null 2>&1 || true
fi

# step: wait-ssh
step "Waiting for SSH on ${vm_ip}"
ready="false"
for _ in $(seq 1 30); do
  if tcp_port_open "$vm_ip" 22; then
    ready="true"
    break
  fi
  sleep 10
done
if [[ "$ready" != "true" ]]; then
  die "SSH did not answer after 5 minutes. Check that LEARNER_IP in .env is still your public IP, then run setup again."
fi

# step: wait-cloud-init
step "Waiting for cloud-init to install the tools (5 to 10 minutes on the first run)"
if ! lab_ssh "cloud-init status --wait > /dev/null 2>&1; test -f /etc/aro-k8s/tools-ready"; then
  die "The tool installation did not finish. Read the log on the VM with: scripts/lab-vm.sh connect, then: sudo tail -n 50 /var/log/aro-k8s-install.log"
fi
lab_ssh "cat /etc/aro-k8s/tools-ready"

# step: sync
step "Copying the course files to the lab VM"
sync_course_to_vm

# step: done
step "Done"
info "Setup took $(duration_text "$SECONDS")."
info "Lab VM: $(vm_name) in $(rg_name), reachable from ${LEARNER_IP} only."
info "It shuts down every day at ${AUTO_SHUTDOWN_TIME} (${AUTO_SHUTDOWN_TIMEZONE}). Stop it yourself when you finish:"
info "  chapters/00-lab-setup/lab/teardown.sh stop"
info "Next: run the readiness report."
info "  chapters/00-lab-setup/lab/validate.sh"
