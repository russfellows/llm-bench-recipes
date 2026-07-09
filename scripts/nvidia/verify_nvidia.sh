#!/usr/bin/env bash
# ==============================================================================
# Post-reboot verification for NVIDIA GPU setup.
# Run after rebooting following setup_nvidia.sh.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

fail=0

log "1. nvidia-smi:"
if nvidia-smi | head -n 20; then ok "nvidia-smi works."; else err "nvidia-smi failed."; fail=1; fi

log "2. nvcc --version:"
if have nvcc; then
  nvcc --version | grep release && ok "nvcc works."
elif [ -x /usr/local/cuda/bin/nvcc ]; then
  /usr/local/cuda/bin/nvcc --version | grep release && \
    warn "nvcc not on PATH — re-source /etc/profile.d/cuda.sh or relogin."
else
  err "nvcc not found."; fail=1
fi

log "3. NVLink Fabric state (NVSwitch systems only):"
HAS_NVSWITCH=$(lspci 2>/dev/null | grep -ci 'nvswitch' || true)
if [ "$HAS_NVSWITCH" -gt 0 ]; then
  if systemctl is-active --quiet nvidia-fabricmanager; then
    ok "nvidia-fabricmanager is active."
  else
    err "nvidia-fabricmanager is NOT active."; fail=1
  fi
  nvidia-smi -q | grep -A1 Fabric | grep State || warn "Could not read Fabric State."
else
  log "No NVSwitches present; skipping fabric checks."
fi

log "4. Container GPU smoke test (skipped if docker missing):"
if have docker; then
  if docker run --rm --runtime=nvidia --gpus all nvidia/cuda:12.4.1-base-ubuntu22.04 nvidia-smi >/dev/null 2>&1; then
    ok "Docker + nvidia runtime works."
  else
    warn "Docker GPU container test failed (may just be a missing image pull permission)."
  fi
else
  log "docker not installed; skipping."
fi

if [ "$fail" -eq 0 ]; then
  ok "All required checks passed."
else
  die "One or more required checks failed."
fi
