#!/usr/bin/env -S uv run --script
# /// script
# requires-python = ">=3.11"
# dependencies = [
#   "tomli; python_version < '3.11'",
# ]
# ///
"""Print the variant names defined in a recipe TOML, one per line.

Usage:
    python3 list_variants.py <recipe.toml>
"""
import sys

try:
    import tomllib
except ImportError:
    import tomli as tomllib


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit("usage: list_variants.py <recipe.toml>")
    with open(sys.argv[1], "rb") as f:
        data = tomllib.load(f)
    for variant in data.get("variants", {}):
        print(variant)


if __name__ == "__main__":
    main()
