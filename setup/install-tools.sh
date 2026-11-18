#!/usr/bin/env bash
# Installs the tools of the course on Ubuntu or Debian: Docker Engine, kubectl, kind and a few small tools.
# Runs as root. On a Linux machine, ./course up runs it with sudo after listing what it installs and asking.
# In the course's WSL distribution, cloud-init runs it at the first start (setup/cloud-init.yaml).
#   sudo bash setup/install-tools.sh USER
# USER is added to the docker group. Safe to run twice.
# Keep KIND_VERSION and KUBECTL_MINOR in line with lib/lib.sh, lib/lib.ps1 and labs/02-kubernetes-core/kind-cluster.yaml.
set -euo pipefail

TARGET_USER="${1:?usage: install-tools.sh USER}"
KIND_VERSION="v0.33.0"
KUBECTL_MINOR="v1.37"

if [[ "$(id -u)" != "0" ]]; then
  echo "Run this script as root, for example with sudo." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive
# shellcheck source=/dev/null
DISTRO_ID="$(. /etc/os-release && echo "$ID")"
# shellcheck source=/dev/null
CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
ARCH="$(dpkg --print-architecture)"
case "$DISTRO_ID" in
  ubuntu | debian) ;;
  *)
    echo "This script installs on Ubuntu or Debian only, and this is ${DISTRO_ID}." >&2
    exit 1
    ;;
esac

echo "Installing the small tools from ${DISTRO_ID}"
apt-get update
# python3-yaml: the validator of lab 2 reads YAML files with it.
apt-get install -y ca-certificates curl gnupg jq git python3 python3-yaml
install -d -m 0755 /etc/apt/keyrings

echo "Adding the Docker apt repository"
curl -fsSL "https://download.docker.com/linux/${DISTRO_ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
printf '%s\n' \
  "Types: deb" \
  "URIs: https://download.docker.com/linux/${DISTRO_ID}" \
  "Suites: ${CODENAME}" \
  "Components: stable" \
  "Architectures: ${ARCH}" \
  "Signed-By: /etc/apt/keyrings/docker.asc" >/etc/apt/sources.list.d/docker.sources

echo "Adding the Kubernetes apt repository for kubectl ${KUBECTL_MINOR}"
curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/Release.key" |
  gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
chmod a+r /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBECTL_MINOR}/deb/ /" \
  >/etc/apt/sources.list.d/kubernetes.list

echo "Installing Docker Engine and kubectl"
apt-get update
apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin kubectl
usermod -aG docker "$TARGET_USER"

echo "Installing kind ${KIND_VERSION} and checking its checksum"
base_url="https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}"
work="$(mktemp -d)"
curl -fsSLo "${work}/kind" "${base_url}/kind-linux-${ARCH}"
curl -fsSLo "${work}/kind.sha256sum" "${base_url}/kind-linux-${ARCH}.sha256sum"
echo "$(awk '{print $1}' "${work}/kind.sha256sum")  ${work}/kind" | sha256sum -c -
install -m 0755 "${work}/kind" /usr/local/bin/kind
rm -rf "$work"

# kind clusters with several nodes need more inotify watches than Ubuntu allows by default.
printf '%s\n' "fs.inotify.max_user_watches = 524288" "fs.inotify.max_user_instances = 512" >/etc/sysctl.d/90-kind.conf
sysctl --system >/dev/null

echo "docker: $(docker --version)"
echo "kind: $(kind version)"
echo "kubectl: $(kubectl version --client 2>/dev/null | head -n 1)"
echo "Tools installed. ${TARGET_USER} is in the docker group from the next login."
