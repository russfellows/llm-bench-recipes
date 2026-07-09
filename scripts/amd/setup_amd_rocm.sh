#!/usr/bin/env bash
# ==============================================================================
# AMD ROCm setup for Instinct MI300X / MI3xx class GPUs.
# Target: Ubuntu 24.04 (noble).
#
# Detection-first:
#   - If rocm-smi reports healthy GPUs AND hipcc works AND /opt/rocm version
#     matches ROCM_VERSION (or any version when ROCM_VERSION=auto), the script
#     exits without modifying the system. Many cloud images ship a working
#     ROCm stack — do not break them.
#
# Env vars:
#   ROCM_VERSION       e.g. "7.2.4". Default: 7.2.4
#                      Set to "auto" to accept whatever is installed.
#   ROCM_DEB_BUILD     amdgpu-install deb build suffix. Default: 7.2.4.70204-1
#   FORCE_REINSTALL    "1" to install even if detection passes.
#   ASSUME_YES         "1" for non-interactive apt (default).
#
# Reboot is required after install. Run scripts/amd/verify_amd.sh after.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

ROCM_VERSION="${ROCM_VERSION:-7.2.3}"
ROCM_DEB_BUILD="${ROCM_DEB_BUILD:-7.2.3.60203-1}"
FORCE_REINSTALL="${FORCE_REINSTALL:-0}"
ASSUME_YES="${ASSUME_YES:-1}"
[ "$ASSUME_YES" = "1" ] && export DEBIAN_FRONTEND=noninteractive

need_root
require_ubuntu_2204_plus

REAL_USER="$(real_user)"

# ---------- Pre-flight ----------
log "Pre-flight checks..."
if secure_boot_enabled; then
  die "SecureBoot is ENABLED. Disable it in BIOS before installing amdgpu DKMS."
fi
ok "SecureBoot disabled."

AMD_COUNT="$(count_gpus_by_vendor 1002)"
if [ "$AMD_COUNT" -eq 0 ]; then
  die "No AMD GPUs detected via lspci. Wrong vendor script?"
fi
ok "Detected $AMD_COUNT AMD GPU(s) via lspci."

# ---------- Detection: skip if already healthy ----------
rocm_stack_healthy() {
  smoke rocm-smi || return 1
  [ -x /opt/rocm/bin/hipcc ] || return 1
  /opt/rocm/bin/hipcc --version >/dev/null 2>&1 || return 1
  if [ "$ROCM_VERSION" != "auto" ]; then
    local got=""
    if [ -f /opt/rocm/.info/version ]; then
      got=$(cut -d'-' -f1 </opt/rocm/.info/version)
    fi
    [ "$got" = "$ROCM_VERSION" ] || return 1
  fi
  return 0
}

if [ "$FORCE_REINSTALL" != "1" ] && rocm_stack_healthy; then
  ok "ROCm stack appears healthy. Skipping install. Set FORCE_REINSTALL=1 to override."
  # Still ensure group membership even if we skip the install.
  log "Ensuring $REAL_USER is in render,video groups..."
  usermod -a -G render,video "$REAL_USER"
  ok "Group membership confirmed. Changes take effect on next login."
  exit 0
fi

# ---------- Repository hygiene + kernel pin ----------
log "Holding kernel image/header packages to current versions..."
apt-mark hold linux-image-generic linux-headers-generic || true

log "Clearing stale Radeon/ROCm apt configs..."
rm -f /etc/apt/sources.list.d/amdgpu.list \
      /etc/apt/sources.list.d/rocm.list \
      /etc/apt/preferences.d/rocm-pin-600

# ---------- amdgpu-install bootstrap ----------
UBUNTU_CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
DEB_URL="https://repo.radeon.com/amdgpu-install/${ROCM_VERSION}/ubuntu/${UBUNTU_CODENAME}/amdgpu-install_${ROCM_DEB_BUILD}_all.deb"
log "Downloading amdgpu-install: $DEB_URL"
tmp="$(mktemp -d)"
wget -nv -O "$tmp/amdgpu-install.deb" "$DEB_URL"
apt-get -y install "$tmp/amdgpu-install.deb"
rm -rf "$tmp"

log "Refreshing AMD GPG key..."
install -d -m 0755 /etc/apt/keyrings
wget -qO - https://repo.radeon.com/rocm/rocm.gpg.key \
  | gpg --dearmor \
  | tee /etc/apt/keyrings/rocm.gpg >/dev/null
apt-get update

# ---------- Purge stale ROCm builds ----------
log "Purging any previous ROCm framework install..."
amdgpu-install -y --uninstall || true
apt-get -y autoremove --purge
rm -rf /opt/rocm-6.* /opt/rocm

# ---------- Install kernel headers + ROCm ----------
log "Installing kernel headers and extra modules for $(uname -r)..."
apt-get -y install "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"

log "Running amdgpu-install --usecase=dkms,rocm..."
amdgpu-install -y --usecase=dkms,rocm

# ---------- User permissions + ldconfig ----------
log "Adding $REAL_USER to render,video groups..."
usermod -a -G render,video "$REAL_USER"

log "Configuring ldconfig for /opt/rocm libs..."
printf '/opt/rocm/lib\n/opt/rocm/lib64\n' > /etc/ld.so.conf.d/rocm.conf
ldconfig

cat <<EOF

==============================================================================
 AMD ROCm install phase complete.
==============================================================================
 A REBOOT is required to load the amdgpu DKMS module.
   sudo reboot
 After reboot, run:
   sudo scripts/amd/verify_amd.sh
==============================================================================
EOF
