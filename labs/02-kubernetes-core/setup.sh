#!/usr/bin/env bash
# Lab 02 setup. Creates a kind cluster (one control plane node, two workers) on the lab VM
# and loads the chapter 1 image into it. No Azure resource is created.
# Run it on the lab VM:
#   course start 02
# Safe to run again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"

IMAGE="sample-app:1.0.0"
WORK_DIR="${HOME}/work/02-kubernetes-core"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: course start 02"
  echo "Creates the kind cluster '${KIND_CLUSTER_NAME}' and loads ${IMAGE} into it."
  exit 0
fi

require_lab_vm
load_env
require_cmd docker "Run the readiness report from your own computer: ./course check"
require_cmd kind "Run the readiness report from your own computer: ./course check"
require_cmd kubectl "Run the readiness report from your own computer: ./course check"

if ! docker info >/dev/null 2>&1; then
  die "Docker does not answer. Disconnect and reconnect to the VM, then try again."
fi

step "Checking the chapter 1 image"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  die "No local image ${IMAGE}. Build it again as in chapter 1 (the lab VM keeps images until it is destroyed)."
fi
info "Found ${IMAGE}."

step "Creating the kind cluster '${KIND_CLUSTER_NAME}'"
info "Cost: nothing extra. The cluster runs inside the lab VM you already pay for."
if kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"; then
  info "The cluster already exists. Kept as it is."
else
  kind create cluster --config "${SCRIPT_DIR}/kind-cluster.yaml" --wait 180s
fi
kubectl config use-context "kind-${KIND_CLUSTER_NAME}" >/dev/null
kubectl wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
kubectl get nodes

step "Loading ${IMAGE} into the cluster nodes"
kind load docker-image "$IMAGE" --name "$KIND_CLUSTER_NAME"

mkdir -p "$WORK_DIR"

step "Done"
info "Setup took $(duration_text "$SECONDS")."
info "kubectl now talks to the cluster: context kind-${KIND_CLUSTER_NAME}."
info "Write your YAML files in ${WORK_DIR}."
info "Next: do the lab tasks of the chapter 2 page. The guided check follows you task by task:"
info "  course check 02 --guided"
info "At the end, the full report:"
info "  course check 02"
