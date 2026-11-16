#!/usr/bin/env bash
# The lab VM side of course up: makes sure that the kit is cloned in ~/aro-k8s-course and that the
# course command is on the PATH. course up sends this script over SSH with the clone URL as its only
# argument. cloud-init does the same on the first boot (setup/infra/cloud-init.yaml), so this is
# usually a check that finds everything in place. It never pulls: course update does that.
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
