#!/usr/bin/env python3
"""Register the M1-M6 milestone epics and their children (issue #468).

Reads the declarative payloads under ``tools/github/milestone-epics.d/``,
validates their current structural contract (per-repository epic homes,
single-purpose child issues, explicit operator gates, and
``state:needs-plan`` labels only for dispatchable work), renders
parseable epic bodies whose design context comes from Proposed ADR-013 and
Proposed ADR-020, and (with ``--apply``) creates the issues via the ``gh`` CLI.

Modes:
  * ``--plan`` (default): print everything that would be created; no writes.
  * ``--apply``: create labels/children/epics in the HomericIntelligence org.
    Retry-safe for one operator: an existing epic is skipped and marker-bound
    child issues from a partial attempt are reused before anything is created.

This tool performs GitHub mutation and is intended to be run by the operator
or the orchestrator that owns GitHub writes — not by sandboxed agents.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

import yaml

ORG = "HomericIntelligence"
PAYLOAD_DIR = Path(__file__).resolve().parent / "milestone-epics.d"
EPIC_LABEL = "agamemnon-epic"
NEEDS_PLAN_LABEL = "state:needs-plan"
EPIC_LABEL_DESCRIPTION = "HMAS epic tracked by Agamemnon"
EPIC_LABEL_COLOR = "0E8A16"
NEEDS_PLAN_LABEL_DESCRIPTION = "Awaiting an advise-gated plan"
NEEDS_PLAN_LABEL_COLOR = "FBCA04"

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
ISSUE_INVENTORY_LIMIT = 10_000
LABEL_INVENTORY_LIMIT = 1_000
MANUAL_COMPLETION_CONDITIONS = {
    "successful_mesh_only_merge": (
        "Close this gate only after one successful exact-pin mesh-only issue merge."
    ),
}
MANUAL_FAILURE_EFFECTS = {
    "keep_open": (
        "Missing readiness or a failed run must be recorded truthfully and leaves "
        "this gate open."
    ),
}


@dataclass(frozen=True)
class Child:
    """One dispatchable task or operator-held gate inside a milestone epic."""

    id: str
    repo: str
    subject: str
    description: str
    manual: bool
    requires_verified: tuple[str, ...]
    completion_condition: str | None
    failure_effect: str | None


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

    def verified_requirements(self, child_id: str) -> tuple[Child, ...]:
        """Return siblings a manual gate must verify without machine dispatch."""
        child = next(candidate for candidate in self.children if candidate.id == child_id)
        return tuple(
            sibling
            for required in child.requires_verified
            for sibling in self.children
            if sibling.id == required
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
                manual=bool(entry.get("manual", False)),
                requires_verified=tuple(
                    str(required) for required in entry.get("requires_verified", [])
                ),
                completion_condition=(
                    str(entry["completion_condition"])
                    if "completion_condition" in entry
                    else None
                ),
                failure_effect=(
                    str(entry["failure_effect"])
                    if "failure_effect" in entry
                    else None
                ),
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
    """Validate the checked-in milestone payload contract."""
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
            if not child.subject.strip() or "\n" in child.subject:
                errors.append(f"{child.id}: subject must be one non-empty line")
            if not child.description.strip():
                errors.append(f"{child.id}: description must not be empty")
            if child.manual and m.blocked_by.get(child.id):
                errors.append(
                    f"{child.id}: manual gate must not use parser dependency edges"
                )
            if child.manual and child.repo != m.epic_home:
                errors.append(f"{child.id}: manual gate must live in the epic home")
            if child.manual and not child.requires_verified:
                errors.append(f"{child.id}: manual gate has no verified prerequisites")
            if child.manual and (
                child.completion_condition not in MANUAL_COMPLETION_CONDITIONS
            ):
                errors.append(
                    f"{child.id}: unsupported manual completion_condition "
                    f"{child.completion_condition!r}"
                )
            if child.manual and child.failure_effect not in MANUAL_FAILURE_EFFECTS:
                errors.append(
                    f"{child.id}: unsupported manual failure_effect "
                    f"{child.failure_effect!r}"
                )
            if child.requires_verified and not child.manual:
                errors.append(
                    f"{child.id}: only a manual gate may require verified siblings"
                )
            if not child.manual and (
                child.completion_condition is not None
                or child.failure_effect is not None
            ):
                errors.append(
                    f"{child.id}: dispatchable task must not define manual policies"
                )
            for required in child.requires_verified:
                if required == child.id:
                    errors.append(f"{child.id}: requires verification of itself")
                elif all(sibling.id != required for sibling in m.children):
                    errors.append(
                        f"{child.id}: requires_verified {required!r} is not a sibling"
                    )
                elif next(
                    sibling for sibling in m.children if sibling.id == required
                ).manual:
                    errors.append(
                        f"{child.id}: manual gate may verify only dispatchable siblings"
                    )
            if len(child.requires_verified) != len(set(child.requires_verified)):
                errors.append(f"{child.id}: duplicate requires_verified identity")
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


def _source_digest(value: object) -> str:
    """Return a deterministic digest for a canonical authored-source projection."""
    encoded = json.dumps(
        value, sort_keys=True, separators=(",", ":"), ensure_ascii=True
    ).encode()
    return hashlib.sha256(encoded).hexdigest()


def child_source_digest(m: Milestone, c: Child) -> str:
    """Bind one generated child to the authored fields that define its behavior."""
    return _source_digest(
        {
            "schema": "homeric-milestone-task/v1",
            "milestone": m.id,
            "milestone_title": m.title,
            "workflow": m.workflow,
            "id": c.id,
            "repo": c.repo,
            "subject": c.subject,
            "description": c.description,
            "blocked_by": list(m.blocked_by.get(c.id, ())),
            "manual": c.manual,
            "requires_verified": list(c.requires_verified),
            "completion_condition": c.completion_condition,
            "failure_effect": c.failure_effect,
        }
    )


def milestone_source_digest(m: Milestone) -> str:
    """Bind one generated epic to its complete authored milestone definition."""
    return _source_digest(
        {
            "schema": "homeric-milestone-epic/v1",
            "id": m.id,
            "title": m.title,
            "epic_home": m.epic_home,
            "workflow": m.workflow,
            "home_rationale": m.home_rationale,
            "ordering_note": m.ordering_note,
            "children": [child_source_digest(m, child) for child in m.children],
        }
    )


def child_identity_marker(c: Child) -> str:
    """Return the stable issue identity marker."""
    return f"<!-- HomericIntelligence:milestone-task id={c.id} -->"


def child_source_marker(m: Milestone, c: Child) -> str:
    """Return the canonical-source binding marker for one child."""
    return (
        "<!-- HomericIntelligence:milestone-task-source "
        f"id={c.id} sha256={child_source_digest(m, c)} -->"
    )


def epic_identity_marker(m: Milestone) -> str:
    """Return the stable epic identity marker."""
    return f"<!-- HomericIntelligence:milestone-epic id={m.id} -->"


def epic_source_marker(m: Milestone) -> str:
    """Return the canonical-source binding marker for one epic."""
    return (
        "<!-- HomericIntelligence:milestone-epic-source "
        f"id={m.id} sha256={milestone_source_digest(m)} -->"
    )


def render_child_body(
    m: Milestone, c: Child, numbers: dict[str, int] | None = None
) -> str:
    """Render a child issue from the current milestone payload."""
    payload = f"tools/github/milestone-epics.d/{m.id.lower()}.yaml"
    source = f"{ORG}/Odysseus:{payload}"
    workflow = f"{ORG}/Odysseus:{m.workflow}"
    preamble = (
        f"Part of {m.id} ({m.title}). Current task source: `{source}`. "
        f"Planning context: `{workflow}` ({ORG}/Odysseus#464) and Proposed "
        "ADR-020 sections 7 and 9.\n\n"
        f"{c.description}"
    )
    if not c.manual:
        return (
            f"{preamble}\n\nSized as a single dispatchable task (~1 h active "
            "work). This task must preserve pointer-only dispatch; Proposed "
            "ADR-013 section 6 records the design rationale. Workers must read "
            "the full task description here at claim time.\n\n"
            f"{child_identity_marker(c)}\n{child_source_marker(m, c)}"
        )
    if numbers is None:
        raise ValueError(f"{c.id}: manual gate rendering needs issue numbers")
    required_refs = ", ".join(
        f"{ORG}/{required.repo}#{numbers[required.id]}"
        for required in m.verified_requirements(c.id)
    )
    completion = MANUAL_COMPLETION_CONDITIONS[c.completion_condition]
    failure = MANUAL_FAILURE_EFFECTS[c.failure_effect]
    return (
        f"{preamble}\n\nThis is an operator-held completion gate and is not "
        f"automatically dispatched. Verified prerequisites: {required_refs}. "
        f"{failure} {completion}\n\n{child_identity_marker(c)}\n"
        f"{child_source_marker(m, c)}"
    )


def render_epic_body(m: Milestone, numbers: dict[str, int]) -> str:
    """Render an epic body with the current parseable checklist contract."""
    payload = f"tools/github/milestone-epics.d/{m.id.lower()}.yaml"
    source = f"{ORG}/Odysseus:{payload}"
    workflow = f"{ORG}/Odysseus:{m.workflow}"
    lines = [
        f"Epic tracking Milestone {m.id[1:]} of the mesh-distributed Hephaestus "
        f"loop. Current task source: `{source}`. Planning context: "
        f"`{workflow}` and Proposed ADR-020 sections 7 and 9. "
        f"{m.home_rationale}",
        "",
        f"Cross-milestone ordering: {m.ordering_note}",
        "",
        "## Tasks",
    ]
    for child in (candidate for candidate in m.children if not candidate.manual):
        number = numbers.get(child.id)
        if number is None:
            raise KeyError(f"{child.id}: child issue number unknown during rendering")
        deps = m.deps(child.id)
        if deps:
            dep_refs = ", ".join(f"#{numbers[dependency.id]}" for dependency in deps)
            lines.append(f"- [ ] #{number} (depends on: {dep_refs})")
        else:
            lines.append(f"- [ ] #{number}")
    manual_gates = [child for child in m.children if child.manual]
    if manual_gates:
        lines.extend(["", "## Operator completion gates"])
        for gate in manual_gates:
            gate_number = numbers.get(gate.id)
            if gate_number is None:
                raise KeyError(f"{gate.id}: gate issue number unknown during rendering")
            required_refs = ", ".join(
                f"{ORG}/{required.repo}#{numbers[required.id]}"
                for required in m.verified_requirements(gate.id)
            )
            lines.append(
                f"- {ORG}/{gate.repo}#{gate_number} "
                f"(operator verifies: {required_refs})"
            )
    lines.extend(["", epic_identity_marker(m), epic_source_marker(m)])
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


def issue_inventory(repo: str) -> list[dict[str, object]]:
    """Load a bounded all-state issue inventory, failing if it may be partial."""
    out = gh(
        "issue", "list", "-R", f"{ORG}/{repo}", "--state", "all",
        "--limit", str(ISSUE_INVENTORY_LIMIT),
        "--json", "number,title,state,body,labels",
    )
    entries = json.loads(out)
    if len(entries) >= ISSUE_INVENTORY_LIMIT:
        raise RuntimeError(
            f"{repo}: issue inventory reached {ISSUE_INVENTORY_LIMIT}; "
            "refusing a potentially incomplete reconciliation"
        )
    return entries


def label_inventory(repo: str) -> set[str]:
    """Load existing label names without rewriting repository-owned metadata."""
    out = gh(
        "label", "list", "-R", f"{ORG}/{repo}",
        "--limit", str(LABEL_INVENTORY_LIMIT), "--json", "name",
    )
    entries = json.loads(out)
    if len(entries) >= LABEL_INVENTORY_LIMIT:
        raise RuntimeError(
            f"{repo}: label inventory reached {LABEL_INVENTORY_LIMIT}; "
            "refusing a potentially incomplete reconciliation"
        )
    return {str(entry["name"]) for entry in entries}


def issue_label_names(entry: dict[str, object]) -> set[str]:
    """Normalize label names returned by ``gh issue list --json labels``."""
    labels = entry.get("labels", [])
    if not isinstance(labels, list):
        raise RuntimeError("issue label payload is not a list")
    names: set[str] = set()
    for label in labels:
        if not isinstance(label, dict) or "name" not in label:
            raise RuntimeError("issue label payload contains an invalid entry")
        names.add(str(label["name"]))
    return names


def existing_open_epic(
    milestone: Milestone, entries: list[dict[str, object]]
) -> int | None:
    """Return one open marker-bound epic, failing closed on identity drift."""
    marker = epic_identity_marker(milestone)
    matches = [entry for entry in entries if marker in str(entry["body"] or "")]
    if len(matches) > 1:
        raise RuntimeError(
            f"{milestone.id}: multiple marker-bound epics exist in "
            f"{milestone.epic_home}"
        )
    if not matches:
        same_title = [entry for entry in entries if entry["title"] == milestone.title]
        if same_title:
            raise RuntimeError(
                f"{milestone.id}: same-title epic without stable marker exists in "
                f"{milestone.epic_home}; operator reconciliation required"
            )
        return None
    match = matches[0]
    if match["title"] != milestone.title:
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic title drift in {milestone.epic_home}"
        )
    if str(match["state"]).upper() != "OPEN":
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic #{match['number']} is not open"
        )
    if epic_source_marker(milestone) not in str(match["body"] or ""):
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic source drift in "
            f"{milestone.epic_home}"
        )
    if EPIC_LABEL not in issue_label_names(match):
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic is missing {EPIC_LABEL!r}"
        )
    return int(match["number"])


def existing_child_issue(
    milestone: Milestone, child: Child, entries: list[dict[str, object]]
) -> int | None:
    """Return a unique open marker-bound child, failing closed on drift."""
    marker = child_identity_marker(child)
    matches = [entry for entry in entries if marker in str(entry["body"] or "")]
    if len(matches) > 1:
        raise RuntimeError(
            f"{child.id}: multiple marker-bound issues exist in {child.repo}"
        )
    if not matches:
        same_title = [entry for entry in entries if entry["title"] == child.subject]
        if same_title:
            raise RuntimeError(
                f"{child.id}: same-title issue without stable marker exists in "
                f"{child.repo}; operator reconciliation required"
            )
        return None
    match = matches[0]
    if match["title"] != child.subject:
        raise RuntimeError(
            f"{child.id}: marker-bound issue title drift in {child.repo}"
        )
    if str(match["state"]).upper() != "OPEN":
        raise RuntimeError(
            f"{child.id}: marker-bound issue #{match['number']} is not open"
        )
    if child_source_marker(milestone, child) not in str(match["body"] or ""):
        raise RuntimeError(
            f"{child.id}: marker-bound issue source drift in {child.repo}"
        )
    state_labels = {
        label for label in issue_label_names(match) if label.startswith("state:")
    }
    expected_state_labels = set() if child.manual else {NEEDS_PLAN_LABEL}
    if state_labels != expected_state_labels:
        raise RuntimeError(
            f"{child.id}: marker-bound issue has unsafe state labels "
            f"{sorted(state_labels)!r}; expected {sorted(expected_state_labels)!r}"
        )
    return int(match["number"])


def _ensure_label(
    repo: str,
    label: str,
    description: str,
    color: str,
    existing_labels: set[str],
) -> None:
    """Create a missing label while preserving existing repository metadata."""
    if label in existing_labels:
        return
    gh(
        "label", "create", label, "-R", f"{ORG}/{repo}",
        "--description", description, "--color", color,
    )
    existing_labels.add(label)


def issue_creation_order(milestone: Milestone) -> tuple[Child, ...]:
    """Create dispatchable work before gates that need all resulting numbers."""
    return tuple(child for child in milestone.children if not child.manual) + tuple(
        child for child in milestone.children if child.manual
    )


def apply_plan(milestones: list[Milestone]) -> int:
    """Create labels, children, and epics via retry-safe ``gh`` reconciliation."""
    created_epics: list[tuple[Milestone, str]] = []

    # Pre-create BOTH labels in every repo touched by children or epic
    # bodies, so `gh issue create --label ...` cannot fail mid-loop on a
    # missing label after earlier children were already created.
    repos = {m.epic_home for m in milestones}
    repos.update(child.repo for m in milestones for child in m.children)
    inventories = {repo: issue_inventory(repo) for repo in sorted(repos)}
    existing_labels = {repo: label_inventory(repo) for repo in sorted(repos)}
    existing_epics = {
        m.id: existing_open_epic(m, inventories[m.epic_home]) for m in milestones
    }
    existing_children = {
        child.id: existing_child_issue(m, child, inventories[child.repo])
        for m in milestones
        if existing_epics[m.id] is None
        for child in m.children
    }

    # Only mutate labels after every issue identity has been reconciled.
    for repo in sorted(repos):
        _ensure_label(
            repo, EPIC_LABEL, EPIC_LABEL_DESCRIPTION, EPIC_LABEL_COLOR,
            existing_labels[repo],
        )
        _ensure_label(
            repo, NEEDS_PLAN_LABEL, NEEDS_PLAN_LABEL_DESCRIPTION,
            NEEDS_PLAN_LABEL_COLOR, existing_labels[repo],
        )

    for m in milestones:
        if existing_epics[m.id] is not None:
            print(f"{m.id}: epic already registered in {m.epic_home}, skipping")
            continue
        numbers: dict[str, int] = {}
        for child in issue_creation_order(m):
            existing_child = existing_children[child.id]
            if existing_child is not None:
                numbers[child.id] = existing_child
                print(
                    f"{m.id}: reused {child.repo}#{existing_child} ({child.id})"
                )
                continue
            create_args = [
                "issue", "create", "-R", f"{ORG}/{child.repo}",
                "--title", child.subject,
                "--body", render_child_body(m, child, numbers),
            ]
            if not child.manual:
                create_args[4:4] = ["--label", NEEDS_PLAN_LABEL]
            url = gh(*create_args)
            numbers[child.id] = issue_number_from_url(url)
            print(f"{m.id}: created {child.repo}#{numbers[child.id]} ({child.id})")
        epic_url = gh(
            "issue", "create", "-R", f"{ORG}/{m.epic_home}",
            "--label", EPIC_LABEL,
            "--title", m.title,
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
            mode = "operator-gate" if child.manual else "dispatch"
            verified = ", ".join(child.requires_verified) or "-"
            print(
                f"  {child.id}  repo={child.repo}  mode={mode}  "
                f"blocked_by={deps}  requires_verified={verified}"
            )
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
