#!/bin/bash -p
""":"
set -euo pipefail
unset BASH_ENV ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_SSH GIT_SSH_COMMAND \
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
  DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_PRINT_TO_FILE

case "$0" in
  */*) script_parent=${0%/*} ;;
  *) script_parent=. ;;
esac
script_directory=$(CDPATH='' cd -P -- "$script_parent" && pwd -P)
repository_root=${script_directory%/tools/github}
if [ "$repository_root" = "$script_directory" ]; then
  /usr/bin/printf '%s\n' 'error: registrar repository root is unavailable' >&2
  exit 2
fi
dependency_python="$repository_root/.pixi/envs/default/bin/python"
if [ ! -x "$dependency_python" ] || [ -d "$dependency_python" ]; then
  /usr/bin/printf '%s\n' \
    'error: run pixi install before the registrar executable entry point' >&2
  exit 2
fi

remote_mode=0
for argument in "$@"; do
  case "$argument" in
    --plan|--apply) remote_mode=1 ;;
  esac
done
clean_environment=(
  'HOME=/dev/null'
  'LC_ALL=C'
  'ODYSSEUS_REGISTRAR_BOUNDARY=1'
  'PATH=/usr/bin:/bin'
  'TZ=UTC'
  'XDG_CONFIG_HOME=/dev/null'
)
if [ "$remote_mode" -eq 1 ]; then
  if [ -n "${GH_TOKEN:-}" ]; then clean_environment+=("GH_TOKEN=$GH_TOKEN"); fi
  if [ -n "${GITHUB_TOKEN:-}" ]; then
    clean_environment+=("GITHUB_TOKEN=$GITHUB_TOKEN")
  fi
fi
exec /usr/bin/env -i "${clean_environment[@]}" \
  "$dependency_python" -I -E -s "$script_directory/${0##*/}" "$@"
":"""

from __future__ import annotations

import argparse
import ctypes
import fcntl
import hashlib
import json
import os
import re
import secrets
import select
import selectors
import signal
import stat
import subprocess
import sys
import threading
import time
from collections import Counter
from contextlib import contextmanager
from dataclasses import dataclass, replace
from pathlib import Path, PurePosixPath
from urllib.parse import urlsplit

import yaml
from yaml.constructor import ConstructorError
from yaml.events import (
    AliasEvent,
    CollectionEndEvent,
    CollectionStartEvent,
    ScalarEvent,
)
from yaml.nodes import MappingNode
from yaml.resolver import BaseResolver

__doc__ = """Register the M1-M6 milestone epics and their children (issue #468).

Reads issue identity and routing data under
``tools/github/milestone-epics.d/``. It resolves task content from the
referenced Telemachy workflow, validates the combined structural contract,
and renders parseable epic bodies. It uses the ``gh`` command-line interface
(CLI) for read-only planning and reviewed writes.

Modes:
  * ``--check`` (default): validate checked-in sources without remote access.
  * ``--plan``: print the next exact business writes and lock-owner policy.
  * ``--apply``: apply one stage only when ``--plan-digest`` matches it.

Stages create labels, non-dispatching staged children, operator gates, epics, and
then activate dispatchable children in that order. Run ``--plan`` again after
each applied stage. Existing epics are skipped, and marker-bound child issues
from a partial attempt are reused.

This tool performs GitHub mutation and is intended to be run by the operator
or the orchestrator that owns GitHub writes — not by sandboxed agents.
"""

if __name__ == "__main__" and any(
    argument in {"--plan", "--apply"} for argument in sys.argv[1:]
):
    if (
        os.environ.get("ODYSSEUS_REGISTRAR_BOUNDARY") != "1"
        or not sys.flags.isolated
        or not sys.flags.ignore_environment
        or not sys.flags.no_user_site
    ):
        raise SystemExit(
            "error: run the executable registrar entry point for plan or apply"
        )


def _trusted_tool_path(raw_path: str) -> Path:
    """Return the literal invocation path when it is a direct regular file."""
    path = Path(os.path.abspath(raw_path))
    try:
        mode = path.lstat().st_mode
        resolved = path.resolve(strict=True)
    except OSError as exc:
        raise RuntimeError(f"{path}: tool path must be a direct regular file") from exc
    if not stat.S_ISREG(mode):
        raise RuntimeError(f"{path}: tool path must be a direct regular file")
    return resolved


ORG = "HomericIntelligence"
TOOL_PATH = _trusted_tool_path(__file__)
REPO_ROOT = TOOL_PATH.parents[2]
PAYLOAD_DIR = TOOL_PATH.parent / "milestone-epics.d"
EPIC_LABEL = "agamemnon-epic"
NEEDS_PLAN_LABEL = "state:needs-plan"
ISSUE_SKIP_LABEL = "state:skip"
OPERATOR_GATE_LABEL = "agamemnon-operator-gate"
REGISTRATION_STAGED_LABEL = "agamemnon-registration-staged"
REGISTRATION_LOCK_LABEL = "agamemnon-milestone-registration-lock"
EPIC_LABEL_DESCRIPTION = "HMAS epic tracked by Agamemnon"
EPIC_LABEL_COLOR = "0E8A16"
NEEDS_PLAN_LABEL_DESCRIPTION = "Awaiting a reviewed plan"
NEEDS_PLAN_LABEL_COLOR = "FBCA04"
OPERATOR_GATE_LABEL_DESCRIPTION = "Operator-held milestone completion gate"
OPERATOR_GATE_LABEL_COLOR = "5319E7"
REGISTRATION_STAGED_LABEL_DESCRIPTION = (
    "Held from dispatch until milestone epic registration completes"
)
REGISTRATION_STAGED_LABEL_COLOR = "D4C5F9"
REGISTRATION_LOCK_LABEL_DESCRIPTION = (
    "Exclusive lock for one reviewed milestone registration stage"
)
REGISTRATION_LOCK_OWNER_SEPARATOR = "; owner="
REGISTRATION_LOCK_PLANNED_DESCRIPTION = (
    f"{REGISTRATION_LOCK_LABEL_DESCRIPTION}"
    f"{REGISTRATION_LOCK_OWNER_SEPARATOR}<fresh-128-bit-token>"
)
REGISTRATION_LOCK_LABEL_COLOR = "B60205"
ISSUE_PLAN_STATE_LABELS = frozenset(
    {
        NEEDS_PLAN_LABEL,
        "state:plan-go",
        "state:plan-no-go",
        "state:plan-blocked",
    }
)

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

ISSUE_REF_PATTERN = rf"(?:#\d+|{re.escape(ORG)}/[A-Za-z0-9_.-]+#\d+)"
CHECKLIST_LINE_RE = re.compile(
    rf"^- \[ \] {ISSUE_REF_PATTERN}"
    rf"( \(depends on: {ISSUE_REF_PATTERN}(, {ISSUE_REF_PATTERN})*\))?$"
)
ISSUE_INVENTORY_LIMIT = 10_000
LABEL_INVENTORY_LIMIT = 1_000
COMMAND_TIMEOUT_SECONDS = 30
GITHUB_HOST = "github.com"
GH_OUTPUT_LIMIT_BYTES = 8 * 1024 * 1024
GIT_OUTPUT_LIMIT_BYTES = 8 * 1024 * 1024
MAX_GH_ARGUMENT_BYTES = 131_071
MAX_GH_ARGV_BYTES = 1024 * 1024
GITHUB_ISSUE_TITLE_MAX_CHARACTERS = 256
GITHUB_ISSUE_BODY_MAX_CHARACTERS = 65_536
GITHUB_LABEL_NAME_MAX_CHARACTERS = 50
GITHUB_LABEL_DESCRIPTION_MAX_CHARACTERS = 100
GH_TERMINATION_GRACE_SECONDS = 0.5
GIT_TERMINATION_GRACE_SECONDS = 0.5
MAX_EXECUTABLE_BYTES = 128 * 1024 * 1024
READ_CHUNK_BYTES = 65536
MAX_PAYLOAD_DIRECTORY_ENTRIES = 128
MAX_PAYLOAD_FILES = 32
MAX_YAML_SOURCE_BYTES = 1024 * 1024
MAX_YAML_ALIASES = 32
MAX_YAML_DEPTH = 32
MAX_YAML_NODES = 10_000
MAX_YAML_SCALAR_CHARACTERS = 256 * 1024
PROCESS_QUIESCENT_SCANS = 2
GH_EXECUTABLE_CANDIDATES = (
    Path("/usr/bin/gh"),
    Path("/usr/local/bin/gh"),
    Path("/opt/homebrew/bin/gh"),
)
GIT_EXECUTABLE_CANDIDATES = (
    Path("/usr/bin/git"),
    Path("/usr/local/bin/git"),
    Path("/opt/homebrew/bin/git"),
)
_PROCESS_CONTAINMENT_LOCK = threading.Lock()
_PR_SET_CHILD_SUBREAPER = 36
_PR_GET_CHILD_SUBREAPER = 37
_TERMINATION_SIGNALS = frozenset({signal.SIGINT, signal.SIGTERM, signal.SIGHUP})
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


class _TerminationRequested(BaseException):
    """One blocked process-termination signal that requires owned cleanup."""

    def __init__(self, signal_number: int) -> None:
        super().__init__(f"termination requested by signal {signal_number}")
        self.signal_number = signal_number


@contextmanager
def _blocked_termination_signals():
    """Block termination until the command tree is acquired and extinguished."""
    blocker = getattr(signal, "pthread_sigmask", None)
    pending_reader = getattr(signal, "sigpending", None)
    if not callable(blocker) or not callable(pending_reader):
        raise NotImplementedError("signal-safe process acquisition is unavailable")
    previous = blocker(signal.SIG_BLOCK, _TERMINATION_SIGNALS)
    try:
        yield
    finally:
        blocker(signal.SIG_SETMASK, previous)


def _raise_for_pending_termination() -> None:
    """Raise the first pending termination signal in stable priority order."""
    pending = signal.sigpending()
    for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        if signal_number in pending:
            raise _TerminationRequested(signal_number)


def _required_string(
    values: dict[str, object], key: str, source: Path, field: str | None = None
) -> str:
    """Return one required authored string without type coercion."""
    field_name = field or key
    if key not in values:
        raise ValueError(f"{source}: {field_name} is required")
    value = values[key]
    if not isinstance(value, str):
        raise ValueError(f"{source}: {field_name} must be a string")
    return value


def _optional_string(
    values: dict[str, object], key: str, source: Path, field: str
) -> str | None:
    """Return one optional authored string without type coercion."""
    if key not in values:
        return None
    return _required_string(values, key, source, field)


def _optional_string_list(
    values: dict[str, object], key: str, source: Path, field: str
) -> tuple[str, ...]:
    """Return one optional authored string list without item coercion."""
    if key not in values:
        return ()
    value = values[key]
    if not isinstance(value, list) or any(not isinstance(item, str) for item in value):
        raise ValueError(f"{source}: {field} must be a list of strings")
    return tuple(value)


def _optional_boolean(
    values: dict[str, object], key: str, source: Path, field: str
) -> bool:
    """Return one optional authored Boolean without truth-value coercion."""
    if key not in values:
        return False
    value = values[key]
    if type(value) is not bool:
        raise ValueError(f"{source}: {field} must be a Boolean")
    return value


class _UniqueKeyLoader(yaml.SafeLoader):
    """Load safe YAML and reject duplicate mapping keys."""


def _construct_unique_mapping(
    loader: _UniqueKeyLoader, node: MappingNode, deep: bool = False
) -> dict[object, object]:
    """Construct one mapping only when each parsed key is unique."""
    if not isinstance(node, MappingNode):
        raise ConstructorError(None, None, "expected a mapping node", node.start_mark)
    for key_node, _value_node in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "YAML merge keys are not permitted",
                key_node.start_mark,
            )
    loader.flatten_mapping(node)
    mapping: dict[object, object] = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        try:
            duplicate = key in mapping
        except TypeError as exc:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                "found an unhashable key",
                key_node.start_mark,
            ) from exc
        if duplicate:
            raise ConstructorError(
                "while constructing a mapping",
                node.start_mark,
                f"found duplicate key {key!r}",
                key_node.start_mark,
            )
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


_UniqueKeyLoader.add_constructor(
    BaseResolver.DEFAULT_MAPPING_TAG, _construct_unique_mapping
)


def _source_record(value: os.stat_result) -> tuple[int, ...]:
    """Return fields that bind one source inode and its content state."""
    return (
        value.st_ctime_ns,
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_mtime_ns,
        value.st_nlink,
        value.st_size,
    )


def _read_bounded_yaml_file(directory_fd: int, name: str, source: Path) -> bytes:
    """Read one direct regular file through its parent descriptor."""
    descriptor: int | None = None
    try:
        descriptor = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
            dir_fd=directory_fd,
        )
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode):
            raise OSError(f"{source} is not a regular file")
        if opened.st_size > MAX_YAML_SOURCE_BYTES:
            raise ValueError(
                f"{source}: YAML source exceeds the "
                f"{MAX_YAML_SOURCE_BYTES}-byte ceiling"
            )

        chunks: list[bytes] = []
        total = 0
        while True:
            chunk = os.read(
                descriptor,
                min(READ_CHUNK_BYTES, MAX_YAML_SOURCE_BYTES - total + 1),
            )
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_YAML_SOURCE_BYTES:
                raise ValueError(
                    f"{source}: YAML source exceeds the "
                    f"{MAX_YAML_SOURCE_BYTES}-byte ceiling"
                )
            chunks.append(chunk)

        final = os.fstat(descriptor)
        rebound = os.lstat(name, dir_fd=directory_fd)
        if _source_record(opened) != _source_record(final) or _source_record(
            opened
        ) != _source_record(rebound):
            raise ValueError(f"{source}: YAML source changed during read")
        return b"".join(chunks)
    finally:
        if descriptor is not None:
            os.close(descriptor)


