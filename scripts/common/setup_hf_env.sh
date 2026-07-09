#!/usr/bin/env bash
# ==============================================================================
# Hugging Face cache + env-var setup, system-wide.
#
# Writes /etc/profile.d/huggingface.sh so every interactive login shell gets
# HF_HOME pointing at the bulk-storage path. Creates the directory and hands
# ownership to the invoking user.
#
# STORAGE_MOUNT can be either a dedicated mount (separate NVMe array) or a
# plain directory on the root filesystem — both work. The only requirement is
# that the filesystem hosting STORAGE_MOUNT has at least STORAGE_MIN_GB free.
# This covers the common case where all NVMe drives form a single large root
# RAID; just create /mnt/data as a directory and everything works unchanged.
#
# Env vars:
#   HF_HOME_PATH      Cache root (default /mnt/data/huggingface)
#   STORAGE_MOUNT     Directory that must exist and have space (default /mnt/data)
#   STORAGE_MIN_GB    Minimum free GB required on that filesystem (default 100)
# ==============================================================================

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"

HF_HOME_PATH="${HF_HOME_PATH:-/mnt/data/huggingface}"
STORAGE_MOUNT="${STORAGE_MOUNT:-/mnt/data}"
STORAGE_MIN_GB="${STORAGE_MIN_GB:-100}"

need_root

REAL_USER="$(real_user)"

# ---------- Ensure STORAGE_MOUNT exists and has enough space ----------
if [ ! -d "$STORAGE_MOUNT" ]; then
  log "Creating $STORAGE_MOUNT ..."
  mkdir -p "$STORAGE_MOUNT"
fi

FREE_GB=$(df -BG "$STORAGE_MOUNT" | awk 'NR==2 {gsub("G","",$4); print $4}')
if [ "$FREE_GB" -lt "$STORAGE_MIN_GB" ]; then
  die "$STORAGE_MOUNT has only ${FREE_GB} GB free (< ${STORAGE_MIN_GB} GB). Free up space or override STORAGE_MOUNT."
fi
ok "$STORAGE_MOUNT is available (${FREE_GB} GB free)."

# ---------- Create cache dir ----------
# 1777 (sticky + world-writable): any user can create files, but only the
# owner of each file can delete it — same pattern as /tmp. Allows multiple
# users to share the model cache without re-downloading.
if [ -d "$HF_HOME_PATH" ]; then
  ok "$HF_HOME_PATH already exists."
else
  log "Creating $HF_HOME_PATH ..."
  mkdir -p "$HF_HOME_PATH"
fi
log "Setting $HF_HOME_PATH to 1777 (sticky, world-writable)..."
chmod 1777 "$HF_HOME_PATH"

# ---------- Write /etc/profile.d/huggingface.sh ----------
PROFILE="/etc/profile.d/huggingface.sh"
log "Writing $PROFILE ..."
cat >"$PROFILE" <<'EOF'
# Managed by gpu-setup: scripts/common/setup_hf_env.sh
# Hugging Face caches and downloads land on bulk storage, not the root FS.
export HF_HOME="/mnt/data/huggingface"
export HUGGINGFACE_HUB_CACHE="$HF_HOME/hub"
export HF_XET_HIGH_PERFORMANCE=1
# Recipes mount HF_HOME into containers at /root/.cache/huggingface

# Each user's token lives in their own home dir (where `hf auth login` puts
# it). HF_TOKEN_PATH tells huggingface_hub to look there rather than $HF_HOME.
export HF_TOKEN_PATH="$HOME/.cache/huggingface/token"
if [ -f "\$HF_TOKEN_PATH" ]; then
    export HF_TOKEN="\$(cat "\$HF_TOKEN_PATH")"
fi

# umask 002: new files are group-writable (664) and dirs are group-writable
# (775), so any user's model downloads are readable and usable by all users
# on this shared GPU server. The sticky bit on HF_HOME ensures users can
# only delete their own files.
umask 002
EOF
chmod 0644 "$PROFILE"

ok "HF env configured. New shells will see HF_HOME=$HF_HOME_PATH."

cat <<EOF

==============================================================================
 Next steps (run as $REAL_USER, not root):
   1. Re-source the new profile (or open a new shell):
        source $PROFILE
   2. Authenticate against the Hub:
        hf auth login
   3. Confirm a download lands under $HF_HOME_PATH:
        hf download <small-model-id>
==============================================================================
EOF
