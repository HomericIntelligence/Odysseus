#!/usr/bin/env python3
"""Validate version consistency across pixi.toml, CHANGELOG.md, and (at release) the git tag.

Requires Python 3.11+ (uses the stdlib `tomllib`). CI runs ubuntu-latest (3.12);
local pre-commit must also run on 3.11+.

Default mode (pre-commit): pixi.toml must parse and declare a version (no cross-file
equality — this repo carries documented-but-never-released CHANGELOG history, so the
manifest legitimately differs from the top dated section).
--expect VERSION (release): tag, pixi.toml, and the top dated CHANGELOG section must
all equal VERSION.
"""
import argparse
import re
import sys
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
DATED_RE = re.compile(r"^## \[(\d+\.\d+\.\d+)\] - \d{4}-\d{2}-\d{2}$", re.MULTILINE)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--expect", help="exact version a release tag must match")
    args = ap.parse_args()

    pixi = tomllib.loads((ROOT / "pixi.toml").read_text(encoding="utf-8"))
    pixi_v = pixi["workspace"]["version"]
    changelog = (ROOT / "CHANGELOG.md").read_text(encoding="utf-8")
    top = DATED_RE.search(changelog)
    top_v = top.group(1) if top else None

    if args.expect:
        if pixi_v != args.expect:
            print(f"::error::pixi.toml version '{pixi_v}' != release tag '{args.expect}'")
            return 1
        if top_v != args.expect:
            print(f"::error::top CHANGELOG dated section '{top_v}' != release tag '{args.expect}'")
            return 1
        print(f"OK: tag, pixi.toml, and CHANGELOG all agree on {args.expect}")
        return 0

    print(f"OK: pixi.toml declares version {pixi_v} (CHANGELOG top dated section: {top_v})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
