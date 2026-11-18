#!/usr/bin/env bash
# Lab 02 setup. Creates the kind cluster of the lab (one control plane node, two workers), whose nodes pull
# from the local registry. On return, it brings the cluster back: it starts the node containers that are
# stopped and waits for the nodes, with everything you applied kept.
#   course start 02 [--yes]
# Safe to run again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"

LAB="02"
IMAGE_REPO="sample-app"
IMAGE_TAG="1.0.0"
WORK_DIR="${HOME}/work/02-kubernetes-core"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "Usage: course start 02 [--yes]"
      echo "Creates the kind cluster '${KIND_CLUSTER_NAME}', or brings it back after a stop."
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

require_environment
require_docker
require_cmd kind
require_cmd kubectl

step "Registry"
require_registry
if ! registry_has_tag "$IMAGE_REPO" "$IMAGE_TAG"; then
  die "The registry ${REGISTRY_HOST} does not hold ${IMAGE_REPO}:${IMAGE_TAG}, your image of chapter 1. Finish lab 1, whose last task pushes it, or copy the solution of lab 1 with course solution 01 and do its build and push tasks. Then run course start 02 again."
fi
info "The registry holds ${REGISTRY_HOST}/${IMAGE_REPO}:${IMAGE_TAG}, your image of chapter 1."

lab_cluster_up "$LAB" "${SCRIPT_DIR}/kind-cluster.yaml"
mkdir -p "$WORK_DIR"

step "Done"
info "This took $(duration_text "$SECONDS")."
info "kubectl talks to the cluster: context ${KUBE_CONTEXT}. Write your YAML files in ${WORK_DIR}."
bash "${SCRIPT_DIR}/validate.sh" --next || true
