# analysis/

Post-hoc reporting tools for sweep results. These run *after* a sweep
finishes — typically on a laptop, against a results directory downloaded
from the GPU box (or a `.tgz` of one) — not as part of the on-box harness
in `recipes/`.

## summarize_results.py

Turns one sweep's results directory (or its `.tgz` archive) into a single
Excel workbook:

- **Results** — one row per `(TP, ISL, OSL, CONC)` combo, every field from
  the bench-client JSON (`vllm bench serve` / ATOM / the stack-agnostic
  `openai` client's `bench_openai.py`): throughput, TTFT/TPOT/ITL/E2E
  latency percentiles, token counts, etc. Sorted numerically by
  TP/ISL/OSL/CONC, with a frozen header row and autofilter. Any
  dict-valued field (e.g. `bench_openai.py`'s nested
  `percentiles_ttft_ms: {"25": ..., "50": ...}`, vs. vLLM's flat
  `p25_ttft_ms`) is flattened one level into its own columns rather than
  crashing the write — openpyxl cells can only hold scalars. With
  `--split-by-tp`, this becomes one sheet per TP value (`TP=1`, `TP=2`,
  ...) instead of a single combined sheet — the now-redundant `tp` column
  is dropped from each per-TP sheet.
- **Run Info** — flattened `provenance.json`: model, vendor, image ref,
  GPU inventory, host info, and the `gpu-setup` git commit the sweep ran at.
- **Recipe TOML** — the exact `recipe.toml` snapshot captured at run time.

Self-contained `uv run --script` — no project venv needed:

```bash
uv run analysis/summarize_results.py results/gpt-oss-120b/nvidia_vllm/20260629_222941/
# or directly against a downloaded archive:
uv run analysis/summarize_results.py gpt-oss-120b_20260629_222941.tgz

# explicit output path
uv run analysis/summarize_results.py gpt-oss-120b_20260629_222941.tgz -o gpt-oss-120b_report.xlsx

# one sheet per TP value instead of a single combined Results sheet
uv run analysis/summarize_results.py gpt-oss-120b_20260629_222941.tgz --split-by-tp
```

If `-o`/`--output` is omitted, the workbook is named
`<model>_<variant>_<timestamp>_summary.xlsx` and written next to the input.

Rows whose `summary.csv` status isn't `ok` (e.g. `server_timeout`) are kept
in the sheet with blank metric columns rather than dropped, so failed combos
stay visible.

A `.tgz` may wrap the results directory in any parent path (e.g. a full
`workspace/` tree) — the script searches for the `summary.csv` it contains
and uses that directory.
