#!/usr/bin/env bash
# Chapter 2 validation. Run it in the environment of the course:
#   course check 02            full report
#   course check 02 --guided   one stage at a time
# Read-only: it reads your YAML files and the cluster, and sends GET requests to the app.
# Only --deep changes anything: it deletes one pod, which Kubernetes replaces,
# and runs a temporary pod, which it removes.
# Exit code 0 when no check fails, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"
# shellcheck source=../../lib/lib-validate.sh
source "${SCRIPT_DIR}/../../lib/lib-validate.sh"

CHAPTER="02"
NS="sample-app"
APP="sample-app"
NAME_LABEL="app.kubernetes.io/name"
IMAGE_REPO="${REGISTRY_HOST}/${APP}"
FINAL_TAG="1.0.0"
V2_TAG="2.0.0"
REPLICAS=5
NODE_PORT=30080
WORK_DIR="${HOME}/work/02-kubernetes-core"
# Image of the temporary pod of the DNS live test. It only needs wget.
PROBE_IMAGE="busybox:1.37.0"
PROBE_POD="validate-probe-$$"

STAGE_TITLES=(
  "Create the namespace"
  "Create the Deployment"
  "Expose the pods with a Service"
  "Scale to ${REPLICAS} replicas"
  "Delete a pod and watch it come back"
  "Roll out version ${V2_TAG}"
  "Roll back and make your files match the cluster"
)
DEEP_NOTICE="they delete one pod of your Deployment to time its replacement, and run a temporary ${PROBE_IMAGE} pod that calls your Service by name, then remove it. Your files and the registry are not touched."

NODES_JSON=""
FILES_JSON="[]"
FILES_ERROR=""
BASELINE_PODS=""
EMPTY_OBJECT="{}"

k() {
  kubectl --context "kind-${KIND_CLUSTER_NAME}" "$@"
}

preflight() {
  require_cmd kubectl
  require_cmd docker
  require_cmd jq
  require_cmd curl
  require_cmd python3
  if ! python3 -c 'import yaml' 2>/dev/null; then
    die "The Python YAML module is missing. Install it with: sudo apt-get install --yes python3-yaml"
  fi

  require_lab_cluster "$CHAPTER"
  step "Cluster"
  local current_context ready_nodes control_planes
  current_context="$(kubectl config current-context 2>/dev/null || true)"
  if [[ "$current_context" == "kind-${KIND_CLUSTER_NAME}" ]]; then
    check_pass "kubectl points at kind-${KIND_CLUSTER_NAME}."
  else
    check_warn "kubectl points at '${current_context:-nothing}'. This validation reads kind-${KIND_CLUSTER_NAME} anyway." "Switch with: kubectl config use-context kind-${KIND_CLUSTER_NAME}"
  fi
  NODES_JSON="$(k get nodes -o json 2>/dev/null || true)"
  if [[ -z "$NODES_JSON" ]]; then
    die "The cluster of lab ${CHAPTER} is not running. Run: course start ${CHAPTER}"
  fi
  ready_nodes="$(jq '[.items[] | select(any(.status.conditions[]; .type == "Ready" and .status == "True"))] | length' <<<"$NODES_JSON")"
  control_planes="$(jq '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane"))] | length' <<<"$NODES_JSON")"
  if [[ "$ready_nodes" == "3" && "$control_planes" == "1" ]]; then
    check_pass "3 nodes are Ready: 1 control plane and 2 workers."
  else
    check_fail "${ready_nodes} Ready nodes and ${control_planes} control plane, expected 3 and 1." "Run course start 02, which starts the nodes that are stopped. If a node stays NotReady, course clean 02 then course start 02 creates the cluster again."
  fi
}

# ---------------------------------------------------------------------------
# What the checks read
# ---------------------------------------------------------------------------

