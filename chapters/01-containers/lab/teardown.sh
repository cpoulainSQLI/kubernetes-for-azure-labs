#!/usr/bin/env bash
# Chapter 1 teardown. Removes the sample-app container and deletes the chapter registry.
# Run it on the lab VM after validate.sh passes:
#   ~/aro-k8s-course/chapters/01-containers/lab/teardown.sh [--yes]
# Keeps your local images, which chapter 2 needs. Safe to run twice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/lib.sh
source "${SCRIPT_DIR}/../../../scripts/lib.sh"

CHAPTER="01"
CONTAINER="sample-app"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "Usage: chapters/01-containers/lab/teardown.sh [--yes]"
      echo "Removes the ${CONTAINER} container and deletes the chapter 1 registry. Local images are kept."
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

require_lab_vm
load_env
require_cmd docker
require_cmd az

if ! confirm "Remove the ${CONTAINER} container and delete the chapter 1 registry?"; then
  info "Nothing changed."
  exit 0
fi

step "Removing the ${CONTAINER} container"
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  docker container rm --force "$CONTAINER" >/dev/null
  info "Container removed. The images stay on the VM for chapter 2."
else
  info "No container named ${CONTAINER}."
fi

step "Deleting the chapter 1 registry"
ensure_vm_identity_login
destroyed="false"
if command -v terraform >/dev/null 2>&1; then
  sub_id="$(az account show --query id --output tsv)"
  tenant_id="$(az account show --query tenantId --output tsv)"
  infra_dir="${SCRIPT_DIR}/infra"
  terraform_env "01-containers" "$sub_id"
  export ARM_USE_MSI=true ARM_TENANT_ID="$tenant_id"
  lab_rg="$(rg_name)"
  export TF_VAR_prefix="$PREFIX" TF_VAR_resource_group_name="$lab_rg" TF_VAR_chapter="$CHAPTER"
  if terraform_init "$infra_dir" "$(state_account_name "$sub_id")" "01-containers.tfstate" &&
    terraform_in "$infra_dir" destroy -auto-approve; then
    destroyed="true"
    info "Terraform deleted what chapter 1 setup created."
  fi
fi
if [[ "$destroyed" != "true" ]]; then
  info "Terraform could not do it. Deleting every registry tagged for chapter 1 with the Azure CLI."
  registry_names="$(az acr list --resource-group "$(rg_name)" \
    --query "[?tags.course=='${COURSE_TAG_VALUE}' && tags.chapter=='${CHAPTER}'].name" --output tsv 2>/dev/null || true)"
  if [[ -z "$registry_names" ]]; then
    info "No chapter 1 registry found."
  else
    while IFS= read -r name; do
      az acr delete --name "$name" --yes --output none
      info "Deleted registry ${name}."
    done <<<"$registry_names"
  fi
fi

list_course_resources
info "The lab VM is still running. From your own computer, stop it with: scripts/lab-vm.sh stop (or .\\scripts\\lab-vm.ps1 stop in PowerShell)"
