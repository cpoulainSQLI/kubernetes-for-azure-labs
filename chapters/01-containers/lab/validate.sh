#!/usr/bin/env bash
# Chapter 1 validation. Run it on the lab VM:
#   ~/aro-k8s-course/chapters/01-containers/lab/validate.sh            full report
#   ~/aro-k8s-course/chapters/01-containers/lab/validate.sh --guided   one stage at a time
# Read-only: it reads your Dockerfile, inspects Docker and the registry, and sends GET requests.
# Only --deep starts anything: a temporary container, removed at the end.
# Exit code 0 when no check fails, 1 otherwise.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../../scripts/lib.sh
source "${SCRIPT_DIR}/../../../scripts/lib.sh"
# shellcheck source=../../../scripts/lib-validate.sh
source "${SCRIPT_DIR}/../../../scripts/lib-validate.sh"

CHAPTER="01"
VALIDATION_DIR="01-containers"
IMAGE_REPO="sample-app"
IMAGE_TAG="1.0.0"
IMAGE="${IMAGE_REPO}:${IMAGE_TAG}"
CONTAINER="sample-app"
SIZE_LIMIT_MB=100
WORK_DIR="${HOME}/work/01-containers"
DOCKERFILE="${WORK_DIR}/sample-app/Dockerfile"
# The user ID of the live test. OpenShift picks an ID of this kind for each project.
PROBE_USER="1000680000:0"
PROBE_NAME="sample-app-validate-$$"

STAGE_TITLES=(
  "Write the Dockerfile"
  "Build the image"
  "Run the container"
  "Push the image to the registry"
)
DEEP_NOTICE="they start a temporary container from your image, call it, stop it and remove it. Your own container, your image and Azure are not touched."

preflight() {
  require_lab_vm
  load_env
  require_cmd docker "Run chapter 0 setup again."
  require_cmd curl
  require_cmd jq
  if ! docker info >/dev/null 2>&1; then
    check_fail "Docker does not answer." "Disconnect and reconnect to the VM, then try again."
    check_summary
    exit 1
  fi
}

# ---------------------------------------------------------------------------
# Stage 1: the Dockerfile, read as text
# ---------------------------------------------------------------------------

# Prints the Dockerfile with one instruction per line: comments and empty lines
# removed, continuation lines joined, the instruction name in upper case.
dockerfile_instructions() {
  awk '
    { sub(/\r$/, "") }
    /^[[:space:]]*#/ { next }
    {
      line = $0
      if (joining) { buffer = buffer " " line } else { buffer = line }
      if (buffer ~ /\\[[:space:]]*$/) {
        sub(/\\[[:space:]]*$/, "", buffer)
        joining = 1
        next
      }
      joining = 0
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", buffer)
      if (buffer == "") { next }
      cut = match(buffer, /[[:space:]]/)
      if (cut == 0) { print toupper(buffer); next }
      rest = substr(buffer, cut + 1)
      sub(/^[[:space:]]+/, "", rest)
      print toupper(substr(buffer, 1, cut - 1)) " " rest
    }
  ' "$1"
}

stage_1_task() {
  cat <<EOF
  Write a file called Dockerfile in ${WORK_DIR}/sample-app, next to main.go.
  - Two stages: the first compiles the app with the golang image, the second
    receives only the binary and is the image that runs.
  - In the last stage: a numeric non-root USER, EXPOSE 8080 and a start command.
  - The version reaches the app at build time, through a build argument.
  Details: chapter 1 page, Lab, task 1.
EOF
}