def _load_bounded_yaml(source: str, path: Path) -> object:
    """Load one YAML document within fixed parser resource budgets."""
    aliases = 0
    depth = 0
    nodes = 0
    open_anchors: list[str | None] = []
    try:
        for event in yaml.parse(source, Loader=yaml.SafeLoader):
            if isinstance(event, AliasEvent):
                if event.anchor in open_anchors:
                    raise ValueError(
                        f"{path}: recursive YAML alias {event.anchor!r} is not permitted"
                    )
                aliases += 1
                nodes += 1
                if aliases > MAX_YAML_ALIASES:
                    raise ValueError(
                        f"{path}: YAML contains more than {MAX_YAML_ALIASES} aliases"
                    )
            elif isinstance(event, CollectionStartEvent):
                open_anchors.append(event.anchor)
                depth += 1
                nodes += 1
                if depth > MAX_YAML_DEPTH:
                    raise ValueError(
                        f"{path}: YAML contains more than {MAX_YAML_DEPTH} "
                        "collection levels"
                    )
            elif isinstance(event, CollectionEndEvent):
                open_anchors.pop()
                depth -= 1
            elif isinstance(event, ScalarEvent):
                nodes += 1
                if len(event.value) > MAX_YAML_SCALAR_CHARACTERS:
                    raise ValueError(
                        f"{path}: YAML scalar exceeds "
                        f"{MAX_YAML_SCALAR_CHARACTERS} characters"
                    )
            if nodes > MAX_YAML_NODES:
                raise ValueError(
                    f"{path}: YAML contains more than {MAX_YAML_NODES} nodes"
                )
        return yaml.load(source, Loader=_UniqueKeyLoader)
    except yaml.YAMLError as exc:
        raise ValueError(f"{path}: invalid YAML: {exc}") from exc


def _read_payload_sources(payload_dir: Path) -> tuple[tuple[Path, str, str], ...]:
    """Read direct regular payload files without following symlinks."""
    if (
        not hasattr(os, "O_NOFOLLOW")
        or os.open not in getattr(os, "supports_dir_fd", ())
        or os.scandir not in getattr(os, "supports_fd", ())
    ):
        raise ValueError(
            f"{payload_dir}: safe payload path capabilities are unavailable"
        )

    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    no_follow = os.O_NOFOLLOW
    directory_fd: int | None = None
    try:
        try:
            directory_fd = os.open(payload_dir, directory_flags | no_follow)
            if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
                raise OSError(f"{payload_dir} is not a directory")
            names: list[str] = []
            entries = 0
            with os.scandir(directory_fd) as inventory:
                for entry in inventory:
                    entries += 1
                    if entries > MAX_PAYLOAD_DIRECTORY_ENTRIES:
                        raise ValueError(
                            f"{payload_dir}: payload directory contains more than "
                            f"{MAX_PAYLOAD_DIRECTORY_ENTRIES} entries"
                        )
                    if entry.name.endswith(".yaml"):
                        names.append(entry.name)
                        if len(names) > MAX_PAYLOAD_FILES:
                            raise ValueError(
                                f"{payload_dir}: payload directory permits at most "
                                f"{MAX_PAYLOAD_FILES} YAML files"
                            )
            names.sort()
        except OSError as exc:
            raise ValueError(
                f"{payload_dir}: payload directory must be a non-symlink directory"
            ) from exc

        sources: list[tuple[Path, str, str]] = []
        for name in names:
            path = payload_dir / name
            try:
                source_bytes = _read_bounded_yaml_file(directory_fd, name, path)
            except OSError as exc:
                raise ValueError(
                    f"{path}: payload source must be a non-symlink regular file"
                ) from exc
            try:
                content = source_bytes.decode("utf-8")
            except UnicodeDecodeError as exc:
                raise ValueError(f"{path}: payload source must be UTF-8") from exc
            sources.append((path, content, hashlib.sha256(source_bytes).hexdigest()))
        return tuple(sources)
    finally:
        if directory_fd is not None:
            os.close(directory_fd)


def _read_workflow_source(
    reference: object, payload_path: Path
) -> tuple[str, str, str]:
    """Read one direct, regular workflow file without following symlinks."""
    if not hasattr(os, "O_NOFOLLOW") or os.open not in getattr(
        os, "supports_dir_fd", ()
    ):
        raise ValueError(
            f"{payload_path}: safe workflow path capabilities are unavailable"
        )
    if not isinstance(reference, str):
        raise ValueError(f"{payload_path}: workflow reference must be a string")
    normalized = PurePosixPath(reference)
    if (
        normalized.is_absolute()
        or normalized.as_posix() != reference
        or len(normalized.parts) != 2
        or normalized.parts[0] != "workflows"
        or normalized.name in {"", ".", ".."}
    ):
        raise ValueError(
            f"{payload_path}: workflow reference {reference!r} must name a "
            "direct file under workflows/"
        )

    workflow_dir = REPO_ROOT / "workflows"
    directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    no_follow = os.O_NOFOLLOW
    directory_fd: int | None = None
    file_fd: int | None = None
    try:
        directory_fd = os.open(workflow_dir, directory_flags | no_follow)
        if not stat.S_ISDIR(os.fstat(directory_fd).st_mode):
            raise OSError(f"{workflow_dir} is not a directory")
        source_bytes = _read_bounded_yaml_file(
            directory_fd, normalized.name, workflow_dir / normalized.name
        )
    except OSError as exc:
        raise ValueError(
            f"{payload_path}: workflow reference {reference!r} must name a "
            "non-symlink regular file directly under workflows/"
        ) from exc
    finally:
        if file_fd is not None:
            os.close(file_fd)
        if directory_fd is not None:
            os.close(directory_fd)
    try:
        content = source_bytes.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ValueError(
            f"{payload_path}: workflow reference {reference!r} must be UTF-8"
        ) from exc
    return reference, content, hashlib.sha256(source_bytes).hexdigest()


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
    payload_path: str
    payload_sha256: str
    workflow: str
    workflow_sha256: str
    home_rationale: str
    ordering_note: str
    children: tuple[Child, ...]
    blocked_by: dict[str, tuple[str, ...]]
    source_sha: str | None = None

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
        child = next(
            candidate for candidate in self.children if candidate.id == child_id
        )
        return tuple(
            sibling
            for required in child.requires_verified
            for sibling in self.children
            if sibling.id == required
        )


@dataclass(frozen=True)
class IssueWrite:
    """One exact GitHub issue-create payload."""

    target: str
    title: str
    label: str
    body: str

    def payload(self) -> dict[str, str]:
        """Return the operator-visible write payload."""
        return {
            "operation": "issue.create",
            "target": self.target,
            "title": self.title,
            "label": self.label,
            "body": self.body,
        }

    def gh_args(self) -> tuple[str, ...]:
        """Return the CLI arguments for this issue write."""
        return (
            "issue",
            "create",
            "-R",
            self.target,
            "--label",
            self.label,
            "--title",
            self.title,
            "--body",
            self.body,
        )


@dataclass(frozen=True)
class LabelWrite:
    """One exact GitHub label-create payload."""

    target: str
    name: str
    description: str
    color: str

    def payload(self) -> dict[str, str]:
        """Return the operator-visible write payload."""
        return {
            "operation": "label.create",
            "target": self.target,
            "name": self.name,
            "description": self.description,
            "color": self.color,
        }

    def gh_args(self) -> tuple[str, ...]:
        """Return the CLI arguments for this label write."""
        return (
            "label",
            "create",
            self.name,
            "-R",
            self.target,
            "--description",
            self.description,
            "--color",
            self.color,
        )


@dataclass(frozen=True)
class LabelDeleteWrite:
    """One exact GitHub label-delete payload."""

    target: str
    name: str

    def payload(self) -> dict[str, str]:
        """Return the operator-visible write payload."""
        return {
            "operation": "label.delete",
            "target": self.target,
            "name": self.name,
        }

    def gh_args(self) -> tuple[str, ...]:
        """Return the CLI arguments for this label deletion."""
        return (
            "label",
            "delete",
            self.name,
            "-R",
            self.target,
            "--yes",
        )


@dataclass(frozen=True)
class IssueEditWrite:
    """One exact GitHub issue-label transition payload."""

    target: str
    number: int
    add_label: str
    remove_label: str

    def payload(self) -> dict[str, str | int]:
        """Return the operator-visible write payload."""
        return {
            "operation": "issue.edit",
            "target": self.target,
            "number": self.number,
            "add_label": self.add_label,
            "remove_label": self.remove_label,
        }

    def gh_args(self) -> tuple[str, ...]:
        """Return the CLI arguments for this issue-label transition."""
        return (
            "issue",
            "edit",
            str(self.number),
            "-R",
            self.target,
            "--add-label",
            self.add_label,
            "--remove-label",
            self.remove_label,
        )


@dataclass(frozen=True)
class LabelMetadata:
    """One immutable GitHub label identity and its mutable description."""

    node_id: str
    description: str


@dataclass(frozen=True)
class RegistrationState:
    """One validated snapshot of the remote registration state."""

    labels: dict[str, dict[str, LabelMetadata]]
    registration_lock: LabelMetadata | None
    children: dict[str, int | None]
    staged_children: dict[str, int]
    numbers: dict[str, dict[str, int]]
    epics: dict[str, int | None]

    @property
    def registration_locked(self) -> bool:
        """Return true when the remote lock label exists."""
        return self.registration_lock is not None


@dataclass(frozen=True)
class RegistrationStage:
    """One bounded group of reviewed remote-write specifications."""

    name: str
    writes: tuple[LabelWrite | LabelDeleteWrite | IssueWrite | IssueEditWrite, ...]


