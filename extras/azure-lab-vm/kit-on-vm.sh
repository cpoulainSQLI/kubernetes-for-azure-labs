#!/usr/bin/env bash
# The lab VM side of course up: makes sure that the kit is cloned in ~/aro-k8s-course, that the
# course command is on the PATH, that kubectl and kind complete with Tab in bash, and that VS Code
# recommends the Kubernetes extension in ~/work. course up sends this script over SSH with the clone
# URL as its only argument. cloud-init clones the kit on the first boot (setup/infra/cloud-init.yaml),
# so this is usually a check that finds everything in place. It never pulls: course update does that.
# It runs on every course up, so lab VMs created before a change here get it too.
set -euo pipefail

url="${1:?usage: kit-on-vm.sh CLONE_URL}"
kit_dir="${HOME}/aro-k8s-course"
launcher="/usr/local/bin/course"

if [[ -d "${kit_dir}/.git" ]]; then
  echo "The kit is cloned in ~/aro-k8s-course. Update it on the lab VM with: course update"
elif [[ -e "$kit_dir" ]]; then
  echo "${kit_dir} exists on the lab VM but is not a Git clone. Move it away, then run course up again." >&2
  exit 3
else
  echo "Cloning the kit into ~/aro-k8s-course from ${url}"
  git clone --quiet "$url" "$kit_dir"
fi

if [[ ! -x "$launcher" ]]; then
  # A launcher rather than a link, so that course runs even if Git did not keep its executable bit.
  printf '#!/usr/bin/env bash\nexec bash "%s/course" "$@"\n' "$kit_dir" | sudo tee "$launcher" >/dev/null
  sudo chmod 0755 "$launcher"
  echo "The course command is now on the PATH of the lab VM."
fi

# Tab completion for kubectl and kind in bash. bash-completion loads the files of /etc/bash_completion.d in
# every new shell. The files are written again only when the installed version of a tool completes differently.
if [[ ! -f /usr/share/bash-completion/bash_completion ]]; then
  echo "Installing bash-completion on the lab VM"
  # Completion is a comfort, so a failed installation does not stop course up.
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq bash-completion >/dev/null \
    || echo "Could not install bash-completion. Tab completion stays off until course up installs it." >&2
fi
for tool in kubectl kind; do
  command -v "$tool" >/dev/null 2>&1 || continue
  target="/etc/bash_completion.d/${tool}"
  if ! "$tool" completion bash | cmp -s - "$target"; then
    "$tool" completion bash | sudo tee "$target" >/dev/null
    sudo chmod 0644 "$target"
    echo "Tab completes ${tool} commands in new shells on the lab VM."
  fi
done

# VS Code offers the extensions of .vscode/extensions.json when it opens a folder. The Kubernetes extension
# completes and checks manifests, and brings the YAML extension it needs. A file you changed stays as it is.
vscode_dir="${HOME}/work/.vscode"
if [[ ! -e "${vscode_dir}/extensions.json" ]]; then
  mkdir -p "$vscode_dir"
  printf '{\n  "recommendations": ["ms-kubernetes-tools.vscode-kubernetes-tools"]\n}\n' >"${vscode_dir}/extensions.json"
  echo "VS Code recommends the Kubernetes extension when you open ~/work on the lab VM."
fi
