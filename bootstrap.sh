#!/usr/bin/env bash
# ==============================================================================
# gpu-setup bootstrap
#
# Detects installed GPUs via lspci, prints a plan, and (with --yes) runs:
#   1. scripts/common/setup_prereqs.sh
#   2. The matching vendor setup (nvidia or amd)
#
# Default mode is DRY-RUN: it shows what it would do and exits. Pass --yes to
# actually install. This is intentional — many cloud GPU images already have
# a working driver/CUDA/ROCm stack and we don't want to clobber them.
#
# Usage:
#   sudo ./bootstrap.sh                   # dry-run: detect + print plan
#   sudo ./bootstrap.sh --yes             # run common prereqs + vendor setup
#   sudo ./bootstrap.sh --yes --skip-common
#   sudo ./bootstrap.sh --yes --vendor nvidia   # override auto-detect
#
# Env vars are forwarded to the vendor scripts (CUDA_VERSION, ROCM_VERSION,
# FORCE_REINSTALL, PYTHON_VERSION, ...).
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/lib/common.sh
source "${SCRIPT_DIR}/scripts/lib/common.sh"

ASSUME_YES=0
SKIP_COMMON=0
VENDOR_OVERRIDE=""

while [ $# -gt 0 ]; do
  case "$1" in
    --yes|-y)         ASSUME_YES=1; shift ;;
    --skip-common)    SKIP_COMMON=1; shift ;;
    --vendor)         VENDOR_OVERRIDE="$2"; shift 2 ;;
    -V|--version)     print_version; exit 0 ;;
    -h|--help)
      sed -n '2,25p' "$0"
      exit 0
      ;;
    *) die "Unknown argument: $1" ;;
  esac
done

if [ "$ASSUME_YES" -eq 1 ]; then need_root; fi

# ---------- Detect ----------
NV_COUNT="$(count_gpus_by_vendor 10de)"
AMD_COUNT="$(count_gpus_by_vendor 1002)"

log "GPU detection (via lspci):"
log "  NVIDIA GPUs : $NV_COUNT"
log "  AMD GPUs    : $AMD_COUNT"

if [ -n "$VENDOR_OVERRIDE" ]; then
  VENDOR="$VENDOR_OVERRIDE"
elif [ "$NV_COUNT" -gt 0 ] && [ "$AMD_COUNT" -eq 0 ]; then
  VENDOR="nvidia"
elif [ "$AMD_COUNT" -gt 0 ] && [ "$NV_COUNT" -eq 0 ]; then
  VENDOR="amd"
elif [ "$NV_COUNT" -eq 0 ] && [ "$AMD_COUNT" -eq 0 ]; then
  die "No NVIDIA or AMD GPUs detected. Pass --vendor to override if you know better."
else
  die "Both NVIDIA and AMD GPUs detected. Pass --vendor nvidia|amd to choose."
fi

ok "Vendor: $VENDOR"

# ---------- Show detail ----------
if [ "$VENDOR" = "nvidia" ]; then
  log "NVIDIA hardware (lspci):"
  lspci -nn | grep -i 'nvidia' | sed 's/^/    /'
  HAS_NVSWITCH=$(lspci 2>/dev/null | grep -ci 'nvswitch' || true)
  log "  NVSwitches: $HAS_NVSWITCH"
else
  log "AMD hardware (lspci):"
  lspci -nn | grep -i 'amd\|advanced micro' | grep -E '\[(0300|0302|0380|1200)\]' | sed 's/^/    /'
fi

# ---------- Plan ----------
PLAN=()
[ "$SKIP_COMMON" -eq 0 ] && PLAN+=("scripts/common/setup_prereqs.sh")
PLAN+=("scripts/${VENDOR}/setup_$( [ "$VENDOR" = "amd" ] && echo "amd_rocm" || echo "nvidia" ).sh")

echo
log "Planned steps:"
for step in "${PLAN[@]}"; do log "  - $step"; done
log "Verify (run after reboot): scripts/${VENDOR}/verify_$( [ "$VENDOR" = "amd" ] && echo "amd" || echo "nvidia" ).sh"

if [ "$ASSUME_YES" -ne 1 ]; then
  echo
  warn "Dry-run mode (no --yes). Re-run with --yes to execute."
  exit 0
fi

# ---------- Execute ----------
for step in "${PLAN[@]}"; do
  echo
  log "=== Running: $step ==="
  bash "${SCRIPT_DIR}/${step}"
done

echo
ok "Bootstrap complete. Reboot and run the verify script:"
echo "    sudo reboot"
echo "    sudo ${SCRIPT_DIR}/scripts/${VENDOR}/verify_$( [ "$VENDOR" = "amd" ] && echo "amd" || echo "nvidia" ).sh"
