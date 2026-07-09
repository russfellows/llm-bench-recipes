#!/usr/bin/env bash
# ==============================================================================
# Recipe sweep harness.
#
# Sourced by run_recipe.sh after load_recipe.py has eval'd the recipe TOML.
# Provides one entrypoint, `run_sweep`, which:
#   1. Builds the image from EXTRA_BUILD_DOCKERFILE if declared, else pulls
#      IMAGE if not already local.
#   2. Creates a timestamped results dir under $HOME/results/...
#   3. Iterates the (TP) x (ISL,OSL) x (CONC) matrix.
#   4. For each combo: launches a container with the vendor-standard flag
#      bundle + recipe-supplied extras + EXTRA_FILES mounted at @RECIPE_DIR@/,
#      waits for the server, runs the bench client via docker exec, tears
#      the container down.
#   5. Aggregates a summary.csv.
#
# Variables sweep.sh expects (populated by load_recipe.py from the TOML):
#   MODEL_NAME, VARIANT_NAME, VENDOR, STACK, IMAGE, MODEL_ID, RECIPE_DIR
#   SERVER_CMD (array, with @TP@/@ISL@/@OSL@/@CONC@/@RECIPE_DIR@ placeholders)
#   PORT (int)
#   EXTRA_DOCKER_ENV (array, -e KEY=VAL pairs)
#   EXTRA_DOCKER_FLAGS (array)
#   EXTRA_FILES (array — files in RECIPE_DIR to mount at @RECIPE_DIR@/<basename>)
#   Optional: BENCH_TOOL, READY_MARKER, READY_TIMEOUT_S, RANDOM_RANGE_RATIO
#   Optional (when build is declared): EXTRA_BUILD_DOCKERFILE,
#     EXTRA_BUILD_CONTEXT, EXTRA_BUILD_TAG, BASE_IMAGE
#   Sweep defaults: SWEEP_TP_DEFAULT, SWEEP_ISL_OSL_DEFAULT, SWEEP_CONC_DEFAULT
#   Sweep CLI overrides: SWEEP_TP, SWEEP_ISL_OSL, SWEEP_CONC (set by CLI parser)
#
# @RECIPE_DIR@ — use this in server_args/runtime_config_path instead of a
# literal "/recipe" path. In Docker mode it resolves to /recipe (safe as a
# hardcoded path there: every container gets its own private filesystem,
# so no two invocations can collide on it). In native mode there is no
# such isolation — it's all one shared host filesystem — so it resolves to
# a fresh mktemp -d directory, unique per run_sweep() invocation. A
# literal "/recipe" in native mode used to be a real bug: any concurrent
# `run_recipe.sh` invocation on the same host (even a --dry-run, even from
# an unrelated recipe or a completely different clone of this repo) would
# silently repoint that one shared symlink and break whichever sweep was
# actually relying on it mid-run.
# ==============================================================================

# Sourced — don't `set -e` globally; let the caller decide.

_SWEEP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../../scripts/lib/common.sh
source "${_SWEEP_DIR}/../../scripts/lib/common.sh"
# shellcheck source=docker_amd.sh
source "${_SWEEP_DIR}/docker_amd.sh"
# shellcheck source=docker_nvidia.sh
source "${_SWEEP_DIR}/docker_nvidia.sh"
# shellcheck source=bench_client.sh
source "${_SWEEP_DIR}/bench_client.sh"

# Sync any vLLM compile artifacts that landed in the ephemeral home cache
# to the persistent VLLM_CACHE_ROOT. Called after every native server shutdown
# so cache is never lost to a pod restart. cp -rn (no-clobber) is safe to
# call repeatedly — it only copies files that don't already exist at the dest.
_sync_vllm_cache() {
  local _src="${HOME}/.cache/vllm"
  local _dst="${VLLM_CACHE_ROOT:-}"
  if [ -n "$_dst" ] && [ -d "$_src" ]; then
    cp -rn "$_src/." "$_dst/" 2>/dev/null || true
    log "vLLM cache synced to ${_dst}"
  fi
}

_default_ready_marker() {
  case "$1" in
    vllm|sglang|atom|trtllm) echo "Application startup complete" ;;
    triton)                   echo "Started GRPCInferenceService" ;;
    *)                        echo "Application startup complete" ;;
  esac
}

