#!/usr/bin/env python3
"""Behavior assertions for the M1-M6 epic registration payloads (issue #468).

Runs under pytest and also through ``just test-milestone-registry``, which
uses the plain-script entry point so the checks work without pytest.
"""

from __future__ import annotations

import importlib.util
import json
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
EXPECTED_MANUAL_GATE_LABEL = "agamemnon-operator-gate"


def _load():
    milestones = reg.load_payloads(PAYLOADS)
    errors = reg.validate(milestones)
    assert not errors, f"payload validation failed: {errors}"
    return milestones


def _assert_all_rejected(cases) -> None:
    """Assert that every unsafe reconciliation case stops before reuse."""
    accepted = []
    for operation, context in cases:
        try:
            operation()
        except RuntimeError:
            continue
        accepted.append(context)
    assert not accepted, f"unsafe reconciliation was accepted: {', '.join(accepted)}"


def _canonical_child_inventory(milestone):
    """Build one complete, canonical child inventory for apply-mode tests."""
    numbers = {
        child.id: number
        for number, child in enumerate(milestone.children, start=100)
    }
    issues_by_repo: dict[str, list[dict[str, object]]] = {}
    for child in milestone.children:
        labels = [
            {
                "name": (
                    EXPECTED_MANUAL_GATE_LABEL
                    if child.manual
                    else reg.NEEDS_PLAN_LABEL
                )
            }
        ]
        issues_by_repo.setdefault(child.repo, []).append(
            {
                "number": numbers[child.id],
                "title": child.subject,
                "state": "OPEN",
                "body": reg.render_child_body(
                    milestone, child, numbers if child.manual else None
                ),
                "labels": labels,
            }
        )
    return issues_by_repo, numbers


def _assert_apply_rejected_before_write(milestone, issues_by_repo, message) -> None:
    """Run apply against an inventory and prove validation precedes every write."""
    calls = []
    original_gh = reg.gh

    def fake_gh(*args):
        calls.append(args)
        if args[:2] == ("issue", "list"):
            repo = args[args.index("-R") + 1].split("/", 1)[1]
            return json.dumps(issues_by_repo.get(repo, []))
        if args[:2] == ("label", "list"):
            # Missing labels make any premature label mutation observable.
            return "[]"
        raise AssertionError(f"mutation occurred before preflight completed: {args}")

    reg.gh = fake_gh
    try:
        try:
            reg.apply_plan([milestone])
        except RuntimeError as exc:
            assert message in str(exc)
        else:  # pragma: no cover
            raise AssertionError("unsafe reusable issue must stop apply")
    finally:
        reg.gh = original_gh

    assert not any(
        call[:2] in {("issue", "create"), ("label", "create")} for call in calls
    )


def test_six_milestones_with_correct_epic_homes() -> None:
    milestones = _load()
    assert [m.id for m in milestones] == [f"M{i}" for i in range(1, 7)]
    for m in milestones:
        assert m.epic_home == EXPECTED_HOMES[m.id]


def test_every_child_is_single_purpose_and_repo_valid() -> None:
    milestones = _load()
    total = 0
    for m in milestones:
        for child in m.children:
            total += 1
            assert child.repo in reg.KNOWN_REPOS
            # Structural presence only: no word, byte, or section-count gate.
            assert "\n" not in child.subject
            assert child.subject.strip()
            assert child.description.strip()
    assert total == 41, f"expected 41 children across M1-M6, got {total}"


def test_each_milestone_has_unblocked_requirements_child_first() -> None:
    for m in _load():
        first = m.children[0]
        assert m.blocked_by.get(first.id, ()) == (), (
            f"{m.id}: first child {first.id} must be the unblocked requirements capture"
        )


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


def test_epic_body_checklist_is_structurally_parseable() -> None:
    for m in _load():
        numbers = {c.id: i + 100 for i, c in enumerate(m.children)}
        body = reg.render_epic_body(m, numbers)
        checklist = [
            line for line in body.splitlines() if line.startswith("- [ ] ")
        ]
        dispatchable = [child for child in m.children if not child.manual]
        assert len(checklist) == len(dispatchable)
        for line in checklist:
            assert reg.CHECKLIST_LINE_RE.match(line), f"bad checklist grammar: {line}"
        assert f"`{reg.ORG}/Odysseus:{m.workflow}`" in body


