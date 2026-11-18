#!/usr/bin/env bash
# Readiness report of the environment of the course. Read-only: it changes nothing.
# Run it where the labs run (a Linux machine, or the course's WSL distribution):
#   course check
# On Windows, .\course.ps1 check runs the same checks from PowerShell (setup/check.ps1).
# Exit code 0 when no check fails, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/lib.sh
source "${SCRIPT_DIR}/../lib/lib.sh"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  echo "Usage: course check"
  echo "Prints PASS, FAIL or WARN for each readiness check of the environment. Changes nothing."
  echo "To check a lab, give its number: course check 01"
  exit 0
fi

platform="$(host_platform)"
if [[ "$platform" == "windows" ]]; then
  die "On Windows, run the readiness report in PowerShell: .\\course.ps1 check"
fi
printf 'Readiness report, %s UTC\n' "$(date -u '+%Y-%m-%d %H:%M')"

step "Platform"
# check: platform
if [[ "$platform" == "linux" ]]; then
  # shellcheck source=/dev/null
  check_pass "Linux: $(. /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}"), kernel $(uname -r)."
else
  check_warn "macOS $(sw_vers -productVersion 2>/dev/null || true): the labs have not been tested on a Mac yet." "Tell the author what works and what does not."
fi
# check: environment
if in_course_wsl; then
  check_pass "This is the WSL distribution of the course, and you are $(id -un)."
else
  check_pass "This machine is the environment of the course, and you are $(id -un)."
fi
# check: systemd
if [[ "$platform" == "linux" ]]; then
  if [[ "$(ps -p 1 -o comm= 2>/dev/null)" == "systemd" ]]; then
    check_pass "systemd runs, so Docker Engine starts with the environment."
  else
    check_warn "systemd does not run, so nothing starts Docker Engine by itself." "Start it yourself before a lab: sudo service docker start"
  fi
fi

step "Tools"
# check: docker
if ! command -v docker >/dev/null 2>&1; then
  check_fail "Docker is not installed." "Run: ./course up, from the kit folder"
elif ! docker info >/dev/null 2>&1; then
  check_fail "Docker is installed, but Docker Engine does not answer for $(id -un)." "If course up just added you to the docker group, log out and back in, or run newgrp docker. Otherwise start Docker Engine: sudo systemctl start docker"
else
  check_pass "Docker Engine $(docker_version) answers. The course does not pin its version."
  # check: docker-engine
  engine_os="$(docker info --format '{{.OperatingSystem}}' 2>/dev/null || true)"
  if in_course_wsl && [[ "$engine_os" == *"Docker Desktop"* ]]; then
    check_warn "The docker command reaches Docker Desktop, not the own Docker Engine of the distribution." "In Docker Desktop, open Settings, Resources, WSL integration, and turn it off for ${KIT_NAME}."
  else
    check_pass "Docker runs on ${engine_os:-an unknown system}."
  fi
fi
# check: kind
found="$(kind_version)"
if [[ "$found" == "$PINNED_KIND_VERSION" ]]; then
  check_pass "kind ${found}."
elif [[ -n "$found" ]]; then
  check_warn "kind ${found}, and the course pins ${PINNED_KIND_VERSION}." "On Linux, ./course up installs the pinned version."
else
  check_fail "kind is not installed." "Run: ./course up, from the kit folder"
fi
# check: kubectl
found="$(kubectl_version)"
if [[ "$found" == "${PINNED_KUBECTL_MINOR}".* ]]; then
  check_pass "kubectl ${found}."
elif [[ -n "$found" ]]; then
  check_warn "kubectl ${found}, and the course pins ${PINNED_KUBECTL_MINOR}." "On Linux, ./course up installs the pinned version."
else
  check_fail "kubectl is not installed." "Run: ./course up, from the kit folder"
fi
# check: tools-other
missing=""
for tool in git curl jq python3; do
  command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if command -v python3 >/dev/null 2>&1 && ! python3 -c 'import yaml' 2>/dev/null; then
  missing="${missing} python3-yaml"
fi
if [[ -z "$missing" ]]; then
  check_pass "git, curl, jq and the YAML module of Python are installed."
else
  check_fail "Missing:${missing}." "Run: ./course up, from the kit folder"
fi
# check: inotify
if [[ "$platform" == "linux" ]]; then
  watches="$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)"
  if ((watches >= 524288)); then
    check_pass "inotify allows ${watches} watches, enough for a kind cluster of three nodes."
  else
    check_warn "inotify allows ${watches} watches. A kind cluster of three nodes may fail to start." "Run: ./course up, which raises it to 524288."
  fi
fi

step "Registry, kit and cluster"
# check: registry
state="$(registry_state 2>/dev/null || true)"
if [[ "$state" == "running" ]] && curl -fsS --max-time 5 "http://${REGISTRY_HOST}/v2/" >/dev/null 2>&1; then
  if docker container inspect --format '{{range .Mounts}}{{.Name}} {{end}}' "$REGISTRY_NAME" 2>/dev/null | grep -qw "$REGISTRY_VOLUME"; then
    check_pass "The registry ${REGISTRY_NAME} answers on ${REGISTRY_HOST}, with its data in the volume ${REGISTRY_VOLUME}."
  else
    check_warn "The registry ${REGISTRY_NAME} answers on ${REGISTRY_HOST}, but keeps its data outside the volume ${REGISTRY_VOLUME}." "Remove it with docker rm --force ${REGISTRY_NAME}, then run course up. The images you pushed are lost."
  fi
elif [[ -n "$state" ]]; then
  check_fail "The registry ${REGISTRY_NAME} is ${state}, or does not answer on ${REGISTRY_HOST}." "Run: course up. It starts the registry."
else
  check_fail "The registry ${REGISTRY_NAME} does not exist." "Run: ./course up, from the kit folder"
fi
# check: kit
if ! git -C "$COURSE_ROOT" rev-parse --git-dir >/dev/null 2>&1; then
  check_warn "The kit in ${COURSE_ROOT} is not a Git clone, so course update cannot update it." "Clone the kit with Git."
elif [[ -z "$(command -v course 2>/dev/null || true)" ]]; then
  check_warn "The kit is cloned in ${COURSE_ROOT} (commit $(git -C "$COURSE_ROOT" rev-parse --short HEAD)), and course is not on your PATH." "Run ./course from ${COURSE_ROOT}, or let ./course up put a launcher in ~/.local/bin."
else
  check_pass "The kit is cloned in ${COURSE_ROOT} (commit $(git -C "$COURSE_ROOT" rev-parse --short HEAD)), and course is on your PATH."
fi
# check: cluster
if ! command -v kind >/dev/null 2>&1 || ! cluster_exists; then
  check_pass "No kind cluster runs now. A lab that needs one creates it with course start NN."
else
  lab="$(cluster_lab)"
  stopped="$(cluster_nodes_state | awk '$2 != "running" {print $1}' | tr '\n' ' ')"
  if [[ -n "${stopped// /}" ]]; then
    check_warn "The cluster of lab ${lab:-unknown} has stopped nodes: ${stopped% }." "Bring it back with: course start ${lab:-NN}"
  elif kubectl --context "$KUBE_CONTEXT" get nodes >/dev/null 2>&1; then
    check_pass "The cluster of lab ${lab:-unknown} runs."
  else
    check_warn "The cluster of lab ${lab:-unknown} does not answer yet." "Run: course start ${lab:-NN}"
  fi
fi

check_summary