_default_bench_tool() {
  # vllm and atom ship their own bench client, guaranteed present alongside
  # the server itself (it's the same package / image). Every other stack —
  # trtllm today, sglang/triton/anything added later — gets the stack-
  # agnostic OpenAI client by default, since it only needs an HTTP endpoint.
  # A recipe can still override BENCH_TOOL explicitly if it wants a
  # different client for a given variant.
  case "$1" in
    vllm) echo "vllm"   ;;
    atom) echo "atom"   ;;
    *)    echo "openai" ;;
  esac
}

# Resolve an HF repo id to its local snapshot directory, using only the
# local cache (no network). Prints the path on success; prints nothing
# (and returns success anyway — caller checks for an empty string) if the
# model isn't cached, so this is safe to call speculatively.
#
# Why this exists: some serving stacks perform their own HF Hub model
# resolution internally and can attempt a fresh download even when the
# model is already fully cached and HF_HOME/HF_HUB_CACHE are set correctly
# (observed with TRT-LLM's PyTorchLLM backend). Passing a literal local
# directory as the model argument bypasses that resolution path entirely,
# regardless of which stack is serving. This also gives us one consistent,
# predictable place to enforce "never download mid-sweep" — pair with
# HF_HUB_OFFLINE=1 on the server process.
_resolve_local_model_path() {
  local hub_cache="$1" model_id="$2"
  # uv run --no-project (not bare python3) so this reliably sees
  # huggingface_hub from the persistent venv (VIRTUAL_ENV), the same way
  # the native server launch and provenance write below do — a host
  # without huggingface_hub on its system python3 would otherwise degrade
  # silently to "could not resolve" for every combo.
  uv run --no-project python3 - "$hub_cache" "$model_id" <<'PYEOF' 2>/dev/null
import sys
from huggingface_hub import snapshot_download
cache_dir, model_id = sys.argv[1], sys.argv[2]
try:
    print(snapshot_download(model_id, cache_dir=cache_dir, local_files_only=True))
except Exception:
    pass
PYEOF
}

_require_var() {
  local n="$1"
  if [ -z "${!n:-}" ]; then
    err "Required variable '$n' not set."
    return 1
  fi
}

# Substitute @TP@, @ISL@, @OSL@, @CONC@, @RECIPE_DIR@ in an array.
_subst_placeholders() {
  local tp="$1" isl="$2" osl="$3" conc="$4" recipe_dir="$5"; shift 5
  local x out=()
  for x in "$@"; do
    x="${x//@TP@/$tp}"
    x="${x//@ISL@/$isl}"
    x="${x//@OSL@/$osl}"
    x="${x//@CONC@/$conc}"
    x="${x//@RECIPE_DIR@/$recipe_dir}"
    out+=("$x")
  done
  printf '%s\n' "${out[@]}"
}

