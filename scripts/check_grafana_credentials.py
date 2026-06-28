#!/usr/bin/env python3
"""Fail-closed gate (#179): documented Grafana default creds must carry an
adjacent rotation WARNING, and anonymous dashboard read must be explicitly
marked e2e-only. Scope is `git ls-files` — THIS repo's tracked files only,
never submodule content this repo cannot edit. `--self-test` runs unit checks.
"""
import re
import subprocess
import sys
import tempfile
from pathlib import Path

CRED_RE = re.compile(r"admin\s*/\s*admin", re.IGNORECASE)
# Require a real admonition: a WARNING/Warning token AND a rotate/change verb,
# so coincidental nearby wording cannot satisfy the gate.
WARN_RE = re.compile(
    r"(warning|caution|important).*(rotate|change|replace)"
    r"|(rotate|change|replace).*(before production|password|default)",
    re.IGNORECASE,
)
ANON_RE = re.compile(r'GF_AUTH_ANONYMOUS_ENABLED\s*[:=]\s*["\']?true', re.IGNORECASE)
E2E_MARKER = re.compile(r"e2e-only", re.IGNORECASE)
WARN_WINDOW = 3      # docs: forward look-ahead from the credential line
ANON_LOOKBACK = 2   # compose: lines above the flag the e2e-only marker may sit on


def _git_tracked(root: Path, patterns: list[str]) -> list[Path]:
    """Return tracked files matching patterns.

    Bounds the scan to THIS repo's index, excluding all submodules and
    untracked/gitignored trees.
    """
    out = subprocess.run(
        ["git", "-C", str(root), "ls-files", "-z", *patterns],
        capture_output=True,
        text=True,
        check=True,
    ).stdout
    return [root / p for p in out.split("\0") if p]


def check_docs(root: Path) -> list[str]:
    """Check tracked markdown files for admin/admin credentials lacking a rotation warning."""
    errs: list[str] = []
    for md in _git_tracked(root, ["*.md"]):
        lines = md.read_text(encoding="utf-8", errors="replace").splitlines()
        for i, line in enumerate(lines):
            if CRED_RE.search(line):
                window = lines[i : i + 1 + WARN_WINDOW]
                if not any(WARN_RE.search(w) for w in window):
                    errs.append(
                        f"{md.relative_to(root)}:{i + 1}: 'admin/admin' "
                        f"with no rotation warning within {WARN_WINDOW} lines"
                    )
    return errs


def check_compose(root: Path) -> list[str]:
    """Check tracked YAML files for anonymous Grafana read lacking an e2e-only marker."""
    errs: list[str] = []
    for yml in _git_tracked(root, ["*.yml", "*.yaml"]):
        lines = yml.read_text(encoding="utf-8", errors="replace").splitlines()
        for i, line in enumerate(lines):
            if ANON_RE.search(line):
                # Look back ANON_LOOKBACK lines AND include the flag line itself,
                # so the e2e-only marker may sit on any of i-2, i-1, or i.
                context = lines[max(0, i - ANON_LOOKBACK) : i + 1]
                if not any(E2E_MARKER.search(c) for c in context):
                    errs.append(
                        f"{yml.relative_to(root)}:{i + 1}: anonymous Grafana "
                        f"read enabled without an 'e2e-only' marker within "
                        f"{ANON_LOOKBACK} lines above"
                    )
    return errs


def _run(root: Path) -> int:
    errs = check_docs(root) + check_compose(root)
    if errs:
        sys.stderr.write("Grafana credential-hygiene check FAILED (#179):\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write(
            f"\nFix: add `> **WARNING:** rotate before production` adjacent to the\n"
            f"credential, or mark a deliberate e2e anonymous stack with `# e2e-only:`\n"
            f"within {ANON_LOOKBACK} lines above the GF_AUTH_ANONYMOUS_ENABLED line.\n"
        )
        return 1
    print("Grafana credential hygiene OK.")
    return 0


def _self_test() -> int:
    """Embedded unit tests — stdlib only, no pytest (repo has no py test harness)."""
    cases: list[tuple[str, bool, int, int]] = []

    def case(name: str, files: dict[str, str], want: int) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            subprocess.run(["git", "-C", d, "init", "-q"], check=True)
            for rel, body in files.items():
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(body)
            subprocess.run(["git", "-C", d, "add", "-A"], check=True)
            got = _run(root)
            cases.append((name, got == want, got, want))

    # --- doc rule ---
    case(
        "creds_no_warning_fails",
        {"doc.md": "Default credentials: `admin / admin`\nNext line.\n"},
        1,
    )
    case(
        "creds_with_blank_then_warning_passes",  # mirrors the shipped doc layout
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n\n"
                "> **WARNING:** Rotate this password before any production use\n"
            )
        },
        0,
    )
    case(
        "loose_word_does_not_satisfy",
        {"doc.md": "Default credentials: `admin / admin`\nWe rotate logs nightly.\n"},
        1,  # bare verb must NOT pass
    )

    # --- compose rule ---
    case(
        "anon_no_marker_fails",
        {"c.yml": 'environment:\n  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'},
        1,
    )
    case(
        "anon_marker_one_line_above_passes",
        {
            "c.yml": (
                "  # e2e-only: anonymous viewer (no prod data)\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        0,
    )
    case(
        "anon_marker_two_lines_above_passes",  # EXACT shipped layout: marker @ i-2
        {
            "c.yml": (
                "  # e2e-only: anonymous Viewer for the local demo stack.\n"
                "  # Never enable this in a prod-facing stack; see #179.\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        0,
    )
    case(
        "anon_marker_three_lines_above_fails",  # boundary: i-3 is out of window
        {
            "c.yml": (
                "  # e2e-only: marker too far up\n"
                "  # filler comment a\n"
                "  # filler comment b\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )

    failed = [c for c in cases if not c[1]]
    for name, ok, got, want in cases:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name} (got={got} want={want})")
    if failed:
        sys.stderr.write(f"SELF-TEST FAILED: {len(failed)}/{len(cases)} cases\n")
        return 1
    print(f"SELF-TEST OK: {len(cases)}/{len(cases)} cases passed.")
    return 0


def main(argv: list[str]) -> int:
    if "--self-test" in argv:
        return _self_test()
    root = Path(
        subprocess.run(
            ["git", "rev-parse", "--show-toplevel"],
            capture_output=True,
            text=True,
            check=True,
        ).stdout.strip()
    )
    return _run(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
