#!/usr/bin/env bash
# GPU server environment for RunPod — source this on every pod restart.
#
# Copy this file to /workspace/gpu-env.sh once, then reference it from
# setup.sh (the pod start command). It persists on /workspace across restarts.
#
# What this does:
#   - Sets SHARED_ROOT, HF cache vars
#   - Creates ~/.cache/uv -> /workspace/.uv-cache symlink (survives restarts)
#   - Recreates /mnt/data -> /workspace/data symlink (ephemeral each restart)
#   - Activates the persistent vLLM venv at /workspace/venv
#   - Exports HF_TOKEN from ~/.cache/huggingface/token if present

export SHARED_ROOT="/workspace/data"

# uv cache: keep on /workspace so it survives pod restarts.
# The symlink catches writes to ~/.cache/uv before UV_CACHE_DIR is exported.
export UV_CACHE_DIR="/workspace/.uv-cache"
mkdir -p "$UV_CACHE_DIR" 2>/dev/null || true
if [ ! -L "$HOME/.cache/uv" ]; then
  mkdir -p "$HOME/.cache" 2>/dev/null || true
  rm -rf "$HOME/.cache/uv" 2>/dev/null || true
  ln -sfn "$UV_CACHE_DIR" "$HOME/.cache/uv" 2>/dev/null || true
fi

# /mnt/data symlink is on the ephemeral root FS — recreate each restart.
if [ ! -L /mnt/data ] && [ ! -e /mnt/data ]; then
  mkdir -p /mnt 2>/dev/null || true
  ln -sfn "$SHARED_ROOT" /mnt/data 2>/dev/null || true
fi

export HF_HOME="$SHARED_ROOT/huggingface"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"

# Disable XET high-performance mode: XET stores blobs in CAS chunk format
# that requires reconstruction on read. The reconstruction fails intermittently
# under load ("Background writer channel closed"), corrupting model loads.
# Standard HTTP download writes plain safetensors files that vLLM reads directly.
export HF_HUB_DISABLE_XET=1
unset HF_XET_HIGH_PERFORMANCE

export HF_TOKEN_PATH="$HOME/.cache/huggingface/token"
if [ -f "$HF_TOKEN_PATH" ]; then
  HF_TOKEN="$(cat "$HF_TOKEN_PATH")"
  export HF_TOKEN
fi

# Activate the persistent vLLM venv (installed in /workspace/venv).
if [ -f "/workspace/venv/bin/activate" ]; then
  # shellcheck disable=SC1091
  source /workspace/venv/bin/activate
fi

umask 002
