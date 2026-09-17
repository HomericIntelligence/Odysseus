#!/usr/bin/env python3
"""Behavior assertions for the M1-M6 epic registration payloads (issue #468).

Runs under pytest and also through ``just test-milestone-registry``, which
uses the plain-script entry point so the checks work without pytest.
"""

from __future__ import annotations

import importlib.util
import io
import json
import shutil
import subprocess
import sys
import tempfile
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import replace
from pathlib import Path

import yaml

_TOOL_PATH = (
    Path(__file__).resolve().parents[2]
    / "tools"
    / "github"
    / "register-milestone-epics.py"
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
TEST_SOURCE_SHA = "0" * 40


def _load_tool(path: Path, module_name: str):
    """Load one isolated registrar copy for artifact-level source tests."""
    spec = importlib.util.spec_from_file_location(module_name, path)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = module
    spec.loader.exec_module(module)
    return module


@contextmanager
def _isolated_tool_tree():
    """Provide an isolated registrar, payload, and workflow tree."""
    source_root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "repo"
        tool_path = root / "tools" / "github" / "register-milestone-epics.py"
        tool_path.parent.mkdir(parents=True)
        shutil.copy2(_TOOL_PATH, tool_path)
        shutil.copytree(PAYLOADS, tool_path.parent / "milestone-epics.d")
        shutil.copytree(source_root / "workflows", root / "workflows")
        yield _load_tool(tool_path, "register_milestone_epics_isolated"), root


def _read_yaml(path: Path):
    """Read a YAML test artifact."""
    return yaml.safe_load(path.read_text())


def _write_yaml(path: Path, value) -> None:
    """Write a YAML test artifact deterministically."""
    path.write_text(yaml.safe_dump(value, sort_keys=False))


def _commit_isolated_sources(root: Path) -> str:
    """Commit one isolated source tree and return its immutable Git SHA."""
    commands = (
        ("git", "init", "--quiet"),
        ("git", "add", "tools/github/milestone-epics.d", "workflows"),
        (
            "git",
            "-c",
            "user.name=Milestone Test",
            "-c",
            "user.email=milestone-test@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "source snapshot",
        ),
    )
    for command in commands:
        subprocess.run(command, cwd=root, check=True, capture_output=True, text=True)
    result = subprocess.run(
        ("git", "rev-parse", "HEAD"),
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    source_sha = result.stdout.strip()
    remote = root.parent / "origin.git"
    subprocess.run(
        ("git", "init", "--bare", "--quiet", str(remote)),
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ("git", "remote", "add", "origin", str(remote)),
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    subprocess.run(
        ("git", "push", "--quiet", "origin", f"{source_sha}:refs/heads/main"),
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return source_sha


def _advance_isolated_main(root: Path, relative_path: str, content: str) -> str:
    """Advance isolated main with one explicit file change and return its SHA."""
    path = root / relative_path
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)
    commands = (
        ("git", "add", relative_path),
        (
            "git",
            "-c",
            "user.name=Milestone Test",
            "-c",
            "user.email=milestone-test@example.invalid",
            "commit",
            "--quiet",
            "-m",
            "advance main",
        ),
    )
    for command in commands:
        subprocess.run(command, cwd=root, check=True, capture_output=True, text=True)
    result = subprocess.run(
        ("git", "rev-parse", "HEAD"),
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    source_sha = result.stdout.strip()
    subprocess.run(
        ("git", "push", "--quiet", "origin", f"{source_sha}:refs/heads/main"),
        cwd=root,
        check=True,
        capture_output=True,
        text=True,
    )
    return source_sha


def test_tool_symlink_invocation_is_rejected() -> None:
    """A linked tool path cannot splice routing and workflow source roots."""
    with tempfile.TemporaryDirectory() as temporary:
        link = Path(temporary) / "register-milestone-epics.py"
        link.symlink_to(_TOOL_PATH)

        try:
            _load_tool(link, "register_milestone_epics_symlink")
        except RuntimeError as exc:
            assert "direct regular file" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a symlinked tool invocation must be rejected")


def test_parent_symlink_uses_one_resolved_repository_root() -> None:
    """A linked parent cannot splice payload and workflow source roots."""
    source_root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory() as temporary:
        temporary_root = Path(temporary)
        real_root = temporary_root / "real" / "repo"
        real_tool = real_root / "tools" / "github" / _TOOL_PATH.name
        real_tool.parent.mkdir(parents=True)
        shutil.copy2(_TOOL_PATH, real_tool)
        shutil.copytree(PAYLOADS, real_tool.parent / "milestone-epics.d")
        shutil.copytree(source_root / "workflows", real_root / "workflows")

        fake_root = temporary_root / "fake" / "repo"
        fake_root.mkdir(parents=True)
        (fake_root / "tools").symlink_to(real_root / "tools", target_is_directory=True)
        (fake_root / "workflows").mkdir()
        (fake_root / "workflows" / "m1-hephaestus-keystone.yaml").write_text(
            "attacker-controlled: true\n"
        )

        linked_tool = fake_root / "tools" / "github" / _TOOL_PATH.name
        isolated = _load_tool(linked_tool, "register_milestone_epics_parent_link")
        assert isolated.REPO_ROOT == real_root.resolve()
        milestones = isolated.load_payloads()
        assert not isolated.validate(milestones)


def _assert_payload_source_rejected_before_remote_access(mode: str) -> None:
    """Prove that an external routing source cannot reach the remote boundary."""
    with _isolated_tool_tree() as (isolated, root):
        payload_dir = root / "tools" / "github" / "milestone-epics.d"
        if mode == "file":
            payload_path = payload_dir / "m1.yaml"
            escaped = root.parent / "escaped-m1.yaml"
            payload_path.rename(escaped)
            payload_path.symlink_to(escaped)
        elif mode == "directory":
            escaped = root.parent / "escaped-payloads"
            payload_dir.rename(escaped)
            payload_dir.symlink_to(escaped, target_is_directory=True)
        else:  # pragma: no cover
            raise AssertionError(f"unknown payload source mode: {mode}")

        calls = []
        original_gh = isolated.gh

        def fake_gh(*args):
            calls.append(args)
            return "[]"

        isolated.gh = fake_gh
        try:
            try:
                isolated.main(
                    [
                        "--apply",
                        "--source-sha",
                        TEST_SOURCE_SHA,
                        "--plan-digest",
                        "0" * 64,
                    ]
                )
            except ValueError as exc:
                assert "payload" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"{mode} payload symlink must be rejected")
        finally:
            isolated.gh = original_gh

        assert calls == [], "invalid payload source reached the GitHub boundary"


def _assert_plan_rejected_before_remote_access(milestones, message: str) -> None:
    """Prove that invalid planned issue identities stop before a remote read."""
    calls = []
    original_load_payloads = reg.load_payloads
    original_gh = reg.gh
    reg.load_payloads = lambda: milestones

    def fake_gh(*args):
        calls.append(args)
        return "[]"

    reg.gh = fake_gh
    stderr = io.StringIO()
    try:
        try:
            with redirect_stderr(stderr):
                status = reg.main(
                    [
                        "--apply",
                        "--source-sha",
                        TEST_SOURCE_SHA,
                        "--plan-digest",
                        "0" * 64,
                    ]
                )
        except (RuntimeError, ValueError):
            status = None
    finally:
        reg.load_payloads = original_load_payloads
        reg.gh = original_gh

    assert status == 2, "invalid issue identities must fail validation"
    assert message in stderr.getvalue()
    assert calls == [], "invalid issue identities reached the GitHub boundary"


def _assert_apply_source_rejected_before_remote_access(
    milestones, message: str
) -> None:
    """Prove that apply validates all source identities before remote access."""
    calls = []
    original_gh = reg.gh

    def fake_gh(*args):
        calls.append(args)
        return "[]"

    reg.gh = fake_gh
    try:
        try:
            reg.apply_plan(milestones, TEST_SOURCE_SHA, "0" * 64)
        except ValueError as exc:
            assert message in str(exc)
        else:  # pragma: no cover
            raise AssertionError("invalid source identities must stop apply")
    finally:
        reg.gh = original_gh

    assert calls == [], "invalid source identities reached the GitHub boundary"


def _assert_routing_type_rejected_before_remote_access(
    payload_name: str, mutate, field: str
) -> None:
    """Prove that one invalid authored type stops before a remote read."""
    with _isolated_tool_tree() as (isolated, root):
        payload_path = root / "tools" / "github" / "milestone-epics.d" / payload_name
        payload = _read_yaml(payload_path)
        mutate(payload)
        _write_yaml(payload_path, payload)

        calls = []
        original_gh = isolated.gh

        def fake_gh(*args):
            calls.append(args)
            return "[]"

        isolated.gh = fake_gh
        try:
            try:
                isolated.main(
                    [
                        "--apply",
                        "--source-sha",
                        TEST_SOURCE_SHA,
                        "--plan-digest",
                        "0" * 64,
                    ]
                )
            except ValueError as exc:
                assert field in str(exc)
                assert "must be" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"invalid {field} type must be rejected")
        finally:
            isolated.gh = original_gh

        assert calls == [], f"invalid {field} reached the GitHub boundary"


def _load():
    milestones = [
        replace(milestone, source_sha=TEST_SOURCE_SHA)
        for milestone in reg.load_payloads(PAYLOADS)
    ]
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


def _canonical_child_inventory(milestone, *, staged: bool = False):
    """Build one complete, canonical child inventory for apply-mode tests."""
    numbers = {
        child.id: number for number, child in enumerate(milestone.children, start=100)
    }
    issues_by_repo: dict[str, list[dict[str, object]]] = {}
    for child in milestone.children:
        labels = [
            {
                "name": (
                    EXPECTED_MANUAL_GATE_LABEL
                    if child.manual
                    else (
                        reg.REGISTRATION_STAGED_LABEL
                        if staged
                        else reg.NEEDS_PLAN_LABEL
                    )
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


def _planned_stage(milestones, fake_gh):
    """Return one exact read-only registration stage from public plan output."""
    original_gh = reg.gh
    reg.gh = fake_gh
    stdout = io.StringIO()
    try:
        with _accepted_source() as source_sha, redirect_stdout(stdout):
            assert reg.plan_mode(milestones, source_sha) == 0
    finally:
        reg.gh = original_gh
    lines = stdout.getvalue().splitlines()
    stage = next(
        line.removeprefix("STAGE ") for line in lines if line.startswith("STAGE ")
    )
    digest = next(
        line.removeprefix("PLAN_SHA256 ")
        for line in lines
        if line.startswith("PLAN_SHA256 ")
    )
    writes = [
        json.loads(line.removeprefix("WRITE "))
        for line in lines
        if line.startswith("WRITE ")
    ]
    return stage, digest, writes


def _write_payload_from_gh_call(call):
    """Project one GitHub mutation call onto its public write payload."""
    if call[:2] == ("issue", "create"):
        return {
            "operation": "issue.create",
            "target": call[call.index("-R") + 1],
            "title": call[call.index("--title") + 1],
            "label": call[call.index("--label") + 1],
            "body": call[call.index("--body") + 1],
        }
    if call[:2] == ("label", "create"):
        return {
            "operation": "label.create",
            "target": call[call.index("-R") + 1],
            "name": call[2],
            "description": call[call.index("--description") + 1],
            "color": call[call.index("--color") + 1],
        }
    if call[:2] == ("label", "delete"):
        return {
            "operation": "label.delete",
            "target": call[call.index("-R") + 1],
            "name": call[2],
        }
    if call[0] == "api" and call[1].endswith("/labels"):
        fields = {
            arg.split("=", 1)[0]: arg.split("=", 1)[1] for arg in call if "=" in arg
        }
        return {
            "operation": "label.create",
            "target": call[1].removeprefix("repos/").removesuffix("/labels"),
            "name": fields["name"],
            "description": fields["description"],
            "color": fields["color"],
        }
    if call[:2] == ("api", "graphql"):
        return {
            "operation": "label.delete",
            "target": f"{reg.ORG}/Odysseus",
            "name": reg.REGISTRATION_LOCK_LABEL,
        }
    if call[:2] == ("issue", "edit"):
        return {
            "operation": "issue.edit",
            "target": call[call.index("-R") + 1],
            "number": int(call[2]),
            "add_label": call[call.index("--add-label") + 1],
            "remove_label": call[call.index("--remove-label") + 1],
        }
    raise AssertionError(f"not a supported mutation call: {call}")


def _mutation_payloads(calls):
    """Project ordered GitHub mutation calls onto reviewed payloads."""
    operations = {
        ("issue", "create"),
        ("issue", "edit"),
        ("label", "create"),
        ("label", "delete"),
        ("api", "graphql"),
    }
    return [
        _write_payload_from_gh_call(call)
        for call in calls
        if call[:2] in operations or (call[0] == "api" and call[1].endswith("/labels"))
    ]


def _is_lock_create_call(call) -> bool:
    """Return true for the reviewed lock-acquisition boundary."""
    return call[:3] == ("label", "create", reg.REGISTRATION_LOCK_LABEL) or (
        call[0] == "api" and call[1].endswith("/labels")
    )


def _is_lock_delete_call(call) -> bool:
    """Return true for a name-based or immutable-ID lock release."""
    return call[:3] == (
        "label",
        "delete",
        reg.REGISTRATION_LOCK_LABEL,
    ) or call[:2] == ("api", "graphql")


def _assert_planned_mutations_applied(calls, planned) -> None:
    """Compare applied writes after accounting for the fresh lock owner token."""
    applied = _mutation_payloads(calls)
    assert len(applied) == len(planned)
    assert applied[0]["operation"] == "label.create"
    assert applied[0]["name"] == reg.REGISTRATION_LOCK_LABEL
    owner_description = applied[0]["description"]
    owner_prefix = (
        reg.REGISTRATION_LOCK_LABEL_DESCRIPTION + reg.REGISTRATION_LOCK_OWNER_SEPARATOR
    )
    assert owner_description.startswith(owner_prefix)
    assert len(owner_description.removeprefix(owner_prefix)) == 32
    expected = [dict(write) for write in planned]
    expected[0]["description"] = owner_description
    assert applied == expected


def _fake_github(*, issues_by_repo=None, labels_by_repo=None, issue_numbers=()):
    """Return one controlled GitHub boundary and its call ledger."""
    issues_by_repo = issues_by_repo or {}
    labels_by_repo = {
        repo: {
            name: {
                "id": f"label-{repo}-{name}",
                "description": "",
            }
            for name in names
        }
        for repo, names in (labels_by_repo or {}).items()
    }
    numbers = iter(issue_numbers)
    calls = []
    created_label_count = 0

    def fake_gh(*args):
        nonlocal created_label_count
        calls.append(args)
        target = args[args.index("-R") + 1] if "-R" in args else ""
        repo = target.split("/", 1)[-1]
        if args[:2] == ("issue", "list"):
            return json.dumps(issues_by_repo.get(repo, []))
        if args[:2] == ("label", "list"):
            return json.dumps(
                [
                    {
                        "id": metadata["id"],
                        "name": name,
                        "description": metadata["description"],
                    }
                    for name, metadata in sorted(labels_by_repo.get(repo, {}).items())
                ]
            )
        if args[:2] == ("label", "create"):
            created_label_count += 1
            labels_by_repo.setdefault(repo, {})[args[2]] = {
                "id": f"created-label-{created_label_count}",
                "description": args[args.index("--description") + 1],
            }
            return ""
        if args[:2] == ("label", "delete"):
            labels_by_repo.setdefault(repo, {}).pop(args[2], None)
            return ""
        if args[0] == "api" and args[1].endswith("/labels"):
            created_label_count += 1
            api_target = args[1].removeprefix("repos/").removesuffix("/labels")
            api_repo = api_target.split("/", 1)[-1]
            fields = {
                arg.split("=", 1)[0]: arg.split("=", 1)[1] for arg in args if "=" in arg
            }
            node_id = f"created-label-{created_label_count}"
            labels_by_repo.setdefault(api_repo, {})[fields["name"]] = {
                "id": node_id,
                "description": fields["description"],
            }
            return node_id
        if args[:2] == ("api", "graphql"):
            label_id = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("labelId=")
            )
            odysseus = labels_by_repo.setdefault("Odysseus", {})
            matching_name = next(
                (
                    name
                    for name, metadata in odysseus.items()
                    if metadata["id"] == label_id
                ),
                None,
            )
            if matching_name is None:
                raise RuntimeError("the owned label node no longer exists")
            del odysseus[matching_name]
            return ""
        if args[:2] == ("issue", "create"):
            number = next(numbers)
            return f"https://github.com/{target}/issues/{number}"
        if args[:2] == ("issue", "edit"):
            return ""
        raise AssertionError(f"unexpected GitHub call: {args}")

    return fake_gh, calls


def _required_labels(milestones):
    """Return the complete current label inventory for selected milestones."""
    repos = {milestone.epic_home for milestone in milestones}
    repos.update(child.repo for milestone in milestones for child in milestone.children)
    labels = {repo: {reg.EPIC_LABEL, reg.NEEDS_PLAN_LABEL} for repo in repos}
    dispatch_repos = {
        child.repo
        for milestone in milestones
        for child in milestone.children
        if not child.manual
    }
    for repo in dispatch_repos:
        labels[repo].add(reg.REGISTRATION_STAGED_LABEL)
    for milestone in milestones:
        for child in milestone.children:
            if child.manual:
                labels[child.repo].add(reg.OPERATOR_GATE_LABEL)
    return labels


@contextmanager
def _accepted_source(module=reg):
    """Replace Git source verification for tests of later GitHub boundaries."""
    original = module.verify_source_snapshot
    calls = []

    def accept(milestones, source_sha):
        calls.append((milestones, source_sha))
        assert source_sha == TEST_SOURCE_SHA
        return source_sha

    module.verify_source_snapshot = accept
    try:
        yield TEST_SOURCE_SHA
    finally:
        module.verify_source_snapshot = original
    assert len(calls) == 1, "apply must verify its source exactly once"


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
            with _accepted_source() as source_sha:
                reg.apply_plan([milestone], source_sha, "0" * 64)
        except RuntimeError as exc:
            assert message in str(exc)
        else:  # pragma: no cover
            raise AssertionError("unsafe reusable issue must stop apply")
    finally:
        reg.gh = original_gh

    assert _mutation_payloads(calls) == []


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
        checklist = [line for line in body.splitlines() if line.startswith("- [ ] ")]
        dispatchable = [child for child in m.children if not child.manual]
        assert len(checklist) == len(dispatchable)
        for line in checklist:
            assert reg.CHECKLIST_LINE_RE.match(line), f"bad checklist grammar: {line}"
        assert f"Odysseus@{TEST_SOURCE_SHA}:{m.workflow}" in body


def test_epic_body_resolves_every_child_to_its_own_repository() -> None:
    """Checklist and dependency references never reuse a foreign issue number."""
    saw_local_shorthand = False
    saw_foreign_identity = False
    for milestone in _load():
        numbers = {
            child.id: index + 100 for index, child in enumerate(milestone.children)
        }
        lines = reg.render_epic_body(milestone, numbers).splitlines()
        for child in (
            candidate for candidate in milestone.children if not candidate.manual
        ):
            issue_ref = (
                f"#{numbers[child.id]}"
                if child.repo == milestone.epic_home
                else f"{reg.ORG}/{child.repo}#{numbers[child.id]}"
            )
            saw_local_shorthand |= child.repo == milestone.epic_home
            saw_foreign_identity |= child.repo != milestone.epic_home
            row = next(line for line in lines if line.startswith(f"- [ ] {issue_ref}"))
            expected_dependencies = [
                (
                    f"#{numbers[dependency.id]}"
                    if dependency.repo == milestone.epic_home
                    else f"{reg.ORG}/{dependency.repo}#{numbers[dependency.id]}"
                )
                for dependency in milestone.deps(child.id)
            ]
            if expected_dependencies:
                assert row.endswith(
                    f" (depends on: {', '.join(expected_dependencies)})"
                )
            else:
                assert row == f"- [ ] {issue_ref}"
    assert saw_local_shorthand
    assert saw_foreign_identity


def test_child_body_transports_authored_content_and_identifies_sources() -> None:
    milestones = _load()
    m1 = next(m for m in milestones if m.id == "M1")
    req = m1.children[0]
    probe = replace(req, description="opaque-authored-payload-7d41")
    body = reg.render_child_body(m1, probe)
    assert "opaque-authored-payload-7d41" in body
    assert f"Odysseus@{TEST_SOURCE_SHA}:{m1.payload_path}" in body
    assert f"Odysseus@{TEST_SOURCE_SHA}:{m1.workflow}" in body
    assert "HomericIntelligence/Odysseus#464" in body
    assert "<!-- HomericIntelligence:milestone-task id=M1.1 -->" in body
    # Cross-repository children land in their owning repository.
    m3 = next(m for m in milestones if m.id == "M3")
    repos = {c.repo for c in m3.children}
    assert {"Myrmidons", "AchaeanFleet", "Agamemnon", "Odysseus"} <= repos


def test_rendered_bodies_cite_one_immutable_source_commit() -> None:
    """Persisted child and epic bodies link each source at the bound commit."""
    milestone = replace(_load()[0], source_sha=TEST_SOURCE_SHA)
    numbers = {
        child.id: number for number, child in enumerate(milestone.children, start=100)
    }
    child_body = reg.render_child_body(milestone, milestone.children[0], numbers)
    epic_body = reg.render_epic_body(milestone, numbers)

    for body in (child_body, epic_body):
        for path in (milestone.payload_path, milestone.workflow):
            citation = (
                f"https://github.com/{reg.ORG}/Odysseus/blob/{TEST_SOURCE_SHA}/{path}"
            )
            assert citation in body
        assert f"Odysseus@{TEST_SOURCE_SHA}" in body


def test_dispatchable_child_description_comes_from_workflow_manifest() -> None:
    """A workflow description change must change generated issue content."""
    with _isolated_tool_tree() as (isolated, root):
        workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
        workflow = yaml.safe_load(workflow_path.read_text())
        expected = "Canonical workflow description sentinel 8e68b9."
        workflow["teams"][0]["tasks"][0]["description"] = expected
        workflow_path.write_text(yaml.safe_dump(workflow, sort_keys=False))

        milestone = replace(isolated.load_payloads()[0], source_sha=TEST_SOURCE_SHA)
        child = milestone.children[0]
        assert child.description == expected
        assert expected in isolated.render_child_body(milestone, child)


def test_workflow_task_source_must_match_once() -> None:
    """Missing and ambiguous workflow task sources must fail closed."""
    for mode in ("missing", "ambiguous"):
        with _isolated_tool_tree() as (isolated, root):
            workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
            workflow = yaml.safe_load(workflow_path.read_text())
            first = workflow["teams"][0]["tasks"][0]
            if mode == "missing":
                first["subject"] = "Different workflow task"
            else:
                workflow["teams"][0]["tasks"].append(dict(first))
            workflow_path.write_text(yaml.safe_dump(workflow, sort_keys=False))

            try:
                isolated.load_payloads()
            except ValueError as exc:
                assert "M1.1" in str(exc)
                assert "exactly one workflow task" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"{mode} workflow source must be rejected")


def test_manual_gate_requires_workflow_metadata_source() -> None:
    """A manual gate must have its authored workflow metadata fields."""
    with _isolated_tool_tree() as (isolated, root):
        workflow_path = root / "workflows" / "m4-full-pipeline-dogfood.yaml"
        workflow = yaml.safe_load(workflow_path.read_text())
        workflow["metadata"].pop("manual_gate_description", None)
        workflow_path.write_text(yaml.safe_dump(workflow, sort_keys=False))

        try:
            isolated.load_payloads()
        except ValueError as exc:
            assert "M4.8" in str(exc)
            assert "manual_gate_description" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("missing manual workflow metadata must be rejected")


def test_routing_payload_cannot_duplicate_workflow_description() -> None:
    """Routing metadata must not become a second task-content source."""
    with _isolated_tool_tree() as (isolated, root):
        payload_path = root / "tools" / "github" / "milestone-epics.d" / "m1.yaml"
        payload = yaml.safe_load(payload_path.read_text())
        payload["children"][0]["description"] = "Conflicting routing prose."
        payload_path.write_text(yaml.safe_dump(payload, sort_keys=False))

        try:
            isolated.load_payloads()
        except ValueError as exc:
            assert "M1.1" in str(exc)
            assert "workflow only" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("duplicate routing prose must be rejected")


def test_workflow_reference_stays_in_direct_regular_file_boundary() -> None:
    """Absolute, traversing, nested, and symlink sources must fail closed."""
    for mode in (
        "absolute",
        "traversal",
        "nested",
        "file_symlink",
        "directory_symlink",
    ):
        with _isolated_tool_tree() as (isolated, root):
            payload_path = root / "tools" / "github" / "milestone-epics.d" / "m1.yaml"
            payload = _read_yaml(payload_path)
            workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
            if mode == "absolute":
                payload["workflow"] = str(workflow_path)
            elif mode == "traversal":
                payload["workflow"] = (
                    "workflows/../workflows/m1-hephaestus-keystone.yaml"
                )
            elif mode == "nested":
                nested = root / "workflows" / "nested"
                nested.mkdir()
                shutil.copy2(workflow_path, nested / workflow_path.name)
                payload["workflow"] = f"workflows/nested/{workflow_path.name}"
            elif mode == "file_symlink":
                escaped = root.parent / "escaped-m1.yaml"
                shutil.copy2(workflow_path, escaped)
                link = root / "workflows" / "m1-link.yaml"
                link.symlink_to(escaped)
                payload["workflow"] = "workflows/m1-link.yaml"
            else:
                escaped = root.parent / "escaped-workflows"
                (root / "workflows").rename(escaped)
                (root / "workflows").symlink_to(escaped, target_is_directory=True)
            _write_yaml(payload_path, payload)

            try:
                isolated.load_payloads()
            except ValueError as exc:
                assert "workflow reference" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"{mode} workflow reference must be rejected")


def test_payload_file_symlink_stops_before_remote_access() -> None:
    """A routing payload must be a regular file in the payload directory."""
    _assert_payload_source_rejected_before_remote_access("file")


def test_payload_directory_symlink_stops_before_remote_access() -> None:
    """The routing payload directory must not resolve through a symlink."""
    _assert_payload_source_rejected_before_remote_access("directory")


def test_payload_filename_must_match_milestone_identity() -> None:
    """A renamed or swapped payload cannot make renderers cite a false path."""
    for mode in ("rename", "swap"):
        with _isolated_tool_tree() as (isolated, root):
            payload_dir = root / "tools" / "github" / "milestone-epics.d"
            m1 = payload_dir / "m1.yaml"
            if mode == "rename":
                m1.rename(payload_dir / "route.yaml")
            else:
                m2 = payload_dir / "m2.yaml"
                temporary = payload_dir / "temporary.yaml"
                m1.rename(temporary)
                m2.rename(m1)
                temporary.rename(m2)

            try:
                isolated.load_payloads()
            except ValueError as exc:
                assert "filename" in str(exc)
                assert "milestone" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"a {mode}d payload must be rejected")


def test_top_level_routing_fields_require_exact_string_types() -> None:
    """The loader must reject coercible non-string milestone fields."""
    cases = (
        ("title", lambda payload: payload.__setitem__("title", ["M1 title"])),
        ("milestone", lambda payload: payload.__setitem__("milestone", 1)),
        (
            "epic_home",
            lambda payload: payload.__setitem__("epic_home", ["Hephaestus"]),
        ),
        (
            "home_rationale",
            lambda payload: payload.__setitem__("home_rationale", {"text": "x"}),
        ),
        (
            "ordering_note",
            lambda payload: payload.__setitem__("ordering_note", 42),
        ),
    )
    for field, mutate in cases:
        _assert_routing_type_rejected_before_remote_access("m1.yaml", mutate, field)


def test_child_routing_fields_require_exact_authored_types() -> None:
    """The loader must not coerce child identity and policy fields."""
    cases = (
        (
            "children[7].id",
            lambda payload: payload["children"][7].__setitem__("id", 108),
        ),
        (
            "children[7].repo",
            lambda payload: payload["children"][7].__setitem__("repo", ["Hephaestus"]),
        ),
        (
            "children[7].requires_verified",
            lambda payload: payload["children"][7].__setitem__("requires_verified", {}),
        ),
        (
            "children[7].completion_condition",
            lambda payload: payload["children"][7].__setitem__(
                "completion_condition", 7
            ),
        ),
        (
            "children[7].failure_effect",
            lambda payload: payload["children"][7].__setitem__(
                "failure_effect", ["keep_open"]
            ),
        ),
    )
    for field, mutate in cases:
        _assert_routing_type_rejected_before_remote_access("m1.yaml", mutate, field)


def test_manual_requires_an_exact_yaml_boolean() -> None:
    """False-like and true-like non-Boolean values must not select task mode."""
    cases = (
        (
            "m1.yaml",
            lambda payload: payload["children"][0].__setitem__("manual", 0),
        ),
        (
            "m1.yaml",
            lambda payload: payload["children"][0].__setitem__("manual", []),
        ),
        (
            "m4.yaml",
            lambda payload: payload["children"][7].__setitem__("manual", "false"),
        ),
        (
            "m4.yaml",
            lambda payload: payload["children"][7].__setitem__("manual", 1),
        ),
    )
    for payload_name, mutate in cases:
        _assert_routing_type_rejected_before_remote_access(
            payload_name, mutate, "manual"
        )


def test_workflow_loading_requires_no_follow_and_dir_fd_capabilities() -> None:
    """A host without either safe path capability must fail closed."""
    for mode in ("no_follow", "dir_fd"):
        with _isolated_tool_tree() as (isolated, root):
            if mode == "no_follow":
                saved = isolated.os.O_NOFOLLOW
                del isolated.os.O_NOFOLLOW
            else:
                saved = isolated.os.supports_dir_fd
                isolated.os.supports_dir_fd = frozenset(
                    function for function in saved if function is not isolated.os.open
                )
            try:
                try:
                    isolated._read_workflow_source(
                        "workflows/m1-hephaestus-keystone.yaml",
                        root / "tools" / "github" / "milestone-epics.d" / "m1.yaml",
                    )
                except ValueError as exc:
                    assert "safe workflow path capabilities" in str(exc)
                else:  # pragma: no cover
                    raise AssertionError(f"missing {mode} capability must stop")
            finally:
                if mode == "no_follow":
                    isolated.os.O_NOFOLLOW = saved
                else:
                    isolated.os.supports_dir_fd = saved


def test_workflow_contract_requires_version_and_epic_home_parity() -> None:
    """The registrar must bind the exact workflow version and epic owner."""
    for mode in ("apiVersion", "epic_home"):
        with _isolated_tool_tree() as (isolated, root):
            workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
            workflow = _read_yaml(workflow_path)
            if mode == "apiVersion":
                workflow["apiVersion"] = "telemachy/v2"
            else:
                workflow["metadata"]["epic_home"] = "Odysseus"
            _write_yaml(workflow_path, workflow)

            try:
                isolated.load_payloads()
            except ValueError as exc:
                assert mode in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"workflow {mode} drift must be rejected")


