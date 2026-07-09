#!/usr/bin/env bash
# ==============================================================================
# NVIDIA driver + CUDA + Fabric Manager + Container Toolkit setup.
# Target: Ubuntu 24.04 with HGX H200 / B200 (or any modern NVIDIA datacenter GPU).
#
# Detection-first:
#   - If nvidia-smi reports healthy GPUs AND nvcc matches CUDA_VERSION (or any
#     CUDA already on PATH when CUDA_VERSION=auto), AND fabric manager is OK
#     when NVSwitches are present, the script exits without modifying the
#     system. Many cloud providers ship working images — do not break them.
#
# Env vars:
#   CUDA_VERSION       e.g. "13-3" (apt suffix form). Default: 13-3
#                      Set to "auto" to accept whatever is installed.
#   FORCE_REINSTALL    "1" to force install even if detection passes.
#   ASSUME_YES         "1" for non-interactive apt (default).
#
# Reboot is required after install. Run scripts/nvidia/verify_nvidia.sh after.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

CUDA_VERSION="${CUDA_VERSION:-13-3}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
ASSUME_YES="${ASSUME_YES:-1}"
[ "$ASSUME_YES" = "1" ] && export DEBIAN_FRONTEND=noninteractive

need_root
require_ubuntu_2204_plus

# ---------- Pre-flight ----------
log "Pre-flight checks..."
if secure_boot_enabled; then
  die "SecureBoot is ENABLED. DKMS modules require signing — disable SecureBoot in BIOS."
fi
ok "SecureBoot disabled."

NV_COUNT="$(count_gpus_by_vendor 10de)"
if [ "$NV_COUNT" -eq 0 ]; then
  die "No NVIDIA GPUs detected via lspci. Wrong vendor script?"
fi
ok "Detected $NV_COUNT NVIDIA GPU(s) via lspci."

HAS_NVSWITCH=$(lspci 2>/dev/null | grep -ci 'nvswitch' || true)
if [ "$HAS_NVSWITCH" -gt 0 ]; then
  log "Detected $HAS_NVSWITCH NVSwitch(es) — Fabric Manager is required."
else
  log "No NVSwitches detected. Fabric Manager will still be installed as a baseline."
fi

# ---------- Detection: skip if already healthy ----------
nvidia_stack_healthy() {
  smoke nvidia-smi || return 1
  # nvcc may not be on root's PATH; check the canonical install path too.
  if have nvcc; then
    nvcc --version >/dev/null 2>&1 || return 1
  elif [ -x /usr/local/cuda/bin/nvcc ]; then
    /usr/local/cuda/bin/nvcc --version >/dev/null 2>&1 || return 1
  else
    return 1
  fi
  if [ "$CUDA_VERSION" != "auto" ]; then
    local want="${CUDA_VERSION//-/.}"
    local got
    got=$( { nvcc --version 2>/dev/null || /usr/local/cuda/bin/nvcc --version; } \
           | grep -oE 'release [0-9]+\.[0-9]+' | awk '{print $2}')
    [ "$got" = "$want" ] || return 1
  fi
  if [ "$HAS_NVSWITCH" -gt 0 ]; then
    systemctl is-active --quiet nvidia-fabricmanager || return 1
  fi
  return 0
}

if [ "$FORCE_REINSTALL" != "1" ] && nvidia_stack_healthy; then
  ok "NVIDIA stack appears healthy. Skipping install. Set FORCE_REINSTALL=1 to override."
  exit 0
fi

# ---------- Kernel headers ----------
log "Installing kernel headers for $(uname -r)..."
apt-get update
apt-get -y install "linux-headers-$(uname -r)"

# ---------- Purge stale NVIDIA packages ----------
log "Purging stale NVIDIA/CUDA packages (if any)..."
PURGE=$(dpkg-query -W -f='${Package}\n' 2>/dev/null \
        | grep -E '^(cuda|nvidia|libnvidia|nsight)' \
        | grep -v '^cuda-keyring' || true)
if [ -n "$PURGE" ]; then
  # shellcheck disable=SC2086
  apt-get -y purge $PURGE
  apt-get -y autoremove --purge
fi
rm -rf /usr/local/cuda*

# ---------- Add CUDA apt repo (cuda-keyring) ----------
log "Adding NVIDIA CUDA apt repository..."
if ! dpkg -s cuda-keyring >/dev/null 2>&1; then
  tmp="$(mktemp -d)"
  wget -nv -O "$tmp/cuda-keyring.deb" \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/x86_64/cuda-keyring_1.1-1_all.deb
  apt-get -y install "$tmp/cuda-keyring.deb"
  rm -rf "$tmp"
fi
apt-get update

# ---------- Add NVIDIA Container Toolkit apt repo ----------
log "Adding NVIDIA Container Toolkit apt repository..."
install -d -m 0755 /etc/apt/keyrings
if [ ! -s /etc/apt/keyrings/nvidia-container-toolkit.gpg ]; then
  curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
    | gpg --dearmor -o /etc/apt/keyrings/nvidia-container-toolkit.gpg
fi
curl -fsSL https://nvidia.github.io/libnvidia-container/stable/deb/nvidia-container-toolkit.list \
  | sed 's#deb https://#deb [signed-by=/etc/apt/keyrings/nvidia-container-toolkit.gpg] https://#g' \
  > /etc/apt/sources.list.d/nvidia-container-toolkit.list
apt-get update

# ---------- Install CUDA toolkit + open driver ----------
log "Installing cuda-toolkit-${CUDA_VERSION} and nvidia-open..."
apt-get -y install "cuda-toolkit-${CUDA_VERSION}" nvidia-open

log "Writing /etc/profile.d/cuda.sh..."
cat >/etc/profile.d/cuda.sh <<'EOF'
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
chmod +x /etc/profile.d/cuda.sh

# ---------- Fabric Manager ----------
log "Installing nvidia-fabricmanager..."
apt-get -y install nvidia-fabricmanager
systemctl enable nvidia-fabricmanager

# ---------- Container Toolkit (if Docker present) ----------
if have docker; then
  log "Configuring NVIDIA Container Toolkit for Docker..."
  apt-get -y install nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
else
  warn "Docker not detected; skipping container toolkit configuration."
  warn "Re-run this script after installing Docker if you need GPU containers."
fi

cat <<EOF

==============================================================================
 NVIDIA install phase complete.
==============================================================================
 A REBOOT is required before verification.
   sudo reboot
 After reboot, run:
   sudo scripts/nvidia/verify_nvidia.sh
==============================================================================
EOF
