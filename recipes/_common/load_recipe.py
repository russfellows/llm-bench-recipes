#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "tomli; python_version < '3.11'",
# ]
# ///
"""
Recipe loader. Reads a recipe TOML and prints bash assignments that
run_recipe.sh evals to populate the variables that sweep.sh expects.

Usage:
    python3 load_recipe.py <recipe.toml> <variant>

Schema (see recipes/README.md for full docs):

    [recipe]
    model_name   = "gpt-oss-120b"
    model_id     = "openai/gpt-oss-120b"
    description  = "..."

    [recipe.defaults]
    sweep_tp        = [1, 2, 4]
    sweep_isl_osl   = ["1024,1024", "8192,1024"]
    sweep_conc      = [4, 8, 16, 32]
    random_range_ratio = 1.0
    ready_timeout_s    = 1800

    [variants.<name>]
    vendor             = "amd" | "nvidia"
    stack              = "vllm" | "atom" | "trtllm" | "sglang" | "triton"
    image              = "registry/repo:tag"           # pinned
    port               = 8000                          # optional
    ready_marker       = "Application startup complete" # optional
    bench_tool         = "vllm" | "atom" | "openai" | "vllm_docker"  # optional
    server_entrypoint  = "vllm serve"
    server_args        = ["...", "@TP@", "..."]        # use @TP@/@ISL@/@OSL@/@CONC@
    docker_flags       = []                            # optional, e.g. cpuset-cpus
    extra_files        = []                            # mounted at @RECIPE_DIR@/<basename>

    [variants.<name>.env]                              # optional, all -> -e KEY=VAL
    KEY = "value"

    [variants.<name>.build]                            # optional
    dockerfile = "Dockerfile.<variant>"
    context    = "."
    tag        = "local/<model>-<variant>:latest"      # used as IMAGE if build present
"""
import json
import os
import shlex
import sys
try:
    import tomllib
except ImportError:
    try:
        import tomli as tomllib  # backport for Python < 3.11
    except ImportError:
        sys.exit("tomllib not found. Install tomli: pip install tomli  (or use Python >= 3.11)")
from pathlib import Path


def quote(v) -> str:
    return shlex.quote(str(v))


def emit_array(name: str, items) -> None:
    print(f"{name}=(")
    for x in items:
        print(f"  {quote(x)}")
    print(")")