stage_1() {
  if [[ ! -f "$DOCKERFILE" ]]; then
    check_fail "No Dockerfile at ${DOCKERFILE}." "Write it in that folder, next to main.go. Chapter 1 setup copies the sample app there."
    return 0
  fi
  check_pass "Found ${DOCKERFILE}."

  local instructions line image name
  instructions="$(dockerfile_instructions "$DOCKERFILE")"

  # FROM lines: the image of each stage and the name given with AS.
  local -a from_images=() stage_names=()
  while IFS= read -r line; do
    [[ "$line" == "FROM "* ]] || continue
    # shellcheck disable=SC2086  # Word splitting is wanted: FROM [--platform=x] image [AS name]
    set -- ${line#FROM }
    while [[ "${1:-}" == --* ]]; do
      shift
    done
    image="${1:-}"
    name=""
    if [[ "${2:-}" == [aA][sS] ]]; then
      name="${3:-}"
    fi
    from_images+=("$image")
    stage_names+=("$name")
  done <<<"$instructions"

  local stages="${#from_images[@]}"
  if ((stages == 0)); then
    check_fail "The Dockerfile has no FROM instruction." "Every stage starts with FROM and the image it builds on."
    return 0
  fi
  if ((stages >= 2)); then
    check_pass "The Dockerfile has ${stages} stages."
  else
    check_fail "The Dockerfile has one stage, the lab asks for at least two." "Compile in a first stage. Start a second stage with another FROM and bring only the binary into it with COPY --from."
  fi

  # Base images with a fixed version. scratch and earlier stages have none.
  local index earlier unpinned="" pinned=""
  for ((index = 0; index < stages; index++)); do
    image="${from_images[index]}"
    earlier=0
    for name in "${stage_names[@]:0:index}"; do
      if [[ -n "$name" && "$name" == "$image" ]]; then
        earlier=1
      fi
    done
    if [[ "$image" == "scratch" || "$earlier" == "1" || "$image" == *'$'* ]]; then
      continue
    fi
    if [[ "$image" == *@sha256:* ]] || { [[ "${image##*/}" == *:* ]] && [[ "${image##*:}" != "latest" ]]; }; then
      pinned="${pinned}${pinned:+, }${image}"
    else
      unpinned="${unpinned}${unpinned:+, }${image}"
    fi
  done
  if [[ -n "$unpinned" ]]; then
    check_warn "Base image without a fixed version: ${unpinned}." "Name a version, such as golang:1.27. Without a tag Docker uses latest, which changes over time, so the same Dockerfile can give another image next month."
  elif [[ -n "$pinned" ]]; then
    check_pass "Every base image names a version (${pinned})."
  fi

  # The last stage is the image that runs. When it starts from an earlier stage,
  # follow the names back to the image that stage was built on.
  local final_image="${from_images[stages - 1]}" final hop
  for ((hop = 0; hop < stages; hop++)); do
    for ((index = 0; index < stages - 1; index++)); do
      if [[ -n "${stage_names[index]}" && "${stage_names[index]}" == "$final_image" ]]; then
        final_image="${from_images[index]}"
      fi
    done
  done
  final="$(awk '/^FROM / { text = "" } { text = text $0 "\n" } END { printf "%s", text }' <<<"$instructions")"

  if ((stages >= 2)); then
    if [[ "${final_image##*/}" == golang* ]]; then
      check_fail "The last stage is built on ${final_image}, so the Go toolchain ends up in the image that runs." "Start the last stage from a small image, such as scratch, and copy the binary into it."
    else
      check_pass "The last stage is built on ${final_image}, not on the toolchain image."
    fi
    if grep -q -E '^COPY .*--from=' <<<"$final"; then
      check_pass "The last stage takes files from an earlier stage with COPY --from."
    else
      check_fail "The last stage copies nothing from an earlier stage." "Bring the compiled binary in with COPY --from=<stage> <path in that stage> <path in the image>."
    fi
    if grep -E '^(COPY|ADD) ' <<<"$final" | grep -v -e '--from=' | grep -q -E '^(COPY|ADD) +(--[^ ]+ +)*\./? '; then
      check_warn "The last stage copies the whole build folder into the image." "Copy only what the app needs at run time. Source code and build files belong to the build stage."
    fi
  fi

  local user_line user_value user_id
  user_line="$(grep '^USER ' <<<"$final" | tail -n 1 || true)"
  user_value="${user_line#USER }"
  user_id="${user_value%%:*}"
  if [[ -z "$user_line" ]]; then
    check_fail "The last stage has no USER instruction, so the container would run as root." "Add USER with a numeric ID that is not 0, such as 65532:65532."
  elif [[ "$user_id" == "0" || "$user_id" == "root" ]]; then
    check_fail "The last stage sets USER ${user_value}, which is root." "Use a numeric ID that is not 0, such as 65532:65532."
  elif [[ "$user_id" =~ ^[0-9]+$ ]]; then
    check_pass "The last stage sets a numeric non-root user (USER ${user_value})."
  else
    check_warn "The last stage sets USER ${user_value}, a name and not a numeric ID." "Kubernetes can only prove that a user is not root when the ID is numeric, and scratch has no user database to look a name up in."
  fi

  if grep -q -E '^EXPOSE (.* )?8080(/tcp)?( |$)' <<<"$final"; then
    check_pass "The last stage declares port 8080 with EXPOSE."
  else
    check_fail "The last stage has no EXPOSE 8080." "EXPOSE documents the port the app listens on. It does not publish it."
  fi

  local start_line
  start_line="$(grep -E '^(ENTRYPOINT|CMD) ' <<<"$final" | tail -n 1 || true)"
  if [[ -z "$start_line" ]]; then
    check_fail "The last stage has no ENTRYPOINT or CMD, so the image does not know what to start." "Add ENTRYPOINT with the path of the binary, in the exec form: ENTRYPOINT [\"/path/to/binary\"]."
  elif [[ "${start_line#* }" == \[* ]]; then
    check_pass "The start command uses the exec form, so the app is the first process and receives the stop signal."
  else
    check_warn "The start command uses the shell form (${start_line})." "Write it as a JSON list: ENTRYPOINT [\"/path/to/binary\"]. The shell form wraps the app in /bin/sh, which scratch does not have and which does not pass the stop signal on."
  fi

  if grep -q -E 'main\.version=["'\''\\]*\$' <<<"$instructions"; then
    if grep -q '^ARG ' <<<"$instructions"; then
      check_pass "The version comes from a build argument (ARG) and reaches the app through -X main.version."
    else
      check_warn "The version uses a variable but the Dockerfile declares no ARG." "Declare it in the build stage, before the RUN that compiles: ARG VERSION=dev."
    fi
  elif grep -q 'main\.version=' <<<"$instructions"; then
    check_warn "The version is written into the Dockerfile." "Chapter 2 builds version 2.0.0 from the same file. Declare ARG VERSION and pass it with --build-arg, so that the file does not change between versions."
  else
    check_fail "The Dockerfile never sets main.version, so the app reports version dev." "Pass -ldflags \"-X main.version=...\" to go build. The sample app page explains the flag."
  fi
}

# ---------------------------------------------------------------------------
# Stage 2: the image
# ---------------------------------------------------------------------------

stage_2_task() {
  cat <<EOF
  From ${WORK_DIR}/sample-app, build the image and tag it ${IMAGE},
  with the version set to ${IMAGE_TAG} through your build argument.
  Then list the layers with: docker image history ${IMAGE}
  and name the instruction that created each one.
  Details: chapter 1 page, Lab, task 2.
EOF
}

remove_probe() {
  docker rm --force "$PROBE_NAME" >/dev/null 2>&1 || true
}

# Starts a temporary container as another user ID, calls it, stops it and removes it.
live_test_image() {
  local port="" code="" attempt started stopped exit_code
  trap remove_probe EXIT
  if ! docker run --detach --name "$PROBE_NAME" --user "$PROBE_USER" --publish "127.0.0.1::8080" "$IMAGE" >/dev/null 2>&1; then
    check_fail "Live test: a temporary container could not start from ${IMAGE} with user ${PROBE_USER}." "Start one by hand to see the error: docker run --rm --user ${PROBE_USER} ${IMAGE}"
    remove_probe
    return 0
  fi
  port="$(docker port "$PROBE_NAME" 8080/tcp 2>/dev/null | head -n 1 || true)"
  port="${port##*:}"
  for ((attempt = 0; attempt < 10; attempt++)); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 2 "http://127.0.0.1:${port}/healthz" || true)"
    if [[ "$code" == "200" ]]; then
      break
    fi
    sleep 1
  done
  if [[ "$code" == "200" ]]; then
    check_pass "Live test: the app answers 200 on /healthz when it starts with the arbitrary user ID ${PROBE_USER}, as it will on OpenShift."
  else
    check_fail "Live test: the app does not answer on /healthz when it starts with the arbitrary user ID ${PROBE_USER}." "OpenShift runs every container with an ID of its own choice. The image must not depend on one user: check file permissions and the port. Logs: docker run --rm --user ${PROBE_USER} ${IMAGE}"
  fi

  started="$SECONDS"
  docker stop -t 10 "$PROBE_NAME" >/dev/null 2>&1 || true
  stopped=$((SECONDS - started))
  exit_code="$(docker container inspect --format '{{.State.ExitCode}}' "$PROBE_NAME" 2>/dev/null || true)"
  if ((stopped <= 5)) && [[ "$exit_code" == "0" ]]; then
    check_pass "Live test: docker stop ends the app in ${stopped} s with exit code 0. The stop signal reaches the app and it shuts down cleanly."
  else
    check_warn "Live test: docker stop took ${stopped} s and the exit code is ${exit_code:-unknown}." "A clean stop is quick and ends with code 0. When Docker has to kill the process after 10 seconds, the stop signal did not reach the app: use the exec form of ENTRYPOINT."
  fi
  remove_probe
  trap - EXIT
}

