#!/usr/bin/env bash
# Readiness report of the lab environment. Read-only: it changes nothing in Azure or on the lab VM.
# Run it on your own computer, from the kit folder:
#   ./course check
# Exit code 0 when no check fails, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/lib.sh
source "${SCRIPT_DIR}/../lib/lib.sh"

CHAPTER="$SETUP_CHAPTER"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: ./course check"
  echo "Prints PASS, FAIL or WARN for each readiness check. Changes nothing."
  exit 0
fi

require_laptop
load_env
require_cmd az "Install the Azure CLI: https://learn.microsoft.com/cli/azure/install-azure-cli"
require_cmd ssh "Install an OpenSSH client."

printf 'Readiness report, %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M')"

# ---------------------------------------------------------------------------
step "Azure CLI and subscription"
# check: cli-signed-in
if ! az_signed_in; then
  check_fail "The Azure CLI is not signed in." "Run: az login"
  check_summary
  exit $?
fi
check_pass "The Azure CLI is signed in."

sub_id="$(az account show --query id --output tsv)"
sub_name="$(az account show --query name --output tsv)"
sub_state="$(az account show --query state --output tsv)"
# check: subscription-match
if [[ -n "$AZURE_SUBSCRIPTION" && "$AZURE_SUBSCRIPTION" != "$sub_name" && "$AZURE_SUBSCRIPTION" != "$sub_id" ]]; then
  check_fail "The CLI points at '${sub_name}', not at AZURE_SUBSCRIPTION from .env." "Run: az account set --subscription \"<value of AZURE_SUBSCRIPTION>\""
else
  check_pass "Subscription in use: ${sub_name}."
fi
# check: subscription-state
if [[ "$sub_state" == "Enabled" ]]; then
  check_pass "The subscription is Enabled."
else
  check_fail "The subscription is ${sub_state}." "A spent credit disables the subscription until the next billing period."
fi

# check: spending-limit
sub_policies="$(az rest --method get --url "https://management.azure.com/subscriptions/${sub_id}?api-version=2022-12-01" \
  --query "[subscriptionPolicies.spendingLimit, subscriptionPolicies.quotaId]" --output tsv 2>/dev/null || true)"
spending_limit="$(printf '%s\n' "$sub_policies" | sed -n '1p')"
quota_id="$(printf '%s\n' "$sub_policies" | sed -n '2p')"
case "$spending_limit" in
  On) check_pass "The spending limit is on (offer: ${quota_id:-unknown})." ;;
  Off) check_warn "The spending limit is off (offer: ${quota_id:-unknown})." "Charges continue past the credit amount. Rely on the budget alerts and stop resources quickly." ;;
  *) check_warn "Could not read the spending limit (offer: ${quota_id:-unknown})." "Check it in the portal under Subscriptions, Overview." ;;
esac

# ---------------------------------------------------------------------------
step "Region ${REGION}"
# check: region-vm-size
size_count="$(az vm list-skus --location "$REGION" --size "$VM_SIZE" --resource-type virtualMachines \
  --query "[?name=='${VM_SIZE}'] | length(@)" --output tsv 2>/dev/null || echo 0)"
size_restrictions="$(az vm list-skus --location "$REGION" --size "$VM_SIZE" --resource-type virtualMachines \
  --query "[?name=='${VM_SIZE}'].restrictions[].reasonCode" --output tsv 2>/dev/null || true)"
if [[ "$size_count" == "0" ]]; then
  check_fail "${VM_SIZE} is not offered in ${REGION}." "Pick another REGION or VM_SIZE in .env."
elif [[ -n "$size_restrictions" ]]; then
  check_fail "${VM_SIZE} is restricted for this subscription in ${REGION} (${size_restrictions})." "Pick another REGION or VM_SIZE in .env."
else
  check_pass "${VM_SIZE} is available in ${REGION}."
fi

# check: region-aks-aro
region_display="$(az account list-locations --query "[?name=='${REGION}'].displayName | [0]" --output tsv 2>/dev/null || true)"
for pair in "Microsoft.ContainerService:managedClusters:AKS (chapter 6)" "Microsoft.RedHatOpenShift:OpenShiftClusters:ARO (chapters 8 and 9)"; do
  namespace="${pair%%:*}"
  rest="${pair#*:}"
  resource_type="${rest%%:*}"
  label="${rest#*:}"
  locations="$(az provider show --namespace "$namespace" \
    --query "resourceTypes[?resourceType=='${resource_type}'].locations[]" --output tsv 2>/dev/null || true)"
  if [[ -n "$region_display" ]] && grep -qix "$region_display" <<<"$locations"; then
    check_pass "${label} is offered in ${region_display}."
  else
    check_warn "${label} does not list ${REGION} as a location." "Choose a region that offers it before that chapter."
  fi
