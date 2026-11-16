#!/usr/bin/env bash
# Chapter 2 broken lab. Run it on the lab VM, once validate.sh passes:
#   ~/aro-k8s-course/chapters/02-kubernetes-core/lab/break.sh
# It changes one object in the sample-app namespace of your kind cluster.
# You find the cause, check it with --diagnose, repair it, and validate.sh confirms.
# It never touches your YAML files or Azure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/lib.sh
source "${SCRIPT_DIR}/../../../scripts/lib.sh"
# shellcheck source=../../../scripts/lib-break.sh
source "${SCRIPT_DIR}/../../../scripts/lib-break.sh"

CHAPTER="02"
BREAK_DIR="02-kubernetes-core"
WORK_DIR="${HOME}/work/02-kubernetes-core"
NS="sample-app"
APP="sample-app"
NODE_PORT=30080
BREAK_CHECK="validate.sh"
BREAK_NOTICE="It changes one object in the ${NS} namespace of your kind cluster with a kubectl command. Your YAML files and Azure are not touched."

SCENARIOS=(selector targetport replicas image)
CAUSES=(
  "The selector of the Service no longer matches the labels of the pods."
  "The Service sends traffic to a port where the app does not listen."
  "The Deployment asks for 0 replicas."
  "The Deployment asks for an image that is not on the nodes."
  "A node of the cluster is not Ready."
  "The namespace ${NS} was deleted."
)

k() {
  kubectl --context "kind-${KIND_CLUSTER_NAME}" -n "$NS" "$@"
}

lab_is_finished() {
  "${SCRIPT_DIR}/validate.sh" >/dev/null 2>&1
}

restore_lab() {
  k apply -f "$WORK_DIR" >/dev/null
  k rollout status "deployment/${APP}" --timeout=120s >/dev/null || true
  info "Your files were applied again: they describe the lab as it was."
}

no_answer() {
  info "A user reports: the app no longer answers on node port ${NODE_PORT}."
}
stuck_rollout() {
  info "A colleague says: I rolled out a new version ten minutes ago, and the app still reports the old one."
}

symptom_selector() { no_answer; }
inject_selector() {
  k patch service "$APP" --type merge --patch '{"spec":{"selector":{"app.kubernetes.io/name":"sample-ap"}}}' >/dev/null
}
explain_selector() {
  info "kubectl -n ${NS} get endpointslices shows no address, and kubectl -n ${NS} describe service ${APP} shows a selector that no pod carries: sample-ap, without the last letter."
  info "kubectl -n ${NS} diff -f ${WORK_DIR} shows the changed line, and kubectl apply -f on your files puts it back."
}

symptom_targetport() { no_answer; }
inject_targetport() {
  k patch service "$APP" --type json --patch '[{"op":"replace","path":"/spec/ports/0/targetPort","value":8081}]' >/dev/null
}
explain_targetport() {
  info "The Service still has its endpoints, but kubectl -n ${NS} describe service ${APP} shows TargetPort 8081, and the app listens on 8080."
  info "kubectl -n ${NS} diff -f ${WORK_DIR} shows the changed line, and kubectl apply -f on your files puts it back."
}

symptom_replicas() { no_answer; }
inject_replicas() {
  k scale "deployment/${APP}" --replicas=0 >/dev/null
}
explain_replicas() {
  info "kubectl -n ${NS} get pods shows no pod, and kubectl -n ${NS} get deployment ${APP} shows 0/0: someone scaled it with a command."
  info "Your file still says 5, so kubectl apply -f on it brings the pods back. This is why changes go through the files."
}

symptom_image() { stuck_rollout; }
inject_image() {
  k set image "deployment/${APP}" "*=${APP}:3.0.0" >/dev/null
}
explain_image() {
  info "kubectl -n ${NS} get pods shows new pods in ErrImagePull or ImagePullBackOff, and kubectl -n ${NS} describe pod on one of them names the image ${APP}:3.0.0, which was never loaded into the nodes."
  info "The old pods keep serving, because a rollout waits for the new ones. kubectl -n ${NS} rollout undo deployment/${APP}, or kubectl apply -f on your files, goes back to the image that exists."
}

run_break "$@"
