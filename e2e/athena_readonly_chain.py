#!/usr/bin/env python3
"""Verify one live Athena review chain without exposing delivery mutations.

This compatibility adapter is intentionally pinned to Athena 0.5.3.  It loads
only the audited implementation, wraps the live forge in a read-only facade,
and calls the review-chain verifier without constructing or invoking any
delivery operation. Histories needing external anchor annexes or historical
proof files fail closed; the ADR-020 mesh owns their future orchestration.
"""

from __future__ import annotations

import argparse
import contextlib
import copy
import ctypes
import hashlib
import io
import importlib.abc
import importlib.util
import json
import math
import os
import re
import resource
import selectors
import signal
import stat
import subprocess
import sys
import sysconfig
import threading
import time
import traceback
from pathlib import Path
from typing import Any


SCHEMA_ID = "odysseus.athena-readonly-chain-proof"
COMMIT_OID = re.compile(r"[0-9a-f]{40}")
STATE_DIGEST = re.compile(r"[0-9a-f]{64}")
ATHENA_RELEASE_VERSION = "0.5.3"
ATHENA_RELEASE_COMMIT = "8c72148529a38efb4dd97e8e78c1b2193d852403"
ATHENA_RELEASE_SOURCE = "https://github.com/HomericIntelligence/Athena.git"
PLUGIN_MANIFEST = ".codex-plugin/plugin.json"
INSTALL_MANIFEST = ".codex-marketplace-install.json"
PLUGIN_MANIFEST_SHA256 = (
    "dd4c5f7eccbc919d34936f8514ba0de5acf37f46ab3432a7058b2750dab319f5"
)
INSTALL_MANIFEST_SHA256 = (
    "1d1d0d693dc4b93b688ebb6463a636fa5008d52703f4616661373d86b4d1eead"
)
EXPECTED_HELPERS = {
    "skills/pr-review/scripts/resolve_pr.py": (
        "978b71a2c79b1fe4a66489c899876403d7ef3d79b589f9128499772e97cb5222"
    ),
    "skills/pr-review/scripts/collect_evidence.py": (
        "961f1af29296763fb1f0297d9dcf873001f0008a93dfcd4a2bf2044c049777a0"
    ),
    "skills/pr-review/scripts/deliver_go.py": (
        "6c12b7c953980ec703e154d8f98989fb2fb1d155f61584768f0ad70c174cfa06"
    ),
    "skills/pr-review/scripts/anchor_proofs.py": (
        "388b1d167bc3eb44ffcd07cc50ec0f6f19f0e6ab4f309d3bd8d0c0c8491975d1"
    ),
    "skills/pr-review/scripts/pr_identity.py": (
        "274f6fff920f5a8d970a8018e3c8cee7d93af26e9aea3fa869e78cbeb32a5a3a"
    ),
    "skills/pr-review/scripts/materialize_snapshot.py": (
        "f560d2ef785bb1a8fd604373e65268cdfaeb1d3360778dfe73bc83dce45e37f2"
    ),
    "skills/review-exchange/scripts/review_exchange.py": (
        "7f6db45e9d4e9364441c0ac8f3c9ab303b165fd9ac8cd54fbdca6585dad0d693"
    ),
    "skills/_cli.py": (
        "80e6189d94f7e7f0d7cc32d57d3e0d1cb11093fb2aed30209624c5939cf2d7d9"
    ),
}
MAX_GH_EXECUTABLE_BYTES = 256 * 1024 * 1024
MAX_GH_STDOUT_BYTES = 16 * 1024 * 1024
MAX_GH_STDERR_BYTES = 64 * 1024
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 100_000
MAX_JSON_NUMBER_CHARACTERS = 128
MAX_JSON_STRING_BYTES = 1024 * 1024
MAX_JSON_TOTAL_STRING_BYTES = 8 * 1024 * 1024
GH_READ_CHUNK_BYTES = 64 * 1024
GH_COMMAND_TIMEOUT_SECONDS = 180.0
GH_TERMINATE_SECONDS = 0.25
GH_REAP_SECONDS = 2.0
GH_MAX_ADDRESS_SPACE_BYTES = 2 * 1024 * 1024 * 1024
CHAIN_DEADLINE_ENV = "ODYSSEUS_ATHENA_CHAIN_DEADLINE_MONOTONIC"

_GH_EXEC_SUPERVISOR = """
import os
import resource
import sys

descriptor = int(sys.argv[1])
address_space = int(sys.argv[2])
cpu_seconds = int(sys.argv[3])
resource.setrlimit(resource.RLIMIT_AS, (address_space, address_space))
resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds))
target = f"/proc/self/fd/{descriptor}"
os.execve(target, [target, *sys.argv[4:]], dict(os.environ))
"""


class VerificationError(RuntimeError):
    """The live review cannot be proven safe for terminal delivery."""


def _scan_json_resource_bounds(payload: str, context: str) -> None:
    """Reject excessive JSON structure before the decoder allocates it."""
    if len(payload) > MAX_GH_STDOUT_BYTES:
        raise VerificationError(f"{context} exceeds JSON resource bounds")
    depth = 0
    nodes = 0
    string_bytes = 0
    in_string = False
    escaped = False
    current_string_bytes = 0
    string_start = 0
    containers: list[tuple[set[str] | None, bool]] = []
    index = 0
    length = len(payload)
    while index < length:
        character = payload[index]
        if in_string:
            # Count the encoded token conservatively, including escapes, before
            # allocating even one decoded string.
            if character != '"' or escaped:
                current_string_bytes += len(character.encode("utf-8"))
            if current_string_bytes > MAX_JSON_STRING_BYTES:
                raise VerificationError(f"{context} exceeds JSON resource bounds")
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                in_string = False
                nodes += 1
                string_bytes += current_string_bytes
                if (
                    current_string_bytes > MAX_JSON_STRING_BYTES
                    or string_bytes > MAX_JSON_TOTAL_STRING_BYTES
                    or nodes > MAX_JSON_NODES
                ):
                    raise VerificationError(
                        f"{context} exceeds JSON resource bounds"
                    )
                current_string_bytes = 0
                if containers and containers[-1][0] is not None and containers[-1][1]:
                    try:
                        key, _end = json.decoder.scanstring(payload, string_start)
                    except (ValueError, UnicodeError) as exc:
                        raise VerificationError(f"{context} is not valid JSON") from exc
                    keys = containers[-1][0]
                    if key in keys:
                        raise VerificationError(f"{context} has duplicate JSON keys")
                    keys.add(key)
            index += 1
            continue
        if character == '"':
            in_string = True
            string_start = index + 1
            index += 1
            continue
        if character in "[{":
            containers.append((set(), True) if character == "{" else (None, False))
            depth += 1
            nodes += 1
            if depth > MAX_JSON_DEPTH or nodes > MAX_JSON_NODES:
                raise VerificationError(f"{context} exceeds JSON resource bounds")
            index += 1
            continue
        if character in "]}":
            if containers:
                containers.pop()
            depth -= 1
            index += 1
            continue
        if character in ":," and containers:
            keys, _expect_key = containers[-1]
            containers[-1] = (keys, character == ",")
        if character == "-" or character.isdigit():
            end = index + 1
            digits = int(character.isdigit())
            while end < length and payload[end] not in " \t\r\n,]}":
                digits += int(payload[end].isdigit())
                end += 1
            nodes += 1
            if digits > MAX_JSON_NUMBER_CHARACTERS or nodes > MAX_JSON_NODES:
                raise VerificationError(f"{context} exceeds JSON resource bounds")
            index = end
            continue
        matched_literal = next(
            (
                literal
                for literal in ("true", "false", "null")
                if payload.startswith(literal, index)
            ),
            None,
        )
        if matched_literal is not None:
            nodes += 1
            if nodes > MAX_JSON_NODES:
                raise VerificationError(f"{context} exceeds JSON resource bounds")
            index += len(matched_literal)
            continue
        index += 1