stage_2() {
  if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    check_fail "No local image named ${IMAGE}." "Build it from your Dockerfile and tag it ${IMAGE}."
    return 0
  fi
  check_pass "The image ${IMAGE} exists."

  local image_user user_part exposed start_command size_bytes size_mb layers
  image_user="$(docker image inspect --format '{{.Config.User}}' "$IMAGE")"
  user_part="${image_user%%:*}"
  if [[ -z "$image_user" || "$user_part" == "root" || "$user_part" == "0" ]]; then
    check_fail "The image runs as root (USER is '${image_user:-not set}')." "Set a numeric non-root USER in the last stage, then build again."
  else
    check_pass "The image runs as a non-root user (${image_user})."
    if [[ ! "$user_part" =~ ^[0-9]+$ ]]; then
      check_warn "The user of the image is a name, not a numeric ID." "Kubernetes can only prove a user is non-root when the ID is numeric, which matters in chapters 4 and 7."
    fi
  fi

  exposed="$(docker image inspect --format '{{json .Config.ExposedPorts}}' "$IMAGE")"
  if jq -e 'has("8080/tcp")' <<<"$exposed" >/dev/null 2>&1; then
    check_pass "The image declares port 8080/tcp."
  else
    check_fail "The image does not declare port 8080/tcp." "Add EXPOSE 8080 to the last stage, then build again."
  fi

  start_command="$(docker image inspect --format '{{json .Config.Entrypoint}} {{json .Config.Cmd}}' "$IMAGE" | jq -c -s 'map(. // []) | add')"
  if [[ "$start_command" == "[]" ]]; then
    check_fail "The image has no start command." "Add ENTRYPOINT to the last stage, then build again."
  elif jq -e '.[0] == "/bin/sh" and .[1] == "-c"' <<<"$start_command" >/dev/null; then
    check_warn "The image starts the app through a shell (${start_command})." "Use the exec form, ENTRYPOINT [\"/path/to/binary\"], then build again."
  else
    check_pass "The image starts the app directly (${start_command})."
  fi

  size_bytes="$(docker image inspect --format '{{.Size}}' "$IMAGE")"
  size_mb=$((size_bytes / 1000000))
  layers="$(docker image inspect --format '{{len .RootFS.Layers}}' "$IMAGE")"
  if ((size_mb <= SIZE_LIMIT_MB)); then
    check_pass "The image is ${size_mb} MB in $(count_of "$layers" layer) (target: ${SIZE_LIMIT_MB} MB or less)."
  else
    check_warn "The image is ${size_mb} MB in $(count_of "$layers" layer) (target: ${SIZE_LIMIT_MB} MB or less)." "Keep the toolchain in the build stage and copy only the binary into a small last stage."
  fi

  if live_test_ready "the image started with another user ID, called, then stopped."; then
    live_test_image
  fi
}