def test_workflow_and_routing_dependencies_must_match_exactly() -> None:
    """Missing, extra, unknown, reordered, and payload-only edges must stop."""
    for mode in ("missing", "extra", "unknown", "reordered", "payload"):
        with _isolated_tool_tree() as (isolated, root):
            payload_path = root / "tools" / "github" / "milestone-epics.d" / "m1.yaml"
            workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
            payload = _read_yaml(payload_path)
            workflow = _read_yaml(workflow_path)
            tasks = workflow["teams"][0]["tasks"]
            if mode == "missing":
                tasks[1]["blocked_by"] = []
            elif mode == "extra":
                tasks[1]["blocked_by"].append(tasks[2]["subject"])
            elif mode == "unknown":
                tasks[1]["blocked_by"] = ["Unknown workflow dependency"]
            elif mode == "reordered":
                tasks[-1]["blocked_by"].reverse()
            else:
                payload["children"][1]["blocked_by"] = []
            _write_yaml(payload_path, payload)
            _write_yaml(workflow_path, workflow)

            try:
                isolated.load_payloads()
            except ValueError as exc:
                assert "dependency parity" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"{mode} dependency drift must be rejected")


def test_dispatchable_workflow_and_routing_tasks_are_bijective() -> None:
    """Neither source may contain an unpaired dispatchable task."""
    for mode in ("extra_workflow", "duplicate_route"):
        with _isolated_tool_tree() as (isolated, root):
            payload_path = root / "tools" / "github" / "milestone-epics.d" / "m1.yaml"
            workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
            payload = _read_yaml(payload_path)
            workflow = _read_yaml(workflow_path)
            if mode == "extra_workflow":
                extra = dict(workflow["teams"][0]["tasks"][-1])
                extra["subject"] = "Unrouted workflow task"
                extra["blocked_by"] = []
                workflow["teams"][0]["tasks"].append(extra)
            else:
                payload["children"][1]["subject"] = payload["children"][0]["subject"]
                payload["children"][1]["blocked_by"] = []
            _write_yaml(payload_path, payload)
            _write_yaml(workflow_path, workflow)

            try:
                isolated.load_payloads()
            except ValueError as exc:
                assert "one-to-one" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"{mode} task mapping must be rejected")


