#!/usr/bin/env python3
"""Behavior assertions for the M1-M6 epic registration payloads (issue #468).

Runs under pytest and also through ``just test-milestone-registry``, which
uses the plain-script entry point so the checks work without pytest.
"""

from __future__ import annotations

import hashlib
import errno
import importlib.util
import io
import json
import os
import signal
import shlex
import shutil
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
from contextlib import contextmanager, redirect_stderr, redirect_stdout
from dataclasses import replace
from pathlib import Path
from unittest.mock import patch

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


def _require_linux() -> None:
    """Mark a Linux-only behavior test as skipped on unsupported hosts."""
    if not sys.platform.startswith("linux"):
        raise unittest.SkipTest("requires Linux subreaper and pidfd containment")


def _write_gh_boundary_executable(directory: Path, name: str, body: str) -> Path:
    """Create one owner-only executable for direct process-boundary tests."""
    executable = directory / name
    executable.write_text(
        f"#!{sys.executable}\n{textwrap.dedent(body).lstrip()}", encoding="utf-8"
    )
    executable.chmod(0o700)
    return executable


def _wait_for_process_group_extinction(process_group: int) -> bool:
    """Wait briefly for a killed test process group to leave the process table."""
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        if not reg._process_group_exists(process_group):
            return True
        time.sleep(0.01)
    return not reg._process_group_exists(process_group)


def _heartbeat_stopped(path: Path, timeout: float = 2.0) -> bool:
    """Return true after one heartbeat file stops changing."""
    deadline = time.monotonic() + timeout
    previous = None
    stable_since = None
    while time.monotonic() < deadline:
        try:
            current = path.read_bytes()
        except FileNotFoundError:
            time.sleep(0.01)
            continue
        if current == previous:
            stable_since = stable_since or time.monotonic()
            if time.monotonic() - stable_since >= 0.15:
                return True
        else:
            previous = current
            stable_since = None
        time.sleep(0.01)
    return False


def _kill_test_process(pid: int) -> None:
    """Remove one leaked test process without masking the test assertion."""
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _linux_process_identity_is_active(process_id: int, start_time: int) -> bool:
    """Return true only while one exact Linux process identity is active."""
    try:
        content = Path(f"/proc/{process_id}/stat").read_bytes()
    except (FileNotFoundError, ProcessLookupError):
        return False
    closing = content.rfind(b")")
    fields = content[closing + 2 :].split() if closing >= 1 else ()
    return len(fields) > 19 and int(fields[19]) == start_time


def test_libc_pidfds_work_without_python_pidfd_bindings() -> None:
    """The locked Python can retain Linux process identity through libc."""
    _require_linux()
    with patch.object(reg.os, "pidfd_open", None, create=True), patch.object(
        reg.signal, "pidfd_send_signal", None, create=True
    ):
        descriptor = reg._pidfd_open(os.getpid())
        try:
            assert not os.get_inheritable(descriptor)
            reg._pidfd_send_signal(descriptor, 0)
        finally:
            os.close(descriptor)
        try:
            reg._pidfd_send_signal(descriptor, 0)
        except OSError as error:
            assert error.errno == errno.EBADF
        else:
            raise AssertionError("a closed pidfd must not retain signal authority")


def test_process_scope_rescans_after_a_scanned_child_forks_then_exits() -> None:
    """An exit after child inventory cannot hide the newly adopted child."""
    supervisor_pid = 101
    parent_pid = 202
    child_pid = 303
    parent_descriptor = 11
    child_descriptor = 12
    inventory_read = threading.Event()
    fork_complete = threading.Event()
    state = {"parent_exited": False, "child_visible": False}

    scope = object.__new__(reg._LinuxProcessScope)
    scope.supervisor = supervisor_pid
    scope.baseline = set()
    scope.owned = {parent_pid: (1, parent_descriptor)}

    original_child_pids = reg._linux_child_pids
    original_identity = reg._linux_process_identity
    original_pidfd_open = getattr(reg.os, "pidfd_open", None)
    original_exited = reg._LinuxProcessScope._exited

    def child_pids(process_id: int) -> set[int]:
        if process_id == supervisor_pid:
            return {child_pid} if state["child_visible"] else set()
        if process_id == parent_pid:
            # Capture the empty inventory before allowing the child to fork and
            # its parent to exit. This is the exact scan-to-pidfd race.
            inventory_read.set()
            assert fork_complete.wait(timeout=1), "the synchronized fork stalled"
            return set()
        return set()

    def identity(process_id: int) -> tuple[int, int] | None:
        if process_id == parent_pid:
            return None if state["parent_exited"] else (parent_pid, 1)
        if process_id == child_pid and state["child_visible"]:
            return child_pid, 2
        return None

    def fork_after_inventory() -> None:
        assert inventory_read.wait(timeout=1), "the parent inventory was not read"
        state["child_visible"] = True
        state["parent_exited"] = True
        fork_complete.set()

    worker = threading.Thread(target=fork_after_inventory)
    worker.start()
    reg._linux_child_pids = child_pids
    reg._linux_process_identity = identity
    reg.os.pidfd_open = lambda process_id, _flags: (
        child_descriptor if process_id == child_pid else parent_descriptor
    )
    reg._LinuxProcessScope._exited = staticmethod(
        lambda descriptor: descriptor == parent_descriptor
    )
    try:
        live = scope.live_descendants(parent_pid)
    finally:
        reg._LinuxProcessScope._exited = staticmethod(original_exited)
        reg._linux_process_identity = original_identity
        reg._linux_child_pids = original_child_pids
        if original_pidfd_open is None:
            del reg.os.pidfd_open
        else:
            reg.os.pidfd_open = original_pidfd_open
        worker.join(timeout=1)

    assert not worker.is_alive(), "the synchronized fork worker did not finish"
    assert live == ((child_pid, child_descriptor),), (
        "the child adopted after its parent's final inventory scan was missed"
    )


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


def _assert_payload_load_fails(isolated, expected: str) -> None:
    """Require one isolated source change to stop local loading."""
    try:
        isolated.load_payloads()
    except ValueError as exc:
        assert expected in str(exc), str(exc)
    else:  # pragma: no cover
        raise AssertionError(f"unsafe YAML was accepted; expected {expected!r}")


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


