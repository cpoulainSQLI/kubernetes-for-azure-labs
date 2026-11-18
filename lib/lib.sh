#!/usr/bin/env bash
# Shared helpers for the course command and every lab script of the kit.
# Source this file from a script. Do not run it on its own.
# shellcheck disable=SC2034  # Variables defined here are used by the scripts that source this file.

if [[ -n "${KIT_LIB_LOADED:-}" ]]; then
  return 0
fi
KIT_LIB_LOADED=1

# Every name of the environment derives from the name of the kit: the WSL distribution, the clone in it,
# the kind cluster, its kubectl context, the registry and its volume. lib.ps1 uses the same names.
KIT_NAME="kubernetes-labs"
COURSE_NAME="Containers and Kubernetes"
COURSE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The course's own WSL distribution carries this marker. cloud-init writes it (setup/cloud-init.yaml).
# A Linux machine of your own never gets it.
ENV_MARKER="/etc/${KIT_NAME}/environment"
TOOLS_READY="/etc/${KIT_NAME}/tools-ready"

KIND_CLUSTER_NAME="$KIT_NAME"
KUBE_CONTEXT="kind-${KIT_NAME}"
REGISTRY_NAME="${KIT_NAME}-registry"
REGISTRY_VOLUME="${KIT_NAME}-registry"
# The registry port is fixed: manifests name localhost:5001, as the kind documentation does.
REGISTRY_PORT="5001"
REGISTRY_HOST="localhost:${REGISTRY_PORT}"
REGISTRY_IMAGE="registry:3"
# What the course command remembers between runs: which lab the cluster belongs to.
STATE_DIR="${XDG_STATE_HOME:-${HOME}/.local/state}/${KIT_NAME}"
CLUSTER_LAB_FILE="${STATE_DIR}/cluster-lab"
# The launcher that ./course up offers to put on the PATH of a Linux machine. Its second line names its kit.
LAUNCHER_FILE="${HOME}/.local/bin/course"
LAUNCHER_TAG="# course launcher of the kit"

# Tool versions. setup/install-tools.sh installs them, and the readiness report checks them.
# Keep them in line with setup/install-tools.sh, lib/lib.ps1 and labs/02-kubernetes-core/kind-cluster.yaml.
# Docker Engine is not pinned: the readiness report prints its version.
PINNED_KIND_VERSION="v0.33.0"
PINNED_KUBECTL_MINOR="v1.37"

if [[ -t 1 ]]; then
  C_GREEN=$'\033[32m'
  C_RED=$'\033[31m'
  C_YELLOW=$'\033[33m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_GREEN=""
  C_RED=""
  C_YELLOW=""
  C_BOLD=""
  C_RESET=""
fi

PASS_COUNT=0
FAIL_COUNT=0
WARN_COUNT=0
SKIP_COUNT=0

# The guided validation of a lab (lib/lib-validate.sh) collects the check
# lines of a stage before it shows them. Everywhere else they print at once.
CHECK_BUFFERING=0
CHECK_BUFFER=""

# ---------------------------------------------------------------------------
# Output
# ---------------------------------------------------------------------------

info() {
  printf '%s\n' "$*"
}

step() {
  printf '\n%s==> %s%s\n' "$C_BOLD" "$*" "$C_RESET"
}

die() {
  printf '%sERROR%s %s\n' "$C_RED" "$C_RESET" "$*" >&2
  exit 1
}

# Prints one line of a validation report, or keeps it for later when buffering is on.
check_line() {
  if [[ "$CHECK_BUFFERING" == "1" ]]; then
    CHECK_BUFFER="${CHECK_BUFFER}${1}"$'\n'
  else
    printf '%s\n' "$1"
  fi
}

check_pass() {
  PASS_COUNT=$((PASS_COUNT + 1))
  check_line "${C_GREEN}[PASS]${C_RESET} $1"
}

check_fail() {
  FAIL_COUNT=$((FAIL_COUNT + 1))
  check_line "${C_RED}[FAIL]${C_RESET} $1"
  if [[ -n "${2:-}" ]]; then
    check_line "       hint: $2"
  fi
  return 0
}

