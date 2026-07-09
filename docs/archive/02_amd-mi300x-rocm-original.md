# AMD MI300X ROCm Setup Scripts - Steps

This guide and script are optimized for the **AMD Instinct MI300X (gfx942)** hardware ecosystem.

> ⚠️ **CRITICAL GOTCHA:** AMD does not use a separate Fabric Manager (xGMI is entirely managed by the driver kernel). However, you must execute precise **Repository Hygiene** before running `amdgpu-install`. If stale `.list` configuration files exist in your apt paths, `dpkg` will trigger an interactive deadlock, hanging your automation indefinitely.

### `setup_amd_mi300x.sh`

Save the script below to your server, make it executable (`chmod +x setup_amd_mi300x.sh`), and run it with `sudo ./setup_amd_mi300x.sh`.

```bash
#!/usr/bin/env bash

set -euo pipefail

# Ensure script is run as root
if [ "$EUID" -ne 0 ]; then
  echo "❌ Please run as root (sudo)"
  exit 1
fi

# Detect calling user if run with sudo to apply permissions later
REAL_USER=${SUDO_USER:-$USER}

echo "===================================================="
OS_VER=$(. /etc/os-release; echo "$VERSION_ID")
if [ "$OS_VER" != "24.04" ]; then
  echo "⚠️ Warning: This script was battle-tested on Ubuntu 24.04. Found: $OS_VER"
fi

# 0. Pre-flight Checks
echo "🚀 Running pre-flight system checks..."
if mokutil --sb-state | grep -q "enabled"; then
  echo "❌ Error: SecureBoot is ENABLED. Please disable SecureBoot in BIOS."
  exit 1
fi

# 1. Repository Hygiene & Kernel Locks
echo "🛡️ Pinning kernel version to safe build profiles..."
apt-mark hold linux-image-generic linux-headers-generic

echo "🧹 Clearing legacy/stale Radeon package lists to mitigate conffile deadlocks..."
rm -f /etc/apt/sources.list.d/amdgpu.list \
      /etc/apt/sources.list.d/rocm.list \
      /etc/apt/preferences.d/rocm-pin-600

# Fetch version-pinned amdgpu installer bundle (ROCm 7.2.4)
echo "📥 Downloading AMD repository package tool..."
wget https://repo.radeon.com/amdgpu-install/7.2.4/ubuntu/noble/amdgpu-install_7.2.4.70204-1_all.deb
apt-get install -y ./amdgpu-install_7.2.4.70204-1_all.deb
rm -f ./amdgpu-install_7.2.4.70204-1_all.deb

# Refresh AMD GPG Keys
echo "🔑 Updating GPG keys for repository confirmation..."
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | gpg --dearmor | tee /etc/apt/keyrings/rocm.gpg >/dev/null
apt-get update

# 2. Clean-Remove Stale ROCm Builds
echo "🗑️ Purging existing ROCm frameworks..."
amdgpu-install -y --uninstall || true
apt-get -y autoremove --purge
rm -rf /opt/rocm-6.* /opt/rocm

# 3. Main Stream System Installs
echo "📦 Injecting active kernel prerequisites..."
apt-get -y install "linux-headers-$(uname -r)" "linux-modules-extra-$(uname -r)"

echo "⚙️ Executing amdgpu-install for DKMS and Compute profiles..."
amdgpu-install -y --usecase=dkms,rocm

# 4. Host System Integration
echo "👥 Assigning permissions for user '$REAL_USER' to kernel drivers (/dev/kfd)..."
usermod -a -G render,video "$REAL_USER"

echo "🔗 Setting up Shared Library runtime paths..."
echo -e "/opt/rocm/lib\n/opt/rocm/lib64" | tee /etc/ld.so.conf.d/rocm.conf
ldconfig

echo "===================================================="
echo "🎉 AMD Instinct Automation Phase Complete!"
echo "⚠️  A system reboot is REQUIRED to properly initialize the amdgpu DKMS module."
echo "👉 Please run: sudo reboot"
echo "===================================================="

```

### Post-Reboot Verification Steps

Once the system has cycled back online, verify your hardware capabilities. Because `rocm-smi` status can sometimes report structural layouts incorrectly, compile a direct test script to verify raw execution logic:

```bash
# 1. Output version tags
cat /opt/rocm/.info/version

# 2. Verify active GPU metrics via SMI trackers
rocm-smi --showproductname | grep -c 'Card Series'

# 3. Generate and compile a test binary to verify the HIP compiler
cat > /tmp/verify_hip.cpp << 'EOF'
#include <hip/hip_runtime.h>
#include <cstdio>

__global__ void add(float* a, float* b, float* c, int n) {
    int i = blockIdx.x * blockDim.x + threadIdx.x;
    if (i < n) c[i] = a[i] + b[i];
}

int main() {
    int nd;
    hipGetDeviceCount(&nd);
    printf("HIP devices detected: %d\n", nd);
    
    int n = 1 << 20;
    size_t s = n * sizeof(float);
    float *a, *b, *c;
    
    hipMallocManaged(&a, s);
    hipMallocManaged(&b, s);
    hipMallocManaged(&c, s);
    
    for(int i=0; i<n; i++) {
        a[i] = 1.5f;
        b[i] = 2.5f;
    }
    
    add<<<(n+255)/256, 256>>>(a, b, c, n);
    hipDeviceSynchronize();
    
    double sum = 0;
    for(int i=0; i<n; i++) sum += c[i];
    printf("Compute Matrix Verification Result: %s\n", sum == 4.0 * n ? "PASS" : "FAIL");
    
    hipFree(a); hipFree(b); hipFree(c);
    return 0;
}
EOF

# Compile and execute the test binary
/opt/rocm/bin/hipcc /tmp/verify_hip.cpp -o /tmp/verify_hip && /tmp/verify_hip

```

### Day 2: Serving LLMs via vLLM on AMD

AMD architectures require no native container toolkit utilities. Pass down direct device nodes (`/dev/kfd` and `/dev/dri`) alongside group profiles:

```bash
docker run -d --device=/dev/kfd --device=/dev/dri \
  --group-add video --group-add render \
  --network=host --ipc=host --security-opt seccomp=unconfined \
  -v /path/to/models:/root/.cache/huggingface \
  rocm/vllm:latest \
  --model <repo-id> \
  --tensor-parallel-size 8 \
  -e VLLM_ROCM_USE_AITER=1 \
  --attention-backend ROCM_AITER_FA \
  --host 0.0.0.0 \
  --port 8000

```

> 💡 **Performance Note:** Passing `-e VLLM_ROCM_USE_AITER=1` maps execution vectors into the custom AMD optimized attention kernels. Skipping this flag can drop matrix calculation speeds by up to 6×.