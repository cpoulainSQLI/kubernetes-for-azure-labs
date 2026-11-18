#!/usr/bin/env bash
# Chapter 1 broken lab. Run it once course check 01 passes:
#   course break 01
# It replaces or stops your sample-app container so that something is wrong with it.
# You find the cause, check it with --diagnose, repair it, and course check 01 confirms.
# It never touches your image, your Dockerfile or the registry.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../lib/lib.sh
source "${SCRIPT_DIR}/../../lib/lib.sh"
# shellcheck source=../../lib/lib-break.sh
source "${SCRIPT_DIR}/../../lib/lib-break.sh"

CHAPTER="01"
WORK_DIR="${HOME}/work/01-containers"
IMAGE="sample-app:1.0.0"
CONTAINER="sample-app"
BREAK_CHECK="course check 01 --stage 3"
BREAK_NOTICE="It removes or stops your ${CONTAINER} container and may start another one in its place. Your image, your files and the registry are not touched."

SCENARIOS=(port listen user stopped)
CAUSES=(
  "Port 8080 of the container is published on another port of the computer."
  "The app inside the container listens on another port than 8080."
  "The container runs as root."
  "The container is stopped."
  "The image ${IMAGE} was deleted."
  "The container runs another version of the app."
)

lab_is_finished() {
  bash "${SCRIPT_DIR}/validate.sh" --stage 3 >/dev/null 2>&1
}

replace_container() {
  docker rm --force "$CONTAINER" >/dev/null 2>&1 || true
  docker run --detach --name "$CONTAINER" "$@" "$IMAGE" >/dev/null
}

restore_lab() {
  replace_container --publish 8080:8080
  info "The container ${CONTAINER} runs again from ${IMAGE}, with port 8080 published on port 8080."
}

symptom_port() {
  info "A user reports: curl http://localhost:8080/ cannot connect any more."
}
inject_port() {
  replace_container --publish 8081:8080
}
explain_port() {
  info "docker ps shows 0.0.0.0:8081->8080/tcp in the PORTS column: the app is fine, but it is published on port 8081 of the computer."
  info "A published port cannot be changed on a running container. Remove the container and start it again with the right --publish."
}

symptom_listen() {
  info "A user reports: curl http://localhost:8080/ gets no answer any more, although docker ps shows the container as Up."
}
inject_listen() {
  replace_container --publish 8080:8080 --env PORT=9090
}
explain_listen() {
  info "docker logs ${CONTAINER} shows 'listening on :9090'. The container was started with the environment variable PORT=9090, which docker inspect shows under Config.Env."
  info "Port 8080 is published, but nothing listens on it inside the container. Remove the container and start it again without that variable."
}

symptom_user() {
  info "A security scan of the computer reports a problem with the running ${CONTAINER} container. The app still answers."
}
inject_user() {
  replace_container --publish 8080:8080 --user 0:0
}
explain_user() {
  info "The first log line of the app ends with 'as user 0', and docker inspect shows 0:0 under Config.User."
  info "The container was started with --user 0:0, which overrides the USER of the image. Remove it and start it again without --user."
}

symptom_stopped() {
  info "A user reports: curl http://localhost:8080/ cannot connect any more."
}
inject_stopped() {
  docker stop "$CONTAINER" >/dev/null
}
explain_stopped() {
  info "docker ps shows nothing, and docker ps --all shows the container with the status Exited."
  info "docker start ${CONTAINER} starts it again with the settings it was created with."
}

run_break "$@"
