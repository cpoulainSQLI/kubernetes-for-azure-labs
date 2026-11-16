#!/usr/bin/env bash
# Chapter 2 teardown. Deletes the kind cluster on the lab VM. No Azure resource is involved.
# Run it on the lab VM after course check 02 passes:
#   course clean 02 [--yes]
# Keeps your YAML files and the local images. Safe to run twice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "Usage: course clean 02 [--yes]"
      echo "Deletes the kind cluster '${KIND_CLUSTER_NAME}'. Your YAML files and images are kept."
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

require_lab_vm
load_env
require_cmd kind

if ! confirm "Delete the kind cluster '${KIND_CLUSTER_NAME}'?"; then
  info "Nothing changed."
  exit 0
fi

step "Deleting the kind cluster"
if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  info "No cluster named ${KIND_CLUSTER_NAME}."
fi

if az_signed_in; then
  list_course_resources
else
  info "The Azure CLI is not signed in on the VM, so the list of course resources was skipped."
  info "From your own computer, run the readiness report: ./course check"
fi
info "The lab VM is still running. From your own computer, stop it with: ./course stop (.\\course.ps1 stop in PowerShell)"