done

# ---------------------------------------------------------------------------
step "Resource providers"
# check: providers-now
for namespace in Microsoft.Compute Microsoft.Network Microsoft.Storage Microsoft.DevTestLab Microsoft.ContainerRegistry Microsoft.Consumption; do
  state="$(az provider show --namespace "$namespace" --query registrationState --output tsv 2>/dev/null || echo "Unknown")"
  if [[ "$state" == "Registered" ]]; then
    check_pass "${namespace} is registered (needed now)."
  else
    check_fail "${namespace} is ${state} (needed now)." "Run ./course up --apply, or: az provider register --namespace ${namespace}"
  fi
done
# check: providers-later
for namespace in Microsoft.ContainerService Microsoft.RedHatOpenShift Microsoft.Authorization Microsoft.ManagedIdentity Microsoft.OperationalInsights; do
  state="$(az provider show --namespace "$namespace" --query registrationState --output tsv 2>/dev/null || echo "Unknown")"
  if [[ "$state" == "Registered" ]]; then
    check_pass "${namespace} is registered (needed later)."
  else
    check_warn "${namespace} is ${state} (needed later)." "Register it before the chapter that uses it: az provider register --namespace ${namespace}"
  fi
done

# ---------------------------------------------------------------------------
step "vCPU quotas in ${REGION}"
usage_table="$(az vm list-usage --location "$REGION" --query "[].[name.value, currentValue, limit]" --output tsv 2>/dev/null || true)"
quota_line() {
  awk -v n="$1" '$1 == n { print $2, $3 }' <<<"$usage_table"
}
read -r regional_used regional_limit <<<"$(quota_line cores)" || true
read -r dasv5_used dasv5_limit <<<"$(quota_line standardDASv5Family)" || true
read -r dsv5_used dsv5_limit <<<"$(quota_line standardDSv5Family)" || true

# check: quota-regional
# check: quota-regional-aro
if [[ -z "${regional_limit:-}" ]]; then
  check_fail "Could not read the regional vCPU quota." "Run: az vm list-usage --location ${REGION} --output table"
else
  if ((regional_limit >= 2)); then
    check_pass "Total regional vCPUs: ${regional_used} used of ${regional_limit} (the lab VM needs 2)."
  else
    check_fail "Total regional vCPUs: limit ${regional_limit}, the lab VM needs 2." "Request an increase under Quotas in the portal."
  fi
  if ((regional_limit < 46)); then
    check_warn "Total regional vCPU limit is ${regional_limit}. ARO needs 44 vCPUs at install time, plus 2 for the lab VM." "Request 46 or more before chapter 8. Credit-based subscriptions may not get it, see the course page on quotas (azure-limits.html)."
  else
    check_pass "Total regional vCPU limit ${regional_limit} covers ARO (44) and the lab VM (2)."
  fi
fi
# check: quota-dasv5
if [[ -z "${dasv5_limit:-}" ]]; then
  check_warn "Could not read the DASv5 family quota." "Run: az vm list-usage --location ${REGION} --output table"
elif ((dasv5_limit >= 2)); then
  check_pass "DASv5 family vCPUs: ${dasv5_used} used of ${dasv5_limit} (lab VM size)."
else
  check_fail "DASv5 family vCPU limit is ${dasv5_limit}, the lab VM needs 2." "Request an increase for Standard DASv5 Family vCPUs."
fi
# check: quota-dsv5
if [[ -z "${dsv5_limit:-}" ]]; then
  check_warn "Could not read the DSv5 family quota." "Run: az vm list-usage --location ${REGION} --output table"
elif ((dsv5_limit >= 44)); then
  check_pass "DSv5 family vCPUs: ${dsv5_used} used of ${dsv5_limit}, enough for the default ARO node sizes (44 at install time)."
else
  check_warn "DSv5 family vCPU limit is ${dsv5_limit}. The default ARO node sizes need 44 at install time." "Request an increase for Standard DSv5 Family vCPUs before chapter 8."
fi

# ---------------------------------------------------------------------------
step "Terraform and its state"
# check: terraform-cli
tf_version="$(terraform_version 2>/dev/null || true)"
if [[ -z "$tf_version" ]]; then
  check_fail "Terraform is not installed on this computer." "Install it: https://developer.hashicorp.com/terraform/install"
elif version_at_least "$tf_version" "$TERRAFORM_MIN_VERSION"; then
  check_pass "Terraform ${tf_version} is installed."