def test_child_body_transports_authored_content_and_identifies_sources() -> None:
    milestones = _load()
    m1 = next(m for m in milestones if m.id == "M1")
    req = m1.children[0]
    probe = replace(req, description="opaque-authored-payload-7d41")
    body = reg.render_child_body(m1, probe)
    assert "opaque-authored-payload-7d41" in body
    assert "`HomericIntelligence/Odysseus:tools/github/milestone-epics.d/m1.yaml`" in body
    assert "`HomericIntelligence/Odysseus:workflows/m1-hephaestus-keystone.yaml`" in body
    assert "HomericIntelligence/Odysseus#464" in body
    assert "<!-- HomericIntelligence:milestone-task id=M1.1 -->" in body
    # Cross-repository children land in their owning repository.
    m3 = next(m for m in milestones if m.id == "M3")
    repos = {c.repo for c in m3.children}
    assert {"Myrmidons", "AchaeanFleet", "Agamemnon", "Odysseus"} <= repos


def test_m4_has_manual_dogfood_evidence_gate_after_rollout() -> None:
    m4 = next(m for m in _load() if m.id == "M4")
    closures = [child for child in m4.children if child.id == "M4.8"]
    assert len(closures) == 1, "M4 needs one evidence-bearing closure child"
    closure = closures[0]
    assert closure.repo == "Odysseus"
    assert closure.manual
    assert m4.blocked_by[closure.id] == ()
    assert closure.requires_verified == (
        "M4.2",
        "M4.3",
        "M4.4",
        "M4.5",
        "M4.6",
        "M4.7",
    )
    assert closure.failure_effect == "keep_open"
    assert closure.completion_condition == "successful_mesh_only_merge"


def test_m4_manual_gate_is_qualified_and_outside_parser_tasks() -> None:
    m4 = next(m for m in _load() if m.id == "M4")
    numbers = {child.id: index + 100 for index, child in enumerate(m4.children)}
    body = reg.render_epic_body(m4, numbers)
    gate_line = next(
        line
        for line in body.splitlines()
        if f"{reg.ORG}/Odysseus#{numbers['M4.8']}" in line
    )
    closure = next(child for child in m4.children if child.id == "M4.8")
    assert not reg.CHECKLIST_LINE_RE.match(gate_line)
    for prerequisite in m4.verified_requirements(closure.id):
        ref = f"{reg.ORG}/{prerequisite.repo}#{numbers[prerequisite.id]}"
        assert ref in gate_line
    gate_body = reg.render_child_body(m4, closure, numbers)
    for prerequisite in m4.verified_requirements(closure.id):
        ref = f"{reg.ORG}/{prerequisite.repo}#{numbers[prerequisite.id]}"
        assert ref in gate_body
    reordered = replace(
        m4,
        children=(closure,) + tuple(child for child in m4.children if not child.manual),
    )
    assert reg.issue_creation_order(reordered)[-1] == closure


def test_label_ensure_preserves_existing_metadata_and_propagates_failures() -> None:
    calls = []
    original_gh = reg.gh

    def fake_gh(*args):
        calls.append(args)
        return ""

    reg.gh = fake_gh
    try:
        existing = {"state:test"}
        reg._ensure_label(
            "Odysseus", "state:test", "local metadata", "012345", existing
        )
        assert calls == [], "existing repository metadata must not be overwritten"
        reg._ensure_label(
            "Odysseus", "state:new", "new label", "abcdef", existing
        )
    finally:
        reg.gh = original_gh

    assert len(calls) == 1
    assert calls[0][:2] == ("label", "create")
    assert "--force" not in calls[0]
    assert "state:new" in existing

    reg.gh = lambda *args: (_ for _ in ()).throw(RuntimeError("label failure"))
    try:
        reg._ensure_label(
            "Odysseus", "state:missing", "test label", "012345", set()
        )
    except RuntimeError as exc:
        assert "label failure" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("label failures must propagate")
    finally:
        reg.gh = original_gh


