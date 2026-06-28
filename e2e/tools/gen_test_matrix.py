#!/usr/bin/env python3
"""Generate e2e/tests/README.md — a coverage matrix mapping each e2e scenario
test to the scenario IDs and system properties it verifies.

DO NOT hand-edit e2e/tests/README.md. Edit the test headers and regenerate:
    python3 e2e/tools/gen_test_matrix.py
CI (_required.yml unit-tests) and `just lint` run `--check` and fail on drift.

Header contract (e2e/tests/<category>/<name>.sh):
    line 2:  # <Category>: <Title> (<ID, ID, ...>)  [— T4 only]
    line 3:  # Validates[:]/Measures[:] <description>   (colon optional)
"""
from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

TESTS_DIR = Path(__file__).resolve().parent.parent / "tests"
README = TESTS_DIR / "README.md"
CATEGORIES = ["chaos", "fault", "perf", "protocol", "security"]

ID_RE = re.compile(r"\b[ABCDE][0-9]{2}\b")
# Line 2: "# Category: Title (IDs) [— T4 only]". Topology detected from the
# literal phrase "T4 only" so any dash byte (em/en/hyphen) is irrelevant.
TITLE_RE = re.compile(r"^#\s*[^:]+:\s*(?P<title>.*?)\s*$")
PAREN_RE = re.compile(r"\s*\([^)]*\)\s*$")  # trailing "(IDs)"
T4_RE = re.compile(r"\bT4 only\b")
# Line 3: colon optional (subject-routing.sh has none).
DESC_RE = re.compile(r"^#\s*(?:Validates|Measures)\b:?\s*(?P<text>.*\S)\s*$")


def parse(path: Path) -> dict:
    lines = path.read_text(encoding="utf-8").splitlines()
    line2 = lines[1] if len(lines) > 1 else ""
    line3 = lines[2] if len(lines) > 2 else ""
    ids = sorted(set(ID_RE.findall(line2)))  # IDs come from line 2 only
    topology = "T4" if T4_RE.search(line2) else "Any"
    title = ""
    m = TITLE_RE.match(line2)
    if m:
        title = m.group("title")
        title = T4_RE.sub("", title)  # drop "T4 only"
        title = title.rstrip(" —-")  # drop trailing em-dash or hyphen
        title = PAREN_RE.sub("", title).strip()  # drop "(IDs)"
    d = DESC_RE.match(line3)
    desc = d.group("text").strip() if d else ""
    return {"file": path.name, "title": title, "ids": ids,
            "desc": desc, "topology": topology}


def all_rows() -> list[dict]:
    rows = []
    for cat in CATEGORIES:
        for p in sorted((TESTS_DIR / cat).glob("*.sh")):
            r = parse(p)
            r["category"] = cat
            rows.append(r)
    return rows


def validate(rows: list[dict]) -> list[str]:
    """Return a list of contract violations (empty => all files conform)."""
    errs = []
    for r in rows:
        if not r["title"]:
            errs.append(f"{r['category']}/{r['file']}: line 2 has no parseable title")
        if not r["desc"]:
            errs.append(f"{r['category']}/{r['file']}: line 3 has no Validates/Measures description")
    return errs


def render(rows: list[dict]) -> str:
    all_ids = sorted({i for r in rows for i in r["ids"]})
    t4 = sum(1 for r in rows if r["topology"] == "T4")
    out = [
        "<!-- GENERATED FILE — DO NOT EDIT.",
        "     Source: e2e/tests/<category>/*.sh headers (lines 2-3).",
        "     Regenerate: python3 e2e/tools/gen_test_matrix.py -->",
        "",
        "# E2E Test Coverage Matrix",
        "",
        "Maps each scenario test in `e2e/tests/` to the scenario IDs and the "
        "system properties it verifies. Tests marked **T4** are partial on the "
        "default topology and fully exercised only under the T4 "
        "(multi-container) topology — i.e. intentionally deferred on single-node runs.",
        "",
        f"**Totals:** {len(rows)} tests, {len(all_ids)} unique scenario IDs "
        f"covered, {t4} T4-only (deferred on the default topology).",
        "",
    ]
    for cat in CATEGORIES:
        crows = [r for r in rows if r["category"] == cat]
        if not crows:
            continue
        out += [f"## {cat.capitalize()}", "",
                "| Test file | Title | Scenario IDs | Verifies | Topology |",
                "| --- | --- | --- | --- | --- |"]
        for r in crows:
            ids = ", ".join(r["ids"]) or "—"
            out.append(f"| `{r['file']}` | {r['title']} | {ids} | {r['desc']} | {r['topology']} |")
        out.append("")
    return "\n".join(out).rstrip("\n") + "\n"


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="fail if README is stale")
    g.add_argument("--validate", action="store_true", help="fail if any header is non-conforming")
    g.add_argument("--print", action="store_true", help="print matrix to stdout")
    args = ap.parse_args(argv)

    rows = all_rows()
    errs = validate(rows)
    if errs:
        sys.stderr.write("ERROR: e2e test header contract violated:\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write("Fix the header (line 2: '# Cat: Title (IDs)', "
                         "line 3: '# Validates ...') and rerun.\n")
        return 1
    if args.validate:
        print(f"OK: all {len(rows)} e2e test headers conform.")
        return 0

    content = render(rows)
    if args.print:
        sys.stdout.write(content)
        return 0
    if args.check:
        current = README.read_text(encoding="utf-8") if README.exists() else ""
        norm = lambda s: s.rstrip("\n") + "\n"
        if norm(current) != norm(content):
            sys.stderr.write("ERROR: e2e/tests/README.md is stale.\n"
                             "Regenerate: python3 e2e/tools/gen_test_matrix.py\n")
            return 1
        print("e2e/tests/README.md is up to date.")
        return 0
    README.write_text(content, encoding="utf-8")
    print(f"Wrote {README} ({len(rows)} tests).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
