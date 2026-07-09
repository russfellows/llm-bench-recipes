#!/usr/bin/env bash
# ==============================================================================
# Docker CE installation for Ubuntu 24.04.
#
# Detection-first: if a working `docker` is already installed, the script just
# ensures the invoking user is in the `docker` group and exits.
#
# On NVIDIA hosts this script also installs/configures nvidia-container-toolkit
# if Docker is being newly installed (the vendor script already handles it when
# Docker was present at that time; this covers the reverse order).
#
# Env vars:
#   ASSUME_YES   "1" for non-interactive apt (default).
#   FORCE_REINSTALL  "1" to skip detection and reinstall anyway.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ASSUME_YES="${ASSUME_YES:-1}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
[ "$ASSUME_YES" = "1" ] && export DEBIAN_FRONTEND=noninteractive

need_root
require_ubuntu_2204_plus

REAL_USER="$(real_user)"

# ---------- Detection ----------
docker_healthy() {
  have docker || return 1
  docker info >/dev/null 2>&1 || return 1
  return 0
}

if [ "$FORCE_REINSTALL" != "1" ] && docker_healthy; then
  ok "Docker already installed: $(docker --version)"
else
  log "Installing Docker CE..."

  # Remove any distro-provided docker.io to avoid two engines.
  if dpkg -s docker.io >/dev/null 2>&1; then
    warn "Removing distro docker.io in favor of upstream docker-ce."
    apt-get -y purge docker.io
    apt-get -y autoremove --purge
  fi

  install -d -m 0755 /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/docker.gpg ]; then
    curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
    chmod a+r /etc/apt/keyrings/docker.gpg
  fi

  UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME} stable
EOF

  apt-get update
  apt-get -y install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

  systemctl enable --now docker
fi

# ---------- Group membership ----------
if id -nG "$REAL_USER" | tr ' ' '\n' | grep -qx docker; then
  ok "User $REAL_USER is already in the 'docker' group."
else
  log "Adding user $REAL_USER to the 'docker' group..."
  usermod -aG docker "$REAL_USER"
  warn "Group change takes effect on next login. For this shell, run:  newgrp docker"
fi

# ---------- NVIDIA container toolkit (if NVIDIA GPUs present and not yet wired) ----------
NV_COUNT="$(count_gpus_by_vendor 10de)"
if [ "$NV_COUNT" -gt 0 ]; then
  if ! dpkg -s nvidia-container-toolkit >/dev/null 2>&1; then
    log "NVIDIA GPUs present and nvidia-container-toolkit is missing — installing."
    install -d -m 0755 /etc/apt/keyrings
    if [ ! -s /etc/apt/keyrings/nvidia-container-toolkit.gpg ]; then
      curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
        | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
    fi
    curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
      | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g' \
      > /etc/apt/sources.list.d/nvidia-container-toolkit.list
    apt-get update
    apt-get -y install nvidia-container-toolkit
    nvidia-ctk runtime configure --runtime=docker
    systemctl restart docker
  else
    ok "nvidia-container-toolkit already installed."
  fi
fi

ok "Docker setup complete."