def test_apply_plan_reuses_children_uses_title_and_holds_manual_gate() -> None:
    m4 = next(m for m in _load() if m.id == "M4")
    existing = m4.children[0]
    calls = []
    next_number = 200
    original_gh = reg.gh

    def fake_gh(*args):
        nonlocal next_number
        calls.append(args)
        if args[:2] == ("issue", "list"):
            repo = args[args.index("-R") + 1]
            if repo == f"{reg.ORG}/{existing.repo}":
                return json.dumps(
                    [
                        {
                            "number": 77,
                            "title": existing.subject,
                            "state": "OPEN",
                            "body": reg.render_child_body(m4, existing),
                            "labels": [{"name": reg.NEEDS_PLAN_LABEL}],
                        }
                    ]
                )
            return "[]"
        if args[:2] == ("label", "list"):
            return json.dumps(
                [
                    {"name": reg.EPIC_LABEL},
                    {"name": reg.NEEDS_PLAN_LABEL},
                    {"name": EXPECTED_MANUAL_GATE_LABEL},
                ]
            )
        if args[:2] == ("issue", "create"):
            repo = args[args.index("-R") + 1]
            next_number += 1
            return f"https://github.com/{repo}/issues/{next_number}"
        raise AssertionError(f"unexpected gh call: {args}")

    reg.gh = fake_gh
    try:
        assert reg.apply_plan([m4]) == 0
    finally:
        reg.gh = original_gh

    creates = [call for call in calls if call[:2] == ("issue", "create")]
    assert creates
    assert all("--title" in call and "--subject" not in call for call in creates)
    created_titles = [call[call.index("--title") + 1] for call in creates]
    assert existing.subject not in created_titles
    assert m4.title in created_titles
    epic_call = next(
        call
        for call in creates
        if call[call.index("--title") + 1] == m4.title
    )
    epic_body = epic_call[epic_call.index("--body") + 1]
    assert reg.epic_identity_marker(m4) in epic_body
    assert reg.epic_source_marker(m4) in epic_body
    gate = next(child for child in m4.children if child.manual)
    gate_call = next(
        call
        for call in creates
        if call[call.index("--title") + 1] == gate.subject
    )
    assert "--label" in gate_call
    assert (
        gate_call[gate_call.index("--label") + 1] == EXPECTED_MANUAL_GATE_LABEL
    )
    gate_body = gate_call[gate_call.index("--body") + 1]
    assert reg.child_identity_marker(gate) in gate_body
    assert reg.child_source_marker(m4, gate) in gate_body
    for child in m4.children:
        if child.manual or child.id == existing.id:
            continue
        child_call = next(
            call
            for call in creates
            if call[call.index("--title") + 1] == child.subject
        )
        assert child_call[child_call.index("--label") + 1] == reg.NEEDS_PLAN_LABEL
        child_body = child_call[child_call.index("--body") + 1]
        assert reg.child_identity_marker(child) in child_body
        assert reg.child_source_marker(m4, child) in child_body


def test_apply_plan_rejects_unsafe_manual_retry_before_any_write() -> None:
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, _ = _canonical_child_inventory(m4)
    gate = next(child for child in m4.children if child.manual)
    gate_entry = next(
        entry
        for entry in issues_by_repo[gate.repo]
        if entry["title"] == gate.subject
    )
    # This is the unsafe legacy state the preflight must reject.
    gate_entry["labels"] = [
        {"name": EXPECTED_MANUAL_GATE_LABEL},
        {"name": reg.NEEDS_PLAN_LABEL},
    ]

    _assert_apply_rejected_before_write(m4, issues_by_repo, "unsafe state labels")


def test_apply_plan_rejects_unlabeled_gate_before_any_write() -> None:
    """A copied public gate body is not reusable without controlled metadata."""
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, _ = _canonical_child_inventory(m4)
    gate = next(child for child in m4.children if child.manual)
    gate_entry = next(
        entry
        for entry in issues_by_repo[gate.repo]
        if entry["title"] == gate.subject
    )
    gate_entry["labels"] = []

    _assert_apply_rejected_before_write(
        m4, issues_by_repo, f"missing {EXPECTED_MANUAL_GATE_LABEL!r}"
    )


def test_existing_epic_does_not_bypass_child_preflight() -> None:
    """A canonical epic cannot hide drift in one of its referenced children."""
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, numbers = _canonical_child_inventory(m4)
    first = m4.children[0]
    first_entry = next(
        entry
        for entry in issues_by_repo[first.repo]
        if entry["title"] == first.subject
    )
    first_entry["body"] = str(first_entry["body"]).replace(
        first.description, "ATTACKER CONTROLLED BODY"
    )
    issues_by_repo.setdefault(m4.epic_home, []).append(
        {
            "number": 999,
            "title": m4.title,
            "state": "OPEN",
            "body": reg.render_epic_body(m4, numbers),
            "labels": [{"name": reg.EPIC_LABEL}],
        }
    )

    _assert_apply_rejected_before_write(m4, issues_by_repo, "source drift")