# Reads every object described in the YAML files of the work folder into FILES_JSON.
# Each object gets a _file field with the name of its file. Returns 1 when there is
# no file or when a file is not valid YAML, with the reason in FILES_ERROR.
load_files() {
  local output
  FILES_JSON="[]"
  FILES_ERROR=""
  if ! compgen -G "${WORK_DIR}/*.yaml" >/dev/null && ! compgen -G "${WORK_DIR}/*.yml" >/dev/null; then
    FILES_ERROR="no-files"
    return 1
  fi
  if output="$(
    python3 - "$WORK_DIR" 2>&1 <<'PY'
import glob
import json
import os
import sys

import yaml

folder = sys.argv[1]
objects = []
for path in sorted(glob.glob(os.path.join(folder, "*.yaml")) + glob.glob(os.path.join(folder, "*.yml"))):
    name = os.path.basename(path)
    try:
        with open(path, encoding="utf-8") as handle:
            documents = list(yaml.safe_load_all(handle))
    except (yaml.YAMLError, UnicodeDecodeError) as error:
        print(f"{name}: {' '.join(str(error).split())}")
        sys.exit(3)
    for document in documents:
        if not isinstance(document, dict):
            continue
        items = document.get("items") if document.get("kind") == "List" else [document]
        for item in items or []:
            if isinstance(item, dict):
                item["_file"] = name
                objects.append(item)
json.dump(objects, sys.stdout, default=str)
PY
  )"; then
    FILES_JSON="$output"
    return 0
  fi
  FILES_ERROR="$output"
  return 1
}

# Prints the object of that kind and name from the files, or nothing.
file_object() {
  jq -c --arg kind "$1" --arg name "$2" '[.[] | select(.kind == $kind and .metadata.name == $name)][0] // empty' <<<"$FILES_JSON"
}

deployment_json() {
  k -n "$NS" get deployment "$APP" -o json 2>/dev/null || true
}

service_json() {
  k -n "$NS" get service "$APP" -o json 2>/dev/null || true
}

# Prints the ReplicaSets that belong to the Deployment given as JSON, as a JSON list.
owned_replicasets() {
  local uid
  uid="$(jq -r '.metadata.uid' <<<"$1")"
  k -n "$NS" get replicasets -o json 2>/dev/null |
    jq -c --arg uid "$uid" '[.items[] | select(any(.metadata.ownerReferences[]?; .uid == $uid))]' 2>/dev/null || echo '[]'
}

# Prints the names of the pods of the app that are ready and not being deleted, one per line.
ready_pods() {
  k -n "$NS" get pods -l "${NAME_LABEL}=${APP}" -o json 2>/dev/null |
    jq -r '.items[]
      | select(.metadata.deletionTimestamp == null)
      | select(any(.status.conditions[]?; .type == "Ready" and .status == "True"))
      | .metadata.name' 2>/dev/null | sort || true
}

node_address() {
  jq -r '[.items[] | select(.metadata.labels | has("node-role.kubernetes.io/control-plane"))][0].status.addresses[] | select(.type == "InternalIP") | .address' <<<"$NODES_JSON"
}

# ---------------------------------------------------------------------------
# Stage 1: the namespace
# ---------------------------------------------------------------------------

stage_1_task() {
  cat <<EOF
  In ${WORK_DIR}, describe a namespace called ${NS} in a YAML file,
  then create it with kubectl apply -f.
  Details: chapter 2 page, Lab, task 1.
EOF
}

stage_1() {
  if ! load_files; then
    if [[ "$FILES_ERROR" == "no-files" ]]; then
      check_fail "No YAML file in ${WORK_DIR}." "Write your files there, with the extension .yaml. Every object of this lab comes from a file."
    else
      check_fail "A file in ${WORK_DIR} is not valid YAML: ${FILES_ERROR}" "YAML is strict about indentation: use spaces, never tabs, and keep the same depth for keys of the same level."
    fi
  else
    check_pass "Your YAML files in ${WORK_DIR} describe $(count_of "$(jq 'length' <<<"$FILES_JSON")" object)."
    if [[ -n "$(file_object Namespace "$NS")" ]]; then
      check_pass "Your files describe the namespace ${NS}."
    else
      check_fail "No file describes a Namespace called ${NS}." "kubectl create namespace is an imperative command and leaves no file. Describe the namespace in a file, with kind: Namespace, and apply it."
    fi
  fi

  if k get namespace "$NS" >/dev/null 2>&1; then
    check_pass "The namespace ${NS} exists in the cluster."
  else
    check_fail "The namespace ${NS} does not exist in the cluster." "Apply your file: kubectl apply -f <file>."
  fi
}

# ---------------------------------------------------------------------------
# Stage 2: the Deployment
# ---------------------------------------------------------------------------

stage_2_task() {
  cat <<EOF
  In the namespace ${NS}, create a Deployment called ${APP} from a YAML file:
  - 3 replicas of the image ${IMAGE_REPO}:${FINAL_TAG}, from the registry of the course
  - pods labelled ${NAME_LABEL}: ${APP}, and the same label as the selector
  - container port 8080
  Apply it, then watch the pods start: kubectl -n ${NS} get pods --watch
  Stretch goal: a readiness probe on /healthz.
  Details: chapter 2 page, Lab, task 2.
EOF
}