run_sweep() {
  # ---------- Validate ----------
  for v in MODEL_NAME VARIANT_NAME VENDOR STACK IMAGE MODEL_ID; do
    _require_var "$v" || return 2
  done
  if [ -z "${SERVER_CMD+x}" ] || [ "${#SERVER_CMD[@]}" -eq 0 ]; then
    err "SERVER_CMD array is empty."
    return 2
  fi

  # Pristine copy of the recipe's declared model ID (an HF repo id or a
  # local path). Model-path resolution below may overwrite MODEL_ID with a
  # resolved local path for the bench client's benefit; every resolution
  # must read from this immutable copy, never from MODEL_ID itself, or a
  # sweep with more than one server restart (e.g. the default TP sweep
  # 1,2,4,8) silently resolves against the wrong value after the first
  # restart.
  local MODEL_ID_ORIG="$MODEL_ID"

  # ---------- Resolve sweep matrix (CLI > TOML default > hardcoded fallback) ----------
  : "${SWEEP_TP:=${SWEEP_TP_DEFAULT:-1}}"
  : "${SWEEP_ISL_OSL:=${SWEEP_ISL_OSL_DEFAULT:-1024,1024}}"
  : "${SWEEP_CONC:=${SWEEP_CONC_DEFAULT:-4 8 16 32 64 128 256}}"
  : "${RANDOM_RANGE_RATIO:=0.9}"
  : "${READY_MARKER:=$(_default_ready_marker "$STACK")}"
  : "${READY_TIMEOUT_S:=1800}"
  : "${BENCH_TOOL:=$(_default_bench_tool "$STACK")}"
  : "${PORT:=8000}"
  : "${DRY_RUN:=0}"
  HOST="${HOST:-localhost}"
  NATIVE="${NATIVE:-0}"

  # ---------- Recipe mount directory (@RECIPE_DIR@) ----------
  # Docker mode: /recipe is safe as a hardcoded literal — every container
  # gets its own private filesystem, so no two invocations can collide on
  # it. Native mode has no such isolation (one shared host filesystem), so
  # every invocation gets its own disposable directory instead of a
  # shared, hardcoded path. The mktemp call only runs for a real native
  # run — a --dry-run must never touch the filesystem, and this is
  # computed early (before FILE_MOUNTS below) specifically so it can be
  # gated on DRY_RUN here rather than threading that check through every
  # later use site.
  local RECIPE_MOUNT_DIR="/recipe"
  if [ "$NATIVE" = "1" ] && [ "$DRY_RUN" != "1" ]; then
    RECIPE_MOUNT_DIR="$(mktemp -d /tmp/gpu-setup-recipe.XXXXXX)"
  fi

  IFS=$' \t\n' read -r -a _TP_ARR    <<< "$SWEEP_TP"
  IFS=$' \t\n' read -r -a _ISLOSL_ARR<<< "$SWEEP_ISL_OSL"
  IFS=$' \t\n' read -r -a _CONC_ARR  <<< "$SWEEP_CONC"

  # ---------- Vendor flag bundle ----------
  local -a VENDOR_FLAGS
  case "$VENDOR" in
    amd)    VENDOR_FLAGS=("${AMD_DOCKER_FLAGS[@]}") ;;
    nvidia) VENDOR_FLAGS=("${NVIDIA_DOCKER_FLAGS[@]}") ;;
    *) err "Unknown VENDOR='$VENDOR'"; return 2 ;;
  esac

  # ---------- HF cache mount ----------
  local HF_HOST_DIR="${HF_HOME:-/mnt/data/huggingface}"
  if [ ! -d "$HF_HOST_DIR" ]; then
    if [ "$DRY_RUN" = "1" ]; then
      warn "HF cache dir $HF_HOST_DIR does not exist (would be created on real run)."
    else
      warn "HF cache dir $HF_HOST_DIR does not exist — creating."
      mkdir -p "$HF_HOST_DIR" \
        || die "Could not create $HF_HOST_DIR. Run scripts/common/setup_hf_env.sh first, or set HF_HOME to a writable path."
    fi
  fi
  # Container-side mount point for HF_HOST_DIR. Named so the model-path
  # resolution logic below can translate a host-side snapshot path to its
  # in-container equivalent without duplicating this literal.
  local HF_CONTAINER_DIR="/root/.cache/huggingface"
  local -a HF_MOUNT=(-v "${HF_HOST_DIR}:${HF_CONTAINER_DIR}")

  # ---------- Torch compile cache mount ----------
  # Inductor/cudagraph compilation artifacts are cached under
  # ~/.cache/torch inside the container. Mounting a persistent host
  # directory means compiled graphs survive container restarts, avoiding
  # recompilation on every run (which can take 30+ minutes for large MoE
  # models with use_inductor_graph_partition=true).
  local TORCH_CACHE_HOST="${HF_HOST_DIR}/../torch_compile_cache"
  TORCH_CACHE_HOST="$(cd "$(dirname "$TORCH_CACHE_HOST")" && pwd)/$(basename "$TORCH_CACHE_HOST")"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$TORCH_CACHE_HOST"
    chmod 1777 "$TORCH_CACHE_HOST"
  fi
  local -a TORCH_CACHE_MOUNT=(-v "${TORCH_CACHE_HOST}:/root/.cache/torch")

  local -a HF_TOKEN_ENV=()
  local _hf_token="${HF_TOKEN:-}"
  if [ -z "$_hf_token" ] && [ -f "${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}" ]; then
    _hf_token="$(cat "${HF_TOKEN_PATH:-$HOME/.cache/huggingface/token}")"
  fi
  [ -n "$_hf_token" ] && HF_TOKEN_ENV=(-e "HF_TOKEN=${_hf_token}")

  # ---------- Extra files mount: RECIPE_DIR/<file> -> @RECIPE_DIR@/<basename> ----------
  local -a FILE_MOUNTS=()
  if [ "${#EXTRA_FILES[@]}" -gt 0 ] && [ -n "${RECIPE_DIR:-}" ]; then
    for f in "${EXTRA_FILES[@]}"; do
      local src="${RECIPE_DIR}/${f}"
      local base
      base="$(basename "$f")"
      if [ ! -e "$src" ]; then
        err "extra_files entry not found: $src"
        return 2
      fi
      FILE_MOUNTS+=(-v "${src}:${RECIPE_MOUNT_DIR}/${base}:ro")
    done
  fi

  # ---------- Results dir ----------
  local TS
  TS="$(date +%Y%m%d_%H%M%S)"
  # Default results to /workspace so they survive pod restarts.
  # Fall back to $HOME only if /workspace isn't a persistent volume.
  local _results_base
  if [ -d "/workspace" ] && [ "$(stat -f -c %T /workspace 2>/dev/null || stat -fc %T /workspace 2>/dev/null || echo local)" != "local" ] || [ -f "/workspace/gpu-env.sh" ]; then
    _results_base="/workspace/results"
  else
    local USER_HOME
    USER_HOME="$(getent passwd "${SUDO_USER:-$USER}" | cut -d: -f6)"
    _results_base="${USER_HOME}/results"
  fi
  : "${RESULTS_DIR:=${_results_base}/${MODEL_NAME}/${VARIANT_NAME}/${TS}}"
  if [ "$DRY_RUN" != "1" ]; then
    mkdir -p "$RESULTS_DIR"
  fi
  log "Results dir: $RESULTS_DIR"

  # ---------- Runtime config: materialize the [runtime_config] TOML table as
  # JSON in the results dir, mount it where the server expects it. JSON is
  # valid YAML, so YAML-expecting tools (trtllm-serve etc.) accept it.
  if [ -n "${RUNTIME_CONFIG_JSON:-}" ] && [ -n "${RUNTIME_CONFIG_PATH:-}" ]; then
    RUNTIME_CONFIG_PATH="${RUNTIME_CONFIG_PATH//@RECIPE_DIR@/$RECIPE_MOUNT_DIR}"
    if [ "$DRY_RUN" != "1" ]; then
      printf '%s' "$RUNTIME_CONFIG_JSON" > "${RESULTS_DIR}/runtime_config.json"
      log "Wrote runtime config: ${RESULTS_DIR}/runtime_config.json -> ${RUNTIME_CONFIG_PATH}"
    else
      log "(dry-run) would write runtime config to ${RESULTS_DIR}/runtime_config.json -> ${RUNTIME_CONFIG_PATH}"
    fi
    FILE_MOUNTS+=(-v "${RESULTS_DIR}/runtime_config.json:${RUNTIME_CONFIG_PATH}:ro")
  fi

  # ---------- Native file mounts: simulate Docker -v by symlinking into RECIPE_MOUNT_DIR ----------
  # In Docker mode FILE_MOUNTS is passed to `docker run -v`. In native mode those
  # volume flags are never applied, so trtllm-serve can't find its runtime config
  # file. Replicate the mounts by symlinking each source path into the private,
  # per-invocation RECIPE_MOUNT_DIR computed above (never a hardcoded shared path
  # — see the comment on RECIPE_MOUNT_DIR). Guarded on DRY_RUN too: a --dry-run
  # must never touch the filesystem, and RECIPE_MOUNT_DIR is left at its
  # placeholder value ("/recipe", never created) in that case anyway.
  if [ "$NATIVE" = "1" ] && [ "$DRY_RUN" != "1" ] && [ "${#FILE_MOUNTS[@]}" -gt 0 ]; then
    local _fi=0
    while [ "$_fi" -lt "${#FILE_MOUNTS[@]}" ]; do
      if [ "${FILE_MOUNTS[$_fi]}" = "-v" ]; then
        _fi=$(( _fi + 1 ))
        local _spec="${FILE_MOUNTS[$_fi]}"
        local _src="${_spec%%:*}"
        local _rest="${_spec#*:}"
        local _dst="${_rest%%:*}"
        ln -sfn "$_src" "$_dst" 2>/dev/null || true
      fi
      _fi=$(( _fi + 1 ))
    done
  fi

  # ---------- Build (optional) or pull ----------
  if [ "$NATIVE" = "0" ]; then
    if [ -n "${EXTRA_BUILD_DOCKERFILE:-}" ]; then
      local df_path="${RECIPE_DIR}/${EXTRA_BUILD_DOCKERFILE}"
      local ctx="${RECIPE_DIR}/${EXTRA_BUILD_CONTEXT:-.}"
      if [ ! -f "$df_path" ]; then
        err "Dockerfile not found: $df_path"
        return 2
      fi
      if [ "$DRY_RUN" = "1" ]; then
        log "(dry-run) would build $IMAGE from $df_path"
        if [ -n "${EXTRA_BUILD_ARGS+x}" ] && [ "${#EXTRA_BUILD_ARGS[@]}" -gt 0 ]; then
          log "(dry-run) build args: ${EXTRA_BUILD_ARGS[*]}"
        fi
      elif docker image inspect "$IMAGE" >/dev/null 2>&1; then
        ok "Built image already present: $IMAGE (skipping rebuild)"
      else
        log "Building $IMAGE from $df_path ..."
        docker build -f "$df_path" -t "$IMAGE" \
          ${EXTRA_BUILD_ARGS[@]+"${EXTRA_BUILD_ARGS[@]}"} \
          "$ctx" \
          || { err "Build failed."; return 3; }
      fi
    else
      if [ "$DRY_RUN" = "1" ]; then
        log "(dry-run) would ensure image present: $IMAGE"
      elif ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
        log "Pulling $IMAGE ..."
        docker pull "$IMAGE" || { err "Pull failed."; return 3; }
      fi
    fi
  else
    log "Native mode — skipping image pull/build; running $STACK directly on host."
  fi

  # ---------- Plan ----------
  local total=$(( ${#_TP_ARR[@]} * ${#_ISLOSL_ARR[@]} * ${#_CONC_ARR[@]} ))
  cat <<EOF

==============================================================================
 SWEEP PLAN
==============================================================================
 Model       : $MODEL_ID
 Variant     : $VARIANT_NAME ($VENDOR / $STACK)
 Image       : $IMAGE
 Mode        : $([ "$NATIVE" = "1" ] && echo "native (no container — $STACK direct on host)" || echo "docker")
 TP sizes    : ${_TP_ARR[*]}
 ISL,OSL     : ${_ISLOSL_ARR[*]}
 Concurrency : ${_CONC_ARR[*]}
 Bench tool  : $BENCH_TOOL
 Ready mark  : $READY_MARKER
 Port        : $PORT
 Results     : $RESULTS_DIR
 Combos      : $total
EOF
  [ "${#EXTRA_FILES[@]}" -gt 0 ] && echo " Extra files : ${EXTRA_FILES[*]}  (mounted at ${RECIPE_MOUNT_DIR}/)"
  [ "${#EXTRA_DOCKER_ENV[@]}" -gt 0 ] && echo " Extra env   : ${EXTRA_DOCKER_ENV[*]}"
  echo "=============================================================================="
  echo

  if [ "$DRY_RUN" = "1" ]; then
    log "DRY_RUN=1 — exiting without running."
    return 0
  fi

  # ---------- Provenance ----------
  # Records exact image digest, base image (for builds), build args, sweep
  # matrix, the full recipe.toml content, and host/GPU info. Apples-to-apples
  # result comparisons across runs depend on this.
  if [ "$DRY_RUN" = "1" ]; then
    log "(dry-run) would write ${RESULTS_DIR}/provenance.json"
  else
  # PROV_* vars are env-var prefixes passed to write_provenance.py, not bash variables.
  # shellcheck disable=SC2034,SC2015
  PROV_RESULTS_DIR="$RESULTS_DIR" \
  PROV_TIMESTAMP="$TS" \
  PROV_MODEL_NAME="$MODEL_NAME" \
  PROV_VARIANT_NAME="$VARIANT_NAME" \
  PROV_MODEL_ID="$MODEL_ID" \
  PROV_VENDOR="$VENDOR" \
  PROV_STACK="$STACK" \
  PROV_IMAGE="$IMAGE" \
  PROV_BASE_IMAGE="${BASE_IMAGE:-}" \
  PROV_DOCKERFILE="${EXTRA_BUILD_DOCKERFILE:+${RECIPE_DIR}/${EXTRA_BUILD_DOCKERFILE}}" \
  PROV_BUILD_ARGS="${PROV_BUILD_ARGS:-}" \
  PROV_SWEEP_TP="${_TP_ARR[*]}" \
  PROV_SWEEP_ISL_OSL="${_ISLOSL_ARR[*]}" \
  PROV_SWEEP_CONC="${_CONC_ARR[*]}" \
  PROV_RECIPE_TOML="${RECIPE_TOML:-${RECIPE_DIR}/recipe.toml}" \
  uv run --no-project "${_SWEEP_DIR}/write_provenance.py" >/dev/null \
    && ok "Wrote ${RESULTS_DIR}/provenance.json" \
    || warn "Provenance write failed (continuing)."
  fi

  # ---------- Loop ----------
  local SUMMARY="${RESULTS_DIR}/summary.csv"
  echo "tp,isl,osl,conc,status,result_file" > "$SUMMARY"

  local rc_total=0
  # Track the running server so we only restart when the server command changes.
  # For most recipes ISL/OSL/CONC don't appear in server_args, so only a TP
  # change triggers a restart — reducing server launches from N_combos to N_tp.
  local _last_srv_cmd_str=""
  local _srv_failed_cmd=""
  local _native_server_pid=""
  local _current_container=""
  local LOG_FILE=""

  # Tear down whichever server instance is currently running (native or docker).
  _teardown_current_server() {
    if [ "$NATIVE" = "0" ]; then
      if [ -n "$_current_container" ]; then
        docker logs "$_current_container" >> "$LOG_FILE" 2>&1 || true
        docker rm -f "$_current_container" >/dev/null 2>&1 || true
        _current_container=""
      fi
    else
      if [ -n "$_native_server_pid" ]; then
        kill "$_native_server_pid" 2>/dev/null || true
        wait "$_native_server_pid" 2>/dev/null || true
        _sync_vllm_cache
        _native_server_pid=""
      fi
    fi
    _last_srv_cmd_str=""
  }

  trap '_teardown_current_server' EXIT INT TERM

  for TP in "${_TP_ARR[@]}"; do
    for P in "${_ISLOSL_ARR[@]}"; do
      ISL="${P%,*}"; OSL="${P#*,}"
      for CONC in "${_CONC_ARR[@]}"; do
        local RESULT_FILENAME="${MODEL_NAME}_${VARIANT_NAME}_tp${TP}_isl${ISL}_osl${OSL}_c${CONC}.json"

        mapfile -t _SRV_CMD < <(_subst_placeholders "$TP" "$ISL" "$OSL" "$CONC" "$RECIPE_MOUNT_DIR" "${SERVER_CMD[@]}")
        # Re-quote each token so bash -lc receives a shell-safe single string.
        local _SRV_CMD_STR
        _SRV_CMD_STR=$(printf '%q ' "${_SRV_CMD[@]}")

        # Skip all combos whose server command previously failed to start.
        if [ -n "$_srv_failed_cmd" ] && [ "$_SRV_CMD_STR" = "$_srv_failed_cmd" ]; then
          err "Skipping tp=$TP isl=$ISL osl=$OSL conc=$CONC — server failed for this TP."
          echo "$TP,$ISL,$OSL,$CONC,server_timeout," >> "$SUMMARY"
          rc_total=$((rc_total + 1))
          continue
        fi

        # (Re)start the server only when its command changes.
        if [ "$_SRV_CMD_STR" != "$_last_srv_cmd_str" ]; then
          _teardown_current_server

          LOG_FILE="${RESULTS_DIR}/server_tp${TP}.log"
          local CONTAINER_NAME="recipe_${MODEL_NAME//./-}_${VARIANT_NAME}_tp${TP}_$$"

          log "==== Starting server: tp=$TP ===="

          # ---- Resolve MODEL_ID_ORIG to a local path if already cached ----
          # Applies identically in native and Docker mode: some serving
          # stacks (TRT-LLM in particular) perform their own HF Hub model
          # resolution and can re-attempt a download even when the model is
          # fully cached and HF_HOME/HF_HUB_CACHE are set correctly. Handing
          # the server a literal local directory sidesteps that resolution
          # path entirely. Always resolves from MODEL_ID_ORIG (never MODEL_ID)
          # so this is correct on every server restart, not just the first.
          local _resolved_cmd="$_SRV_CMD_STR"
          local _hub_cache="${HF_HOST_DIR}/hub"
          local _local_model_path
          _local_model_path="$(_resolve_local_model_path "$_hub_cache" "$MODEL_ID_ORIG")"

          if [ -n "$_local_model_path" ] && [ -d "$_local_model_path" ]; then
            local _model_path_for_server="$_local_model_path"
            if [ "$NATIVE" = "0" ]; then
              # Translate the host-side snapshot path to its in-container
              # path using the same prefix HF_MOUNT bind-mounts on.
              _model_path_for_server="${HF_CONTAINER_DIR}${_local_model_path#"$HF_HOST_DIR"}"
            fi
            log "Resolved $MODEL_ID_ORIG -> $_model_path_for_server"
            local _quoted_id
            _quoted_id=$(printf '%q' "$MODEL_ID_ORIG")
            _resolved_cmd="${_SRV_CMD_STR//${_quoted_id}/$(printf '%q' "$_model_path_for_server")}"
            # Bench client uses the same model name the server was given,
            # so both agree regardless of stack-specific model-name echoing.
            MODEL_ID="$_model_path_for_server"
          else
            warn "Could not resolve $MODEL_ID_ORIG to local cache — server will attempt to fetch it (blocked by HF_HUB_OFFLINE=1; pre-download the model first)."
            MODEL_ID="$MODEL_ID_ORIG"
          fi

          if [ "$NATIVE" = "0" ]; then
            docker rm -f "$CONTAINER_NAME" >/dev/null 2>&1 || true
            # Launch detached (no --rm: we need to capture logs after exit).
            # HF_HUB_OFFLINE / HF_HUB_DISABLE_XET mirror the native launch
            # below, keeping "never download mid-sweep" consistent across
            # both modes.
            docker run -d --name "$CONTAINER_NAME" \
              "${VENDOR_FLAGS[@]}" \
              "${HF_MOUNT[@]}" \
              "${TORCH_CACHE_MOUNT[@]}" \
              "${FILE_MOUNTS[@]}" \
              -v "${RESULTS_DIR}:/results" \
              "${HF_TOKEN_ENV[@]}" \
              -e HF_HUB_DISABLE_XET=1 \
              -e HF_HUB_OFFLINE=1 \
              ${EXTRA_DOCKER_ENV[@]+"${EXTRA_DOCKER_ENV[@]}"} \
              ${EXTRA_DOCKER_FLAGS[@]+"${EXTRA_DOCKER_FLAGS[@]}"} \
              --entrypoint=/bin/bash \
              "$IMAGE" -lc "$_resolved_cmd" \
              >/dev/null
            _current_container="$CONTAINER_NAME"
          else
            # Native mode: extract KEY=VAL pairs from EXTRA_DOCKER_ENV (-e KEY=VAL ...).
            local -a _native_env=()
            local _i=0
            while [ "$_i" -lt "${#EXTRA_DOCKER_ENV[@]}" ]; do
              if [ "${EXTRA_DOCKER_ENV[$_i]}" = "-e" ]; then
                _i=$(( _i + 1 ))
                _native_env+=("${EXTRA_DOCKER_ENV[$_i]}")
              fi
              _i=$(( _i + 1 ))
            done

            # Launch server via uv so VIRTUAL_ENV is respected.
            # PYTHONUNBUFFERED=1 forces Python to flush stdout/stderr immediately
            # when writing to a file (not a TTY), so startup logs appear in real time.
            env "${_native_env[@]+"${_native_env[@]}"}" \
                HF_TOKEN="${_hf_token:-}" \
                HF_HOME="$HF_HOST_DIR" \
                HUGGINGFACE_HUB_CACHE="$_hub_cache" \
                HF_HUB_CACHE="$_hub_cache" \
                HF_HUB_DISABLE_XET=1 \
                HF_HUB_OFFLINE=1 \
                PYTHONUNBUFFERED=1 \
                uv run --no-project bash -c "$_resolved_cmd" > "$LOG_FILE" 2>&1 &
            _native_server_pid=$!
            log "Native server launched (PID $_native_server_pid) — logging to $LOG_FILE"
          fi

          # Wait for ready marker.
          local waited=0
          local ready=0
          while [ "$waited" -lt "$READY_TIMEOUT_S" ]; do
            if [ "$NATIVE" = "0" ]; then
              if docker logs "$CONTAINER_NAME" 2>&1 | grep -q "$READY_MARKER"; then
                ready=1; break
              fi
              if ! docker ps -q --filter "name=^${CONTAINER_NAME}$" | grep -q .; then
                err "Server container exited before becoming ready."
                break
              fi
            else
              if grep -q "$READY_MARKER" "$LOG_FILE" 2>/dev/null; then
                ready=1; break
              fi
              if ! kill -0 "$_native_server_pid" 2>/dev/null; then
                err "Server process $_native_server_pid exited before becoming ready."
                break
              fi
            fi
            sleep 10; waited=$((waited + 10))
          done

          if [ "$ready" -ne 1 ]; then
            err "Server failed to reach '$READY_MARKER' in ${READY_TIMEOUT_S}s."
            _srv_failed_cmd="$_SRV_CMD_STR"
            _teardown_current_server
            echo "$TP,$ISL,$OSL,$CONC,server_timeout," >> "$SUMMARY"
            rc_total=$((rc_total + 1))
            continue
          fi
          ok "Server is ready (after ${waited}s)."
          _last_srv_cmd_str="$_SRV_CMD_STR"
          _srv_failed_cmd=""
        fi

        log "---- Bench: tp=$TP isl=$ISL osl=$OSL conc=$CONC ----"

        # Remove any stale result file before the bench run. vllm bench serve
        # appends (not overwrites) when the file exists — caused by the warmup
        # phase writing an interim JSON before the final result is written.
        # Deleting here ensures each bench run produces exactly one JSON object.
        rm -f "${RESULTS_DIR}/${RESULT_FILENAME}"

        if run_bench; then
          echo "$TP,$ISL,$OSL,$CONC,ok,$RESULT_FILENAME" >> "$SUMMARY"
        else
          err "Bench client failed."
          echo "$TP,$ISL,$OSL,$CONC,bench_failed,$RESULT_FILENAME" >> "$SUMMARY"
          rc_total=$((rc_total + 1))
        fi

      done
    done
  done

  # Final teardown — kills server and syncs cache if still running.
  _teardown_current_server
  # Clear the trap: its target's locals go out of scope when run_sweep
  # returns, so leaving it armed causes an unbound-variable error when the
  # caller (run_recipe.sh) exits and re-fires it outside this scope.
  trap - EXIT INT TERM

  # Clean up the private native recipe-mount directory (see RECIPE_MOUNT_DIR
  # above) now that every server restart in this sweep is done with it. A
  # leftover dir from an abnormally-killed run (Ctrl+C, OOM-kill) is
  # harmless — it's uniquely named per invocation and never collides with
  # anything — so this best-effort cleanup only needs to cover the normal
  # completion path.
  if [ "$NATIVE" = "1" ] && [ "$DRY_RUN" != "1" ] && [ -d "$RECIPE_MOUNT_DIR" ]; then
    rm -rf "$RECIPE_MOUNT_DIR"
  fi

  # Restore ownership: the bench client runs as root inside the container and
  # writes result files as uid 0. Chown the entire results dir back to the
  # invoking user so they can read/delete results without sudo.
  local _invoke_user="${SUDO_USER:-$USER}"
  local _invoke_group; _invoke_group="$(id -gn "$_invoke_user" 2>/dev/null || echo users)"
  chown -R "$_invoke_user:$_invoke_group" "$RESULTS_DIR" 2>/dev/null \
    || sudo chown -R "$_invoke_user:$_invoke_group" "$RESULTS_DIR" 2>/dev/null \
    || warn "chown of $RESULTS_DIR failed — result files may be root-owned."

  echo
  ok "Sweep complete. Summary: $SUMMARY"
  if [ "$rc_total" -gt 0 ]; then
    warn "$rc_total combination(s) had failures."
    return 1
  fi
  return 0
}
