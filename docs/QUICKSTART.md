# Quickstart — Running Benchmarks on a GPU Server

This guide is for someone who has been given access to a GPU server that is
**already set up** (drivers, Docker, storage, and HF credentials configured).
If you are setting up a fresh box from scratch, start with the [root README](../README.md).

---

## 1. Verify your environment

Run through the checklist below **before** trying to launch any recipe. Most
failures come from one of these being wrong.

### 1a. GPU stack

```bash
# AMD
rocm-smi                        # should list all GPUs
hipcc --version                 # should print ROCm version

# NVIDIA
nvidia-smi                      # should list all GPUs
nvcc --version                  # should print CUDA version
```

If `rocm-smi` or `nvidia-smi` is not found, the drivers aren't installed.
Run `sudo ./scripts/amd/setup_amd_rocm.sh` or `sudo ./scripts/nvidia/setup_nvidia.sh`,
then reboot.

### 1b. Docker

```bash
docker info                     # must succeed without sudo
docker run --rm hello-world     # end-to-end smoke test
```

If `docker info` fails with "permission denied", your user is not in the
`docker` group. Fix:
```bash
sudo usermod -aG docker $USER
newgrp docker                   # takes effect in the current shell
                                # or log out and back in
```

**AMD only** — verify GPU passthrough works in Docker:
```bash
docker run --rm \
    --device=/dev/kfd --device=/dev/dri \
    --group-add="$(getent group video  | cut -d: -f3)" \
    --group-add="$(getent group render | cut -d: -f3)" \
    rocm/rocm-terminal rocm-smi
```

**NVIDIA only** — verify GPU passthrough:
```bash
docker run --rm --gpus all nvidia/cuda:12.0-base-ubuntu22.04 nvidia-smi
```

### 1c. Environment variables

The following env vars must be set in your shell session. They are written to
`/etc/profile.d/huggingface.sh` by `setup_hf_env.sh` and sourced automatically
by every new login shell.

```bash
# Check all at once
echo "HF_HOME            = $HF_HOME"
echo "HUGGINGFACE_HUB_CACHE = $HUGGINGFACE_HUB_CACHE"
echo "HF_TOKEN_PATH      = $HF_TOKEN_PATH"
echo "HF_XET_HIGH_PERFORMANCE = $HF_XET_HIGH_PERFORMANCE"
```

Expected values:

| Variable | Expected value |
|---|---|
| `HF_HOME` | `/mnt/data/huggingface` |
| `HUGGINGFACE_HUB_CACHE` | `/mnt/data/huggingface/hub` |
| `HF_TOKEN_PATH` | `$HOME/.cache/huggingface/token` |
| `HF_XET_HIGH_PERFORMANCE` | `1` |

If any are blank or wrong, either run `source /etc/profile.d/huggingface.sh`
(quick fix for this session) or open a new login shell. If the file doesn't
exist at all, run `sudo ./scripts/common/setup_hf_env.sh`.

### 1d. Hugging Face authentication

```bash
# Check if you are logged in
cat "$HF_TOKEN_PATH"            # should print your token (starts with "hf_")

# If empty or missing, log in
hf auth login                   # prompts for a token from hf.co/settings/tokens

# Confirm the token is valid and HF_HOME is correct
hf whoami                       # should print your HF username
```

If `hf` is not found on PATH, run `source ~/.profile` or open a new shell.
The CLI is installed to `~/.local/bin` by `uv tool install huggingface_hub`.

**`HF_TOKEN` for recipes.** Recipes forward the `HF_TOKEN` environment
variable into containers so the model download inside the container is
authenticated. The profile script reads `$HF_TOKEN_PATH` and exports
`HF_TOKEN` automatically on every new login shell. The harness also reads
`HF_TOKEN_PATH` directly as a fallback if `HF_TOKEN` is not set in the
current session.

```bash
# Verify the token is set in your current session:
echo $HF_TOKEN | head -c 10    # should print "hf_..." (first 10 chars)
```

If `HF_TOKEN` is empty, either open a new shell (to re-source the profile)
or re-authenticate with `hf auth login`.

### 1e. Storage

```bash
df -h /mnt/data                 # check free space — models need 100s of GB
ls /mnt/data/huggingface/       # should exist; may already contain model dirs
```

