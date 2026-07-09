#!/usr/bin/env bash
# ==============================================================================
# Unified recipe runner — loads recipes/<model>/recipe.toml and invokes the
# sweep harness for the requested variant.
#
# Usage:
#   ./run_recipe.sh <model> <variant> [options]
#   ./run_recipe.sh --list
#   ./run_recipe.sh --help
#
# Options:
#   --tp 1,2,4                       Tensor-parallel sizes (comma or space)
#   --shapes "1024,1024 8192,1024"   ISL,OSL pairs (space separated)
#   --conc "4 8 16 32"               Concurrencies (comma or space)
#   --dry-run                        Print the plan and exit
#   --env ENV                        Runtime environment profile (auto-detected if omitted)
#                                    Profiles: baremetal | container | runpod
#   --results-dir PATH               Override results directory
#
# Examples:
#   ./run_recipe.sh gpt-oss-120b amd_atom
#   ./run_recipe.sh qwen3-next-80b nvidia_vllm --tp 4 --shapes "1000,100 5000,500"
#   ./run_recipe.sh qwen3-next-80b nvidia_vllm --env runpod --dry-run
#   ./run_recipe.sh --list
# ==============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_DIR="${SCRIPT_DIR}/../environments"
# shellcheck source=../scripts/lib/common.sh
source "${SCRIPT_DIR}/../scripts/lib/common.sh"

LOADER="${SCRIPT_DIR}/_common/load_recipe.py"
HARNESS="${SCRIPT_DIR}/_common/sweep.sh"

list_recipes() {
  printf "Available recipes:\n\n"
  printf "  %-25s  %s\n" "MODEL" "VARIANTS"
  printf "  %-25s  %s\n" "-----" "--------"
  shopt -s nullglob
  for dir in "${SCRIPT_DIR}"/*/; do
    local model
    model="$(basename "$dir")"
    [ "$model" = "_common" ] && continue
    local toml="${dir}recipe.toml"
    [ -f "$toml" ] || continue
    local variants
    variants=$(uv run --no-project python -c "
try:
    import tomllib
except ImportError:
    import tomli as tomllib
with open('$toml','rb') as f: d = tomllib.load(f)
print(' '.join(sorted(d.get('variants',{}).keys())))
") || variants="(parse error)"
    printf "  %-25s  %s\n" "$model" "$variants"
  done
}

usage() {
  sed -n '4,22p' "$0"
}

if [ "$#" -eq 0 ]; then usage; exit 1; fi
case "$1" in
  -h|--help)     usage; exit 0 ;;
  -V|--version)  print_version; exit 0 ;;
  --list)        list_recipes; exit 0 ;;
esac

MODEL="${1:-}"; shift || true
VARIANT="${1:-}"; shift || true

if [ -z "$MODEL" ] || [ -z "$VARIANT" ]; then
  err "Usage: $0 <model> <variant> [options]"
  err "Run '$0 --list' to see what's available."
  exit 1
fi

export RECIPE_TOML="${SCRIPT_DIR}/${MODEL}/recipe.toml"
if [ ! -f "$RECIPE_TOML" ]; then
  err "Recipe TOML not found: $RECIPE_TOML"
  err "Run '$0 --list' to see available recipes."
  exit 1
fi

# CLI overrides become env vars consumed by sweep.sh.
export DRY_RUN="${DRY_RUN:-0}"
_TP=""; _SHAPES=""; _CONC=""; _RESULTS=""; _ENV_OVERRIDE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    --tp)          _TP="${2//,/ }"; shift 2 ;;
    --shapes)      _SHAPES="$2"; shift 2 ;;
    --conc)        _CONC="${2//,/ }"; shift 2 ;;
    --dry-run)     export DRY_RUN=1; shift ;;
    --env)         _ENV_OVERRIDE="$2"; shift 2 ;;
    --results-dir) _RESULTS="$2"; shift 2 ;;
    *) err "Unknown option: $1"; usage; exit 1 ;;
  esac
done
[ -n "$_TP" ]      && export SWEEP_TP="$_TP"
[ -n "$_SHAPES" ]  && export SWEEP_ISL_OSL="$_SHAPES"
[ -n "$_CONC" ]    && export SWEEP_CONC="$_CONC"
[ -n "$_RESULTS" ] && export RESULTS_DIR="$_RESULTS"

# ---------- Environment profile ----------
# Determines NATIVE, SHARED_ROOT, HF_HOME etc. for the target runtime.
# Explicit --env overrides auto-detection; DETECTED_ENV can be pre-set too.
_load_env_profile() {
  local name="$1"
  local profile="${ENV_DIR}/${name}.sh"
  if [ ! -f "$profile" ]; then
    err "Unknown environment '${name}'. Available: $(find "${ENV_DIR}" -maxdepth 1 -name '*.sh' -print0 2>/dev/null | xargs -0n1 basename | sed 's/\.sh$//' | tr '\n' ' ')"
    exit 1
  fi
  # shellcheck disable=SC1090
  source "$profile"
  log "Environment: ${name} (NATIVE=${NATIVE:-0}, SHARED_ROOT=${SHARED_ROOT:-/mnt/data})"
}

if [ -n "$_ENV_OVERRIDE" ]; then
  _load_env_profile "$_ENV_OVERRIDE"
elif [ -n "${DETECTED_ENV:-}" ]; then
  _load_env_profile "$DETECTED_ENV"
else
  # Auto-detect.
  # shellcheck source=../environments/detect.sh
  source "${ENV_DIR}/detect.sh"
  _load_env_profile "$DETECTED_ENV"
fi

log "Loading recipe: $MODEL / $VARIANT"
# Pull bash assignments from the TOML into this shell.
RECIPE_VARS=$(uv run --no-project "$LOADER" "$RECIPE_TOML" "$VARIANT")
# shellcheck disable=SC1090
eval "$RECIPE_VARS"

# Load the harness and run.
# shellcheck source=_common/sweep.sh
source "$HARNESS"
run_sweep
