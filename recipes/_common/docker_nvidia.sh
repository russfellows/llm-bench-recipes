#!/usr/bin/env bash
# Standard NVIDIA docker-run flag bundle.
# Sourced by sweep.sh. Sets the array NVIDIA_DOCKER_FLAGS.
#
# Requires nvidia-container-toolkit to be installed and registered with
# docker (scripts/common/setup_docker.sh / scripts/nvidia/setup_nvidia.sh
# handle that).

# shellcheck disable=SC2034  # used externally by sweep.sh via source
NVIDIA_DOCKER_FLAGS=(
  --runtime=nvidia
  --gpus=all
  --ipc=host
  --network=host
  --ulimit=memlock=-1
  --ulimit=stack=67108864
  --shm-size=64g
)
