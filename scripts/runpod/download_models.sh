#!/usr/bin/env bash
# Download all three inference models to /workspace with XET disabled.
#
# XET (HF_XET_HIGH_PERFORMANCE) stores blobs as CAS chunks that require
# reconstruction on read — which fails during vLLM model loading. This script
# forces standard HTTP download so blobs land as plain safetensors files.
#
# Usage:
#   bash download_models.sh              # download all three models
#   bash download_models.sh gpt-oss-120b # single model by short name
#
# Logs: /workspace/logs/dl_<model>.log
# Requires: hf auth login   (run once to authenticate with HuggingFace)

set -euo pipefail

source /workspace/gpu-env.sh   # sets HF_HOME, activates venv, etc.
unset HF_XET_HIGH_PERFORMANCE
export HF_HUB_DISABLE_XET=1   # force plain safetensors download

LOG_DIR="/workspace/logs"
mkdir -p "$LOG_DIR"

download_model() {
  local name="$1" hf_id="$2"
  local log="${LOG_DIR}/dl_${name}.log"
  echo "[$(date)] Starting download: $hf_id -> $log"
  {
    echo "START $(date)"
    echo "HF_HOME=$HF_HOME"
    echo "HF_HUB_DISABLE_XET=$HF_HUB_DISABLE_XET"
    hf download "$hf_id"
    echo "DONE $(date)"
  } >> "$log" 2>&1
  echo "[$(date)] Done: $name"
}

# Map short names to HuggingFace repo IDs.
declare -A MODEL_IDS=(
  [qwen3-next-80b]="Qwen/Qwen3-Next-80B-A3B-Instruct-FP8"
  [gpt-oss-120b]="openai/gpt-oss-120b"
  [kimi-k2.6]="nvidia/Kimi-K2.6-NVFP4"
)

# Download requested models (all three if no args given).
TARGETS=("${@:-qwen3-next-80b gpt-oss-120b}")   # kimi excluded by default (595 GB)
if [ "$#" -gt 0 ]; then
  TARGETS=("$@")
fi

for name in "${TARGETS[@]}"; do
  hf_id="${MODEL_IDS[$name]:-}"
  if [ -z "$hf_id" ]; then
    echo "Unknown model '$name'. Valid names: ${!MODEL_IDS[*]}"
    exit 1
  fi
  download_model "$name" "$hf_id"
done

echo "[$(date)] All downloads complete."
echo "Run hf cache ls to verify."