def test_validate_detects_dependency_cycle_from_source_mutation() -> None:
    """A source mutation that forms a cycle must reach a production error."""
    with _isolated_tool_tree() as (isolated, root):
        payload_path = root / "tools" / "github" / "milestone-epics.d" / "m1.yaml"
        workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
        payload = _read_yaml(payload_path)
        workflow = _read_yaml(workflow_path)
        payload["children"][0]["blocked_by"] = ["M1.2"]
        workflow["teams"][0]["tasks"][0]["blocked_by"] = [
            workflow["teams"][0]["tasks"][1]["subject"]
        ]
        _write_yaml(payload_path, payload)
        _write_yaml(workflow_path, workflow)

        errors = isolated.validate(isolated.load_payloads())
        assert any("dependency cycle" in error for error in errors)


def test_cross_milestone_child_title_collision_stops_before_remote_access() -> None:
    """Two planned children cannot use the same title in one repository."""
    milestones = _load()
    first = milestones[0].children[0]
    second_milestone = milestones[1]
    second = second_milestone.children[-1]
    changed_children = tuple(
        replace(child, repo=first.repo, subject=first.subject)
        if child.id == second.id
        else child
        for child in second_milestone.children
    )
    changed_plan = [
        replace(milestone, children=changed_children)
        if milestone.id == second_milestone.id
        else milestone
        for milestone in milestones
    ]

    _assert_plan_rejected_before_remote_access(changed_plan, "duplicate issue title")