def test_existing_epic_allows_canonical_child_lifecycle_progress() -> None:
    """Retry skips a registered epic after canonical children advance or close."""
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, numbers = _canonical_child_inventory(m4)
    first = m4.children[0]
    first_entry = next(
        entry
        for entry in issues_by_repo[first.repo]
        if entry["title"] == first.subject
    )
    first_entry["state"] = "CLOSED"
    first_entry["labels"] = [{"name": "state:plan-go"}]
    issues_by_repo.setdefault(m4.epic_home, []).append(
        {
            "number": 999,
            "title": m4.title,
            "state": "OPEN",
            "body": reg.render_epic_body(m4, numbers),
            "labels": [{"name": reg.EPIC_LABEL}],
        }
    )
    calls = []
    original_gh = reg.gh

    def fake_gh(*args):
        calls.append(args)
        if args[:2] == ("issue", "list"):
            repo = args[args.index("-R") + 1].split("/", 1)[1]
            return json.dumps(issues_by_repo.get(repo, []))
        if args[:2] == ("label", "list"):
            return json.dumps(
                [
                    {"name": reg.EPIC_LABEL},
                    {"name": reg.NEEDS_PLAN_LABEL},
                    {"name": EXPECTED_MANUAL_GATE_LABEL},
                ]
            )
        raise AssertionError(f"registered epic rerun attempted a write: {args}")

    reg.gh = fake_gh
    try:
        assert reg.apply_plan([m4]) == 0
    finally:
        reg.gh = original_gh

    assert not any(
        call[:2] in {("issue", "create"), ("label", "create")} for call in calls
    )


def test_partial_retry_requires_initial_child_state_before_any_write() -> None:
    """Without a registered epic, reusable children must remain at intake."""
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, _ = _canonical_child_inventory(m4)
    first = m4.children[0]
    first_entry = next(
        entry
        for entry in issues_by_repo[first.repo]
        if entry["title"] == first.subject
    )
    first_entry["labels"] = [{"name": "state:plan-go"}]

    _assert_apply_rejected_before_write(m4, issues_by_repo, "unsafe state labels")

    closed_issues, _ = _canonical_child_inventory(m4)
    closed_entry = next(
        entry
        for entry in closed_issues[first.repo]
        if entry["title"] == first.subject
    )
    closed_entry["state"] = "CLOSED"
    _assert_apply_rejected_before_write(m4, closed_issues, "is not open")


def test_registered_child_lifecycle_matches_pinned_hephaestus_contract() -> None:
    """Issue plan states allow optional skip but never PR verdict states."""
    milestone = _load()[0]
    child = milestone.children[0]

    def entry(labels):
        return {
            "number": 42,
            "title": child.subject,
            "state": "CLOSED",
            "body": reg.render_child_body(milestone, child),
            "labels": [{"name": label} for label in labels],
        }

    plan_states = (
        reg.NEEDS_PLAN_LABEL,
        "state:plan-go",
        "state:plan-no-go",
        "state:plan-blocked",
    )
    for plan_state in plan_states:
        assert reg.existing_child_issue(
            milestone,
            child,
            [entry([plan_state])],
            require_initial_state=False,
        ) == 42
        assert reg.existing_child_issue(
            milestone,
            child,
            [entry([plan_state, "state:skip"])],
            require_initial_state=False,
        ) == 42

    _assert_all_rejected(
        (
            (
                lambda: reg.existing_child_issue(
                    milestone,
                    child,
                    [entry(["state:implementation-go"])],
                    require_initial_state=False,
                ),
                "PR-only implementation-go on an issue",
            ),
            (
                lambda: reg.existing_child_issue(
                    milestone,
                    child,
                    [entry(["state:implementation-no-go"])],
                    require_initial_state=False,
                ),
                "PR-only implementation-no-go on an issue",
            ),
            (
                lambda: reg.existing_child_issue(
                    milestone,
                    child,
                    [entry(["state:skip"])],
                    require_initial_state=False,
                ),
                "skip without one issue plan state",
            ),
            (
                lambda: reg.existing_child_issue(
                    milestone,
                    child,
                    [entry([reg.NEEDS_PLAN_LABEL, "state:plan-go"])],
                    require_initial_state=False,
                ),
                "two mutually exclusive issue plan states",
            ),
        )
    )