def _load_json(payload: str, context: str) -> object:
    """Decode one bounded JSON value and normalize all evidence errors."""
    if not isinstance(payload, str):
        raise VerificationError(f"{context} is not valid JSON")
    _scan_json_resource_bounds(payload, context)

    def bounded_integer(value: str) -> int:
        if sum(character.isdigit() for character in value) > MAX_JSON_NUMBER_CHARACTERS:
            raise VerificationError(f"{context} exceeds JSON resource bounds")
        return int(value)

    def bounded_float(value: str) -> float:
        if sum(character.isdigit() for character in value) > MAX_JSON_NUMBER_CHARACTERS:
            raise VerificationError(f"{context} exceeds JSON resource bounds")
        result = float(value)
        if not math.isfinite(result):
            raise VerificationError(f"{context} exceeds JSON resource bounds")
        return result

    try:
        value = json.loads(
            payload,
            object_pairs_hook=_unique_object,
            parse_int=bounded_integer,
            parse_float=bounded_float,
            parse_constant=lambda _value: (_ for _ in ()).throw(
                VerificationError(f"{context} exceeds JSON resource bounds")
            ),
        )
    except VerificationError:
        raise
    except (json.JSONDecodeError, RecursionError, UnicodeError, ValueError) as exc:
        raise VerificationError(f"{context} is not valid JSON") from exc

    pending = [(value, 1)]
    nodes = 0
    string_bytes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        if depth > MAX_JSON_DEPTH or nodes > MAX_JSON_NODES:
            raise VerificationError(f"{context} exceeds JSON resource bounds")
        if isinstance(current, dict):
            for key, item in current.items():
                encoded = key.encode("utf-8")
                if len(encoded) > MAX_JSON_STRING_BYTES:
                    raise VerificationError(
                        f"{context} exceeds JSON resource bounds"
                    )
                string_bytes += len(encoded)
                pending.append((item, depth + 1))
        elif isinstance(current, list):
            pending.extend((item, depth + 1) for item in current)
        elif isinstance(current, str):
            encoded = current.encode("utf-8")
            if len(encoded) > MAX_JSON_STRING_BYTES:
                raise VerificationError(f"{context} exceeds JSON resource bounds")
            string_bytes += len(encoded)
        if string_bytes > MAX_JSON_TOTAL_STRING_BYTES:
            raise VerificationError(f"{context} exceeds JSON resource bounds")
    return value


def _bounded_json_text(payload: str, context: str) -> str:
    """Return canonical JSON after bounded validation."""
    value = _load_json(payload, context)
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, UnicodeError, ValueError) as exc:
        raise VerificationError(f"{context} is not valid JSON") from exc


def _verify_inherited_tool_descriptor(
    descriptor: int, digest_variable: str, label: str
) -> None:
    """Verify one inherited tool is the exact sealed snapshot promised."""
    expected_digest = os.environ.get(digest_variable, "")
    if STATE_DIGEST.fullmatch(expected_digest) is None:
        raise VerificationError(f"the trusted {label} digest is malformed")
    if sys.platform != "linux" or not os.path.isdir("/proc/self/fd"):
        raise VerificationError(
            f"sealed descriptor-bound {label} execution is unavailable"
        )
    try:
        import fcntl

        required_seals = (
            fcntl.F_SEAL_WRITE
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_SEAL
        )
        seals = fcntl.fcntl(descriptor, fcntl.F_GET_SEALS)
        before = os.fstat(descriptor)
    except (AttributeError, ImportError, OSError) as exc:
        raise VerificationError(
            f"the trusted {label} sealed binding is unavailable"
        ) from exc
    if (
        seals & required_seals != required_seals
        or not stat.S_ISREG(before.st_mode)
        or before.st_uid not in {0, os.geteuid()}
        or before.st_mode & 0o022
        or before.st_mode & 0o111 == 0
        or before.st_size <= 0
        or before.st_size > MAX_GH_EXECUTABLE_BYTES
    ):
        raise VerificationError(f"the trusted {label} sealed binding is unsafe")
    digest = hashlib.sha256()
    offset = 0
    try:
        while offset < before.st_size:
            chunk = os.pread(
                descriptor,
                min(GH_READ_CHUNK_BYTES, before.st_size - offset),
                offset,
            )
            if not chunk:
                raise VerificationError(
                    f"the trusted {label} sealed binding is incomplete"
                )
            digest.update(chunk)
            offset += len(chunk)
        after = os.fstat(descriptor)
    except OSError as exc:
        raise VerificationError(
            f"the trusted {label} sealed binding cannot be read"
        ) from exc
    def identity(value: os.stat_result) -> tuple[int, ...]:
        return (
            value.st_dev,
            value.st_ino,
            value.st_mode,
            value.st_uid,
            value.st_nlink,
            value.st_size,
        )
    if identity(after) != identity(before) or digest.hexdigest() != expected_digest:
        raise VerificationError(f"the trusted {label} digest changed")


def _verify_inherited_gh_descriptor(descriptor: int) -> None:
    _verify_inherited_tool_descriptor(
        descriptor, "ODYSSEUS_GH_EXECUTABLE_SHA256", "GitHub CLI"
    )


def _independent_owner(user_id: int) -> bool:
    """Return whether a host object is outside the contained target identity."""
    target_user = os.geteuid()
    return target_user != 0 and user_id != target_user


def _secure_independent_ancestry(path: str) -> bool:
    parent = os.path.dirname(path)
    while True:
        try:
            metadata = os.stat(parent, follow_symlinks=False)
        except OSError:
            return False
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or not _independent_owner(metadata.st_uid)
            or metadata.st_mode & 0o022
        ):
            return False
        next_parent = os.path.dirname(parent)
        if next_parent == parent:
            return True
        parent = next_parent


def _verify_python_dependency_closure() -> None:
    roots: set[str] = set()
    for key in ("stdlib", "platstdlib"):
        root = sysconfig.get_paths().get(key)
        if not isinstance(root, str) or not root:
            raise VerificationError("the Python dependency closure is unavailable")
        canonical = os.path.realpath(root)
        try:
            metadata = os.stat(canonical, follow_symlinks=False)
        except OSError as exc:
            raise VerificationError(
                "the Python dependency closure is unavailable"
            ) from exc
        if (
            not stat.S_ISDIR(metadata.st_mode)
            or not _independent_owner(metadata.st_uid)
            or metadata.st_mode & 0o022
            or not _secure_independent_ancestry(
                os.path.join(canonical, "anchor")
            )
        ):
            raise VerificationError("the Python dependency closure is unsafe")
        roots.add(canonical)
    required_modules = (ctypes, resource, traceback)
    module_paths: set[str] = set()
    for module in (*tuple(sys.modules.values()), *required_modules):
        for attribute in ("__file__", "__cached__"):
            path = getattr(module, attribute, None)
            if (
                not isinstance(path, str)
                or (attribute == "__cached__" and not os.path.lexists(path))
            ):
                continue
            canonical = os.path.realpath(path)
            if any(
                os.path.commonpath((root, canonical)) == root
                for root in roots
            ):
                module_paths.add(canonical)
    for path in module_paths:
        try:
            metadata = os.stat(path, follow_symlinks=False)
        except OSError as exc:
            raise VerificationError(
                "the Python dependency closure is unavailable"
            ) from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or not _independent_owner(metadata.st_uid)
            or metadata.st_mode & 0o022
            or not _secure_independent_ancestry(path)
        ):
            raise VerificationError("the Python dependency closure is unsafe")
    try:
        with open("/proc/self/maps", "r", encoding="utf-8") as stream:
            mappings = stream.read(8 * 1024 * 1024 + 1)
    except (OSError, UnicodeError) as exc:
        raise VerificationError("the Python dependency closure is unavailable") from exc
    if len(mappings.encode("utf-8")) > 8 * 1024 * 1024:
        raise VerificationError("the Python dependency closure is too large")
    dependencies = {
        fields[-1].removesuffix(" (deleted)")
        for line in mappings.splitlines()
        if len(fields := line.split(maxsplit=5)) == 6
        and fields[-1].startswith("/")
        and ".so" in fields[-1]
    }
    for dependency in dependencies:
        canonical = os.path.realpath(dependency)
        try:
            metadata = os.stat(canonical, follow_symlinks=False)
        except OSError as exc:
            raise VerificationError(
                "the Python dependency closure is unavailable"
            ) from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or not _independent_owner(metadata.st_uid)
            or metadata.st_mode & 0o022
            or not _secure_independent_ancestry(canonical)
        ):
            raise VerificationError("the Python dependency closure is unsafe")