If `/mnt/data` doesn't exist or is tiny (it's sitting on the root FS with
little space), you need either:
- A dedicated NVMe array: `sudo ./scripts/common/setup_storage.sh --execute`
- Or simply enough space on your root FS — `setup_hf_env.sh` will use a
  plain directory if needed, but make sure you have headroom.

---

## 2. Verify everything with one command

```bash
./recipes/run_recipe.sh qwen3-next-80b amd_vllm --dry-run
```

A successful dry-run prints the SWEEP PLAN and exits without launching
anything. If it errors, the message will tell you exactly what is missing
(bad env var, missing Docker group, image not found, etc.).

---

## 3. Download model weights (first time only)

Recipes download model weights automatically on first run. To pre-download
and verify the weights land in the shared cache:

```bash
# gpt-oss-120b (ungated)
HF_XET_HIGH_PERFORMANCE=1 hf download openai/gpt-oss-120b \
    --exclude "original/*" --exclude "metal/*"

# Kimi-K2.6 AMD variant (gated — HF_TOKEN required)
hf download amd/Kimi-K2.6-MXFP4

# Kimi-K2.6 NVIDIA variant (gated)
hf download nvidia/Kimi-K2.6-NVFP4

# Qwen3-Next-80B (gated)
hf download Qwen/Qwen3-Next-80B-A3B-Instruct-FP8

# Confirm they are in the shared cache
ls $HF_HOME/hub/
```

All users on this server share the cache at `/mnt/data/huggingface`. If
someone else has already downloaded a model, it's already there — no need to
re-download.

---

## 4. Run a recipe

```bash
# See what's available
./recipes/run_recipe.sh --list

# Smoke test — single small shape, 4 concurrent requests
./recipes/run_recipe.sh gpt-oss-120b amd_atom \
    --tp 4 --shapes "1024,1024" --conc 4

# Full sweep with recipe defaults
./recipes/run_recipe.sh qwen3-next-80b amd_vllm

# Override the matrix
./recipes/run_recipe.sh kimi-k2.6 amd_vllm \
    --tp 4 --shapes "1024,1024 1024,8192 8192,1024" --conc "4 8 16 32 64"
```

Results land under `$HOME/results/<model>/<variant>/<timestamp>/`. See
[recipes/README.md](../recipes/README.md) for the full results layout.

---

## 5. Check results

```bash
# Summary of the last run
LATEST=$(ls -t ~/results/qwen3-next-80b/amd_vllm/ | head -1)
cat ~/results/qwen3-next-80b/amd_vllm/$LATEST/summary.csv

# Per-combo metrics (JSON)
python3 -c "
import json, sys
d = json.load(open('$HOME/results/qwen3-next-80b/amd_vllm/$LATEST/*.json'.replace('*', \
    '$(ls ~/results/qwen3-next-80b/amd_vllm/$LATEST/*.json 2>/dev/null | head -1 | xargs basename 2>/dev/null)')))
for k,v in d.items():
    if 'throughput' in k or 'ttft' in k or 'tpot' in k or 'e2el' in k:
        print(f'{k}: {v:.2f}' if isinstance(v,float) else f'{k}: {v}')
"

# Server log (to check for AITER tuning misses or warnings)
cat ~/results/qwen3-next-80b/amd_vllm/$LATEST/server_*.log | grep -iE "warn|error|not found tuned"
```

---

## Common problems

| Symptom | Likely cause | Fix |
|---|---|---|
| `docker: permission denied` | Not in docker group | `sudo usermod -aG docker $USER && newgrp docker` |
| `Unable to find group render` | Old Docker flag style | Already fixed in harness; update your repo |
| `HF_TOKEN is not set` | Profile not sourced | `source /etc/profile.d/huggingface.sh` or new shell |
| `OSError: <model> is not a valid model` | Wrong model_id or no HF auth | `hf auth login`, confirm `echo $HF_TOKEN` |
| `server_timeout` in summary.csv | Server didn't start in time | Check server log; for Kimi the Inductor compile takes 30+ min on first run — `ready_timeout_s = 3600` is set |
| Result JSON has two objects (parse error) | Old harness bug | Already fixed — update your repo |
| Result files owned by root | Old harness bug | Already fixed — update your repo |
| `not found tuned config` in server log | AITER BF16 tuning CSV missing | Known issue for Kimi-K2.6 BF16 path; see `recipes/kimi-k2.6/README.md` |