# ---------------------------------------------------------------------------
# Stage 3: the container
# ---------------------------------------------------------------------------

stage_3_task() {
  cat <<EOF
  Start a container named ${CONTAINER} from ${IMAGE}, in the background,
  with port 8080 of the container published on port 8080 of the VM.
  Call it with curl on http://localhost:8080/ and on /healthz, then read its logs
  and match each line with the request that produced it.
  Details: chapter 1 page, Lab, task 3.
EOF
}

stage_3() {
  local container_state container_image_id local_image_id container_user published health_code reported_version
  container_state="$(docker container inspect --format '{{.State.Status}}' "$CONTAINER" 2>/dev/null || true)"
  if [[ "$container_state" != "running" ]]; then
    check_fail "No running container named ${CONTAINER} (state: ${container_state:-not found})." "Start it in the background from ${IMAGE}, with the name ${CONTAINER} and port 8080 published. If it stopped, read: docker logs ${CONTAINER}"
    return 0
  fi
  check_pass "The container ${CONTAINER} is running."

  container_image_id="$(docker container inspect --format '{{.Image}}' "$CONTAINER")"
  local_image_id="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  if [[ -n "$local_image_id" && "$container_image_id" == "$local_image_id" ]]; then
    check_pass "The container runs the current ${IMAGE} image."
  else
    check_fail "The container runs another image than the current ${IMAGE}." "A container keeps the image it was started from. After a new build, remove the container and start it again."
  fi

  container_user="$(docker container inspect --format '{{.Config.User}}' "$CONTAINER")"
  if [[ -z "$container_user" || "${container_user%%:*}" == "root" || "${container_user%%:*}" == "0" ]]; then
    check_fail "The container runs as root." "Do not override the user with --user, and set USER in the Dockerfile."
  else
    check_pass "The container runs as user ${container_user}."
  fi

  published="$(docker port "$CONTAINER" 8080/tcp 2>/dev/null || true)"
  if grep -q ':8080$' <<<"$published"; then
    check_pass "Port 8080 of the container is published on port 8080 of the VM."
  elif [[ -n "$published" ]]; then
    check_fail "Port 8080 of the container is published on $(head -n 1 <<<"$published"), the lab asks for port 8080 of the VM." "Remove the container and start it again with --publish 8080:8080."
    return 0
  else
    check_fail "Port 8080 of the container is not published on the VM." "EXPOSE does not publish. Remove the container and start it again with --publish 8080:8080."
    return 0
  fi

  health_code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://localhost:8080/healthz || true)"
  if [[ "$health_code" == "200" ]]; then
    check_pass "GET http://localhost:8080/healthz answers 200."
  else
    check_fail "GET http://localhost:8080/healthz answers ${health_code/#000/nothing (no connection)}." "Check the container logs with: docker logs ${CONTAINER}"
  fi

  reported_version="$(curl -s --max-time 5 http://localhost:8080/ | jq -r '.version' 2>/dev/null || true)"
  if [[ "$reported_version" == "$IMAGE_TAG" ]]; then
    check_pass "GET / reports version ${IMAGE_TAG}."
  else
    check_fail "GET / reports version '${reported_version:-nothing}', expected ${IMAGE_TAG}." "Pass the version when you build, with --build-arg, then start the container again from the new image."
  fi
}