stage_2() {
  local deployment described image tag spec_replicas ready_replicas
  load_files || true
  deployment="$(deployment_json)"
  if [[ -z "$deployment" ]]; then
    check_fail "Deployment ${APP} not found in ${NS}." "Describe it in a YAML file and apply it with kubectl apply -f."
    return 0
  fi
  check_pass "Deployment ${APP} exists in ${NS}."

  described="$(file_object Deployment "$APP")"
  if [[ -z "$described" ]]; then
    check_fail "No file in ${WORK_DIR} describes a Deployment called ${APP}." "kubectl create deployment leaves no file. Keep the Deployment in a YAML file and apply it."
  elif [[ "$(jq -r '.metadata.namespace // empty' <<<"$described")" == "$NS" ]]; then
    check_pass "Your file $(jq -r '._file' <<<"$described") describes the Deployment, in the namespace ${NS}."
  else
    check_warn "Your file $(jq -r '._file' <<<"$described") describes the Deployment without metadata.namespace: ${NS}." "Without it the file only works with -n ${NS} on every command, and lands in the default namespace when you forget."
  fi

  if jq -e '.metadata.annotations["kubectl.kubernetes.io/last-applied-configuration"]' <<<"$deployment" >/dev/null; then
    check_pass "The Deployment was created or updated with kubectl apply (declarative)."
  else
    check_warn "The Deployment has no trace of kubectl apply." "Keep the desired state in a YAML file and use kubectl apply -f, not kubectl create."
  fi

  if [[ "$(jq -r --arg k "$NAME_LABEL" '.spec.template.metadata.labels[$k] // empty' <<<"$deployment")" == "$APP" ]]; then
    check_pass "Pods are labelled ${NAME_LABEL}=${APP}."
  else
    check_fail "The pod template has no label ${NAME_LABEL}=${APP}." "Add it under spec.template.metadata.labels and in spec.selector.matchLabels."
  fi
  if [[ "$(jq -r --arg k "$NAME_LABEL" '.spec.selector.matchLabels[$k] // empty' <<<"$deployment")" == "$APP" ]]; then
    check_pass "The Deployment selects its pods with that label."
  else
    check_fail "The selector of the Deployment does not use ${NAME_LABEL}=${APP}." "A selector cannot be changed afterwards. Delete the Deployment, set spec.selector.matchLabels in your file, and apply it again."
  fi

  image="$(jq -r '.spec.template.spec.containers[0].image' <<<"$deployment")"
  tag="${image##*:}"
  if [[ "${image##*/}" != *:* || "$tag" == "latest" ]]; then
    check_fail "The Deployment runs ${image}, without a fixed tag." "With latest, or with no tag, you cannot tell which build runs. Name the version: ${IMAGE_REPO}:${FINAL_TAG}."
  elif [[ "${image%:*}" == "$IMAGE_REPO" && ("$tag" == "$FINAL_TAG" || "$tag" == "$V2_TAG") ]]; then
    check_pass "The Deployment runs ${image}, from the registry of the course, with a fixed tag."
  else
    check_fail "The Deployment runs ${image}, the lab uses ${IMAGE_REPO}:${FINAL_TAG}." "The nodes pull from the registry of the course, so the image name starts with ${REGISTRY_HOST}/. Set it in your file and apply it again."
  fi

  if [[ -n "$(jq -r '[.spec.template.spec.containers[0].ports[]?.containerPort] | index(8080) // empty' <<<"$deployment")" ]]; then
    check_pass "The container declares port 8080."
  else
    check_warn "The container does not declare containerPort 8080." "Declaring the port documents it and lets a Service refer to it by name."
  fi

  spec_replicas="$(jq -r '.spec.replicas' <<<"$deployment")"
  ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$deployment")"
  if [[ "$ready_replicas" == "$spec_replicas" ]] && ((spec_replicas > 0)); then
    check_pass "All ${spec_replicas} replicas are ready."
  else
    check_fail "${ready_replicas} of ${spec_replicas} replicas are ready." "Look at the pods: kubectl -n ${NS} get pods, then kubectl -n ${NS} describe pod <name>. Read the Events at the bottom."
  fi

  if jq -e '.spec.template.spec.containers[0].readinessProbe' <<<"$deployment" >/dev/null; then
    check_pass "Stretch goal: the container has a readiness probe."
  else
    check_note "Stretch goal not done: no readiness probe. It is optional, and chapter 3 covers probes."
  fi
}

