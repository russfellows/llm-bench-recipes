# Archive — original drafts

These three markdown files were the seed material for `llm-bench-recipes`. They are
preserved as a historical reference. The current, fixed scripts live under
[`../../scripts/`](../../scripts/) and are dispatched by
[`../../bootstrap.sh`](../../bootstrap.sh).

| File | Replaced by |
|------|-------------|
| `01_initial-setup-original.md` | `scripts/common/setup_prereqs.sh` |
| `02_amd-mi300x-rocm-original.md` | `scripts/amd/setup_amd_rocm.sh`, `scripts/amd/verify_amd.sh` |
| `03_nvidia-h200-b200-original.md` | `scripts/nvidia/setup_nvidia.sh`, `scripts/nvidia/verify_nvidia.sh` |

Notable corrections made in the port:

- NVIDIA: fixed `[ -not -z "$PURGE" ]` (invalid test) → `[ -n "$PURGE" ]`.
- NVIDIA: added the missing `cuda-keyring` apt repo setup before installing
  `cuda-toolkit-*`, and the missing NVIDIA Container Toolkit apt repo before
  `nvidia-container-toolkit`.
- Common: removed workload-specific extras (a project directory and
  `yfinance/gradio/plotly/langchain`) that were unrelated to
  general-purpose GPU bring-up.
- Common: pinned Python **3.12** instead of 3.10.
- All scripts: added a detection-first pass that skips reinstall when an
  existing healthy stack is present.
- All scripts: vendor versions parameterized via `CUDA_VERSION` / `ROCM_VERSION`
  environment variables.
- Added `bootstrap.sh` at the top level for `lspci`-driven detection and
  dispatch.