def load_payloads(payload_dir: Path = PAYLOAD_DIR) -> list[Milestone]:
    """Load routing payloads and canonical workflow task content, ordered M1..M6."""
    milestones: list[Milestone] = []
    for path, payload_text, payload_sha256 in _read_payload_sources(payload_dir):
        doc = _load_bounded_yaml(payload_text, path)
        if not isinstance(doc, dict):
            raise ValueError(f"{path}: payload must be a mapping")
        milestone_id = _required_string(doc, "milestone", path)
        expected_filename = f"{milestone_id.lower()}.yaml"
        if path.name != expected_filename:
            raise ValueError(
                f"{path}: payload filename must match milestone {milestone_id!r} "
                f"as {expected_filename!r}"
            )
        title = _required_string(doc, "title", path)
        payload_epic_home = _required_string(doc, "epic_home", path)
        home_rationale = _required_string(doc, "home_rationale", path).strip()
        ordering_note = _required_string(doc, "ordering_note", path).strip()
        try:
            payload_path = path.relative_to(REPO_ROOT).as_posix()
        except ValueError as exc:
            raise ValueError(
                f"{path}: payload source must be inside the repository"
            ) from exc
        workflow_ref, workflow_text, workflow_sha256 = _read_workflow_source(
            doc.get("workflow"), path
        )
        workflow_path = REPO_ROOT / workflow_ref
        workflow = _load_bounded_yaml(workflow_text, workflow_path)
        if not isinstance(workflow, dict):
            raise ValueError(f"{workflow_path}: workflow must be a mapping")
        if workflow.get("apiVersion") != "telemachy/v1":
            raise ValueError(
                f"{workflow_path}: apiVersion must be exactly 'telemachy/v1'"
            )
        metadata = workflow.get("metadata")
        if not isinstance(metadata, dict):
            raise ValueError(f"{workflow_path}: metadata must be a mapping")
        if metadata.get("epic_home") != payload_epic_home:
            raise ValueError(
                f"{workflow_path}: metadata.epic_home {metadata.get('epic_home')!r} "
                f"does not match payload epic_home {payload_epic_home!r}"
            )
        workflow_tasks: list[dict[str, object]] = []
        teams = workflow.get("teams")
        if not isinstance(teams, list):
            raise ValueError(f"{workflow_path}: teams must be a list")
        for team in teams:
            if not isinstance(team, dict) or not isinstance(team.get("tasks"), list):
                raise ValueError(f"{workflow_path}: each team must contain a task list")
            for task in team["tasks"]:
                if not isinstance(task, dict):
                    raise ValueError(f"{workflow_path}: every task must be a mapping")
                if (
                    not isinstance(task.get("subject"), str)
                    or not task["subject"].strip()
                ):
                    raise ValueError(
                        f"{workflow_path}: every task subject must be non-empty"
                    )
                dependencies = task.get("blocked_by", [])
                if not isinstance(dependencies, list) or any(
                    not isinstance(dependency, str) for dependency in dependencies
                ):
                    raise ValueError(
                        f"{workflow_path}: workflow dependency parity requires "
                        "blocked_by to be a list of subjects"
                    )
                workflow_tasks.append(task)

        children_list: list[Child] = []
        routing_entries = doc.get("children")
        if not isinstance(routing_entries, list):
            raise ValueError(f"{path}: children must be a list")
        for index, entry in enumerate(routing_entries):
            if not isinstance(entry, dict):
                raise ValueError(f"{path}: every child must be a mapping")
            field_prefix = f"children[{index}]"
            child_id = _required_string(entry, "id", path, f"{field_prefix}.id")
            repo = _required_string(entry, "repo", path, f"{field_prefix}.repo")
            manual = _optional_boolean(entry, "manual", path, f"{field_prefix}.manual")
            requires_verified = _optional_string_list(
                entry,
                "requires_verified",
                path,
                f"{field_prefix}.requires_verified",
            )
            completion_condition = _optional_string(
                entry,
                "completion_condition",
                path,
                f"{field_prefix}.completion_condition",
            )
            failure_effect = _optional_string(
                entry, "failure_effect", path, f"{field_prefix}.failure_effect"
            )
            if "description" in entry:
                raise ValueError(
                    f"{path}: {child_id} must define its description in the "
                    "referenced workflow only"
                )
            if manual:
                if "subject" in entry:
                    raise ValueError(
                        f"{path}: {child_id} manual subject must come from "
                        "workflow metadata"
                    )
                prefix = entry.get("workflow_metadata_prefix")
                if not isinstance(prefix, str) or not prefix:
                    raise ValueError(
                        f"{path}: {child_id} needs workflow_metadata_prefix"
                    )
                subject_key = f"{prefix}_subject"
                description_key = f"{prefix}_description"
                missing = [
                    key
                    for key in (subject_key, description_key)
                    if not isinstance(metadata.get(key), str)
                    or not metadata[key].strip()
                ]
                if missing:
                    raise ValueError(
                        f"{workflow_path}: {child_id} needs non-empty workflow "
                        f"metadata {', '.join(missing)}"
                    )
                subject = metadata[subject_key].strip()
                description = metadata[description_key].strip()
            else:
                raw_subject = entry.get("subject")
                if not isinstance(raw_subject, str) or not raw_subject.strip():
                    raise ValueError(
                        f"{path}: {child_id} needs a non-empty routing subject"
                    )
                subject = raw_subject
                matches = [
                    task for task in workflow_tasks if task.get("subject") == subject
                ]
                if len(matches) != 1:
                    raise ValueError(
                        f"{workflow_path}: {child_id} expected exactly one workflow "
                        f"task with subject {subject!r}; found {len(matches)}"
                    )
                raw_description = matches[0].get("description")
                if not isinstance(raw_description, str) or not raw_description.strip():
                    raise ValueError(
                        f"{workflow_path}: {child_id} workflow task description "
                        "must not be empty"
                    )
                description = raw_description.strip()
            children_list.append(
                Child(
                    id=child_id,
                    repo=repo,
                    subject=subject,
                    description=description,
                    manual=manual,
                    requires_verified=requires_verified,
                    completion_condition=completion_condition,
                    failure_effect=failure_effect,
                )
            )
        children = tuple(children_list)
        workflow_subjects = Counter(task["subject"] for task in workflow_tasks)
        routing_subjects = Counter(
            child.subject for child in children if not child.manual
        )
        if workflow_subjects != routing_subjects:
            raise ValueError(
                f"{workflow_path}: dispatchable workflow tasks and routing "
                "children must have a one-to-one subject mapping"
            )

        blocked_by: dict[str, tuple[str, ...]] = {}
        for index, entry in enumerate(routing_entries):
            child_id = _required_string(entry, "id", path, f"children[{index}].id")
            dependencies = entry.get("blocked_by", [])
            if not isinstance(dependencies, list) or any(
                not isinstance(dependency, str) for dependency in dependencies
            ):
                raise ValueError(
                    f"{path}: {child_id} dependency parity requires blocked_by "
                    "to be a list of child IDs"
                )
            blocked_by[child_id] = tuple(dependencies)

        child_by_id = {child.id: child for child in children}
        task_by_subject = {task["subject"]: task for task in workflow_tasks}
        for child in (candidate for candidate in children if not candidate.manual):
            dependency_ids = blocked_by[child.id]
            unknown = [
                dependency
                for dependency in dependency_ids
                if dependency not in child_by_id
            ]
            if unknown:
                raise ValueError(
                    f"{path}: {child.id} dependency parity has unknown child IDs "
                    f"{unknown!r}"
                )
            expected_subjects = tuple(
                child_by_id[dependency].subject for dependency in dependency_ids
            )
            actual_subjects = tuple(
                task_by_subject[child.subject].get("blocked_by", [])
            )
            if actual_subjects != expected_subjects:
                raise ValueError(
                    f"{workflow_path}: {child.id} dependency parity mismatch; "
                    f"workflow has {actual_subjects!r}, routing expects "
                    f"{expected_subjects!r}"
                )
        milestones.append(
            Milestone(
                id=milestone_id,
                title=title,
                epic_home=payload_epic_home,
                payload_path=payload_path,
                payload_sha256=payload_sha256,
                workflow=workflow_ref,
                workflow_sha256=workflow_sha256,
                home_rationale=home_rationale,
                ordering_note=ordering_note,
                children=children,
                blocked_by=blocked_by,
            )
        )
    milestones.sort(key=lambda m: m.id)
    return milestones


def validate(
    milestones: list[Milestone], *, require_complete_inventory: bool = True
) -> list[str]:
    """Validate the checked-in milestone payload contract."""
    errors: list[str] = []
    seen_ids: set[str] = set()

    ids = [m.id for m in milestones]
    if require_complete_inventory and ids != [f"M{i}" for i in range(1, 7)]:
        errors.append(f"expected exactly six milestones M1..M6, got {ids}")

    title_owners: dict[tuple[str, str], str] = {}
    for milestone in milestones:
        planned_issues = [
            (milestone.epic_home, milestone.title, f"{milestone.id} epic"),
            *((child.repo, child.subject, child.id) for child in milestone.children),
        ]
        for repo, title, identity in planned_issues:
            key = (repo, title)
            previous = title_owners.get(key)
            if previous is not None:
                errors.append(
                    f"{identity}: duplicate issue title {title!r} in {repo}; "
                    f"conflicts with {previous}"
                )
            else:
                title_owners[key] = identity

    for m in milestones:
        if not m.title.strip() or m.title.splitlines() != [m.title]:
            errors.append(f"{m.id}: epic title must be one non-empty line")
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
            if re.fullmatch(rf"{re.escape(m.id)}\.[1-9][0-9]*", child.id) is None:
                errors.append(
                    f"{child.id!r}: child id must match {m.id}.<positive integer>"
                )
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

        child_ids = [child.id for child in m.children]
        if len(child_ids) == len(set(child_ids)):
            known_ids = set(child_ids)
            indegree = {child_id: 0 for child_id in child_ids}
            dependents = {child_id: [] for child_id in child_ids}
            for child_id in child_ids:
                for dependency in m.blocked_by.get(child_id, ()):
                    if dependency not in known_ids or dependency == child_id:
                        continue
                    indegree[child_id] += 1
                    dependents[dependency].append(child_id)
            ready = [child_id for child_id in child_ids if indegree[child_id] == 0]
            visited = 0
            while ready:
                dependency = ready.pop()
                visited += 1
                for dependent in dependents[dependency]:
                    indegree[dependent] -= 1
                    if indegree[dependent] == 0:
                        ready.append(dependent)
            if visited != len(child_ids):
                cyclic = sorted(
                    child_id for child_id, degree in indegree.items() if degree > 0
                )
                errors.append(f"{m.id}: dependency cycle detected involving {cyclic!r}")

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


def _source_citation(milestone: Milestone, path: str) -> str:
    """Return one immutable GitHub source citation for an issue body."""
    source_sha = milestone.source_sha
    if (
        source_sha is None
        or re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", source_sha) is None
    ):
        raise ValueError(
            f"{milestone.id}: issue rendering requires an immutable source SHA"
        )
    identity = f"{ORG}/Odysseus@{source_sha}:{path}"
    url = f"https://github.com/{ORG}/Odysseus/blob/{source_sha}/{path}"
    return f"[`{identity}`]({url})"


def _body_source_sha(milestone: Milestone, body: str) -> str:
    """Return the one exact source SHA cited for both selected source paths."""
    cited_shas: set[str] = set()
    for path in (milestone.payload_path, milestone.workflow):
        escaped_path = re.escape(path)
        citation = re.compile(
            rf"\[`{re.escape(f'{ORG}/Odysseus@')}"
            rf"(?P<identity>[0-9a-f]{{40}}|[0-9a-f]{{64}}):{escaped_path}`\]"
            rf"\({re.escape(f'https://github.com/{ORG}/Odysseus/blob/')}"
            rf"(?P<url>[0-9a-f]{{40}}|[0-9a-f]{{64}})/{escaped_path}\)"
        )
        matches = tuple(citation.finditer(body))
        if len(matches) != 1:
            raise ValueError(
                f"{milestone.id}: issue body must contain one exact citation for {path}"
            )
        identity_sha = matches[0].group("identity")
        url_sha = matches[0].group("url")
        if identity_sha != url_sha:
            raise ValueError(
                f"{milestone.id}: issue body source citation SHA values differ"
            )
        cited_shas.add(identity_sha)
    if len(cited_shas) != 1:
        raise ValueError(
            f"{milestone.id}: issue body source citations name different commits"
        )
    return cited_shas.pop()


def _historical_body_milestone(
    milestone: Milestone,
    body: str,
    source_milestones: list[Milestone] | tuple[Milestone, ...] | None,
    verified_historical_sources: set[str] | None,
) -> Milestone:
    """Return an equivalent historical source binding cited by an exact body."""
    cited_sha = _body_source_sha(milestone, body)
    current_sha = milestone.source_sha
    if (
        current_sha is None
        or re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", current_sha) is None
    ):
        raise ValueError(
            f"{milestone.id}: reconciliation requires a current source SHA"
        )
    if cited_sha == current_sha:
        return milestone
    selected = tuple(source_milestones or (milestone,))
    if (
        verified_historical_sources is None
        or cited_sha not in verified_historical_sources
    ):
        _verify_equivalent_historical_source(selected, cited_sha, current_sha)
        if verified_historical_sources is not None:
            verified_historical_sources.add(cited_sha)
    return replace(milestone, source_sha=cited_sha)


