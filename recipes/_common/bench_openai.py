#!/usr/bin/env python3
"""
Stack-agnostic OpenAI-compatible endpoint benchmark.

Accepts the same CLI interface as `vllm bench serve` so it works as a
drop-in replacement for any server (TRT-LLM, vLLM, SGLang, etc.) that
exposes a /v1/completions endpoint.  Results are saved in the same JSON
schema used by vllm bench serve so downstream tooling is unaffected.

Usage (via bench_client.sh / sweep.sh):
    python3 bench_openai.py --model <id> --base-url http://host:port \
        --random-input-len 1024 --random-output-len 1024 \
        --num-prompts 160 --num-warmups 32 --max-concurrency 16 \
        --save-result --result-dir /results --result-filename out.json
"""
import argparse
import asyncio
import json
import math
import os
import random
import statistics
import sys
import time
from pathlib import Path
from typing import Dict, List, Optional, Tuple

import openai as _openai


# ---------------------------------------------------------------------------
# Prompt generation
# ---------------------------------------------------------------------------

def _build_vocab(size: int = 4096) -> List[str]:
    """Deterministic pseudo-word vocabulary for reproducible prompts."""
    rng = random.Random(42)
    letters = "abcdefghijklmnopqrstuvwxyz"
    words: set = set()
    while len(words) < size:
        words.add("".join(rng.choices(letters, k=rng.randint(3, 9))))
    return sorted(words)


_VOCAB = _build_vocab()


def _load_tokenizer(model_path: str):
    """Try to load a HuggingFace tokenizer from a local or hub path."""
    try:
        from transformers import AutoTokenizer
        return AutoTokenizer.from_pretrained(model_path, local_files_only=True)
    except Exception:
        pass
    try:
        from transformers import AutoTokenizer
        return AutoTokenizer.from_pretrained(model_path)
    except Exception:
        return None


def _sample_len(target_tokens: int, range_ratio: float) -> int:
    """
    Sample a request length uniformly from the symmetric range vLLM's own
    `vllm bench serve` uses: [floor(target*(1-ratio)), ceil(target*(1+ratio))].
    Matches `vllm.benchmarks.datasets.utils.get_sampling_params` (verified
    against vllm 0.24.0 source) — ratio=0 means every request is exactly
    `target_tokens`; ratio must be in [0, 1) per that same implementation.
    """
    if range_ratio <= 0:
        return target_tokens
    lo = max(1, math.floor(target_tokens * (1.0 - range_ratio)))
    hi = max(lo, math.ceil(target_tokens * (1.0 + range_ratio)))
    return random.randint(lo, hi)


def _make_prompt(target_tokens: int, tokenizer) -> str:
    """
    Return a random prompt with exactly `target_tokens` input tokens (the
    caller is responsible for having already applied random-range-ratio
    jitter to `target_tokens`). If a tokenizer is provided it is used for
    exact counting; otherwise we fall back to a ~4-chars/token approximation.
    """
    if tokenizer is not None:
        words: List[str] = []
        while True:
            words.extend(random.choices(_VOCAB, k=64))
            text = " ".join(words)
            n = len(tokenizer.encode(text, add_special_tokens=False))
            if n >= target_tokens:
                # Trim back to exactly target tokens.
                while n > target_tokens and words:
                    words.pop()
                    n = len(tokenizer.encode(" ".join(words), add_special_tokens=False))
                return " ".join(words)
    else:
        target_chars = target_tokens * 4
        words = []
        chars = 0
        while chars < target_chars:
            w = random.choice(_VOCAB)
            words.append(w)
            chars += len(w) + 1
        return " ".join(words)


# ---------------------------------------------------------------------------
# Per-request result container
# ---------------------------------------------------------------------------

class _RequestResult:
    __slots__ = ("ttft_ms", "itl_ms", "e2el_ms", "output_tokens", "success", "error")

    def __init__(self) -> None:
        self.ttft_ms: Optional[float] = None
        self.itl_ms: List[float] = []
        self.e2el_ms: Optional[float] = None
        self.output_tokens: int = 0
        self.success: bool = False
        self.error: Optional[str] = None


# ---------------------------------------------------------------------------
# Single async request
# ---------------------------------------------------------------------------

