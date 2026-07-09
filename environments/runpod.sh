#!/usr/bin/env bash
# ==============================================================================
# Environment profile: runpod
#
# RunPod cloud GPU pod.  We are inside a container managed by the RunPod
# platform.  The persistent network volume is mounted at /workspace (a
# RunPod MFS endpoint); everything that must survive pod restarts lives there.
#
# Storage layout on RunPod:
#   /workspace          — persistent network volume (100s of TB available)
#   /workspace/data     — SHARED_ROOT: model cache, results, torch compile cache
#   /mnt/data           — symlink -> /workspace/data (for script compatibility)
#   /                   — ephemeral overlay FS (~30 GB, lost on restart)
#
# To add vLLM or other inference packages, install them into a persistent venv:
#   uv venv /workspace/venv --python 3.12
#   source /workspace/venv/bin/activate
#   uv pip install vllm==<version>
# Then add `source /workspace/venv/bin/activate` to your pod start command.
# ==============================================================================

# RunPod uses /workspace as its persistent volume.
export SHARED_ROOT="/workspace/data"

# Delegate common container setup (sets NATIVE=1, HF_HOME, /mnt/data symlink).
# shellcheck source=container.sh
source "$(dirname "${BASH_SOURCE[0]}")/container.sh"
