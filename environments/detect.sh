#!/usr/bin/env bash
# ==============================================================================
# Runtime environment detection.
#
# Prints one of the following to stdout, then exits:
#   baremetal   — direct GPU access on an Ubuntu host (default)
#   container   — inside a Docker/OCI container with GPU passthrough
#   runpod      — RunPod cloud container (subset of container)
#
# Sourced by run_recipe.sh when --env is not supplied.  Can also be run
# directly to print the detected environment:
#   ./environments/detect.sh
# ==============================================================================

_detect_env() {
  # RunPod: network storage mounted at /workspace from a RunPod MFS endpoint,
  # or the RUNPOD_POD_ID env var is set by the platform.
  if [ -n "${RUNPOD_POD_ID:-}" ] || \
     mount 2>/dev/null | grep -q 'runpod\|mfs#.*runpod'; then
    echo "runpod"; return
  fi

  # Generic container: /.dockerenv is created by the Docker runtime.
  # Also catches containerd/podman runtimes that write the same marker.
  if [ -f "/.dockerenv" ] || \
     grep -q 'docker\|containerd\|lxc' /proc/1/cgroup 2>/dev/null; then
    echo "container"; return
  fi

  echo "baremetal"
}

# When sourced, export DETECTED_ENV but don't print.
# When run directly, print and exit.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  _detect_env
else
  DETECTED_ENV="$(_detect_env)"
  export DETECTED_ENV
fi