def test_child_and_epic_title_collision_stops_before_remote_access() -> None:
    """A planned child cannot use an epic title in the same repository."""
    milestones = _load()
    epic = milestones[1]
    child_milestone = milestones[0]
    child = child_milestone.children[-1]
    changed_children = tuple(
        replace(candidate, repo=epic.epic_home, subject=epic.title)
        if candidate.id == child.id
        else candidate
        for candidate in child_milestone.children
    )
    changed_plan = [
        replace(milestone, children=changed_children)
        if milestone.id == child_milestone.id
        else milestone
        for milestone in milestones
    ]

    _assert_plan_rejected_before_remote_access(changed_plan, "duplicate issue title")


def test_epic_title_shape_stops_apply_before_remote_access() -> None:
    """An epic title must contain one non-empty line."""
    milestone = _load()[0]
    for invalid_title in ("", "   ", "M1 title\nsecond line"):
        _assert_apply_source_rejected_before_remote_access(
            [replace(milestone, title=invalid_title)], "epic title"
        )


def test_child_id_shape_stops_apply_before_remote_access() -> None:
    """A child ID must use its milestone prefix and a positive integer."""
    milestone = _load()[0]
    child = milestone.children[-1]
    for invalid_id in ("", "M1", "M1.", "M1.0", "M1.01", "M2.8", "task-8"):
        changed_children = tuple(
            replace(candidate, id=invalid_id) if candidate.id == child.id else candidate
            for candidate in milestone.children
        )
        _assert_apply_source_rejected_before_remote_access(
            [replace(milestone, children=changed_children)], "child id"
        )


def test_apply_preflights_late_milestone_before_any_remote_access() -> None:
    """A late invalid milestone must stop before an earlier milestone writes."""
    milestones = _load()[:2]
    late = milestones[1]
    late_child = late.children[-1]
    changed_children = tuple(
        replace(child, id="late-invalid") if child.id == late_child.id else child
        for child in late.children
    )
    changed_plan = [milestones[0], replace(late, children=changed_children)]

    _assert_apply_source_rejected_before_remote_access(changed_plan, "child id")


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


def test_label_stage_plan_and_apply_payloads_are_exact() -> None:
    """The first stage displays every missing label write before apply."""
    m4 = next(m for m in _load() if m.id == "M4")
    plan_gh, plan_calls = _fake_github()
    stage, digest, planned = _planned_stage([m4], plan_gh)

    assert stage == "labels"
    assert len(planned) == 18
    assert planned[0]["name"] == reg.REGISTRATION_LOCK_LABEL
    assert planned[-1] == {
        "operation": "label.delete",
        "target": f"{reg.ORG}/Odysseus",
        "name": reg.REGISTRATION_LOCK_LABEL,
    }
    label_creates = [write for write in planned if write["operation"] == "label.create"]
    assert len(label_creates) == 17
    assert all(
        set(write) == {"operation", "target", "name", "description", "color"}
        for write in label_creates
    )
    assert not any(_is_lock_create_call(call) for call in plan_calls)

    apply_gh, apply_calls = _fake_github()
    original_gh = reg.gh
    reg.gh = apply_gh
    try:
        with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
            assert reg.apply_plan([m4], source_sha, digest) == 0
    finally:
        reg.gh = original_gh
    _assert_planned_mutations_applied(apply_calls, planned)
    assert not any(call[:2] == ("issue", "create") for call in apply_calls)


def test_child_stage_plan_and_apply_payloads_are_exact() -> None:
    """A child stage applies only the full issue payloads that plan displays."""
    m4 = next(m for m in _load() if m.id == "M4")
    labels = _required_labels([m4])
    plan_gh, plan_calls = _fake_github(labels_by_repo=labels)
    stage, digest, planned = _planned_stage([m4], plan_gh)

    assert stage == "children"
    issue_creates = [write for write in planned if write["operation"] == "issue.create"]
    assert len(issue_creates) == len(
        [child for child in m4.children if not child.manual]
    )
    assert all(
        set(write) == {"operation", "target", "title", "label", "body"}
        for write in issue_creates
    )
    assert {write["label"] for write in issue_creates} == {
        reg.REGISTRATION_STAGED_LABEL
    }
    assert not any(write["label"].startswith("state:") for write in issue_creates)
    webhook = next(
        write
        for write in issue_creates
        if write["title"]
        == "Hermes merged-PR webhook bridge publishing the learn trigger"
    )
    assert webhook["target"] == f"{reg.ORG}/Hermes"
    assert webhook["label"] == reg.REGISTRATION_STAGED_LABEL
    assert webhook["label"] != reg.NEEDS_PLAN_LABEL
    assert f"Odysseus@{TEST_SOURCE_SHA}" in webhook["body"]
    assert not any(call[:2][1:] == ("create",) for call in plan_calls)

    apply_gh, apply_calls = _fake_github(
        labels_by_repo=labels,
        issue_numbers=range(200, 200 + len(issue_creates)),
    )
    original_gh = reg.gh
    reg.gh = apply_gh
    try:
        with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
            assert reg.apply_plan([m4], source_sha, digest) == 0
    finally:
        reg.gh = original_gh
    applied = [
        _write_payload_from_gh_call(call)
        for call in apply_calls
        if call[:2] == ("issue", "create")
    ]
    assert applied == issue_creates
    _assert_planned_mutations_applied(apply_calls, planned)
    assert all(write["title"] != m4.title for write in applied)