def render_child_body(
    m: Milestone, c: Child, numbers: dict[str, int] | None = None
) -> str:
    """Render a child issue from the current milestone payload."""
    routing_source = _source_citation(m, m.payload_path)
    task_source = _source_citation(m, m.workflow)
    preamble = (
        f"Part of {m.id} ({m.title}). Current task source: {task_source}. "
        f"Registration metadata: {routing_source}. Planning context: "
        f"{ORG}/Odysseus#464 and Proposed "
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
    routing_source = _source_citation(m, m.payload_path)
    task_source = _source_citation(m, m.workflow)
    lines = [
        f"Epic tracking Milestone {m.id[1:]} of the mesh-distributed Hephaestus "
        f"loop. Current task source: {task_source}. Registration metadata: "
        f"{routing_source}. Proposed ADR-020 sections 7 and 9 provide "
        "planning context. "
        f"{m.home_rationale}",
        "",
        f"Cross-milestone ordering: {m.ordering_note}",
        "",
        "## Tasks",
    ]

    def issue_ref(child: Child) -> str:
        number = numbers[child.id]
        if child.repo == m.epic_home:
            return f"#{number}"
        return f"{ORG}/{child.repo}#{number}"

    for child in (candidate for candidate in m.children if not candidate.manual):
        number = numbers.get(child.id)
        if number is None:
            raise KeyError(f"{child.id}: child issue number unknown during rendering")
        deps = m.deps(child.id)
        if deps:
            dep_refs = ", ".join(issue_ref(dependency) for dependency in deps)
            lines.append(f"- [ ] {issue_ref(child)} (depends on: {dep_refs})")
        else:
            lines.append(f"- [ ] {issue_ref(child)}")
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


def child_issue_write(
    milestone: Milestone, child: Child, numbers: dict[str, int]
) -> IssueWrite:
    """Build the exact issue-create payload for one child."""
    label = OPERATOR_GATE_LABEL if child.manual else REGISTRATION_STAGED_LABEL
    return IssueWrite(
        target=f"{ORG}/{child.repo}",
        title=child.subject,
        label=label,
        body=render_child_body(milestone, child, numbers),
    )


def epic_issue_write(milestone: Milestone, numbers: dict[str, int]) -> IssueWrite:
    """Build the exact issue-create payload for one milestone epic."""
    return IssueWrite(
        target=f"{ORG}/{milestone.epic_home}",
        title=milestone.title,
        label=EPIC_LABEL,
        body=render_epic_body(milestone, numbers),
    )


def _canonical_repo_target(target: str) -> str:
    """Return one host-qualified repository target from the exact allowlist."""
    if not isinstance(target, str) or not target:
        raise ValueError("GitHub repository target must be a nonempty string")
    unqualified = target
    host_prefix = f"{GITHUB_HOST}/"
    if unqualified.startswith(host_prefix):
        unqualified = unqualified.removeprefix(host_prefix)
    parts = unqualified.split("/")
    if len(parts) != 2 or parts[0] != ORG or parts[1] not in KNOWN_REPOS:
        raise ValueError(
            f"GitHub repository target is outside the allowlist: {target!r}"
        )
    return f"{GITHUB_HOST}/{unqualified}"


def _single_option_value(args: tuple[str, ...], option: str) -> str | None:
    """Return one option value, and reject duplicate or incomplete fields."""
    positions = [index for index, value in enumerate(args) if value == option]
    if not positions:
        return None
    if len(positions) != 1 or positions[0] + 1 >= len(args):
        raise ValueError(f"GitHub option {option!r} must have one value")
    return args[positions[0] + 1]


def _validate_github_field_limits(args: tuple[str, ...]) -> None:
    """Reject GitHub fields that exceed the documented service ceilings."""
    limits = (
        ("--title", GITHUB_ISSUE_TITLE_MAX_CHARACTERS, "issue title"),
        ("--body", GITHUB_ISSUE_BODY_MAX_CHARACTERS, "issue body"),
        ("--label", GITHUB_LABEL_NAME_MAX_CHARACTERS, "label name"),
        ("--add-label", GITHUB_LABEL_NAME_MAX_CHARACTERS, "label name"),
        ("--remove-label", GITHUB_LABEL_NAME_MAX_CHARACTERS, "label name"),
        (
            "--description",
            GITHUB_LABEL_DESCRIPTION_MAX_CHARACTERS,
            "label description",
        ),
    )
    for option, maximum, label in limits:
        value = _single_option_value(args, option)
        if value is not None and len(value) > maximum:
            raise ValueError(f"GitHub {label} exceeds {maximum} characters")

    if args[:2] in {("label", "create"), ("label", "delete")}:
        if len(args) < 3 or len(args[2]) > GITHUB_LABEL_NAME_MAX_CHARACTERS:
            raise ValueError(
                f"GitHub label name exceeds {GITHUB_LABEL_NAME_MAX_CHARACTERS} "
                "characters"
            )

    if args and args[0] == "api":
        for index, value in enumerate(args[:-1]):
            if value not in {"-f", "-F"}:
                continue
            field = args[index + 1]
            name, separator, content = field.partition("=")
            if not separator:
                continue
            if name == "name" and len(content) > GITHUB_LABEL_NAME_MAX_CHARACTERS:
                raise ValueError(
                    f"GitHub label name exceeds {GITHUB_LABEL_NAME_MAX_CHARACTERS} "
                    "characters"
                )
            if (
                name == "description"
                and len(content) > GITHUB_LABEL_DESCRIPTION_MAX_CHARACTERS
            ):
                raise ValueError(
                    "GitHub label description exceeds "
                    f"{GITHUB_LABEL_DESCRIPTION_MAX_CHARACTERS} characters"
                )


def _bound_gh_args(*args: str) -> tuple[str, ...]:
    """Bind one supported gh operation to github.com and an allowed repository."""
    if not args or any(
        not isinstance(value, str) or not value or "\0" in value for value in args
    ):
        raise ValueError("GitHub arguments must be nonempty strings without NUL bytes")
    try:
        encoded_lengths = tuple(len(value.encode("utf-8")) for value in args)
    except UnicodeEncodeError as exc:
        raise ValueError("GitHub arguments must be valid UTF-8 strings") from exc
    if any(length > MAX_GH_ARGUMENT_BYTES for length in encoded_lengths):
        raise ValueError(
            f"GitHub argument exceeds {MAX_GH_ARGUMENT_BYTES} encoded bytes"
        )
    if sum(length + 1 for length in encoded_lengths) > MAX_GH_ARGV_BYTES:
        raise ValueError(
            f"GitHub aggregate argv exceeds {MAX_GH_ARGV_BYTES} encoded bytes"
        )
    _validate_github_field_limits(args)
    if args[0] in {"issue", "label"}:
        if "--hostname" in args:
            raise ValueError("repository commands must use a host-qualified -R target")
        positions = [
            index for index, value in enumerate(args) if value in {"-R", "--repo"}
        ]
        if len(positions) != 1 or positions[0] + 1 >= len(args):
            raise ValueError("GitHub repository command requires one exact -R target")
        position = positions[0] + 1
        bound = list(args)
        bound[position] = _canonical_repo_target(bound[position])
        return tuple(bound)
    if args[0] != "api":
        raise ValueError(f"unsupported GitHub operation: {args[0]!r}")

    bound = list(args)
    host_positions = [
        index for index, value in enumerate(bound) if value == "--hostname"
    ]
    if len(host_positions) > 1:
        raise ValueError("GitHub API operation has multiple host authorities")
    if host_positions:
        position = host_positions[0]
        if position + 1 >= len(bound) or bound[position + 1] != GITHUB_HOST:
            raise ValueError("GitHub API operation must target github.com")
    else:
        bound[1:1] = ["--hostname", GITHUB_HOST]

    value_options = {"--hostname", "--method", "-f", "-F", "--jq"}
    endpoint = None
    index = 1
    while index < len(bound):
        value = bound[index]
        if value in value_options:
            if index + 1 >= len(bound):
                raise ValueError(f"GitHub API option {value!r} requires a value")
            index += 2
            continue
        if value.startswith("-"):
            raise ValueError(f"unsupported GitHub API option: {value!r}")
        endpoint = value
        break
    if endpoint == "graphql":
        return tuple(bound)
    match = re.fullmatch(rf"repos/{re.escape(ORG)}/([^/]+)/.+", endpoint or "")
    if match is None or match.group(1) not in KNOWN_REPOS:
        raise ValueError(f"GitHub API endpoint is outside the allowlist: {endpoint!r}")
    return tuple(bound)


def _trusted_executable_identity(path: Path, label: str) -> tuple[int, ...]:
    """Return a stable identity for one approved, direct executable."""
    try:
        value = path.lstat()
    except OSError as exc:
        raise RuntimeError(
            f"{path}: approved {label} executable is unavailable"
        ) from exc
    if (
        not path.is_absolute()
        or not stat.S_ISREG(value.st_mode)
        or value.st_uid not in {0, os.geteuid()}
        or value.st_nlink != 1
        or stat.S_IMODE(value.st_mode) & 0o022
        or stat.S_IMODE(value.st_mode) & 0o111 == 0
    ):
        raise RuntimeError(f"{path}: approved {label} executable is not owner-bound")
    return _stat_identity(value)


def _stat_identity(value: os.stat_result) -> tuple[int, ...]:
    """Return the metadata fields used to bind an executable descriptor."""
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _gh_executable_identity(path: Path) -> tuple[int, ...]:
    """Return the stable identity of one approved gh executable."""
    return _trusted_executable_identity(path, "gh")


def _git_executable_identity(path: Path) -> tuple[int, ...]:
    """Return the stable identity of one approved Git executable."""
    return _trusted_executable_identity(path, "Git")


def _resolve_executable(
    candidates: tuple[Path, ...], label: str
) -> tuple[Path, tuple[int, ...]]:
    """Resolve one fixed executable candidate and bind its direct identity."""
    identity_reader = (
        _git_executable_identity if label == "Git" else _gh_executable_identity
    )
    for candidate in candidates:
        try:
            identity = identity_reader(candidate)
        except (OSError, RuntimeError):
            continue
        return candidate, identity
    raise RuntimeError(f"no approved absolute {label} executable is available")


def _required_seals() -> tuple[int, int, int]:
    """Return the Linux operations and mask for one immutable memfd."""
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("sealed executable support is unavailable")
    # Linux UAPI: include/uapi/linux/fcntl.h and asm-generic/fcntl.h.
    # Older Python build headers can omit these stable kernel ABI constants.
    defaults = {
        "F_ADD_SEALS": 1033, "F_GET_SEALS": 1034,
        "F_SEAL_GROW": 4, "F_SEAL_SEAL": 1,
        "F_SEAL_SHRINK": 2, "F_SEAL_WRITE": 8,
    }
    values = {
        name: default if getattr(fcntl, name, None) is None else getattr(fcntl, name)
        for name, default in defaults.items()
    }
    if any(not isinstance(value, int) for value in values.values()):
        raise NotImplementedError("sealed executable support is unavailable")
    seals = (
        values["F_SEAL_GROW"]
        | values["F_SEAL_SEAL"]
        | values["F_SEAL_SHRINK"]
        | values["F_SEAL_WRITE"]
    )
    return values["F_ADD_SEALS"], values["F_GET_SEALS"], seals


def _memfd_create(name: str, flags: int) -> int:
    """Create a native Linux memfd without depending on Python build headers."""
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("sealed executable support is unavailable")
    creator = getattr(os, "memfd_create", None)
    if callable(creator):
        return creator(name, flags)
    library = ctypes.CDLL(None, use_errno=True)
    creator = getattr(library, "memfd_create", None)
    if creator is None:
        raise NotImplementedError("native memfd_create is unavailable")
    creator.argtypes = [ctypes.c_char_p, ctypes.c_uint]
    creator.restype = ctypes.c_int
    descriptor = creator(os.fsencode(name), flags)
    if descriptor < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return descriptor


def _descriptor_digest(descriptor: int) -> tuple[int, bytes]:
    """Read one executable descriptor with a fixed aggregate byte ceiling."""
    digest = hashlib.sha256()
    size = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, READ_CHUNK_BYTES)
        if not chunk:
            os.lseek(descriptor, 0, os.SEEK_SET)
            return size, digest.digest()
        size += len(chunk)
        if size > MAX_EXECUTABLE_BYTES:
            raise RuntimeError("trusted executable exceeds its byte ceiling")
        digest.update(chunk)


def _copy_descriptor(source: int, destination: int) -> tuple[int, bytes]:
    """Copy exact executable bytes and return their size and digest."""
    digest = hashlib.sha256()
    size = 0
    os.lseek(source, 0, os.SEEK_SET)
    while True:
        chunk = os.read(source, READ_CHUNK_BYTES)
        if not chunk:
            os.lseek(source, 0, os.SEEK_SET)
            return size, digest.digest()
        size += len(chunk)
        if size > MAX_EXECUTABLE_BYTES:
            raise RuntimeError("trusted executable exceeds its byte ceiling")
        digest.update(chunk)
        remaining = memoryview(chunk)
        while remaining:
            written = os.write(destination, remaining)
            if written <= 0:
                raise RuntimeError("sealed executable copy made no progress")
            remaining = remaining[written:]


@contextmanager
def _sealed_executable(path: Path, expected: tuple[int, ...], label: str):
    """Yield a Linux executable path backed by one sealed descriptor snapshot."""
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("sealed executable support is unavailable")
    creator = _memfd_create
    # Linux UAPI include/uapi/linux/memfd.h: MFD_ALLOW_SEALING = 0x0002.
    allow_sealing = getattr(os, "MFD_ALLOW_SEALING", None)
    if allow_sealing is None:
        allow_sealing = 2
    no_follow = getattr(os, "O_NOFOLLOW", None)
    close_on_exec = getattr(os, "O_CLOEXEC", None)
    if (
        not isinstance(allow_sealing, int)
        or not isinstance(no_follow, int)
        or not isinstance(close_on_exec, int)
    ):
        raise NotImplementedError("sealed executable support is unavailable")
    identity_reader = (
        _git_executable_identity if label == "Git" else _gh_executable_identity
    )
    source = os.open(path, os.O_RDONLY | no_follow | close_on_exec)
    sealed = -1
    try:
        if identity_reader(path) != expected:
            raise RuntimeError(f"approved {label} executable changed before sealing")
        source_metadata = os.fstat(source)
        source_identity = _stat_identity(source_metadata)
        if source_identity != expected:
            raise RuntimeError(f"approved {label} executable changed while opening")
        add_seals, get_seals, required = _required_seals()
        # Do not use MFD_CLOEXEC. Script fixtures need the sealed descriptor to
        # remain available to their absolute shebang interpreter after exec.
        sealed = creator(f"odysseus-{label.lower()}", allow_sealing)
        size, digest = _copy_descriptor(source, sealed)
        if identity_reader(path) != expected or source_identity != _stat_identity(
            os.fstat(source)
        ):
            raise RuntimeError(f"approved {label} executable changed while sealing")
        os.fchmod(sealed, 0o500)
        fcntl.fcntl(sealed, add_seals, required)
        held = os.fstat(sealed)
        held_size, held_digest = _descriptor_digest(sealed)
        if (
            not stat.S_ISREG(held.st_mode)
            or held.st_size != size
            or held_size != size
            or held_digest != digest
            or fcntl.fcntl(sealed, get_seals) & required != required
        ):
            raise RuntimeError(f"sealed {label} executable failed verification")
        launch_path = f"/proc/self/fd/{sealed}"
        linked = os.stat(launch_path)
        if (linked.st_dev, linked.st_ino) != (held.st_dev, held.st_ino):
            raise RuntimeError(f"sealed {label} executable route changed")
        yield launch_path, (sealed,)
    finally:
        if sealed >= 0:
            os.close(sealed)
        os.close(source)


def _pidfd_open(process_id: int, flags: int = 0) -> int:
    """Use native pidfds even when Python was built against older headers."""
    native = getattr(os, "pidfd_open", None)
    if callable(native):
        return native(process_id, flags)
    library = ctypes.CDLL(None, use_errno=True)
    function = getattr(library, "pidfd_open", None)
    if function is None:
        raise NotImplementedError("Linux pidfd_open is unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_uint]
    function.restype = ctypes.c_int
    result = function(process_id, flags)
    if result < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))
    return result


def _pidfd_send_signal(descriptor: int, signal_number: int) -> None:
    """Signal only the retained pidfd; never fall back to a numeric PID."""
    native = getattr(signal, "pidfd_send_signal", None)
    if callable(native):
        native(descriptor, signal_number, None, 0)
        return
    library = ctypes.CDLL(None, use_errno=True)
    function = getattr(library, "pidfd_send_signal", None)
    if function is None:
        raise NotImplementedError("Linux pidfd_send_signal is unavailable")
    function.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p, ctypes.c_uint]
    function.restype = ctypes.c_int
    if function(descriptor, signal_number, None, 0) < 0:
        error_number = ctypes.get_errno()
        raise OSError(error_number, os.strerror(error_number))