def test_executable_entry_rejects_python_startup_and_loader_authority() -> None:
    """The operator entry boundary starts isolated Python with a minimal environment."""
    source_root = Path(__file__).resolve().parents[2]
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary) / "repo"
        tool = root / "tools" / "github" / _TOOL_PATH.name
        tool.parent.mkdir(parents=True)
        shutil.copy2(_TOOL_PATH, tool)
        shutil.copytree(PAYLOADS, tool.parent / "milestone-epics.d")
        shutil.copytree(source_root / "workflows", root / "workflows")
        tool.chmod(0o700)

        dependency_python = root / ".pixi" / "envs" / "default" / "bin" / "python"
        dependency_python.parent.mkdir(parents=True)
        dependency_python.write_text(
            f'#!/bin/bash -p\nexec {shlex.quote(sys.executable)} "$@"\n',
            encoding="utf-8",
        )
        dependency_python.chmod(0o700)

        hostile = Path(temporary) / "hostile"
        hostile.mkdir()
        marker = Path(temporary) / "sitecustomize-ran"
        (hostile / "sitecustomize.py").write_text(
            "import os\n"
            "from pathlib import Path\n"
            f"Path({str(marker)!r}).write_text("
            "os.environ.get('GH_TOKEN', 'missing'), encoding='utf-8')\n",
            encoding="utf-8",
        )
        hostile_bin = Path(temporary) / "bin"
        hostile_bin.mkdir()
        (hostile_bin / "python3").symlink_to(Path(sys.executable).resolve())
        environment = {
            "DYLD_LIBRARY_PATH": str(hostile),
            "GH_TOKEN": "odysseus-entry-secret",
            "HOME": str(Path(temporary) / "home"),
            "LD_LIBRARY_PATH": str(hostile),
            "PATH": f"{hostile_bin}:/usr/bin:/bin",
            "PYTHONPATH": str(hostile),
            "PYTHONSTARTUP": str(hostile / "startup.py"),
        }

        result = subprocess.run(
            (str(tool), "--plan"),
            cwd=root,
            env=environment,
            capture_output=True,
            text=True,
            timeout=10,
            check=False,
        )

        assert result.returncode == 2, result.stderr
        assert "--plan and --apply require --source-sha" in result.stderr
        assert not marker.exists(), "sitecustomize executed before registrar isolation"
        assert "odysseus-entry-secret" not in result.stdout + result.stderr


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


def test_yaml_duplicate_keys_are_rejected_at_each_authored_level() -> None:
    """Duplicate root and nested keys cannot silently replace authored data."""
    cases = (
        (
            "payload root",
            "tools/github/milestone-epics.d/m1.yaml",
            lambda source: (
                source + '\ntitle: "M1 Epic: Hephaestus mesh keystone (ADR-020)"\n'
            ),
        ),
        (
            "payload child",
            "tools/github/milestone-epics.d/m1.yaml",
            lambda source: source.replace(
                "  - id: M1.1\n    repo: Hephaestus\n",
                "  - id: M1.1\n    repo: Hephaestus\n    repo: Hephaestus\n",
                1,
            ),
        ),
        (
            "workflow metadata",
            "workflows/m1-hephaestus-keystone.yaml",
            lambda source: source.replace(
                "  epic_home: Hephaestus\n",
                "  epic_home: Hephaestus\n  epic_home: Hephaestus\n",
                1,
            ),
        ),
        (
            "workflow task",
            "workflows/m1-hephaestus-keystone.yaml",
            lambda source: source.replace(
                "      - subject: Requirements and invariants for the mesh worker package\n",
                "      - subject: Requirements and invariants for the mesh worker package\n"
                "        subject: Requirements and invariants for the mesh worker package\n",
                1,
            ),
        ),
    )
    for _label, relative_path, mutate in cases:
        with _isolated_tool_tree() as (isolated, root):
            path = root / relative_path
            path.write_text(mutate(path.read_text(encoding="utf-8")), encoding="utf-8")
            _assert_payload_load_fails(isolated, "duplicate key")


def test_payload_inventory_and_yaml_source_bytes_have_hard_ceilings() -> None:
    """Source enumeration and reads reject inputs above their fixed budgets."""
    with _isolated_tool_tree() as (isolated, root):
        payload_dir = root / "tools" / "github" / "milestone-epics.d"
        for index in range(27):
            (payload_dir / f"extra-{index:02d}.yaml").write_text("null\n")
        try:
            isolated._read_payload_sources(payload_dir)
        except ValueError as exc:
            assert "at most 32 YAML files" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a 33-file payload inventory was accepted")

    oversized = b"#" * (1024 * 1024 + 1)
    with _isolated_tool_tree() as (isolated, root):
        payload_dir = root / "tools" / "github" / "milestone-epics.d"
        (payload_dir / "oversized.yaml").write_bytes(oversized)
        try:
            isolated._read_payload_sources(payload_dir)
        except ValueError as exc:
            assert "1048576-byte ceiling" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("an oversized routing payload was accepted")

    with _isolated_tool_tree() as (isolated, root):
        workflow_path = root / "workflows" / "m1-hephaestus-keystone.yaml"
        workflow_path.write_bytes(oversized)
        try:
            isolated._read_workflow_source(
                "workflows/m1-hephaestus-keystone.yaml",
                root / "tools" / "github" / "milestone-epics.d" / "m1.yaml",
            )
        except ValueError as exc:
            assert "1048576-byte ceiling" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("an oversized workflow was accepted")


def test_yaml_alias_depth_node_and_string_budgets_apply_to_all_sources() -> None:
    """Payload and workflow YAML cannot exceed parser resource budgets."""
    cases = (
        (
            "aliases",
            "padding: [&shared harmless, " + ", ".join(["*shared"] * 33) + "]\n",
            "more than 32 aliases",
        ),
        (
            "recursive alias",
            "padding: &cycle [*cycle]\n",
            "recursive YAML alias",
        ),
        (
            "merge expansion",
            "padding_base: &base {value: harmless}\npadding:\n  <<: *base\n",
            "YAML merge keys are not permitted",
        ),
        (
            "depth",
            "padding: " + "[" * 33 + "null" + "]" * 33 + "\n",
            "more than 32 collection levels",
        ),
        (
            "nodes",
            "padding:\n" + "  - null\n" * 10001,
            "more than 10000 nodes",
        ),
        (
            "scalar",
            'padding: "' + "x" * (256 * 1024 + 1) + '"\n',
            "scalar exceeds 262144 characters",
        ),
    )
    targets = (
        "tools/github/milestone-epics.d/m1.yaml",
        "workflows/m1-hephaestus-keystone.yaml",
    )
    for _label, addition, expected in cases:
        for relative_path in targets:
            with _isolated_tool_tree() as (isolated, root):
                path = root / relative_path
                with path.open("a", encoding="utf-8") as stream:
                    stream.write("\n" + addition)
                _assert_payload_load_fails(isolated, expected)


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