def test_child_reconciliation_fails_closed_on_ambiguous_identity() -> None:
    milestone = next(m for m in _load() if m.id == "M1")
    child = milestone.children[0]
    marker = reg.child_identity_marker(child)

    same_title_without_marker = [
        {"number": 1, "title": child.subject, "state": "OPEN", "body": "legacy"}
    ]
    try:
        reg.existing_child_issue(milestone, child, same_title_without_marker)
    except RuntimeError as exc:
        assert "without stable marker" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("unmarked same-title issues must stop reconciliation")

    duplicate_markers = [
        {"number": 2, "title": child.subject, "state": "OPEN", "body": marker},
        {"number": 3, "title": child.subject, "state": "OPEN", "body": marker},
    ]
    try:
        reg.existing_child_issue(milestone, child, duplicate_markers)
    except RuntimeError as exc:
        assert "multiple marker-bound" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("duplicate stable identities must stop reconciliation")

    stale_source = [
        {
            "number": 4,
            "title": child.subject,
            "state": "OPEN",
            "body": marker,
            "labels": [{"name": reg.NEEDS_PLAN_LABEL}],
        }
    ]
    try:
        reg.existing_child_issue(milestone, child, stale_source)
    except RuntimeError as exc:
        assert "source drift" in str(exc)
    else:  # pragma: no cover
        raise AssertionError("stale marker-bound task content must stop reconciliation")

    changed = replace(child, description=child.description + " changed")
    assert reg.child_source_marker(milestone, changed) != reg.child_source_marker(
        milestone, child
    )


def test_reconciliation_rejects_body_drift_with_current_markers() -> None:
    """A copied source marker must not authenticate changed generated content."""
    milestones = _load()
    milestone = milestones[0]
    child = milestone.children[0]
    canonical_child = reg.render_child_body(milestone, child)
    altered_child = canonical_child.replace(
        child.description, "ATTACKER CONTROLLED BODY"
    )
    child_entry = {
        "number": 42,
        "title": child.subject,
        "state": "OPEN",
        "body": altered_child,
        "labels": [{"name": reg.NEEDS_PLAN_LABEL}],
    }
    numbers = {
        candidate.id: index + 100
        for index, candidate in enumerate(milestone.children)
    }
    canonical_epic = reg.render_epic_body(milestone, numbers)
    first_number = numbers[milestone.children[0].id]
    changed_epic_bodies = {
        "lowercase checked canonical row": canonical_epic.replace(
            f"- [ ] #{first_number}", f"- [x] #{first_number}", 1
        ),
        "uppercase checked canonical row": canonical_epic.replace(
            f"- [ ] #{first_number}", f"- [X] #{first_number}", 1
        ),
        "injected unchecked row": canonical_epic.replace(
            "## Tasks", "## Tasks\n- [ ] #999999"
        ),
        "injected checked row": canonical_epic.replace(
            "## Tasks", "## Tasks\n- [x] #999999"
        ),
    }
    cases = [
        (
            lambda: reg.existing_child_issue(milestone, child, [child_entry]),
            "changed child body retaining both current markers",
        )
    ]
    for context, body in changed_epic_bodies.items():
        epic_entry = {
            "number": 11,
            "title": milestone.title,
            "state": "OPEN",
            "body": body,
            "labels": [{"name": reg.EPIC_LABEL}],
        }
        cases.append(
            (
                lambda entry=epic_entry: reg.existing_open_epic(
                    milestone, [entry], numbers
                ),
                context,
            )
        )
    _assert_all_rejected(cases)


def test_reconciliation_rejects_unmarked_same_title_alongside_marker() -> None:
    """One marker-bound issue must not hide a second ambiguous title match."""
    milestone = _load()[0]
    child = milestone.children[0]
    child_entries = [
        {
            "number": 42,
            "title": child.subject,
            "state": "OPEN",
            "body": reg.render_child_body(milestone, child),
            "labels": [{"name": reg.NEEDS_PLAN_LABEL}],
        },
        {
            "number": 43,
            "title": child.subject,
            "state": "OPEN",
            "body": "unmarked duplicate",
            "labels": [],
        },
    ]

    numbers = {
        candidate.id: index + 100
        for index, candidate in enumerate(milestone.children)
    }
    epic_entries = [
        {
            "number": 11,
            "title": milestone.title,
            "state": "OPEN",
            "body": reg.render_epic_body(milestone, numbers),
            "labels": [{"name": reg.EPIC_LABEL}],
        },
        {
            "number": 12,
            "title": milestone.title,
            "state": "OPEN",
            "body": "unmarked duplicate",
            "labels": [],
        },
    ]

    cases = (
        (
            lambda: reg.existing_child_issue(milestone, child, child_entries),
            "marked child plus unmarked same-title child",
        ),
        (
            lambda: reg.existing_open_epic(milestone, epic_entries, numbers),
            "marked epic plus unmarked same-title epic",
        ),
    )
    _assert_all_rejected(cases)


