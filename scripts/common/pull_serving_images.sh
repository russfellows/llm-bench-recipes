#!/usr/bin/env bash
# ==============================================================================
# Pre-pull the standard inference-engine container images.
#
# Vendor-aware: detects NVIDIA vs AMD via lspci and pulls only the matching
# image set. Detection-first: skips any image already present locally.
#
# Image tags are configurable via env vars (with conservative defaults that
# match images recipes in this repo target). Override per-engine to pin to
# a specific tag.
#
# Env vars (defaults shown):
#   VENDOR              Override auto-detect: "nvidia" | "amd" | "both"
#   VLLM_IMAGE          NVIDIA: vllm/vllm-openai:latest
#   VLLM_ROCM_IMAGE     AMD:    vllm/vllm-openai-rocm:latest
#   TRITON_IMAGE        NVIDIA: nvcr.io/nvidia/tritonserver:25.06-py3
#   TRTLLM_IMAGE        NVIDIA: nvcr.io/nvidia/tensorrt-llm/release:latest
#   SGLANG_IMAGE        NVIDIA: lmsysorg/sglang:latest
#   SGLANG_ROCM_IMAGE   AMD:    auto-selected by GPU family (mi35x or mi30x);
#                               override to pin a specific tag
#   ATOM_IMAGE          AMD:    (gated repo) — only pulled if INCLUDE_ATOM=1
#   INCLUDE_ATOM        "1" to pull ATOM image (requires repo access)
#   DRY_RUN             "1" to print what would be pulled and exit
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

VENDOR="${VENDOR:-}"
DRY_RUN="${DRY_RUN:-0}"
INCLUDE_ATOM="${INCLUDE_ATOM:-0}"

VLLM_IMAGE="${VLLM_IMAGE:-vllm/vllm-openai:latest}"
VLLM_ROCM_IMAGE="${VLLM_ROCM_IMAGE:-vllm/vllm-openai-rocm:latest}"
TRITON_IMAGE="${TRITON_IMAGE:-nvcr.io/nvidia/tritonserver:25.06-py3}"
TRTLLM_IMAGE="${TRTLLM_IMAGE:-nvcr.io/nvidia/tensorrt-llm/release:latest}"
SGLANG_IMAGE="${SGLANG_IMAGE:-lmsysorg/sglang:latest}"
ATOM_IMAGE="${ATOM_IMAGE:-}"

# SGLang AMD: auto-select by GPU family if caller did not override.
# Tags follow the pattern: lmsysorg/sglang:<version>-rocm<major><minor>-<family>
# Latest as of 2026-06: v0.5.13.post1
if [ -z "${SGLANG_ROCM_IMAGE:-}" ]; then
  _AMD_FAMILY="$(amd_gpu_family)"
  case "$_AMD_FAMILY" in
    mi35x)  SGLANG_ROCM_IMAGE="lmsysorg/sglang:v0.5.13.post1-rocm720-mi35x" ;;
    mi30x)  SGLANG_ROCM_IMAGE="lmsysorg/sglang:v0.5.13.post1-rocm720-mi30x" ;;
    *)      SGLANG_ROCM_IMAGE="lmsysorg/sglang:v0.5.13.post1-rocm720-mi35x"
            warn "Unknown AMD GPU family; defaulting SGLang image to mi35x tag." ;;
  esac
  log "Auto-selected SGLang ROCm image for $_AMD_FAMILY: $SGLANG_ROCM_IMAGE"
fi

if ! have docker; then
  die "docker is not installed. Run scripts/common/setup_docker.sh first."
fi
docker info >/dev/null 2>&1 || die "docker daemon not reachable. Run as a user in the 'docker' group or with sudo."

# ---------- Detect vendor ----------
if [ -z "$VENDOR" ]; then
  NV=$(count_gpus_by_vendor 10de)
  AMD=$(count_gpus_by_vendor 1002)
  if [ "$NV" -gt 0 ] && [ "$AMD" -eq 0 ]; then VENDOR="nvidia"
  elif [ "$AMD" -gt 0 ] && [ "$NV" -eq 0 ]; then VENDOR="amd"
  elif [ "$NV" -gt 0 ] && [ "$AMD" -gt 0 ]; then VENDOR="both"
  else die "No NVIDIA or AMD GPUs detected. Set VENDOR=nvidia|amd|both to override."
  fi
fi
log "Vendor: $VENDOR"

# ---------- Build pull list ----------
declare -a IMAGES
case "$VENDOR" in
  nvidia)
    IMAGES=("$VLLM_IMAGE" "$TRITON_IMAGE" "$TRTLLM_IMAGE" "$SGLANG_IMAGE")
    ;;
  amd)
    IMAGES=("$VLLM_ROCM_IMAGE" "$SGLANG_ROCM_IMAGE")
    [ "$INCLUDE_ATOM" = "1" ] && [ -n "$ATOM_IMAGE" ] && IMAGES+=("$ATOM_IMAGE")
    [ "$INCLUDE_ATOM" = "1" ] && [ -z "$ATOM_IMAGE" ] && \
      warn "INCLUDE_ATOM=1 but ATOM_IMAGE is unset — skipping."
    ;;
  both)
    IMAGES=("$VLLM_IMAGE" "$TRITON_IMAGE" "$TRTLLM_IMAGE" "$SGLANG_IMAGE" \
            "$VLLM_ROCM_IMAGE" "$SGLANG_ROCM_IMAGE")
    [ "$INCLUDE_ATOM" = "1" ] && [ -n "$ATOM_IMAGE" ] && IMAGES+=("$ATOM_IMAGE")
    ;;
  *) die "Unknown VENDOR: $VENDOR" ;;
esac

# ---------- Plan ----------
log "Image plan:"
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then
    printf "  %-60s  %s\n" "$img" "PRESENT (skip)"
  else
    printf "  %-60s  %s\n" "$img" "WILL PULL"
  fi
done

if [ "$DRY_RUN" = "1" ]; then
  echo
  warn "DRY_RUN=1 — exiting without pulling."
  exit 0
fi

# ---------- Pull ----------
fail=0
for img in "${IMAGES[@]}"; do
  if docker image inspect "$img" >/dev/null 2>&1; then continue; fi
  log "Pulling $img ..."
  if ! docker pull "$img"; then
    err "Pull failed: $img"
    fail=$((fail + 1))
  fi
done

if [ "$fail" -gt 0 ]; then
  die "$fail image(s) failed to pull. Check registry access / image tags / authentication."
fi
ok "All required images present."
