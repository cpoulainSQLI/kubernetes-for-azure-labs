#!/usr/bin/env bash
# Chapter 2 teardown. Deletes the kind cluster of the lab.
#   course clean 02 [--yes]
# Keeps your YAML files, your images and the registry. Safe to run twice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "Usage: course clean 02 [--yes]"
      echo "Deletes the kind cluster '${KIND_CLUSTER_NAME}'. Your YAML files, your images and the registry are kept."
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

require_environment
require_cmd kind

if ! confirm "Delete the kind cluster '${KIND_CLUSTER_NAME}' of lab 02?"; then
  info "Nothing changed."
  exit 0
fi

step "Deleting the kind cluster"
owner="$(cluster_lab)"
if cluster_exists && [[ -n "$owner" && "$owner" != "02" ]]; then
  info "The cluster ${KIND_CLUSTER_NAME} belongs to lab ${owner}, so it is kept. course clean ${owner} deletes it."
  exit 0
elif cluster_exists; then
  kind delete cluster --name "$KIND_CLUSTER_NAME"
else
  info "No cluster named ${KIND_CLUSTER_NAME}."
fi
forget_cluster_lab
info "Kept: your files in ~/work/02-kubernetes-core, your images, and the registry ${REGISTRY_HOST}."
