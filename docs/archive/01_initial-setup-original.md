# Initial Setup Scripts
Here is a complete, production-ready bash script tailored for **Ubuntu 24.04** to handle all core system tools, development utilities, the GitHub CLI, Python environments, and the Hugging Face CLI ecosystem.

This script focuses entirely on software orchestration and avoids touching any underlying graphics processing stacks.

---

### 1. Prerequisites Setup Script (`setup_prereqs.sh`)

Adding `uv` to this workflow is an excellent choice. Developed by Astral (in Rust), `uv` is blindingly fast and completely replaces the need for `python3-venv` and `pip`. It can even manage underlying Python versions dynamically, ensuring you are using the exact same Python interpreter version on both your AMD and NVIDIA test machines without relying on system updates.

Here is the updated, unified `setup_prereqs.sh` script for **Ubuntu 24.04**. It handles the core tools, provisions `uv`, and shifts the python architecture over to it.

---

## 1. Updated Prerequisites Setup Script (`setup_prereqs.sh`)

```bash
#!/usr/bin/env bash

# ==============================================================================
# vLLM Benchmarking Setup Script (UV Optimized)
# Target OS: Ubuntu 24.04 LTS
# ==============================================================================

set -e

echo "=== 1. Updating System Package Index ==="
sudo apt update && sudo apt upgrade -y

echo "=== 2. Installing Essential Build & Utility Tooling ==="
# Base OS infrastructure utilities needed for testing and processing data
sudo apt install -y \
    curl \
    wget \
    git \
    gnupg \
    gcc \
    g++ \
    make \
    build-essential \
    jq \
    tmux \
    htop

echo "=== 3. Installing and Configuring 'uv' Runtime ==="
# Download and execute the official standalone Astral installer script
curl -LsSf https://astral.sh/uv/install.sh | sh

# Inject uv binaries into the active script subshell path immediately
export PATH="$HOME/.local/bin:$PATH"

# Set up specific explicit python variant via uv (Python 3.10 chosen for baseline vLLM alignment)
uv python install 3.10

echo "=== 4. Setting Up Official GitHub CLI Repository ==="
sudo mkdir -p -m 755 /etc/apt/keyrings
out=$(mktemp)
wget -nv -O"$out" https://cli.github.com/packages/githubcli-archive-keyring.gpg
cat "$out" | sudo tee /etc/apt/keyrings/githubcli-archive-keyring.gpg > /dev/null
sudo chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | \
sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null

echo "=== 5. Installing GitHub CLI ==="
sudo apt update
sudo apt install -y gh

echo "=== 6. Initializing Virtual Environment via 'uv' ==="
PROJECT_DIR="$HOME/llm-bench"
mkdir -p "$PROJECT_DIR"
cd "$PROJECT_DIR"

# 'uv venv' completely circumvents standard slow virtualenv processes
if [ ! -d ".venv" ]; then
    uv venv --python 3.10
    echo "Virtual environment successfully initialized by uv."
fi

echo "=== 7. Installing Packages via 'uv pip' ==="
# Installs packages at lightning-fast speeds into the local environment
uv pip install "huggingface_hub[cli]"
uv pip install \
    yfinance \
    pandas \
    numpy \
    matplotlib \
    gradio \
    plotly \
    requests \
    aiohttp \
    langchain \
    langchain-community

echo "=============================================================================="
echo " SYSTEM ENVIRONMENT PROVISIONING COMPLETE (UV-POWERED)"
echo "=============================================================================="
echo " Next Steps Required:"
echo " 1. Activate your environment:  source $PROJECT_DIR/.venv/bin/activate"
echo " 2. Authenticate Git via CLI:   gh auth login"
echo " 3. Authenticate Hugging Face:  huggingface-cli login"
echo "=============================================================================="

```

---

## 2. Levering `uv` Features for your Benchmark Workspace

Because you are using `uv`, you don't even have to use traditional activation loops (`source .venv/bin/activate`) if you don't want to. `uv` allows for modular, clean command invocation:

### Explicit Context Execution (`uv run`)

If you want to run your test benchmark scripts inside your exact workspace dependencies environment without ever manually activating the `.venv` shell, run it directly with:

```bash
cd ~/llm-bench
uv run run_benchmark.py 16

```

### Script Execution with Ephemeral Dependencies

Let's say you have a single standalone utility file (like a quick graph plotter or diagnostic script) that needs a specific library, but you don't want to permanently install that library to your project directory cache. You can run it on the fly:

```bash
# This downloads and maps 'scikit-learn' to an ephemeral context, runs the command, and discards it
uv run --with scikit-learn quick_verify_script.py

```

### Keep `uv` Current

To ensure you are utilizing the newest caching optimizations, update `uv` natively anytime by executing:

```bash
uv self update

```

## 3. Post-Setup Verification Check Ledger

Run these commands to verify that `uv` is properly hooked into your ecosystem:

```bash
# Verify uv version
uv --version

# List all fast packages managed inside your clean testing directory
cd ~/llm-bench
uv pip list

```

---

### 2. Interactive Authentications to Run Post-Script

Once the script completes successfully, you must run the following verification interactive logins from your terminal session to connect to your remote gateways:

### GitHub Account Authentication

Run this to log in to GitHub, which automatically handles your git credentials without needing to manually map SSH profiles:

```bash
gh auth login

```

* **Account type:** `GitHub.com`
* **Preferred Protocol:** `HTTPS` (highly recommended for bare-metal remote testing)
* **Authentication Method:** `Login with a web browser` (copy the device token output, hit enter, and verify it on your remote machine).

### Hugging Face Access Token Mapping

Since your benchmark uses vLLM to serve gated and non-gated model instances like `microsoft/Phi-4` or Llama models directly into your custom API configurations, log in to fetch your model cache:

```bash
huggingface-cli login

```

*(Generate a **Read** token inside your Hugging Face Account Settings -> Access Tokens, paste it into the terminal prompt, and confirm).*

---

### 3. Post-Setup Verification Check Ledger

To double-check that your dependencies are completely bound and healthy before deploying your automated benchmark files, check your tool versions:

```bash
# Verify the GitHub CLI works
gh --version

# Activate your new environment array 
source ~/llm-bench/venv/bin/activate

# Check if the Hugging Face engine tools are responsive
huggingface-cli --help

# Ensure Python matches the required modules from your repository architecture
python3 -c "import yfinance, gradio, plotly, aiohttp; print('All explicit Python modules verified successfully.')"

```