check_warn() {
  WARN_COUNT=$((WARN_COUNT + 1))
  check_line "${C_YELLOW}[WARN]${C_RESET} $1"
  if [[ -n "${2:-}" ]]; then
    check_line "       hint: $2"
  fi
  return 0
}

# Prints a number of seconds as text, for example "45 s" or "12 min".
duration_text() {
  if (($1 < 60)); then
    printf '%d s' "$1"
  else
    printf '%d min' "$((($1 + 30) / 60))"
  fi
}

# A check that was not run, for example a live test without --deep. It never fails the run.
check_skip() {
  SKIP_COUNT=$((SKIP_COUNT + 1))
  check_line "[SKIP] $1"
  return 0
}

# An extra line under a check, such as a detail of what was found. It is not counted.
check_note() {
  check_line "       $1"
}

# Prints the totals and returns 1 when at least one check failed.
check_summary() {
  if ((SKIP_COUNT > 0)); then
    printf '\nSummary: %d PASS, %d FAIL, %d WARN, %d SKIP\n' "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT" "$SKIP_COUNT"
  else
    printf '\nSummary: %d PASS, %d FAIL, %d WARN\n' "$PASS_COUNT" "$FAIL_COUNT" "$WARN_COUNT"
  fi
  if ((FAIL_COUNT > 0)); then
    printf 'Result: FAIL. Fix the failed checks and run the validation again.\n'
    return 1
  fi
  printf 'Result: PASS.\n'
  return 0
}

# ---------------------------------------------------------------------------
# Arguments and prompts
# ---------------------------------------------------------------------------

ASSUME_YES="${ASSUME_YES:-0}"

# Asks a yes or no question. Returns 0 for yes. --yes on the command line skips it.
confirm() {
  if [[ "$ASSUME_YES" == "1" ]]; then
    return 0
  fi
  local answer=""
  read -r -p "$1 [y/N] " answer || true
  [[ "$answer" =~ ^[Yy]$ ]]
}

# ---------------------------------------------------------------------------
# Where the script runs
# ---------------------------------------------------------------------------

# Prints linux, macos or windows. Windows means Git Bash or a similar shell, where the labs do not run.
host_platform() {
  case "$(uname -s)" in
    Linux*) printf 'linux' ;;
    Darwin*) printf 'macos' ;;
    MINGW* | MSYS* | CYGWIN*) printf 'windows' ;;
    *) printf 'other' ;;
  esac
}

# Returns 0 inside the course's own WSL distribution.
in_course_wsl() {
  [[ -f "$ENV_MARKER" ]]
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    die "The command '$1' is missing. ${2:-Run the readiness report: course check}"
  fi
}

# Stops unless the script runs where the labs run: the course's WSL distribution, a Linux machine, or a Mac.
require_environment() {
  if [[ "$(host_platform)" == "windows" ]]; then
    die "On Windows, the labs run in the WSL distribution of the course. Open it with: .\\course.ps1 connect (in PowerShell, from the kit folder), then run the course command there."
  fi
}

# Stops with one message when Docker does not answer.
require_docker() {
  require_cmd docker "Run: ./course up, from the kit folder"
  if docker info >/dev/null 2>&1; then
    return 0
  fi
  if [[ "$(host_platform)" == "linux" ]] && ! id -nG 2>/dev/null | tr ' ' '\n' | grep -qx docker; then
    die "Docker does not answer, and your user is not in the docker group yet. Log out and back in (restart the machine if it is a virtual machine), or run newgrp docker in this terminal, then run the command again."
  fi
  die "Docker Engine does not answer. Start it, then run the command again. On Linux: sudo systemctl start docker"
}

