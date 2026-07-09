# Recipes

Reproducible benchmark sweeps for specific LLMs on specific serving stacks.

A **recipe** is one TOML file describing a model and one or more *variants* —
each variant is a `(vendor, stack)` combination such as `amd_vllm` or
`nvidia_trtllm`. The runner reads the TOML and, depending on the detected
runtime environment, either launches the server in a Docker container
(bare-metal — the original target) or as a direct process on the host
(RunPod / generic GPU containers, where nested Docker isn't available —
see [environments/README.md](../environments/README.md)). Either way it
waits for the server, runs the bench client, captures the result, and
tears the server down between combos.

## Quick start

```bash
# List what's available
./recipes/run_recipe.sh --list

# Run a recipe with its built-in default sweep
./recipes/run_recipe.sh gpt-oss-120b amd_atom

# Override the matrix from the command line
./recipes/run_recipe.sh qwen3-next-80b nvidia_vllm \
    --tp 1,2,4 \
    --shapes "1000,100 5000,500 10000,1000" \
    --conc "4 8 16 32 64 128 256"

# Dry-run (prints the plan and exits — no containers launched)
./recipes/run_recipe.sh kimi-k2.6 amd_vllm --dry-run
```

## Prerequisites

These must be in place before running any recipe on **bare-metal with
Docker** (this repo's original target). See
[docs/QUICKSTART.md](../docs/QUICKSTART.md) for verification commands. If
you're on RunPod or a generic GPU container instead, see
[environments/README.md](../environments/README.md) — the environment
profile handles most of this automatically (native process launch instead
of Docker, cache paths under the platform's persistent volume, etc.).

1. **GPU drivers + ROCm or CUDA** — run `scripts/<vendor>/setup_*.sh` then reboot.
2. **Docker** — `scripts/common/setup_docker.sh`. Your user must be in the `docker`
   group (log out and back in after install). Not needed in native-mode
   environments (RunPod, generic containers) — the server runs as a
   direct process instead.
3. **Storage + HF environment** — `scripts/common/setup_hf_env.sh`. Sets
   `HF_HOME=/mnt/data/huggingface` system-wide and writes
   `/etc/profile.d/huggingface.sh`. Source it or open a new shell.
4. **HF authentication** — `hf auth login`. Recipes forward `HF_TOKEN` from
   `$HF_TOKEN_PATH` into the container (or native process) automatically.

## Results layout

Each run creates a timestamped directory:

```
<results_base>/<model>/<variant>/<timestamp>/
    provenance.json                          # image digest, build args, sweep matrix, recipe snapshot, host/GPU info
    summary.csv                               # one row per (TP, ISL, OSL, CONC) combo: status + result filename
    server_tp<TP>.log                         # server stdout, one per TP (restarts only when TP changes)
    <model>_<variant>_tp<TP>_isl<ISL>_osl<OSL>_c<CONC>.json  # bench client output per combo
```

`provenance.json` is the authoritative record for apples-to-apples comparisons —
read it before comparing two runs that used different images or build args.

`<results_base>` is `/workspace/results` when `/workspace` is a mounted
persistent volume or `/workspace/gpu-env.sh` exists (RunPod convention),
otherwise `$HOME/results`. Never `/mnt/data/` (scratch storage that may
not persist) on bare-metal.

## Directory layout

```
recipes/
  run_recipe.sh              # unified CLI entrypoint
  README.md                  # this file
  _common/
    load_recipe.py           # reads recipe.toml, emits bash variable assignments
    sweep.sh                 # sweep harness (sourced by run_recipe.sh)
    docker_amd.sh            # standard AMD docker-run flag bundle
    docker_nvidia.sh         # standard NVIDIA docker-run flag bundle
    bench_client.sh          # bench client shim — dispatches to vllm bench serve / atom / openai
    bench_openai.py          # stack-agnostic OpenAI-compatible bench client (no vLLM dependency)
    write_provenance.py      # writes provenance.json after each run
  <model-name>/
    recipe.toml              # model + all variants defined here
    README.md                # human-readable notes: variants, caveats, sweep matrix
    Dockerfile.<variant>     # optional: only when a variant needs a custom image build
```

## Recipe TOML schema

Each model has exactly one `recipe.toml`. All variants live inside it.

### Top-level `[recipe]` table

```toml
[recipe]
model_name  = "my-model"              # slug used in result paths
model_id    = "org/my-model"          # default HF model ID (variants may override)
description = "..."
```

### `[recipe.defaults]` — sweep matrix defaults

```toml
[recipe.defaults]
sweep_tp           = [1, 2, 4]
sweep_isl_osl      = ["1024,1024", "1024,8192", "8192,1024"]
sweep_conc         = [4, 8, 16, 32, 64, 128, 256]
random_range_ratio = 0.9
ready_timeout_s    = 1800
```

`random_range_ratio` follows `vllm bench serve`'s own semantics (verified
against vLLM 0.24.0 source, `vllm.benchmarks.datasets.utils.get_sampling_params`):
each request's ISL and OSL are drawn independently and uniformly from
`[target*(1-ratio), target*(1+ratio)]`, so ratio `0.2` on an ISL of 1024
samples individual prompts between 819 and 1229 tokens. Ratio must be in
`[0, 1)`; `0` (vLLM's own default) means every request uses the nominal
ISL/OSL exactly. This repo's own `bench_openai.py` (used when `bench_tool =
"openai"`) implements this exact convention as of `gpu-setup` 0.3.0 —
earlier versions had a distinct, incorrect one-sided formula. ATOM's own
bench client uses a different, below-target-only convention
(`[target*ratio, target]`) that this harness does not control or alter —
be aware of this when comparing `random_range_ratio` results across
`amd_atom` and other variants.

CLI flags (`--tp`, `--shapes`, `--conc`) override these at run time.

### `[variants.<name>]` — one block per variant

Required fields:

| Field | Example | Meaning |
|---|---|---|
| `vendor` | `"amd"` or `"nvidia"` | Selects the docker flag bundle |
| `stack` | `"vllm"`, `"atom"`, `"trtllm"`, `"sglang"`, `"triton"` | Selects default bench tool and ready marker |
| `image` | `"vllm/vllm-openai-rocm:nightly-<digest>"` | Docker image; **must be pinned**, no `:latest` (also the reference image in native-mode environments, even though it's never pulled — see `environments/README.md`) |
| `server_entrypoint` | `"vllm serve"` | Command run as PID 1 inside the container, or the native process in native-mode environments |
| `server_args` | `["model-id", "--port", "8000", ...]` | Full argument list; use `@TP@`, `@ISL@`, `@OSL@`, `@CONC@`, `@RECIPE_DIR@` as placeholders |

Optional fields:

| Field | Default | Meaning |
|---|---|---|
| `model_id` | recipe-level `model_id` | Per-variant model identifier (use when AMD/NVIDIA use different HF repos) |
| `port` | `8000` | Port the server listens on |
| `ready_marker` | stack-default | Log string that signals server is ready |
| `bench_tool` | `"vllm"` for `stack="vllm"`, `"atom"` for `stack="atom"`, **`"openai"` for everything else** (`trtllm`, `sglang`, ...) | Which bench client to use: `vllm`, `atom`, `openai`, or `vllm_docker`. `vllm`/`atom` ship their own client alongside the server (same package/image); `openai` (`bench_openai.py`) is a stack-agnostic HTTP client for stacks that don't, so installing vLLM just for its bench CLI isn't required; `vllm_docker` runs the real `vllm bench serve` CLI via a disposable `vllm/vllm-openai-cpu` container regardless of the server's own stack — an opt-in for Docker-capable hosts that want vLLM's exact bench-client implementation (not just its documented semantics) against a non-vLLM server; needs a working `docker` daemon, so it's not usable in native-mode environments (see below). Override explicitly if a variant wants a different client. |
| `docker_flags` | `[]` | Extra docker run flags (e.g. `--cpuset-cpus`, `--cpuset-mems`) — Docker mode only |
| `bench_extra_args` | `[]` | Extra args forwarded to the bench client (e.g. `["--trust-remote-code"]`) |
| `extra_files` | `[]` | Files in the recipe dir to mount at `@RECIPE_DIR@/<basename>` (read-only) |
| `runtime_config_path` | — | Where the materialized `[variants.<name>.runtime_config]` JSON is mounted — use `@RECIPE_DIR@/<filename>`, not a literal path (see below) |

### `@RECIPE_DIR@` placeholder

Resolves differently depending on how the server actually runs:

- **Docker mode**: `/recipe` — safe as a literal here, since every
  container gets its own private, isolated filesystem.
- **Native mode** (`NATIVE=1` — RunPod, generic GPU containers): a fresh
  `mktemp -d` directory, unique per `run_recipe.sh` invocation. Native
  mode has no container-level isolation — it's all one shared host
  filesystem — so a literal `/recipe` there would be silently shared,
  mutable state across every invocation on the host, including an
  unrelated recipe's `--dry-run` in a different clone. (This was a real
  bug: exactly that scenario once repointed a live sweep's mount
  mid-run and crashed it.) **Never hardcode `/recipe` in a recipe.toml**
  — always use `@RECIPE_DIR@`.

### `bench_tool = "vllm_docker"` — real `vllm bench serve`, any backend

There is a real cross-tool inconsistency: `vllm bench serve` and
ATOM's own client implement `random_range_ratio` with different semantics
(see the `[recipe.defaults]` note above), so results from one aren't
directly comparable to the other's. The workaround is to always drive
the *bench client* side with `vllm bench serve` — via a disposable,
pinned `vllm/vllm-openai-cpu` Docker container — no matter what server is
actually being benchmarked (vLLM, ATOM, TRT-LLM, ...). This gets exact
upstream vLLM bench-client behavior without installing vLLM natively next
to a non-vLLM server (and its torch/CUDA build) or trusting a
reimplementation's semantics to match.

```toml
[variants.nvidia_trtllm]
bench_tool = "vllm_docker"
```

This launches `docker run --rm --network=host --entrypoint vllm
vllm/vllm-openai-cpu:v0.24.0 bench serve ...` per combo — a plain HTTP
client against whatever server is already listening on `localhost:<port>`,
regardless of how that server itself is running (Docker or native). It
therefore **requires a working Docker daemon on the host** and is not
usable in native-mode environments (RunPod, nested containers) where
Docker isn't available at all — use `bench_tool = "openai"` there instead.
Override the image with the `VLLM_BENCH_DOCKER_IMAGE` env var if you need a
different pinned tag/digest.

### `[variants.<name>.env]` — environment variables

```toml
[variants.amd_vllm.env]
VLLM_ROCM_USE_AITER = "1"
HIP_VISIBLE_DEVICES = "0,1,2,3"
```

Every key-value pair is passed to the container as `-e KEY=VALUE`.

### `[variants.<name>.build]` — custom Docker builds

When a variant needs a customised image (e.g. to bake in a tuning CSV):

```toml
[variants.amd_vllm.build]
dockerfile = "Dockerfile.amd_vllm"   # relative to the recipe directory
context    = "."
tag        = "gpu-setup/my-model-amd:local"
build_args = { BASE_IMAGE = "vllm/vllm-openai-rocm:nightly-<digest>" }
```

The harness builds the image once and reuses it on subsequent runs. When
`build` is present, `image` serves as the base for the `FROM` line only.

### `[variants.<name>.runtime_config]` — YAML-tool config as JSON

Some serving stacks (e.g. `trtllm-serve`) accept config via a YAML file.
Put the config as a TOML table; the harness serializes it to JSON (valid
YAML) at run time and mounts it where the tool expects it:

```toml
[variants.nvidia_trtllm]
runtime_config_path = "@RECIPE_DIR@/runtime_config.json"
server_args = [
  "model-id", "--port", "8000",
  "--extra_llm_api_options", "@RECIPE_DIR@/runtime_config.json",
]

[variants.nvidia_trtllm.runtime_config]
# ...fields here...
```

Always reference the mounted path via `@RECIPE_DIR@`, never a literal
`/recipe/...` — see the placeholder note above.

No YAML files are committed to this repo.

### `[variants.<name>.defaults]` — variant-level sweep overrides

A variant can override the recipe-level defaults (e.g. to lock to TP=4):

```toml
[variants.amd_vllm_numa.defaults]
sweep_tp = [4]
```

## Writing a new recipe

1. Create `recipes/<model-name>/recipe.toml`. Copy an existing one as a template.
2. **Pin every `image`** — `:latest` is not allowed in checked-in recipes.
   Use a digest or a specific version tag.
3. **Use `@TP@`, `@ISL@`, `@OSL@`, `@CONC@` in `server_args`** — never
   hardcode the tensor-parallel size or sequence lengths. **Use
   `@RECIPE_DIR@`, never a literal `/recipe/...`**, for any mounted file
   path (`runtime_config_path`, `extra_files` destinations).
4. Provide sensible **sweep defaults** in `[recipe.defaults]`. A recipe that
   requires CLI flags to do anything is a broken recipe.
5. If a variant needs a custom image, put the build definition in
   `[variants.<name>.build]` and the Dockerfile in the same directory.
6. Add `recipes/<model-name>/README.md`: what the model is, variant differences,
   NUMA/gated-repo/hardware caveats.
7. Test with `--dry-run` before committing — confirm it makes no
   filesystem changes (`--dry-run` must always be side-effect-free).
8. If the variant needs a serving stack whose bench client isn't
   installed alongside it (e.g. TRT-LLM without vLLM), let `bench_tool`
   default to `openai` rather than installing an unrelated package just
   for its CLI — see the placeholder/bench_tool notes above.
