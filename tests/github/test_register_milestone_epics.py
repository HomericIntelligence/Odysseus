#!/usr/bin/env python3
"""Behavior assertions for the M1-M6 epic registration payloads (issue #468).

Runs under pytest (``uv run python -m pytest tests/github/``) and also as a
plain script (``python3 tests/github/register-milestone-epics.test.py``) so it
works in environments without pytest, matching the repo's self-test pattern.
"""

from __future__ import annotations

import importlib.util
import sys
from dataclasses import replace
from pathlib import Path

_TOOL_PATH = (
    Path(__file__).resolve().parents[2] / "tools" / "github" / "register-milestone-epics.py"
)
_spec = importlib.util.spec_from_file_location("register_milestone_epics", _TOOL_PATH)
assert _spec is not None and _spec.loader is not None
reg = importlib.util.module_from_spec(_spec)
sys.modules["register_milestone_epics"] = reg
_spec.loader.exec_module(reg)

PAYLOADS = reg.PAYLOAD_DIR
EXPECTED_HOMES = {
    "M1": "Hephaestus",
    "M2": "Odysseus",
    "M3": "Myrmidons",
    "M4": "Odysseus",
    "M5": "Nestor",
    "M6": "Odysseus",
}


def _load():
    milestones = reg.load_payloads(PAYLOADS)
    errors = reg.validate(milestones)
    assert not errors, f"payload validation failed: {errors}"
    return milestones


def test_six_milestones_with_correct_epic_homes() -> None:
    milestones = _load()
    assert [m.id for m in milestones] == [f"M{i}" for i in range(1, 7)]
    for m in milestones:
        assert m.epic_home == EXPECTED_HOMES[m.id]


def test_every_child_is_single_dispatchable_and_labeled_repo_valid() -> None:
    milestones = _load()
    total = 0
    for m in milestones:
        for child in m.children:
            total += 1
            assert child.repo in reg.KNOWN_REPOS
            # One dispatchable task: subject is a single line, description
            # carries the transcribed requirements (never empty).
            assert "\n" not in child.subject
            assert len(child.description) > 40
    assert total == 40, f"expected 40 children across M1-M6, got {total}"


def test_each_milestone_has_unblocked_requirements_child_first() -> None:
    for m in _load():
        first = m.children[0]
        assert m.blocked_by.get(first.id, ()) == (), (
            f"{m.id}: first child {first.id} must be the unblocked requirements capture"
        )
        assert "Requirements" in first.subject or "requirements" in first.subject


def test_dependency_edges_resolve_to_siblings_acyclically() -> None:
    for m in _load():
        resolved = {c.id for c in m.children}
        for cid, deps in m.blocked_by.items():
            for dep in deps:
                assert dep != cid
                assert dep in resolved, f"{cid}: unknown dependency {dep}"
        # Acyclicity via Kahn's algorithm.
        indegree = {c.id: len(m.blocked_by.get(c.id, ())) for c in m.children}
        queue = [cid for cid, deg in indegree.items() if deg == 0]
        seen = 0
        while queue:
            node = queue.pop()
            seen += 1
            for cid, deps in m.blocked_by.items():
                if node in deps:
                    indegree[cid] -= 1
                    if indegree[cid] == 0:
                        queue.append(cid)
        assert seen == len(m.children), f"{m.id}: dependency cycle detected"


def test_epic_body_checklist_matches_adr013_grammar() -> None:
    for m in _load():
        numbers = {c.id: i + 100 for i, c in enumerate(m.children)}
        body = reg.render_epic_body(m, numbers)
        checklist = [
            line for line in body.splitlines() if line.startswith("- [ ] ")
        ]
        assert len(checklist) == len(m.children)
        for line in checklist:
            assert reg.CHECKLIST_LINE_RE.match(line), f"bad checklist grammar: {line}"
        assert f"`{m.workflow}`" in body
        assert "ADR-020" in body


def test_child_body_transcribes_workflow_requirements() -> None:
    milestones = _load()
    m1 = next(m for m in milestones if m.id == "M1")
    req = m1.children[0]
    body = reg.render_child_body(m1, req)
    assert "AckExplicit" in body and "MaxDeliver 3" in body
    assert "`workflows/m1-hephaestus-keystone.yaml`" in body
    assert "pointer-only" in body
    # Cross-repo children land in their owning repo (ADR-020 section 6).
    m3 = next(m for m in milestones if m.id == "M3")
    repos = {c.repo for c in m3.children}
    assert {"Myrmidons", "AchaeanFleet", "Agamemnon", "Odysseus"} <= repos


def test_validate_rejects_broken_payloads() -> None:
    milestones = _load()

    wrong_home = [replace(milestones[0], epic_home="Odysseus")] + milestones[1:]
    assert any("epic_home" in e for e in reg.validate(wrong_home))

    m1 = milestones[0]
    clashing_children = (
        m1.children[0],
        replace(m1.children[1], id=m1.children[0].id),
    ) + tuple(m1.children[2:])
    dup_id = [replace(m1, children=clashing_children)] + milestones[1:]
    assert any("duplicate child id" in e for e in reg.validate(dup_id))

    broken_deps = [
        replace(
            milestones[0],
            children=milestones[0].children,
            blocked_by={"M1.9": ()},
        )
    ] + milestones[1:]
    broken_deps[0] = replace(
        broken_deps[0],
        blocked_by={**broken_deps[0].blocked_by, "M1.2": ("M1.9",)},
    )
    assert any("not a sibling" in e for e in reg.validate(broken_deps))

    missing = milestones[:5]
    assert any("six milestones" in e for e in reg.validate(missing))


def test_rendering_requires_known_numbers() -> None:
    m1 = _load()[0]
    try:
        reg.render_epic_body(m1, {})
    except KeyError as exc:
        assert "child issue number" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("render_epic_body must fail on missing numbers")


def main() -> int:
    checks = [
        test_six_milestones_with_correct_epic_homes,
        test_every_child_is_single_dispatchable_and_labeled_repo_valid,
        test_each_milestone_has_unblocked_requirements_child_first,
        test_dependency_edges_resolve_to_siblings_acyclically,
        test_epic_body_checklist_matches_adr013_grammar,
        test_child_body_transcribes_workflow_requirements,
        test_validate_rejects_broken_payloads,
        test_rendering_requires_known_numbers,
    ]
    failed = 0
    for check in checks:
        try:
            check()
        except AssertionError as exc:
            print(f"FAIL {check.__name__}: {exc}")
            failed += 1
        else:
            print(f"ok   {check.__name__}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
