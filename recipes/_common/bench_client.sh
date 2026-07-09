#!/usr/bin/env bash
# Bench client shim. Sourced by sweep.sh; provides `run_bench`.
#
# Four interchangeable bench tools, selected per-variant via BENCH_TOOL
# (see sweep.sh:_default_bench_tool for the default mapping):
#   vllm        `vllm bench serve` — used when the stack IS vllm, so the
#               vllm package is guaranteed present alongside the server.
#   atom        `atom.benchmarks.benchmark_serving` — AMD ATOM's own client.
#   openai      bench_openai.py (this directory) — stack-agnostic client for
#               any OpenAI-compatible /v1/completions endpoint (TRT-LLM,
#               SGLang, or vllm/atom if you'd rather not rely on their
#               bundled clients). Requires no packages beyond the `openai`
#               SDK. Implements the same random_range_ratio convention as
#               real `vllm bench serve` (see recipes/README.md).
#   vllm_docker `vllm bench serve`, run via a disposable official
#               `vllm/vllm-openai-cpu` container regardless of what stack
#               the server under test actually is. Uses one canonical
#               bench client's semantics across every backend (vLLM,
#               ATOM, TRT-LLM, ...) without installing vLLM natively next
#               to a non-vLLM server. Needs a working Docker daemon on
#               the host — not usable in native-mode environments
#               (RunPod, nested containers) where Docker isn't available
#               at all; use `openai` there instead.
#
# vllm/atom run wherever the server does: inside the container in Docker
# mode (via `docker exec`, since only that image is guaranteed to have the
# package installed), or on the host in native mode. openai always runs on
# the host — it's a plain HTTP client, and both docker_nvidia.sh and
# docker_amd.sh launch containers with --network=host, so the server's
# port is already reachable from the host in every mode. vllm_docker always
# launches its own short-lived container (`docker run --rm`), independent
# of the server's own container or process.
#
# Required env when calling run_bench:
#   CONTAINER_NAME, MODEL_ID, BENCH_TOOL (vllm|atom|openai|vllm_docker),
#   HOST, PORT, ISL, OSL, CONC, RANDOM_RANGE_RATIO, RESULTS_HOST_DIR,
#   RESULT_FILENAME
# Optional:
#   BENCH_EXTRA_ARGS (array)
#   VLLM_BENCH_DOCKER_IMAGE — image for BENCH_TOOL=vllm_docker (default
#     below); pin a different tag/digest if you need a specific vLLM
#     bench-client version independent of the server's own vLLM version.

run_bench() {
  # Ensure BENCH_EXTRA_ARGS is always an array, even if the caller left it unset.
  BENCH_EXTRA_ARGS=("${BENCH_EXTRA_ARGS[@]+"${BENCH_EXTRA_ARGS[@]}"}")
  local num_warmups=$(( CONC * 2 ))
  local num_prompts=$(( CONC * 10 ))

  local -a cmd
  local _bench_on_host
  local _bench_via_docker_image=0
  case "$BENCH_TOOL" in
    vllm)
      cmd=(vllm bench serve)
      _bench_on_host="${NATIVE:-0}"
      ;;
    atom)
      cmd=(python3 -m atom.benchmarks.benchmark_serving)
      _bench_on_host="${NATIVE:-0}"
      ;;
    openai)
      # Stack-agnostic client for any OpenAI-compatible endpoint. Always
      # runs on the host (see file header) — never via docker exec.
      cmd=(python3 "$(dirname "${BASH_SOURCE[0]}")/bench_openai.py")
      _bench_on_host=1
      ;;
    vllm_docker)
      if ! command -v docker >/dev/null 2>&1; then
        err "BENCH_TOOL=vllm_docker requires a docker binary on the host, but none was found. Not usable in native-mode environments (RunPod, nested containers) — use BENCH_TOOL=openai there instead."
        return 2
      fi
      # `vllm` is the image's overridden entrypoint (see docker run below);
      # cmd only holds the subcommand + args here.
      cmd=(bench serve)
      _bench_on_host=0
      _bench_via_docker_image=1
      ;;
    *)
      err "Unknown BENCH_TOOL='$BENCH_TOOL' (expected vllm|atom|openai|vllm_docker)"
      return 2
      ;;
  esac

  # Result dir depends on where the bench client actually executes, not on
  # where the server runs: a host-side client writes straight into
  # RESULTS_DIR; a client running via `docker exec`/`docker run` writes to
  # /results, the RESULTS_DIR bind-mount inside that container.
  local _result_dir
  if [ "$_bench_on_host" = "1" ]; then
    _result_dir="$RESULTS_DIR"
  else
    _result_dir="/results"
  fi

  # shellcheck disable=SC2054  # commas are inside argument values, not array separators
  cmd+=(
    --model="$MODEL_ID"
    --backend=vllm
    --base-url="http://${HOST}:${PORT}"
    --dataset-name=random
    --random-input-len="$ISL"
    --random-output-len="$OSL"
    --random-range-ratio="${RANDOM_RANGE_RATIO:-0.0}"
    --num-prompts="$num_prompts"
    --num-warmups="$num_warmups"
    --max-concurrency="$CONC"
    --request-rate=inf
    --ignore-eos
    --save-result
    --result-dir="$_result_dir"
    --result-filename="$RESULT_FILENAME"
    --percentile-metrics=ttft,tpot,itl,e2el
    --metric-percentiles=25,50,75,90,95,99
  )
  if [ "${#BENCH_EXTRA_ARGS[@]}" -gt 0 ]; then
    cmd+=("${BENCH_EXTRA_ARGS[@]}")
  fi

  # If the server was launched with --trust-remote-code (e.g. models with
  # custom tokenizer code), the bench client tokenizer needs it too.
  # Auto-add it unless already present in BENCH_EXTRA_ARGS.
  if [[ " ${SERVER_CMD[*]:-} " =~ " --trust-remote-code " ]]; then
    local _has_trc=0
    for _a in "${BENCH_EXTRA_ARGS[@]+"${BENCH_EXTRA_ARGS[@]}"}"; do
      [[ "$_a" == "--trust-remote-code" ]] && _has_trc=1 && break
    done
    [ "$_has_trc" -eq 0 ] && cmd+=("--trust-remote-code")
  fi

  log "Bench: ISL=$ISL OSL=$OSL CONC=$CONC -> $RESULT_FILENAME"
  if [ "$_bench_on_host" = "1" ]; then
    PYTHONUNBUFFERED=1 uv run --no-project "${cmd[@]}"
  elif [ "$_bench_via_docker_image" = "1" ]; then
    # A disposable container, independent of whatever the server under
    # test actually is — --entrypoint overrides the image's own server
    # entrypoint so `cmd` (which starts with the `bench serve` subcommand)
    # runs through the vllm CLI instead of launching an API server.
    docker run --rm --network=host \
      -v "${RESULTS_DIR}:/results" \
      --entrypoint vllm \
      "${VLLM_BENCH_DOCKER_IMAGE:-vllm/vllm-openai-cpu:v0.24.0}" \
      "${cmd[@]}"
  else
    docker exec "$CONTAINER_NAME" "${cmd[@]}"
  fi
}