def _verify_inherited_python_descriptor(descriptor: int) -> None:
    expected_digest = os.environ.get("ODYSSEUS_PYTHON_EXECUTABLE_SHA256", "")
    if STATE_DIGEST.fullmatch(expected_digest) is None:
        raise VerificationError("the trusted Python digest is malformed")
    if sys.platform != "linux" or not os.path.isdir("/proc/self/fd"):
        raise VerificationError("descriptor-bound Python execution is unavailable")
    try:
        metadata = os.fstat(descriptor)
        source = os.path.realpath(os.readlink(f"/proc/self/fd/{descriptor}"))
    except OSError as exc:
        raise VerificationError("the trusted Python binding is unavailable") from exc
    if (
        not stat.S_ISREG(metadata.st_mode)
        or not _independent_owner(metadata.st_uid)
        or metadata.st_mode & 0o022
        or metadata.st_mode & 0o111 == 0
        or not _secure_independent_ancestry(source)
    ):
        raise VerificationError("the trusted Python binding is unsafe")
    digest = hashlib.sha256()
    offset = 0
    try:
        while offset < metadata.st_size:
            chunk = os.pread(
                descriptor,
                min(GH_READ_CHUNK_BYTES, metadata.st_size - offset),
                offset,
            )
            if not chunk:
                raise VerificationError("the trusted Python binding is incomplete")
            digest.update(chunk)
            offset += len(chunk)
    except OSError as exc:
        raise VerificationError("the trusted Python binding cannot be read") from exc
    if digest.hexdigest() != expected_digest:
        raise VerificationError("the trusted Python digest changed")
    _verify_python_dependency_closure()


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _gh_leader_exited(process: subprocess.Popen) -> bool:
    """Observe the exact child without releasing its PID/PGID reservation."""
    if process.returncode is not None:
        raise VerificationError("the GitHub CLI leader authority was already reaped")
    try:
        status = os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
    except (AttributeError, ChildProcessError, OSError) as exc:
        raise VerificationError("the GitHub CLI leader authority is unavailable") from exc
    return status is not None and status.si_pid == process.pid


def _gh_group_is_extinct(process_group: int) -> bool:
    """Inventory a retained Linux group; only absent/zombie members are extinct."""
    if sys.platform != "linux":
        raise VerificationError("GitHub CLI group extinction requires Linux")
    observed = 0
    try:
        with os.scandir("/proc") as entries:
            for entry in entries:
                if not entry.name.isdecimal():
                    continue
                observed += 1
                if observed > 65536:
                    raise VerificationError("the GitHub CLI task inventory exceeds its bound")
                try:
                    with open(f"/proc/{entry.name}/stat", "rb") as source:
                        raw = source.read(8193)
                except FileNotFoundError:
                    continue
                if len(raw) > 8192 or b") " not in raw:
                    raise VerificationError("the GitHub CLI task identity is malformed")
                fields = raw.rsplit(b") ", 1)[1].split()
                if len(fields) < 20:
                    raise VerificationError("the GitHub CLI task identity is incomplete")
                if int(fields[2]) == process_group and fields[0] not in {b"Z", b"X"}:
                    return False
    except (OSError, ValueError) as exc:
        raise VerificationError("the GitHub CLI task inventory is unproven") from exc
    return True


def _stop_gh_process_group(process: subprocess.Popen) -> None:
    """Prove extinction before the sole reap; never reuse a reaped numeric ID."""
    _gh_leader_exited(process)
    for number in (signal.SIGTERM, signal.SIGKILL):
        _gh_leader_exited(process)
        try:
            os.killpg(process.pid, number)
        except ProcessLookupError:
            pass
        except OSError as exc:
            raise VerificationError("the GitHub CLI group cannot be signaled") from exc
    deadline = time.monotonic() + GH_REAP_SECONDS
    while True:
        _gh_leader_exited(process)
        if _gh_group_is_extinct(process.pid):
            break
        if time.monotonic() >= deadline:
            raise VerificationError("the GitHub CLI process group remained active")
        time.sleep(0.01)
    # No numeric group query or signal is permitted after this point.
    process.wait(timeout=GH_REAP_SECONDS)


def _gh_resource_limits() -> None:
    """Apply hard child-only memory, CPU, and core-file ceilings."""
    try:
        import resource

        resource.setrlimit(
            resource.RLIMIT_AS,
            (GH_MAX_ADDRESS_SPACE_BYTES, GH_MAX_ADDRESS_SPACE_BYTES),
        )
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        cpu_seconds = max(1, int(GH_COMMAND_TIMEOUT_SECONDS) + 1)
        resource.setrlimit(resource.RLIMIT_CPU, (cpu_seconds, cpu_seconds))
    except (AttributeError, ImportError, OSError, ValueError) as exc:
        raise VerificationError("GitHub CLI resource limits are unavailable") from exc


def _gh_environment() -> dict[str, str]:
    """Retain only the fixed GitHub authority inherited from the outer adapter."""
    environment = {
        "GH_HOST": "github.com",
        "GH_PROMPT_DISABLED": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "NO_PROXY": "*",
        "no_proxy": "*",
        "NO_COLOR": "1",
        "LANG": "C",
        "LC_ALL": "C",
    }
    for name in (
        "HOME",
        "GH_CONFIG_DIR",
        "GH_TOKEN",
        "ODYSSEUS_GH_EXECUTABLE_FD",
        "ODYSSEUS_GH_EXECUTABLE_SHA256",
        "ODYSSEUS_GIT_EXECUTABLE_FD",
        "ODYSSEUS_GIT_EXECUTABLE_SHA256",
        "ODYSSEUS_GIT_EXEC_PATH",
        "ODYSSEUS_PYTHON_EXECUTABLE_FD",
        "ODYSSEUS_PYTHON_EXECUTABLE_SHA256",
        CHAIN_DEADLINE_ENV,
    ):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    git_exec_path = environment.get("ODYSSEUS_GIT_EXEC_PATH")
    if git_exec_path is not None:
        canonical = os.path.realpath(git_exec_path)
        try:
            metadata = os.stat(canonical, follow_symlinks=False)
            helpers = tuple(
                os.stat(
                    os.path.realpath(os.path.join(canonical, helper)),
                    follow_symlinks=False,
                )
                for helper in ("git-remote-http", "git-remote-https")
            )
        except OSError as exc:
            raise VerificationError(
                "the Git helper dependency closure is unavailable"
            ) from exc
        if (
            canonical != git_exec_path
            or not stat.S_ISDIR(metadata.st_mode)
            or not _independent_owner(metadata.st_uid)
            or metadata.st_mode & 0o022
            or not _secure_independent_ancestry(
                os.path.join(canonical, "anchor")
            )
            or any(
                not stat.S_ISREG(item.st_mode)
                or not _independent_owner(item.st_uid)
                or item.st_mode & 0o022
                or item.st_mode & 0o111 == 0
                for item in helpers
            )
        ):
            raise VerificationError("the Git helper dependency closure is unsafe")
    environment.update(
        {
            "PATH": "/usr/bin:/bin",
            "GIT_ATTR_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": os.devnull,
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": os.devnull,
            "GIT_EXEC_PATH": git_exec_path or "/__odysseus_no_git_helpers__",
            "GIT_GRAFT_FILE": os.devnull,
            "GIT_NO_LAZY_FETCH": "1",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0",
        }
    )
    return environment


def _owned_gh_deadline() -> tuple[float, float]:
    """Return the shared chain deadline and the shorter per-command deadline."""
    raw = os.environ.get(CHAIN_DEADLINE_ENV, "")
    try:
        chain_deadline = float(raw)
    except (TypeError, ValueError) as exc:
        raise VerificationError("the Athena chain deadline is unavailable") from exc
    now = time.monotonic()
    if not math.isfinite(chain_deadline) or chain_deadline <= now:
        raise VerificationError("the Athena chain deadline has expired")
    return chain_deadline, min(
        chain_deadline, now + GH_COMMAND_TIMEOUT_SECONDS
    )