def test_real_issue_ids_stage_gate_then_epic_payloads_exactly() -> None:
    """Later stages use reconciled issue IDs and require a new reviewed plan."""
    m4 = next(m for m in _load() if m.id == "M4")
    labels = _required_labels([m4])
    complete_inventory, numbers = _canonical_child_inventory(m4, staged=True)
    gate = next(child for child in m4.children if child.manual)
    dispatch_inventory = {
        repo: [entry for entry in entries if entry["title"] != gate.subject]
        for repo, entries in complete_inventory.items()
    }

    gate_plan_gh, _ = _fake_github(
        issues_by_repo=dispatch_inventory, labels_by_repo=labels
    )
    stage, gate_digest, gate_planned = _planned_stage([m4], gate_plan_gh)
    assert stage == "operator-gates"
    gate_issue_writes = [
        write for write in gate_planned if write["operation"] == "issue.create"
    ]
    assert len(gate_issue_writes) == 1
    assert gate_issue_writes[0]["label"] == reg.OPERATOR_GATE_LABEL
    assert not gate_issue_writes[0]["label"].startswith("state:")
    assert all(
        f"#{numbers[child_id]}" in gate_issue_writes[0]["body"]
        for child_id in gate.requires_verified
    )

    gate_apply_gh, gate_apply_calls = _fake_github(
        issues_by_repo=dispatch_inventory,
        labels_by_repo=labels,
        issue_numbers=(numbers[gate.id],),
    )
    original_gh = reg.gh
    reg.gh = gate_apply_gh
    try:
        with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
            assert reg.apply_plan([m4], source_sha, gate_digest) == 0
    finally:
        reg.gh = original_gh
    assert [
        _write_payload_from_gh_call(call)
        for call in gate_apply_calls
        if call[:2] == ("issue", "create")
    ] == gate_issue_writes
    _assert_planned_mutations_applied(gate_apply_calls, gate_planned)

    epic_plan_gh, _ = _fake_github(
        issues_by_repo=complete_inventory, labels_by_repo=labels
    )
    stage, epic_digest, epic_planned = _planned_stage([m4], epic_plan_gh)
    assert stage == "epics"
    epic_issue_writes = [
        write for write in epic_planned if write["operation"] == "issue.create"
    ]
    assert len(epic_issue_writes) == 1
    assert epic_issue_writes[0]["title"] == m4.title
    assert all(
        f"#{number}" in epic_issue_writes[0]["body"] for number in numbers.values()
    )

    epic_apply_gh, epic_apply_calls = _fake_github(
        issues_by_repo=complete_inventory,
        labels_by_repo=labels,
        issue_numbers=(900,),
    )
    reg.gh = epic_apply_gh
    try:
        with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
            assert reg.apply_plan([m4], source_sha, epic_digest) == 0
    finally:
        reg.gh = original_gh
    assert [
        _write_payload_from_gh_call(call)
        for call in epic_apply_calls
        if call[:2] == ("issue", "create")
    ] == epic_issue_writes
    _assert_planned_mutations_applied(epic_apply_calls, epic_planned)

    registered_inventory = {
        repo: [dict(entry) for entry in entries]
        for repo, entries in complete_inventory.items()
    }
    registered_inventory.setdefault(m4.epic_home, []).append(
        {
            "number": 900,
            "title": m4.title,
            "state": "OPEN",
            "body": reg.render_epic_body(m4, numbers),
            "labels": [{"name": reg.EPIC_LABEL}],
        }
    )
    activation_plan_gh, activation_plan_calls = _fake_github(
        issues_by_repo=registered_inventory, labels_by_repo=labels
    )
    stage, activation_digest, activation_planned = _planned_stage(
        [m4], activation_plan_gh
    )
    assert stage == "activation"
    activation_edits = [
        write for write in activation_planned if write["operation"] == "issue.edit"
    ]
    assert len(activation_edits) == len(
        [child for child in m4.children if not child.manual]
    )
    assert all(
        write
        == {
            "operation": "issue.edit",
            "target": write["target"],
            "number": write["number"],
            "add_label": reg.NEEDS_PLAN_LABEL,
            "remove_label": reg.REGISTRATION_STAGED_LABEL,
        }
        for write in activation_edits
    )
    assert not any(call[:2] == ("issue", "edit") for call in activation_plan_calls)

    rejected_gh, rejected_calls = _fake_github(
        issues_by_repo=registered_inventory, labels_by_repo=labels
    )
    reg.gh = rejected_gh
    try:
        try:
            with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
                reg.apply_plan([m4], source_sha, "f" * 64)
        except ValueError as exc:
            assert "plan digest" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("unreviewed activation must be rejected")
    finally:
        reg.gh = original_gh
    assert not any(call[:2] == ("issue", "edit") for call in rejected_calls)

    activation_apply_gh, activation_apply_calls = _fake_github(
        issues_by_repo=registered_inventory, labels_by_repo=labels
    )
    reg.gh = activation_apply_gh
    try:
        with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
            assert reg.apply_plan([m4], source_sha, activation_digest) == 0
    finally:
        reg.gh = original_gh
    assert [
        _write_payload_from_gh_call(call)
        for call in activation_apply_calls
        if call[:2] == ("issue", "edit")
    ] == activation_edits
    _assert_planned_mutations_applied(activation_apply_calls, activation_planned)


def test_partial_child_apply_failure_leaves_no_active_issue() -> None:
    """A failed child stage can leave only explicitly non-dispatching issues."""
    m4 = next(m for m in _load() if m.id == "M4")
    labels = _required_labels([m4])
    plan_gh, _ = _fake_github(labels_by_repo=labels)
    stage, digest, _ = _planned_stage([m4], plan_gh)
    assert stage == "children"

    calls = []
    create_count = 0
    lock_description = None

    def failing_gh(*args):
        nonlocal create_count, lock_description
        calls.append(args)
        target = args[args.index("-R") + 1] if "-R" in args else ""
        repo = target.split("/", 1)[-1]
        if args[:2] == ("issue", "list"):
            return "[]"
        if args[:2] == ("label", "list"):
            entries = [
                {"id": f"label-{name}", "name": name, "description": ""}
                for name in sorted(labels.get(repo, set()))
            ]
            if repo == "Odysseus" and lock_description is not None:
                entries.append(
                    {
                        "id": "registration-lock-a",
                        "name": reg.REGISTRATION_LOCK_LABEL,
                        "description": lock_description,
                    }
                )
            return json.dumps(entries)
        if args[:2] == ("label", "create"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            lock_description = args[args.index("--description") + 1]
            return ""
        if args[0] == "api" and args[1].endswith("/labels"):
            lock_description = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("description=")
            )
            return "registration-lock-a"
        if args[:2] == ("label", "delete"):
            lock_description = None
            return ""
        if args[:2] == ("issue", "create"):
            create_count += 1
            if create_count == 2:
                raise RuntimeError("simulated partial child-stage failure")
            return f"https://github.com/{target}/issues/700"
        raise AssertionError(f"unexpected GitHub call: {args}")

    original_gh = reg.gh
    reg.gh = failing_gh
    try:
        try:
            with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
                reg.apply_plan([m4], source_sha, digest)
        except RuntimeError as exc:
            assert "simulated partial" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("the injected partial failure must propagate")
    finally:
        reg.gh = original_gh

    issue_writes = [call for call in calls if call[:2] == ("issue", "create")]
    assert len(issue_writes) == 2
    assert all(
        call[call.index("--label") + 1] == reg.REGISTRATION_STAGED_LABEL
        for call in issue_writes
    )
    assert lock_description is not None, (
        "an ambiguous partial write must retain the remote lock"
    )
    assert not any(_is_lock_delete_call(call) for call in calls)
    assert not any(call[:2] == ("issue", "edit") for call in calls)


