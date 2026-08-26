#!/usr/bin/env python3
"""Register the M1-M6 milestone epics and their children (issue #468, ADR-020).

Reads the declarative payloads under ``tools/github/milestone-epics.d/``,
validates them against the ADR-020 section 6/7 epic conventions (per-repo
epic homes, one dispatchable task per child, ``state:needs-plan`` labels),
renders ADR-013 section 6 parseable epic bodies, and (with ``--apply``)
creates the issues via the ``gh`` CLI.

Modes:
  * ``--plan`` (default): print everything that would be created; no writes.
  * ``--apply``: create labels/children/epics in the HomericIntelligence org.
    Idempotent: an epic whose title already exists open in its home repo is
    skipped, so re-running never duplicates registration.

This tool performs GitHub mutation and is intended to be run by the operator
or the orchestrator that owns GitHub writes — not by sandboxed agents.
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

ORG = "HomericIntelligence"
PAYLOAD_DIR = Path(__file__).resolve().parent / "milestone-epics.d"
EPIC_LABEL = "agamemnon-epic"
NEEDS_PLAN_LABEL = "state:needs-plan"
EPIC_LABEL_DESCRIPTION = "HMAS epic tracked by Agamemnon"
EPIC_LABEL_COLOR = "0E8A16"

KNOWN_REPOS = (
    "Odysseus",
    "Hephaestus",
    "Myrmidons",
    "Nestor",
    "AchaeanFleet",
    "Agamemnon",
    "Proteus",
    "Hermes",
    "Argus",
)

EXPECTED_EPIC_HOMES = {
    "M1": "Hephaestus",
    "M2": "Odysseus",
    "M3": "Myrmidons",
    "M4": "Odysseus",
    "M5": "Nestor",
    "M6": "Odysseus",
}

CHECKLIST_LINE_RE = re.compile(r"^- \[ \] #\d+( \(depends on: #\d+(, #\d+)*\))?$")


@dataclass(frozen=True)
class Child:
    """One dispatchable task issue inside a milestone epic."""

    id: str
    repo: str
    subject: str
    description: str


@dataclass(frozen=True)
class Milestone:
    """One per-repo epic plus its children and intra-epic dependency edges."""

    id: str
    title: str
    epic_home: str
    workflow: str
    home_rationale: str
    ordering_note: str
    children: tuple[Child, ...]
    blocked_by: dict[str, tuple[str, ...]]

    def deps(self, child_id: str) -> tuple[Child, ...]:
        """Return sibling children this child depends on, in payload order."""
        return tuple(
            child
            for dep in self.blocked_by.get(child_id, ())
            for child in self.children
            if child.id == dep
        )


def load_payloads(payload_dir: Path = PAYLOAD_DIR) -> list[Milestone]:
    """Load and parse every milestone payload file, ordered M1..M6."""
    milestones: list[Milestone] = []
    for path in sorted(payload_dir.glob("*.yaml")):
        doc = yaml.safe_load(path.read_text())
        if not isinstance(doc, dict):
            raise ValueError(f"{path}: payload must be a mapping")
        children = tuple(
            Child(
                id=str(entry["id"]),
                repo=str(entry["repo"]),
                subject=str(entry["subject"]),
                description=str(entry["description"]).strip(),
            )
            for entry in doc["children"]
        )
        blocked_by = {
            str(entry["id"]): tuple(str(dep) for dep in entry.get("blocked_by", []))
            for entry in doc["children"]
        }
        milestones.append(
            Milestone(
                id=str(doc["milestone"]),
                title=str(doc["title"]),
                epic_home=str(doc["epic_home"]),
                workflow=str(doc["workflow"]),
                home_rationale=str(doc["home_rationale"]).strip(),
                ordering_note=str(doc["ordering_note"]).strip(),
                children=children,
                blocked_by=blocked_by,
            )
        )
    milestones.sort(key=lambda m: m.id)
    return milestones


def validate(milestones: list[Milestone]) -> list[str]:
    """Validate payloads against the ADR-020/ADR-013 conventions."""
    errors: list[str] = []
    seen_ids: set[str] = set()

    ids = [m.id for m in milestones]
    if ids != [f"M{i}" for i in range(1, 7)]:
        errors.append(f"expected exactly six milestones M1..M6, got {ids}")

    for m in milestones:
        expected_home = EXPECTED_EPIC_HOMES.get(m.id)
        if expected_home is not None and m.epic_home != expected_home:
            errors.append(
                f"{m.id}: epic_home {m.epic_home!r} != workflow metadata "
                f"{expected_home!r} (workflows/m*.yaml epic_home)"
            )
        if not m.children:
            errors.append(f"{m.id}: epic has no children")
        subjects = [c.subject for c in m.children]
        if len(subjects) != len(set(subjects)):
            errors.append(f"{m.id}: duplicate child subjects")
        for child in m.children:
            if child.id in seen_ids:
                errors.append(f"{child.id}: duplicate child id across milestones")
            seen_ids.add(child.id)
            if child.repo not in KNOWN_REPOS:
                errors.append(f"{child.id}: unknown repo {child.repo!r}")
            for dep in m.blocked_by.get(child.id, ()):
                if dep == child.id:
                    errors.append(f"{child.id}: depends on itself")
                elif all(sibling.id != dep for sibling in m.children):
                    errors.append(
                        f"{child.id}: blocked_by {dep!r} is not a sibling of {m.id}"
                    )

        first = m.children[0] if m.children else None
        if first is not None and m.blocked_by.get(first.id):
            errors.append(f"{m.id}: requirements child {first.id} must be unblocked")

    return errors


def render_child_body(m: Milestone, c: Child) -> str:
    """Render the body of a child issue from its transcribed description."""
    return (
        f"Part of {m.id} ({m.title}) - ADR-020 sections 7 and 9 staged rollout; "
        f"requirements transcribed verbatim from `{m.workflow}` (#464).\n\n"
        f"{c.description}\n\n"
        "Sized as a single dispatchable task (~1 h active work). Dispatch "
        "packets stay pointer-only per ADR-013 section 6; workers read the "
        "full task description here at claim time."
    )


def render_epic_body(m: Milestone, numbers: dict[str, int]) -> str:
    """Render an epic body with an ADR-013 section 6 parseable checklist."""
    lines = [
        f"Epic tracking Milestone {m.id[1:]} of the mesh-distributed Hephaestus "
        f"loop (ADR-020 sections 7 and 9). Definitions: `{m.workflow}`. "
        f"{m.home_rationale}",
        "",
        f"Cross-milestone ordering: {m.ordering_note}",
        "",
        "## Tasks",
    ]
    for child in m.children:
        number = numbers.get(child.id)
        if number is None:
            raise KeyError(f"{child.id}: child issue number unknown during rendering")
        deps = m.deps(child.id)
        if deps:
            dep_refs = ", ".join(f"#{numbers[d.id]}" for d in deps)
            lines.append(f"- [ ] #{number} (depends on: {dep_refs})")
        else:
            lines.append(f"- [ ] #{number}")
    return "\n".join(lines)


def gh(*args: str) -> str:
    """Run a ``gh`` command and return stdout."""
    result = subprocess.run(
        ["gh", *args], capture_output=True, text=True, check=False
    )
    if result.returncode != 0:
        raise RuntimeError(f"gh {' '.join(args)} failed: {result.stderr.strip()}")
    return result.stdout


def issue_number_from_url(url: str) -> int:
    """Extract the issue number from a ``gh issue create`` URL."""
    match = re.search(r"/issues/(\d+)$", url.strip())
    if match is None:
        raise ValueError(f"cannot parse issue number from {url!r}")
    return int(match.group(1))


def existing_open_epic(repo: str, title: str) -> int | None:
    """Return the number of an open epic with this title in ``repo``, if any."""
    out = gh(
        "issue", "list", "-R", f"{ORG}/{repo}", "--label", EPIC_LABEL,
        "--state", "open", "--json", "number,title",
    )
    for entry in json.loads(out):
        if entry["title"] == title:
            return int(entry["number"])
    return None


def apply_plan(milestones: list[Milestone]) -> int:
    """Create labels, children, and epics via ``gh``. Idempotent per epic."""
    created_epics: list[tuple[Milestone, str]] = []

    homes = sorted({m.epic_home for m in milestones})
    for repo in homes:
        subprocess.run(
            [
                "gh", "label", "create", "-R", f"{ORG}/{repo}", EPIC_LABEL,
                "--description", EPIC_LABEL_DESCRIPTION,
                "--color", EPIC_LABEL_COLOR,
            ],
            capture_output=True,
            text=True,
            check=False,  # already-exists failures are fine
        )

    for m in milestones:
        if existing_open_epic(m.epic_home, m.title) is not None:
            print(f"{m.id}: epic already registered in {m.epic_home}, skipping")
            continue
        numbers: dict[str, int] = {}
        for child in m.children:
            url = gh(
                "issue", "create", "-R", f"{ORG}/{child.repo}",
                "--label", NEEDS_PLAN_LABEL,
                "--subject", child.subject,
                "--body", render_child_body(m, child),
            )
            numbers[child.id] = issue_number_from_url(url)
            print(f"{m.id}: created {child.repo}#{numbers[child.id]} ({child.id})")
        epic_url = gh(
            "issue", "create", "-R", f"{ORG}/{m.epic_home}",
            "--label", EPIC_LABEL,
            "--subject", m.title,
            "--body", render_epic_body(m, numbers),
        )
        epic_number = issue_number_from_url(epic_url)
        print(f"{m.id}: epic {m.epic_home}#{epic_number}")
        created_epics.append((m, epic_url.rstrip()))

    print("\nRegistered epics:")
    for _, url in created_epics:
        print(f"  {url}")
    return 0


def plan_mode(milestones: list[Milestone]) -> int:
    """Print the full registration plan without touching GitHub."""
    for m in milestones:
        print(f"=== {m.id}: {m.title}  [epic home: {m.epic_home}] ===")
        for child in m.children:
            deps = ", ".join(d.id for d in m.deps(child.id)) or "-"
            print(f"  {child.id}  repo={child.repo}  blocked_by={deps}")
            print(f"      subject: {child.subject}")
        print("  --- rendered epic body ---")
        preview = {c.id: i + 100 for i, c in enumerate(m.children)}
        print(render_epic_body(m, preview))
        print()
    total = sum(len(m.children) for m in milestones)
    print(f"{len(milestones)} epics, {total} children would be created.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--plan", action="store_true", help="print plan only")
    target.add_argument("--apply", action="store_true", help="create issues via gh")
    args = parser.parse_args(argv)

    milestones = load_payloads()
    errors = validate(milestones)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 2
    if args.apply:
        return apply_plan(milestones)
    return plan_mode(milestones)


if __name__ == "__main__":
    raise SystemExit(main())