def _enable_linux_subreaper() -> None:
    """Enable and verify the Linux orphan-adoption boundary."""
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("Linux descendant containment is unavailable")
    descriptor = _pidfd_open(os.getpid())
    try:
        _pidfd_send_signal(descriptor, 0)
    finally:
        os.close(descriptor)
    library = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(library, "prctl", None)
    if prctl is None:
        raise NotImplementedError("Linux subreaper containment is unavailable")
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    ctypes.set_errno(0)
    if prctl(_PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        error_number = ctypes.get_errno() or 1
        raise OSError(error_number, "could not enable Linux subreaper containment")
    state = ctypes.c_int(0)
    ctypes.set_errno(0)
    if prctl(_PR_GET_CHILD_SUBREAPER, ctypes.addressof(state), 0, 0, 0) != 0:
        error_number = ctypes.get_errno() or 1
        raise OSError(error_number, "could not verify Linux subreaper containment")
    if state.value != 1:
        raise OSError("Linux subreaper containment is not active")
    if not Path(f"/proc/{os.getpid()}/task").is_dir():
        raise NotImplementedError("Linux process inventory is unavailable")


def _linux_process_identity(process_id: int) -> tuple[int, int] | None:
    """Return one PID and kernel start time without following process names."""
    try:
        with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
            content = stream.read(65537)
    except (FileNotFoundError, ProcessLookupError):
        return None
    if len(content) > 65536:
        raise RuntimeError("Linux process identity exceeded its byte ceiling")
    closing = content.rfind(b")")
    if closing < 1:
        raise RuntimeError("Linux process identity is malformed")
    fields = content[closing + 2 :].split()
    if len(fields) <= 19:
        raise RuntimeError("Linux process identity is incomplete")
    try:
        start_time = int(fields[19])
    except ValueError as exc:
        raise RuntimeError("Linux process identity is malformed") from exc
    return process_id, start_time


def _linux_child_pids(process_id: int) -> set[int]:
    """Return children of every thread in one Linux process."""
    task_root = Path(f"/proc/{process_id}/task")
    try:
        task_ids = tuple(
            entry.name for entry in task_root.iterdir() if entry.name.isdecimal()
        )
    except (FileNotFoundError, ProcessLookupError):
        return set()
    children: set[int] = set()
    for task_id in task_ids:
        try:
            with open(task_root / task_id / "children", "rb", buffering=0) as stream:
                content = stream.read(1048577)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if len(content) > 1048576:
            raise RuntimeError("Linux child inventory exceeded its byte ceiling")
        for value in content.split():
            if not value.isdigit():
                raise RuntimeError("Linux child inventory is malformed")
            child = int(value)
            if child > 1:
                children.add(child)
    return children


class _LinuxProcessScope:
    """Track one command and every descendant adopted by this subreaper."""

    def __init__(self) -> None:
        _enable_linux_subreaper()
        self.supervisor = os.getpid()
        self.baseline = {
            identity
            for process_id in _linux_child_pids(self.supervisor)
            if (identity := _linux_process_identity(process_id)) is not None
        }
        self.owned: dict[int, tuple[int, int]] = {}

    def _track(self, process_id: int, *, root: bool = False) -> bool:
        identity = _linux_process_identity(process_id)
        if identity is None or (not root and identity in self.baseline):
            return False
        previous = self.owned.get(process_id)
        if previous is not None and previous[0] == identity[1]:
            return False
        if previous is not None:
            os.close(previous[1])
        descriptor = _pidfd_open(process_id, 0)
        rebound = _linux_process_identity(process_id)
        if rebound != identity:
            os.close(descriptor)
            if rebound is None:
                return False
            raise RuntimeError("Linux process identity changed while binding")
        self.owned[process_id] = (identity[1], descriptor)
        return True

    def track_root(self, process_id: int) -> int:
        if not self._track(process_id, root=True):
            raise RuntimeError("could not bind the command leader")
        return self.owned[process_id][1]

    def discover(self) -> bool:
        """Bind the current descendant closure and report any new identity."""
        discovered = False
        while True:
            candidates = set(_linux_child_pids(self.supervisor))
            for process_id, (start_time, _descriptor) in tuple(self.owned.items()):
                if _linux_process_identity(process_id) == (process_id, start_time):
                    candidates.update(_linux_child_pids(process_id))
            changed = False
            for process_id in candidates:
                changed = self._track(process_id) or changed
            discovered = discovered or changed
            if not changed:
                return discovered

    @staticmethod
    def _exited(descriptor: int) -> bool:
        ready, _writable, _exceptional = select.select([descriptor], [], [], 0)
        return bool(ready)

    def leader_exited(self, descriptor: int) -> bool:
        return self._exited(descriptor)

    def _live_snapshot(self) -> tuple[tuple[int, int], ...]:
        """Return live bound identities without performing another inventory."""
        return tuple(
            (process_id, descriptor)
            for process_id, (_start_time, descriptor) in self.owned.items()
            if not self._exited(descriptor)
        )

    def live(self) -> tuple[tuple[int, int], ...]:
        """Return live identities after closing the final fork/exit window."""
        self.discover()
        live = self._live_snapshot()
        if live:
            return live

        # A process can fork after its children file was read and exit before
        # its pidfd is checked. Once every bound parent is exited, no further
        # fork is possible; require consecutive unchanged rescans so every
        # child reparented to this subreaper is bound before accepting empty.
        unchanged_scans = 0
        while unchanged_scans < PROCESS_QUIESCENT_SCANS:
            changed = self.discover()
            live = self._live_snapshot()
            if live:
                return live
            unchanged_scans = 0 if changed else unchanged_scans + 1
        return ()

    def live_descendants(self, leader: int) -> tuple[tuple[int, int], ...]:
        return tuple(item for item in self.live() if item[0] != leader)

    @staticmethod
    def _send(descriptor: int, signal_number: int) -> None:
        try:
            _pidfd_send_signal(descriptor, signal_number)
        except ProcessLookupError:
            pass

    def terminate(self, process: subprocess.Popen[bytes], grace: float) -> None:
        """Terminate every bound member, including adopted detached sessions."""
        cleanup_error: BaseException | None = None
        for signal_number, interval in (
            (signal.SIGTERM, max(0.0, grace)),
            (signal.SIGKILL, max(0.1, grace)),
        ):
            deadline = time.monotonic() + interval
            while True:
                try:
                    live = self.live()
                except BaseException as exc:
                    cleanup_error = cleanup_error or exc
                    live = tuple(
                        (process_id, descriptor)
                        for process_id, (_start, descriptor) in self.owned.items()
                        if not self._exited(descriptor)
                    )
                if not live:
                    break
                for _process_id, descriptor in live:
                    try:
                        self._send(descriptor, signal_number)
                    except BaseException as exc:
                        cleanup_error = cleanup_error or exc
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.01)
        survivors = self.live()
        if survivors:
            raise RuntimeError(
                "owned descendant processes survived containment cleanup"
            ) from cleanup_error
        try:
            process.wait(timeout=max(0.1, grace))
        except subprocess.TimeoutExpired as exc:
            raise RuntimeError("command leader could not be reaped") from exc
        self.reap_adopted(process.pid)
        if cleanup_error is not None:
            raise RuntimeError(
                "descendant containment cleanup failed"
            ) from cleanup_error

    def reap_adopted(self, leader: int) -> None:
        """Reap exact adopted descendants after the direct leader is reaped."""
        for process_id in tuple(self.owned):
            if process_id == leader:
                continue
            try:
                os.waitpid(process_id, os.WNOHANG)
            except ChildProcessError:
                pass

    def close(self) -> None:
        for _start_time, descriptor in self.owned.values():
            os.close(descriptor)
        self.owned.clear()


def _run_linux_bound_process(
    executable: Path,
    expected_identity: tuple[int, ...],
    argv: tuple[str, ...],
    environment: dict[str, str],
    *,
    deadline_ns: int,
    output_limit: int,
    termination_grace: float,
    label: str,
) -> tuple[int, bytes, bytes]:
    """Run one sealed command in a Linux subreaper and pidfd boundary."""
    with _PROCESS_CONTAINMENT_LOCK, _blocked_termination_signals():
        scope = _LinuxProcessScope()
        process: subprocess.Popen[bytes] | None = None
        selector = selectors.DefaultSelector()
        streams: dict[int, bytearray] = {}
        stdout_fd = -1
        stderr_fd = -1
        try:
            with _sealed_executable(executable, expected_identity, label) as (
                launch_path,
                inherited_descriptors,
            ):
                _raise_for_pending_termination()
                if time.monotonic_ns() >= deadline_ns:
                    raise TimeoutError
                process = subprocess.Popen(
                    argv,
                    executable=launch_path,
                    pass_fds=inherited_descriptors,
                    cwd=REPO_ROOT,
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    env=environment,
                    close_fds=True,
                    start_new_session=True,
                )
                leader_descriptor = scope.track_root(process.pid)
                _raise_for_pending_termination()
                if process.stdout is None or process.stderr is None:
                    raise RuntimeError(f"{label} output pipes are unavailable")
                stdout_fd = process.stdout.fileno()
                stderr_fd = process.stderr.fileno()
                streams = {stdout_fd: bytearray(), stderr_fd: bytearray()}
                for stream in (process.stdout, process.stderr):
                    os.set_blocking(stream.fileno(), False)
                    selector.register(stream, selectors.EVENT_READ)
                total = 0
                while selector.get_map() or not scope.leader_exited(leader_descriptor):
                    _raise_for_pending_termination()
                    remaining = (deadline_ns - time.monotonic_ns()) / 1_000_000_000
                    if remaining <= 0:
                        raise TimeoutError
                    scope.discover()
                    if selector.get_map():
                        events = selector.select(min(0.05, remaining))
                    else:
                        time.sleep(min(0.01, remaining))
                        events = ()
                    for key, _mask in events:
                        try:
                            chunk = os.read(
                                key.fd,
                                min(READ_CHUNK_BYTES, output_limit - total + 1),
                            )
                        except BlockingIOError:
                            continue
                        if not chunk:
                            selector.unregister(key.fileobj)
                            continue
                        streams[key.fd].extend(chunk)
                        total += len(chunk)
                        if total > output_limit:
                            raise RuntimeError(
                                f"{label} output exceeded {output_limit} bytes"
                            )
                if scope.live_descendants(process.pid):
                    raise RuntimeError(f"{label} left a descendant process running")
                _raise_for_pending_termination()
                remaining = (deadline_ns - time.monotonic_ns()) / 1_000_000_000
                if remaining <= 0:
                    raise TimeoutError
                returncode = process.wait(timeout=remaining)
                scope.reap_adopted(process.pid)
                identity_reader = (
                    _git_executable_identity
                    if label == "Git"
                    else _gh_executable_identity
                )
                if identity_reader(executable) != expected_identity:
                    raise RuntimeError(
                        f"approved {label} executable changed during invocation"
                    )
                _raise_for_pending_termination()
                return (
                    returncode,
                    bytes(streams[stdout_fd]),
                    bytes(streams[stderr_fd]),
                )
        except BaseException:
            if process is not None:
                scope.terminate(process, termination_grace)
            raise
        finally:
            selector.close()
            if process is not None:
                for stream in (process.stdout, process.stderr):
                    if stream is not None and not stream.closed:
                        stream.close()
            scope.close()


def _resolve_gh_executable() -> Path:
    """Resolve gh only through fixed platform entrypoints, never ambient PATH."""
    return _resolve_executable(GH_EXECUTABLE_CANDIDATES, "gh")[0]


def _resolve_git_executable() -> Path:
    """Resolve Git only through fixed platform entrypoints, never ambient PATH."""
    return _resolve_executable(GIT_EXECUTABLE_CANDIDATES, "Git")[0]


def _gh_environment() -> dict[str, str]:
    """Return the minimal environment required for a github.com API call."""
    environment = {
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
        "GH_HOST": GITHUB_HOST,
        "GH_PROMPT_DISABLED": "1",
        "GH_PAGER": "cat",
        "GH_NO_UPDATE_NOTIFIER": "1",
        "NO_COLOR": "1",
        "HOME": "/dev/null",
        "TZ": "UTC",
        "XDG_CONFIG_HOME": "/dev/null",
    }
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name)
        if value:
            environment[name] = value
    return environment


def _git_environment() -> dict[str, str]:
    """Return a fixed environment for local Git object inspection."""
    return {
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PAGER": "cat",
        "GIT_PROTOCOL_FROM_USER": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/dev/null",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TZ": "UTC",
        "XDG_CONFIG_HOME": "/dev/null",
    }


def _process_group_exists(process_id: int) -> bool:
    try:
        os.killpg(process_id, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        # Every member created by this boundary has our effective user. On
        # macOS an extinct group can return EPERM after its leader is reaped;
        # an inaccessible group is therefore not the owned invocation group.
        return False
    return True


def _terminate_process_group(process: subprocess.Popen[bytes]) -> None:
    """Extinguish the exact session created for one gh invocation."""
    # Reap a leader that already exited before probing its former process group.
    # On macOS an unreaped leader can make killpg(..., 0) report a group that
    # cannot be signalled, which would mask the original boundary failure.
    process.poll()
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + GH_TERMINATION_GRACE_SECONDS
    while _process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    if _process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=GH_TERMINATION_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=GH_TERMINATION_GRACE_SECONDS)


def _run_portable_gh_process(
    executable: Path, args: tuple[str, ...], environment: dict[str, str]
) -> tuple[int, bytes, bytes]:
    """Run one credential-free test command on a non-Linux host."""
    before = _gh_executable_identity(executable)
    process = subprocess.Popen(
        (str(executable), *args),
        cwd=REPO_ROOT,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=environment,
        close_fds=True,
        start_new_session=True,
    )
    assert process.stdout is not None and process.stderr is not None
    selector = selectors.DefaultSelector()
    stdout_fd = process.stdout.fileno()
    stderr_fd = process.stderr.fileno()
    streams = {stdout_fd: bytearray(), stderr_fd: bytearray()}
    for stream in (process.stdout, process.stderr):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ)
    deadline = time.monotonic() + COMMAND_TIMEOUT_SECONDS
    total = 0
    try:
        while selector.get_map() or process.poll() is None:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise TimeoutError
            for key, _mask in selector.select(min(0.05, remaining)):
                chunk = os.read(key.fd, min(65536, GH_OUTPUT_LIMIT_BYTES - total + 1))
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                streams[key.fd].extend(chunk)
                total += len(chunk)
                if total > GH_OUTPUT_LIMIT_BYTES:
                    raise RuntimeError(
                        f"gh output exceeded {GH_OUTPUT_LIMIT_BYTES} bytes"
                    )
        returncode = process.wait(timeout=max(0.01, deadline - time.monotonic()))
        if _process_group_exists(process.pid):
            raise RuntimeError("gh left a descendant process running")
    except BaseException:
        _terminate_process_group(process)
        raise
    finally:
        selector.close()
        process.stdout.close()
        process.stderr.close()
    after = _gh_executable_identity(executable)
    if after != before:
        raise RuntimeError("approved gh executable changed during invocation")
    return returncode, bytes(streams[stdout_fd]), bytes(streams[stderr_fd])