# Reads optional KEY=VALUE lines from .env without executing them. The course runs without .env.
load_env() {
  local env_file="${COURSE_ROOT}/.env" line
  [[ -f "$env_file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    if [[ "$line" =~ ^([A-Z][A-Z0-9_]*)=(.*)$ ]]; then
      export "${BASH_REMATCH[1]}=${BASH_REMATCH[2]}"
    fi
  done <"$env_file"
}

# Returns 0 when a TCP port answers within 5 seconds. Works with bash 3.2 (macOS), which has no timeout command.
tcp_port_open() {
  local host="$1" port="$2" probe watchdog
  (exec 3<>"/dev/tcp/${host}/${port}") 2>/dev/null &
  probe=$!
  (sleep 5 && kill "$probe" 2>/dev/null) &
  watchdog=$!
  if wait "$probe" 2>/dev/null; then
    kill "$watchdog" 2>/dev/null || true
    return 0
  fi
  kill "$watchdog" 2>/dev/null || true
  return 1
}

# version_at_least HAVE NEED returns 0 when version HAVE is NEED or later. Works with bash 3.2.
version_at_least() {
  local IFS=. i
  local -a have need
  read -r -a have <<<"${1#v}"
  read -r -a need <<<"${2#v}"
  for i in 0 1 2; do
    if ((${have[i]:-0} > ${need[i]:-0})); then
      return 0
    fi
    if ((${have[i]:-0} < ${need[i]:-0})); then
      return 1
    fi
  done
  return 0
}

# Prints the installed versions, for example v0.33.0 and v1.37.2, or nothing when the tool is missing.
kind_version() {
  kind version 2>/dev/null | sed -n 's/^kind \(v[0-9][0-9.]*\).*/\1/p'
}
kubectl_version() {
  kubectl version --client 2>/dev/null | sed -n 's/^Client Version: \(v[0-9][0-9.]*\).*/\1/p'
}
docker_version() {
  docker version --format '{{.Server.Version}}' 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# The local registry, part of the environment
# ---------------------------------------------------------------------------

# Prints the state of the registry container: running, exited, created, or nothing when it does not exist.
registry_state() {
  docker container inspect --format '{{.State.Status}}' "$REGISTRY_NAME" 2>/dev/null || true
}

# Creates the registry with a named volume for its data, or starts it when it is stopped. Safe to run twice.
# course clean NN never removes it. course destroy removes it with its volume.
ensure_registry() {
  local state
  state="$(registry_state)"
  if [[ "$state" == "running" ]]; then
    info "The registry ${REGISTRY_NAME} runs on ${REGISTRY_HOST}."
    return 0
  fi
  if tcp_port_open 127.0.0.1 "$REGISTRY_PORT"; then
    die "Something else listens on port ${REGISTRY_PORT}, which the registry of the course needs. Stop that program, then run the command again. On Linux, this shows it: sudo ss -ltnp 'sport = :${REGISTRY_PORT}'"
  fi
  if [[ -n "$state" ]]; then
    info "Starting the registry ${REGISTRY_NAME}, which was ${state}."
    docker start "$REGISTRY_NAME" >/dev/null
  else
    info "Creating the registry ${REGISTRY_NAME} on ${REGISTRY_HOST}, with its data in the Docker volume ${REGISTRY_VOLUME}."
    docker volume create "$REGISTRY_VOLUME" >/dev/null
    docker pull --quiet "$REGISTRY_IMAGE" >/dev/null
    docker run --detach --restart=always --publish "127.0.0.1:${REGISTRY_PORT}:5000" --network bridge \
      --name "$REGISTRY_NAME" --volume "${REGISTRY_VOLUME}:/var/lib/registry" "$REGISTRY_IMAGE" >/dev/null
  fi
  local _
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    if curl -fsS --max-time 2 "http://${REGISTRY_HOST}/v2/" >/dev/null 2>&1; then
      info "The registry answers on ${REGISTRY_HOST}."
      return 0
    fi
    sleep 1
  done
  die "The registry ${REGISTRY_NAME} does not answer on ${REGISTRY_HOST}. Read its log: docker logs ${REGISTRY_NAME}"
}

# Stops with one message when the registry is not running. Lab scripts call it, course up creates the registry.
require_registry() {
  local state
  state="$(registry_state)"
  if [[ -z "$state" ]]; then
    die "The registry of the course does not exist. Create it from the kit folder with: ./course up"
  fi
  if [[ "$state" != "running" ]]; then
    ensure_registry
  fi
}

# registry_has_tag REPOSITORY TAG returns 0 when the registry holds that tag.
registry_has_tag() {
  curl -fsS --max-time 5 "http://${REGISTRY_HOST}/v2/$1/tags/list" 2>/dev/null |
    jq -e --arg tag "$2" '(.tags // []) | index($tag) != null' >/dev/null 2>&1
}

# registry_digest REPOSITORY TAG prints the digest of the manifest the registry serves for that tag.
registry_digest() {
  curl -fsS --max-time 5 --head \
    -H 'Accept: application/vnd.oci.image.index.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.list.v2+json' \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
    -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
    "http://${REGISTRY_HOST}/v2/$1/manifests/$2" 2>/dev/null |
    tr -d '\r' | sed -n 's/^[Dd]ocker-[Cc]ontent-[Dd]igest: *//p'
}

# ---------------------------------------------------------------------------
# The kind cluster: one at a time, owned by one lab
# ---------------------------------------------------------------------------

cluster_exists() {
  kind get clusters 2>/dev/null | grep -qx "$KIND_CLUSTER_NAME"
}

# Prints the lab number that the cluster belongs to, for example 02, or nothing when no lab recorded it.
cluster_lab() {
  if cluster_exists && [[ -f "$CLUSTER_LAB_FILE" ]]; then
    tr -d '[:space:]' <"$CLUSTER_LAB_FILE"
  fi
}

record_cluster_lab() {
  mkdir -p "$STATE_DIR"
  printf '%s\n' "$1" >"$CLUSTER_LAB_FILE"
}

forget_cluster_lab() {
  rm -f "$CLUSTER_LAB_FILE"
}

# Prints the node containers of the cluster with their state, one per line: "name state".
cluster_nodes_state() {
  local node
  for node in $(kind get nodes --name "$KIND_CLUSTER_NAME" 2>/dev/null); do
    printf '%s %s\n' "$node" "$(docker container inspect --format '{{.State.Status}}' "$node" 2>/dev/null || echo missing)"
  done
}

# Starts the node containers that are stopped. WSL stops the distribution when its last terminal closes,
# and the control plane does not always come back at the next start: one docker start repairs it.
start_stopped_nodes() {
  local node state started=""
  while read -r node state; do
    [[ -n "$node" ]] || continue
    if [[ "$state" != "running" ]]; then
      docker start "$node" >/dev/null
      started="${started} ${node}"
    fi
  done <<<"$(cluster_nodes_state)"
  if [[ -n "$started" ]]; then
    info "Started the node containers that were stopped:${started}."
  else
    info "Every node container runs."
  fi
}

# Waits until the API server answers (2 minutes at most) and every node is Ready (2 more minutes at most). Returns 1 after that.
wait_for_nodes() {
  local deadline=$((SECONDS + 120))
  until kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1; do
    if ((SECONDS >= deadline)); then
      return 1
    fi
    sleep 2
  done
  kubectl --context "$KUBE_CONTEXT" wait --for=condition=Ready nodes --all --timeout=120s >/dev/null
}

# Lets the nodes pull from the local registry, as the kind documentation describes: a hosts.toml file on each
# node maps localhost:5001 to the registry container, the registry joins the kind network, and a ConfigMap
# documents it. https://kind.sigs.k8s.io/docs/user/local-registry/
connect_registry_to_cluster() {
  local node dir="/etc/containerd/certs.d/${REGISTRY_HOST}"
  for node in $(kind get nodes --name "$KIND_CLUSTER_NAME"); do
    docker exec "$node" mkdir -p "$dir"
    printf '[host."http://%s:5000"]\n' "$REGISTRY_NAME" | docker exec -i "$node" cp /dev/stdin "${dir}/hosts.toml"
  done
  if [[ "$(docker inspect --format '{{json .NetworkSettings.Networks.kind}}' "$REGISTRY_NAME")" == "null" ]]; then
    docker network connect kind "$REGISTRY_NAME"
  fi
  kubectl --context "$KUBE_CONTEXT" apply -f - >/dev/null <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-registry-hosting
  namespace: kube-public
data:
  localRegistryHosting.v1: |
    host: "${REGISTRY_HOST}"
    help: "https://kind.sigs.k8s.io/docs/user/local-registry/"
EOF
}

# Prints the folder of a lab from its number, for example labs/02-kubernetes-core for 02, or nothing.
lab_folder() {
  local dir
  for dir in "${COURSE_ROOT}"/labs/"$1"-*/; do
    if [[ -d "$dir" ]]; then
      printf '%s' "${dir%/}"
      return 0
    fi
  done
}

# lab_cluster_up NN CONFIG makes sure the cluster of lab NN runs: it creates it when it is missing, starts the
# node containers that are stopped, and waits for every node to be Ready. One cluster runs at a time: when the
# cluster of another lab exists, it asks to clean that lab first.
lab_cluster_up() {
  local lab="$1" config="$2" owner other
  owner="$(cluster_lab)"
  if cluster_exists && [[ "$owner" != "$lab" ]]; then
    if [[ -n "$owner" ]]; then
      other="$(lab_folder "$owner")"
      info "The cluster of lab ${owner} still exists. One cluster runs at a time."
      if ! confirm "Clean lab ${owner} first (course clean ${owner}), then set up lab ${lab}?"; then
        info "Nothing changed. Lab ${owner} keeps its cluster."
        exit 0
      fi
      if [[ -n "$other" && -f "${other}/teardown.sh" ]]; then
        ASSUME_YES=1 bash "${other}/teardown.sh" --yes
      else
        kind delete cluster --name "$KIND_CLUSTER_NAME"
        forget_cluster_lab
      fi
    else
      info "A kind cluster named ${KIND_CLUSTER_NAME} exists, and no lab of this kit recorded it."
      if ! confirm "Delete it and create the cluster of lab ${lab}?"; then
        info "Nothing changed."
        exit 0
      fi
      kind delete cluster --name "$KIND_CLUSTER_NAME"
    fi
  fi

  if cluster_exists; then
    step "The cluster of lab ${lab}"
    start_stopped_nodes
  else
    step "Creating the cluster of lab ${lab} (about a minute, more the first time)"
    kind create cluster --config "$config" --wait 180s
    record_cluster_lab "$lab"
  fi
  kubectl config use-context "$KUBE_CONTEXT" >/dev/null
  info "Waiting for the nodes to be Ready."
  if ! wait_for_nodes; then
    die "The nodes are not Ready after 4 minutes. Look at them with: docker ps --all, and kubectl get nodes. If the cluster does not come back, course clean ${lab} then course start ${lab} creates it again. Your files in ~/work are kept, and what you applied to the cluster is lost."
  fi
  connect_registry_to_cluster
  kubectl --context "$KUBE_CONTEXT" get nodes
  # After a stop, the pods of the lab start again with the nodes. Wait for them, so that what course start says
  # about the next task is true. A fault of course break can keep a pod from ever being ready: the wait ends.
  info "Waiting for the pods to be ready (at most a minute)."
  if ! kubectl --context "$KUBE_CONTEXT" wait --for=condition=Ready pods --all --all-namespaces --field-selector=status.phase!=Succeeded,status.phase!=Failed --timeout=60s >/dev/null 2>&1; then
    info "Some pods are not ready after a minute. This shows them: kubectl get pods --all-namespaces"
  fi
}

# ---------------------------------------------------------------------------
# Lab state, for course check and course break
# ---------------------------------------------------------------------------

# Stops with one message when lab NN was never started: its work folder does not exist.
require_lab_started() {
  if [[ ! -d "$2" ]]; then
    die "Lab $1 is not started. Run: course start $1"
  fi
}

# Stops with one message when the cluster of lab NN does not answer, for example after the environment stopped.
require_lab_cluster() {
  if ! cluster_exists || [[ "$(cluster_lab)" != "$1" ]]; then
    die "The cluster of lab $1 does not exist. Run: course start $1"
  fi
  if ! kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1; then
    die "The cluster of lab $1 is not running. Run: course start $1"
  fi
}