def test_stale_interleaved_apply_cannot_duplicate_child_issue() -> None:
    """A remote CAS and guarded reread reject a plan raced by another apply."""
    m4 = next(m for m in _load() if m.id == "M4")
    labels = _required_labels([m4])
    state = {"lock_description": None, "raced": False}
    calls = []
    first = next(child for child in m4.children if not child.manual)

    def interleaved_gh(*args):
        calls.append(args)
        target = args[args.index("-R") + 1] if "-R" in args else ""
        repo = target.split("/", 1)[-1]
        if args[:2] == ("issue", "list"):
            if state["raced"] and repo == first.repo:
                return json.dumps(
                    [
                        {
                            "number": 777,
                            "title": first.subject,
                            "state": "OPEN",
                            "body": reg.render_child_body(m4, first),
                            "labels": [{"name": reg.REGISTRATION_STAGED_LABEL}],
                        }
                    ]
                )
            return "[]"
        if args[:2] == ("label", "list"):
            entries = [
                {"id": f"label-{name}", "name": name, "description": ""}
                for name in sorted(labels.get(repo, set()))
            ]
            if repo == "Odysseus" and state["lock_description"] is not None:
                entries.append(
                    {
                        "id": "registration-lock-a",
                        "name": reg.REGISTRATION_LOCK_LABEL,
                        "description": state["lock_description"],
                    }
                )
            return json.dumps(entries)
        if args[:2] == ("label", "create"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            assert state["lock_description"] is None
            state["lock_description"] = args[args.index("--description") + 1]
            # A previously started apply completed one write before this stale
            # invocation acquired the global lock.
            state["raced"] = True
            return ""
        if args[0] == "api" and args[1].endswith("/labels"):
            assert state["lock_description"] is None
            state["lock_description"] = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("description=")
            )
            state["raced"] = True
            return "registration-lock-a"
        if args[:2] == ("label", "delete"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            state["lock_description"] = None
            return ""
        if args[:2] == ("api", "graphql"):
            assert "labelId=registration-lock-a" in args
            state["lock_description"] = None
            return ""
        if args[:2] in {("issue", "create"), ("issue", "edit")}:
            raise AssertionError("stale reviewed writes reached GitHub")
        raise AssertionError(f"unexpected GitHub call: {args}")

    stage, digest, planned = _planned_stage([m4], interleaved_gh)
    assert stage == "children"
    assert planned[0]["operation"] == "label.create"
    assert planned[0]["name"] == reg.REGISTRATION_LOCK_LABEL
    assert planned[-1]["operation"] == "label.delete"
    assert planned[-1]["name"] == reg.REGISTRATION_LOCK_LABEL

    calls.clear()
    original_gh = reg.gh
    reg.gh = interleaved_gh
    try:
        try:
            with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
                reg.apply_plan([m4], source_sha, digest)
        except ValueError as exc:
            assert "changed before the registration lock" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a stale concurrent apply must be rejected")
    finally:
        reg.gh = original_gh

    assert state["lock_description"] is None
    lock_operations = [
        "create"
        if _is_lock_create_call(call)
        else "delete"
        if _is_lock_delete_call(call)
        else None
        for call in calls
    ]
    assert [operation for operation in lock_operations if operation is not None] == [
        "create",
        "delete",
    ]
    assert not any(
        call[:2] in {("issue", "create"), ("issue", "edit")} for call in calls
    )


def test_replaced_registration_lock_stops_owner_and_preserves_replacement() -> None:
    """A replaced lock stops the old owner without deleting the new lock."""
    m4 = next(m for m in _load() if m.id == "M4")
    labels = _required_labels([m4])
    plan_gh, _ = _fake_github(labels_by_repo=labels)
    stage, digest, _ = _planned_stage([m4], plan_gh)
    assert stage == "children"

    replacement_description = None
    lock_description = None
    calls = []
    next_issue_number = 700

    def interleaved_gh(*args):
        nonlocal lock_description, next_issue_number, replacement_description
        calls.append(args)
        target = args[args.index("-R") + 1] if "-R" in args else ""
        repo = target.split("/", 1)[-1]
        if args[:2] == ("issue", "list"):
            return "[]"
        if args[:2] == ("label", "list"):
            entries = [
                {"id": f"label-{name}", "name": name, "description": ""}
                for name in sorted(labels.get(repo, set()))
            ]
            if repo == "Odysseus" and lock_description is not None:
                entries.append(
                    {
                        "id": "label-owner-b",
                        "name": reg.REGISTRATION_LOCK_LABEL,
                        "description": lock_description,
                    }
                )
            return json.dumps(entries)
        if args[:2] == ("label", "create"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            acquired_description = args[args.index("--description") + 1]
            owner_prefix = (
                reg.REGISTRATION_LOCK_LABEL_DESCRIPTION
                + reg.REGISTRATION_LOCK_OWNER_SEPARATOR
            )
            owner_token = acquired_description.removeprefix(owner_prefix)
            assert acquired_description.startswith(owner_prefix)
            assert len(owner_token) == 32
            int(owner_token, 16)
            # Invocation B copies the public token when it replaces A's label.
            replacement_description = acquired_description
            lock_description = acquired_description
            return ""
        if args[0] == "api" and args[1].endswith("/labels"):
            acquired_description = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("description=")
            )
            replacement_description = acquired_description
            lock_description = acquired_description
            return "label-owner-a"
        if args[:2] == ("label", "delete"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            lock_description = None
            return ""
        if args[:2] == ("api", "graphql"):
            label_id = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("labelId=")
            )
            if label_id != "label-owner-b":
                raise RuntimeError("the owned label node no longer exists")
            lock_description = None
            return ""
        if args[:2] == ("issue", "create"):
            next_issue_number += 1
            return f"https://github.com/{target}/issues/{next_issue_number}"
        raise AssertionError(f"unexpected GitHub call: {args}")

    original_gh = reg.gh
    reg.gh = interleaved_gh
    try:
        try:
            with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
                reg.apply_plan([m4], source_sha, digest)
        except RuntimeError as exc:
            assert "registration lock owner changed" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a replaced registration lock must stop its old owner")
    finally:
        reg.gh = original_gh

    assert replacement_description is not None
    assert lock_description == replacement_description
    assert not any(
        call[:2] in {("issue", "create"), ("issue", "edit")} for call in calls
    )
    assert not any(_is_lock_delete_call(call) for call in calls)


def test_release_cannot_delete_replacement_after_owner_check() -> None:
    """Release targets A's immutable label when B replaces its name."""
    m4 = next(m for m in _load() if m.id == "M4")
    labels = _required_labels([m4])
    plan_gh, _ = _fake_github(labels_by_repo=labels)
    stage, digest, _ = _planned_stage([m4], plan_gh)
    assert stage == "children"

    expected_business_writes = len([child for child in m4.children if not child.manual])
    current_lock = None
    replacement = {
        "id": "label-owner-b",
        "name": reg.REGISTRATION_LOCK_LABEL,
        "description": "milestone registration owner b",
    }
    replaced = False
    business_writes = 0
    calls = []

    def interleaved_gh(*args):
        nonlocal current_lock, replaced, business_writes
        calls.append(args)
        target = args[args.index("-R") + 1] if "-R" in args else ""
        repo = target.split("/", 1)[-1]
        if args[:2] == ("issue", "list"):
            return "[]"
        if args[:2] == ("label", "list"):
            entries = [
                {"id": f"label-{name}", "name": name, "description": ""}
                for name in sorted(labels.get(repo, set()))
            ]
            if repo == "Odysseus" and current_lock is not None:
                lock_snapshot = dict(current_lock)
                if business_writes == expected_business_writes and not replaced:
                    current_lock = dict(replacement)
                    replaced = True
                entries.append(lock_snapshot)
            return json.dumps(entries)
        if args[:2] == ("label", "create"):
            current_lock = {
                "id": "label-owner-a",
                "name": reg.REGISTRATION_LOCK_LABEL,
                "description": args[args.index("--description") + 1],
            }
            return ""
        if args[0] == "api" and args[1].endswith("/labels"):
            current_lock = {
                "id": "label-owner-a",
                "name": reg.REGISTRATION_LOCK_LABEL,
                "description": next(
                    arg.split("=", 1)[1]
                    for arg in args
                    if arg.startswith("description=")
                ),
            }
            return "label-owner-a"
        if args[:2] == ("label", "delete"):
            current_lock = None
            return ""
        if args[:2] == ("api", "graphql"):
            label_id = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("labelId=")
            )
            if current_lock is None or current_lock["id"] != label_id:
                raise RuntimeError("the owned label node no longer exists")
            current_lock = None
            return ""
        if args[:2] == ("issue", "create"):
            business_writes += 1
            return f"https://github.com/{target}/issues/{700 + business_writes}"
        raise AssertionError(f"unexpected GitHub call: {args}")

    original_gh = reg.gh
    reg.gh = interleaved_gh
    try:
        try:
            with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
                reg.apply_plan([m4], source_sha, digest)
        except RuntimeError as exc:
            assert "owned label node" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("A must not delete B's replacement label")
    finally:
        reg.gh = original_gh

    assert replaced
    assert current_lock == replacement
    assert business_writes == expected_business_writes
    assert not any(call[:2] == ("label", "delete") for call in calls)


def test_partial_activation_replans_only_children_still_staged() -> None:
    """Activation retries do not relabel children that already entered intake."""
    m4 = next(m for m in _load() if m.id == "M4")
    inventory, numbers = _canonical_child_inventory(m4, staged=True)
    first = next(child for child in m4.children if not child.manual)
    first_entry = next(
        entry for entry in inventory[first.repo] if entry["title"] == first.subject
    )
    first_entry["labels"] = [{"name": reg.NEEDS_PLAN_LABEL}]
    inventory.setdefault(m4.epic_home, []).append(
        {
            "number": 900,
            "title": m4.title,
            "state": "OPEN",
            "body": reg.render_epic_body(m4, numbers),
            "labels": [{"name": reg.EPIC_LABEL}],
        }
    )
    plan_gh, _ = _fake_github(
        issues_by_repo=inventory, labels_by_repo=_required_labels([m4])
    )
    stage, _, writes = _planned_stage([m4], plan_gh)

    assert stage == "activation"
    edits = [write for write in writes if write["operation"] == "issue.edit"]
    assert {write["number"] for write in edits} == {
        numbers[child.id]
        for child in m4.children
        if not child.manual and child.id != first.id
    }


def test_apply_rejects_unreviewed_stage_before_remote_write() -> None:
    """Apply refuses a stage when its exact plan digest was not approved."""
    m4 = next(m for m in _load() if m.id == "M4")
    fake_gh, calls = _fake_github(labels_by_repo=_required_labels([m4]))
    original_gh = reg.gh
    reg.gh = fake_gh
    try:
        try:
            with _accepted_source() as source_sha:
                reg.apply_plan([m4], source_sha, "f" * 64)
        except ValueError as exc:
            assert "plan digest" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("an unreviewed stage digest must be rejected")
    finally:
        reg.gh = original_gh
    assert not any(call[:2][1:] == ("create",) for call in calls)


def test_apply_requires_explicit_immutable_source_sha() -> None:
    """Apply cannot reach GitHub without one explicit immutable source SHA."""
    calls = []
    original_gh = reg.gh

    def fake_gh(*args):
        calls.append(args)
        raise AssertionError("apply reached GitHub without a source SHA")

    reg.gh = fake_gh
    stderr = io.StringIO()
    try:
        try:
            with redirect_stderr(stderr):
                reg.main(["--apply"])
        except SystemExit as exc:
            assert exc.code == 2
        else:  # pragma: no cover
            raise AssertionError("--apply without --source-sha must fail")
    finally:
        reg.gh = original_gh

    assert "--source-sha" in stderr.getvalue()
    assert calls == []


def test_check_mode_is_offline() -> None:
    """The CI structural check does not read or write a remote service."""
    original_gh = reg.gh
    reg.gh = lambda *args: (_ for _ in ()).throw(
        AssertionError(f"offline check reached GitHub: {args}")
    )
    try:
        with redirect_stdout(io.StringIO()):
            assert reg.main(["--check"]) == 0
    finally:
        reg.gh = original_gh


def test_github_timeout_is_truthful_and_cannot_reach_mutation() -> None:
    """A timed-out GitHub read fails instead of continuing into writes."""
    commands = []
    original_run = reg.subprocess.run

    def timeout_run(command, **kwargs):
        commands.append(command)
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    reg.subprocess.run = timeout_run
    try:
        try:
            reg.issue_inventory("Odysseus")
        except RuntimeError as exc:
            assert f"timed out after {reg.COMMAND_TIMEOUT_SECONDS}s" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a GitHub timeout must propagate truthfully")
    finally:
        reg.subprocess.run = original_run

    assert len(commands) == 1
    assert commands[0][:3] == ["gh", "issue", "list"]
    assert not any(
        tuple(command[1:3])
        in {
            ("issue", "create"),
            ("issue", "edit"),
            ("label", "create"),
            ("label", "delete"),
        }
        for command in commands
    )


def test_git_timeout_stops_before_github_access() -> None:
    """A timed-out source read cannot fall through to GitHub planning."""
    milestones = _load()
    github_calls = []
    original_run = reg.subprocess.run
    original_gh = reg.gh

    def timeout_run(command, **kwargs):
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    reg.subprocess.run = timeout_run
    reg.gh = lambda *args: github_calls.append(args) or TEST_SOURCE_SHA
    try:
        try:
            reg.verify_source_snapshot(milestones, TEST_SOURCE_SHA)
        except ValueError as exc:
            assert "immutable source commit is unavailable" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a Git timeout must stop source verification")
    finally:
        reg.gh = original_gh
        reg.subprocess.run = original_run

    assert github_calls == []


def test_apply_verifies_every_selected_blob_before_github_access() -> None:
    """Payload or workflow drift from the selected commit stops apply."""
    for relative_path in (
        "tools/github/milestone-epics.d/m6.yaml",
        "workflows/m6-idea-watcher-web.yaml",
    ):
        with _isolated_tool_tree() as (isolated, root):
            source_sha = _commit_isolated_sources(root)
            source = root / relative_path
            source.write_text(source.read_text() + "\n# uncommitted drift\n")
            milestones = isolated.load_payloads()
            calls = []
            original_gh = isolated.gh

            def fake_gh(*args):
                calls.append(args)
                raise AssertionError("source drift reached GitHub")

            isolated.gh = fake_gh
            try:
                try:
                    isolated.apply_plan(milestones, source_sha, "0" * 64)
                except ValueError as exc:
                    assert source_sha in str(exc)
                    assert relative_path in str(exc)
                else:  # pragma: no cover
                    raise AssertionError(f"drift in {relative_path} must stop apply")
            finally:
                isolated.gh = original_gh

            assert calls == []


