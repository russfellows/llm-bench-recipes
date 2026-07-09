#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = []
# ///
"""
Write provenance.json into the results directory before a sweep starts.

The point: every sweep MUST record exactly what was run so results can be
compared apples-to-apples weeks/months later — image digest, base image
for built images, build args, sweep matrix, the full recipe.toml as it
existed at run time, and a basic GPU inventory.

Inputs come via env vars (set by sweep.sh) so we don't have to thread
two dozen CLI args:

    PROV_RESULTS_DIR    Target directory (must already exist).
    PROV_TIMESTAMP      ISO timestamp string.
    PROV_MODEL_NAME, PROV_VARIANT_NAME, PROV_MODEL_ID,
    PROV_VENDOR, PROV_STACK, PROV_IMAGE
    PROV_BASE_IMAGE     (optional) base image for builds.
    PROV_BUILD_ARGS     (optional) "K1=V1\nK2=V2" — newline separated.
    PROV_DOCKERFILE     (optional) path to the Dockerfile that built IMAGE.
    PROV_SWEEP_TP, PROV_SWEEP_ISL_OSL, PROV_SWEEP_CONC
    PROV_RECIPE_TOML    Path to the recipe.toml on disk.
"""
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


def env(name: str, default: str = "") -> str:
    return os.environ.get(name, default)


def sh(cmd: list[str]) -> str:
    try:
        out = subprocess.check_output(cmd, stderr=subprocess.DEVNULL, text=True)
        return out.strip()
    except Exception:
        return ""


def docker_inspect(image_ref: str) -> dict:
    if not image_ref or not shutil.which("docker"):
        return {}
    raw = sh(["docker", "image", "inspect", image_ref])
    if not raw:
        return {}
    try:
        items = json.loads(raw)
    except json.JSONDecodeError:
        return {}
    if not items:
        return {}
    info = items[0]
    return {
        "id":           info.get("Id"),
        "repo_digests": info.get("RepoDigests", []),
        "repo_tags":    info.get("RepoTags", []),
        "created":      info.get("Created"),
        "architecture": info.get("Architecture"),
        "os":           info.get("Os"),
        "size_bytes":   info.get("Size"),
    }


def gpu_summary() -> dict:
    out = {"nvidia": None, "amd": None, "lspci": []}
    if shutil.which("nvidia-smi"):
        s = sh(["nvidia-smi", "--query-gpu=index,name,driver_version,memory.total",
                "--format=csv,noheader"])
        if s:
            out["nvidia"] = [line.strip() for line in s.splitlines()]
    if shutil.which("rocm-smi"):
        s = sh(["rocm-smi", "--showproductname"])
        if s:
            out["amd"] = s.splitlines()
    s = sh(["bash", "-c",
            "lspci -nn 2>/dev/null | grep -E '\\[(0300|0302|0380)\\]' | grep -iE 'nvidia|amd|advanced micro'"])
    if s:
        out["lspci"] = s.splitlines()
    return out


def gpu_setup_repo_info() -> dict:
    # The "gpu-setup" working tree root — three levels up from this file.
    repo = Path(__file__).resolve().parents[2]
    if not (repo / ".git").is_dir():
        return {"path": str(repo), "git": None}
    commit = sh(["git", "-C", str(repo), "rev-parse", "HEAD"])
    short  = sh(["git", "-C", str(repo), "rev-parse", "--short", "HEAD"])
    status = sh(["git", "-C", str(repo), "status", "--porcelain"])
    return {
        "path":   str(repo),
        "commit": commit or None,
        "short":  short or None,
        "dirty":  bool(status),
    }


def parse_build_args(raw: str) -> dict:
    out = {}
    for line in (raw or "").splitlines():
        line = line.strip()
        if not line or "=" not in line:
            continue
        k, _, v = line.partition("=")
        out[k.strip()] = v.strip()
    return out


def main() -> int:
    results_dir = Path(env("PROV_RESULTS_DIR"))
    if not results_dir.is_dir():
        print(f"PROV_RESULTS_DIR not a directory: {results_dir}", file=sys.stderr)
        return 1

    image_ref = env("PROV_IMAGE")
    image_info = docker_inspect(image_ref)

    build = None
    base = env("PROV_BASE_IMAGE")
    dfile = env("PROV_DOCKERFILE")
    args  = parse_build_args(env("PROV_BUILD_ARGS"))
    if base or dfile or args:
        build = {
            "base_image":      base or None,
            "dockerfile_path": dfile or None,
            "build_args":      args,
        }

    recipe_toml_path = env("PROV_RECIPE_TOML")
    recipe_toml_content = None
    if recipe_toml_path and Path(recipe_toml_path).is_file():
        recipe_toml_content = Path(recipe_toml_path).read_text(encoding="utf-8")

    data = {
        "timestamp_utc":   datetime.now(timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "timestamp_local": env("PROV_TIMESTAMP") or None,
        "model_name":      env("PROV_MODEL_NAME"),
        "variant_name":    env("PROV_VARIANT_NAME"),
        "model_id":        env("PROV_MODEL_ID"),
        "vendor":          env("PROV_VENDOR"),
        "stack":           env("PROV_STACK"),
        "image": {
            "ref":  image_ref,
            "info": image_info,
        },
        "build": build,
        "sweep": {
            "tp":      env("PROV_SWEEP_TP").split(),
            "isl_osl": env("PROV_SWEEP_ISL_OSL").split(),
            "conc":    env("PROV_SWEEP_CONC").split(),
        },
        "system": {
            "hostname":   sh(["hostname"]),
            "kernel":     sh(["uname", "-r"]),
            "os_release": sh(["bash", "-c",
                              "grep -E '^(NAME|VERSION_ID|PRETTY_NAME)=' /etc/os-release | tr -d '\"'"]).splitlines(),
            "gpus":       gpu_summary(),
        },
        "gpu_setup_repo": gpu_setup_repo_info(),
        "recipe_toml":    recipe_toml_content,
    }

    out_path = results_dir / "provenance.json"
    out_path.write_text(json.dumps(data, indent=2), encoding="utf-8")
    print(str(out_path))
    return 0


if __name__ == "__main__":
    sys.exit(main())
