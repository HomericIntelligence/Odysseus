#!/usr/bin/env python3
"""Validate docker-compose file structure (issue #198).

Binary-free: podman/docker is not installed on the lint/CI runner, so a
`compose config` gate would skip and assert nothing. This parses each compose
file with PyYAML and checks structural invariants, so it runs anywhere python3
+ PyYAML are present (PyYAML ships transitively with yamllint, already in CI).
"""
import sys
from pathlib import Path

import yaml


def check(path: Path) -> tuple[bool, str]:
    """Check docker-compose structural invariants.

    Returns (True, description) on success or (False, error_message) on failure.
    """
    try:
        doc = yaml.safe_load(path.read_text(encoding="utf-8"))
    except yaml.YAMLError as exc:
        return False, f"YAML parse error: {exc}"
    if not isinstance(doc, dict):
        return False, "top level is not a mapping"
    services = doc.get("services")
    if not isinstance(services, dict) or not services:
        return False, "missing or empty 'services' mapping"
    for name, svc in services.items():
        if not isinstance(svc, dict):
            return False, f"service '{name}' is not a mapping"
    return True, f"{len(services)} service(s)"


def main() -> int:
    """Validate all docker-compose*.yml files in root and e2e/."""
    root = Path(__file__).resolve().parent.parent
    files = sorted(root.glob("docker-compose*.yml")) + sorted(
        root.glob("e2e/docker-compose*.yml")
    )
    if not files:
        print("No docker-compose files found; nothing to validate")
        return 0
    failed = 0
    for f in files:
        ok, msg = check(f)
        if ok:
            print(f"OK ({msg}): {f.relative_to(root)}")
        else:
            print(f"FAILED: {f.relative_to(root)} -- {msg}", file=sys.stderr)
            failed += 1
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