def _run_gh_process(
    executable: Path, args: tuple[str, ...], environment: dict[str, str]
) -> tuple[int, bytes, bytes]:
    """Run gh with bounded output and complete descendant containment."""
    if sys.platform.startswith("linux"):
        deadline_ns = time.monotonic_ns() + int(COMMAND_TIMEOUT_SECONDS * 1_000_000_000)
        return _run_linux_bound_process(
            executable,
            _gh_executable_identity(executable),
            (str(executable), *args),
            environment,
            deadline_ns=deadline_ns,
            output_limit=GH_OUTPUT_LIMIT_BYTES,
            termination_grace=GH_TERMINATION_GRACE_SECONDS,
            label="gh",
        )
    if any(environment.get(name) for name in ("GH_TOKEN", "GITHUB_TOKEN")):
        raise RuntimeError(
            "credential-bearing gh descendant containment is unavailable on this host"
        )
    return _run_portable_gh_process(executable, args, environment)


def gh(*args: str) -> str:
    """Run one authority-bound ``gh`` command and return bounded stdout."""
    bound_args = _bound_gh_args(*args)
    executable = _resolve_gh_executable()
    try:
        returncode, stdout, stderr = _run_gh_process(
            executable, bound_args, _gh_environment()
        )
    except TimeoutError as exc:
        raise RuntimeError(
            f"gh {' '.join(bound_args)} timed out after {COMMAND_TIMEOUT_SECONDS}s"
        ) from exc
    if returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        raise RuntimeError(f"gh {' '.join(bound_args)} failed: {detail}")
    try:
        return stdout.decode("utf-8")
    except UnicodeDecodeError as exc:
        raise RuntimeError("gh returned non-UTF-8 output") from exc


def issue_number_from_url(url: str, *, expected_target: str) -> int:
    """Extract a number only from the exact issue-create repository URL."""
    canonical_target = _canonical_repo_target(expected_target)
    parsed = urlsplit(url.strip())
    expected_path_prefix = (
        f"/{canonical_target.removeprefix(f'{GITHUB_HOST}/')}/issues/"
    )
    if (
        parsed.scheme != "https"
        or parsed.netloc != GITHUB_HOST
        or parsed.query
        or parsed.fragment
        or not parsed.path.startswith(expected_path_prefix)
    ):
        raise ValueError(f"cannot bind issue receipt to {expected_target!r}: {url!r}")
    number = parsed.path.removeprefix(expected_path_prefix)
    if re.fullmatch(r"[1-9][0-9]*", number) is None:
        raise ValueError(f"cannot parse issue number from {url!r}")
    return int(number)


def issue_inventory(repo: str) -> list[dict[str, object]]:
    """Load a bounded all-state issue inventory, failing if it may be partial."""
    out = gh(
        "issue",
        "list",
        "-R",
        f"{ORG}/{repo}",
        "--state",
        "all",
        "--limit",
        str(ISSUE_INVENTORY_LIMIT),
        "--json",
        "number,title,state,body,labels",
    )
    try:
        entries = json.loads(out)
    except json.JSONDecodeError as exc:
        raise RuntimeError(f"{repo}: issue inventory is not valid JSON") from exc
    if not isinstance(entries, list):
        raise RuntimeError(f"{repo}: issue inventory must be a list")
    if len(entries) >= ISSUE_INVENTORY_LIMIT:
        raise RuntimeError(
            f"{repo}: issue inventory reached {ISSUE_INVENTORY_LIMIT}; "
            "refusing a potentially incomplete reconciliation"
        )
    required_fields = {"number", "title", "state", "body", "labels"}
    seen_numbers: set[int] = set()
    for index, entry in enumerate(entries):
        if not isinstance(entry, dict) or set(entry) != required_fields:
            raise RuntimeError(
                f"{repo}: issue inventory entry {index} has an invalid schema"
            )
        number = entry["number"]
        if type(number) is not int or number <= 0:
            raise RuntimeError(
                f"{repo}: issue inventory entry {index} has an invalid issue number"
            )
        if number in seen_numbers:
            raise RuntimeError(
                f"{repo}: issue inventory contains duplicate issue number {number}"
            )
        seen_numbers.add(number)
        if (
            not isinstance(entry["title"], str)
            or not isinstance(entry["state"], str)
            or entry["state"] not in {"OPEN", "CLOSED"}
            or not isinstance(entry["body"], str)
        ):
            raise RuntimeError(
                f"{repo}: issue inventory entry {index} has invalid text fields"
            )
        labels = entry["labels"]
        if not isinstance(labels, list):
            raise RuntimeError(
                f"{repo}: issue inventory entry {index} has invalid labels"
            )
        label_names: set[str] = set()
        for label in labels:
            name = label.get("name") if isinstance(label, dict) else None
            if not isinstance(name, str) or not name or name in label_names:
                raise RuntimeError(
                    f"{repo}: issue inventory entry {index} has an invalid label"
                )
            label_names.add(name)
    return entries


def label_inventory(repo: str) -> dict[str, LabelMetadata]:
    """Load immutable label identities and descriptions."""
    out = gh(
        "label",
        "list",
        "-R",
        f"{ORG}/{repo}",
        "--limit",
        str(LABEL_INVENTORY_LIMIT),
        "--json",
        "id,name,description",
    )
    entries = json.loads(out)
    if len(entries) >= LABEL_INVENTORY_LIMIT:
        raise RuntimeError(
            f"{repo}: label inventory reached {LABEL_INVENTORY_LIMIT}; "
            "refusing a potentially incomplete reconciliation"
        )
    labels: dict[str, LabelMetadata] = {}
    for entry in entries:
        if not isinstance(entry, dict) or not isinstance(entry.get("name"), str):
            raise RuntimeError(f"{repo}: label inventory contains an invalid entry")
        node_id = entry.get("id")
        if not isinstance(node_id, str) or not node_id:
            raise RuntimeError(
                f"{repo}: label inventory contains an invalid immutable ID"
            )
        raw_description = entry.get("description")
        if raw_description is None:
            description = ""
        elif isinstance(raw_description, str):
            description = raw_description
        else:
            raise RuntimeError(
                f"{repo}: label inventory contains an invalid description"
            )
        name = entry["name"]
        if name in labels:
            raise RuntimeError(f"{repo}: label inventory contains duplicate {name!r}")
        labels[name] = LabelMetadata(node_id=node_id, description=description)
    return labels


def issue_label_names(entry: dict[str, object]) -> set[str]:
    """Normalize label names returned by ``gh issue list --json labels``."""
    labels = entry.get("labels", [])
    if not isinstance(labels, list):
        raise RuntimeError("issue label payload is not a list")
    names: set[str] = set()
    for label in labels:
        name = label.get("name") if isinstance(label, dict) else None
        if not isinstance(name, str) or not name or name in names:
            raise RuntimeError("issue label payload contains an invalid entry")
        names.add(name)
    return names


def _issue_number(entry: dict[str, object]) -> int:
    """Return one exact positive issue number without coercion."""
    number = entry.get("number")
    if type(number) is not int or number <= 0:
        raise RuntimeError("issue payload contains an invalid issue number")
    return number


def _unique_issue_candidate(
    entries: list[dict[str, object]],
    *,
    title: str,
    marker: str,
    identity: str,
    repo: str,
) -> dict[str, object] | None:
    """Find one marker-and-title candidate without treating public text as trust."""
    marker_matches = [
        entry
        for entry in entries
        if marker in str(entry.get("body") or "").splitlines()
    ]
    title_matches = [entry for entry in entries if entry.get("title") == title]
    if len(marker_matches) > 1:
        raise RuntimeError(f"{identity}: multiple marker-bound issues exist in {repo}")
    if not marker_matches:
        if title_matches:
            raise RuntimeError(
                f"{identity}: same-title issue without stable marker exists in "
                f"{repo}; operator reconciliation required"
            )
        return None

    match = marker_matches[0]
    if match.get("title") != title:
        raise RuntimeError(f"{identity}: marker-bound issue title drift in {repo}")
    match_number = match.get("number")
    if any(candidate.get("number") != match_number for candidate in title_matches):
        raise RuntimeError(
            f"{identity}: marker-bound issue conflicts with another same-title "
            f"issue in {repo}; operator reconciliation required"
        )
    return match


def existing_open_epic(
    milestone: Milestone,
    entries: list[dict[str, object]],
    numbers: dict[str, int] | None = None,
    *,
    source_milestones: list[Milestone] | tuple[Milestone, ...] | None = None,
    verified_historical_sources: set[str] | None = None,
) -> int | None:
    """Return one canonical open epic, failing closed on identity drift."""
    match = _unique_issue_candidate(
        entries,
        title=milestone.title,
        marker=epic_identity_marker(milestone),
        identity=milestone.id,
        repo=milestone.epic_home,
    )
    if match is None:
        return None
    if str(match["state"]).upper() != "OPEN":
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic #{match['number']} is not open"
        )
    if EPIC_LABEL not in issue_label_names(match):
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic is missing {EPIC_LABEL!r}"
        )
    try:
        expected_body = render_epic_body(milestone, numbers or {})
    except KeyError as exc:
        raise RuntimeError(
            f"{milestone.id}: marker-bound epic cannot be verified until every "
            "child issue is reconciled"
        ) from exc
    body = str(match.get("body") or "")
    if body != expected_body:
        try:
            historical_milestone = _historical_body_milestone(
                milestone,
                body,
                source_milestones,
                verified_historical_sources,
            )
            historical_body = render_epic_body(historical_milestone, numbers or {})
        except (KeyError, ValueError) as exc:
            raise RuntimeError(
                f"{milestone.id}: marker-bound epic source drift (canonical body "
                f"mismatch) in {milestone.epic_home}"
            ) from exc
        if body != historical_body:
            raise RuntimeError(
                f"{milestone.id}: marker-bound epic source drift (canonical body "
                f"mismatch) in {milestone.epic_home}"
            )
    return _issue_number(match)


def existing_child_issue(
    milestone: Milestone,
    child: Child,
    entries: list[dict[str, object]],
    numbers: dict[str, int] | None = None,
    *,
    require_initial_state: bool = True,
    allow_staged_state: bool = False,
    require_staged_state: bool = False,
    source_milestones: list[Milestone] | tuple[Milestone, ...] | None = None,
    verified_historical_sources: set[str] | None = None,
) -> int | None:
    """Return one canonical child with an explicitly safe lifecycle state."""
    if allow_staged_state and require_staged_state:
        raise ValueError("staged state cannot be both optional and required")
    match = _unique_issue_candidate(
        entries,
        title=child.subject,
        marker=child_identity_marker(child),
        identity=child.id,
        repo=child.repo,
    )
    if match is None:
        return None
    try:
        expected_body = render_child_body(milestone, child, numbers)
    except (KeyError, ValueError) as exc:
        raise RuntimeError(
            f"{child.id}: marker-bound manual gate cannot be verified until "
            "every prerequisite issue is reconciled"
        ) from exc
    body = str(match.get("body") or "")
    if body != expected_body:
        try:
            historical_milestone = _historical_body_milestone(
                milestone,
                body,
                source_milestones,
                verified_historical_sources,
            )
            historical_body = render_child_body(historical_milestone, child, numbers)
        except (KeyError, ValueError) as exc:
            raise RuntimeError(
                f"{child.id}: marker-bound issue source drift (canonical body "
                f"mismatch) in {child.repo}"
            ) from exc
        if body != historical_body:
            raise RuntimeError(
                f"{child.id}: marker-bound issue source drift (canonical body "
                f"mismatch) in {child.repo}"
            )
    labels = issue_label_names(match)
    state_labels = {label for label in labels if label.startswith("state:")}
    issue_state = str(match.get("state") or "").upper()
    if issue_state not in {"OPEN", "CLOSED"}:
        raise RuntimeError(
            f"{child.id}: marker-bound issue has invalid state {issue_state!r}"
        )
    is_staged = REGISTRATION_STAGED_LABEL in labels
    must_be_open = require_initial_state or require_staged_state or is_staged
    if must_be_open and issue_state != "OPEN":
        raise RuntimeError(
            f"{child.id}: marker-bound issue #{match['number']} is not open"
        )
    if child.manual:
        if is_staged:
            raise RuntimeError(
                f"{child.id}: marker-bound manual gate carries dispatch staging "
                f"label {REGISTRATION_STAGED_LABEL!r}"
            )
        expected_state_labels: set[str] = set()
    elif require_staged_state:
        if not is_staged:
            raise RuntimeError(
                f"{child.id}: marker-bound issue is missing non-dispatch staging "
                f"label {REGISTRATION_STAGED_LABEL!r}"
            )
        expected_state_labels = set()
    elif is_staged:
        if not allow_staged_state:
            raise RuntimeError(
                f"{child.id}: marker-bound issue unexpectedly carries staging "
                f"label {REGISTRATION_STAGED_LABEL!r}"
            )
        expected_state_labels = set()
    elif require_initial_state:
        expected_state_labels = {NEEDS_PLAN_LABEL}
    else:
        expected_state_labels = state_labels
        plan_state_labels = state_labels & ISSUE_PLAN_STATE_LABELS
        allowed_lifecycle_labels = ISSUE_PLAN_STATE_LABELS | {ISSUE_SKIP_LABEL}
        if len(plan_state_labels) != 1 or not state_labels <= allowed_lifecycle_labels:
            raise RuntimeError(
                f"{child.id}: marker-bound issue has unsafe lifecycle labels "
                f"{sorted(state_labels)!r}; expected exactly one issue plan "
                f"state and optional {ISSUE_SKIP_LABEL!r}"
            )
    if state_labels != expected_state_labels:
        raise RuntimeError(
            f"{child.id}: marker-bound issue has unsafe state labels "
            f"{sorted(state_labels)!r}; expected {sorted(expected_state_labels)!r}"
        )
    if child.manual and OPERATOR_GATE_LABEL not in labels:
        raise RuntimeError(
            f"{child.id}: marker-bound manual gate is missing {OPERATOR_GATE_LABEL!r}"
        )
    return _issue_number(match)


