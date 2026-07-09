#!/usr/bin/env bash
# One-time RunPod pod setup — run once to bootstrap a fresh pod.
#
# Installs Node.js and Claude Code to /workspace so they persist across
# pod restarts. Also saves SSH authorized_keys to /workspace/.ssh and
# writes /workspace/gpu-env.sh from the repo template.
#
# After this completes, set 'bash /workspace/setup.sh' as the pod's
# Start Command in the RunPod console.

set -euo pipefail

WORKSPACE=/workspace
NODE_VERSION=22.13.0
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

echo "=== Step 1: Node.js -> /workspace/node ==="
if [ ! -f "$WORKSPACE/node/bin/node" ]; then
  cd "$WORKSPACE"
  curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-x64.tar.xz" \
    | tar -xJ --no-same-owner
  mv "node-v${NODE_VERSION}-linux-x64" node
  echo "  Installed: $($WORKSPACE/node/bin/node --version)"
else
  echo "  Already installed: $($WORKSPACE/node/bin/node --version)"
fi

export PATH="$WORKSPACE/node/bin:$WORKSPACE/npm-global/bin:$PATH"

echo "=== Step 2: Claude Code -> /workspace/npm-global ==="
mkdir -p "$WORKSPACE/npm-global"
npm config set prefix "$WORKSPACE/npm-global"
npm install -g @anthropic-ai/claude-code 2>&1 | tail -3
echo "  Claude Code: $(claude --version)"

echo "=== Step 3: Save SSH authorized_keys to /workspace/.ssh ==="
mkdir -p "$WORKSPACE/.ssh"
if [ -f /root/.ssh/authorized_keys ]; then
  cp /root/.ssh/authorized_keys "$WORKSPACE/.ssh/authorized_keys"
  chmod 700 "$WORKSPACE/.ssh" && chmod 600 "$WORKSPACE/.ssh/authorized_keys"
  echo "  Saved."
else
  echo "  WARNING: /root/.ssh/authorized_keys not found — SSH keys not saved."
fi

echo "=== Step 4: Install gpu-env.sh to /workspace ==="
if [ ! -f "$WORKSPACE/gpu-env.sh" ]; then
  cp "$REPO_DIR/scripts/runpod/gpu-env.sh" "$WORKSPACE/gpu-env.sh"
  echo "  Copied from repo."
else
  echo "  Already exists at /workspace/gpu-env.sh (not overwritten)."
fi

echo ""
echo "=== All done! ==="
echo "  Next steps:"
echo "    1. Set pod Start Command: bash /workspace/setup.sh"
echo "    2. Set ANTHROPIC_API_KEY as a RunPod pod secret (not in any file)"
echo "    3. Run: hf auth login   (to authenticate with HuggingFace)"
