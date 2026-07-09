#!/usr/bin/env bash
# Pod start command — run this on every RunPod pod restart.
#
# Set this as the pod's "Start Command" in the RunPod console, or call it
# from your container's entrypoint. It is safe to run multiple times.
#
# Prerequisites (one-time, run first-time-setup.sh):
#   - Node.js installed at /workspace/node
#   - Claude Code installed at /workspace/npm-global
#   - SSH authorized_keys saved to /workspace/.ssh/authorized_keys
#   - gpu-env.sh present at /workspace/gpu-env.sh

set -euo pipefail

# ---- SSH keys ---------------------------------------------------------------
if [ -f /workspace/.ssh/authorized_keys ]; then
  mkdir -p /root/.ssh
  cp /workspace/.ssh/authorized_keys /root/.ssh/authorized_keys
  chmod 700 /root/.ssh && chmod 600 /root/.ssh/authorized_keys
fi

# ---- PATH for persistent Node.js + Claude Code ------------------------------
export PATH="/workspace/node/bin:/workspace/npm-global/bin:$PATH"
{
  echo 'export PATH=/workspace/node/bin:/workspace/npm-global/bin:$PATH'
} >> /root/.bashrc

# ---- GPU environment (HF cache, uv cache, vLLM venv) -----------------------
if [ -f /workspace/gpu-env.sh ]; then
  # shellcheck disable=SC1091
  source /workspace/gpu-env.sh
  # Install to /etc/profile.d so all login shells pick it up this session.
  cp /workspace/gpu-env.sh /etc/profile.d/gpu-env.sh 2>/dev/null || true
fi

# ---- API keys ---------------------------------------------------------------
# Set ANTHROPIC_API_KEY in the RunPod console as a pod secret / env var,
# or add the export below (never commit secrets to the repo):
#
#   export ANTHROPIC_API_KEY="sk-ant-..."
#   echo 'export ANTHROPIC_API_KEY="sk-ant-..."' >> /root/.bashrc

# ---- Summary ----------------------------------------------------------------
NODE_VER=$(node --version 2>/dev/null || echo "not installed")
CLAUDE_VER=$(claude --version 2>/dev/null || echo "not installed")
echo "=== RunPod setup complete ==="
echo "  Node.js : $NODE_VER"
echo "  Claude  : $CLAUDE_VER"
echo "  SSH     : $([ -f /root/.ssh/authorized_keys ] && echo 'authorized_keys restored' || echo 'no keys found')"
echo "  GPU env : $([ -f /workspace/gpu-env.sh ] && echo 'sourced' || echo 'gpu-env.sh not found')"