def test_manual_gate_requires_dedicated_non_state_label() -> None:
    """Public marker prose cannot substitute for repository-controlled metadata."""
    milestone = next(candidate for candidate in _load() if candidate.id == "M4")
    gate = next(child for child in milestone.children if child.manual)
    numbers = {
        child.id: index + 100 for index, child in enumerate(milestone.children)
    }
    body = reg.render_child_body(milestone, gate, numbers)

    def entry(labels):
        return {
            "number": 44,
            "title": gate.subject,
            "state": "OPEN",
            "body": body,
            "labels": [{"name": label} for label in labels],
        }

    assert reg.OPERATOR_GATE_LABEL == EXPECTED_MANUAL_GATE_LABEL
    assert reg.existing_child_issue(
        milestone, gate, [entry([EXPECTED_MANUAL_GATE_LABEL])], numbers
    ) == 44
    _assert_all_rejected(
        (
            (
                lambda: reg.existing_child_issue(
                    milestone, gate, [entry([])], numbers
                ),
                "unlabeled manual-gate spoof",
            ),
            (
                lambda: reg.existing_child_issue(
                    milestone,
                    gate,
                    [entry([EXPECTED_MANUAL_GATE_LABEL, reg.NEEDS_PLAN_LABEL])],
                    numbers,
                ),
                "manual gate carrying an automatic state label",
            ),
        )
    )


def test_epic_reconciliation_requires_current_source_and_tracking_label() -> None:
    milestone = _load()[0]
    identity = reg.epic_identity_marker(milestone)
    current = reg.epic_source_marker(milestone)
    numbers = {
        child.id: index + 100 for index, child in enumerate(milestone.children)
    }

    assert reg.existing_open_epic(
        milestone,
        [
            {
                "number": 9,
                "title": milestone.title,
                "state": "OPEN",
                "body": reg.render_epic_body(milestone, numbers),
                "labels": [{"name": reg.EPIC_LABEL}],
            }
        ],
        numbers,
    ) == 9

    for body, labels, message in (
        (identity, [{"name": reg.EPIC_LABEL}], "source drift"),
        (f"{identity}\n{current}", [], "missing"),
    ):
        try:
            reg.existing_open_epic(
                milestone,
                [
                    {
                        "number": 9,
                        "title": milestone.title,
                        "state": "OPEN",
                        "body": body,
                        "labels": labels,
                    }
                ],
                numbers,
            )
        except RuntimeError as exc:
            assert message in str(exc)
        else:  # pragma: no cover
            raise AssertionError("epic drift must stop reconciliation")


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

    m4 = next(m for m in milestones if m.id == "M4")
    gate = next(child for child in m4.children if child.manual)
    unsafe_gate = replace(gate, failure_effect="close_on_failure")
    unsafe_children = tuple(
        unsafe_gate if child.id == gate.id else child for child in m4.children
    )
    unsafe_plan = [
        replace(m4, children=unsafe_children) if m.id == "M4" else m
        for m in milestones
    ]
    assert any("failure_effect" in e for e in reg.validate(unsafe_plan))


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
        test_every_child_is_single_purpose_and_repo_valid,
        test_each_milestone_has_unblocked_requirements_child_first,
        test_dependency_edges_resolve_to_siblings_acyclically,
        test_epic_body_checklist_is_structurally_parseable,
        test_child_body_transports_authored_content_and_identifies_sources,
        test_m4_has_manual_dogfood_evidence_gate_after_rollout,
        test_m4_manual_gate_is_qualified_and_outside_parser_tasks,
        test_label_ensure_preserves_existing_metadata_and_propagates_failures,
        test_apply_plan_reuses_children_uses_title_and_holds_manual_gate,
        test_apply_plan_rejects_unsafe_manual_retry_before_any_write,
        test_apply_plan_rejects_unlabeled_gate_before_any_write,
        test_existing_epic_does_not_bypass_child_preflight,
        test_existing_epic_allows_canonical_child_lifecycle_progress,
        test_partial_retry_requires_initial_child_state_before_any_write,
        test_registered_child_lifecycle_matches_pinned_hephaestus_contract,
        test_child_reconciliation_fails_closed_on_ambiguous_identity,
        test_reconciliation_rejects_body_drift_with_current_markers,
        test_reconciliation_rejects_unmarked_same_title_alongside_marker,
        test_manual_gate_requires_dedicated_non_state_label,
        test_epic_reconciliation_requires_current_source_and_tracking_label,
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