def test_plan_and_apply_reject_unexecutable_write_arguments_before_mutation() -> None:
    """Every reviewed write must be executable before a lock can be created."""
    milestone = next(m for m in _load() if m.id == "M4")
    selected = next(child for child in milestone.children if not child.manual)
    children = tuple(
        replace(child, description=f"{child.description}\0invalid")
        if child.id == selected.id
        else child
        for child in milestone.children
    )
    malformed = replace(milestone, children=children)
    labels = _required_labels([malformed])
    fake_gh, calls = _fake_github(labels_by_repo=labels)
    original_gh = reg.gh
    reg.gh = fake_gh
    plan_output = io.StringIO()
    try:
        try:
            with _accepted_source() as source_sha, redirect_stdout(plan_output):
                reg.plan_mode([malformed], source_sha)
        except ValueError as exc:
            assert "NUL" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("plan accepted an unexecutable GitHub argument")

        bound = [replace(malformed, source_sha=TEST_SOURCE_SHA)]
        state = reg._read_registration_state(bound)
        business_stage = reg.next_registration_stage(bound, state)
        reviewed_stage = reg._guarded_registration_stage(business_stage)
        digest = reg.registration_stage_digest(reviewed_stage, TEST_SOURCE_SHA)
        try:
            with _accepted_source() as source_sha, redirect_stdout(io.StringIO()):
                reg.apply_plan([malformed], source_sha, digest)
        except ValueError as exc:
            assert "NUL" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("apply acquired a lock for an unexecutable stage")
    finally:
        reg.gh = original_gh

    assert "PLAN_SHA256" not in plan_output.getvalue()
    assert _mutation_payloads(calls) == []


def test_github_argument_and_field_limits_reject_before_execution() -> None:
    """The command boundary rejects platform and GitHub limit violations."""
    target = f"{reg.ORG}/Odysseus"
    cases = (
        (
            "per-argument byte limit",
            (
                "issue",
                "create",
                "-R",
                target,
                "--title",
                "bounded",
                "--body",
                "x" * 131_072,
            ),
            "argument exceeds",
        ),
        (
            "aggregate argv byte limit",
            (
                "issue",
                "create",
                "-R",
                target,
                "--title",
                "bounded",
                "--body",
                "bounded",
                *("x" * 1024 for _ in range(1025)),
            ),
            "aggregate",
        ),
        (
            "issue title limit",
            (
                "issue",
                "create",
                "-R",
                target,
                "--title",
                "x" * 257,
                "--body",
                "bounded",
            ),
            "issue title",
        ),
        (
            "issue body limit",
            (
                "issue",
                "create",
                "-R",
                target,
                "--title",
                "bounded",
                "--body",
                "x" * 65_537,
            ),
            "issue body",
        ),
        (
            "label name limit",
            (
                "label",
                "create",
                "x" * 51,
                "-R",
                target,
                "--description",
                "bounded",
                "--color",
                "0E8A16",
            ),
            "label name",
        ),
        (
            "label description limit",
            (
                "label",
                "create",
                "bounded",
                "-R",
                target,
                "--description",
                "x" * 101,
                "--color",
                "0E8A16",
            ),
            "label description",
        ),
    )
    for name, arguments, expected in cases:
        try:
            reg._bound_gh_args(*arguments)
        except ValueError as exc:
            assert expected in str(exc), f"{name}: {exc}"
        else:  # pragma: no cover
            raise AssertionError(f"{name} was accepted")


def test_oversized_issue_body_stops_before_digest_lock_or_mutation() -> None:
    """An oversized rendered body cannot become a plan or acquire the lock."""
    milestone = next(m for m in _load() if m.id == "M4")
    selected = next(child for child in milestone.children if not child.manual)
    children = tuple(
        replace(child, description="x" * 65_537) if child.id == selected.id else child
        for child in milestone.children
    )
    oversized = replace(milestone, children=children)
    fake_gh, calls = _fake_github(labels_by_repo=_required_labels([oversized]))
    original_gh = reg.gh
    original_digest = reg.registration_stage_digest
    digest_calls = []

    def unexpected_digest(*args, **kwargs):
        digest_calls.append((args, kwargs))
        raise AssertionError("an oversized stage reached digest creation")

    reg.gh = fake_gh
    reg.registration_stage_digest = unexpected_digest
    plan_output = io.StringIO()
    try:
        for mode in ("plan", "apply"):
            try:
                with _accepted_source() as source_sha, redirect_stdout(plan_output):
                    if mode == "plan":
                        reg.plan_mode([oversized], source_sha)
                    else:
                        reg.apply_plan([oversized], source_sha, "0" * 64)
            except ValueError as exc:
                assert "issue body" in str(exc), str(exc)
            else:  # pragma: no cover
                raise AssertionError(f"{mode} accepted an oversized issue body")
    finally:
        reg.registration_stage_digest = original_digest
        reg.gh = original_gh

    assert digest_calls == []
    assert "PLAN_SHA256" not in plan_output.getvalue()
    assert _mutation_payloads(calls) == []


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


def test_github_arguments_are_pinned_to_the_canonical_host_and_repository() -> None:
    """Every remote operation carries the exact github.com repository authority."""
    assert reg._bound_gh_args(
        "issue", "list", "-R", f"{reg.ORG}/Odysseus", "--state", "all"
    ) == (
        "issue",
        "list",
        "-R",
        f"github.com/{reg.ORG}/Odysseus",
        "--state",
        "all",
    )
    assert reg._bound_gh_args("api", f"repos/{reg.ORG}/Odysseus/labels") == (
        "api",
        "--hostname",
        "github.com",
        f"repos/{reg.ORG}/Odysseus/labels",
    )

    for hostile in (
        ("issue", "list", "-R", "evil.example/HomericIntelligence/Odysseus"),
        ("issue", "list", "-R", "OtherOwner/Odysseus"),
        ("api", "--hostname", "evil.example", "graphql"),
        ("api", "repos/OtherOwner/Odysseus/labels"),
    ):
        try:
            reg._bound_gh_args(*hostile)
        except ValueError:
            pass
        else:  # pragma: no cover
            raise AssertionError(f"hostile GitHub authority was accepted: {hostile}")


def test_issue_inventory_rejects_malformed_identifiers_and_schema() -> None:
    """Issue/API data must be exact typed input before it can select a write."""
    valid = {
        "number": 17,
        "title": "A title",
        "state": "OPEN",
        "body": "A body",
        "labels": [
            {
                "id": "label-17",
                "name": "state:needs-plan",
                "description": "",
                "color": "ffffff",
            }
        ],
    }
    cases = {
        "top-level mapping": {"entry": valid},
        "boolean issue number": [{**valid, "number": True}],
        "floating issue number": [{**valid, "number": 17.5}],
        "string issue number": [{**valid, "number": "17"}],
        "zero issue number": [{**valid, "number": 0}],
        "duplicate issue number": [valid, {**valid, "title": "Another title"}],
        "missing issue field": [
            {key: value for key, value in valid.items() if key != "body"}
        ],
        "extra issue field": [{**valid, "unexpected": "value"}],
        "non-string title": [{**valid, "title": None}],
        "non-string state": [{**valid, "state": 1}],
        "non-string unhashable state": [{**valid, "state": []}],
        "non-string body": [{**valid, "body": None}],
        "non-list labels": [{**valid, "labels": {"name": "state:needs-plan"}}],
        "non-mapping label": [{**valid, "labels": ["state:needs-plan"]}],
        "missing label name": [{**valid, "labels": [{"color": "ffffff"}]}],
        "empty label name": [{**valid, "labels": [{"name": ""}]}],
        "non-string label name": [{**valid, "labels": [{"name": True}]}],
        "duplicate label name": [
            {
                **valid,
                "labels": [
                    {"name": "state:needs-plan"},
                    {"name": "state:needs-plan"},
                ],
            }
        ],
    }
    original_gh = reg.gh
    accepted = []
    try:
        for label, payload in cases.items():
            reg.gh = lambda *_args, value=payload: json.dumps(value)
            try:
                reg.issue_inventory("Odysseus")
            except RuntimeError:
                continue
            accepted.append(label)
    finally:
        reg.gh = original_gh

    assert accepted == [], f"malformed issue inventory was accepted: {accepted}"


