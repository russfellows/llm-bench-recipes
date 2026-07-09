# gpu-setup

A reproducible LLM inference benchmarking harness — TOML-driven sweeps
across serving stacks (vLLM, ATOM, TensorRT-LLM) and vendors (AMD, NVIDIA),
on bare-metal Docker hosts or native-process environments like RunPod.
Also includes one-time bootstrap tooling to take a fresh Ubuntu GPU box
from stock install to ready-for-Docker, for when you need to prep a box
from scratch.

> **Fresh box, nothing installed yet?**
> Jump to **[One-Time Host Setup](#one-time-host-setup-bare-metal)** below —
> it covers driver/CUDA/ROCm bootstrap, optional NVMe storage, and the
> Docker + HuggingFace environment.
>
> **Box already set up (or on RunPod / a pre-built container)?**
> Keep reading — **[docs/QUICKSTART.md](docs/QUICKSTART.md)** covers
> environment verification, HF authentication, model downloads, and
> running your first recipe.

**Contents:** [Running Recipes](#running-recipes) ·
[Monitoring Test Runs](#monitoring-test-runs) ·
[Analyzing Results](#analyzing-results) ·
[Environments](#environments) ·
[One-Time Host Setup](#one-time-host-setup-bare-metal) ·
[Version](#version)

---

## Layout

```
recipes/                     # benchmark sweep recipes — the core of this repo, see recipes/README.md
  run_recipe.sh              # CLI entrypoint:  ./recipes/run_recipe.sh <model> <variant>
  _common/                   # harness, loader, vendor docker-flag bundles, bench clients
  gpt-oss-120b/              # OpenAI GPT-OSS 120B (vLLM, ATOM, TensorRT-LLM)
  kimi-k2.6/                 # Moonshot Kimi-K2.6 (MXFP4 on AMD, NVFP4 on NVIDIA vLLM)
  qwen3-next-80b/            # Qwen3-Next-80B-A3B-Instruct-FP8 (vLLM, ATOM, TensorRT-LLM)
environments/                 # runtime profiles: bare-metal+Docker vs. native (RunPod/containers)
analysis/                    # post-hoc reporting: results dir/.tgz -> Excel workbook
docs/
  QUICKSTART.md              # new-user guide: verify env, check HF token, run first recipe
  archive/                   # original drafts kept for reference
bootstrap.sh                 # one-time host setup entrypoint: detect GPUs, dispatch (bare-metal only)
scripts/
  lib/common.sh              # shared bash helpers
  common/
    setup_prereqs.sh         # vendor-neutral: build tools, uv, gh, hf CLI
    setup_storage.sh         # opt-in: discover NVMe, build mdraid + XFS, mount /mnt/data
    setup_docker.sh          # Docker CE + (NVIDIA hosts) nvidia-container-toolkit
    setup_hf_env.sh          # /etc/profile.d/huggingface.sh + HF cache on /mnt/data
    pull_serving_images.sh   # pre-pull vLLM / Triton / TRT-LLM / SGLang images
    monitor_sweep.sh         # read-only: check progress of a live or finished sweep
  nvidia/
    setup_nvidia.sh          # CUDA + open driver + fabric manager + container toolkit
    verify_nvidia.sh         # post-reboot health checks
  amd/
    setup_amd_rocm.sh        # amdgpu-install + ROCm
    verify_amd.sh            # post-reboot HIP compute test
```

---

## Running Recipes

[`recipes/`](recipes/) holds reproducible benchmark sweeps for specific
LLMs on specific serving stacks (vLLM, ATOM, TensorRT-LLM). A recipe is
one TOML file describing the model and one or more variants — `(vendor,
stack)` combinations like `amd_vllm` or `nvidia_trtllm`. A unified runner
reads the TOML, launches the server — in a Docker container on bare-metal,
or as a direct process where Docker isn't available (RunPod, generic GPU
containers; see [Environments](#environments)) — waits for it, runs a
sweep of `(TP × ISL/OSL × concurrency)` via the bench client, and tears
the server down between combinations. The runtime environment is
auto-detected; override with `--env baremetal|container|runpod` if
detection gets it wrong.

```bash
# What's available
./recipes/run_recipe.sh --list

# Use the recipe's built-in defaults
./recipes/run_recipe.sh gpt-oss-120b amd_atom

# Override the matrix
./recipes/run_recipe.sh qwen3-next-80b nvidia_vllm \
    --tp 1,2,4 --shapes "1000,100 5000,500" --conc "16 32 64"

# See the exact plan without running anything
./recipes/run_recipe.sh kimi-k2.6 amd_vllm --dry-run

# Explicit environment override
./recipes/run_recipe.sh gpt-oss-120b nvidia_trtllm --env runpod
```

A full sweep across several TP values, shapes, and concurrencies can run for
hours. Launch it in the background with output redirected to a log file so
you can disconnect and check back later — see
[Monitoring Test Runs](#monitoring-test-runs) below for how to watch progress
against that log file.

```bash
mkdir -p /workspace/logs
nohup ./recipes/run_recipe.sh gpt-oss-120b nvidia_vllm \
    > /workspace/logs/gpt-oss-120b_full_sweep.log 2>&1 &
```

### Results directory layout

Results land under `<results_base>/<model>/<variant>/<timestamp>/`, where
`<results_base>` is `/workspace/results` when `/workspace` is a mounted
persistent volume or `/workspace/gpu-env.sh` exists (RunPod convention),
otherwise `$HOME/results`:

- `provenance.json` — image digest, base image (for builds), build args, sweep
  matrix, full recipe.toml snapshot, host/GPU info. Required reading for any
  apples-to-apples comparison across runs.
- `summary.csv` — one row per `(TP, ISL, OSL, CONC)` combo
- `<model>_<variant>_tp*_isl*_osl*_c*.json` — bench client output per combo
- `server_tp*.log` — server stdout, one per TP (server restarts only when TP changes)

For full recipe authoring docs (TOML schema, custom Dockerfile builds,
runtime-config JSON injection, `extra_files` mounts, `@TP@`/`@ISL@`/`@OSL@`
/`@CONC@`/`@RECIPE_DIR@` placeholders) see [recipes/README.md](recipes/README.md).

---

## Monitoring Test Runs

A sweep writes one result file per `(TP, ISL, OSL, CONC)` combo as it goes, so
you can check progress at any time without disturbing a running sweep.
[`scripts/common/monitor_sweep.sh`](scripts/common/monitor_sweep.sh) is
**read-only** — it only reads the results directory and a log file, never the
sweep process itself — so it's safe to run anytime alongside a live sweep, or
after the fact against a finished one.

```bash
scripts/common/monitor_sweep.sh <results_dir> [log_file] [total_combos]
```

- `results_dir` — a `recipes/run_recipe.sh` results directory (the one
  containing `provenance.json`), e.g.
  `$HOME/results/gpt-oss-120b/nvidia_vllm/20260629_222941/`
- `log_file` *(optional)* — defaults to
  `/workspace/logs/<model_name>_full_sweep.log`, where `<model_name>` is read
  from `provenance.json`. Pass this explicitly if you logged the sweep
  somewhere else (see the `nohup` example above).
- `total_combos` *(optional)* — defaults to
  `len(tp) * len(isl_osl) * len(conc)` computed from the sweep matrix in
  `provenance.json`, when `jq` is available.

```bash
# Typical usage — everything inferred from provenance.json
scripts/common/monitor_sweep.sh $HOME/results/gpt-oss-120b/nvidia_vllm/20260629_222941/

# Explicit log file, e.g. if it isn't under /workspace/logs
scripts/common/monitor_sweep.sh $HOME/results/gpt-oss-120b/nvidia_vllm/20260629_222941/ \
    /path/to/gpt-oss-120b_full_sweep.log
```

Example output:

```
=== Sweep Progress: 20260629_222941 ===
Results dir : /home/user/results/gpt-oss-120b/nvidia_vllm/20260629_222941
Log file    : /workspace/logs/gpt-oss-120b_full_sweep.log

Combos done : 47 / 84
Current srv : ==== Starting server: TP=4 ====
Current run : ---- Bench: ISL=8192 OSL=1024 CONC=64 ----
Last status : [OK] tp=4 isl=8192 osl=1024 conc=32 -> ok
Elapsed     : 3h14m
Avg/combo   : 4m08s
Est. remain : 2h32m (rough — pace varies a lot by shape/TP)

tail -f "/workspace/logs/gpt-oss-120b_full_sweep.log"
```

The ETA is a straight-line average across combos already completed, so treat
it as a rough estimate — different `(TP, shape)` combinations can take very
different amounts of time per request.

---

## Analyzing Results

Once a sweep finishes, [`analysis/summarize_results.py`](analysis/summarize_results.py)
turns its results directory (or a downloaded `.tgz` of one) into a single
Excel workbook — no manual spreadsheet wrangling of `summary.csv` and dozens
of per-combo JSON files.

The workbook has three sheets:

- **Results** — one row per `(TP, ISL, OSL, CONC)` combo, every field from the
  bench-client JSON (throughput, TTFT/TPOT/ITL/E2E latency percentiles, token
  counts, etc.), sorted numerically with a frozen header row and autofilter.
- **Run Info** — flattened `provenance.json`: model, vendor, image ref, GPU
  inventory, host info, and the `gpu-setup` git commit the sweep ran at.
- **Recipe TOML** — the exact `recipe.toml` snapshot captured at run time.

```bash
# Against a results directory
uv run analysis/summarize_results.py $HOME/results/gpt-oss-120b/nvidia_vllm/20260629_222941/

# Or directly against a downloaded .tgz archive
uv run analysis/summarize_results.py gpt-oss-120b_20260629_222941.tgz

# Explicit output path
uv run analysis/summarize_results.py gpt-oss-120b_20260629_222941.tgz -o gpt-oss-120b_report.xlsx

# One sheet per TP value (TP=1, TP=2, ...) instead of a single combined sheet
uv run analysis/summarize_results.py gpt-oss-120b_20260629_222941.tgz --split-by-tp
```

Self-contained `uv run --script` — no project venv needed. If `-o`/`--output`
is omitted, the workbook is named `<model>_<variant>_<timestamp>_summary.xlsx`
and written next to the input. Rows whose `summary.csv` status isn't `ok`
(e.g. `server_timeout`) are kept with blank metric columns rather than
dropped, so failed combos stay visible.

See [analysis/README.md](analysis/README.md) for the full field list and
additional detail.

---

## Environments

The same recipes and harness run unmodified across two kinds of host:

- **Bare-metal (or bare-metal-like) with Docker** — the original target.
  Each combo runs in its own container.
- **Native-process environments** — RunPod pods, generic GPU containers —
  where nested Docker isn't available. The server runs as a direct
  process instead; everything else (sweep matrix, results, provenance)
  works the same.

`run_recipe.sh` auto-detects which one it's on (RunPod markers, then
generic container markers, then falls back to bare-metal) and sets
`NATIVE=0`/`NATIVE=1` accordingly. Override explicitly with `--env
baremetal|container|runpod` if detection is ever wrong for your setup —
cheap to verify directly:

```bash
./environments/detect.sh   # prints "baremetal", "container", or "runpod"
```

Full details — profile variables, adding a new environment — in
[environments/README.md](environments/README.md).

---

## One-Time Host Setup (bare-metal)

Skip this whole section if you're on RunPod, a pre-built inference
container, or any box where the GPU stack + Docker are already configured
— go straight to [Running Recipes](#running-recipes) above. This section
is for taking a **fresh bare-metal Ubuntu GPU box** from stock install to
ready-for-Docker.

### Assumptions

The **only** things assumed in advance:

- OS: **Ubuntu 22.04 LTS or later** (developed on 24.04; tested on 22.04)
- One or more datacenter GPUs installed (NVIDIA or AMD)
- Root / sudo access

Everything else — driver state, CUDA/ROCm presence, kernel headers, container
toolkit — is **detected at runtime**. If a working stack is already present,
the scripts skip reinstall rather than risk breaking a working cloud image.

### Bootstrap

```bash
git clone https://github.com/russfellows/gpu-setup.git
cd gpu-setup

# 1. Dry-run: shows what was detected and the planned steps.
sudo ./bootstrap.sh

# 2. Execute. Runs common prereqs + the matching vendor setup.
sudo ./bootstrap.sh --yes

# 3. Reboot, then run the vendor verify script.
sudo reboot
sudo ./scripts/nvidia/verify_nvidia.sh   # or scripts/amd/verify_amd.sh
```

#### Detection-first behavior

Each vendor script runs a health check before installing:

- **NVIDIA**: `nvidia-smi` works, `nvcc` reports the right CUDA version, and
  Fabric Manager is active when NVSwitches are present.
- **AMD**: `rocm-smi` works, `hipcc` works, and `/opt/rocm/.info/version`
  matches the requested ROCm version.

If the stack passes, the script exits without changes. Override with
`FORCE_REINSTALL=1`.

#### Environment variables

| Variable          | Default     | Meaning                                          |
|-------------------|-------------|--------------------------------------------------|
| `PYTHON_VERSION`  | `3.12`      | Python version installed via `uv`                |
| `CUDA_VERSION`    | `13-3`      | apt suffix for `cuda-toolkit-<ver>` (NVIDIA)     |
| `ROCM_VERSION`    | `7.2.4`     | ROCm release (AMD)                               |
| `ROCM_DEB_BUILD`  | `7.2.4.70204-1` | amdgpu-install deb build suffix              |
| `FORCE_REINSTALL` | `0`         | Set `1` to skip the "already healthy" shortcut   |
| `ASSUME_YES`      | `1`         | Non-interactive apt                              |

Set `CUDA_VERSION=auto` or `ROCM_VERSION=auto` to accept whatever is already installed.

#### Manual override

```bash
# Force the NVIDIA path even if detection is ambiguous
sudo ./bootstrap.sh --yes --vendor nvidia

# Skip common prereqs (e.g., you already ran them)
sudo ./bootstrap.sh --yes --skip-common
```

### Storage setup (opt-in, separate)

Most fresh GPU boxes ship with multiple unused NVMe devices. The optional
[`scripts/common/setup_storage.sh`](scripts/common/setup_storage.sh) script
discovers them, builds an mdraid array sized to the disk count, formats it
with XFS aligned to the RAID geometry, and mounts it at `/mnt/data`.

It is intentionally **not** wired into `bootstrap.sh` — storage is destructive
and conceptually independent from the GPU stack. Run it explicitly when you
want it.

```bash
# Dry-run: prints what was detected, why anything was excluded, and the exact
# commands it would run. Default mode — totally safe.
sudo ./scripts/common/setup_storage.sh

# Once you're happy with the plan:
sudo ./scripts/common/setup_storage.sh --execute
```

#### RAID level by device count

| Disks | Layout                                                       |
|-------|--------------------------------------------------------------|
| 1     | No RAID — XFS straight on the device                         |
| 2     | RAID-1 mirror                                                |
| 3     | RAID-1 (2 active) + 1 hot spare                              |
| 4     | RAID-10                                                      |
| 5     | RAID-10 (4 active) + 1 hot spare                             |
| N ≥ 6 | RAID-10 over the largest even count ≤ N; any odd leftover is a spare |

#### Safety screen

A device is included **only** if every check passes; any tripwire excludes it:

- Not the device that hosts `/`
- Not currently mounted (anywhere, any partition)
- No filesystem / LVM / MD / swap signature (`wipefs -n` is empty)
- No existing partitions
- Not already a member of an md array (`/proc/mdstat`, `mdadm --examine`)
- Not active swap
- Not in `$EXCLUDE_DEVICES`
- Size ≥ `STORAGE_MIN_GB`

Every device is printed with the reason it was kept or skipped, so you can
audit the decision before running with `--execute`.

#### Storage env vars

| Variable           | Default     | Meaning                                                 |
|--------------------|-------------|---------------------------------------------------------|
| `STORAGE_MOUNT`    | `/mnt/data` | Mount point                                             |
| `STORAGE_MIN_GB`   | `100`       | Minimum device size considered (excludes tiny boot NVMe) |
| `STORAGE_RAID_NAME`| `data`      | md array name (becomes `/dev/md/<name>`)                |
| `EXCLUDE_DEVICES`  | (empty)     | Extra devices to skip, space-separated absolute paths   |
| `CHUNK_KB`         | `512`       | mdadm chunk size (KiB)                                  |

#### XFS geometry choices

- 4 KiB block size, 4 KiB sector size (NVMe is 4K LBA).
- 2 GiB internal log — helps metadata throughput during large model downloads.
- For RAID-10: `-d su=<chunk>,sw=<active/2>` aligns allocation to stripe geometry.
- Mount options: `defaults,noatime,nodiratime,largeio,inode64,allocsize=16m,logbufs=8,logbsize=256k`.

> Larger XFS block sizes (>4 KiB) require kernel large-block-size support that
> is still maturing on Linux. We stick with 4 KiB; the AI-workload benefit
> comes from stripe alignment + `largeio` + `allocsize=16m`, not from block size.

### Serving stack setup (opt-in)

Three independent helpers in [scripts/common/](scripts/common/) get the host
ready to run containerized inference engines. None of them are wired into
`bootstrap.sh` — run them when you want them.

```bash
# Docker CE + (NVIDIA hosts) nvidia-container-toolkit. Adds you to docker group.
sudo ./scripts/common/setup_docker.sh

# /etc/profile.d/huggingface.sh so HF_HOME=/mnt/data/huggingface for every user.
# Refuses to run if /mnt/data isn't mounted.
sudo ./scripts/common/setup_hf_env.sh

# Pre-pull vLLM / Triton / TRT-LLM / SGLang images for the detected vendor.
sudo ./scripts/common/pull_serving_images.sh             # dry-run on first call
DRY_RUN=1 ./scripts/common/pull_serving_images.sh        # show plan
```

After authenticating with `hf auth login` (and optionally `gh auth login`),
the host is ready to run recipes — see [Running Recipes](#running-recipes) above.

---

## Version

The repo version lives in the top-level [`VERSION`](VERSION) file (plain
semver, e.g. `0.2.0`) — the single source of truth, bumped by hand as part of
a PR when a change warrants it. Check it with:

```bash
./bootstrap.sh --version
./recipes/run_recipe.sh --version
cat VERSION
```

## Python tooling

Where Python is needed, scripts use [uv](https://github.com/astral-sh/uv) — no
pre-installed Python environment is assumed. The HuggingFace CLI is installed
as a `uv tool` rather than into any project venv.

## License

GNU Affero General Public License v3.0 — see [LICENSE](LICENSE).