def issue_creation_order(milestone: Milestone) -> tuple[Child, ...]:
    """Create dispatchable work before gates that need all resulting numbers."""
    return tuple(child for child in milestone.children if not child.manual) + tuple(
        child for child in milestone.children if child.manual
    )


def _git_bytes(*args: str) -> bytes:
    """Run one read-only Git command and return its exact output bytes."""
    command_label = f"git {' '.join(args)}"
    if not args or any(
        not isinstance(value, str) or not value or "\0" in value for value in args
    ):
        raise ValueError("Git arguments must be nonempty strings without NUL bytes")
    if not sys.platform.startswith("linux"):
        raise ValueError("git process containment is unavailable on this host")
    deadline_ns = time.monotonic_ns() + int(COMMAND_TIMEOUT_SECONDS * 1_000_000_000)
    try:
        executable = _resolve_git_executable()
        returncode, stdout, stderr = _run_linux_bound_process(
            executable,
            _git_executable_identity(executable),
            (
                str(executable),
                "--no-pager",
                "--no-replace-objects",
                "--literal-pathspecs",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "credential.helper=",
                *args,
            ),
            _git_environment(),
            deadline_ns=deadline_ns,
            output_limit=GIT_OUTPUT_LIMIT_BYTES,
            termination_grace=GIT_TERMINATION_GRACE_SECONDS,
            label="Git",
        )
    except TimeoutError as exc:
        raise ValueError(
            f"{command_label} timed out after {COMMAND_TIMEOUT_SECONDS}s"
        ) from exc
    except (NotImplementedError, OSError, RuntimeError) as exc:
        raise ValueError(f"{command_label} failed: {exc}") from exc
    if returncode != 0:
        detail = stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(f"{command_label} failed: {detail}")
    return stdout


def _git_blob_digest(content: bytes, object_id: str) -> str:
    """Return the Git blob ID for exact content in the repository hash format."""
    if len(object_id) == 40:
        algorithm = "sha1"
    elif len(object_id) == 64:
        algorithm = "sha256"
    else:
        raise ValueError("Git returned an invalid blob object ID")
    digest = hashlib.new(algorithm, usedforsecurity=False)
    digest.update(f"blob {len(content)}\0".encode("ascii"))
    digest.update(content)
    return digest.hexdigest()


def _git_selected_blobs(commit: str, paths: tuple[str, ...]) -> dict[str, bytes]:
    """Bind selected commit paths to exact blob IDs and verified content."""
    if not paths or len(paths) != len(set(paths)):
        raise ValueError("selected Git blob paths must be nonempty and unique")
    for path in paths:
        normalized = PurePosixPath(path)
        if (
            not path
            or normalized.is_absolute()
            or normalized.as_posix() != path
            or any(part in {"", ".", ".."} for part in normalized.parts)
        ):
            raise ValueError(f"invalid selected Git blob path: {path!r}")
    output = _git_bytes(
        "ls-tree",
        "-z",
        "--format=%(objecttype) %(objectname)%x09%(path)",
        commit,
        "--",
        *paths,
    )
    records = output.split(b"\0")
    if not records or records[-1] != b"":
        raise ValueError(f"{commit}: selected Git blob inventory is truncated")
    object_ids: dict[str, str] = {}
    for record in records[:-1]:
        prefix, separator, raw_path = record.partition(b"\t")
        values = prefix.split(b" ")
        if separator != b"\t" or len(values) != 2 or values[0] != b"blob":
            raise ValueError(f"{commit}: selected Git blob inventory is malformed")
        try:
            path = raw_path.decode("utf-8")
            object_id = values[1].decode("ascii")
        except UnicodeDecodeError as exc:
            raise ValueError(
                f"{commit}: selected Git blob inventory is not canonical text"
            ) from exc
        if (
            path not in paths
            or path in object_ids
            or re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", object_id) is None
        ):
            raise ValueError(f"{commit}: selected Git blob inventory is inconsistent")
        object_ids[path] = object_id
    if set(object_ids) != set(paths):
        raise ValueError(f"{commit}: selected Git blob inventory is incomplete")

    contents: dict[str, bytes] = {}
    for path in paths:
        object_id = object_ids[path]
        content = _git_bytes("cat-file", "blob", object_id)
        if _git_blob_digest(content, object_id) != object_id:
            raise ValueError(f"{commit}:{path}: selected Git blob content changed")
        contents[path] = content
    return contents


def _verify_equivalent_historical_source(
    milestones: tuple[Milestone, ...], historical_sha: str, current_sha: str
) -> None:
    """Verify an older first-parent source with identical selected blobs."""
    if re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", historical_sha) is None:
        raise ValueError("historical source must be one full lowercase Git SHA")
    current_bindings = {milestone.source_sha for milestone in milestones}
    if current_bindings != {current_sha}:
        raise ValueError("selected milestones do not share the current source SHA")
    try:
        object_type = (
            _git_bytes("cat-file", "-t", historical_sha).decode("ascii").strip()
        )
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError(
            f"{historical_sha}: cited historical source commit is unavailable"
        ) from exc
    if object_type != "commit":
        raise ValueError(
            f"{historical_sha}: cited historical source object must be a commit"
        )

    try:
        first_parent_history = (
            _git_bytes("rev-list", "--first-parent", current_sha)
            .decode("ascii")
            .splitlines()
        )
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError(
            f"{current_sha}: current first-parent history is unavailable"
        ) from exc
    if historical_sha not in first_parent_history:
        raise ValueError(
            f"{historical_sha}: cited source is not in the current main "
            "first-parent history"
        )

    payload_root = "tools/github/milestone-epics.d"
    try:
        tree_entries = _git_bytes(
            "ls-tree",
            "-r",
            "-z",
            "--name-only",
            historical_sha,
            "--",
            payload_root,
        ).split(b"\0")
        historical_payloads = {
            entry.decode("utf-8")
            for entry in tree_entries
            if entry and entry.endswith(b".yaml")
        }
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError(
            f"{historical_sha}: historical payload inventory is unavailable"
        ) from exc
    loaded_payloads = {milestone.payload_path for milestone in milestones}
    if historical_payloads != loaded_payloads:
        raise ValueError(
            f"{historical_sha}: historical payload inventory differs from the "
            "current selected inventory"
        )

    sources: dict[str, str] = {}
    for milestone in milestones:
        for path, digest in (
            (milestone.payload_path, milestone.payload_sha256),
            (milestone.workflow, milestone.workflow_sha256),
        ):
            previous = sources.setdefault(path, digest)
            if previous != digest:
                raise ValueError(f"{path}: selected source digests conflict")
    try:
        selected_blobs = _git_selected_blobs(historical_sha, tuple(sorted(sources)))
    except ValueError as exc:
        raise ValueError(
            f"{historical_sha}: historical source blobs are unavailable"
        ) from exc
    for path, expected_digest in sorted(sources.items()):
        source_bytes = selected_blobs[path]
        if hashlib.sha256(source_bytes).hexdigest() != expected_digest:
            raise ValueError(
                f"{historical_sha}:{path}: historical source blob does not match "
                "the current selected bytes"
            )


def _canonical_github_main_sha() -> str:
    """Read the canonical Odysseus main head independent of local Git remotes."""
    try:
        source_sha = gh(
            "api",
            "--hostname",
            "github.com",
            f"repos/{ORG}/Odysseus/git/ref/heads/main",
            "--jq",
            ".object.sha",
        ).strip()
    except RuntimeError as exc:
        raise ValueError("canonical GitHub main source is unavailable") from exc
    if re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", source_sha) is None:
        raise ValueError("canonical GitHub main returned an invalid Git SHA")
    return source_sha


def verify_source_snapshot(milestones: list[Milestone], source_sha: str) -> str:
    """Verify all selected sources against one immutable Git commit."""
    if (
        not isinstance(source_sha, str)
        or re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", source_sha) is None
    ):
        raise ValueError(
            f"{source_sha!r}: source must be an immutable full lowercase Git SHA"
        )

    try:
        object_type = _git_bytes("cat-file", "-t", source_sha).decode("ascii").strip()
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError(
            f"{source_sha}: immutable source commit is unavailable"
        ) from exc
    if object_type != "commit":
        raise ValueError(f"{source_sha}: immutable source object must be a commit")

    payload_root = "tools/github/milestone-epics.d"
    try:
        tree_entries = _git_bytes(
            "ls-tree",
            "-r",
            "-z",
            "--name-only",
            source_sha,
            "--",
            payload_root,
        ).split(b"\0")
        canonical_payloads = {
            entry.decode("utf-8")
            for entry in tree_entries
            if entry and entry.endswith(b".yaml")
        }
    except (UnicodeDecodeError, ValueError) as exc:
        raise ValueError(
            f"{source_sha}: canonical payload inventory is unavailable"
        ) from exc
    loaded_payloads = {milestone.payload_path for milestone in milestones}
    if canonical_payloads != loaded_payloads:
        missing = sorted(canonical_payloads - loaded_payloads)
        unexpected = sorted(loaded_payloads - canonical_payloads)
        raise ValueError(
            f"{source_sha}: canonical payload inventory differs from loaded "
            f"sources; missing locally={missing!r}, unexpected locally="
            f"{unexpected!r}"
        )

    sources: dict[str, str] = {}
    for milestone in milestones:
        selected = (
            (milestone.payload_path, milestone.payload_sha256),
            (milestone.workflow, milestone.workflow_sha256),
        )
        for path, digest in selected:
            previous = sources.setdefault(path, digest)
            if previous != digest:
                raise ValueError(
                    f"{source_sha}:{path}: conflicting loaded source bytes"
                )

    try:
        selected_blobs = _git_selected_blobs(source_sha, tuple(sorted(sources)))
    except ValueError as exc:
        raise ValueError(
            f"{source_sha}: committed source blobs are unavailable"
        ) from exc
    for path, expected_digest in sorted(sources.items()):
        source_bytes = selected_blobs[path]
        actual_digest = hashlib.sha256(source_bytes).hexdigest()
        if actual_digest != expected_digest:
            raise ValueError(
                f"{source_sha}:{path}: committed source blob does not match "
                "the loaded bytes"
            )

    # Consult the fixed github.com authority only after every local source byte
    # has matched its selected blob. Local remote names and URLs are mutable
    # repository configuration and are never consulted.
    canonical_sha = _canonical_github_main_sha()
    if canonical_sha != source_sha:
        raise ValueError(
            f"{source_sha}: source is not canonical GitHub main ({canonical_sha})"
        )

    return source_sha


def _read_registration_state(
    milestones: list[Milestone],
) -> RegistrationState:
    """Read and validate all remote state before a stage is selected."""
    repos = {milestone.epic_home for milestone in milestones}
    repos.update(child.repo for milestone in milestones for child in milestone.children)
    repos.add("Odysseus")
    inventories = {repo: issue_inventory(repo) for repo in sorted(repos)}
    labels = {repo: label_inventory(repo) for repo in sorted(repos)}
    children: dict[str, int | None] = {}
    staged_children: dict[str, int] = {}
    numbers_by_milestone: dict[str, dict[str, int]] = {}
    epics: dict[str, int | None] = {}
    verified_historical_sources: set[str] = set()

    for milestone in milestones:
        numbers: dict[str, int] = {}
        for child in issue_creation_order(milestone):
            number = existing_child_issue(
                milestone,
                child,
                inventories[child.repo],
                numbers,
                require_initial_state=False,
                allow_staged_state=True,
                source_milestones=milestones,
                verified_historical_sources=verified_historical_sources,
            )
            children[child.id] = number
            if number is not None:
                numbers[child.id] = number
                matching_entry = next(
                    entry
                    for entry in inventories[child.repo]
                    if entry["number"] == number
                )
                if not child.manual and REGISTRATION_STAGED_LABEL in issue_label_names(
                    matching_entry
                ):
                    staged_children[child.id] = number
        numbers_by_milestone[milestone.id] = numbers
        epics[milestone.id] = existing_open_epic(
            milestone,
            inventories[milestone.epic_home],
            numbers,
            source_milestones=milestones,
            verified_historical_sources=verified_historical_sources,
        )
        if epics[milestone.id] is None:
            for child in issue_creation_order(milestone):
                if children[child.id] is None:
                    continue
                existing_child_issue(
                    milestone,
                    child,
                    inventories[child.repo],
                    numbers,
                    require_initial_state=child.manual,
                    require_staged_state=not child.manual,
                    source_milestones=milestones,
                    verified_historical_sources=verified_historical_sources,
                )

    return RegistrationState(
        labels=labels,
        registration_lock=labels["Odysseus"].get(REGISTRATION_LOCK_LABEL),
        children=children,
        staged_children=staged_children,
        numbers=numbers_by_milestone,
        epics=epics,
    )