def test_issue_create_url_is_bound_to_the_expected_repository() -> None:
    """A success URL from another host or repository cannot become a receipt."""
    target = f"{reg.ORG}/Odysseus"
    assert (
        reg.issue_number_from_url(
            f"https://github.com/{target}/issues/17", expected_target=target
        )
        == 17
    )
    for hostile_url in (
        f"https://evil.example/{target}/issues/17",
        f"https://github.com/{reg.ORG}/Hermes/issues/17",
        f"https://github.com/{target}/issues/17?redirect=true",
    ):
        try:
            reg.issue_number_from_url(hostile_url, expected_target=target)
        except ValueError:
            pass
        else:  # pragma: no cover
            raise AssertionError(f"hostile issue receipt was accepted: {hostile_url}")


def test_github_boundary_uses_a_fixed_executable_and_scrubbed_environment() -> None:
    """Credential-bearing calls cannot inherit PATH, host, proxy, or hook routing."""
    observed = {}
    original_resolve = reg._resolve_gh_executable
    original_run = reg._run_gh_process
    hostile_environment = {
        "PATH": "/tmp/attacker",
        "GH_HOST": "evil.example",
        "HTTP_PROXY": "http://evil.example",
        "HTTPS_PROXY": "http://evil.example",
        "GIT_CONFIG_PARAMETERS": "'credential.helper'='!attack'",
    }
    saved = {name: os.environ.get(name) for name in hostile_environment}
    os.environ.update(hostile_environment)

    def fake_resolve():
        return Path("/verified/bin/gh")

    def fake_run(executable, args, environment):
        observed.update(
            executable=executable,
            args=args,
            environment=dict(environment),
        )
        return 0, b"[]\n", b""

    reg._resolve_gh_executable = fake_resolve
    reg._run_gh_process = fake_run
    try:
        assert reg.issue_inventory("Odysseus") == []
    finally:
        reg._resolve_gh_executable = original_resolve
        reg._run_gh_process = original_run
        for name, value in saved.items():
            if value is None:
                os.environ.pop(name, None)
            else:
                os.environ[name] = value

    assert observed["executable"] == Path("/verified/bin/gh")
    assert observed["args"][observed["args"].index("-R") + 1] == (
        f"github.com/{reg.ORG}/Odysseus"
    )
    environment = observed["environment"]
    assert environment["GH_HOST"] == "github.com"
    assert environment["GH_PROMPT_DISABLED"] == "1"
    assert environment["GH_PAGER"] == "cat"
    assert environment["PATH"] == "/usr/bin:/bin"
    assert "HTTP_PROXY" not in environment
    assert "HTTPS_PROXY" not in environment
    assert "GIT_CONFIG_PARAMETERS" not in environment


def test_github_timeout_is_truthful_and_cannot_reach_mutation() -> None:
    """A timed-out GitHub read fails instead of continuing into writes."""
    commands = []
    original_resolve = reg._resolve_gh_executable
    original_run = reg._run_gh_process

    def timeout_run(executable, args, environment):
        commands.append((str(executable), *args))
        raise TimeoutError

    reg._resolve_gh_executable = lambda: Path("/verified/bin/gh")
    reg._run_gh_process = timeout_run
    try:
        try:
            reg.issue_inventory("Odysseus")
        except RuntimeError as exc:
            assert f"timed out after {reg.COMMAND_TIMEOUT_SECONDS}s" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("a GitHub timeout must propagate truthfully")
    finally:
        reg._resolve_gh_executable = original_resolve
        reg._run_gh_process = original_run

    assert len(commands) == 1
    assert commands[0][:3] == ("/verified/bin/gh", "issue", "list")
    assert commands[0][commands[0].index("-R") + 1] == (
        f"github.com/{reg.ORG}/Odysseus"
    )
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


def test_run_gh_process_returns_exact_stdout_stderr_and_status() -> None:
    """The direct boundary preserves bounded output and the child status."""
    with tempfile.TemporaryDirectory() as temporary:
        executable = _write_gh_boundary_executable(
            Path(temporary),
            "gh-normal",
            """
            import os
            import sys

            os.write(1, f"out:{sys.argv[1]}:{os.environ['BOUND_VALUE']}".encode())
            os.write(2, f"err:{sys.argv[2]}".encode())
            raise SystemExit(7)
            """,
        )

        status, stdout, stderr = reg._run_gh_process(
            executable,
            ("first", "second"),
            {"BOUND_VALUE": "controlled", "LC_ALL": "C"},
        )

    assert status == 7
    assert stdout == b"out:first:controlled"
    assert stderr == b"err:second"