else
  check_fail "Terraform ${tf_version} is installed, the course needs ${TERRAFORM_MIN_VERSION} or later." "Install a newer version: https://developer.hashicorp.com/terraform/install"
fi

# check: tfstate-storage
state_account="$(state_account_name "$sub_id")"
state_info="$(az storage account show --resource-group "$(state_rg_name)" --name "$state_account" \
  --query "[tags.course, tags.chapter, allowSharedKeyAccess]" --output tsv 2>/dev/null || true)"
if [[ -z "$state_info" ]]; then
  check_fail "No Terraform state storage account ${state_account} in $(state_rg_name)." "Run ./course up."
elif [[ "$(tr '\n' ' ' <<<"$state_info")" == "${COURSE_TAG_VALUE} ${CHAPTER} false " ]]; then
  check_pass "State storage account ${state_account} has the course tags and refuses account keys."
else
  check_warn "State storage account ${state_account} is missing the course tags or accepts account keys." "Run ./course up --apply."
fi

# check: tfstate-blob
if [[ -n "$state_info" ]] && [[ "$(az storage blob exists --account-name "$state_account" --container-name "$STATE_CONTAINER" \
  --name "${SETUP_FOLDER}.tfstate" --auth-mode login --query exists --output tsv 2>/dev/null || true)" == "true" ]]; then
  check_pass "The state of the setup is in ${state_account}/${STATE_CONTAINER}, and your account can read it."
else
  check_fail "The state of the setup is missing, or your account cannot read it." "Run ./course up. A new role can take up to 10 minutes to apply."
fi

# ---------------------------------------------------------------------------
step "Budget"
# check: budget-exists
# check: budget-amount
# check: budget-alerts
# check: budget-forecast
budget_json_query="[properties.amount, properties.timeGrain, length(values(properties.notifications)), length(values(properties.notifications)[?thresholdType=='Forecasted'])]"
budget_info="$(az rest --method get \
  --url "https://management.azure.com/subscriptions/${sub_id}/providers/Microsoft.Consumption/budgets/$(budget_name)?api-version=2023-05-01" \
  --query "$budget_json_query" --output tsv 2>/dev/null || true)"
if [[ -z "$budget_info" ]]; then
  check_fail "Budget $(budget_name) not found." "Run ./course up."
else
  read -r budget_amount budget_grain alert_count forecast_count <<<"$(tr '\n' ' ' <<<"$budget_info")"
  if [[ "${budget_amount%.*}" == "$BUDGET_AMOUNT" ]]; then
    check_pass "Budget $(budget_name): ${BUDGET_AMOUNT} ${CURRENCY}, ${budget_grain}."
  else
    check_warn "Budget amount is ${budget_amount%.*}, .env says ${BUDGET_AMOUNT}." "Run ./course up --apply to apply the amount from .env."
  fi
  if ((alert_count >= 1)); then
    check_pass "The budget has ${alert_count} alerts."
  else
    check_fail "The budget has no alerts." "Run ./course up --apply."
  fi
  if ((forecast_count >= 1)); then
    check_pass "The budget has a forecast alert."
  else
    check_warn "The budget has no forecast alert." "Forecast alerts warn you before the money is spent."
  fi
fi

# ---------------------------------------------------------------------------
step "Lab resources and tags"
rg="$(rg_name)"
vm="$(vm_name)"
# check: rg-tags
rg_tags="$(az group show --name "$rg" --query "[tags.course, tags.chapter]" --output tsv 2>/dev/null || true)"
if [[ -z "$rg_tags" ]]; then
  check_fail "Resource group ${rg} not found." "Run ./course up."
  check_summary
  exit $?
fi
if [[ "$(tr '\n' ' ' <<<"$rg_tags")" == "${COURSE_TAG_VALUE} ${CHAPTER} " ]]; then
  check_pass "Resource group ${rg} has the tags ${COURSE_TAG_KEY}=${COURSE_TAG_VALUE} and chapter=${CHAPTER}."
else
  check_fail "Resource group ${rg} is missing the course tags." "Run ./course up --apply."
fi

# check: vm-tags
# check: vm-size
vm_info="$(az vm show --resource-group "$rg" --name "$vm" \
  --query "[tags.course, tags.chapter, hardwareProfile.vmSize, identity.principalId]" --output tsv 2>/dev/null || true)"
if [[ -z "$vm_info" ]]; then
  check_fail "Lab VM ${vm} not found." "Run ./course up."
  check_summary
  exit $?
fi
read -r vm_course vm_chapter vm_size vm_principal <<<"$(tr '\n' ' ' <<<"$vm_info")"
if [[ "$vm_course" == "$COURSE_TAG_VALUE" && "$vm_chapter" == "$CHAPTER" ]]; then
  check_pass "Lab VM ${vm} has the course tags."
