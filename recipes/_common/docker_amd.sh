#!/usr/bin/env bash
# Standard AMD ROCm docker-run flag bundle.
# Sourced by sweep.sh. Sets the array AMD_DOCKER_FLAGS.
#
# Mirrors the device pass-through pattern that AMD GPU containers expect:
# /dev/kfd for the compute driver, /dev/dri for display/render, plus the
# render+video groups so the container's processes can talk to them.

# shellcheck disable=SC2034  # used externally by sweep.sh via source
AMD_DOCKER_FLAGS=(
  --device=/dev/kfd
  --device=/dev/dri
  --group-add="$(getent group video  2>/dev/null | cut -d: -f3 || true)"
  --group-add="$(getent group render 2>/dev/null | cut -d: -f3 || true)"
  --ipc=host
  --network=host
  --cap-add=SYS_PTRACE
  --security-opt=seccomp=unconfined
  --shm-size=64g
)