def test_pending_signal_acquisition_cleans_scope_before_propagation() -> None:
    """The spawn boundary owns cleanup across both acquisition signal windows."""
    original_scope = reg._LinuxProcessScope
    original_sealed = reg._sealed_executable
    original_popen = reg.subprocess.Popen
    original_identity = reg._gh_executable_identity
    original_sigmask = getattr(reg.signal, "pthread_sigmask", None)
    original_sigpending = getattr(reg.signal, "sigpending", None)
    expected_identity = (1,) * 9

    for phase, signal_number in (("pre", signal.SIGTERM), ("post", signal.SIGHUP)):
        pending = set()
        events = []
        stdout_read, stdout_write = os.pipe()
        stderr_read, stderr_write = os.pipe()
        os.close(stdout_write)
        os.close(stderr_write)

        class FakeStream:
            def __init__(self, descriptor):
                self._descriptor = descriptor
                self.closed = False

            def fileno(self):
                return self._descriptor

            def close(self):
                if not self.closed:
                    os.close(self._descriptor)
                    self.closed = True

        class FakeProcess:
            pid = 4242
            stdout = FakeStream(stdout_read)
            stderr = FakeStream(stderr_read)

            @staticmethod
            def wait(timeout=None):
                events.append(("wait", timeout))
                return 0

        class FakeScope:
            def __init__(self):
                events.append("scope")

            @staticmethod
            def track_root(process_id):
                events.append(("track", process_id))
                if phase == "post":
                    pending.add(signal_number)
                return 99

            @staticmethod
            def leader_exited(_descriptor):
                return True

            @staticmethod
            def live_descendants(_leader):
                return ()

            @staticmethod
            def discover():
                return False

            @staticmethod
            def reap_adopted(_leader):
                events.append("reap")

            @staticmethod
            def terminate(_process, _grace):
                events.append("terminate")

            @staticmethod
            def close():
                events.append("close")

        @contextmanager
        def fake_sealed(_executable, _expected, _label):
            yield "/sealed/executable", ()

        def fake_popen(*_args, **_kwargs):
            events.append("popen")
            if phase == "pre":
                pending.add(signal_number)
            return FakeProcess()

        def fake_sigmask(operation, signals):
            events.append(("sigmask", operation, frozenset(signals)))
            return frozenset()

        reg._LinuxProcessScope = FakeScope
        reg._sealed_executable = fake_sealed
        reg.subprocess.Popen = fake_popen
        reg._gh_executable_identity = lambda _path: expected_identity
        reg.signal.pthread_sigmask = fake_sigmask
        reg.signal.sigpending = lambda: frozenset(pending)
        try:
            try:
                reg._run_linux_bound_process(
                    Path("/verified/bin/gh"),
                    expected_identity,
                    ("/verified/bin/gh", "api"),
                    {"LC_ALL": "C"},
                    deadline_ns=time.monotonic_ns() + 1_000_000_000,
                    output_limit=4096,
                    termination_grace=0.05,
                    label="gh",
                )
            except BaseException as exc:
                assert getattr(exc, "signal_number", None) == signal_number
            else:  # pragma: no cover
                raise AssertionError(f"{phase}-track signal was not propagated")
        finally:
            reg._gh_executable_identity = original_identity
            reg.subprocess.Popen = original_popen
            reg._sealed_executable = original_sealed
            reg._LinuxProcessScope = original_scope
            if original_sigpending is None:
                del reg.signal.sigpending
            else:
                reg.signal.sigpending = original_sigpending
            if original_sigmask is None:
                del reg.signal.pthread_sigmask
            else:
                reg.signal.pthread_sigmask = original_sigmask

        assert events.index("popen") < events.index("terminate")
        assert events.index("terminate") < events.index("close")
        assert events[0][0] == "sigmask"


def test_term_and_hup_during_process_acquisition_extinguish_owned_trees() -> None:
    """Signals before and after root binding cannot orphan an owned process tree."""
    _require_linux()
    cases = (("pre", signal.SIGTERM), ("post", signal.SIGHUP))
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        executable = _write_gh_boundary_executable(
            directory,
            "gh-signal-tree",
            """
            import os
            import signal
            import sys
            import time
            from pathlib import Path

            def identity(process_id):
                content = Path(f"/proc/{process_id}/stat").read_bytes()
                closing = content.rfind(b")")
                return int(content[closing + 2:].split()[19])

            identity_path = Path(sys.argv[1])
            heartbeat = Path(sys.argv[2])
            child = os.fork()
            if child == 0:
                os.setsid()
                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                signal.signal(signal.SIGHUP, signal.SIG_IGN)
                os.close(1)
                os.close(2)
                count = 0
                while True:
                    heartbeat.write_text(str(count), encoding="ascii")
                    count += 1
                    time.sleep(0.01)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            signal.signal(signal.SIGHUP, signal.SIG_IGN)
            identity_path.write_text(
                f"{os.getpid()} {identity(os.getpid())} {child} {identity(child)}",
                encoding="ascii",
            )
            os.close(1)
            os.close(2)
            while True:
                time.sleep(1)
            """,
        )

        for phase, signal_number in cases:
            identity_path = directory / f"{phase}.identity"
            heartbeat = directory / f"{phase}.heartbeat"
            ready = directory / f"{phase}.ready"
            worker = directory / f"{phase}-worker.py"
            worker.write_text(
                textwrap.dedent(
                    f"""
                    import importlib.util
                    import signal
                    import sys
                    import time
                    from pathlib import Path

                    tool_path = Path({str(_TOOL_PATH)!r})
                    spec = importlib.util.spec_from_file_location(
                        "registrar_signal_{phase}", tool_path
                    )
                    module = importlib.util.module_from_spec(spec)
                    sys.modules[spec.name] = module
                    spec.loader.exec_module(module)
                    original_track = module._LinuxProcessScope.track_root
                    ready = Path({str(ready)!r})

                    def synchronized_track(scope, process_id):
                        if {phase!r} == "pre":
                            ready.write_text("pre", encoding="ascii")
                            deadline = time.monotonic() + 5
                            while not (
                                {{signal.SIGTERM, signal.SIGHUP}} & signal.sigpending()
                            ):
                                if time.monotonic() >= deadline:
                                    raise RuntimeError("pre-track signal did not arrive")
                                time.sleep(0.005)
                            return original_track(scope, process_id)
                        descriptor = original_track(scope, process_id)
                        ready.write_text("post", encoding="ascii")
                        return descriptor

                    module._LinuxProcessScope.track_root = synchronized_track
                    executable = Path({str(executable)!r})
                    module._run_linux_bound_process(
                        executable,
                        module._gh_executable_identity(executable),
                        (
                            str(executable),
                            {str(identity_path)!r},
                            {str(heartbeat)!r},
                        ),
                        {{"LC_ALL": "C"}},
                        deadline_ns=time.monotonic_ns() + 10_000_000_000,
                        output_limit=4096,
                        termination_grace=0.05,
                        label="gh",
                    )
                    """
                ).lstrip(),
                encoding="utf-8",
            )
            process = subprocess.Popen(
                (sys.executable, "-I", str(worker)),
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                start_new_session=True,
            )
            identities: tuple[int, int, int, int] | None = None
            try:
                deadline = time.monotonic() + 5
                while time.monotonic() < deadline:
                    if ready.exists() and identity_path.exists() and heartbeat.exists():
                        break
                    time.sleep(0.01)
                assert ready.exists(), f"{phase}: acquisition marker was not written"
                assert identity_path.exists(), f"{phase}: process tree was not started"
                identities = tuple(map(int, identity_path.read_text().split()))
                os.kill(process.pid, signal_number)
                process.wait(timeout=5)

                parent_pid, parent_start, child_pid, child_start = identities
                extinction_deadline = time.monotonic() + 2
                while time.monotonic() < extinction_deadline and any(
                    (
                        _linux_process_identity_is_active(parent_pid, parent_start),
                        _linux_process_identity_is_active(child_pid, child_start),
                    )
                ):
                    time.sleep(0.01)
                assert not _linux_process_identity_is_active(parent_pid, parent_start)
                assert not _linux_process_identity_is_active(child_pid, child_start)
                assert _heartbeat_stopped(heartbeat), (
                    f"{phase}: heartbeat continued after signal cleanup"
                )
                assert process.returncode == -signal_number
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait(timeout=2)
                if identities is not None:
                    for leaked_pid in (identities[0], identities[2]):
                        _kill_test_process(leaked_pid)