def _spawn_owned_gh(
    owner: dict[str, object],
    command: tuple[str, ...],
    descriptor: int,
    cwd: str | None,
    *,
    acquisition_deadline: float,
) -> subprocess.Popen:
    """Publish ownership by a deadline; extinguish any late-acquired process."""
    ready = threading.Event()
    cancelled = threading.Event()
    lock = threading.Lock()
    outcome: dict[str, object] = {}

    def spawn() -> None:
        process = None
        try:
            python_descriptor, python_executable = _inherited_tool_binding("python")
            process = subprocess.Popen(
                [
                    python_executable,
                    "-I",
                    "-S",
                    "-B",
                    "-c",
                    _GH_EXEC_SUPERVISOR,
                    str(descriptor),
                    str(GH_MAX_ADDRESS_SPACE_BYTES),
                    str(max(1, int(GH_COMMAND_TIMEOUT_SECONDS) + 1)),
                    *command[1:],
                ],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                cwd=cwd,
                env=_gh_environment(),
                pass_fds=(descriptor, python_descriptor),
                start_new_session=True,
            )
            with lock:
                if cancelled.is_set():
                    outcome["late_process"] = process
                else:
                    owner["process"] = process
                    outcome["process"] = process
        except BaseException as exc:
            with lock:
                outcome["error"] = exc
        finally:
            late_process = outcome.get("late_process")
            if late_process is not None:
                try:
                    _stop_gh_process_group(late_process)
                except BaseException as exc:
                    with lock:
                        outcome["late_cleanup_error"] = exc
            ready.set()

    worker = threading.Thread(
        target=spawn, daemon=False, name="athena-gh-spawn"
    )
    interrupted: BaseException | None = None
    interrupted_traceback = None
    try:
        worker.start()
        while not ready.is_set():
            remaining = acquisition_deadline - time.monotonic()
            if remaining <= 0:
                with lock:
                    cancelled.set()
                raise VerificationError(
                    "the GitHub CLI acquisition deadline expired"
                )
            ready.wait(min(0.01, remaining))
    except BaseException as exc:
        interrupted = exc
        interrupted_traceback = exc.__traceback__
        if worker.ident is None:
            raise
        with lock:
            cancelled.set()
    finally:
        if worker.ident is not None and ready.is_set():
            while worker.is_alive():
                try:
                    worker.join(0.01)
                except BaseException as exc:
                    if interrupted is None:
                        interrupted = exc
                        interrupted_traceback = exc.__traceback__
    if interrupted is not None:
        raise interrupted.with_traceback(interrupted_traceback)
    error = outcome.get("error")
    if isinstance(error, BaseException):
        raise error
    process = outcome.get("process")
    if process is None:
        raise VerificationError("the GitHub CLI process was not acquired")
    return process


def _finalize_owned_gh(process: subprocess.Popen) -> None:
    """Finish process-group cleanup in a non-daemon worker before returning."""
    outcome: dict[str, object] = {}

    def finalize() -> None:
        try:
            _stop_gh_process_group(process)
        except BaseException as exc:
            outcome["error"] = exc

    worker = threading.Thread(
        target=finalize, daemon=False, name="athena-gh-finalizer"
    )
    interrupted: BaseException | None = None
    interrupted_traceback = None
    try:
        worker.start()
    except BaseException as exc:
        interrupted = exc
        interrupted_traceback = exc.__traceback__
        if worker.ident is None:
            _stop_gh_process_group(process)
    if worker.ident is not None:
        while worker.is_alive():
            try:
                worker.join(0.01)
            except BaseException as exc:
                if interrupted is None:
                    interrupted = exc
                    interrupted_traceback = exc.__traceback__
    error = outcome.get("error")
    if isinstance(error, BaseException):
        raise error
    if interrupted is not None:
        raise interrupted.with_traceback(interrupted_traceback)


def _run_bounded_gh(
    command: tuple[str, ...], descriptor: int, *, cwd: str | None = None
) -> subprocess.CompletedProcess:
    """Run one exact GitHub CLI with bounded output and one absolute deadline."""
    chain_deadline, deadline = _owned_gh_deadline()
    owner: dict[str, object] = {}
    process = None
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    primary_error: BaseException | None = None
    try:
        process = _spawn_owned_gh(
            owner,
            command,
            descriptor,
            cwd,
            acquisition_deadline=deadline,
        )
        if process.stdout is None or process.stderr is None:
            raise VerificationError("the GitHub CLI output pipes are unavailable")
        for stream, name in ((process.stdout, "stdout"), (process.stderr, "stderr")):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, name)
        while selector.get_map() or not _gh_leader_exited(process):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                if time.monotonic() >= chain_deadline:
                    raise VerificationError("the Athena chain deadline has expired")
                raise VerificationError("the GitHub CLI did not complete")
            if _gh_leader_exited(process) and not _gh_group_is_extinct(process.pid):
                raise VerificationError("the GitHub CLI left descendant processes")
            if not selector.get_map():
                time.sleep(min(0.01, remaining))
                continue
            for key, _mask in selector.select(min(0.05, remaining)):
                try:
                    chunk = os.read(key.fd, GH_READ_CHUNK_BYTES)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    key.fileobj.close()
                    continue
                target = stdout if key.data == "stdout" else stderr
                limit = (
                    MAX_GH_STDOUT_BYTES
                    if key.data == "stdout" else MAX_GH_STDERR_BYTES
                )
                if len(target) + len(chunk) > limit:
                    raise VerificationError(
                        f"the GitHub CLI {key.data} exceeded its output bound"
                    )
                target.extend(chunk)
        returncode = 0  # The exact exit status becomes available only after cleanup.
    except BaseException as exc:
        primary_error = exc
        returncode = -1
    finally:
        try:
            selector.close()
        except BaseException as exc:
            if primary_error is None:
                primary_error = exc
            else:
                primary_error.add_note(f"GitHub CLI selector cleanup failed: {exc}")
        owned_process = owner.get("process")
        if process is None and owned_process is not None:
            process = owned_process
        if process is not None:
            try:
                _finalize_owned_gh(process)
                returncode = process.returncode
            except BaseException as exc:
                if primary_error is None:
                    primary_error = exc
                else:
                    primary_error.add_note(f"GitHub CLI cleanup also failed: {exc}")
            for stream in (process.stdout, process.stderr):
                if stream is None or stream.closed:
                    continue
                try:
                    stream.close()
                except BaseException as exc:
                    if primary_error is None:
                        primary_error = exc
                    else:
                        primary_error.add_note(
                            f"GitHub CLI stream cleanup also failed: {exc}"
                        )
    if primary_error is not None:
        if isinstance(primary_error, VerificationError):
            raise primary_error
        raise VerificationError("the GitHub CLI execution failed") from primary_error
    try:
        stdout_text = stdout.decode("utf-8", errors="strict")
        stderr_text = stderr.decode("utf-8", errors="strict")
    except UnicodeError as exc:
        raise VerificationError("the GitHub CLI output is not valid UTF-8") from exc
    return subprocess.CompletedProcess(command, returncode, stdout_text, stderr_text)


def _inherited_tool_binding(tool: str) -> tuple[int, str]:
    """Return one verified descriptor-bound helper executable."""
    variables = {
        "gh": (
            "ODYSSEUS_GH_EXECUTABLE_FD",
            "ODYSSEUS_GH_EXECUTABLE_SHA256",
            "GitHub CLI",
        ),
        "git": (
            "ODYSSEUS_GIT_EXECUTABLE_FD",
            "ODYSSEUS_GIT_EXECUTABLE_SHA256",
            "Git",
        ),
        "python": (
            "ODYSSEUS_PYTHON_EXECUTABLE_FD",
            "ODYSSEUS_PYTHON_EXECUTABLE_SHA256",
            "Python",
        ),
    }
    try:
        descriptor_variable, digest_variable, label = variables[tool]
    except KeyError as exc:
        raise VerificationError("Athena attempted an unbound command") from exc
    raw_descriptor = os.environ.get(descriptor_variable, "")
    if re.fullmatch(r"[0-9]{1,10}", raw_descriptor) is None:
        raise VerificationError(f"the trusted {label} binding is unavailable")
    descriptor = int(raw_descriptor)
    if tool == "python":
        _verify_inherited_python_descriptor(descriptor)
    else:
        _verify_inherited_tool_descriptor(descriptor, digest_variable, label)
    return descriptor, _descriptor_execution_path(descriptor)


