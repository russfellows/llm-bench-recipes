# kimi-k2.6

Moonshot Kimi-K2.6, configured per-vendor with FP4-quantized weights:

- **AMD**: [`amd/Kimi-K2.6-MXFP4`](https://huggingface.co/amd/Kimi-K2.6-MXFP4)
  — MXFP4 weights+activations on a locally-built vLLM-rocm image that
  patches an AITER FP4 tuning CSV into a pinned vLLM-rocm nightly.
- **NVIDIA**: [`nvidia/Kimi-K2.6-NVFP4`](https://huggingface.co/nvidia/Kimi-K2.6-NVFP4)
  — NVFP4 weights, served on stock `vllm/vllm-openai:v0.21.0`.

> If you specifically need the explicit "Thinking" branch rather than the
> base K2.6 release, AMD also publishes
> [`amd/Kimi-K2-Thinking-MXFP4`](https://huggingface.co/amd/Kimi-K2-Thinking-MXFP4).
> Override the model id by editing `recipe.toml`.

## Variants

| Variant              | Vendor | Stack | Model                                                                       | Notes                                                       |
|----------------------|--------|-------|-----------------------------------------------------------------------------|-------------------------------------------------------------|
| `amd_vllm`           | AMD    | vLLM  | [`amd/Kimi-K2.6-MXFP4`](https://huggingface.co/amd/Kimi-K2.6-MXFP4)         | Pinned base + AITER CSV. **Reproducible — default.**        |
| `amd_vllm_nightly`   | AMD    | vLLM  | [`amd/Kimi-K2.6-MXFP4`](https://huggingface.co/amd/Kimi-K2.6-MXFP4)         | `rocm/vllm-dev:nightly_main` + AITER CSV. Floating tag — not reproducible. |
| `amd_vllm_quark`     | AMD    | vLLM  | [`amd/Kimi-K2.6-MXFP4`](https://huggingface.co/amd/Kimi-K2.6-MXFP4)         | Above + `amd-quark` from source. Matches the model-card build recipe most closely. |
| `nvidia_vllm`        | NVIDIA | vLLM  | [`nvidia/Kimi-K2.6-NVFP4`](https://huggingface.co/nvidia/Kimi-K2.6-NVFP4)   | `vllm/vllm-openai:v0.21.0`. Pinned, reproducible.           |

### Choosing an AMD variant

- **`amd_vllm`** — the right default. Pinned base image digest, pinned AITER
  commit. Re-runs are bit-identical and comparable across weeks/months.
- **`amd_vllm_nightly`** — same recipe but on a floating nightly base. Use to
  isolate "what does the base image alone change?"
- **`amd_vllm_quark`** — adds `amd-quark` from source on top. Use when
  reproducing the model-card build recipe.

Every run captures the resolved image digest, base image, and build args in
`provenance.json` alongside the bench results, so the floating-tag variants
are still auditable after the fact.

## Default sweep matrix

- TP: 4, 8
- ISL,OSL: 1024/1024, 1024/8192, 8192/1024
- Concurrency: 4, 8, 16, 32, 64, 128, 256

Override per-run:
```bash
./recipes/run_recipe.sh kimi-k2.6 amd_vllm --conc "16 32 64"
```

## How the AMD image is built

The first time `amd_vllm` runs, the harness builds
`llm-bench-recipes/vllm-rocm-kimi-k2-6-mxfp4:local` from
[Dockerfile.amd_vllm](Dockerfile.amd_vllm). The Dockerfile pins:

- Base image: `vllm/vllm-openai-rocm:nightly-04c2a8deac44fdb1ca3e2b5ec3e6bf16f3f6a914`
- AITER commit (for the CSV fetch): `78ef4be9d621e3660c89cfb611679fb12fe10ed4`

Both pins matter for reproducibility — update them deliberately when you
want a newer baseline. Subsequent runs reuse the locally built image.

## Caveats

- `max-model-len` is set to **16384** so 8k/8k shapes fit. If you sweep
  larger shapes, edit `recipe.toml`.
- `max-num-seqs` is set to **512**. Concurrencies above 512 will queue.
- The NVIDIA variant sets `TORCH_CUDA_ARCH_LIST=10.0`, which targets
  Blackwell (B200 etc.). For Hopper (H100/H200) override with
  `EXTRA_DOCKER_ENV` or change in `recipe.toml`.
- **KV cache is the real concurrency ceiling at TP=4, not `max-num-seqs`.**
  Kimi-K2.6 is a very large model, so at TP=4 on an 8x B200 NVFP4 run its
  weights leave little HBM for KV cache (~404k tokens observed, i.e. vLLM's
  own "Maximum concurrency" log line reported ~25x for a 16k-token request)
  — nowhere close to `max-num-seqs=512` or the higher end of the default
  `sweep_conc`. For the 8k-context shapes (`1024,8192` / `8192,1024`),
  concurrencies past ~25-40 queue behind KV-cache pressure rather than
  reflecting steady-state throughput, and TTFT balloons accordingly (seen:
  minutes, not milliseconds, at c128/c256). TP=8 roughly doubles the KV
  cache budget (mirrors gpt-oss-120b's TP4→TP8 scaling) and is now in
  `sweep_tp` for this reason — prefer it over TP=4 when trusting the
  high-concurrency, long-context rows.
