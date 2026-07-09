#!/usr/bin/env bash
# Shared helpers for gpu-setup scripts.
# Source this file:  source "$(dirname "$0")/../lib/common.sh"

set -euo pipefail

# ---------- Logging ----------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
err()  { printf '\033[1;31m[ERR]\033[0m %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

# ---------- Privilege ----------
need_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    die "Must run as root (use sudo)."
  fi
}

# Original invoking user when run via sudo, falls back to current user.
real_user() {
  echo "${SUDO_USER:-${USER:-$(id -un)}}"
}

# ---------- OS ----------
require_ubuntu_2204_plus() {
  local ver major minor
  ver=$(. /etc/os-release && echo "$VERSION_ID")
  major="${ver%%.*}"
  minor="${ver##*.}"
  if [ "$major" -lt 22 ] || { [ "$major" -eq 22 ] && [ "$minor" -lt 4 ]; }; then
    die "Ubuntu 22.04 or later required; detected $ver."
  fi
  if [ "$ver" != "24.04" ]; then
    warn "Scripts are developed on Ubuntu 24.04; detected $ver. Some apt sources may use a different codename."
  fi
}

# ---------- SecureBoot ----------
secure_boot_enabled() {
  command -v mokutil >/dev/null 2>&1 || return 1
  mokutil --sb-state 2>/dev/null | grep -qi 'enabled'
}

# ---------- GPU detection ----------
# Counts via lspci. Echos count; exit code reflects whether any were found.
count_nvidia_gpus() {
  lspci -nn 2>/dev/null | grep -Eci 'VGA|3D|Display' | grep -ci 'nvidia' 2>/dev/null || true
  # The above is conservative; use the simpler vendor-id form below.
}

# Robust vendor counting via PCI vendor IDs.
#   NVIDIA vendor: 10de
#   AMD    vendor: 1002
# Classes covered:
#   0300 VGA, 0302 3D, 0380 Display — traditional GPU classes
#   1200 Processing accelerators     — AMD Instinct MI300X and similar HPC GPUs
count_gpus_by_vendor() {
  local vendor="$1"
  lspci -nn 2>/dev/null \
    | grep -E '\[(0300|0302|0380|1200)\]' \
    | grep -ci "\\[${vendor}:" || true
}

# Detect AMD GPU sub-family for image tag selection.
# Returns "mi35x" (MI355X/MI350X), "mi30x" (MI300X/MI308X), or "unknown".
# MI355X PCI device: 0x75a3  |  MI300X PCI device: 0x74a0/0x74a1
amd_gpu_family() {
  local ids
  ids=$(lspci -nn 2>/dev/null | grep '\[1002:' | grep -oE '\[1002:[0-9a-f]+\]' | sort -u)
  if echo "$ids" | grep -qE '\[1002:75'; then
    echo "mi35x"
  elif echo "$ids" | grep -qE '\[1002:74'; then
    echo "mi30x"
  else
    echo "unknown"
  fi
}

# ---------- Version ----------
# Repo root, computed relative to this file's own location (scripts/lib/),
# so it resolves correctly regardless of which script sourced us.
_COMMON_SH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${_COMMON_SH_DIR}/../.." && pwd)"

print_version() {
  if [ -f "${REPO_ROOT}/VERSION" ]; then
    cat "${REPO_ROOT}/VERSION"
  else
    echo "unknown"
  fi
}

# ---------- Command checks ----------
have() { command -v "$1" >/dev/null 2>&1; }

# Returns 0 if a command exists AND a simple smoke test succeeds.
smoke() {
  local cmd="$1"; shift
  have "$cmd" || return 1
  "$cmd" "$@" >/dev/null 2>&1
}