else
  check_fail "Lab VM ${vm} is missing the course tags." "Run ./course up --apply."
fi
if [[ "$vm_size" == "$VM_SIZE" ]]; then
  check_pass "Lab VM size is ${vm_size}."
else
  check_warn "Lab VM size is ${vm_size}, .env says ${VM_SIZE}." "Run ./course up --apply to align them."
fi

# check: untagged
untagged="$(az resource list --resource-group "$rg" \
  --query "[?tags.course!='${COURSE_TAG_VALUE}' && type!='Microsoft.Compute/disks'].name" --output tsv 2>/dev/null || true)"
if [[ -z "$untagged" ]]; then
  check_pass "Every resource in ${rg} carries the course tag (the OS disk is checked through the VM)."
else
  check_warn "Resources without the course tag in ${rg}: $(tr '\n' ' ' <<<"$untagged")" "Tag them or delete them, so teardown can find them."
fi

# check: auto-shutdown
shutdown_info="$(az resource show --resource-group "$rg" --resource-type Microsoft.DevTestLab/schedules \
  --name "shutdown-computevm-${vm}" --query "[properties.status, properties.dailyRecurrence.time, properties.timeZoneId]" \
  --output tsv 2>/dev/null || true)"
if [[ -z "$shutdown_info" ]]; then
  check_fail "No auto-shutdown schedule on ${vm}." "Run ./course up --apply."
else
  read -r shutdown_status shutdown_time shutdown_zone <<<"$(tr '\n' ' ' <<<"$shutdown_info")"
  if [[ "$shutdown_status" == "Enabled" ]]; then
    check_pass "Auto-shutdown is enabled at ${shutdown_time} (${shutdown_zone})."
  else
    check_fail "Auto-shutdown is ${shutdown_status}." "Run ./course up --apply."
  fi
fi

# check: nsg
nsg_rules="$(az network nsg rule list --resource-group "$rg" --nsg-name "${vm}-nsg" \
  --query "[?direction=='Inbound' && access=='Allow'].[name, sourceAddressPrefix, destinationPortRange]" --output tsv 2>/dev/null || true)"
rule_count="$(grep -c . <<<"$nsg_rules" || true)"
if [[ "$rule_count" == "1" ]] && grep -q $'\t'"${LEARNER_IP}/32"$'\t22$' <<<"$nsg_rules"; then
  check_pass "The NSG allows SSH (port 22) from LEARNER_IP only."
elif grep -q $'\t22$' <<<"$nsg_rules"; then
  check_fail "The NSG inbound rules do not match LEARNER_IP from .env, or allow more than SSH." "If your IP changed, update LEARNER_IP in .env and run ./course up again."
else
  check_fail "No NSG rule allows SSH to the lab VM." "Run ./course up --apply."
fi

# check: identity-roles
if [[ -n "$vm_principal" ]]; then
  rg_id="$(az group show --name "$rg" --query id --output tsv)"
  roles="$(az role assignment list --assignee "$vm_principal" --scope "$rg_id" --query "[].roleDefinitionName" --output tsv 2>/dev/null || true)"
  state_id="$(az storage account show --resource-group "$(state_rg_name)" --name "$(state_account_name "$sub_id")" --query id --output tsv 2>/dev/null || true)"
  state_roles=""
  if [[ -n "$state_id" ]]; then
    state_roles="$(az role assignment list --assignee "$vm_principal" --scope "$state_id" --query "[].roleDefinitionName" --output tsv 2>/dev/null || true)"
  fi
  if grep -qx "Contributor" <<<"$roles" && grep -qx "AcrPush" <<<"$roles" && grep -qx "Storage Blob Data Contributor" <<<"$state_roles"; then
    check_pass "The VM managed identity has Contributor and AcrPush on ${rg}, and Storage Blob Data Contributor on the state storage."
  else
    check_fail "The VM managed identity lacks Contributor or AcrPush on ${rg}, or Storage Blob Data Contributor on the state storage." "Run ./course up --apply. Role assignments can take up to 10 minutes to appear."
  fi
else
  check_fail "The lab VM has no managed identity." "Run ./course up --apply."
fi

# ---------------------------------------------------------------------------
step "Tools on the lab VM"
# check: vm-running
power_state="$(az vm get-instance-view --resource-group "$rg" --name "$vm" \
  --query "instanceView.statuses[?starts_with(code, 'PowerState/')].code | [0]" --output tsv 2>/dev/null || true)"