async def _do_request(
    client: _openai.AsyncOpenAI,
    model: str,
    prompt: str,
    max_tokens: int,
    sem: asyncio.Semaphore,
    ignore_eos: bool,
    tokenizer,
) -> _RequestResult:
    res = _RequestResult()
    async with sem:
        t0 = time.perf_counter()
        t_last = t0
        first_token = True
        usage_tokens: Optional[int] = None
        try:
            # ignore_eos alone only stops the EOS token from ending
            # generation early — it does not guarantee the engine actually
            # generates max_tokens; min_tokens is an independent floor and
            # both must be set together to force a fixed output length.
            extra_body = {"ignore_eos": True, "min_tokens": max_tokens} if ignore_eos else {}
            stream = await client.completions.create(
                model=model,
                prompt=prompt,
                max_tokens=max_tokens,
                stream=True,
                temperature=1.0,
                stream_options={"include_usage": True},
                extra_body=extra_body,
            )
            async for chunk in stream:
                now = time.perf_counter()
                # The final chunk of an include_usage stream carries a
                # populated `usage` and typically empty `choices` — this is
                # the only server-authoritative token count. Chunk *count*
                # is not a proxy for token count: servers commonly batch
                # several tokens per network chunk (TRT-LLM's
                # stream_interval, for instance), which silently deflated
                # output_tokens by ~10x when we counted 1 per chunk here.
                usage = getattr(chunk, "usage", None)
                if usage is not None:
                    usage_tokens = usage.completion_tokens
                text = chunk.choices[0].text if chunk.choices else ""
                if not text:
                    continue
                # Tokenize this chunk's text to know how many real tokens
                # it represents, so a multi-token chunk contributes that
                # many samples to the ITL distribution instead of one.
                n_tokens = len(tokenizer.encode(text, add_special_tokens=False)) if tokenizer else 1
                n_tokens = max(1, n_tokens)
                if first_token:
                    res.ttft_ms = (now - t0) * 1000.0
                    first_token = False
                else:
                    per_token_gap = (now - t_last) * 1000.0 / n_tokens
                    res.itl_ms.extend([per_token_gap] * n_tokens)
                res.output_tokens += n_tokens
                t_last = now
            # Authoritative count always wins over our tokenized estimate
            # when the server provides one.
            if usage_tokens is not None:
                res.output_tokens = usage_tokens
            res.e2el_ms = (time.perf_counter() - t0) * 1000.0
            res.success = True
        except Exception as exc:
            res.error = str(exc)
    return res


# ---------------------------------------------------------------------------
# Resolve the model name the server is actually using
# ---------------------------------------------------------------------------

async def _resolve_model_name(client: _openai.AsyncOpenAI, requested: str) -> str:
    """
    Query /v1/models and return the best match for `requested`.
    Falls back to `requested` unchanged if the endpoint is unavailable or
    if the name is already an exact match.
    """
    try:
        models = await client.models.list()
        ids = [m.id for m in models.data]
        if not ids:
            return requested
        if requested in ids:
            return requested
        # Prefer an ID that ends with the basename of a local path.
        basename = os.path.basename(requested.rstrip("/"))
        for mid in ids:
            if mid.endswith(basename) or basename in mid:
                return mid
        # Fall back to the first model the server advertises.
        print(
            f"[warn] Requested model '{requested}' not found in /v1/models "
            f"({ids}); using '{ids[0]}'",
            file=sys.stderr,
        )
        return ids[0]
    except Exception:
        return requested


# ---------------------------------------------------------------------------
# Statistics helpers
# ---------------------------------------------------------------------------

def _percentiles(data: List[float], pcts: List[int]) -> Dict[str, Optional[float]]:
    if not data:
        return {str(p): None for p in pcts}
    s = sorted(data)
    n = len(s)
    out: Dict[str, Optional[float]] = {}
    for p in pcts:
        idx = min(int(math.ceil(p / 100.0 * n)) - 1, n - 1)
        out[str(p)] = round(s[max(0, idx)], 3)
    return out


def _stats(data: List[float]) -> Tuple[float, float, float]:
    if not data:
        return 0.0, 0.0, 0.0
    mean = statistics.mean(data)
    median = statistics.median(data)
    std = statistics.stdev(data) if len(data) > 1 else 0.0
    return round(mean, 3), round(median, 3), round(std, 3)