# ---------------------------------------------------------------------------
# Stage 3: the Service
# ---------------------------------------------------------------------------

stage_3_task() {
  cat <<EOF
  Expose the pods with a Service called ${APP}, from a YAML file:
  type NodePort, port 80, sending traffic to port 8080 of the pods,
  node port ${NODE_PORT}, selecting the pods by their label.
  Then call the app several times from the environment, through a node address,
  and look at the host names in the answers:
    kubectl get nodes -o wide      then      curl http://<node address>:${NODE_PORT}/
  Details: chapter 2 page, Lab, task 3.
EOF
}

remove_probe_pod() {
  k -n "$NS" delete pod "$PROBE_POD" --ignore-not-found --wait=false >/dev/null 2>&1 || true
}

# Runs a temporary pod that calls the Service by its DNS name, then removes the pod.
live_test_dns() {
  local output status=0
  trap remove_probe_pod EXIT
  output="$(k -n "$NS" run "$PROBE_POD" --image="$PROBE_IMAGE" --restart=Never --rm --attach --quiet \
    --pod-running-timeout=90s --command -- wget -q -O - -T 5 "http://${APP}/healthz" 2>&1)" || status=$?
  remove_probe_pod
  trap - EXIT
  if ((status == 0)) && [[ "$output" == *ok* ]]; then
    check_pass "Live test: from a temporary pod, the name ${APP} resolves through the cluster DNS and port 80 of the Service answers."
  elif [[ "$output" == *wget:* ]]; then
    check_fail "Live test: a temporary pod could not call http://${APP}/healthz ($(grep -m 1 'wget:' <<<"$output"))." "Inside the cluster, clients use the Service name and its port (80), not the node port. Check spec.ports[0].port and the selector."
  else
    check_warn "Live test: the temporary pod did not run, so the Service name was not tested." "The nodes may not reach Docker Hub to pull ${PROBE_IMAGE}. Message: $(head -n 1 <<<"$output")"
  fi
}

