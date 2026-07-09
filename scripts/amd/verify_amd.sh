#!/usr/bin/env bash
# ==============================================================================
# Post-reboot verification for AMD ROCm setup.
# Runs rocm-smi, hipcc, and a small HIP compute test.
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

fail=0
CHECK_USER="${SUDO_USER:-${USER:-$(id -un)}}"

log "1. GPU device permissions (render/video groups for $CHECK_USER):"
MISSING_GROUPS=()
for grp in render video; do
  if id -nG "$CHECK_USER" 2>/dev/null | tr ' ' '\n' | grep -qx "$grp"; then
    ok "  $CHECK_USER is in group '$grp'."
  else
    err "  $CHECK_USER is NOT in group '$grp' — amd-smi/rocm-smi will have limited access."
    MISSING_GROUPS+=("$grp")
  fi
done
if [ "${#MISSING_GROUPS[@]}" -gt 0 ]; then
  warn "  Fix: sudo usermod -aG ${MISSING_GROUPS[*]} $CHECK_USER  (then log out and back in)"
  fail=1
fi

log "2. ROCm version:"
if [ -f /opt/rocm/.info/version ]; then
  ok "ROCm $(cat /opt/rocm/.info/version)"
else
  err "/opt/rocm/.info/version missing."; fail=1
fi

log "3. rocm-smi:"
if smoke rocm-smi --showproductname; then
  rocm-smi --showproductname
  ok "rocm-smi works."
else
  err "rocm-smi failed."; fail=1
fi

log "4. HIP compute smoke test (vector add):"
SRC="$(mktemp --suffix=.cpp)"
BIN="$(mktemp -u)"
cat >"$SRC" <<'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void vadd(const float* a, const float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    int nd = 0;
    hipGetDeviceCount(&nd);
    printf("HIP devices detected: %d\n", nd);
    if (nd == 0) return 1;

    const int n = 1 << 20;
    const size_t s = n * sizeof(float);
    float *a, *b, *c;
    hipMallocManaged(&a, s);
    hipMallocManaged(&b, s);
    hipMallocManaged(&c, s);
    for (int i = 0; i < n; i++) { a[i] = 1.5f; b[i] = 2.5f; }

    vadd<<<(n + 255) / 256, 256>>>(a, b, c, n);
    hipDeviceSynchronize();

    double sum = 0.0;
    for (int i = 0; i < n; i++) sum += c[i];
    bool pass = (sum == 4.0 * n);
    printf("HIP vadd verification: %s\n", pass ? "PASS" : "FAIL");

    hipFree(a); hipFree(b); hipFree(c);
    return pass ? 0 : 2;
}
EOF

if [ -x /opt/rocm/bin/hipcc ]; then
  if /opt/rocm/bin/hipcc "$SRC" -o "$BIN" >/dev/null 2>&1 && "$BIN"; then
    ok "HIP compute test passed."
  else
    err "HIP compute test failed."; fail=1
  fi
else
  err "hipcc not found at /opt/rocm/bin/hipcc."; fail=1
fi

rm -f "$SRC" "$BIN"

if [ "$fail" -eq 0 ]; then
  ok "All required checks passed."
else
  die "One or more required checks failed."
fi