def _missing_label_writes(
    milestones: list[Milestone], state: RegistrationState
) -> tuple[LabelWrite, ...]:
    """Return each missing label as an exact create payload."""
    repos = {milestone.epic_home for milestone in milestones}
    repos.update(child.repo for milestone in milestones for child in milestone.children)
    writes: list[LabelWrite] = []
    for repo in sorted(repos):
        for name, description, color in (
            (EPIC_LABEL, EPIC_LABEL_DESCRIPTION, EPIC_LABEL_COLOR),
            (NEEDS_PLAN_LABEL, NEEDS_PLAN_LABEL_DESCRIPTION, NEEDS_PLAN_LABEL_COLOR),
        ):
            if name not in state.labels[repo]:
                writes.append(
                    LabelWrite(
                        target=f"{ORG}/{repo}",
                        name=name,
                        description=description,
                        color=color,
                    )
                )

    dispatch_repos = {
        child.repo
        for milestone in milestones
        for child in milestone.children
        if not child.manual
    }
    for repo in sorted(dispatch_repos):
        if REGISTRATION_STAGED_LABEL not in state.labels[repo]:
            writes.append(
                LabelWrite(
                    target=f"{ORG}/{repo}",
                    name=REGISTRATION_STAGED_LABEL,
                    description=REGISTRATION_STAGED_LABEL_DESCRIPTION,
                    color=REGISTRATION_STAGED_LABEL_COLOR,
                )
            )

    manual_repos = {
        child.repo
        for milestone in milestones
        for child in milestone.children
        if child.manual
    }
    for repo in sorted(manual_repos):
        if OPERATOR_GATE_LABEL not in state.labels[repo]:
            writes.append(
                LabelWrite(
                    target=f"{ORG}/{repo}",
                    name=OPERATOR_GATE_LABEL,
                    description=OPERATOR_GATE_LABEL_DESCRIPTION,
                    color=OPERATOR_GATE_LABEL_COLOR,
                )
            )
    return tuple(writes)


def next_registration_stage(
    milestones: list[Milestone], state: RegistrationState
) -> RegistrationStage:
    """Select the next bounded stage whose writes are fully known."""
    label_writes = _missing_label_writes(milestones, state)
    if label_writes:
        return RegistrationStage("labels", label_writes)

    child_writes = tuple(
        child_issue_write(milestone, child, state.numbers[milestone.id])
        for milestone in milestones
        if state.epics[milestone.id] is None
        for child in milestone.children
        if not child.manual and state.children[child.id] is None
    )
    if child_writes:
        return RegistrationStage("children", child_writes)

    gate_writes = tuple(
        child_issue_write(milestone, child, state.numbers[milestone.id])
        for milestone in milestones
        if state.epics[milestone.id] is None
        for child in milestone.children
        if child.manual and state.children[child.id] is None
    )
    if gate_writes:
        return RegistrationStage("operator-gates", gate_writes)

    epic_writes = tuple(
        epic_issue_write(milestone, state.numbers[milestone.id])
        for milestone in milestones
        if state.epics[milestone.id] is None
    )
    if epic_writes:
        return RegistrationStage("epics", epic_writes)

    activation_writes = tuple(
        IssueEditWrite(
            target=f"{ORG}/{child.repo}",
            number=state.staged_children[child.id],
            add_label=NEEDS_PLAN_LABEL,
            remove_label=REGISTRATION_STAGED_LABEL,
        )
        for milestone in milestones
        for child in milestone.children
        if not child.manual and child.id in state.staged_children
    )
    if activation_writes:
        return RegistrationStage("activation", activation_writes)
    return RegistrationStage("complete", ())


def registration_stage_digest(stage: RegistrationStage, source_sha: str) -> str:
    """Bind one reviewed stage to its source and ordered write specifications."""
    return _source_digest(
        {
            "schema": "homeric-milestone-registration-stage/v1",
            "source_sha": source_sha,
            "stage": stage.name,
            "writes": [write.payload() for write in stage.writes],
        }
    )


def _guarded_registration_stage(
    stage: RegistrationStage,
    *,
    lock_description: str = REGISTRATION_LOCK_PLANNED_DESCRIPTION,
) -> RegistrationStage:
    """Wrap a mutating stage in the canonical remote lock policy."""
    if not stage.writes:
        return stage
    target = f"{ORG}/Odysseus"
    acquire = LabelWrite(
        target=target,
        name=REGISTRATION_LOCK_LABEL,
        description=lock_description,
        color=REGISTRATION_LOCK_LABEL_COLOR,
    )
    release = LabelDeleteWrite(target=target, name=REGISTRATION_LOCK_LABEL)
    return RegistrationStage(stage.name, (acquire, *stage.writes, release))


def _preflight_registration_stage(stage: RegistrationStage) -> None:
    """Bind every command in one exact stage before any remote mutation."""
    for write in stage.writes:
        _bound_gh_args(*write.gh_args())


class RegistrationLockOwnershipError(RuntimeError):
    """The active registration lock does not belong to this invocation."""


def _new_registration_lock_description() -> str:
    """Return one fresh lock description with 128 bits of owner identity."""
    owner_token = secrets.token_hex(16)
    return (
        f"{REGISTRATION_LOCK_LABEL_DESCRIPTION}"
        f"{REGISTRATION_LOCK_OWNER_SEPARATOR}{owner_token}"
    )


def _acquire_registration_lock(acquire: LabelWrite) -> LabelMetadata:
    """Create the lock and return the immutable identity from that write."""
    node_id = gh(
        "api",
        f"repos/{acquire.target}/labels",
        "--method",
        "POST",
        "-f",
        f"name={acquire.name}",
        "-f",
        f"description={acquire.description}",
        "-f",
        f"color={acquire.color}",
        "--jq",
        ".node_id",
    ).strip()
    if not node_id or any(character.isspace() for character in node_id):
        raise RuntimeError(
            "registration lock was created without one immutable label ID; "
            "operator recovery is required"
        )
    print(f"  created {acquire.target} label {acquire.name}")
    return LabelMetadata(node_id=node_id, description=acquire.description)


def _require_registration_lock_owner(
    expected_description: str, expected_node_id: str | None = None
) -> LabelMetadata:
    """Return the lock only when its owner and immutable identity are exact."""
    labels = label_inventory("Odysseus")
    lock = labels.get(REGISTRATION_LOCK_LABEL)
    if (
        lock is None
        or lock.description != expected_description
        or (expected_node_id is not None and lock.node_id != expected_node_id)
    ):
        raise RegistrationLockOwnershipError(
            "registration lock owner changed or the lock disappeared"
        )
    return lock


def _release_registration_lock(
    release: LabelDeleteWrite,
    expected_description: str,
    expected_node_id: str,
) -> None:
    """Release the lock only while this invocation remains its exact owner."""
    _require_registration_lock_owner(expected_description, expected_node_id)
    gh(
        "api",
        "graphql",
        "-f",
        (
            "query=mutation($labelId:ID!){"
            "deleteLabel(input:{id:$labelId}){clientMutationId}}"
        ),
        "-F",
        f"labelId={expected_node_id}",
    )
    print(f"  deleted {release.target} label {release.name}")


def _prepare_registration(
    milestones: list[Milestone], source_sha: str
) -> tuple[list[Milestone], RegistrationStage]:
    """Verify the source and return the next exact remote-write stage."""
    errors = validate(milestones, require_complete_inventory=False)
    if errors:
        raise ValueError(f"invalid milestone plan: {'; '.join(errors)}")
    verify_source_snapshot(milestones, source_sha)
    bound = [replace(milestone, source_sha=source_sha) for milestone in milestones]
    state = _read_registration_state(bound)
    if state.registration_locked:
        raise RuntimeError(
            f"{ORG}/Odysseus carries {REGISTRATION_LOCK_LABEL!r}; another "
            "registration stage may be active or require operator recovery"
        )
    stage = next_registration_stage(bound, state)
    _preflight_registration_stage(_guarded_registration_stage(stage))
    return bound, stage


def _apply_remote_write(
    write: LabelWrite | LabelDeleteWrite | IssueWrite | IssueEditWrite,
) -> None:
    """Apply one reviewed write and reject ambiguous issue-create output."""
    output = gh(*write.gh_args())
    if isinstance(write, IssueWrite):
        issue_number_from_url(output, expected_target=write.target)
        print(f"  created {output.strip()}")
    elif isinstance(write, LabelWrite):
        print(f"  created {write.target} label {write.name}")
    elif isinstance(write, LabelDeleteWrite):
        print(f"  deleted {write.target} label {write.name}")
    else:
        print(f"  activated {write.target}#{write.number} with {write.add_label}")


def apply_plan(
    milestones: list[Milestone], source_sha: str, reviewed_digest: str
) -> int:
    """Apply one reviewed, retry-safe registration stage."""
    if re.fullmatch(r"[0-9a-f]{64}", reviewed_digest) is None:
        raise ValueError("reviewed plan digest must be one lowercase SHA-256 value")
    bound, business_stage = _prepare_registration(milestones, source_sha)
    stage = _guarded_registration_stage(business_stage)
    _preflight_registration_stage(stage)
    actual_digest = registration_stage_digest(stage, source_sha)
    if reviewed_digest != actual_digest:
        raise ValueError(
            "reviewed plan digest does not match the current registration stage"
        )

    print(f"Verified source commit: {source_sha}")
    print(f"Applying reviewed stage: {stage.name}")
    if not stage.writes:
        print("Milestone registration is already complete.")
        return 0

    planned_acquire = stage.writes[0]
    release = stage.writes[-1]
    if not isinstance(planned_acquire, LabelWrite) or not isinstance(
        release, LabelDeleteWrite
    ):
        raise AssertionError("mutating registration stage lacks lock guards")

    lock_description = _new_registration_lock_description()
    acquire = replace(planned_acquire, description=lock_description)
    _bound_gh_args(*acquire.gh_args())
    acquired_lock = _acquire_registration_lock(acquire)
    lock_node_id = acquired_lock.node_id
    business_started = False
    lock_released = False
    try:
        locked_state = _read_registration_state(bound)
        owned_lock = locked_state.registration_lock
        if owned_lock != acquired_lock:
            raise RegistrationLockOwnershipError(
                "registration lock owner changed or the lock disappeared"
            )
        current_business_stage = next_registration_stage(bound, locked_state)
        current_stage = _guarded_registration_stage(current_business_stage)
        _preflight_registration_stage(current_stage)
        current_digest = registration_stage_digest(current_stage, source_sha)
        if current_digest != reviewed_digest:
            _release_registration_lock(release, lock_description, lock_node_id)
            lock_released = True
            raise ValueError(
                "remote state changed before the registration lock was acquired; "
                "run --plan again"
            )

        for write in current_business_stage.writes:
            _require_registration_lock_owner(lock_description, lock_node_id)
            business_started = True
            _apply_remote_write(write)
        _release_registration_lock(release, lock_description, lock_node_id)
        lock_released = True
    except Exception:
        if not business_started and not lock_released:
            try:
                _release_registration_lock(release, lock_description, lock_node_id)
            except RegistrationLockOwnershipError:
                pass
            except Exception as release_error:
                raise RuntimeError(
                    "registration failed before business writes and its lock "
                    "could not be released; operator recovery is required"
                ) from release_error
        raise

    print("Stage applied. Run --plan again to review the next exact stage.")
    return 0


def plan_mode(milestones: list[Milestone], source_sha: str) -> int:
    """Print the next reviewed registration stage without remote writes."""
    _, business_stage = _prepare_registration(milestones, source_sha)
    stage = _guarded_registration_stage(business_stage)
    _preflight_registration_stage(stage)
    digest = registration_stage_digest(stage, source_sha)
    print(f"Verified source commit: {source_sha}")
    print(f"STAGE {stage.name}")
    print(f"PLAN_SHA256 {digest}")
    for write in stage.writes:
        print(f"WRITE {json.dumps(write.payload(), sort_keys=True)}")
    if not stage.writes:
        print("No remote writes are required.")
    return 0


def check_mode(milestones: list[Milestone]) -> int:
    """Report a successful offline structural validation."""
    total = sum(len(milestone.children) for milestone in milestones)
    print(f"Validated {len(milestones)} milestones and {total} children.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    target = parser.add_mutually_exclusive_group()
    target.add_argument("--check", action="store_true", help="validate local sources")
    target.add_argument(
        "--plan",
        action="store_true",
        help="print the next exact business writes and lock-owner policy",
    )
    target.add_argument(
        "--apply", action="store_true", help="apply one reviewed remote-write stage"
    )
    parser.add_argument(
        "--source-sha",
        help="current canonical GitHub main SHA that owns plan or apply sources",
    )
    parser.add_argument(
        "--plan-digest",
        help="exact PLAN_SHA256 value from the current --plan output",
    )
    args = parser.parse_args(argv)
    if (args.plan or args.apply) and args.source_sha is None:
        parser.error("--plan and --apply require --source-sha")
    if not (args.plan or args.apply) and args.source_sha is not None:
        parser.error("--source-sha requires --plan or --apply")
    if args.apply and args.plan_digest is None:
        parser.error("--apply requires --plan-digest")
    if not args.apply and args.plan_digest is not None:
        parser.error("--plan-digest requires --apply")

    milestones = load_payloads()
    errors = validate(milestones)
    if errors:
        for err in errors:
            print(f"ERROR: {err}", file=sys.stderr)
        return 2
    if args.apply:
        return apply_plan(milestones, args.source_sha, args.plan_digest)
    if args.plan:
        return plan_mode(milestones, args.source_sha)
    return check_mode(milestones)


if __name__ == "__main__":
    raise SystemExit(main())