def test_source_verification_accepts_only_exact_committed_blobs() -> None:
    """A full commit SHA verifies the exact parsed payload and workflow bytes."""
    with _isolated_tool_tree() as (isolated, root):
        source_sha = _commit_isolated_sources(root)
        milestones = isolated.load_payloads()
        original_gh = isolated.gh
        calls = []

        def canonical_gh(*args):
            calls.append(args)
            return source_sha

        isolated.gh = canonical_gh
        try:
            assert isolated.verify_source_snapshot(milestones, source_sha) == source_sha
        finally:
            isolated.gh = original_gh
        assert calls == [
            (
                "api",
                "--hostname",
                "github.com",
                f"repos/{reg.ORG}/Odysseus/git/ref/heads/main",
                "--jq",
                ".object.sha",
            )
        ]

        for mutable_reference in ("HEAD", source_sha[:12], "A" * 40):
            try:
                isolated.verify_source_snapshot(milestones, mutable_reference)
            except ValueError as exc:
                assert "immutable" in str(exc)
            else:  # pragma: no cover
                raise AssertionError(
                    f"mutable source reference {mutable_reference!r} must be rejected"
                )


def test_source_verification_rejects_noncanonical_remote_head() -> None:
    """A matching local origin cannot impersonate canonical GitHub main."""
    with _isolated_tool_tree() as (isolated, root):
        source_sha = _commit_isolated_sources(root)
        canonical_sha = "f" * 40
        milestones = isolated.load_payloads()
        calls = []
        original_gh = isolated.gh

        def canonical_gh(*args):
            calls.append(args)
            return canonical_sha

        isolated.gh = canonical_gh
        try:
            try:
                isolated.verify_source_snapshot(milestones, source_sha)
            except ValueError as exc:
                assert "canonical GitHub main" in str(exc)
                assert source_sha in str(exc)
                assert canonical_sha in str(exc)
            else:  # pragma: no cover
                raise AssertionError("a local origin must not replace canonical main")
        finally:
            isolated.gh = original_gh

        assert len(calls) == 1


