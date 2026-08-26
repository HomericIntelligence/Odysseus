#!/usr/bin/env python3
"""Lane model loader for the ADR-020 automation lanes (issue #465).

Reads the canonical pin file ``configs/lane-models.yaml`` and either
validates + prints it as a markdown table (default / ``--table``) or emits
source-able ``export HEPH_*_MODEL`` lines (``--env``) for loop launch shells.

Exit codes:
    0 — config valid and output produced
    1 — config missing, a lane is missing/extra, or an ID is malformed
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - PyYAML ships via the pixi env
    sys.exit("lane_models.py requires PyYAML (available via `pixi run`)")

CONFIG_PATH = Path(__file__).resolve().parent.parent / "configs" / "lane-models.yaml"

REQUIRED_LANES = ("planning", "implementation", "review", "mechanical")

# opencode provider/model form, e.g. opencode/x-preview-f-free-high
MODEL_ID_RE = re.compile(r"^[a-z0-9][a-z0-9._-]*/[A-Za-z0-9._-]+$")

# Mechanical lane fans out to the per-phase env vars Hephaestus reads
# (learn / advise); see shared/Hephaestus hephaestus/agents/runtime.py.
LANE_TO_ENV_VARS: dict[str, tuple[str, ...]] = {
    "planning": ("HEPH_PLANNER_MODEL",),
    "implementation": ("HEPH_IMPLEMENTER_MODEL",),
    "review": ("HEPH_REVIEWER_MODEL",),
    "mechanical": ("HEPH_LEARN_MODEL", "HEPH_ADVISE_MODEL"),
}


def load_lanes(config_path: Path = CONFIG_PATH) -> dict[str, str]:
    """Load and validate the lane-model pin file.

    Returns the mapping of lane name -> model ID. Raises ``ValueError`` with
    a human-readable message when the file is missing, structurally invalid,
    missing a required lane, carries an extra lane, or contains a malformed
    model ID.
    """
    if not config_path.is_file():
        raise ValueError(f"lane-model config not found: {config_path}")
    try:
        doc = yaml.safe_load(config_path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        raise ValueError(f"invalid YAML in {config_path}: {exc}") from exc

    if not isinstance(doc, dict) or not isinstance(doc.get("lanes"), dict):
        raise ValueError(f"{config_path}: expected top-level 'lanes' mapping")

    lanes = doc["lanes"]
    missing = [lane for lane in REQUIRED_LANES if lane not in lanes]
    extra = [lane for lane in lanes if lane not in REQUIRED_LANES]
    if missing:
        raise ValueError(f"{config_path}: missing lane(s): {', '.join(missing)}")
    if extra:
        raise ValueError(f"{config_path}: unexpected lane(s): {', '.join(sorted(extra))}")

    validated: dict[str, str] = {}
    for lane in REQUIRED_LANES:
        model = lanes[lane]
        if not isinstance(model, str) or not MODEL_ID_RE.match(model):
            raise ValueError(
                f"{config_path}: lane '{lane}' has malformed model ID {model!r} "
                "(expected provider/model)"
            )
        validated[lane] = model
    return validated


def format_table(lanes: dict[str, str]) -> str:
    """Render the lane pin as a markdown table."""
    lines = [
        "| Lane | Pinned ID |",
        "|---|---|",
    ]
    lines.extend(f"| {lane} | `{lanes[lane]}` |" for lane in REQUIRED_LANES)
    return "\n".join(lines)


def format_env(lanes: dict[str, str]) -> str:
    """Render source-able export lines for the loop launch shell."""
    lines = []
    for lane in REQUIRED_LANES:
        for var in LANE_TO_ENV_VARS[lane]:
            lines.append(f"export {var}={lanes[lane]}")
    return "\n".join(lines)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument("--table", action="store_true", help="print markdown table (default)")
    mode.add_argument("--env", action="store_true", help="emit source-able HEPH_*_MODEL exports")
    parser.add_argument(
        "--config",
        type=Path,
        default=CONFIG_PATH,
        help="path to the lane-model YAML (default: configs/lane-models.yaml)",
    )
    args = parser.parse_args(argv)

    try:
        lanes = load_lanes(args.config)
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 1

    print(format_env(lanes) if args.env else format_table(lanes))
    return 0


if __name__ == "__main__":
    sys.exit(main())