stage_3() {
  local service deployment described selector labels ready_endpoints wanted node_ip health_code answer answer_version index names distinct
  load_files || true
  service="$(service_json)"
  if [[ -z "$service" ]]; then
    check_fail "Service ${APP} not found in ${NS}." "Describe it in a YAML file and apply it."
    return 0
  fi
  check_pass "Service ${APP} exists in ${NS}."

  described="$(file_object Service "$APP")"
  if [[ -n "$described" ]]; then
    check_pass "Your file $(jq -r '._file' <<<"$described") describes the Service."
  else
    check_fail "No file in ${WORK_DIR} describes a Service called ${APP}." "kubectl expose leaves no file. Keep the Service in a YAML file and apply it."
  fi

  if [[ "$(jq -r '.spec.type' <<<"$service")" == "NodePort" ]]; then
    check_pass "The Service is of type NodePort."
  else
    check_fail "The Service is of type $(jq -r '.spec.type' <<<"$service"), expected NodePort." "Set spec.type: NodePort."
  fi
  if [[ "$(jq -r '.spec.ports[0].port' <<<"$service")" == "80" ]]; then
    check_pass "The Service listens on port 80."
  else
    check_fail "The Service listens on port $(jq -r '.spec.ports[0].port' <<<"$service"), expected 80." "Set spec.ports[0].port: 80."
  fi

  deployment="$(deployment_json)"
  local target port_name=""
  target="$(jq -r '.spec.ports[0].targetPort' <<<"$service")"
  if [[ -n "$deployment" ]]; then
    port_name="$(jq -r '[.spec.template.spec.containers[0].ports[]? | select(.containerPort == 8080) | .name // empty][0] // empty' <<<"$deployment")"
  fi
  if [[ "$target" == "8080" || (-n "$port_name" && "$target" == "$port_name") ]]; then
    check_pass "The Service sends traffic to container port ${target}."
  else
    check_fail "The Service targets port ${target}, the app listens on 8080." "Set spec.ports[0].targetPort: 8080."
  fi
  if [[ "$(jq -r '.spec.ports[0].nodePort // empty' <<<"$service")" == "$NODE_PORT" ]]; then
    check_pass "The Service uses node port ${NODE_PORT}."
  else
    check_fail "The Service node port is $(jq -r '.spec.ports[0].nodePort // "not set"' <<<"$service"), expected ${NODE_PORT}." "Set spec.ports[0].nodePort: ${NODE_PORT}."
  fi

  selector="$(jq -c '.spec.selector // {}' <<<"$service")"
  labels="$(jq -c '.spec.template.metadata.labels // {}' <<<"${deployment:-$EMPTY_OBJECT}")"
  if [[ "$(jq -r --arg k "$NAME_LABEL" '.[$k] // empty' <<<"$selector")" != "$APP" ]]; then
    check_fail "The Service selector does not use ${NAME_LABEL}=${APP}." "Set spec.selector to the label of the pods."
  elif jq -n -e --argjson s "$selector" --argjson l "$labels" '$s | to_entries | all(.value == $l[.key])' >/dev/null; then
    check_pass "The Service selector ($(jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")' <<<"$selector")) matches the labels of the pods."
  else
    check_fail "The Service selector ($(jq -r 'to_entries | map("\(.key)=\(.value)") | join(", ")' <<<"$selector")) asks for a label the pods do not have." "Every key and value of the selector must be on the pods. Compare with: kubectl -n ${NS} get pods --show-labels"
  fi

  ready_endpoints="$(k -n "$NS" get endpointslices -l "kubernetes.io/service-name=${APP}" -o json 2>/dev/null |
    jq '[.items[].endpoints[]? | select(.conditions.ready == true)] | length' 2>/dev/null || echo 0)"
  wanted="$(jq -r '.spec.replicas // 0' <<<"${deployment:-$EMPTY_OBJECT}")"
  if ((ready_endpoints > 0)) && [[ "$ready_endpoints" == "$wanted" ]]; then
    check_pass "The Service has ${ready_endpoints} ready endpoints, one per pod."
  else
    check_fail "The Service has ${ready_endpoints} ready endpoints, expected ${wanted}." "An endpoint is a ready pod that the selector matches. Look at: kubectl -n ${NS} get endpointslices"
    return 0
  fi

  node_ip="$(node_address)"
  health_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://${node_ip}:${NODE_PORT}/healthz" || true)"
  if [[ "$health_code" != "200" ]]; then
    check_fail "GET /healthz through node port ${NODE_PORT} answers ${health_code/#000/nothing (no connection)}." "Check the ports of the Service: port, targetPort and nodePort."
    return 0
  fi
  check_pass "GET /healthz through node port ${NODE_PORT} answers 200."

  names=""
  for ((index = 0; index < 20; index++)); do
    answer="$(curl -s --max-time 5 "http://${node_ip}:${NODE_PORT}/" || true)"
    names="${names}$(jq -r '.hostname // empty' <<<"$answer" 2>/dev/null || true)"$'\n'
  done
  answer_version="$(jq -r '.version // empty' <<<"$answer" 2>/dev/null || true)"
  distinct="$(grep -c . <<<"$(sort -u <<<"$names")" || true)"
  if [[ -z "$answer_version" ]]; then
    check_fail "GET / through the Service does not return the JSON answer of the app." "Call it yourself: curl http://${node_ip}:${NODE_PORT}/"
  elif ((distinct >= 2)); then
    check_pass "20 requests through the Service were answered by ${distinct} different pods (version ${answer_version})."
  elif ((wanted >= 2)); then
    check_warn "20 requests through the Service were all answered by the same pod." "A Service spreads connections over its ready endpoints. Check that every pod is ready."
  else
    check_pass "GET / through the Service answers with version ${answer_version}."
  fi

  if live_test_ready "a temporary pod that calls the Service by its DNS name."; then
    live_test_dns
  fi
}

# ---------------------------------------------------------------------------
# Stage 4: scaling
# ---------------------------------------------------------------------------

stage_4_task() {
  cat <<EOF
  Scale the Deployment to ${REPLICAS} replicas by changing your YAML file and applying it.
  Do not use kubectl scale: the file must stay the description of what runs.
  Details: chapter 2 page, Lab, task 4.
EOF
}

