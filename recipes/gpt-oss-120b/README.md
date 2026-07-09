# gpt-oss-120b

OpenAI [`gpt-oss-120b`](https://huggingface.co/openai/gpt-oss-120b) — 120B
parameter open-weights model. Configuration in this directory benchmarks
it on three stacks.

## Variants

| Variant         | Vendor | Stack           | Bench tool |
|-----------------|--------|-----------------|------------|
| `nvidia_vllm`   | NVIDIA | vLLM            | vllm       |
| `amd_atom`      | AMD    | ATOM            | atom       |
| `nvidia_trtllm` | NVIDIA | TensorRT-LLM    | openai     |

`nvidia_trtllm` uses the stack-agnostic `openai` bench client
(`recipes/_common/bench_openai.py`), not `vllm bench serve` — the
NVIDIA TensorRT-LLM release container this variant targets does not ship
vLLM, and installing it just for its bench CLI risks a torch/CUDA
version conflict with the TRT-LLM engine actually being benchmarked. See
[recipes/README.md](../README.md#recipe-toml-schema) for how `bench_tool`
resolves by default per stack.

`nvidia_trtllm` also runs **natively** (no Docker) when the detected
environment has `NATIVE=1` (RunPod, generic GPU containers — see
[environments/README.md](../../environments/README.md)) since nested
Docker isn't available there; it needs the model already downloaded to
the local HF cache; `HF_HUB_OFFLINE=1` is set on the server process so it
never attempts a mid-sweep download.

The NVIDIA variant's `trtllm-serve` LLM-API options live in
`[variants.nvidia_trtllm.runtime_config]` inside `recipe.toml`. The harness
materializes them as JSON in the results directory at run time and mounts
them at `@RECIPE_DIR@/runtime_config.json` — no YAML on disk.

## Default sweep matrix

- TP: 1, 2, 4, 8
- ISL,OSL: 1024/1024, 1024/8192, 8192/1024
- Concurrency: 4, 8, 16, 32, 64, 128, 256

Override per-run from the CLI:

```bash
./recipes/run_recipe.sh gpt-oss-120b amd_atom \
    --tp 1,2 --shapes "1024,1024" --conc "16 32 64"
```

## Prerequisites

- Model weights cached. Download once with:
  ```bash
  HF_XET_HIGH_PERFORMANCE=1 hf download openai/gpt-oss-120b \
      --exclude "original/*" --exclude "metal/*"
  ```
- HF_TOKEN exported if needed (this repo is currently ungated, but the
  recipe forwards `HF_TOKEN` regardless).
