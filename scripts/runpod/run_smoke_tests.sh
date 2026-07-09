#!/usr/bin/env bash
# Smoke test runner for RunPod — one test per model, sequential, each with
# its own log file. TP size is derived automatically from each recipe's
# sweep_tp so an invalid configuration can never be launched.
#
# Usage:
#   bash run_smoke_tests.sh                  # all three models
#   bash run_smoke_tests.sh gpt-oss-120b     # single model
#
# Logs:    /workspace/logs/smoke_<model>.log
# Results: /workspace/results/<model>/

set -euo pipefail

RESULTS_BASE="/workspace/results"
LOG_DIR="/workspace/logs"
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NGPUS=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l || echo 8)

mkdir -p "$LOG_DIR" "$RESULTS_BASE"
source /workspace/gpu-env.sh
cd "$REPO"

# Return the largest TP from the recipe's sweep_tp that fits on available GPUs.
max_tp_for_recipe() {
  local model="$1" variant="$2"
  uv run --no-project python3 -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib

with open('recipes/${model}/recipe.toml', 'rb') as f:
    r = tomllib.load(f)

# Variant-level defaults take precedence over recipe-level defaults.
tp_list = (r.get('variants', {}).get('${variant}', {}).get('defaults', {}).get('sweep_tp')
           or r.get('recipe', {}).get('defaults', {}).get('sweep_tp', [${NGPUS}]))

valid = [t for t in tp_list if t <= ${NGPUS}]
print(max(valid) if valid else ${NGPUS})
"
}

run_model() {
  local model="$1" variant="$2"
  local tp
  tp=$(max_tp_for_recipe "$model" "$variant")
  local log="${LOG_DIR}/smoke_${model}.log"
  local results_dir="${RESULTS_BASE}/${model}"
  mkdir -p "$results_dir"

  {
    echo "======================================"
    echo "SMOKE TEST: $model / $variant  (tp=$tp / $NGPUS GPUs)"
    echo "START: $(date)"
    echo "======================================"
  } | tee "$log"

  recipes/run_recipe.sh "$model" "$variant" \
    --env runpod --tp "$tp" --shapes 1024,1024 --conc 4 \
    --results-dir "$results_dir" >> "$log" 2>&1
  local rc=$?

  {
    echo "======================================"
    echo "END: $(date) (exit $rc)"
    echo "======================================"
  } >> "$log"

  if [ $rc -eq 0 ]; then
    echo "[OK]   $model (tp=$tp)"
  else
    echo "[FAIL] $model (exit $rc) — see $log"
  fi
  return $rc
}

# Models to test — filter by first arg if provided.
MODELS=(qwen3-next-80b kimi-k2.6 gpt-oss-120b)
if [ "$#" -gt 0 ]; then
  MODELS=("$@")
fi

echo "[$(date)] Starting smoke tests (${NGPUS} GPUs available)"
for model in "${MODELS[@]}"; do
  run_model "$model" nvidia_vllm
done
echo "[$(date)] Done. Logs: $LOG_DIR/smoke_*.log  Results: $RESULTS_BASE"