stage_4() {
  local deployment described spec_replicas ready_replicas file_replicas
  load_files || true
  deployment="$(deployment_json)"
  if [[ -z "$deployment" ]]; then
    check_fail "Deployment ${APP} not found in ${NS}." "Do stage 2 first."
    return 0
  fi
  spec_replicas="$(jq -r '.spec.replicas' <<<"$deployment")"
  ready_replicas="$(jq -r '.status.readyReplicas // 0' <<<"$deployment")"
  if [[ "$spec_replicas" == "$REPLICAS" ]]; then
    check_pass "The Deployment asks for ${REPLICAS} replicas."
  else
    check_fail "The Deployment asks for ${spec_replicas} replicas, expected ${REPLICAS}." "Set spec.replicas: ${REPLICAS} in your file and apply it again."
  fi
  if [[ "$ready_replicas" == "$REPLICAS" ]]; then
    check_pass "${ready_replicas} replicas are ready."
  else
    check_fail "${ready_replicas} replicas are ready, expected ${REPLICAS}." "Look at the pods: kubectl -n ${NS} get pods, then kubectl -n ${NS} describe pod <name>."
  fi

  described="$(file_object Deployment "$APP")"
  if [[ -n "$described" ]]; then
    file_replicas="$(jq -r '.spec.replicas // 1' <<<"$described")"
    if [[ "$file_replicas" == "$REPLICAS" ]]; then
      check_pass "Your file asks for ${REPLICAS} replicas too."
    else
      check_fail "Your file asks for ${file_replicas} replicas and the cluster runs ${spec_replicas}." "A change made with kubectl scale is not in the file, so the next kubectl apply undoes it. Change spec.replicas in the file and apply it."
    fi
  fi
}

# ---------------------------------------------------------------------------
# Stage 5: self-healing
# ---------------------------------------------------------------------------

stage_5_task() {
  cat <<EOF
  List the pods and note their names. Delete one pod. List the pods again:
  which name is gone, which one is new, and which controller created it?
    kubectl -n ${NS} get pods
    kubectl -n ${NS} delete pod <name>
  The guided check watches the pods while this stage is open, so delete a pod
  now, even if you already did it earlier.
  Details: chapter 2 page, Lab, task 5.
EOF
}

# Guided mode: notes which pods exist when the stage opens.
stage_5_enter() {
  BASELINE_PODS="$(ready_pods)"
}

# Deletes one pod and waits for the ReplicaSet to bring the count back.
live_test_self_healing() {
  local wanted="$1" before victim started now new waited
  before="$(ready_pods)"
  victim="$(head -n 1 <<<"$before")"
  started="$SECONDS"
  if ! k -n "$NS" delete pod "$victim" --wait=false >/dev/null 2>&1; then
    check_fail "Live test: could not delete the pod ${victim}." "Try it yourself: kubectl -n ${NS} delete pod ${victim}"
    return 0
  fi
  while ((SECONDS - started < 60)); do
    now="$(ready_pods)"
    if [[ "$(grep -c . <<<"$now" || true)" == "$wanted" ]] && ! grep -qx "$victim" <<<"$now"; then
      waited=$((SECONDS - started))
      new="$(comm -13 <(printf '%s\n' "$before") <(printf '%s\n' "$now") | tr '\n' ' ')"
      check_pass "Live test: deleted the pod ${victim}. The ReplicaSet created ${new% } and ${wanted} pods were ready again after ${waited} s."
      return 0
    fi
    sleep 2
  done
  check_fail "Live test: 60 s after the pod ${victim} was deleted, ${wanted} ready pods are not back." "Look at the new pod: kubectl -n ${NS} get pods, then kubectl -n ${NS} describe pod <name>."
}

