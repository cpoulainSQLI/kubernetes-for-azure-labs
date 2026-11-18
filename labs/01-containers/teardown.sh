#!/usr/bin/env bash
# Chapter 1 teardown. Removes the sample-app container of the lab.
#   course clean 01 [--yes]
# Keeps your files, your local images and the registry with the image you pushed: chapter 2 pulls it from there.
# Safe to run twice.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"

CONTAINER="sample-app"

for arg in "$@"; do
  case "$arg" in
    --yes) ASSUME_YES=1 ;;
    -h | --help)
      echo "Usage: course clean 01 [--yes]"
      echo "Removes the ${CONTAINER} container. Your files, your images and the registry are kept."
      exit 0
      ;;
    *) die "Unknown option: ${arg}. Run with --help." ;;
  esac
done

require_environment
require_docker

if ! confirm "Remove the ${CONTAINER} container?"; then
  info "Nothing changed."
  exit 0
fi

step "Removing the ${CONTAINER} container"
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
  docker container rm --force "$CONTAINER" >/dev/null
  info "Container removed."
else
  info "No container named ${CONTAINER}."
fi
info "Kept: your files in ~/work/01-containers, your images, and the registry ${REGISTRY_HOST} with what you pushed."
info "Chapter 2 pulls your image from the registry. Next: course start 02"