if [[ "$power_state" != "PowerState/running" ]]; then
  check_warn "The lab VM is ${power_state#PowerState/}, so the tool checks were skipped." "Start it with: ./course up, then run this report again."
  check_summary
  exit $?
fi
check_pass "The lab VM is running."

# check: vm-ssh
vm_report="$(lab_ssh 'bash -s' <<'REMOTE' 2>/dev/null || true
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
printf 'kit=%s\n' "$(git -C ~/aro-k8s-course rev-parse --short HEAD 2>/dev/null || echo missing)"
printf 'env=%s\n' "$(test -f ~/aro-k8s-course/.env && echo yes || echo no)"
printf 'launcher=%s\n' "$(command -v course >/dev/null 2>&1 && echo yes || echo no)"
REMOTE
)"
if [[ -z "$vm_report" ]]; then
  check_fail "Could not connect to the lab VM over SSH." "Check LEARNER_IP in .env against your current public IP, then run ./course up again."
  check_summary
  exit $?
fi
vm_value() {
  sed -n "s/^$1=//p" <<<"$vm_report"
}

# check: tools-cloud-init
if [[ "$(vm_value marker)" == "yes" ]]; then
  check_pass "cloud-init finished installing the tools ($(vm_value cloudinit))."
else
  check_fail "cloud-init has not finished installing the tools (status: $(vm_value cloudinit))." "On the VM: sudo tail -n 50 /var/log/aro-k8s-install.log"
fi
# check: tools-docker
docker_version="$(vm_value docker)"
if [[ "$docker_version" != "missing" && -n "$docker_version" ]]; then
  check_pass "Docker Engine ${docker_version} answers without sudo."
else
  check_fail "Docker does not answer for ${ADMIN_USERNAME} without sudo." "Reconnect to the VM (group membership applies to new sessions) or read the install log."
fi
# check: tools-kind
kind_version="$(vm_value kind)"
if [[ "$kind_version" == "$PINNED_KIND_VERSION" ]]; then
  check_pass "kind ${kind_version} is installed."
elif [[ "$kind_version" == "missing" || -z "$kind_version" ]]; then
  check_fail "kind is missing." "Read the install log on the VM."
else
  check_warn "kind ${kind_version} is installed, the course expects ${PINNED_KIND_VERSION}." "Chapter 2 may behave differently."
fi
# check: tools-kubectl
kubectl_version="$(vm_value kubectl)"
if [[ "$kubectl_version" == "${PINNED_KUBECTL_MINOR}".* ]]; then
  check_pass "kubectl ${kubectl_version} is installed."
elif [[ "$kubectl_version" == "missing" || -z "$kubectl_version" ]]; then
  check_fail "kubectl is missing." "Read the install log on the VM."
else
  check_warn "kubectl ${kubectl_version} is installed, the course expects ${PINNED_KUBECTL_MINOR}.x." "kubectl works with clusters one minor version older or newer."
fi
# check: tools-terraform
terraform_vm_version="$(vm_value terraform)"
if [[ "$terraform_vm_version" == "$PINNED_TERRAFORM_VERSION" ]]; then
  check_pass "Terraform ${terraform_vm_version} is installed."
elif [[ "$terraform_vm_version" == "missing" || -z "$terraform_vm_version" ]]; then
  check_fail "Terraform is missing on the lab VM." "Read the install log on the VM."
else
  check_warn "Terraform ${terraform_vm_version} is installed, the course expects ${PINNED_TERRAFORM_VERSION}." "Later chapters may behave differently."
fi
# check: tools-other
for tool in az git jq; do
  tool_version="$(vm_value "$tool")"
  if [[ "$tool_version" != "missing" && -n "$tool_version" ]]; then
    check_pass "${tool} ${tool_version} is installed."
  else
    check_fail "${tool} is missing on the lab VM." "Read the install log on the VM."
  fi
done
# check: inotify
watches="$(vm_value watches)"
if [[ "$watches" =~ ^[0-9]+$ ]] && ((watches >= 524288)); then
  check_pass "inotify limits are raised for kind."
else
  check_warn "inotify limits are at the Ubuntu default." "On the VM: sudo sysctl --system"
fi
# check: kit-on-vm
kit_commit="$(vm_value kit)"
if [[ "$kit_commit" != "missing" && -n "$kit_commit" && "$(vm_value env)" == "yes" && "$(vm_value launcher)" == "yes" ]]; then
  check_pass "The kit is cloned in ~/${VM_COURSE_DIR} on the lab VM (commit ${kit_commit}), with your .env, and course is on the PATH."
else
  check_fail "The kit, its .env or the course command is missing on the lab VM." "Run: ./course up"
fi

check_summary