def test_run_gh_process_rejects_combined_output_overflow_from_each_stream() -> None:
    """Either output stream can exhaust the one combined byte budget."""
    original_limit = reg.GH_OUTPUT_LIMIT_BYTES
    reg.GH_OUTPUT_LIMIT_BYTES = 64
    try:
        for descriptor, stream_name in ((1, "stdout"), (2, "stderr")):
            with tempfile.TemporaryDirectory() as temporary:
                executable = _write_gh_boundary_executable(
                    Path(temporary),
                    f"gh-{stream_name}-overflow",
                    """
                    import os
                    import sys

                    os.write(int(sys.argv[1]), b"x" * 65)
                    """,
                )
                try:
                    reg._run_gh_process(executable, (str(descriptor),), {"LC_ALL": "C"})
                except RuntimeError as exc:
                    assert "gh output exceeded 64 bytes" in str(exc)
                else:  # pragma: no cover
                    raise AssertionError(f"{stream_name} overflow must be rejected")
    finally:
        reg.GH_OUTPUT_LIMIT_BYTES = original_limit


def test_run_gh_process_timeout_extinguishes_term_resistant_descendant() -> None:
    """A deadline kills the full session, including a TERM-resistant child."""
    original_timeout = reg.COMMAND_TIMEOUT_SECONDS
    original_grace = reg.GH_TERMINATION_GRACE_SECONDS
    reg.COMMAND_TIMEOUT_SECONDS = 1.0
    reg.GH_TERMINATION_GRACE_SECONDS = 0.05
    try:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            pid_path = directory / "pids"
            executable = _write_gh_boundary_executable(
                directory,
                "gh-timeout",
                """
                import os
                import signal
                import sys
                import time
                from pathlib import Path

                signal.signal(signal.SIGTERM, signal.SIG_IGN)
                child = os.fork()
                if child == 0:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    while True:
                        time.sleep(1)
                Path(sys.argv[1]).write_text(f"{os.getpid()} {child}")
                while True:
                    time.sleep(1)
                """,
            )
            try:
                reg._run_gh_process(executable, (str(pid_path),), {"LC_ALL": "C"})
            except TimeoutError:
                pass
            else:  # pragma: no cover
                raise AssertionError("the bounded process must time out")

            parent_pid, child_pid = map(int, pid_path.read_text().split())
            assert parent_pid != child_pid
            assert _wait_for_process_group_extinction(parent_pid), (
                "the timed-out process group survived cleanup"
            )
    finally:
        reg.COMMAND_TIMEOUT_SECONDS = original_timeout
        reg.GH_TERMINATION_GRACE_SECONDS = original_grace


def test_run_gh_process_rejects_and_extinguishes_surviving_descendant() -> None:
    """A successful leader cannot conceal a descendant that remains alive."""
    original_grace = reg.GH_TERMINATION_GRACE_SECONDS
    reg.GH_TERMINATION_GRACE_SECONDS = 0.05
    try:
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            pid_path = directory / "pids"
            executable = _write_gh_boundary_executable(
                directory,
                "gh-descendant",
                """
                import os
                import signal
                import sys
                import time
                from pathlib import Path

                child = os.fork()
                if child == 0:
                    signal.signal(signal.SIGTERM, signal.SIG_IGN)
                    os.close(1)
                    os.close(2)
                    while True:
                        time.sleep(1)
                Path(sys.argv[1]).write_text(f"{os.getpid()} {child}")
                """,
            )
            try:
                reg._run_gh_process(executable, (str(pid_path),), {"LC_ALL": "C"})
            except RuntimeError as exc:
                assert "gh left a descendant process running" in str(exc)
            else:  # pragma: no cover
                raise AssertionError("a surviving descendant must be rejected")

            parent_pid, child_pid = map(int, pid_path.read_text().split())
            assert parent_pid != child_pid
            assert _wait_for_process_group_extinction(parent_pid), (
                "the rejected descendant process group survived cleanup"
            )
    finally:
        reg.GH_TERMINATION_GRACE_SECONDS = original_grace


def test_run_gh_process_rejects_executable_identity_change_on_readback() -> None:
    """Replacing the executable during a call invalidates its result."""
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        executable = _write_gh_boundary_executable(
            directory,
            "gh-replaced",
            """
            import os
            import sys

            os.replace(sys.argv[1], sys.argv[2])
            os.write(1, b"untrusted success")
            """,
        )
        replacement = _write_gh_boundary_executable(
            directory,
            "replacement",
            """
            # replacement identity
            raise SystemExit(0)
            """,
        )
        before = executable.stat()

        try:
            reg._run_gh_process(
                executable,
                (str(replacement), str(executable)),
                {"LC_ALL": "C"},
            )
        except RuntimeError as exc:
            assert "approved gh executable changed during invocation" in str(exc)
        else:  # pragma: no cover
            raise AssertionError("an executable replacement must invalidate the result")

        after = executable.stat()
        assert (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino)
        assert "replacement identity" in executable.read_text()


def test_git_timeout_stops_before_github_access() -> None:
    """A timed-out source read cannot fall through to GitHub planning."""
    milestones = _load()
    github_calls = []
    runner_calls = []
    original_platform = reg.sys.platform
    original_resolve = reg._resolve_git_executable
    original_identity = reg._git_executable_identity
    original_runner = reg._run_linux_bound_process
    original_gh = reg.gh

    def timeout_runner(*args, **kwargs):
        runner_calls.append((args, kwargs))
        raise TimeoutError("test-forced Git deadline")

    reg.sys.platform = "linux"
    reg._resolve_git_executable = lambda: Path("/verified/bin/git")
    reg._git_executable_identity = lambda _path: (1,) * 9
    reg._run_linux_bound_process = timeout_runner
    reg.gh = lambda *args: github_calls.append(args) or TEST_SOURCE_SHA
    try:
        try:
            reg.verify_source_snapshot(milestones, TEST_SOURCE_SHA)
        except ValueError as exc:
            assert "immutable source commit is unavailable" in str(exc)
            assert isinstance(exc.__cause__, ValueError)
            assert f"timed out after {reg.COMMAND_TIMEOUT_SECONDS}s" in str(
                exc.__cause__
            )
            assert isinstance(exc.__cause__.__cause__, TimeoutError)
        else:  # pragma: no cover
            raise AssertionError("a Git timeout must stop source verification")
    finally:
        reg.gh = original_gh
        reg._run_linux_bound_process = original_runner
        reg._git_executable_identity = original_identity
        reg._resolve_git_executable = original_resolve
        reg.sys.platform = original_platform

    assert len(runner_calls) == 1
    assert runner_calls[0][1]["label"] == "Git"
    assert github_calls == []


def test_apply_verifies_every_selected_blob_before_github_access() -> None:
    """Payload or workflow drift from the selected commit stops apply."""
    _require_linux()
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


