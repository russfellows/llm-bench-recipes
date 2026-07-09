#!/usr/bin/env bash
# ==============================================================================
# Common prerequisites for a fresh Ubuntu 24.04 GPU box.
#
# Vendor-neutral. Installs:
#   - Base build/utility tooling (curl, git, build-essential, jq, tmux, htop, ...)
#   - uv  (Astral) with a pinned Python interpreter
#   - GitHub CLI (gh)
#   - Hugging Face CLI (via uv tool install)
#
# Detection-first: every step checks whether a working version is already
# present and skips reinstall if so. Many cloud GPU images already ship these.
#
# Env vars:
#   PYTHON_VERSION   Python version uv should install (default: 3.12)
#   ASSUME_YES       If "1", run apt non-interactively (default: 1)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

PYTHON_VERSION="${PYTHON_VERSION:-3.12}"
ASSUME_YES="${ASSUME_YES:-1}"
APT_FLAGS=(-y)
[ "$ASSUME_YES" = "1" ] && export DEBIAN_FRONTEND=noninteractive

need_root
require_ubuntu_2204_plus

REAL_USER="$(real_user)"
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)"
log "Setting up prerequisites for user: $REAL_USER (home: $REAL_HOME)"

# ---------- 1. Base packages ----------
BASE_PKGS=(curl wget git gnupg ca-certificates lsb-release software-properties-common
           build-essential gcc g++ make cmake ninja-build pkg-config
           jq tmux htop unzip)

missing=()
for pkg in "${BASE_PKGS[@]}"; do
  dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
done

if [ "${#missing[@]}" -eq 0 ]; then
  ok "Base packages already installed."
else
  log "Installing base packages: ${missing[*]}"
  apt-get update
  apt-get "${APT_FLAGS[@]}" install "${missing[@]}"
fi

# ---------- 2. uv ----------
# uv is installed to ~/.local/bin for REAL_USER, not root.
UV_BIN="${REAL_HOME}/.local/bin/uv"
if [ -x "$UV_BIN" ] && sudo -u "$REAL_USER" "$UV_BIN" --version >/dev/null 2>&1; then
  ok "uv already installed: $(sudo -u "$REAL_USER" "$UV_BIN" --version)"
else
  log "Installing uv for user $REAL_USER..."
  sudo -u "$REAL_USER" bash -lc 'curl -LsSf https://astral.sh/uv/install.sh | sh'
fi

# Pin a specific Python via uv.
if sudo -u "$REAL_USER" "$UV_BIN" python list --only-installed 2>/dev/null \
     | grep -q "cpython-${PYTHON_VERSION}"; then
  ok "Python ${PYTHON_VERSION} already managed by uv."
else
  log "Installing Python ${PYTHON_VERSION} via uv..."
  sudo -u "$REAL_USER" "$UV_BIN" python install "${PYTHON_VERSION}"
fi

# ---------- 3. GitHub CLI ----------
if smoke gh --version; then
  ok "gh already installed: $(gh --version | head -1)"
else
  log "Setting up GitHub CLI apt repository..."
  install -d -m 0755 /etc/apt/keyrings
  if [ ! -s /etc/apt/keyrings/githubcli-archive-keyring.gpg ]; then
    tmp="$(mktemp)"
    wget -nv -O "$tmp" https://cli.github.com/packages/githubcli-archive-keyring.gpg
    install -m 0644 "$tmp" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    rm -f "$tmp"
  fi
  cat >/etc/apt/sources.list.d/github-cli.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main
EOF
  apt-get update
  apt-get "${APT_FLAGS[@]}" install gh
fi

# ---------- 4. Hugging Face CLI ----------
# Install as a uv tool under REAL_USER so it lands in ~/.local/bin without
# polluting any project venv.
if sudo -u "$REAL_USER" bash -lc 'command -v hf' >/dev/null 2>&1; then
  ok "Hugging Face CLI ('hf') already available."
else
  log "Installing huggingface_hub[cli] as a uv tool..."
  sudo -u "$REAL_USER" "$UV_BIN" tool install 'huggingface_hub[cli]'
fi

# ---------- Done ----------
cat <<EOF

==============================================================================
 Common prerequisites complete.
==============================================================================
 Next steps (run as $REAL_USER, not root):
   1. Re-source your shell so ~/.local/bin is on PATH:
        exec \$SHELL -l
   2. Authenticate GitHub:    gh auth login
   3. Authenticate HF Hub:    hf auth login
   4. Run the vendor-specific GPU setup (NVIDIA or AMD), or use bootstrap.sh.
==============================================================================
EOF
