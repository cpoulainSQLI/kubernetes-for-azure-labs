#!/usr/bin/env bash
# The parts of the environment that only the course's WSL distribution gets, after setup/install-tools.sh:
# the marker of the environment, the work folder, the clone of the kit, the course command on the PATH and
# three lines at login. cloud-init runs it as root at the first start (setup/cloud-init.yaml).
#   bash wsl-environment.sh USER KIT_NAME CLONE_URL [REF]
# REF is the branch or tag to clone, the one the clone on Windows is on. Without it, Git clones the default branch.
# Safe to run twice. It never pulls: course update does that.
set -euo pipefail

TARGET_USER="${1:?usage: wsl-environment.sh USER KIT_NAME CLONE_URL}"
KIT_NAME="${2:?usage: wsl-environment.sh USER KIT_NAME CLONE_URL}"
KIT_REPO="${3:?usage: wsl-environment.sh USER KIT_NAME CLONE_URL}"
KIT_REF="${4:-}"
HOME_DIR="/home/${TARGET_USER}"
KIT_DIR="${HOME_DIR}/${KIT_NAME}"

install -d -m 0755 "/etc/${KIT_NAME}"
touch "/etc/${KIT_NAME}/environment"
install -d -o "$TARGET_USER" -g "$TARGET_USER" "${HOME_DIR}/work"

if [[ ! -d "${KIT_DIR}/.git" ]]; then
  if [[ -n "$KIT_REF" ]]; then
    echo "Cloning the kit from ${KIT_REPO}, at ${KIT_REF}"
    sudo -H -u "$TARGET_USER" git clone --quiet --branch "$KIT_REF" "$KIT_REPO" "$KIT_DIR"
  else
    echo "Cloning the kit from ${KIT_REPO}"
    sudo -H -u "$TARGET_USER" git clone --quiet "$KIT_REPO" "$KIT_DIR"
  fi
fi
# A launcher rather than a link, so that course runs even if Git did not keep its executable bit.
printf '#!/usr/bin/env bash\nexec bash "%s/course" "$@"\n' "$KIT_DIR" >/usr/local/bin/course
chmod 0755 /usr/local/bin/course

# Three lines at each interactive login. The environment stops when its last terminal closes, so the
# second line says how to bring a lab back.
cat >"/etc/profile.d/${KIT_NAME}.sh" <<EOF
case "\$-" in
  *i*)
    echo "Lab kit ${KIT_NAME}."
    echo "  course help                 the commands of the course"
    echo "  course start NN             start lab NN, or bring it back after a stop"
    echo "  course check NN --guided    check your work on lab NN, task by task"
    ;;
esac
EOF

{
  echo "docker: $(docker --version)"
  echo "kind: $(kind version)"
  echo "kubectl: $(kubectl version --client 2>/dev/null | head -n 1)"
  echo "kit: $(sudo -H -u "$TARGET_USER" git -C "$KIT_DIR" rev-parse --short HEAD)"
} >"/etc/${KIT_NAME}/tools-ready"
echo "The environment of ${KIT_NAME} is ready."
