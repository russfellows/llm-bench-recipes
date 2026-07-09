#!/usr/bin/env bash
# Read-only sweep progress monitor — safe to run anytime against a live or
# finished sweep; never touches the sweep itself.
#
# Usage: monitor_sweep.sh <results_dir> [log_file] [total_combos]
#   results_dir   - a recipes/run_recipe.sh results dir (contains provenance.json)
#   log_file      - defaults to <results_dir>/../../../../logs/<model>_full_sweep.log
#                    if omitted, falls back to searching /workspace/logs/*.log
#   total_combos  - defaults to len(tp) * len(isl_osl) * len(conc) from
#                    provenance.json's sweep matrix, when provenance.json exists
#                    and jq is available
set -u
RESULTS_DIR="${1:?usage: monitor_sweep.sh <results_dir> [log_file] [total_combos]}"
LOG_FILE="${2:-}"
TOTAL="${3:-}"
PROVENANCE="$RESULTS_DIR/provenance.json"

if [ -z "$LOG_FILE" ]; then
  model_name=$(jq -r '.model_name // empty' "$PROVENANCE" 2>/dev/null)
  if [ -n "$model_name" ]; then
    guess="/workspace/logs/${model_name}_full_sweep.log"
    [ -f "$guess" ] && LOG_FILE="$guess"
  fi
  LOG_FILE="${LOG_FILE:?could not infer log_file — pass it explicitly}"
fi

if [ -z "$TOTAL" ] && [ -f "$PROVENANCE" ] && command -v jq >/dev/null 2>&1; then
  TOTAL=$(jq -r '(.sweep.tp | length) * (.sweep.isl_osl | length) * (.sweep.conc | length)' "$PROVENANCE" 2>/dev/null || echo "")
fi

n_done=$(find "$RESULTS_DIR" -maxdepth 1 -name '*.json' ! -name 'provenance.json' 2>/dev/null | wc -l)

current_srv=$(grep -F -- "==== Starting server:" "$LOG_FILE" 2>/dev/null | tail -1)
current_bench=$(grep -F -- "---- Bench:" "$LOG_FILE" 2>/dev/null | tail -1)
last_ok=$(grep -E -- "^\[OK\]|Sweep complete" "$LOG_FILE" 2>/dev/null | tail -1)

start_epoch=$(date -d "$(stat -c '%y' "$RESULTS_DIR"/provenance.json 2>/dev/null | cut -d. -f1)" +%s 2>/dev/null || echo "")
now_epoch=$(date +%s)

echo "=== Sweep Progress: $(basename "$RESULTS_DIR") ==="
echo "Results dir : $RESULTS_DIR"
echo "Log file    : $LOG_FILE"
echo
if [ -n "$TOTAL" ]; then
  echo "Combos done : $n_done / $TOTAL"
else
  echo "Combos done : $n_done"
fi
echo "Current srv : ${current_srv:-<none yet>}"
echo "Current run : ${current_bench:-<none yet>}"
[ -n "$last_ok" ] && echo "Last status : $last_ok"

if [ -n "$start_epoch" ] && [ "$n_done" -gt 0 ] && [ -n "$TOTAL" ]; then
  elapsed=$(( now_epoch - start_epoch ))
  rate=$(( elapsed / n_done ))
  remaining=$(( TOTAL - n_done ))
  eta_sec=$(( rate * remaining ))
  printf "Elapsed     : %dh%02dm\n" $((elapsed/3600)) $(((elapsed%3600)/60))
  printf "Avg/combo   : %dm%02ds\n" $((rate/60)) $((rate%60))
  printf "Est. remain : %dh%02dm (rough — pace varies a lot by shape/TP)\n" $((eta_sec/3600)) $(((eta_sec%3600)/60))
fi
echo
echo "tail -f \"$LOG_FILE\""