def main() -> int:
    if len(sys.argv) != 3:
        print("Usage: load_recipe.py <recipe.toml> <variant>", file=sys.stderr)
        return 2

    toml_path = Path(sys.argv[1]).resolve()
    variant = sys.argv[2]

    if not toml_path.is_file():
        print(f"Recipe TOML not found: {toml_path}", file=sys.stderr)
        return 2

    with toml_path.open("rb") as f:
        data = tomllib.load(f)

    recipe = data.get("recipe", {})
    defaults = dict(recipe.get("defaults", {}))
    variants = data.get("variants", {})
    if variant not in variants:
        print(f"Variant '{variant}' not found in {toml_path}.", file=sys.stderr)
        print(f"Available: {sorted(variants.keys())}", file=sys.stderr)
        return 2
    v = variants[variant]
    # Variant-level [defaults] override recipe-level [recipe.defaults]
    # for fields like sweep_tp where one variant has different reference values.
    defaults.update(v.get("defaults", {}))

    # ---- Required top-level ----
    for k in ("model_name", "model_id"):
        if k not in recipe:
            print(f"[recipe].{k} is required", file=sys.stderr)
            return 2
    # ---- Required variant ----
    for k in ("vendor", "stack", "image", "server_entrypoint"):
        if k not in v:
            print(f"[variants.{variant}].{k} is required", file=sys.stderr)
            return 2

    # ---- Scalars ----
    print(f"# Recipe TOML: {toml_path}")
    print(f"# Variant: {variant}")
    print(f"MODEL_NAME={quote(recipe['model_name'])}")
    # Variant-level model_id overrides recipe-level when set (e.g. kimi uses
    # different HF repo IDs for AMD/MXFP4 vs NVIDIA/NVFP4 variants).
    model_id = v.get("model_id", recipe["model_id"])
    print(f"MODEL_ID={quote(model_id)}")
    print(f"VARIANT_NAME={quote(variant)}")
    print(f"VENDOR={quote(v['vendor'])}")
    print(f"STACK={quote(v['stack'])}")
    print(f"PORT={int(v.get('port', 8000))}")

    # ready_marker / bench_tool: only emit if specified; otherwise sweep.sh
    # picks the per-stack default.
    if "ready_marker" in v:
        print(f"READY_MARKER={quote(v['ready_marker'])}")
    if "bench_tool" in v:
        print(f"BENCH_TOOL={quote(v['bench_tool'])}")
    if "ready_timeout_s" in defaults:
        print(f"READY_TIMEOUT_S={int(defaults['ready_timeout_s'])}")
    if "random_range_ratio" in defaults:
        print(f"RANDOM_RANGE_RATIO={float(defaults['random_range_ratio'])}")

    # ---- Image / build ----
    build = v.get("build")
    if build:
        for k in ("dockerfile", "tag"):
            if k not in build:
                print(f"[variants.{variant}.build].{k} is required", file=sys.stderr)
                return 2
        print(f"EXTRA_BUILD_DOCKERFILE={quote(build['dockerfile'])}")
        print(f"EXTRA_BUILD_CONTEXT={quote(build.get('context', '.'))}")
        print(f"EXTRA_BUILD_TAG={quote(build['tag'])}")
        # When a build is declared, IMAGE is the build tag (overrides the
        # `image` field, which acts only as the base for the FROM line).
        print(f"IMAGE={quote(build['tag'])}")
        print(f"BASE_IMAGE={quote(v['image'])}")

        # Build args -> EXTRA_BUILD_ARGS as a bash array of --build-arg KEY=VAL.
        # Also serialize a newline-separated KEY=VAL form for provenance.
        build_args = build.get("build_args", {}) or {}
        if build_args:
            flat = []
            for k, val in build_args.items():
                flat += ["--build-arg", f"{k}={val}"]
            emit_array("EXTRA_BUILD_ARGS", flat)
            # Provenance friendly: PROV_BUILD_ARGS="K1=V1\nK2=V2"
            joined = "\n".join(f"{k}={v_}" for k, v_ in build_args.items())
            print(f"PROV_BUILD_ARGS={quote(joined)}")
        else:
            print("EXTRA_BUILD_ARGS=()")
    else:
        print(f"IMAGE={quote(v['image'])}")

    # ---- Server command ----
    # Entrypoint may be a multi-token string like "python3 -m foo.bar"; split
    # on shell whitespace so each token becomes its own argv element.
    entrypoint_tokens = shlex.split(v["server_entrypoint"])
    args = v.get("server_args", [])
    server_cmd = entrypoint_tokens + list(args)
    emit_array("SERVER_CMD", server_cmd)

    # ---- Environment ----
    # Expand ${VAR} / $VAR references in values so recipes can write
    # ${SHARED_ROOT}/vllm_cache and have it resolve to the platform-specific
    # path set by the environment profile (runpod.sh / baremetal.sh / etc.)
    # that was sourced by run_recipe.sh before load_recipe.py runs.
    env = v.get("env", {})
    if env:
        flat = []
        for k, val in env.items():
            flat += ["-e", f"{k}={os.path.expandvars(str(val))}"]
        emit_array("EXTRA_DOCKER_ENV", flat)
    else:
        print("EXTRA_DOCKER_ENV=()")

    # ---- Extra docker flags (cpuset, etc.) ----
    flags = v.get("docker_flags", [])
    if flags:
        emit_array("EXTRA_DOCKER_FLAGS", flags)
    else:
        print("EXTRA_DOCKER_FLAGS=()")

    # ---- Bench client extra args ----
    bench_extra = v.get("bench_extra_args", [])
    if bench_extra:
        emit_array("BENCH_EXTRA_ARGS", bench_extra)
    else:
        print("BENCH_EXTRA_ARGS=()")

    # ---- Extra files: mounted at /recipe/<basename> ----
    files = v.get("extra_files", [])
    if files:
        emit_array("EXTRA_FILES", files)
    else:
        print("EXTRA_FILES=()")

    # ---- Runtime config: written as JSON at run time, mounted into container.
    # YAML loaders (e.g. trtllm-serve's --extra_llm_api_options) accept JSON
    # because JSON is a strict subset of YAML — so we can keep the repo
    # YAML-free while still feeding YAML-expecting tools.
    runtime_config = v.get("runtime_config")
    if runtime_config is not None:
        print(f"RUNTIME_CONFIG_JSON={quote(json.dumps(runtime_config))}")
        print(f"RUNTIME_CONFIG_PATH={quote(v.get('runtime_config_path', '/recipe/runtime_config.json'))}")

    # ---- Defaults / sweep matrix ----
    def join_strs(xs):
        return " ".join(str(x) for x in xs)

    if "sweep_tp" in defaults:
        print(f"SWEEP_TP_DEFAULT={quote(join_strs(defaults['sweep_tp']))}")
    if "sweep_isl_osl" in defaults:
        print(f"SWEEP_ISL_OSL_DEFAULT={quote(join_strs(defaults['sweep_isl_osl']))}")
    if "sweep_conc" in defaults:
        print(f"SWEEP_CONC_DEFAULT={quote(join_strs(defaults['sweep_conc']))}")

    # ---- Recipe directory (where TOML and extra_files live) ----
    print(f"RECIPE_DIR={quote(str(toml_path.parent))}")

    return 0


if __name__ == "__main__":
    sys.exit(main())
