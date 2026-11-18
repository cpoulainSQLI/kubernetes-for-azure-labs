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

step "Done"
info "Setup took $(duration_text "$SECONDS")."
info "Your working folder: ${WORK_DIR}/sample-app"
bash "${SCRIPT_DIR}/validate.sh" --next || true