def test_git_boundary_ignores_hostile_path_and_fails_closed_without_containment() -> (
    None
):
    """Git source evidence never executes a PATH-selected program."""
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        marker = directory / "ambient-git-ran"
        hostile = _write_gh_boundary_executable(
            directory,
            "git",
            f"""
            from pathlib import Path

            Path({str(marker)!r}).write_text("executed", encoding="utf-8")
            print("hostile git")
            """,
        )
        trusted_directory = directory / "trusted"
        trusted_directory.mkdir()
        trusted = _write_gh_boundary_executable(
            trusted_directory,
            "git",
            """
            import os

            os.write(1, b"git version controlled\\n")
            """,
        )
        saved_path = os.environ.get("PATH")
        original_candidates = reg.GIT_EXECUTABLE_CANDIDATES
        os.environ["PATH"] = str(hostile.parent)
        reg.GIT_EXECUTABLE_CANDIDATES = (trusted,)
        try:
            if sys.platform.startswith("linux"):
                output = reg._git_bytes("--version")
                assert output.startswith(b"git version ")
            else:
                try:
                    reg._git_bytes("--version")
                except ValueError as exc:
                    assert "containment is unavailable" in str(exc)
                else:  # pragma: no cover
                    raise AssertionError(
                        "an unsupported host must fail before Git execution"
                    )
        finally:
            reg.GIT_EXECUTABLE_CANDIDATES = original_candidates
            if saved_path is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = saved_path

        assert not marker.exists(), "the PATH-selected Git executable ran"


def test_git_boundary_scrubs_ambient_repository_and_config_environment() -> None:
    """A trusted Git command receives no caller-selected repository or config."""
    _require_linux()
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        executable = _write_gh_boundary_executable(
            directory,
            "git",
            """
            import os
            import sys

            forbidden = {
                "GIT_ALTERNATE_OBJECT_DIRECTORIES",
                "GIT_CONFIG_COUNT",
                "GIT_CONFIG_PARAMETERS",
                "GIT_DIR",
                "GIT_OBJECT_DIRECTORY",
                "GIT_WORK_TREE",
                "HTTP_PROXY",
                "HTTPS_PROXY",
            }
            if forbidden & os.environ.keys():
                raise SystemExit(88)
            if os.environ.get("HOME") != "/dev/null":
                raise SystemExit(89)
            os.write(1, b"git version controlled\\n")
            """,
        )
        hostile = {
            "GIT_ALTERNATE_OBJECT_DIRECTORIES": str(directory / "objects"),
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "alias.cat-file",
            "GIT_CONFIG_PARAMETERS": "'credential.helper'='!attack'",
            "GIT_CONFIG_VALUE_0": "!attack",
            "GIT_DIR": str(directory / "repo"),
            "GIT_OBJECT_DIRECTORY": str(directory / "objects"),
            "GIT_WORK_TREE": str(directory / "worktree"),
            "HTTP_PROXY": "http://evil.example",
            "HTTPS_PROXY": "http://evil.example",
        }
        saved = {name: os.environ.get(name) for name in hostile}
        original_candidates = reg.GIT_EXECUTABLE_CANDIDATES
        os.environ.update(hostile)
        reg.GIT_EXECUTABLE_CANDIDATES = (executable,)
        try:
            assert reg._git_bytes("--version") == b"git version controlled\n"
        finally:
            reg.GIT_EXECUTABLE_CANDIDATES = original_candidates
            for name, value in saved.items():
                if value is None:
                    os.environ.pop(name, None)
                else:
                    os.environ[name] = value


def test_git_boundary_rejects_an_output_flood_without_buffering_it_all() -> None:
    """Git stdout and stderr share one fixed byte ceiling."""
    _require_linux()
    with tempfile.TemporaryDirectory() as temporary:
        executable = _write_gh_boundary_executable(
            Path(temporary),
            "git",
            """
            import os

            os.write(1, b"x" * (8 * 1024 * 1024 + 1))
            """,
        )
        original_candidates = reg.GIT_EXECUTABLE_CANDIDATES
        reg.GIT_EXECUTABLE_CANDIDATES = (executable,)
        try:
            try:
                reg._git_bytes("--version")
            except ValueError as exc:
                assert "output exceeded" in str(exc)
            else:  # pragma: no cover
                raise AssertionError("a Git output flood must be rejected")
        finally:
            reg.GIT_EXECUTABLE_CANDIDATES = original_candidates


def test_git_timeout_extinguishes_a_setsid_descendant_with_closed_pipes() -> None:
    """A Git timeout stops a detached heartbeat after its pipes close."""
    _require_linux()
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        pid_path = directory / "pid"
        heartbeat = directory / "heartbeat"
        executable = _write_gh_boundary_executable(
            directory,
            "git",
            """
            import os
            import signal
            import sys
            import time
            from pathlib import Path

            pid_path = Path(sys.argv[-2])
            heartbeat = Path(sys.argv[-1])
            child = os.fork()
            if child == 0:
                os.setsid()
                os.close(0)
                os.close(1)
                os.close(2)
                pid_path.write_text(str(os.getpid()), encoding="ascii")
                count = 0
                while True:
                    heartbeat.write_text(str(count), encoding="ascii")
                    count += 1
                    time.sleep(0.01)
            signal.signal(signal.SIGTERM, signal.SIG_IGN)
            while True:
                time.sleep(1)
            """,
        )
        original_candidates = reg.GIT_EXECUTABLE_CANDIDATES
        original_timeout = reg.COMMAND_TIMEOUT_SECONDS
        reg.GIT_EXECUTABLE_CANDIDATES = (executable,)
        reg.COMMAND_TIMEOUT_SECONDS = 1.0
        leaked_pid = None
        try:
            try:
                reg._git_bytes("--version", str(pid_path), str(heartbeat))
            except ValueError as exc:
                assert "timed out" in str(exc), str(exc)
            else:  # pragma: no cover
                raise AssertionError("a hanging Git command must time out")
            leaked_pid = int(pid_path.read_text(encoding="ascii"))
            assert _heartbeat_stopped(heartbeat), (
                "the detached Git descendant continued after timeout"
            )
        finally:
            reg.COMMAND_TIMEOUT_SECONDS = original_timeout
            reg.GIT_EXECUTABLE_CANDIDATES = original_candidates
            if leaked_pid is None and pid_path.exists():
                leaked_pid = int(pid_path.read_text(encoding="ascii"))
            if leaked_pid is not None:
                _kill_test_process(leaked_pid)


def test_gh_success_rejects_and_extinguishes_a_setsid_closed_pipe_descendant() -> None:
    """A successful gh leader cannot leave a detached heartbeat alive."""
    _require_linux()
    with tempfile.TemporaryDirectory() as temporary:
        directory = Path(temporary)
        pid_path = directory / "pid"
        heartbeat = directory / "heartbeat"
        executable = _write_gh_boundary_executable(
            directory,
            "gh-detached",
            """
            import os
            import sys
            import time
            from pathlib import Path

            if os.environ.get("GH_TOKEN") != "odysseus-test-placeholder":
                raise SystemExit(91)
            pid_path = Path(sys.argv[-2])
            heartbeat = Path(sys.argv[-1])
            child = os.fork()
            if child == 0:
                os.setsid()
                os.close(0)
                os.close(1)
                os.close(2)
                pid_path.write_text(str(os.getpid()), encoding="ascii")
                count = 0
                while True:
                    heartbeat.write_text(str(count), encoding="ascii")
                    count += 1
                    time.sleep(0.01)
            """,
        )
        leaked_pid = None
        try:
            try:
                reg._run_gh_process(
                    executable,
                    (str(pid_path), str(heartbeat)),
                    {
                        "GH_TOKEN": "odysseus-test-placeholder",
                        "LC_ALL": "C",
                    },
                )
            except RuntimeError as exc:
                assert "descendant process" in str(exc)
            else:  # pragma: no cover
                raise AssertionError("a detached gh descendant must be rejected")
            leaked_pid = int(pid_path.read_text(encoding="ascii"))
            assert _heartbeat_stopped(heartbeat), (
                "the detached gh descendant continued after leader success"
            )
        finally:
            if leaked_pid is None and pid_path.exists():
                leaked_pid = int(pid_path.read_text(encoding="ascii"))
            if leaked_pid is not None:
                _kill_test_process(leaked_pid)