stage_5() {
  local deployment wanted pods_json total orphans owners now gone new rollouts
  deployment="$(deployment_json)"
  if [[ -z "$deployment" ]]; then
    check_fail "Deployment ${APP} not found in ${NS}." "Do stage 2 first."
    return 0
  fi
  wanted="$(jq -r '.spec.replicas' <<<"$deployment")"
  pods_json="$(k -n "$NS" get pods -l "${NAME_LABEL}=${APP}" -o json 2>/dev/null || echo '{"items":[]}')"
  total="$(jq '[.items[] | select(.metadata.deletionTimestamp == null)] | length' <<<"$pods_json")"
  orphans="$(jq '[.items[] | select(.metadata.deletionTimestamp == null) | select(any(.metadata.ownerReferences[]?; .kind == "ReplicaSet") | not)] | length' <<<"$pods_json")"
  owners="$(jq -r '[.items[] | select(.metadata.deletionTimestamp == null) | .metadata.ownerReferences[]? | select(.kind == "ReplicaSet") | .name] | unique | join(", ")' <<<"$pods_json")"
  if ((total == 0)); then
    check_fail "No pod carries the label ${NAME_LABEL}=${APP}." "Do stage 2 first."
    return 0
  fi
  if [[ "$(grep -c . <<<"$(ready_pods)" || true)" != "$wanted" && -z "$BASELINE_PODS" ]]; then
    check_fail "The Deployment does not have its ${wanted} pods ready, so this is not the moment to delete one." "Fix the earlier stages first: kubectl -n ${NS} get pods"
    return 0
  fi
  if ((orphans == 0)); then
    check_pass "All ${total} pods belong to a ReplicaSet (${owners}), which replaces any pod that disappears."
  else
    check_warn "$(count_of "$orphans" pod) with the label of the app belong to no ReplicaSet." "A pod created by hand, with kubectl run, is not replaced when it disappears. Delete it."
  fi

  if [[ -n "$BASELINE_PODS" ]]; then
    now="$(ready_pods)"
    gone="$(comm -23 <(printf '%s\n' "$BASELINE_PODS") <(printf '%s\n' "$now") | tr '\n' ' ')"
    new="$(comm -13 <(printf '%s\n' "$BASELINE_PODS") <(printf '%s\n' "$now") | tr '\n' ' ')"
    rollouts="$(jq 'length' <<<"$(owned_replicasets "$deployment")")"
    if [[ -n "${gone// /}" && -n "${new// /}" && "$(grep -c . <<<"$now" || true)" == "$wanted" ]]; then
      check_pass "While this stage was open, ${gone% } disappeared and ${new% } took over. ${wanted} pods are ready."
    elif [[ -n "${gone// /}" ]]; then
      check_fail "The pod ${gone% } is gone and its replacement is not ready yet." "Wait a few seconds, then check again."
    elif ((rollouts >= 2)); then
      check_skip "Not checked: the rollout of stage 6 has replaced every pod since, so nothing shows whether you deleted one."
    else
      check_fail "No pod has been replaced since this stage was opened." "In a second terminal, delete one pod and list the pods again. Then check again here."
    fi
    return 0
  fi

  if live_test_ready "one pod deleted, and its replacement timed. A report cannot tell whether you deleted a pod earlier: --guided checks it while you do it."; then
    live_test_self_healing "$wanted"
  fi
}

# ---------------------------------------------------------------------------
# Stage 6: rollout
# ---------------------------------------------------------------------------

stage_6_task() {
  cat <<EOF
  Build ${APP}:${V2_TAG} from your chapter 1 Dockerfile, with the version set to ${V2_TAG},
  and push it as ${IMAGE_REPO}:${V2_TAG}. Then change the image in your Deployment file and apply it.
  Watch the rollout, and call the app while it runs:
    kubectl -n ${NS} rollout status deployment/${APP}
    kubectl -n ${NS} get replicasets
  Details: chapter 2 page, Lab, task 6.
EOF
}

stage_6() {
  local deployment replicasets count wanted updated ready current
  if docker image inspect "${APP}:${V2_TAG}" >/dev/null 2>&1; then
    check_pass "The image ${APP}:${V2_TAG} exists in Docker."
  else
    check_fail "No local image named ${APP}:${V2_TAG}." "Build it as in chapter 1, with the version and the tag set to ${V2_TAG}."
  fi

  if registry_has_tag "$APP" "$V2_TAG"; then
    check_pass "The registry holds ${IMAGE_REPO}:${V2_TAG}."
  else
    check_fail "The registry does not hold ${IMAGE_REPO}:${V2_TAG}." "The nodes only see what the registry holds. Tag the image ${IMAGE_REPO}:${V2_TAG} and push it."
  fi

  deployment="$(deployment_json)"
  if [[ -z "$deployment" ]]; then
    check_fail "Deployment ${APP} not found in ${NS}." "Do stage 2 first."
    return 0
  fi
  replicasets="$(owned_replicasets "$deployment")"
  count="$(jq 'length' <<<"$replicasets")"
  if jq -e --arg tag ":${V2_TAG}" 'any(.[]; .spec.template.spec.containers[0].image | endswith($tag))' <<<"$replicasets" >/dev/null; then
    check_pass "Version ${V2_TAG} was rolled out: one of the ${count} ReplicaSets of the Deployment runs or ran that image."
  else
    check_fail "No ReplicaSet of the Deployment ever ran version ${V2_TAG}." "Change the image in your Deployment file to ${IMAGE_REPO}:${V2_TAG} and apply it."
  fi

  wanted="$(jq -r '.spec.replicas' <<<"$deployment")"
  updated="$(jq -r '.status.updatedReplicas // 0' <<<"$deployment")"
  ready="$(jq -r '.status.readyReplicas // 0' <<<"$deployment")"
  current="$(jq -r '.status.replicas // 0' <<<"$deployment")"
  if [[ "$updated" == "$wanted" && "$ready" == "$wanted" && "$current" == "$wanted" ]]; then
    check_pass "No rollout is in progress: all ${wanted} pods run the current version and are ready."
  else
    check_fail "A rollout is in progress or stuck: ${updated} of ${wanted} pods updated, ${ready} ready, ${current} in total." "Follow it with: kubectl -n ${NS} rollout status deployment/${APP}. ErrImagePull on the new pods means the registry does not hold that image."
  fi
}