# ---------------------------------------------------------------------------
# Main benchmark coroutine
# ---------------------------------------------------------------------------

async def _run(args: argparse.Namespace) -> dict:
    if not (0.0 <= args.random_range_ratio < 1.0):
        print(
            f"[error] --random-range-ratio must be in [0, 1), got "
            f"{args.random_range_ratio}",
            file=sys.stderr,
        )
        sys.exit(1)

    tokenizer = _load_tokenizer(args.model)
    if tokenizer is None:
        print(
            f"[warn] Could not load tokenizer for '{args.model}'; "
            "using ~4-chars/token approximation for prompt length.",
            file=sys.stderr,
        )

    total_requests = args.num_prompts + args.num_warmups
    # Input and output lengths are jittered independently — matching vLLM's
    # own `get_sampling_params`, which draws each from its own
    # [target*(1-ratio), target*(1+ratio)] range rather than tying OSL to
    # whatever ISL happened to sample.
    input_lens = [
        _sample_len(args.random_input_len, args.random_range_ratio)
        for _ in range(total_requests)
    ]
    output_lens = [
        _sample_len(args.random_output_len, args.random_range_ratio)
        for _ in range(total_requests)
    ]
    prompts = [_make_prompt(input_lens[i], tokenizer) for i in range(total_requests)]

    # The OpenAI SDK does not append a version prefix on its own — base_url
    # must already end in /v1, or every request 404s against the bare path
    # (e.g. POST /completions instead of POST /v1/completions). All the
    # OpenAI-compatible servers we target (trtllm-serve, vllm serve,
    # SGLang) mount their routes under /v1, so normalize here rather than
    # relying on every caller to remember the suffix.
    base_url = args.base_url.rstrip("/")
    if not base_url.endswith("/v1"):
        base_url += "/v1"
    client = _openai.AsyncOpenAI(base_url=base_url, api_key="ignored")
    serving_model = await _resolve_model_name(client, args.model)
    if serving_model != args.model:
        print(f"[info] Using server model name: '{serving_model}'", file=sys.stderr)

    sem = asyncio.Semaphore(args.max_concurrency)

    async def _batch(indices: List[int]) -> List[_RequestResult]:
        tasks = [
            _do_request(
                client,
                serving_model,
                prompts[i],
                output_lens[i],
                sem,
                args.ignore_eos,
                tokenizer,
            )
            for i in indices
        ]
        return await asyncio.gather(*tasks)

    if args.num_warmups > 0:
        print(f"[info] Warming up with {args.num_warmups} requests …", file=sys.stderr)
        await _batch(list(range(args.num_warmups)))

    print(
        f"[info] Benchmarking {args.num_prompts} requests "
        f"(concurrency={args.max_concurrency}, "
        f"isl={args.random_input_len}, osl={args.random_output_len}) …",
        file=sys.stderr,
    )
    bench_indices = list(range(args.num_warmups, total_requests))
    t_start = time.perf_counter()
    results = await _batch(bench_indices)
    duration = time.perf_counter() - t_start

    ok_pairs = [(i, r) for i, r in zip(bench_indices, results) if r.success]
    ok = [r for _, r in ok_pairs]
    failed = len(results) - len(ok)
    if failed:
        sample = next((r.error for r in results if not r.success), "unknown")
        print(f"[warn] {failed} request(s) failed. Sample error: {sample}", file=sys.stderr)

    pcts = [int(x) for x in args.metric_percentiles.split(",")]
    metric_names = {m.strip() for m in args.percentile_metrics.split(",")}

    ttfts  = [r.ttft_ms  for r in ok if r.ttft_ms  is not None]
    e2els  = [r.e2el_ms  for r in ok if r.e2el_ms  is not None]
    itls   = [ms for r in ok for ms in r.itl_ms]
    tpots  = [
        (r.e2el_ms - r.ttft_ms) / max(1, r.output_tokens - 1)
        for r in ok
        if r.e2el_ms is not None and r.ttft_ms is not None and r.output_tokens > 1
    ]

    total_out = sum(r.output_tokens for r in ok)
    # Actual sampled ISL per request, not the nominal target — range_ratio
    # jitter means these differ whenever range_ratio > 0.
    total_in  = sum(input_lens[i] for i, _ in ok_pairs)

    output: dict = {
        "backend":               "openai",
        "model_id":              args.model,
        "num_prompts":           args.num_prompts,
        "max_concurrency":       args.max_concurrency,
        "random_input_len":      args.random_input_len,
        "random_output_len":     args.random_output_len,
        "duration":              round(duration, 3),
        "completed":             len(ok),
        "failed":                failed,
        "total_input_tokens":    total_in,
        "total_output_tokens":   total_out,
        "request_throughput":    round(len(ok) / duration, 3),
        "output_throughput":     round(total_out / duration, 3),
        "total_token_throughput": round((total_in + total_out) / duration, 3),
    }

    for metric, data in [("ttft", ttfts), ("tpot", tpots), ("itl", itls), ("e2el", e2els)]:
        if metric not in metric_names:
            continue
        mean, median, std = _stats(data)
        output[f"mean_{metric}_ms"]        = mean
        output[f"median_{metric}_ms"]      = median
        output[f"std_{metric}_ms"]         = std
        output[f"percentiles_{metric}_ms"] = _percentiles(data, pcts)

    return output


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def _parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(
        description="OpenAI-compatible endpoint benchmark (stack-agnostic)."
    )
    p.add_argument("--model",              required=True,  help="Model ID or local path passed to --model in the API request.")
    p.add_argument("--base-url",           required=True,  help="Base URL of the serving endpoint, e.g. http://localhost:8000")
    p.add_argument("--backend",            default="openai", help="Ignored; present for CLI compatibility with vllm bench serve.")
    p.add_argument("--dataset-name",       default="random")
    p.add_argument("--random-input-len",   type=int, required=True)
    p.add_argument("--random-output-len",  type=int, required=True)
    p.add_argument(
        "--random-range-ratio",
        type=float,
        default=0.0,
        help=(
            "Jitter ISL/OSL independently within "
            "[target*(1-ratio), target*(1+ratio)], matching `vllm bench "
            "serve`'s own semantics. Must be in [0, 1); 0 (the default, "
            "also vLLM's) means every request uses exactly the nominal "
            "ISL/OSL."
        ),
    )
    p.add_argument("--num-prompts",        type=int, required=True)
    p.add_argument("--num-warmups",        type=int, default=0)
    p.add_argument("--max-concurrency",    type=int, required=True)
    p.add_argument("--request-rate",       default="inf", help="Ignored; concurrency-based pacing only.")
    p.add_argument("--ignore-eos",         action="store_true")
    p.add_argument("--save-result",        action="store_true")
    p.add_argument("--result-dir",         default=".")
    p.add_argument("--result-filename",    required=True)
    p.add_argument("--percentile-metrics", default="ttft,tpot,itl,e2el")
    p.add_argument("--metric-percentiles", default="25,50,75,90,95,99")
    p.add_argument("--trust-remote-code",  action="store_true", help="Ignored; present for CLI compatibility.")
    return p.parse_args()


def main() -> None:
    args = _parse_args()
    result = asyncio.run(_run(args))

    print(json.dumps(result, indent=2))

    if args.save_result:
        out_path = Path(args.result_dir) / args.result_filename
        out_path.parent.mkdir(parents=True, exist_ok=True)
        with open(out_path, "w") as fh:
            json.dump(result, fh, indent=2)
        print(f"[info] Result saved → {out_path}", file=sys.stderr)

    # A totally-dead endpoint (wrong URL, server never actually came up
    # despite passing the ready-marker check, auth rejected, etc.) must
    # surface as a failure to the caller. The JSON is still written above
    # so the failure is diagnosable, but sweep.sh's `if run_bench; then …`
    # needs a real exit code — silently exiting 0 here is what let a
    # 100%-failed run masquerade as "ok" in summary.csv.
    if result["completed"] == 0 and args.num_prompts > 0:
        print(
            f"[error] All {result['failed']} request(s) failed — "
            "treating this combo as a bench failure.",
            file=sys.stderr,
        )
        sys.exit(1)


if __name__ == "__main__":
    main()