def test_source_verification_accepts_only_exact_committed_blobs() -> None:
    """A full commit SHA verifies the exact parsed payload and workflow bytes."""
    _require_linux()
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


def test_source_verification_binds_canonical_blob_ids_without_local_remote_config() -> (
    None
):
    """Canonical GitHub identity and exact selected blob IDs authorize content."""
    milestones = _load()
    source_sha = "a" * 40
    payload_paths = sorted(milestone.payload_path for milestone in milestones)
    selected_paths = sorted(
        {
            path
            for milestone in milestones
            for path in (milestone.payload_path, milestone.workflow)
        }
    )
    contents = {path: (reg.REPO_ROOT / path).read_bytes() for path in selected_paths}
    object_ids = {
        path: hashlib.sha1(
            f"blob {len(content)}\0".encode("ascii") + content,
            usedforsecurity=False,
        ).hexdigest()
        for path, content in contents.items()
    }
    calls = []
    original_git = reg._git_bytes
    original_gh = reg.gh

    def fake_git(*args):
        calls.append(args)
        if args == ("cat-file", "-t", source_sha):
            return b"commit\n"
        if args[:5] == (
            "ls-tree",
            "-r",
            "-z",
            "--name-only",
            source_sha,
        ):
            return b"\0".join(path.encode("utf-8") for path in payload_paths) + b"\0"
        if args[:4] == (
            "ls-tree",
            "-z",
            "--format=%(objecttype) %(objectname)%x09%(path)",
            source_sha,
        ):
            return b"".join(
                b"blob "
                + object_ids[path].encode("ascii")
                + b"\t"
                + path.encode("utf-8")
                + b"\0"
                for path in selected_paths
            )
        if args[:2] == ("cat-file", "blob") and args[2] in object_ids.values():
            path = next(path for path, oid in object_ids.items() if oid == args[2])
            return contents[path]
        if args and args[0] == "ls-remote":  # pragma: no cover - RED assertion
            raise AssertionError(
                "source verification consulted mutable local remote config"
            )
        raise AssertionError(f"unexpected Git evidence request: {args!r}")

    reg._git_bytes = fake_git
    reg.gh = lambda *args: source_sha
    try:
        assert reg.verify_source_snapshot(milestones, source_sha) == source_sha
    finally:
        reg.gh = original_gh
        reg._git_bytes = original_git

    assert not any(args and args[0] == "ls-remote" for args in calls)
    assert {args[2] for args in calls if args[:2] == ("cat-file", "blob")} == set(
        object_ids.values()
    )


def test_source_verification_rejects_noncanonical_remote_head() -> None:
    """A matching local origin cannot impersonate canonical GitHub main."""
    _require_linux()
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
    _require_linux()
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
    _require_linux()
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
    _require_linux()
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
        original_gh = isolated.gh
        isolated.gh = lambda *args: published_sha
        try:
            try:
                isolated.verify_source_snapshot(milestones, source_sha)
            except ValueError as exc:
                assert "canonical GitHub main" in str(exc)
                assert published_sha in str(exc)
                assert source_sha in str(exc)
            else:  # pragma: no cover
                raise AssertionError("an unpublished commit must be rejected")
        finally:
            isolated.gh = original_gh


def test_registration_resumes_exact_historical_bodies_after_unrelated_main_change() -> (
    None
):
    """A later stage accepts exact A-bound bodies when selected blobs match B."""
    _require_linux()
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
    _require_linux()
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
        test_libc_pidfds_work_without_python_pidfd_bindings,
        test_process_scope_rescans_after_a_scanned_child_forks_then_exits,
        test_tool_symlink_invocation_is_rejected,
        test_executable_entry_rejects_python_startup_and_loader_authority,
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
        test_yaml_duplicate_keys_are_rejected_at_each_authored_level,
        test_payload_inventory_and_yaml_source_bytes_have_hard_ceilings,
        test_yaml_alias_depth_node_and_string_budgets_apply_to_all_sources,
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
        test_plan_and_apply_reject_unexecutable_write_arguments_before_mutation,
        test_github_argument_and_field_limits_reject_before_execution,
        test_oversized_issue_body_stops_before_digest_lock_or_mutation,
        test_apply_requires_explicit_immutable_source_sha,
        test_check_mode_is_offline,
        test_github_arguments_are_pinned_to_the_canonical_host_and_repository,
        test_issue_inventory_rejects_malformed_identifiers_and_schema,
        test_issue_create_url_is_bound_to_the_expected_repository,
        test_github_boundary_uses_a_fixed_executable_and_scrubbed_environment,
        test_github_timeout_is_truthful_and_cannot_reach_mutation,
        test_run_gh_process_returns_exact_stdout_stderr_and_status,
        test_pending_signal_acquisition_cleans_scope_before_propagation,
        test_term_and_hup_during_process_acquisition_extinguish_owned_trees,
        test_run_gh_process_rejects_combined_output_overflow_from_each_stream,
        test_run_gh_process_timeout_extinguishes_term_resistant_descendant,
        test_run_gh_process_rejects_and_extinguishes_surviving_descendant,
        test_run_gh_process_rejects_executable_identity_change_on_readback,
        test_git_timeout_stops_before_github_access,
        test_git_boundary_ignores_hostile_path_and_fails_closed_without_containment,
        test_git_boundary_scrubs_ambient_repository_and_config_environment,
        test_git_boundary_rejects_an_output_flood_without_buffering_it_all,
        test_git_timeout_extinguishes_a_setsid_descendant_with_closed_pipes,
        test_gh_success_rejects_and_extinguishes_a_setsid_closed_pipe_descendant,
        test_apply_verifies_every_selected_blob_before_github_access,
        test_source_verification_accepts_only_exact_committed_blobs,
        test_source_verification_binds_canonical_blob_ids_without_local_remote_config,
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
        except unittest.SkipTest as exc:
            print(f"SKIP {check.__name__}: {exc}")
        except AssertionError as exc:
            print(f"FAIL {check.__name__}: {exc}")
            failed += 1
        else:
            print(f"ok   {check.__name__}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