def test_source_verification_ignores_local_replace_refs() -> None:
    """A replace ref cannot substitute attacker-controlled source bytes."""
    with _isolated_tool_tree() as (isolated, root):
        source_sha = _commit_isolated_sources(root)
        payload = root / "tools" / "github" / "milestone-epics.d" / "m6.yaml"
        payload.write_text(payload.read_text() + "\n# replacement-only bytes\n")
        subprocess.run(
            ("git", "add", str(payload.relative_to(root))),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            (
                "git",
                "-c",
                "user.name=Milestone Test",
                "-c",
                "user.email=milestone-test@example.invalid",
                "commit",
                "--quiet",
                "-m",
                "replacement source",
            ),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        replacement_sha = subprocess.run(
            ("git", "rev-parse", "HEAD"),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        subprocess.run(
            ("git", "replace", source_sha, replacement_sha),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        milestones = isolated.load_payloads()
        original_gh = isolated.gh
        isolated.gh = lambda *args: source_sha
        try:
            try:
                isolated.verify_source_snapshot(milestones, source_sha)
            except ValueError as exc:
                assert "committed source blob does not match" in str(exc)
                assert "m6.yaml" in str(exc)
            else:  # pragma: no cover
                raise AssertionError("a local replace ref must not authorize bytes")
        finally:
            isolated.gh = original_gh


def test_source_verification_rejects_canonical_payload_missing_locally() -> None:
    """The selected commit cannot contain an unparsed canonical YAML payload."""
    with _isolated_tool_tree() as (isolated, root):
        payload_dir = root / "tools" / "github" / "milestone-epics.d"
        extra_payload = payload_dir / "m7.yaml"
        extra_payload.write_text("milestone: M7\n")
        source_sha = _commit_isolated_sources(root)
        extra_payload.unlink()
        milestones = isolated.load_payloads()
        calls = []
        original_gh = isolated.gh

        def unexpected_gh(*args):
            calls.append(args)
            return source_sha

        isolated.gh = unexpected_gh
        try:
            try:
                isolated.verify_source_snapshot(milestones, source_sha)
            except ValueError as exc:
                assert "payload inventory" in str(exc)
                assert "m7.yaml" in str(exc)
            else:  # pragma: no cover
                raise AssertionError("an omitted canonical payload must be rejected")
        finally:
            isolated.gh = original_gh

        assert calls == []


def test_source_verification_rejects_unpublished_commit() -> None:
    """A local-only commit cannot authorize GitHub issue writes."""
    with _isolated_tool_tree() as (isolated, root):
        published_sha = _commit_isolated_sources(root)
        payload = root / "tools" / "github" / "milestone-epics.d" / "m6.yaml"
        payload.write_text(payload.read_text() + "\n# local-only commit\n")
        subprocess.run(
            ("git", "add", str(payload.relative_to(root))),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        subprocess.run(
            (
                "git",
                "-c",
                "user.name=Milestone Test",
                "-c",
                "user.email=milestone-test@example.invalid",
                "commit",
                "--quiet",
                "-m",
                "unpublished source",
            ),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        )
        source_sha = subprocess.run(
            ("git", "rev-parse", "HEAD"),
            cwd=root,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()
        assert source_sha != published_sha
        milestones = isolated.load_payloads()
        try:
            isolated.verify_source_snapshot(milestones, source_sha)
        except ValueError as exc:
            assert "origin" in str(exc)
            assert "main" in str(exc)
            assert source_sha in str(exc)
        else:  # pragma: no cover
            raise AssertionError("an unpublished commit must be rejected")


def test_registration_resumes_exact_historical_bodies_after_unrelated_main_change() -> (
    None
):
    """A later stage accepts exact A-bound bodies when selected blobs match B."""
    with _isolated_tool_tree() as (isolated, root):
        source_a = _commit_isolated_sources(root)
        milestones_a = [
            replace(milestone, source_sha=source_a)
            for milestone in isolated.load_payloads()
        ]
        existing_milestone = milestones_a[0]
        existing_child = existing_milestone.children[0]
        existing_body = isolated.render_child_body(existing_milestone, existing_child)
        issues_by_repo = {
            existing_child.repo: [
                {
                    "number": 77,
                    "title": existing_child.subject,
                    "state": "OPEN",
                    "body": existing_body,
                    "labels": [{"name": isolated.REGISTRATION_STAGED_LABEL}],
                }
            ]
        }
        source_b = _advance_isolated_main(
            root,
            "docs/unrelated.txt",
            "This change does not modify milestone registration sources.\n",
        )
        assert source_b != source_a
        milestones_b = isolated.load_payloads()
        remote_gh, calls = _fake_github(
            issues_by_repo=issues_by_repo,
            labels_by_repo=_required_labels(milestones_b),
            issue_numbers=range(1_000, 1_100),
        )

        def canonical_gh(*args):
            if args[:3] == ("api", "--hostname", "github.com"):
                return source_b
            return remote_gh(*args)

        original_gh = isolated.gh
        isolated.gh = canonical_gh
        try:
            stdout = io.StringIO()
            with redirect_stdout(stdout):
                assert isolated.plan_mode(milestones_b, source_b) == 0
            lines = stdout.getvalue().splitlines()
            assert "STAGE children" in lines
            digest = next(
                line.removeprefix("PLAN_SHA256 ")
                for line in lines
                if line.startswith("PLAN_SHA256 ")
            )
            with redirect_stdout(io.StringIO()):
                assert isolated.apply_plan(milestones_b, source_b, digest) == 0
        finally:
            isolated.gh = original_gh

        created_titles = {
            call[call.index("--title") + 1]
            for call in calls
            if call[:2] == ("issue", "create")
        }
        assert existing_child.subject not in created_titles
        assert not any(
            call[:2] == ("issue", "edit") and call[2] == "77" for call in calls
        )
        assert issues_by_repo[existing_child.repo][0]["body"] == existing_body


def test_historical_body_resume_rejects_changed_sources_and_tampering_before_write() -> (
    None
):
    """Only exact bodies with equivalent payload and workflow blobs can resume."""
    cases = (
        ("payload blob changed", "tools/github/milestone-epics.d/m1.yaml"),
        ("workflow blob changed", "workflows/m1-hephaestus-keystone.yaml"),
        ("forged citation", None),
        ("body drift", None),
    )
    for case, selected_path in cases:
        with _isolated_tool_tree() as (isolated, root):
            source_a = _commit_isolated_sources(root)
            milestones_a = [
                replace(milestone, source_sha=source_a)
                for milestone in isolated.load_payloads()
            ]
            existing_milestone = milestones_a[0]
            existing_child = existing_milestone.children[0]
            existing_body = isolated.render_child_body(
                existing_milestone, existing_child
            )

            if selected_path is None:
                source_b = _advance_isolated_main(
                    root,
                    "docs/unrelated.txt",
                    "This change does not modify milestone registration sources.\n",
                )
            else:
                selected = root / selected_path
                source_b = _advance_isolated_main(
                    root,
                    selected_path,
                    selected.read_text() + "\n# changed selected source bytes at B\n",
                )

            if case == "forged citation":
                existing_body = existing_body.replace(source_a, "f" * 40)
            elif case == "body drift":
                existing_body = existing_body.replace(
                    existing_child.description,
                    "ATTACKER CONTROLLED BODY",
                    1,
                )

            milestones_b = isolated.load_payloads()
            issues_by_repo = {
                existing_child.repo: [
                    {
                        "number": 77,
                        "title": existing_child.subject,
                        "state": "OPEN",
                        "body": existing_body,
                        "labels": [{"name": isolated.REGISTRATION_STAGED_LABEL}],
                    }
                ]
            }
            remote_gh, calls = _fake_github(
                issues_by_repo=issues_by_repo,
                labels_by_repo=_required_labels(milestones_b),
            )

            def canonical_gh(*args):
                if args[:3] == ("api", "--hostname", "github.com"):
                    return source_b
                return remote_gh(*args)

            original_gh = isolated.gh
            isolated.gh = canonical_gh
            stdout = io.StringIO()
            try:
                try:
                    with redirect_stdout(stdout):
                        isolated.plan_mode(milestones_b, source_b)
                except RuntimeError as exc:
                    assert "marker-bound issue source drift" in str(exc), (
                        f"{case} failed outside historical body reconciliation: {exc}"
                    )
                else:  # pragma: no cover
                    raise AssertionError(f"{case} must stop historical resume")
            finally:
                isolated.gh = original_gh

            assert "PLAN_SHA256" not in stdout.getvalue(), (
                f"{case} reached a reviewable plan before complete preflight"
            )
            assert _mutation_payloads(calls) == [], (
                f"{case} reached a GitHub write before complete preflight"
            )


def test_apply_plan_reuses_children_uses_title_and_holds_manual_gate() -> None:
    m4 = next(m for m in _load() if m.id == "M4")
    existing = m4.children[0]
    calls = []
    next_number = 200
    lock_description = None
    original_gh = reg.gh

    def fake_gh(*args):
        nonlocal next_number, lock_description
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
                            "labels": [{"name": reg.REGISTRATION_STAGED_LABEL}],
                        }
                    ]
                )
            return "[]"
        if args[:2] == ("label", "list"):
            entries = [
                {"id": f"label-{name}", "name": name, "description": ""}
                for name in sorted(
                    {
                        reg.EPIC_LABEL,
                        reg.NEEDS_PLAN_LABEL,
                        reg.REGISTRATION_STAGED_LABEL,
                        EXPECTED_MANUAL_GATE_LABEL,
                    }
                )
            ]
            repo = args[args.index("-R") + 1]
            if repo == f"{reg.ORG}/Odysseus" and lock_description is not None:
                entries.append(
                    {
                        "id": "registration-lock-a",
                        "name": reg.REGISTRATION_LOCK_LABEL,
                        "description": lock_description,
                    }
                )
            return json.dumps(entries)
        if args[:2] == ("label", "create"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            lock_description = args[args.index("--description") + 1]
            return ""
        if args[0] == "api" and args[1].endswith("/labels"):
            lock_description = next(
                arg.split("=", 1)[1] for arg in args if arg.startswith("description=")
            )
            return "registration-lock-a"
        if args[:2] == ("label", "delete"):
            assert args[2] == reg.REGISTRATION_LOCK_LABEL
            lock_description = None
            return ""
        if args[:2] == ("api", "graphql"):
            assert "labelId=registration-lock-a" in args
            lock_description = None
            return ""
        if args[:2] == ("issue", "create"):
            repo = args[args.index("-R") + 1]
            next_number += 1
            return f"https://github.com/{repo}/issues/{next_number}"
        raise AssertionError(f"unexpected gh call: {args}")

    stage, digest, planned = _planned_stage([m4], fake_gh)
    assert stage == "children"
    reg.gh = fake_gh
    try:
        with _accepted_source() as source_sha:
            assert reg.apply_plan([m4], source_sha, digest) == 0
    finally:
        reg.gh = original_gh

    creates = [call for call in calls if call[:2] == ("issue", "create")]
    planned_creates = [
        write for write in planned if write["operation"] == "issue.create"
    ]
    assert len(creates) == len(planned_creates)
    assert all("--title" in call and "--subject" not in call for call in creates)
    created_titles = [call[call.index("--title") + 1] for call in creates]
    assert existing.subject not in created_titles
    assert m4.title not in created_titles
    gate = next(child for child in m4.children if child.manual)
    assert gate.subject not in created_titles
    for child in m4.children:
        if child.manual or child.id == existing.id:
            continue
        child_call = next(
            call for call in creates if call[call.index("--title") + 1] == child.subject
        )
        assert (
            child_call[child_call.index("--label") + 1] == reg.REGISTRATION_STAGED_LABEL
        )
        child_body = child_call[child_call.index("--body") + 1]
        assert reg.child_identity_marker(child) in child_body
        assert reg.child_source_marker(m4, child) in child_body


def test_apply_plan_rejects_unsafe_manual_retry_before_any_write() -> None:
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, _ = _canonical_child_inventory(m4, staged=True)
    gate = next(child for child in m4.children if child.manual)
    gate_entry = next(
        entry for entry in issues_by_repo[gate.repo] if entry["title"] == gate.subject
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
    issues_by_repo, _ = _canonical_child_inventory(m4, staged=True)
    gate = next(child for child in m4.children if child.manual)
    gate_entry = next(
        entry for entry in issues_by_repo[gate.repo] if entry["title"] == gate.subject
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
        entry for entry in issues_by_repo[first.repo] if entry["title"] == first.subject
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
        entry for entry in issues_by_repo[first.repo] if entry["title"] == first.subject
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
                    {"id": "label-epic", "name": reg.EPIC_LABEL},
                    {"id": "label-plan", "name": reg.NEEDS_PLAN_LABEL},
                    {
                        "id": "label-staged",
                        "name": reg.REGISTRATION_STAGED_LABEL,
                    },
                    {"id": "label-gate", "name": EXPECTED_MANUAL_GATE_LABEL},
                ]
            )
        raise AssertionError(f"registered epic rerun attempted a write: {args}")

    stage, digest, planned = _planned_stage([m4], fake_gh)
    assert stage == "complete"
    assert planned == []
    reg.gh = fake_gh
    try:
        with _accepted_source() as source_sha:
            assert reg.apply_plan([m4], source_sha, digest) == 0
    finally:
        reg.gh = original_gh

    assert not any(
        call[:2] == ("issue", "create") or _is_lock_create_call(call) for call in calls
    )


def test_partial_retry_requires_staged_child_state_before_any_write() -> None:
    """Without a registered epic, reusable children remain non-dispatching."""
    m4 = next(m for m in _load() if m.id == "M4")
    issues_by_repo, _ = _canonical_child_inventory(m4, staged=True)
    first = m4.children[0]
    first_entry = next(
        entry for entry in issues_by_repo[first.repo] if entry["title"] == first.subject
    )
    first_entry["labels"] = [{"name": "state:plan-go"}]

    _assert_apply_rejected_before_write(
        m4, issues_by_repo, "missing non-dispatch staging label"
    )

    closed_issues, _ = _canonical_child_inventory(m4, staged=True)
    closed_entry = next(
        entry for entry in closed_issues[first.repo] if entry["title"] == first.subject
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
        assert (
            reg.existing_child_issue(
                milestone,
                child,
                [entry([plan_state])],
                require_initial_state=False,
            )
            == 42
        )
        assert (
            reg.existing_child_issue(
                milestone,
                child,
                [entry([plan_state, "state:skip"])],
                require_initial_state=False,
            )
            == 42
        )

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
        candidate.id: index + 100 for index, candidate in enumerate(milestone.children)
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
        candidate.id: index + 100 for index, candidate in enumerate(milestone.children)
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
    numbers = {child.id: index + 100 for index, child in enumerate(milestone.children)}
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
    assert (
        reg.existing_child_issue(
            milestone, gate, [entry([EXPECTED_MANUAL_GATE_LABEL])], numbers
        )
        == 44
    )
    _assert_all_rejected(
        (
            (
                lambda: reg.existing_child_issue(milestone, gate, [entry([])], numbers),
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
    numbers = {child.id: index + 100 for index, child in enumerate(milestone.children)}

    assert (
        reg.existing_open_epic(
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
        )
        == 9
    )

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
        replace(m4, children=unsafe_children) if m.id == "M4" else m for m in milestones
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
        test_tool_symlink_invocation_is_rejected,
        test_parent_symlink_uses_one_resolved_repository_root,
        test_six_milestones_with_correct_epic_homes,
        test_every_child_is_single_purpose_and_repo_valid,
        test_each_milestone_has_unblocked_requirements_child_first,
        test_dependency_edges_resolve_to_siblings_acyclically,
        test_epic_body_checklist_is_structurally_parseable,
        test_epic_body_resolves_every_child_to_its_own_repository,
        test_child_body_transports_authored_content_and_identifies_sources,
        test_rendered_bodies_cite_one_immutable_source_commit,
        test_dispatchable_child_description_comes_from_workflow_manifest,
        test_workflow_task_source_must_match_once,
        test_manual_gate_requires_workflow_metadata_source,
        test_routing_payload_cannot_duplicate_workflow_description,
        test_workflow_reference_stays_in_direct_regular_file_boundary,
        test_payload_file_symlink_stops_before_remote_access,
        test_payload_directory_symlink_stops_before_remote_access,
        test_payload_filename_must_match_milestone_identity,
        test_top_level_routing_fields_require_exact_string_types,
        test_child_routing_fields_require_exact_authored_types,
        test_manual_requires_an_exact_yaml_boolean,
        test_workflow_loading_requires_no_follow_and_dir_fd_capabilities,
        test_workflow_contract_requires_version_and_epic_home_parity,
        test_workflow_and_routing_dependencies_must_match_exactly,
        test_dispatchable_workflow_and_routing_tasks_are_bijective,
        test_validate_detects_dependency_cycle_from_source_mutation,
        test_cross_milestone_child_title_collision_stops_before_remote_access,
        test_child_and_epic_title_collision_stops_before_remote_access,
        test_epic_title_shape_stops_apply_before_remote_access,
        test_child_id_shape_stops_apply_before_remote_access,
        test_apply_preflights_late_milestone_before_any_remote_access,
        test_m4_has_manual_dogfood_evidence_gate_after_rollout,
        test_m4_manual_gate_is_qualified_and_outside_parser_tasks,
        test_label_stage_plan_and_apply_payloads_are_exact,
        test_child_stage_plan_and_apply_payloads_are_exact,
        test_real_issue_ids_stage_gate_then_epic_payloads_exactly,
        test_partial_child_apply_failure_leaves_no_active_issue,
        test_stale_interleaved_apply_cannot_duplicate_child_issue,
        test_replaced_registration_lock_stops_owner_and_preserves_replacement,
        test_release_cannot_delete_replacement_after_owner_check,
        test_partial_activation_replans_only_children_still_staged,
        test_apply_rejects_unreviewed_stage_before_remote_write,
        test_apply_requires_explicit_immutable_source_sha,
        test_check_mode_is_offline,
        test_github_timeout_is_truthful_and_cannot_reach_mutation,
        test_git_timeout_stops_before_github_access,
        test_apply_verifies_every_selected_blob_before_github_access,
        test_source_verification_accepts_only_exact_committed_blobs,
        test_source_verification_rejects_noncanonical_remote_head,
        test_source_verification_ignores_local_replace_refs,
        test_source_verification_rejects_canonical_payload_missing_locally,
        test_source_verification_rejects_unpublished_commit,
        test_registration_resumes_exact_historical_bodies_after_unrelated_main_change,
        test_historical_body_resume_rejects_changed_sources_and_tampering_before_write,
        test_apply_plan_reuses_children_uses_title_and_holds_manual_gate,
        test_apply_plan_rejects_unsafe_manual_retry_before_any_write,
        test_apply_plan_rejects_unlabeled_gate_before_any_write,
        test_existing_epic_does_not_bypass_child_preflight,
        test_existing_epic_allows_canonical_child_lifecycle_progress,
        test_partial_retry_requires_staged_child_state_before_any_write,
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