# ---------------------------------------------------------------------------
# Stage 4: the registry
# ---------------------------------------------------------------------------

stage_4_task() {
  cat <<EOF
  Publish the image to your chapter registry:
  sign Docker in with az acr login, tag the image with the login server of
  the registry, then push it. Chapter 1 setup printed the login server.
  This command prints it again:
    az acr list --resource-group $(rg_name) --query "[].loginServer" --output tsv
  Details: chapter 1 page, Lab, task 4.
EOF
}

stage_4() {
  if ! az_signed_in; then
    check_fail "The Azure CLI on the VM is not signed in, so the registry cannot be read." "Run chapter 1 setup again, or: az login --identity"
    return 0
  fi

  local registry_name registry_info login_server registry_sku admin_enabled tags remote_digest local_digests
  registry_name="$(az acr list --resource-group "$(rg_name)" \
    --query "[?tags.course=='${COURSE_TAG_VALUE}' && tags.chapter=='${CHAPTER}'].name | [0]" --output tsv 2>/dev/null || true)"
  if [[ -z "$registry_name" ]]; then
    check_fail "No registry tagged chapter=${CHAPTER} in $(rg_name)." "Run chapter 1 setup."
    return 0
  fi
  registry_info="$(az acr show --name "$registry_name" --query "[loginServer, sku.name, adminUserEnabled]" --output tsv)"
  read -r login_server registry_sku admin_enabled <<<"$(tr '\n' ' ' <<<"$registry_info")"
  check_pass "Registry ${login_server} exists with the course tags (${registry_sku} tier)."
  if [[ "$admin_enabled" == "false" ]]; then
    check_pass "The registry admin account is disabled. Access goes through Microsoft Entra ID."
  else
    check_warn "The registry admin account is enabled." "Disable it: a shared password cannot be traced to a person."
  fi

  local local_id registry_tag_id
  local_id="$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)"
  registry_tag_id="$(docker image inspect --format '{{.Id}}' "${login_server}/${IMAGE}" 2>/dev/null || true)"
  if [[ -z "$registry_tag_id" ]]; then
    check_fail "No local image is tagged ${login_server}/${IMAGE}." "Docker pushes to the registry named in the image name. Add that name with docker tag."
  elif [[ "$registry_tag_id" == "$local_id" ]]; then
    check_pass "Your image also carries the registry name (${login_server}/${IMAGE})."
  else
    check_fail "The tag ${login_server}/${IMAGE} points at an older build, not at your current ${IMAGE}." "A tag stays on the image it was given to. After a new build, run docker tag again, then push."
  fi

  tags="$(az acr repository show-tags --name "$registry_name" --repository "$IMAGE_REPO" --output tsv 2>/dev/null || true)"
  if ! grep -qx "$IMAGE_TAG" <<<"$tags"; then
    check_fail "The repository ${IMAGE_REPO} has no tag ${IMAGE_TAG} in ${login_server}." "Run az acr login --name ${registry_name}, then push ${login_server}/${IMAGE}."
    return 0
  fi
  check_pass "The repository ${IMAGE_REPO} has the tag ${IMAGE_TAG}."

  remote_digest="$(az acr repository show --name "$registry_name" --image "$IMAGE" --query digest --output tsv 2>/dev/null || true)"
  local_digests="$(docker image inspect --format '{{range .RepoDigests}}{{println .}}{{end}}' "$IMAGE" 2>/dev/null || true)"
  if [[ -n "$remote_digest" ]] && grep -qx "${login_server}/${IMAGE_REPO}@${remote_digest}" <<<"$local_digests"; then
    check_pass "The pushed image has the same digest as your local image (${remote_digest:0:19}...)."
  else
    check_fail "The image in the registry is not your current local ${IMAGE}: the digests differ." "You built again after the push. Tag and push again, so that the registry holds what you tested."
  fi
}

run_validation "$@"
