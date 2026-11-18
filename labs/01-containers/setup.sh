#!/usr/bin/env bash
# Lab 01 setup. Makes sure the local registry of the environment runs, and copies the sample app to ~/work.
#   course start 01 [--yes]
# Safe to run again: it keeps your files, and on return it says which task comes next.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"

WORK_DIR="${HOME}/work/01-containers"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "Usage: course start 01 [--yes]"
      echo "Starts the local registry if it is stopped, and copies the sample app to ${WORK_DIR}."
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

require_environment
require_docker

step "Registry"
require_registry
info "Lab 1 pushes your image to ${REGISTRY_HOST}. Nothing of the lab leaves your computer."

step "Copying the sample app to ${WORK_DIR}"
mkdir -p "$WORK_DIR"
if [[ -d "${WORK_DIR}/sample-app" ]]; then
  info "${WORK_DIR}/sample-app already exists. Kept as it is."
else
  cp -r "${COURSE_ROOT}/sample-app" "${WORK_DIR}/sample-app"
  info "Copied."
fi

# After a stop of the environment, the container of the lab is exited. Start it again, unless course break 01 stopped
# it on purpose: then finding that is the exercise.
if [[ "$(docker container inspect --format '{{.State.Status}}' sample-app 2>/dev/null || true)" == "exited" ]]; then
  if [[ -f "${WORK_DIR}/.broken-lab" ]]; then
    info "The container sample-app is stopped, and a fault of course break 01 is in place. It stays as it is."
  else
    step "Starting your container sample-app again"
    docker start sample-app >/dev/null
    info "Started. Its settings are the ones you gave it."
  fi
fi

step "Done"
info "Setup took $(duration_text "$SECONDS")."
info "Your working folder: ${WORK_DIR}/sample-app"
bash "${SCRIPT_DIR}/validate.sh" --next || true