# ---------------------------------------------------------------------------
# Stage 7: rollback, and files that match the cluster
# ---------------------------------------------------------------------------

stage_7_task() {
  cat <<EOF
  Roll back to the previous revision with kubectl rollout undo, and check which
  version the app reports. Then make your files describe what runs again:
  this command prints what kubectl apply would change, and changes nothing.
    kubectl -n ${NS} diff -f ${WORK_DIR}
  Edit your files until it prints nothing.
  Details: chapter 2 page, Lab, task 7.
EOF
}

stage_7() {
  local deployment image revision node_ip answer_version described file_image file_replicas output status=0 changed line
  deployment="$(deployment_json)"
  if [[ -z "$deployment" ]]; then
    check_fail "Deployment ${APP} not found in ${NS}." "Do stage 2 first."
    return 0
  fi
  image="$(jq -r '.spec.template.spec.containers[0].image' <<<"$deployment")"
  if [[ "$image" == *":${FINAL_TAG}" ]]; then
    check_pass "The Deployment runs ${image}."
  else
    check_fail "The Deployment runs ${image}, expected the ${FINAL_TAG} image after the rollback." "Roll back with: kubectl -n ${NS} rollout undo deployment/${APP}"
  fi
  revision="$(jq -r '.metadata.annotations["deployment.kubernetes.io/revision"] // "0"' <<<"$deployment")"
  if ((revision >= 3)); then
    check_pass "The Deployment is at revision ${revision}: a rollout, then a return to ${FINAL_TAG}."
  else
    check_warn "The Deployment is at revision ${revision}." "The first version is revision 1, the rollout of ${V2_TAG} is revision 2, and the rollback creates revision 3."
  fi

  node_ip="$(node_address)"
  answer_version="$(curl -s --max-time 5 "http://${node_ip}:${NODE_PORT}/" | jq -r '.version // empty' 2>/dev/null || true)"
  if [[ "$answer_version" == "$FINAL_TAG" ]]; then
    check_pass "GET / through the Service reports version ${FINAL_TAG}."
  else
    check_fail "GET / through the Service reports version '${answer_version:-nothing}', expected ${FINAL_TAG}." "Finish the rollback and wait for the pods to be ready."
  fi

  if ! load_files; then
    check_fail "Your YAML files cannot be compared with the cluster." "Stage 1 says what is wrong with the files in ${WORK_DIR}."
    return 0
  fi
  output="$(k -n "$NS" diff -f "$WORK_DIR" 2>&1)" || status=$?
  if ((status == 0)); then
    check_pass "Your files match the cluster: kubectl apply would change nothing."
    return 0
  fi
  if ((status > 1)); then
    check_fail "kubectl diff could not compare your files with the cluster: $(head -n 1 <<<"$output")" "Run it yourself: kubectl -n ${NS} diff -f ${WORK_DIR}"
    return 0
  fi
  check_fail "Your files do not match the cluster: kubectl apply would change it." "After kubectl rollout undo, the file still names the version you rolled back from. Edit the files until this prints nothing: kubectl -n ${NS} diff -f ${WORK_DIR}"
  described="$(file_object Deployment "$APP")"
  if [[ -n "$described" ]]; then
    file_image="$(jq -r '.spec.template.spec.containers[0].image // empty' <<<"$described")"
    file_replicas="$(jq -r '.spec.replicas // 1' <<<"$described")"
    if [[ "$file_image" != "$image" ]]; then
      check_note "image: your file says ${file_image}, the cluster runs ${image}."
    fi
    if [[ "$file_replicas" != "$(jq -r '.spec.replicas' <<<"$deployment")" ]]; then
      check_note "replicas: your file says ${file_replicas}, the cluster runs $(jq -r '.spec.replicas' <<<"$deployment")."
    fi
  fi
  changed="$(grep -E '^[+-][^+-]' <<<"$output" | grep -v -E 'generation:|resourceVersion:' | head -n 6 || true)"
  if [[ -n "$changed" ]]; then
    check_note "First lines of the difference (- is the cluster, + is your files):"
    while IFS= read -r line; do
      check_note "  ${line}"
    done <<<"$changed"
  fi
}

run_validation "$@"