def _admit_broker_command(arguments: object) -> tuple[tuple[str, ...], int]:
    """Admit only the read/evidence command grammar used by release 0.5.3."""
    if (
        not isinstance(arguments, (list, tuple))
        or len(arguments) < 2
        or not all(
            isinstance(argument, str)
            and argument
            and "\x00" not in argument
            and len(argument.encode("utf-8")) <= 1024 * 1024
            for argument in arguments
        )
    ):
        raise VerificationError("Athena attempted a malformed subprocess command")
    command = tuple(arguments)
    tool = command[0]
    if tool == "gh":
        operation = command[1]
        if any(option in {"--web", "-w"} for option in command):
            raise VerificationError(
                "Athena attempted to launch an ambient helper"
            )
        if operation == "api":
            if any(
                value == "--input"
                or value.startswith("--input=")
                or value in {"-XPOST", "-XPATCH", "-XPUT", "-XDELETE"}
                or (
                    value.startswith("--method=")
                    and value.partition("=")[2] != "GET"
                )
                or (
                    value.startswith("-X")
                    and len(value) > 2
                    and value[2:].removeprefix("=") != "GET"
                )
                for value in command
            ):
                raise VerificationError("Athena attempted a GitHub mutation")
            for index, value in enumerate(command[:-1]):
                if value in {"--method", "-X"} and command[index + 1] != "GET":
                    raise VerificationError("Athena attempted a GitHub mutation")
            fields: list[str] = []
            for index, value in enumerate(command):
                if value in {"-f", "-F", "--field", "--raw-field"}:
                    if index + 1 >= len(command):
                        raise VerificationError(
                            "Athena attempted a malformed GitHub field"
                        )
                    fields.append(command[index + 1])
                elif value.startswith(("--field=", "--raw-field=")):
                    fields.append(value.partition("=")[2])
                elif value.startswith(("-f", "-F")) and len(value) > 2:
                    fields.append(value[2:])
            is_graphql = len(command) > 2 and command[2] == "graphql"
            explicit_get = any(
                value in {"--method=GET", "-XGET", "-X=GET"}
                or (
                    value in {"--method", "-X"}
                    and index + 1 < len(command)
                    and command[index + 1] == "GET"
                )
                for index, value in enumerate(command)
            )
            if fields and not is_graphql and not explicit_get:
                raise VerificationError("Athena attempted a GitHub mutation")
            if is_graphql:
                query_values = [
                    value.partition("=")[2]
                    for value in fields
                    if value.startswith("query=")
                ]
                if (
                    len(query_values) != 1
                    or not query_values[0].lstrip().startswith("query")
                    or re.search(
                        r"\bmutation\b", query_values[0], re.IGNORECASE
                    )
                ):
                    raise VerificationError("Athena attempted a GraphQL mutation")
        elif operation in {"pr", "repo", "issue"}:
            if len(command) < 3 or command[2] != "view":
                raise VerificationError("Athena attempted a GitHub mutation")
        else:
            raise VerificationError("Athena attempted an unknown GitHub operation")
    elif tool == "git":
        index = 1
        configuration: list[str] = []
        while index < len(command):
            value = command[index]
            if value == "-c":
                if index + 1 >= len(command):
                    raise VerificationError(
                        "Athena attempted malformed Git configuration"
                    )
                configuration.append(command[index + 1])
                index += 2
                continue
            if value in {"--no-replace-objects", "--literal-pathspecs"}:
                index += 1
                continue
            break
        safe_configuration = {
            "core.commitGraph=false",
            "diff.external=",
            "diff.autoRefreshIndex=false",
            "init.defaultBranch=athena-review",
            "remote.origin.fetch=",
            "fetch.writeCommitGraph=false",
            "fetch.fsckObjects=true",
            "transfer.fsckObjects=true",
        }
        if any(
            item not in safe_configuration
            and re.fullmatch(
                r"core\.hooksPath=/tmp/athena-pr-review-[A-Za-z0-9._-]+/"
                r"empty-hooks",
                item,
            )
            is None
            for item in configuration
        ):
            raise VerificationError("Athena attempted unsafe Git configuration")
        if index >= len(command) or command[index] not in {
            "cat-file",
            "check-ref-format",
            "checkout",
            "config",
            "diff",
            "fetch",
            "init",
            "merge-base",
            "rev-parse",
        }:
            raise VerificationError("Athena attempted an unknown Git operation")
        operation_arguments = command[index + 1 :]
        if command[index] == "config" and not (
            len(operation_arguments) == 3
            and operation_arguments[0] == "--local"
            and operation_arguments[1] in {"--get", "--get-regexp"}
        ):
            raise VerificationError("Athena attempted a Git config write")
        if command[index] == "fetch":
            # This is the exact pinned materialize_snapshot grammar. The
            # repository is positional, never a URL found among refspecs.
            if not (
                len(operation_arguments) == 8
                and operation_arguments[:5] == (
                    "--quiet", "--no-tags", "--no-write-fetch-head",
                    "--no-recurse-submodules", "--refmap=",
                )
                and re.fullmatch(
                    r"https://github\.com/[A-Za-z0-9_.-]+/"
                    r"[A-Za-z0-9_.-]+\.git",
                    operation_arguments[5],
                )
                and re.fullmatch(
                    r"\+refs/heads/[A-Za-z0-9_./-]+:refs/athena/base",
                    operation_arguments[6],
                )
                and re.fullmatch(
                    r"\+refs/pull/([1-9][0-9]*)/head:refs/athena/pr/\1/head",
                    operation_arguments[7],
                )
            ):
                raise VerificationError("Athena attempted an unsafe Git fetch")
    else:
        raise VerificationError("Athena attempted an unbound command")
    descriptor, executable = _inherited_tool_binding(tool)
    return (executable, *command[1:]), descriptor


def _broker_run(arguments: object, **options: Any) -> subprocess.CompletedProcess:
    """Execute one admitted command through its retained executable object."""
    command, descriptor = _admit_broker_command(arguments)
    original_arguments = list(arguments) if isinstance(arguments, list) else arguments
    capture_output = options.pop("capture_output", False)
    text = options.pop("text", False)
    check = options.pop("check", False)
    cwd = options.pop("cwd", None)
    input_value = options.pop("input", None)
    stdout_mode = options.pop("stdout", None)
    stderr_mode = options.pop("stderr", None)
    options.pop("env", None)
    options.pop("timeout", None)
    empty_input = input_value is None or (
        type(input_value) is bytes and input_value == b""
    ) or (
        type(input_value) is str and input_value == ""
    )
    if options or not empty_input:
        raise VerificationError("Athena attempted an unsupported subprocess option")
    if capture_output and (stdout_mode is not None or stderr_mode is not None):
        raise VerificationError("Athena attempted conflicting subprocess output modes")
    if cwd is not None:
        try:
            cwd = os.fspath(cwd)
        except TypeError as exc:
            raise VerificationError("Athena attempted an invalid working directory") from exc
    result = _run_bounded_gh(command, descriptor, cwd=cwd)
    stdout: str | bytes | None = result.stdout
    stderr: str | bytes | None = result.stderr
    if arguments[0] == "gh" and result.returncode == 0:
        stdout = _bounded_json_text(stdout, "the GitHub helper response")
    if not text:
        stdout = stdout.encode("utf-8")
        stderr = stderr.encode("utf-8")
    if not capture_output and stdout_mode != subprocess.PIPE:
        stdout = None
    if not capture_output and stderr_mode != subprocess.PIPE:
        stderr = None
    completed = subprocess.CompletedProcess(
        original_arguments, result.returncode, stdout, stderr
    )
    if check and completed.returncode != 0:
        raise subprocess.CalledProcessError(
            completed.returncode,
            original_arguments,
            output=completed.stdout,
            stderr=completed.stderr,
        )
    return completed


class _BrokerProcess:
    """Completed, stream-compatible process returned by the exact tool broker."""

    def __init__(self, arguments: object, **options: Any) -> None:
        text = bool(options.get("text", False))
        stdout_mode = options.pop("stdout", subprocess.PIPE)
        stderr_mode = options.pop("stderr", subprocess.PIPE)
        if stdout_mode not in {subprocess.PIPE, subprocess.DEVNULL} or (
            stderr_mode not in {subprocess.PIPE, subprocess.DEVNULL}
        ):
            raise VerificationError("Athena attempted an unsupported output stream")
        options["capture_output"] = True
        completed = _broker_run(arguments, **options)
        self.args = arguments
        self.returncode = completed.returncode
        self.stdout = (
            io.StringIO(completed.stdout)
            if text
            else io.BytesIO(completed.stdout)
        )
        self.stderr = (
            io.StringIO(completed.stderr)
            if text
            else io.BytesIO(completed.stderr)
        )

    def poll(self) -> int:
        return self.returncode

    def wait(self, timeout: float | None = None) -> int:
        del timeout
        return self.returncode

    def kill(self) -> None:
        return None

    def terminate(self) -> None:
        return None

    def communicate(self, input: object = None, timeout: float | None = None):
        del input, timeout
        return self.stdout.read(), self.stderr.read()


class _BoundSubprocessModule:
    """Small subprocess facade that cannot resolve commands through PATH."""

    PIPE = subprocess.PIPE
    DEVNULL = subprocess.DEVNULL
    STDOUT = subprocess.STDOUT
    SubprocessError = subprocess.SubprocessError
    CalledProcessError = subprocess.CalledProcessError
    TimeoutExpired = subprocess.TimeoutExpired
    CompletedProcess = subprocess.CompletedProcess
    Popen = _BrokerProcess

    @staticmethod
    def run(arguments: object, **options: Any) -> subprocess.CompletedProcess:
        return _broker_run(arguments, **options)


