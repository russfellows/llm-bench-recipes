#!/usr/bin/env bash
# ==============================================================================
# Environment profile: baremetal
#
# Bare-metal Ubuntu GPU server — the original target for this repo.
# This profile is a no-op: all defaults in sweep.sh and the setup scripts
# already target this environment.  It exists so --env baremetal can be
# passed explicitly and documented clearly.
#
# Assumptions:
#   - GPU drivers installed by scripts/nvidia/setup_nvidia.sh or
#     scripts/amd/setup_amd_rocm.sh
#   - Docker installed by scripts/common/setup_docker.sh
#   - HF env written by scripts/common/setup_hf_env.sh
#     (sets HF_HOME=/mnt/data/huggingface, sources from /etc/profile.d/)
#   - SHARED_ROOT=/mnt/data (a real mount, not a symlink)
# ==============================================================================

# No overrides needed: sweep.sh NATIVE defaults to 0 (docker), and
# HF_HOME defaults to /mnt/data/huggingface if not set.
: "${NATIVE:=0}"
: "${SHARED_ROOT:=/mnt/data}"
: "${HF_HOME:=${SHARED_ROOT}/huggingface}"

export NATIVE SHARED_ROOT HF_HOME
