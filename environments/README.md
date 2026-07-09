# Environments

Runtime environment profiles for the recipe harness.  Each profile is a
short bash script that sets a handful of variables consumed by `run_recipe.sh`
and `sweep.sh`.  The scripts in `scripts/` and `recipes/` are correct for
their original target (bare-metal Ubuntu); profiles add support for other
runtimes without modifying that code.

## Supported environments

| Name | Description | Key differences from baremetal |
|---|---|---|
| `baremetal` | Bare-metal Ubuntu GPU server | Default; uses Docker, `/mnt/data` |
| `container` | Generic OCI container with GPU passthrough | `NATIVE=1`, `SHARED_ROOT=/workspace/data` |
| `runpod` | RunPod cloud GPU pod | Inherits `container`; `SHARED_ROOT=/workspace/data` |

## Key variables

| Variable | Default (baremetal) | Meaning |
|---|---|---|
| `NATIVE` | `0` | `1` = run inference servers as host processes; `0` = use Docker |
| `SHARED_ROOT` | `/mnt/data` | Root of the shared storage volume |
| `HF_HOME` | `$SHARED_ROOT/huggingface` | HuggingFace model cache root |

## Using a profile

### Explicit (recommended when you know the environment)

```bash
./recipes/run_recipe.sh qwen3-next-80b nvidia_vllm --env runpod
./recipes/run_recipe.sh qwen3-next-80b nvidia_vllm --env container --dry-run
./recipes/run_recipe.sh gpt-oss-120b   nvidia_trtllm --env baremetal
```

### Auto-detect (default when --env is omitted)

`run_recipe.sh` calls `environments/detect.sh` and sources the matching
profile automatically.  Detection order:

1. RunPod markers (`RUNPOD_POD_ID` env var, or `/workspace` mounted from a
   RunPod MFS endpoint).
2. Generic container markers (`/.dockerenv`, cgroup strings).
3. Falls back to `baremetal`.

Override detection at any time:

```bash
DETECTED_ENV=container ./recipes/run_recipe.sh qwen3-next-80b nvidia_vllm
```

## Adding a new environment

1. Create `environments/<name>.sh`.  Set at minimum `NATIVE` and `SHARED_ROOT`.
   Source `container.sh` if you are inheriting container behavior.
2. Add a detection rule to `environments/detect.sh` **before** the generic
   container check.
3. Add a row to the table above.
4. Test with `--env <name> --dry-run`.

### Minimal template

```bash
#!/usr/bin/env bash
# Environment profile: <name>
# <one-line description>

export SHARED_ROOT="<path-to-persistent-storage>"

# Source container.sh for NATIVE=1 and HF_HOME defaults.
source "$(dirname "${BASH_SOURCE[0]}")/container.sh"
```