@contextlib.contextmanager
def _interposed_subprocess():
    """Make verified Athena source import only the descriptor-bound broker."""
    facade = _BoundSubprocessModule()
    missing = object()
    previous = sys.modules.get("subprocess", missing)
    sys.modules["subprocess"] = facade
    try:
        yield facade
    finally:
        if previous is missing:
            sys.modules.pop("subprocess", None)
        else:
            sys.modules["subprocess"] = previous


def _read_regular_file(path: str, maximum_bytes: int = 8 * 1024 * 1024) -> bytes:
    """Read a bounded regular file without following its final symlink."""
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if not isinstance(no_follow, int) or no_follow == 0:
        raise VerificationError("O_NOFOLLOW is required for Athena verification")
    try:
        descriptor = os.open(path, os.O_RDONLY | no_follow)
    except OSError as exc:
        raise VerificationError("an Athena helper cannot be opened safely") from exc
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode):
            raise VerificationError("an Athena helper is not a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            value = stream.read(maximum_bytes + 1)
    finally:
        os.close(descriptor)
    if len(value) > maximum_bytes:
        raise VerificationError("an Athena helper exceeds its audited size bound")
    return value


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise VerificationError(f"duplicate release metadata key: {key}")
        result[key] = value
    return result


def _release_object(
    path: str, context: str, expected_sha256: str
) -> dict[str, object]:
    try:
        release_bytes = _read_regular_file(path, 64 * 1024)
        if hashlib.sha256(release_bytes).hexdigest() != expected_sha256:
            raise VerificationError(f"{context} bytes do not match release 0.5.3")
        payload = release_bytes.decode("utf-8")
        value = _load_json(payload, context)
    except UnicodeError as exc:
        raise VerificationError(f"{context} is not valid JSON") from exc
    if not isinstance(value, dict):
        raise VerificationError(f"{context} is not a JSON object")
    return value


def _release_path(root: str, relative: str) -> str:
    candidate = os.path.normpath(os.path.join(root, relative))
    if (
        os.path.commonpath((root, candidate)) != root
        or os.path.realpath(candidate) != candidate
    ):
        raise VerificationError("Athena release metadata escapes the plugin tree")
    return candidate


def _verify_release_metadata(root: str) -> None:
    plugin = _release_object(
        _release_path(root, PLUGIN_MANIFEST),
        "the Athena plugin manifest",
        PLUGIN_MANIFEST_SHA256,
    )
    if (
        plugin.get("name") != "athena"
        or plugin.get("version") != ATHENA_RELEASE_VERSION
        or plugin.get("repository")
        != "https://github.com/HomericIntelligence/Athena"
    ):
        raise VerificationError("the Athena plugin manifest is not release 0.5.3")
    installation = _release_object(
        _release_path(root, INSTALL_MANIFEST),
        "the Athena install manifest",
        INSTALL_MANIFEST_SHA256,
    )
    if installation != {
        "source_type": "git",
        "source": ATHENA_RELEASE_SOURCE,
        "ref_name": "main",
        "sparse_paths": [],
        "revision": ATHENA_RELEASE_COMMIT,
    }:
        raise VerificationError("the Athena install manifest is not the pinned release")


def _verified_plugin_payloads(value: str) -> dict[str, bytes]:
    """Read each audited helper once and bind the exact bytes to its digest."""
    if not value or not os.path.isabs(value):
        raise VerificationError("ATHENA_PLUGIN_ROOT must be an absolute path")
    normalized = os.path.normpath(value)
    if normalized != value or os.path.realpath(value) != value:
        raise VerificationError("ATHENA_PLUGIN_ROOT must not contain symlinks")
    root = Path(value)
    try:
        root_metadata = os.lstat(root)
    except OSError as exc:
        raise VerificationError("ATHENA_PLUGIN_ROOT is unavailable") from exc
    if not stat.S_ISDIR(root_metadata.st_mode):
        raise VerificationError("ATHENA_PLUGIN_ROOT is not a directory")
    _verify_release_metadata(value)
    payloads: dict[str, bytes] = {}
    for relative, expected_digest in EXPECTED_HELPERS.items():
        candidate = _release_path(value, relative)
        payload = _read_regular_file(candidate)
        observed = hashlib.sha256(payload).hexdigest()
        if observed != expected_digest:
            raise VerificationError("the Athena helper release digest does not match")
        payloads[relative] = payload
    return payloads


_SYNTHETIC_PLUGIN_ROOT = Path("/__odysseus_verified_athena_053__/plugin")
_IMPORTABLE_HELPERS = {
    "anchor_proofs": "skills/pr-review/scripts/anchor_proofs.py",
    "collect_evidence": "skills/pr-review/scripts/collect_evidence.py",
    "materialize_snapshot": "skills/pr-review/scripts/materialize_snapshot.py",
    "pr_identity": "skills/pr-review/scripts/pr_identity.py",
}
_TRANSIENT_MODULE_NAMES = frozenset({
    *_IMPORTABLE_HELPERS,
    "athena_locked_delivery",
    "athena_pr_review_exchange",
    "athena_pr_collect_evidence",
    "athena_installed_cli",
})


def _synthetic_helper_path(relative: str) -> str:
    return str(_SYNTHETIC_PLUGIN_ROOT / relative)


class _VerifiedSourceLoader(importlib.abc.Loader):
    """Compile one already-verified buffer without reopening a source path."""

    def __init__(self, fullname: str, relative: str, payload: bytes) -> None:
        self.fullname = fullname
        self.relative = relative
        self.payload = payload

    def create_module(self, _spec: Any) -> None:
        return None

    def exec_module(self, module: Any) -> None:
        filename = _synthetic_helper_path(self.relative)
        module.__file__ = filename
        module.__package__ = ""
        exec(compile(self.payload, filename, "exec"), module.__dict__)


class _VerifiedSourceFinder(importlib.abc.MetaPathFinder):
    def __init__(self, payloads: dict[str, bytes]) -> None:
        self.payloads = payloads

    def find_spec(
        self, fullname: str, _path: Any = None, _target: Any = None
    ) -> Any:
        relative = _IMPORTABLE_HELPERS.get(fullname)
        if relative is None:
            return None
        return _verified_source_spec(fullname, relative, self.payloads)


def _verified_source_spec(
    name: str, relative: str, payloads: dict[str, bytes]
) -> Any:
    payload = payloads.get(relative)
    if payload is None:
        raise VerificationError("Athena attempted to import an unaudited helper")
    loader = _VerifiedSourceLoader(name, relative, payload)
    return importlib.util.spec_from_loader(
        name, loader, origin=_synthetic_helper_path(relative)
    )


def _synthetic_relative(location: Any) -> str | None:
    try:
        candidate = os.path.normpath(os.fspath(location))
    except TypeError:
        return None
    root = str(_SYNTHETIC_PLUGIN_ROOT)
    prefix = root + os.sep
    if not candidate.startswith(prefix):
        return None
    relative = candidate[len(prefix):]
    if not relative or relative.startswith("../"):
        return None
    return relative


@contextlib.contextmanager
def _verified_import_environment(payloads: dict[str, bytes]):
    """Route all audited Athena imports to immutable in-memory buffers."""
    if os.path.lexists(_SYNTHETIC_PLUGIN_ROOT):
        raise VerificationError("the synthetic Athena source root is occupied")
    if set(payloads) != set(EXPECTED_HELPERS):
        raise VerificationError("the audited Athena source inventory is incomplete")
    for relative, expected in EXPECTED_HELPERS.items():
        if hashlib.sha256(payloads[relative]).hexdigest() != expected:
            raise VerificationError("an in-memory Athena helper digest changed")

    missing = object()
    saved_modules = {
        name: sys.modules.get(name, missing)
        for name in _TRANSIENT_MODULE_NAMES
    }
    for name in _TRANSIENT_MODULE_NAMES:
        sys.modules.pop(name, None)
    saved_path = list(sys.path)
    original_spec_from_file = importlib.util.spec_from_file_location
    finder = _VerifiedSourceFinder(payloads)

    def verified_spec_from_file_location(
        name: str, location: Any, *_args: Any, **_kwargs: Any
    ) -> Any:
        relative = _synthetic_relative(location)
        if relative is None:
            raise VerificationError(
                "Athena attempted to load source outside its verified buffers"
            )
        return _verified_source_spec(name, relative, payloads)

    sys.meta_path.insert(0, finder)
    importlib.util.spec_from_file_location = verified_spec_from_file_location
    try:
        yield
    finally:
        importlib.util.spec_from_file_location = original_spec_from_file
        if finder in sys.meta_path:
            sys.meta_path.remove(finder)
        sys.path[:] = saved_path
        for name, module in saved_modules.items():
            if module is missing:
                sys.modules.pop(name, None)
            else:
                sys.modules[name] = module


def _load_verified_module(
    payloads: dict[str, bytes], relative: str, name: str
) -> Any:
    spec = _verified_source_spec(name, relative, payloads)
    if spec is None or spec.loader is None:
        raise VerificationError("the audited Athena helper cannot be loaded")
    module = importlib.util.module_from_spec(spec)
    sys.modules[name] = module
    try:
        spec.loader.exec_module(module)
    except BaseException:
        sys.modules.pop(name, None)
        raise
    return module


def _load_delivery_module(payloads: dict[str, bytes]) -> Any:
    """Load the audited delivery graph entirely from verified byte buffers."""
    with _interposed_subprocess(), _verified_import_environment(payloads):
        return _load_verified_module(
            payloads,
            "skills/pr-review/scripts/deliver_go.py",
            "athena_locked_delivery",
        )


class _ReadOnlyForge:
    """Expose only the two live reads used by Athena's chain verifier."""

    __slots__ = ("_delegate",)

    def __init__(self, delegate: Any) -> None:
        self._delegate = delegate

    def snapshot(self) -> Any:
        return self._delegate.snapshot()

    def is_ancestor(self, older_oid: str, newer_oid: str) -> bool:
        return bool(self._delegate.is_ancestor(older_oid, newer_oid))

    def collect_requirements_binding(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot collect delivery data")

    def verify_requirements_binding(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot mutate delivery state")

    def reply(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot reply")

    def resolve(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot resolve threads")

    def set_implementation_go(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot change labels")

    def set_implementation_no_go(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot change labels")

    def publish_terminal(self, *_args: Any, **_kwargs: Any) -> Any:
        raise VerificationError("the read-only verifier cannot publish reviews")


def _install_read_only_gh(delivery: Any, repository: str) -> None:
    """Restrict Athena's internal GitHub adapter to its three required reads."""
    original_run_command = getattr(delivery, "run_command", None)
    if callable(original_run_command):
        raw_descriptor = os.environ.get("ODYSSEUS_GH_EXECUTABLE_FD", "")
        if re.fullmatch(r"[0-9]{1,10}", raw_descriptor) is None:
            raise VerificationError("the trusted GitHub CLI binding is malformed")
        descriptor = int(raw_descriptor)
        try:
            gh_metadata = os.fstat(descriptor)
        except OSError as exc:
            raise VerificationError("the trusted GitHub CLI is unavailable") from exc
        if (
            not stat.S_ISREG(gh_metadata.st_mode)
            or gh_metadata.st_uid not in {0, os.geteuid()}
            or gh_metadata.st_mode & 0o022
            or gh_metadata.st_mode & 0o111 == 0
        ):
            raise VerificationError("the trusted GitHub CLI binding is unsafe")
        _verify_inherited_gh_descriptor(descriptor)
        gh_executable = _descriptor_execution_path(descriptor)

        def bound_run_command(command: Any, *args: Any, **kwargs: Any) -> Any:
            if (
                not isinstance(command, (list, tuple))
                or not command
                or command[0] != "gh"
            ):
                raise VerificationError("Athena attempted an unbound command")
            if args or "pass_fds" in kwargs:
                raise VerificationError("Athena attempted an unsafe GitHub call")
            capture_output = kwargs.pop("capture_output", None)
            text = kwargs.pop("text", None)
            check = kwargs.pop("check", None)
            input_value = kwargs.pop("input", None)
            input_text = kwargs.pop("input_text", None)
            cwd = kwargs.pop("cwd", None)
            if (
                capture_output is not True
                or text is not True
                or check is not False
                or input_value is not None
                or input_text is not None
                or kwargs
                or (cwd is not None and not isinstance(cwd, str))
            ):
                raise VerificationError("Athena attempted an unsafe GitHub call")
            return _run_bounded_gh(
                (gh_executable, *command[1:]), descriptor, cwd=cwd
            )

        delivery.run_command = bound_run_command
    original = delivery._gh
    owner, name = repository.split("/", maxsplit=1)

    def read_only_gh(*arguments: str, input_text: str | None = None) -> str:
        if input_text is not None or not arguments or arguments[0] != "api":
            raise VerificationError("Athena attempted a non-read-only GitHub call")
        is_graphql = len(arguments) >= 2 and arguments[1] == "graphql"
        forbidden_long = (
            "--method", "--input", "--raw-field", "--field",
        )
        has_forbidden_option = any(
            item in forbidden_long
            or any(
                item.startswith(f"{option}=")
                for option in forbidden_long
            )
            or item == "-X"
            or (item.startswith("-X") and len(item) > 2)
            or (item.startswith("-f") and len(item) > 2)
            or (item.startswith("-F") and len(item) > 2)
            for item in arguments
        )
        if has_forbidden_option:
            if is_graphql:
                raise VerificationError(
                    "Athena attempted a non-read-only GraphQL call"
                )
            raise VerificationError("Athena attempted a REST mutation")
        if is_graphql:
            if (
                len(arguments) != 12
                or tuple(arguments[2:5])
                != ("--hostname", "github.com", "-f")
                or arguments[6] != "-f"
                or arguments[7] != f"owner={owner}"
                or arguments[8] != "-f"
                or arguments[9] != f"name={name}"
                or arguments[10] != "-F"
                or re.fullmatch(r"number=[1-9][0-9]*", arguments[11]) is None
                or not arguments[5].startswith("query=")
            ):
                raise VerificationError(
                    "Athena attempted a non-read-only GraphQL call"
                )
            query = arguments[5][6:]
            if (
                not query.lstrip().startswith("query")
                or re.search(r"\bmutation\b", query, re.IGNORECASE)
            ):
                raise VerificationError("Athena attempted a GraphQL mutation")
        else:
            if tuple(arguments[1:]) == ("--hostname", "github.com", "user"):
                response = original(*arguments)
                return _bounded_json_text(response, "the GitHub response")
            paths = [item for item in arguments if item.startswith("repos/")]
            if len(paths) != 1:
                raise VerificationError("Athena attempted an unknown REST operation")
            path = paths[0]
            permission = re.fullmatch(
                rf"repos/{re.escape(owner)}/{re.escape(name)}/collaborators/"
                r"[^/]+/permission",
                path,
            )
            comparison = re.fullmatch(
                rf"repos/{re.escape(owner)}/{re.escape(name)}/compare/"
                r"[0-9a-f]{40}\.\.\.[0-9a-f]{40}",
                path,
            )
            if permission is None and comparison is None:
                raise VerificationError("Athena attempted an unknown REST operation")
            if any(item in {"-f", "-F"} for item in arguments):
                raise VerificationError("Athena attempted a REST mutation")
        response = original(*arguments)
        return _bounded_json_text(response, "the GitHub response")

    delivery._gh = read_only_gh


def _descriptor_execution_path(descriptor: int) -> str:
    """Return the Linux descriptor path or fail before a path reopen."""
    if sys.platform != "linux" or not os.path.isdir("/proc/self/fd"):
        raise VerificationError(
            "descriptor-bound GitHub CLI execution is unavailable"
        )
    return f"/proc/self/fd/{descriptor}"


def _role_normalized_snapshot(
    delivery: Any,
    snapshot: Any,
    reviewer_login: str,
    author_login: str,
) -> Any:
    """Authenticate carrier publishers before replaying Athena's pinned graph."""
    normalized_reviews = []
    for review in snapshot.reviews:
        if delivery.review_exchange.CARRIER_PREFIX not in review.body:
            normalized_reviews.append(review)
            continue
        try:
            envelope = delivery.review_exchange.extract_carrier(review.body)
        except Exception as exc:
            raise VerificationError("an Athena carrier is malformed") from exc
        schema_id = envelope.get("schema_id")
        if schema_id == delivery.review_exchange.STATE_SCHEMA_ID:
            expected_author = reviewer_login
            expected_viewer_ownership = True
        elif schema_id == delivery.review_exchange.AUTHOR_EVENT_SCHEMA_ID:
            expected_author = author_login
            expected_viewer_ownership = author_login == reviewer_login
        else:
            raise VerificationError("an Athena carrier has an unknown logical role")
        if (
            review.author != expected_author
            or bool(review.viewer_did_author) is not expected_viewer_ownership
        ):
            raise VerificationError(
                "an Athena carrier has the wrong publisher identity for its role"
            )
        normalized = copy.copy(review)
        if not expected_viewer_ownership:
            # Release 0.5.3's replay helper predates reviewer-authenticated author
            # events and treats its ownership bit as a syntactic admission check.
            # Publisher authentication above is the authoritative live check.
            object.__setattr__(normalized, "viewer_did_author", True)
        normalized_reviews.append(normalized)
    normalized_snapshot = copy.copy(snapshot)
    reviews = (
        tuple(normalized_reviews)
        if isinstance(snapshot.reviews, tuple)
        else normalized_reviews
    )
    object.__setattr__(normalized_snapshot, "reviews", reviews)
    return normalized_snapshot


def verify_chain(arguments: argparse.Namespace) -> dict[str, Any]:
    """Return a bounded proof for one exact live, immutable review chain."""
    if COMMIT_OID.fullmatch(arguments.base_oid) is None:
        raise VerificationError("the base object identifier is malformed")
    if COMMIT_OID.fullmatch(arguments.head_oid) is None:
        raise VerificationError("the head object identifier is malformed")
    if STATE_DIGEST.fullmatch(arguments.terminal_state_sha256) is None:
        raise VerificationError("the terminal state digest is malformed")
    if re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", arguments.repository) is None:
        raise VerificationError("the repository identity is malformed")
    expected_url = (
        f"https://github.com/{arguments.repository}/pull/{arguments.number}"
    )
    if arguments.url != expected_url:
        raise VerificationError("the pull-request URL is malformed")
    if re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", arguments.reviewer_login
    ) is None:
        raise VerificationError("the trusted Athena reviewer login is malformed")
    if (
        re.fullmatch(
            r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", arguments.author_login
        )
        is None
    ):
        raise VerificationError("the trusted pull-request author login is malformed")

    payloads = _verified_plugin_payloads(arguments.plugin_root)
    delivery = _load_delivery_module(payloads)
    _install_read_only_gh(delivery, arguments.repository)
    binding = delivery.ReviewBinding(
        repository=arguments.repository,
        number=arguments.number,
        url=arguments.url,
        base_oid=arguments.base_oid,
        head_oid=arguments.head_oid,
    )
    forge = _ReadOnlyForge(delivery.GitHubForge(binding, "github.com"))
    viewer = delivery._json_object(
        delivery._gh("api", "--hostname", "github.com", "user"),
        "authenticated viewer response",
    )
    if viewer.get("login") != arguments.reviewer_login:
        raise VerificationError("the authenticated viewer is not the Athena reviewer")
    snapshot = delivery._snapshot(forge, binding)
    replay_snapshot = _role_normalized_snapshot(
        delivery,
        snapshot,
        arguments.reviewer_login,
        arguments.author_login,
    )
    states, authors = delivery._review_carriers(replay_snapshot, binding)
    if any(
        review.author != arguments.reviewer_login
        for review, _envelope in states.values()
    ) or any(
        review.author != arguments.author_login
        for review, _envelope in authors
    ):
        raise VerificationError("an Athena carrier has the wrong publisher identity")
    if any(
        comment.author != arguments.reviewer_login
        for thread in snapshot.threads
        for comment in thread.comments
        if "<!-- HomericIntelligence:review-" in comment.body
    ):
        raise VerificationError("an Athena review root has the wrong publisher identity")
    terminal_records = [
        (review, envelope)
        for review, envelope in states.values()
        if (
            review.head_oid == arguments.head_oid
            and review.author == arguments.reviewer_login
            and envelope["state_sha256"] == arguments.terminal_state_sha256
            and envelope["state"]["artifact_binding"]["revision"]
            == arguments.head_oid
            and envelope["state"]["surface"] == "pull_request"
            and envelope["state"]["phase"] == "complete"
            and envelope["state"]["verdict"] == "GO"
            and envelope["state"]["next_action"] == "finalize"
            and envelope["state"]["coverage_complete"] is True
        )
    ]
    if len(terminal_records) != 1:
        raise VerificationError("there is not one exact-head terminal Athena GO")
    terminal_review, terminal = terminal_records[0]
    chain = delivery._verify_state_chain(
        forge,
        terminal,
        replay_snapshot,
        binding,
        None,
        (),
        recover_direct_reframe=False,
    )
    if (
        terminal["state_sha256"] not in chain.selected_state_sha256s
        or terminal["state_sha256"] not in chain.verified_state_sha256s
    ):
        raise VerificationError("the terminal state is outside the verified chain")
    implementation_labels = {
        label for label in snapshot.labels
        if label.startswith("state:implementation-")
    }
    if implementation_labels != {"state:implementation-go"}:
        raise VerificationError("the live implementation state is not exclusive GO")
    unresolved = [thread.id for thread in snapshot.threads if not thread.is_resolved]
    if unresolved:
        raise VerificationError("the live Athena review still has open threads")
    final_snapshot = delivery._snapshot(forge, binding)
    if final_snapshot != snapshot:
        raise VerificationError("the live Athena review changed during verification")
    return {
        "schema_id": SCHEMA_ID,
        "schema_version": 1,
        "binding": {
            "repository": binding.repository,
            "number": binding.number,
            "url": binding.url,
            "base_oid": binding.base_oid,
            "head_oid": binding.head_oid,
        },
        "terminal": {
            "review_id": terminal_review.id,
            "reviewer_login": terminal_review.author,
            "state_sha256": terminal["state_sha256"],
            "reviewed_scope_sha256": terminal["state"]["artifact_binding"]["sha256"],
            "requirements_sha256": terminal["state"]["requirements_sha256"],
        },
        "selected_state_sha256s": sorted(chain.selected_state_sha256s),
        "verified_state_sha256s": sorted(chain.verified_state_sha256s),
        "implementation_labels": sorted(implementation_labels),
        "unresolved_thread_count": 0,
    }


def _run_verified_helper(arguments: argparse.Namespace) -> int:
    """Execute one audited helper directly from verified source bytes."""
    if arguments.relative not in {
        "skills/pr-review/scripts/collect_evidence.py",
        "skills/review-exchange/scripts/review_exchange.py",
    }:
        raise VerificationError("the source-only helper is not allowlisted")
    helper_argv = list(arguments.helper_argv)
    if helper_argv[:1] == ["--"]:
        helper_argv = helper_argv[1:]
    payloads = _verified_plugin_payloads(arguments.plugin_root)
    source = payloads[arguments.relative]
    script = _synthetic_helper_path(arguments.relative)
    with _interposed_subprocess(), _verified_import_environment(payloads):
        original_argv = sys.argv
        sys.argv = [script, *helper_argv]
        namespace = {
            "__builtins__": __builtins__,
            "__file__": script,
            "__name__": "__main__",
            "__package__": None,
        }
        try:
            exec(compile(source, script, "exec"), namespace, namespace)
        except SystemExit as exc:
            if exc.code in {None, 0}:
                return 0
            if isinstance(exc.code, int):
                return exc.code
            print(str(exc.code), file=sys.stderr)
            return 1
        finally:
            sys.argv = original_argv
    return 0


def _helper_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-root", required=True)
    parser.add_argument("--relative", required=True)
    parser.add_argument("helper_argv", nargs=argparse.REMAINDER)
    return parser


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plugin-root", required=True)
    parser.add_argument("--repository", required=True)
    parser.add_argument("--number", required=True, type=int)
    parser.add_argument("--url", required=True)
    parser.add_argument("--base-oid", required=True)
    parser.add_argument("--head-oid", required=True)
    parser.add_argument("--terminal-state-sha256", required=True)
    parser.add_argument("--reviewer-login", required=True)
    parser.add_argument("--author-login", required=True)
    return parser


def main(argv: list[str] | None = None) -> int:
    values = sys.argv[1:] if argv is None else argv
    try:
        if values[:1] == ["run-helper"]:
            return _run_verified_helper(_helper_parser().parse_args(values[1:]))
        proof = verify_chain(_parser().parse_args(values))
    except (Exception, SystemExit) as exc:
        if isinstance(exc, KeyboardInterrupt):
            raise
        message = " ".join(str(exc).split())[:500] or "Athena chain verification failed"
        print(message, file=sys.stderr)
        return 1
    print(json.dumps(proof, ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
