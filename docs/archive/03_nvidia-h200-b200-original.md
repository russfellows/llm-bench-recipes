# NVIDIA H200 / B200 Multi-GPU Setup Scripts - Steps

This guide and script are optimized for multi-GPU environments using **HGX H200/B200 architectures**.

> ⚠️ **CRITICAL GOTCHA:** Without the **Fabric Manager** daemon tracking your driver version exactly, multi-GPU systems will throw a cryptic `Error 802: system not yet initialized` when running workloads, despite `nvidia-smi` showing healthy cards. The script completely automates this.

### `setup_nvidia_h200_b200.sh`

Save the script below to your server, make it executable (`chmod +x setup_nvidia_h200_b200.sh`), and run it with `sudo ./setup_nvidia_h200_b200.sh`.

```bash
#!/usr/bin/env bash

set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root (sudo)"
  exit 1
fi

echo "===================================================="
# Check Ubuntu version
OS_VER=$(. /etc/os-release; echo "$VERSION_ID")
if [ "$OS_VER" != "24.04" ]; then
  echo "⚠️ Warning: This script was battle-tested on Ubuntu 24.04. Found: $OS_VER"
fi

# 0. Pre-flight Checks
echo "🚀 Running pre-flight system checks..."
if mokutil --sb-state | grep -q "enabled"; then
  echo "❌ Error: SecureBoot is ENABLED. DKMS modules require signing. Please disable SecureBoot in BIOS."
  exit 1
else
  echo "✅ SecureBoot is disabled."
fi

echo "📦 Installing required linux headers..."
apt-get update && apt-get install -y "linux-headers-$(uname -r)"

HAS_NVSWITCH=$(lspci | grep -ci nvswitch || true)
if [ "$HAS_NVSWITCH" -gt 0 ]; then
  echo "🖥️  Detected $HAS_NVSWITCH NVSwitches. Fabric Manager installation is MANDATORY."
else
  echo "ℹ️  No NVSwitches detected via lspci. Fabric Manager will still be installed as a baseline."
fi

# 1. Clean Purge Stale Packages
echo "🧹 Purging any existing/broken NVIDIA installations..."
PURGE=$(dpkg-query -W -f='${Package}\n' | grep -E '^(cuda|nvidia|libnvidia|nsight)' | grep -v '^cuda-keyring' || true)
if [ -not -z "$PURGE" ]; then
  apt-get -y purge $PURGE
  apt-get -y autoremove --purge
fi
rm -rf /usr/local/cuda*

# 2. Install CUDA Toolkit + Open-Module Drivers
echo "⚙️ Installing CUDA Toolkit 13.3 and Open Kernel Drivers..."
apt-get update
apt-get -y install cuda-toolkit-13-3 nvidia-open

echo "📝 Configuring system-wide environment paths..."
cat << 'EOF' > /etc/profile.d/cuda.sh
export PATH=/usr/local/cuda/bin:$PATH
export LD_LIBRARY_PATH=/usr/local/cuda/lib64:$LD_LIBRARY_PATH
EOF
chmod +x /etc/profile.d/cuda.sh

# 3. Fabric Manager Setup
echo "🚀 Installing unversioned Fabric Manager..."
apt-get -y install nvidia-fabricmanager
echo "🔄 Enabling fabricmanager to start cleanly at system boot..."
systemctl enable nvidia-fabricmanager

# 4. Container Runtime Engine Setup
if command -v docker &> /dev/null; then
  echo "🐳 Configuring NVIDIA Container Toolkit for Docker..."
  apt-get -y install nvidia-container-toolkit
  nvidia-ctk runtime configure --runtime=docker
  systemctl restart docker
else
  echo "⚠️ Docker not detected. Skipping Container Toolkit configurations."
fi

echo "===================================================="
echo "🎉 System automation phase complete!"
echo "⚠️  A system reboot is REQUIRED to synchronize the open driver module and the Fabric Manager."
echo "👉 Please run: sudo reboot"
echo "===================================================="

```

### Post-Reboot Verification Steps

Once the system has cycled back online, verify the active stack using these checks:

```bash
# 1. Verify CUDA version matches 13.3
bash -lc 'nvcc --version | grep release'

# 2. Verify driver version maps up correctly
nvidia-smi | head -4

# 3. Check NVLink Fabric Interconnect status (Must output 'Completed' for all nodes)
nvidia-smi -q | grep -A1 Fabric | grep State

# 4. End-to-End Container Compute Verification
docker run --rm --runtime nvidia --gpus all --entrypoint python3 \
  vllm/vllm-openai:latest -c 'import torch; print("CUDA Functional:", torch.cuda.is_available(), "| Active GPUs:", torch.cuda.device_count())'

```

### Day 2: Serving LLMs via vLLM

Deploy high-throughput inference on your H200/B200 cluster using the following container orchestration block:

```bash
docker run -d --runtime nvidia --gpus all --network=host --ipc=host \
  -v /path/to/model-cache:/root/.cache/huggingface \
  -e HUGGING_FACE_HUB_TOKEN=$HF_TOKEN \
  vllm/vllm-openai:latest \
  --model <repo-id> \
  --tensor-parallel-size 8 \
  --max-model-len 32768 \
  --max-num-seqs 8 \
  --host 0.0.0.0 \
  --port 8000

```

---

