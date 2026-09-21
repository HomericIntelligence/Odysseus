#!/usr/bin/env python3
"""Fail-closed gate (#179): documented Grafana default creds must carry an
adjacent rotation WARNING, and anonymous dashboard read must be explicitly
marked e2e-only. Scope is `git ls-files` — THIS repo's tracked files only,
never submodule content this repo cannot edit. `--self-test` runs unit checks.
"""

import os as _bootstrap_os
import sys as _bootstrap_sys


if not _bootstrap_sys.flags.isolated:
    _bootstrap_executable = _bootstrap_sys.executable
    if not _bootstrap_executable or not _bootstrap_os.path.isabs(
        _bootstrap_executable
    ):
        raise SystemExit("error: cannot isolate the selected Python interpreter")
    _bootstrap_os.execve(
        _bootstrap_executable,
        [
            _bootstrap_executable,
            "-I",
            _bootstrap_os.path.abspath(__file__),
            *_bootstrap_sys.argv[1:],
        ],
        {
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "PYTHONDONTWRITEBYTECODE": "1",
        },
    )

import codecs
import contextlib
import hashlib
import io
import json
import mmap
import os
import ast
import re
import resource
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time
import types
from pathlib import Path, PurePosixPath

import yaml
from yaml.events import AliasEvent



def _load_git_guard():
    """Load the exact sibling helper without adding the checkout to sys.path."""
    required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")
    if any(not hasattr(os, name) for name in required):
        raise RuntimeError("safe helper loading is unavailable")
    helper_name = "check_doc_field_drift.py"
    helper_directory = os.path.dirname(os.path.abspath(__file__))
    flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptors = []
    links = []
    helper_fd = -1
    try:
        root_fd = os.open("/", flags)
        descriptors.append(root_fd)
        current = root_fd
        for component in Path(helper_directory).parts[1:]:
            child = os.open(component, flags, dir_fd=current)
            metadata = os.fstat(child)
            identity = (metadata.st_dev, metadata.st_ino, metadata.st_mode)
            links.append((current, component, child, identity))
            descriptors.append(child)
            current = child
        helper_fd = os.open(
            helper_name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=current,
        )
        before = os.fstat(helper_fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size > 256 * 1024
        ):
            raise RuntimeError("Git guard helper is not a bounded direct file")
        chunks = []
        remaining = 256 * 1024 + 1
        while remaining:
            chunk = os.read(helper_fd, min(65_536, remaining))
            if not chunk:
                break
            chunks.append(chunk)
            remaining -= len(chunk)
        source = b"".join(chunks)
        after = os.fstat(helper_fd)
        def identity(item):
            return (
                item.st_dev,
                item.st_ino,
                item.st_mode,
                item.st_nlink,
                item.st_size,
                item.st_mtime_ns,
                item.st_ctime_ns,
            )
        named = os.stat(helper_name, dir_fd=current, follow_symlinks=False)
        if len(source) > 256 * 1024 or identity(before) != identity(after):
            raise RuntimeError("Git guard helper changed while it was read")
        if identity(named) != identity(before):
            raise RuntimeError("Git guard helper name changed while it was read")
        for parent_fd, name, child_fd, expected in links:
            named_directory = os.stat(
                name, dir_fd=parent_fd, follow_symlinks=False
            )
            opened_directory = os.fstat(child_fd)
            if (
                not stat.S_ISDIR(named_directory.st_mode)
                or (
                    named_directory.st_dev,
                    named_directory.st_ino,
                    named_directory.st_mode,
                )
                != expected
                or (
                    opened_directory.st_dev,
                    opened_directory.st_ino,
                    opened_directory.st_mode,
                )
                != expected
            ):
                raise RuntimeError("Git guard helper route changed while loading")
        module = types.ModuleType("_odysseus_staged_git_guard")
        module.__file__ = os.path.join(helper_directory, helper_name)
        module.__package__ = None
        exec(compile(source, module.__file__, "exec"), module.__dict__)
        return module
    finally:
        if helper_fd >= 0:
            os.close(helper_fd)
        for descriptor in reversed(descriptors):
            os.close(descriptor)


try:
    _GIT_GUARD = _load_git_guard()
except (OSError, RuntimeError, ImportError, SyntaxError):
    sys.stderr.write("Grafana credential-hygiene check unavailable: Git input guard could not load\n")
    raise SystemExit(2)
RepositoryBinding = _GIT_GUARD.RepositoryBinding
CheckFailure = _GIT_GUARD.CheckFailure
_run_git = _GIT_GUARD._run_git
_run_git_to_fd = _GIT_GUARD._run_git_to_fd

E2E_MARKER_RE = re.compile(
    rb"(?P<indent>[ \t]*)#\s*e2e-only:\s*anonymous\b", re.IGNORECASE
)
E2E_COMPOSE_PATHS = frozenset(
    {
        "docker-compose.e2e.yml",
        "e2e/docker-compose.chaos.yml",
        "e2e/docker-compose.cluster.yml",
        "e2e/docker-compose.scale.yml",
    }
)
WARN_WINDOW = 3  # docs: forward look-ahead from the credential line
ANON_LOOKBACK = 2  # compose: lines above the flag the e2e-only marker may sit on
ANON_SETTING = "GF_AUTH_ANONYMOUS_ENABLED"
MAX_INVENTORY_BYTES = 2 * 1024 * 1024
MAX_TRACKED_INPUTS = 4_096
MAX_YAML_DOCUMENTS = 8
MAX_YAML_NODES = 10_000
MAX_YAML_DEPTH = 50
MAX_YAML_ALIASES = 0
SCAN_DEADLINE_SECONDS = 30.0
MAX_FINDINGS = 1_000
MAX_DIAGNOSTIC_BYTES = 64 * 1024
MAX_DIAGNOSTIC_MESSAGE_BYTES = 2 * 1024
MAX_DISPLAY_PATH_BYTES = 1_024
MAX_YAML_RESULT_BYTES = 64 * 1024
MAX_YAML_RESULT_LINES = MAX_FINDINGS + 1
YAML_WORKER_CPU_SECONDS = 5
YAML_WORKER_WALL_SECONDS = 10.0
YAML_WORKER_MEMORY_BYTES = 1024 * 1024 * 1024
YAML_WORKER_FILE_BYTES = 0
YAML_WORKER_OPEN_FILES = 32
YAML_WORKER_PROCESSES = 1
TRACKED_SUFFIXES = (b".md", b".yml", b".yaml")
_DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT = False


def _check_deadline(deadline: float) -> None:
    if time.monotonic() >= deadline:
        raise CheckFailure("credential validation exceeded its deadline")


def _bounded_diagnostic(message: str) -> str:
    candidate = message[:MAX_DIAGNOSTIC_MESSAGE_BYTES]
    encoded = candidate.encode("utf-8", "replace")
    if len(encoded) <= MAX_DIAGNOSTIC_MESSAGE_BYTES and len(candidate) == len(message):
        return candidate
    prefix = encoded[: MAX_DIAGNOSTIC_MESSAGE_BYTES - 3]
    return prefix.decode("utf-8", "replace") + "..."


class FindingBudget:
    """Retain bounded diagnostics without weakening the fail result."""

    def __init__(self):
        self.errors = []
        self.bytes = 0
        self.exhausted = False

    def add(self, message: str) -> bool:
        if self.exhausted:
            return False
        bounded = _bounded_diagnostic(message)
        addition = len(("  - " + bounded + "\n").encode("utf-8", "replace"))
        if len(self.errors) >= MAX_FINDINGS or self.bytes + addition > MAX_DIAGNOSTIC_BYTES:
            self.errors.append("additional findings omitted after output limit")
            self.exhausted = True
            return False
        self.errors.append(bounded)
        self.bytes += addition
        return True


class YamlPolicyError(ValueError):
    """A content-free YAML policy failure with an optional source position."""

    def __init__(self, classification: str, source=None):
        super().__init__(classification)
        self.classification = classification
        mark = getattr(source, "start_mark", source)
        line = getattr(mark, "line", None)
        column = getattr(mark, "column", None)
        self.line = line + 1 if isinstance(line, int) and line >= 0 else None
        self.column = column + 1 if isinstance(column, int) and column >= 0 else None


class BoundedSafeLoader(yaml.SafeLoader):
    """SafeLoader with explicit structural budgets."""

    def __init__(self, stream, deadline):
        super().__init__(stream)
        self._gate_deadline = deadline
        self._gate_nodes = 0
        self._gate_depth = 0
        self._gate_aliases = 0

    def compose_node(self, parent, index):
        _check_deadline(self._gate_deadline)
        if self.check_event(AliasEvent):
            self._gate_aliases += 1
            if self._gate_aliases > MAX_YAML_ALIASES:
                raise yaml.YAMLError("YAML alias limit exceeded")
        self._gate_nodes += 1
        if self._gate_nodes > MAX_YAML_NODES:
            raise yaml.YAMLError("YAML node limit exceeded")
        self._gate_depth += 1
        if self._gate_depth > MAX_YAML_DEPTH:
            raise yaml.YAMLError("YAML depth limit exceeded")
        try:
            node = super().compose_node(parent, index)
            _check_deadline(self._gate_deadline)
            return node
        finally:
            self._gate_depth -= 1


def _display_path(path: bytes) -> str:
    shortened = len(path) > MAX_DISPLAY_PATH_BYTES
    decoded = os.fsdecode(path[:MAX_DISPLAY_PATH_BYTES])
    if any(
        ord(character) < 32
        or ord(character) == 127
        or 0xD800 <= ord(character) <= 0xDFFF
        for character in decoded
    ):
        decoded = repr(decoded)
    if shortened:
        return decoded + "..."
    return decoded


def _parse_tracked_inventory(
    raw: bytes, selected_path: bytes | None = None
) -> list[tuple[bytes, str]]:
    if raw and not raw.endswith(b"\0"):
        raise CheckFailure("Git returned a malformed tracked-file inventory")
    records = raw[:-1].split(b"\0") if raw else []
    inputs = []
    for record in records:
        try:
            metadata, path = record.split(b"\t", 1)
            mode, object_id, stage = metadata.split(b" ")
        except ValueError as error:
            raise CheckFailure("Git returned a malformed index entry") from error
        if stage != b"0":
            raise CheckFailure("unmerged index entries cannot be validated")
        if selected_path is not None:
            if path != selected_path:
                continue
        elif not path.lower().endswith(TRACKED_SUFFIXES):
            continue
        if mode not in (b"100644", b"100755"):
            raise CheckFailure(
                "%s: tracked validation input is not a regular blob"
                % _display_path(path)
            )
        if not re.fullmatch(rb"[0-9a-f]{40}|[0-9a-f]{64}", object_id):
            raise CheckFailure("Git returned an invalid validation object ID")
        inputs.append((path, object_id.decode("ascii")))
        if len(inputs) > MAX_TRACKED_INPUTS:
            raise CheckFailure("tracked validation input count exceeds its limit")
    return inputs


def _verify_blob_file(object_id: str, size: int, stream, deadline: float) -> None:
    algorithm = "sha1" if len(object_id) == 40 else "sha256"
    digest = hashlib.new(algorithm)
    digest.update(b"blob " + str(size).encode("ascii") + b"\0")
    stream.seek(0)
    while True:
        _check_deadline(deadline)
        chunk = stream.read(65_536)
        if not chunk:
            break
        digest.update(chunk)
    if digest.hexdigest() != object_id:
        raise CheckFailure("Git returned validation bytes with the wrong object ID")
    stream.seek(0)


class TrackedBlobFiles:
    """Yield one exact staged blob at a time from a retained index binding."""

    def __init__(self, root: Path, deadline: float):
        self.root = root
        self.deadline = deadline
        self.bound = None
        self.initial_inventory = None
        self.inventory = []
        self.position = 0
        self.current = None

    def __enter__(self):
        self.bound = RepositoryBinding(self.root)
        try:
            self.initial_inventory = _run_git(
                self.bound.git_fd,
                self.bound.index_fd,
                ["ls-files", "--stage", "-z"],
                MAX_INVENTORY_BYTES,
                self.deadline,
            )
            self.inventory = _parse_tracked_inventory(self.initial_inventory)
            return self
        except BaseException:
            self.bound.close()
            self.bound = None
            raise

    def __iter__(self):
        return self

    def __next__(self):
        self._close_current()
        if self.position >= len(self.inventory):
            raise StopIteration
        _check_deadline(self.deadline)
        path, object_id = self.inventory[self.position]
        self.position += 1
        self._validate_worktree_type(path)
        self.current = self._open_blob(object_id)
        return path, self.current

    def open_reference(self, path: bytes):
        """Open one referenced regular blob from the same retained index.

        The caller owns the returned stream. Opening a reference must not close
        the current Compose stream or consult mutable worktree content.
        """
        _check_deadline(self.deadline)
        entries = _parse_tracked_inventory(self.initial_inventory, path)
        if not entries:
            return None
        if len(entries) != 1:
            raise CheckFailure("referenced validation path is ambiguous")
        if not self._validate_worktree_type(path):
            return None
        return self._open_blob(entries[0][1])

    def _validate_worktree_type(self, path: bytes) -> bool:
        """Reject symlink/type replacements without reading worktree contents."""
        parts = path.split(b"/")
        if any(part in (b"", b".", b"..") for part in parts):
            raise CheckFailure("validation path is not repository relative")
        descriptor = os.dup(self.bound.root.fd)
        try:
            for part in parts[:-1]:
                child = os.open(
                    part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=descriptor,
                )
                os.close(descriptor)
                descriptor = child
            metadata = os.stat(parts[-1], dir_fd=descriptor, follow_symlinks=False)
            if not stat.S_ISREG(metadata.st_mode):
                raise CheckFailure("validation worktree path is not a regular file")
            return True
        except FileNotFoundError:
            return False
        finally:
            os.close(descriptor)

    def _open_blob(self, object_id: str):
        _check_deadline(self.deadline)
        size_output = _run_git(
            self.bound.git_fd,
            self.bound.index_fd,
            ["cat-file", "-s", object_id],
            128,
            self.deadline,
        ).strip()
        if not size_output.isdigit():
            raise CheckFailure("Git returned an invalid blob size")
        size = int(size_output)
        stream = tempfile.TemporaryFile()
        try:
            written = _run_git_to_fd(
                self.bound.git_fd,
                self.bound.index_fd,
                ["cat-file", "blob", object_id],
                stream.fileno(),
                size,
                self.deadline,
            )
            stream.flush()
            metadata = os.fstat(stream.fileno())
            if (
                written != size
                or not stat.S_ISREG(metadata.st_mode)
                or metadata.st_size != size
            ):
                raise CheckFailure("Git returned a blob with the wrong size")
            _verify_blob_file(object_id, size, stream, self.deadline)
        except BaseException:
            stream.close()
            raise
        return stream

    def _close_current(self):
        if self.current is not None:
            self.current.close()
            self.current = None

    def __exit__(self, exception_type, _exception, _traceback):
        self._close_current()
        try:
            if exception_type is None and self.bound is not None:
                final_inventory = _run_git(
                    self.bound.git_fd,
                    self.bound.index_fd,
                    ["ls-files", "--stage", "-z"],
                    MAX_INVENTORY_BYTES,
                    self.deadline,
                )
                if final_inventory != self.initial_inventory:
                    raise CheckFailure(
                        "Git index changed during credential validation"
                    )
                self.bound.revalidate()
        finally:
            if self.bound is not None:
                self.bound.close()
                self.bound = None
        return False


CRED_RE = re.compile(r"admin\s*/\s*admin", re.IGNORECASE)
# Accept one narrow affirmative admonition grammar. The action must immediately
# follow the marker and directly name the credential object; advisory prose that
# merely contains the same words is not authority for the exception.
AFFIRMATIVE_WARNING_RE = re.compile(
    r"^\s*(?:>\s*)?(?:\*\*)?(?:warning|caution|important)\b"
    r"\s*:?\s*(?:\*\*)?\s*"
    r"(?:rotate|change|replace)\s+"
    r"(?:(?:this|these|the|that|default|documented|example|grafana|admin)\s+){0,3}"
    r"(?:password|credentials?|secrets?|admin\s*/\s*admin)\b"
    r"(?:\s+(?:before\s+(?:any\s+production\s+or\s+shared-network\s+use|"
    r"(?:any\s+)?production(?:\s+use)?|use)|immediately|now))?"
    r"[.!]?\s*$",
    re.IGNORECASE,
)
ANON_NAME = "GF_AUTH_ANONYMOUS_ENABLED"
ANON_NAME_RE = re.compile(rf"\b{ANON_NAME}\b", re.IGNORECASE)
YAML_HEX_ESCAPE_RE = re.compile(
    r"\\x(?P<x>[0-9a-fA-F]{2})|\\u(?P<u>[0-9a-fA-F]{4})|"
    r"\\U(?P<U>[0-9a-fA-F]{8})"
)
# Only an affirmative YAML comment is authority for this exception. Incidental
# or negated prose containing the same words must not satisfy the gate.
E2E_MARKER = re.compile(r"^\s*#\s*e2e-only\s*:", re.IGNORECASE)
ANON_E2E_PATHS = frozenset({"docker-compose.e2e.yml"})
WARN_WINDOW = 3      # docs: forward look-ahead from the credential line
ANON_LOOKBACK = 2   # compose: lines above the flag the e2e-only marker may sit on


def _is_rotation_warning(line: str) -> bool:
    return bool(AFFIRMATIVE_WARNING_RE.fullmatch(line))


def _marker_is_yaml_comment(
    lines: list[str], marker_index: int, setting_index: int
) -> bool:
    """Accept only a sibling-indented physical YAML comment marker."""
    marker = lines[marker_index]
    marker_indent = len(marker) - len(marker.lstrip(" "))
    setting = lines[setting_index]
    setting_indent = len(setting) - len(setting.lstrip(" "))
    # The exemption is intentionally narrower than general YAML comment
    # placement: the marker must be a physical comment at the setting's exact
    # indentation. Block/quoted scalar content is necessarily deeper than the
    # real sibling setting and cannot grant the exception.
    return marker_indent == setting_indent


def _canonicalize_yaml_escapes(text: str) -> str:
    """Expose YAML hexadecimal escapes before the fail-closed name check."""

    def replace(match: re.Match[str]) -> str:
        digits = next(group for group in match.groups() if group is not None)
        try:
            return chr(int(digits, 16))
        except (ValueError, OverflowError):
            return match.group(0)

    return YAML_HEX_ESCAPE_RE.sub(replace, text)


def _strip_yaml_comment(text: str) -> str:
    """Strip only an unquoted YAML comment introduced after whitespace."""
    single = False
    double = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if double:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                double = False
        elif single:
            if char == "'" and index + 1 < len(text) and text[index + 1] == "'":
                index += 1
            elif char == "'":
                single = False
        elif char == '"':
            double = True
        elif char == "'":
            single = True
        elif char == "#" and (index == 0 or text[index - 1].isspace()):
            return text[:index].rstrip()
        index += 1
    return text.rstrip()


def _split_mapping(text: str) -> tuple[str, str] | None:
    """Split one simple YAML mapping at its first unquoted colon."""
    single = False
    double = False
    escaped = False
    index = 0
    while index < len(text):
        char = text[index]
        if double:
            if escaped:
                escaped = False
            elif char == "\\":
                escaped = True
            elif char == '"':
                double = False
        elif single:
            if char == "'" and index + 1 < len(text) and text[index + 1] == "'":
                index += 1
            elif char == "'":
                single = False
        elif char == '"':
            double = True
        elif char == "'":
            single = True
        elif char == ":":
            return text[:index].strip(), text[index + 1 :].strip()
        index += 1
    return None


def _decode_yaml_scalar(text: str) -> str | None:
    """Decode the bounded scalar forms accepted by Compose environment syntax."""
    text = text.strip()
    if not text:
        return ""
    if text.startswith('"'):
        try:
            value = ast.literal_eval(text)
        except (SyntaxError, ValueError):
            return None
        return value if isinstance(value, str) else None
    if text.startswith("'"):
        if not re.fullmatch(r"'(?:[^']|'')*'", text):
            return None
        return text[1:-1].replace("''", "'")
    if any(character.isspace() for character in text):
        return None
    return text


def _literal_bool(text: str) -> bool | None:
    scalar = _decode_yaml_scalar(text)
    if scalar is None:
        return None
    if scalar.casefold() == "true":
        return True
    if scalar.casefold() == "false":
        return False
    return None


def _anonymous_assignment(line: str) -> tuple[bool, bool | None]:
    """Return whether a line assigns the setting and its literal value."""
    canonical = _canonicalize_yaml_escapes(line)
    text = _strip_yaml_comment(line).strip()
    if not text or text.startswith("#"):
        return False, None

    if text.startswith("-"):
        item = _decode_yaml_scalar(text[1:].strip())
        if item is not None and "=" in item:
            key, value = item.split("=", 1)
            if key.casefold() == ANON_NAME.casefold():
                return True, _literal_bool(value)
        # A list mapping is not canonical Compose syntax, but identify it so it
        # fails as an unknown form instead of being skipped.
        text = text[1:].strip()

    mapping = _split_mapping(text)
    if mapping:
        key_text, value_text = mapping
        key = _decode_yaml_scalar(key_text)
        if key is not None and key.casefold() == ANON_NAME.casefold():
            return True, _literal_bool(value_text)

    # Any visible or hex-escaped spelling that did not match the closed grammar
    # is an unsafe/dynamic use, not an unrelated line.
    return bool(ANON_NAME_RE.search(canonical)), None


def _inside_double_quote(text: str) -> bool:
    """Return whether the end of a physical YAML line is double-quoted."""
    double = False
    escaped = False
    for char in text:
        if not double:
            if char == '"':
                double = True
            continue
        if escaped:
            escaped = False
        elif char == "\\":
            escaped = True
        elif char == '"':
            double = False
    return double


def _logical_yaml_lines(lines: list[str]) -> list[tuple[int, str]]:
    """Join YAML double-quoted escaped line continuations for inspection."""
    logical: list[tuple[int, str]] = []
    buffer = ""
    start = 0
    for index, physical in enumerate(lines):
        if not buffer:
            start = index
            buffer = physical
        else:
            buffer += physical.lstrip()

        stripped = buffer.rstrip()
        trailing = len(stripped) - len(stripped.rstrip("\\"))
        if _inside_double_quote(stripped) and trailing % 2 == 1:
            buffer = stripped[:-1]
            continue
        logical.append((start, buffer))
        buffer = ""
    if buffer:
        logical.append((start, buffer))
    return logical


def _environment_lines(lines: list[str]) -> set[int]:
    """Return physical line indexes belonging to Compose environment nodes."""
    indexes: set[int] = set()
    environment_indent: int | None = None
    for index, physical in enumerate(lines):
        text = _strip_yaml_comment(physical)
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip(" "))
        if environment_indent is not None:
            if indent > environment_indent:
                indexes.add(index)
                continue
            environment_indent = None

        mapping = _split_mapping(text.strip())
        if mapping is None:
            continue
        key = _decode_yaml_scalar(mapping[0])
        if key is None or key.casefold() != "environment":
            continue
        indexes.add(index)
        if not mapping[1].strip():
            environment_indent = indent
    return indexes


def _dynamic_environment_key(line: str) -> bool:
    """Reject Compose interpolation in an environment variable name."""
    text = _strip_yaml_comment(line).strip()
    if not text:
        return False

    mapping = _split_mapping(text)
    if mapping is not None:
        outer_key = _decode_yaml_scalar(mapping[0])
        if outer_key is not None and outer_key.casefold() == "environment":
            value = mapping[1]
            # Inline list and mapping forms. Values may be dynamic; only a
            # variable-name position is rejected here.
            if re.search(
                r"(?:^|[\[{,])\s*['\"]?\s*\$\{[^}\r\n]+\}"
                r"(?:[^='\"\r\n]*=|\s*['\"]?\s*:)",
                value,
            ):
                return True
            return False

    if text.startswith("-"):
        item = _decode_yaml_scalar(text[1:].strip())
        if item is None:
            item = text[1:].strip().strip("'\"")
        key = item.split("=", 1)[0]
        return "$" in key

    if mapping is not None:
        key = _decode_yaml_scalar(mapping[0])
        if key is None:
            key = mapping[0]
        return "$" in key
    return False


def _environment_uses_yaml_indirection(line: str) -> bool:
    """Reject aliases, anchors, and merge keys on an environment node/member."""
    text = _strip_yaml_comment(line)
    return bool(
        re.search(r"(?:^|[\s\[{,:-])[&*](?=[^\s\[\]{},])", text)
        or re.search(r"(?:^|[\s\[{,])<<\s*:", text)
    )


def _grafana_service_keys(lines: list[str]) -> set[str]:
    """Recognize Grafana images independently of a Compose service's name.

    Inspect the complete service before resolving env_file, since image may
    appear after it. Retain the conventional name for image-less overlays.
    """
    names = {"grafana"}
    services_indent: int | None = None
    service_indent: int | None = None
    service: str | None = None
    field_indent: int | None = None
    for physical in lines:
        text = _strip_yaml_comment(physical)
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip(" "))
        mapping = _split_mapping(text.strip())
        key = _decode_yaml_scalar(mapping[0]) if mapping else None
        if services_indent is not None and indent <= services_indent:
            services_indent = service_indent = field_indent = None
            service = None
        if services_indent is None:
            if key == "services" and mapping is not None and not mapping[1]:
                services_indent = indent
            continue
        if service_indent is None:
            service_indent = indent
        if indent == service_indent:
            service = key
            field_indent = None
            continue
        if service is None or mapping is None:
            continue
        if field_indent is None:
            field_indent = indent
        if indent != field_indent or key != "image":
            continue
        value = _decode_yaml_scalar(mapping[1])
        if (value is None or not value or "$" in value
                or value[0] in "!&*|>[{"
                or _environment_uses_yaml_indirection(physical)):
            # A dynamic image cannot prove that the service is unrelated.
            names.add(service.casefold())
            continue
        image_name = value.split("@", 1)[0].rsplit("/", 1)[-1].split(":", 1)[0]
        if image_name in {"grafana", "grafana-oss", "grafana-enterprise"}:
            names.add(service.casefold())
    return names


def _grafana_env_file_targets(lines: list[str]) -> list[tuple[int, str | None]]:
    """Return literal short-syntax env_file entries for the Grafana service.

    ``None`` marks an entry whose syntax is not a single literal scalar.  This
    intentionally rejects interpolation, aliases, inline collections, and the
    long mapping syntax rather than attempting a partial Compose parser.
    """
    targets: list[tuple[int, str | None]] = []
    grafana_keys = _grafana_service_keys(lines)
    services_indent: int | None = None
    service_indent: int | None = None
    grafana_service = False
    env_file_indent: int | None = None
    env_file_line: int | None = None
    env_file_had_entry = False

    for index, physical in enumerate(lines):
        text = _strip_yaml_comment(physical)
        if not text.strip():
            continue
        indent = len(text) - len(text.lstrip(" "))
        stripped = text.strip()

        if env_file_indent is not None:
            if indent > env_file_indent:
                env_file_had_entry = True
                if not stripped.startswith("-") or _environment_uses_yaml_indirection(
                    physical
                ):
                    targets.append((index, None))
                else:
                    targets.append((index, _decode_yaml_scalar(stripped[1:].strip())))
                continue
            if not env_file_had_entry and env_file_line is not None:
                targets.append((env_file_line, None))
            env_file_indent = None
            env_file_line = None
            env_file_had_entry = False

        mapping = _split_mapping(stripped)
        key = _decode_yaml_scalar(mapping[0]) if mapping is not None else None

        if services_indent is not None and indent <= services_indent:
            services_indent = None
            service_indent = None
            grafana_service = False

        if services_indent is None:
            if (
                mapping is not None
                and key is not None
                and key.casefold() == "services"
            ):
                if mapping[1]:
                    targets.append((index, None))
                else:
                    services_indent = indent
            continue

        if service_indent is None:
            service_indent = indent

        if indent == service_indent:
            if _environment_uses_yaml_indirection(physical):
                targets.append((index, None))
                grafana_service = False
                continue
            is_grafana = bool(
                mapping is not None
                and key is not None
                and key.casefold() in grafana_keys
            )
            if is_grafana and mapping is not None and mapping[1]:
                targets.append((index, None))
            grafana_service = is_grafana and mapping is not None and not mapping[1]
            continue

        if not grafana_service or mapping is None or key is None:
            continue
        if _environment_uses_yaml_indirection(physical):
            targets.append((index, None))
            continue
        if key.casefold() != "env_file":
            continue
        if not mapping[1]:
            env_file_indent = indent
            env_file_line = index
            continue
        targets.append((index, _decode_yaml_scalar(mapping[1])))

    if (
        env_file_indent is not None
        and not env_file_had_entry
        and env_file_line is not None
    ):
        targets.append((env_file_line, None))
    return targets


def _bind_env_file_target(compose_relative: str, target: str) -> str | None:
    """Bind one literal Compose env_file path inside the repository."""
    if (
        not target
        or target[0] in "[{!&*|>"
        or "$" in target
        or "\x00" in target
        or "\n" in target
        or "\r" in target
    ):
        return None
    path = PurePosixPath(target)
    if path.is_absolute() or ".." in path.parts:
        return None
    bound = PurePosixPath(compose_relative).parent / path
    if not bound.parts or any(part in {"", ".", ".."} for part in bound.parts):
        return None
    return bound.as_posix()


def _has_e2e_marker(
    lines: list[str],
    setting_index: int,
    *,
    allowed_indexes: set[int] | None = None,
) -> bool:
    """Return whether a same-indent e2e-only comment authorizes a setting."""
    context_start = max(0, setting_index - ANON_LOOKBACK)
    return any(
        (allowed_indexes is None or marker_index in allowed_indexes)
        and E2E_MARKER.search(lines[marker_index])
        and _marker_is_yaml_comment(lines, marker_index, setting_index)
        for marker_index in range(context_start, setting_index + 1)
    )


def _env_comment_lines(lines: list[str]) -> set[int]:
    """Return e2e marker lines that are outside multiline dotenv quotes."""
    indexes: set[int] = set()
    quote: str | None = None
    for index, line in enumerate(lines):
        if quote is None and E2E_MARKER.search(line):
            indexes.add(index)

        escaped = False
        for offset, character in enumerate(line):
            if quote is not None:
                if escaped:
                    escaped = False
                elif character == "\\":
                    escaped = True
                elif character == quote:
                    quote = None
                continue
            if character == "#" and (offset == 0 or line[offset - 1].isspace()):
                break
            if character in {"'", '"'}:
                quote = character
    return indexes


def _tracked_blob_files(root: Path, deadline: float):
    return TrackedBlobFiles(root, deadline)


def _decoded_line_chunks(mapped, start, end, deadline):
    decoder = codecs.getincrementaldecoder("utf-8")("replace")
    offset = start
    while offset < end:
        _check_deadline(deadline)
        chunk_end = min(offset + 65_536, end)
        yield decoder.decode(
            mapped[offset:chunk_end],
            final=chunk_end == end,
        )
        offset = chunk_end


def _normalized_warning_line(mapped, start, end, deadline):
    """Normalize whitespace with bounded storage for the warning grammar."""
    characters = []
    pending_space = False
    for text in _decoded_line_chunks(mapped, start, end, deadline):
        for character in text:
            if character.isspace():
                pending_space = bool(characters)
                continue
            if pending_space:
                characters.append(" ")
                pending_space = False
            characters.append(character)
            # The finite affirmative grammar cannot match a longer normalized
            # sentence. This bounds matcher state, not document input size.
            if len(characters) > 512:
                return None
    return "".join(characters)


def _has_rotation_warning(mapped, lines, deadline) -> bool:
    """Require an affirmative credential-rotation admonition, not keywords."""
    normalized = [
        _normalized_warning_line(mapped, start, end, deadline)
        for _number, start, end in lines
    ]
    for index, line in enumerate(normalized):
        if line is None:
            continue
        sentence = line
        for continuation in normalized[index + 1:]:
            if continuation is None or not continuation.startswith(">"):
                break
            sentence += " " + continuation[1:].lstrip()
        if _is_rotation_warning(sentence):
            return True
    return False


def _line_has_credentials(mapped, start, end, deadline) -> bool:
    """Find the credential token with bounded UTF-8 decoding state."""
    states = set()
    for text in _decoded_line_chunks(mapped, start, end, deadline):
        for character in text:
            folded = character.casefold()
            following = {1} if folded == "a" else set()
            for state in states:
                if state == 1 and folded == "d":
                    following.add(2)
                elif state == 2 and folded == "m":
                    following.add(3)
                elif state == 3 and folded == "i":
                    following.add(4)
                elif state == 4 and folded == "n":
                    following.add(5)
                elif state in (5, 6):
                    if character.isspace():
                        following.add(6)
                    elif character == "/":
                        following.add(7)
                elif state == 7:
                    if character.isspace():
                        following.add(7)
                    elif folded == "a":
                        following.add(8)
                elif state == 8 and folded == "d":
                    following.add(9)
                elif state == 9 and folded == "m":
                    following.add(10)
                elif state == 10 and folded == "i":
                    following.add(11)
                elif state == 11 and folded == "n":
                    return True
            states = following
    return False


def _mapped_lines(mapped, deadline):
    line_number = 1
    start = 0
    length = len(mapped)
    while start < length:
        search = start
        newline = -1
        while search < length:
            _check_deadline(deadline)
            search_end = min(search + 65_536, length)
            newline = mapped.find(b"\n", search, search_end)
            if newline >= 0 or search_end == length:
                break
            search = search_end
        next_start = length if newline < 0 else newline + 1
        end = length if newline < 0 else newline
        if end > start and mapped[end - 1] == 13:
            end -= 1
        yield line_number, start, end
        line_number += 1
        start = next_start


def check_docs(blobs, findings: FindingBudget, deadline: float) -> None:
    """Check staged Markdown blobs for unsafe documented credentials."""
    for path, stream in blobs:
        if findings.exhausted:
            return
        if not path.lower().endswith(b".md"):
            continue
        if os.fstat(stream.fileno()).st_size == 0:
            continue
        stream.seek(0)
        with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
            pending = []

            def check_window() -> None:
                line_number, start, end = pending[0]
                if _line_has_credentials(
                    mapped,
                    start,
                    end,
                    deadline,
                ) and not _has_rotation_warning(
                    mapped,
                    pending,
                    deadline,
                ):
                    findings.add(
                        f"{_display_path(path)}:{line_number}: 'admin/admin' "
                        f"with no credential-rotation warning within "
                        f"{WARN_WINDOW} lines"
                    )
            for line in _mapped_lines(mapped, deadline):
                pending.append(line)
                if len(pending) > WARN_WINDOW:
                    check_window()
                    if findings.exhausted:
                        return
                    pending.pop(0)
            while pending:
                check_window()
                if findings.exhausted:
                    return
                pending.pop(0)


def _mapping_lookup(node, expected: str, seen=None):
    """Return the effective YAML mapping entry, including merge aliases."""
    if not isinstance(node, yaml.MappingNode):
        return None
    visited = set() if seen is None else set(seen)
    if id(node) in visited:
        return None
    visited.add(id(node))
    explicit = None
    merges = []
    for key_node, value_node in node.value:
        if key_node.tag == "tag:yaml.org,2002:merge":
            if isinstance(value_node, yaml.MappingNode):
                merges.append(value_node)
            elif isinstance(value_node, yaml.SequenceNode):
                merges.extend(
                    item
                    for item in value_node.value
                    if isinstance(item, yaml.MappingNode)
                )
        elif isinstance(key_node, yaml.ScalarNode) and key_node.value == expected:
            explicit = (key_node, value_node)
    if explicit is not None:
        return explicit
    for merged in merges:
        found = _mapping_lookup(merged, expected, visited)
        if found is not None:
            return found
    return None


def _literal_enabled(value: object, source=None) -> bool:
    """Return a literal anonymous-auth state or reject an unresolved value."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().casefold()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    raise YamlPolicyError("invalid anonymous-auth literal", source)


def _environment_mark(environment: object, node, *, strict: bool = True):
    """Return the source line for one effective enabled setting."""
    source_node = None
    if isinstance(environment, dict):
        if any(not isinstance(key, str) or "$" in key for key in environment):
            raise YamlPolicyError("nonliteral environment key", node)
        if ANON_SETTING not in environment:
            return None
        found = _mapping_lookup(node, ANON_SETTING)
        if found is None:
            raise YamlPolicyError("missing anonymous-auth source", node)
        if not _literal_enabled(environment[ANON_SETTING], found[1]):
            return None
        source_node = found[0]
    elif isinstance(environment, list):
        enabled_index = None
        for index, item in enumerate(environment):
            if not isinstance(item, str):
                if strict:
                    raise YamlPolicyError("nonliteral environment key", node)
                continue
            name, separator, value = item.partition("=")
            if strict and "$" in name:
                raise YamlPolicyError("nonliteral environment key", node)
            if name.strip() != ANON_SETTING:
                continue
            if not separator:
                raise YamlPolicyError(
                    "missing anonymous-auth literal",
                    node.value[index] if index < len(node.value) else node,
                )
            enabled_index = (
                index
                if _literal_enabled(
                    value,
                    node.value[index] if index < len(node.value) else node,
                )
                else None
            )
        if enabled_index is None or not isinstance(node, yaml.SequenceNode):
            return None
        if enabled_index < len(node.value):
            source_node = node.value[enabled_index]
    if source_node is None:
        raise YamlPolicyError("missing anonymous-auth source", node)
    line_number = source_node.start_mark.line
    if line_number < 0:
        raise YamlPolicyError("invalid anonymous-auth source", source_node)
    return line_number


def _anonymous_entries(document: object, node):
    """Find effective enabled Grafana environment values in one YAML document."""
    results = set()
    pending = [(document, node)]
    visited = set()
    while pending:
        value, value_node = pending.pop()
        identity = (id(value), id(value_node))
        if identity in visited:
            continue
        visited.add(identity)
        if isinstance(value, dict) and isinstance(value_node, yaml.MappingNode):
            if ANON_SETTING in value:
                mark = _environment_mark(value, value_node)
                if mark is not None:
                    results.add(mark)
            if "environment" in value:
                found = _mapping_lookup(value_node, "environment")
                if found is None:
                    raise YamlPolicyError(
                        "missing environment source",
                        value_node,
                    )
                mark = _environment_mark(value["environment"], found[1])
                if mark is not None:
                    results.add(mark)
            for key, child in value.items():
                found = _mapping_lookup(value_node, str(key))
                if found is not None:
                    pending.append((child, found[1]))
        elif isinstance(value, list) and isinstance(value_node, yaml.SequenceNode):
            # Standalone YAML fragments can carry environment assignments too.
            # Other list members need not be environment entries; explicit
            # environment blocks retain the strict validation above.
            mark = _environment_mark(value, value_node, strict=False)
            if mark is not None:
                results.add(mark)
            pending.extend(zip(value, value_node.value))
    return sorted(results)


def _reject_duplicate_yaml_keys(node) -> None:
    pending = [node]
    visited = set()
    while pending:
        current = pending.pop()
        if id(current) in visited:
            continue
        visited.add(id(current))
        if isinstance(current, yaml.MappingNode):
            keys = set()
            for key_node, value_node in current.value:
                if isinstance(key_node, yaml.ScalarNode):
                    if key_node.tag == "tag:yaml.org,2002:merge":
                        raise YamlPolicyError(
                            "YAML merge keys are not permitted",
                            key_node,
                        )
                    identity = (key_node.tag, key_node.value)
                    if identity in keys:
                        raise YamlPolicyError(
                            "duplicate YAML mapping key",
                            key_node,
                        )
                    keys.add(identity)
                pending.extend((key_node, value_node))
        elif isinstance(current, yaml.SequenceNode):
            pending.extend(current.value)


def _load_bounded_yaml(source, deadline):
    loader = BoundedSafeLoader(source, deadline)
    document_count = 0
    try:
        while True:
            _check_deadline(deadline)
            if not loader.check_node():
                break
            if document_count >= MAX_YAML_DOCUMENTS:
                raise yaml.YAMLError("YAML document limit exceeded")
            node = loader.get_node()
            _reject_duplicate_yaml_keys(node)
            document = loader.construct_document(node)
            document_count += 1
            yield document, node
    finally:
        loader.dispose()


def _yaml_error_position(error):
    mark = getattr(error, "problem_mark", None)
    if mark is None:
        mark = getattr(error, "context_mark", None)
    line = getattr(mark, "line", None)
    column = getattr(mark, "column", None)
    return (
        line + 1 if isinstance(line, int) and 0 <= line <= 2**31 else None,
        column + 1 if isinstance(column, int) and 0 <= column <= 2**31 else None,
    )


def _yaml_worker_payload(source, deadline, dotenv=False):
    try:
        if dotenv:
            lines = source.read().splitlines()
            _check_deadline(deadline)
            markers = _env_comment_lines(lines)
            entries = []
            unmarked = []
            for index, line in enumerate(lines):
                _check_deadline(deadline)
                matched, value = _anonymous_assignment(f"- {line}")
                if not matched or value is False:
                    continue
                if value is None:
                    raise YamlPolicyError("invalid anonymous-auth literal")
                if len(entries) >= MAX_YAML_RESULT_LINES:
                    return {
                        "status": "error",
                        "kind": "resource",
                        "classification": "worker result limit",
                        "line": None,
                        "column": None,
                    }
                entries.append(index)
                if not _has_e2e_marker(lines, index, allowed_indexes=markers):
                    unmarked.append(index)
            return {
                "status": "ok", "lines": entries,
                "env_files": [], "unmarked_lines": unmarked,
            }
        entries = []
        for document, node in _load_bounded_yaml(source, deadline):
            for line in _anonymous_entries(document, node):
                if len(entries) >= MAX_YAML_RESULT_LINES:
                    return {
                        "status": "error",
                        "kind": "resource",
                        "classification": "worker result limit",
                        "line": None,
                        "column": None,
                    }
                entries.append(line)
        # Resolve Compose references inside the same resource-bounded worker.
        # The parent receives paths only, never environment-file contents.
        source.seek(0)
        _check_deadline(deadline)
        env_files = _grafana_env_file_targets(source.read().splitlines())
        _check_deadline(deadline)
        if len(env_files) > MAX_YAML_RESULT_LINES:
            return {
                "status": "error",
                "kind": "resource",
                "classification": "worker result limit",
                "line": None,
                "column": None,
            }
        return {"status": "ok", "lines": entries, "env_files": env_files}
    except YamlPolicyError as error:
        return {
            "status": "error",
            "kind": "policy",
            "classification": error.classification,
            "line": error.line,
            "column": error.column,
        }
    except UnicodeError:
        return {
            "status": "error",
            "kind": "encoding",
            "classification": "invalid UTF-8",
            "line": None,
            "column": None,
        }
    except yaml.YAMLError as error:
        syntax_types = (
            yaml.scanner.ScannerError,
            yaml.parser.ParserError,
            yaml.composer.ComposerError,
            yaml.constructor.ConstructorError,
        )
        line, column = _yaml_error_position(error)
        return {
            "status": "error",
            "kind": "syntax" if isinstance(error, syntax_types) else "structure",
            "classification": (
                "syntax error"
                if isinstance(error, syntax_types)
                else "YAML structure limit"
            ),
            "line": line,
            "column": column,
        }
    except CheckFailure:
        return {
            "status": "error",
            "kind": "resource",
            "classification": "worker deadline exceeded",
            "line": None,
            "column": None,
        }
    except (MemoryError, RecursionError):
        return {
            "status": "error",
            "kind": "resource",
            "classification": "worker resource limit",
            "line": None,
            "column": None,
        }


def _set_worker_limit(limit_name, requested, minimum=None):
    limit = getattr(resource, limit_name, None)
    if limit is None:
        raise RuntimeError("required worker resource limit is unavailable")
    _soft, hard = resource.getrlimit(limit)
    selected = requested if hard == resource.RLIM_INFINITY else min(requested, hard)
    if minimum is not None and selected < minimum:
        raise RuntimeError("required worker resource limit is too small")
    resource.setrlimit(limit, (selected, selected))


def _apply_yaml_worker_limits():
    _set_worker_limit("RLIMIT_CPU", YAML_WORKER_CPU_SECONDS, 1)
    if sys.platform.startswith("linux"):
        _set_worker_limit("RLIMIT_AS", YAML_WORKER_MEMORY_BYTES, 128 * 1024 * 1024)
        _set_worker_limit("RLIMIT_DATA", YAML_WORKER_MEMORY_BYTES)
    elif not (
        sys.platform == "darwin" and _DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT
    ):
        raise RuntimeError("YAML worker memory containment requires Linux")
    _set_worker_limit("RLIMIT_FSIZE", YAML_WORKER_FILE_BYTES)
    _set_worker_limit("RLIMIT_NOFILE", YAML_WORKER_OPEN_FILES, 8)
    _set_worker_limit("RLIMIT_NPROC", YAML_WORKER_PROCESSES, 1)
    if hasattr(resource, "RLIMIT_CORE"):
        _set_worker_limit("RLIMIT_CORE", 0)


def _close_yaml_worker_fds(keep):
    descriptor_directory = "/proc/self/fd" if sys.platform.startswith("linux") else "/dev/fd"
    try:
        descriptors = [int(item) for item in os.listdir(descriptor_directory)]
    except (OSError, ValueError) as error:
        raise RuntimeError("cannot enumerate worker descriptors") from error
    for descriptor in descriptors:
        if descriptor > 2 and descriptor not in keep:
            try:
                os.close(descriptor)
            except OSError:
                pass


def _write_yaml_worker_result(descriptor, payload):
    encoded = json.dumps(payload, separators=(",", ":"), sort_keys=True).encode(
        "ascii"
    )
    if len(encoded) > MAX_YAML_RESULT_BYTES:
        encoded = (
            b'{"classification":"worker result limit",'
            b'"column":null,"kind":"resource","line":null,'
            b'"status":"error"}'
        )
    view = memoryview(encoded)
    while view:
        written = os.write(descriptor, view)
        if written <= 0:
            raise OSError("cannot write YAML worker result")
        view = view[written:]


def _kill_yaml_worker(pid, process_group_ready):
    if process_group_ready:
        try:
            os.killpg(pid, signal.SIGKILL)
        except OSError:
            pass
    try:
        os.kill(pid, signal.SIGKILL)
    except OSError:
        pass


def _yaml_worker_group_exists(pid):
    try:
        os.killpg(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _finish_yaml_worker(pid, status, process_group_ready, terminate):
    cleanup_deadline = time.monotonic() + 1.0
    if terminate:
        _kill_yaml_worker(pid, process_group_ready)
    while status is None and time.monotonic() < cleanup_deadline:
        try:
            waited, candidate = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if waited == pid:
            status = candidate
            break
        if terminate:
            _kill_yaml_worker(pid, process_group_ready)
        time.sleep(0.01)
    if status is None:
        _kill_yaml_worker(pid, process_group_ready)
        return None

    surviving_group = process_group_ready and _yaml_worker_group_exists(pid)
    if not surviving_group:
        return status

    group_deadline = time.monotonic() + 1.0
    while _yaml_worker_group_exists(pid):
        _kill_yaml_worker(pid, True)
        if time.monotonic() >= group_deadline:
            break
        time.sleep(0.01)
    return None


def _contained_yaml_parse(stream, deadline, dotenv=False):
    if not sys.platform.startswith("linux") and not (
        sys.platform == "darwin" and _DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT
    ):
        raise CheckFailure("YAML worker containment requires Linux")
    result_read, result_write = os.pipe()
    ready_read, ready_write = os.pipe()
    stream.seek(0)
    try:
        pid = os.fork()
    except BaseException as error:
        for descriptor in (result_read, result_write, ready_read, ready_write):
            os.close(descriptor)
        raise CheckFailure("YAML worker could not start") from error

    if pid == 0:  # pragma: no cover - observed through the supervising parent
        try:
            os.close(result_read)
            os.close(ready_read)
            os.setsid()
            os.write(ready_write, b"1")
            os.close(ready_write)
            _close_yaml_worker_fds({stream.fileno(), result_write})
            _apply_yaml_worker_limits()
            raw = os.fdopen(os.dup(stream.fileno()), "rb", buffering=0)
            source = io.TextIOWrapper(raw, encoding="utf-8", errors="strict")
            try:
                payload = _yaml_worker_payload(
                    source,
                    min(deadline, time.monotonic() + YAML_WORKER_WALL_SECONDS),
                    dotenv=dotenv,
                )
            finally:
                source.close()
            _write_yaml_worker_result(result_write, payload)
            os.close(result_write)
            os._exit(0)
        except BaseException:
            try:
                _write_yaml_worker_result(
                    result_write,
                    {
                        "status": "error",
                        "kind": "resource",
                        "classification": "worker containment failure",
                        "line": None,
                        "column": None,
                    },
                )
            except BaseException:
                pass
            os._exit(1)

    os.close(result_write)
    os.close(ready_write)
    for descriptor in (result_read, ready_read):
        os.set_blocking(descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(result_read, selectors.EVENT_READ, "result")
    selector.register(ready_read, selectors.EVENT_READ, "ready")
    result = bytearray()
    status = None
    failure = None
    process_group_ready = False
    worker_deadline = min(deadline, time.monotonic() + YAML_WORKER_WALL_SECONDS)
    try:
        while selector.get_map() or status is None:
            if status is None:
                try:
                    waited, candidate = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    failure = "YAML worker could not be supervised"
                    break
                if waited == pid:
                    status = candidate
            remaining = worker_deadline - time.monotonic()
            if remaining <= 0:
                failure = "YAML worker exceeded its wall deadline"
                break
            events = selector.select(min(remaining, 0.05)) if selector.get_map() else []
            for key, _mask in events:
                try:
                    chunk = os.read(key.fd, 65_536)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    os.close(key.fd)
                    continue
                if key.data == "ready":
                    selector.unregister(key.fd)
                    os.close(key.fd)
                    if chunk == b"1":
                        process_group_ready = True
                    else:
                        failure = "YAML worker containment was not established"
                    continue
                if len(result) + len(chunk) > MAX_YAML_RESULT_BYTES:
                    failure = "YAML worker result exceeded its byte limit"
                    break
                result.extend(chunk)
            if failure:
                break
    finally:
        status = _finish_yaml_worker(
            pid,
            status,
            process_group_ready,
            terminate=failure is not None or status is None,
        )
        for key in list(selector.get_map().values()):
            try:
                selector.unregister(key.fd)
                os.close(key.fd)
            except OSError:
                pass
        selector.close()
    if failure is not None:
        return {
            "status": "error",
            "kind": "resource",
            "classification": failure,
            "line": None,
            "column": None,
        }
    if status is None or not os.WIFEXITED(status) or os.WEXITSTATUS(status) != 0:
        return {
            "status": "error",
            "kind": "resource",
            "classification": "worker containment failure",
            "line": None,
            "column": None,
        }
    try:
        payload = json.loads(bytes(result))
    except (UnicodeError, json.JSONDecodeError):
        raise CheckFailure("YAML worker returned a malformed result")
    if not isinstance(payload, dict) or payload.get("status") not in ("ok", "error"):
        raise CheckFailure("YAML worker returned an invalid result")
    if payload["status"] == "ok":
        lines = payload.get("lines")
        if (
            not isinstance(lines, list)
            or len(lines) > MAX_YAML_RESULT_LINES
            or any(type(line) is not int or line < 0 for line in lines)
        ):
            raise CheckFailure("YAML worker returned invalid source lines")
        env_files = payload.get("env_files", [])
        if (
            not isinstance(env_files, list)
            or len(env_files) > MAX_YAML_RESULT_LINES
            or any(
                not isinstance(entry, list)
                or len(entry) != 2
                or type(entry[0]) is not int
                or entry[0] < 0
                or (entry[1] is not None and not isinstance(entry[1], str))
                for entry in env_files
            )
        ):
            raise CheckFailure("YAML worker returned invalid environment references")
        unmarked = payload.get("unmarked_lines", [])
        if (
            not isinstance(unmarked, list)
            or len(unmarked) > MAX_YAML_RESULT_LINES
            or any(type(line) is not int or line not in lines for line in unmarked)
            or (dotenv and "unmarked_lines" not in payload)
        ):
            raise CheckFailure("worker returned invalid environment marker results")
        return payload
    allowed_kinds = {"encoding", "policy", "resource", "structure", "syntax"}
    allowed_classifications = {
        "YAML merge keys are not permitted",
        "YAML structure limit",
        "duplicate YAML mapping key",
        "invalid UTF-8",
        "invalid anonymous-auth literal",
        "invalid anonymous-auth source",
        "missing anonymous-auth literal",
        "missing anonymous-auth source",
        "missing environment source",
        "nonliteral environment key",
        "syntax error",
        "worker containment failure",
        "worker deadline exceeded",
        "worker resource limit",
        "worker result limit",
    }
    if (
        payload.get("kind") not in allowed_kinds
        or payload.get("classification") not in allowed_classifications
        or payload.get("line") is not None
        and (not isinstance(payload["line"], int) or payload["line"] < 1)
        or payload.get("column") is not None
        and (not isinstance(payload["column"], int) or payload["column"] < 1)
    ):
        raise CheckFailure("YAML worker returned an invalid diagnostic")
    return payload


def _yaml_finding(path, result):
    location = _display_path(path)
    if result.get("line") is not None:
        location += ":%d" % result["line"]
        if result.get("column") is not None:
            location += ":%d" % result["column"]
    return "%s: YAML rejected (%s) [type=%s]" % (
        location,
        result["classification"],
        result["kind"],
    )


def _marker_status(mapped, entries, deadline):
    targets = set(entries)
    status = {}
    previous = []
    for line_number, start, end in _mapped_lines(mapped, deadline):
        zero_based = line_number - 1
        if zero_based in targets:
            target_indent = 0
            while (
                start + target_indent < end
                and mapped[start + target_indent] in (9, 32)
            ):
                target_indent += 1
            marked = False
            for _prior_number, prior_start, prior_end in previous:
                marker = E2E_MARKER_RE.match(
                    mapped,
                    prior_start,
                    prior_end,
                )
                if marker is not None:
                    indent_start, indent_end = marker.span("indent")
                    if indent_end - indent_start == target_indent:
                        marked = True
                        break
            status[zero_based] = marked
        previous.append((line_number, start, end))
        if len(previous) > ANON_LOOKBACK:
            previous.pop(0)
    return status


def _check_environment_references(
    path, references, reader, findings: FindingBudget, deadline: float
):
    for source_line, target_text in references:
        _check_deadline(deadline)
        if findings.exhausted:
            return
        location = f"{_display_path(path)}:{source_line + 1}"
        target = (
            _bind_env_file_target(os.fsdecode(path), target_text)
            if target_text is not None else None
        )
        if target is None:
            findings.add(location + ": Grafana env_file requires a literal repository path")
            continue
        if reader is None:
            raise CheckFailure("staged environment reference reader is unavailable")
        stream = reader.open_reference(os.fsencode(target))
        if stream is None:
            findings.add(location + ": Grafana env_file target is missing or untracked")
            continue
        with stream:
            result = _contained_yaml_parse(stream, deadline, dotenv=True)
        if result["status"] == "error":
            findings.add(_yaml_finding(os.fsencode(target), result))
            continue
        for line in result["lines"]:
            target_location = f"{_display_path(os.fsencode(target))}:{line + 1}"
            if os.fsdecode(path) not in E2E_COMPOSE_PATHS:
                findings.add(target_location + ": anonymous Grafana read is not allowed here")
            elif line in result["unmarked_lines"]:
                findings.add(target_location + ": anonymous Grafana read requires an e2e-only comment")


def check_compose(
    blobs, findings: FindingBudget, deadline: float, reference_reader=None
) -> None:
    """Parse staged YAML and enforce the anonymous Grafana e2e marker."""
    for path, stream in blobs:
        if findings.exhausted:
            return
        if not path.lower().endswith((b".yml", b".yaml")):
            continue
        result = _contained_yaml_parse(stream, deadline)
        if result["status"] == "error":
            findings.add(_yaml_finding(path, result))
            continue
        _check_environment_references(
            path, result.get("env_files", []), reference_reader, findings, deadline
        )
        entries = result["lines"]
        display_path = _display_path(path)
        marker_status = {}
        if entries and os.fstat(stream.fileno()).st_size:
            stream.seek(0)
            with mmap.mmap(stream.fileno(), 0, access=mmap.ACCESS_READ) as mapped:
                marker_status = _marker_status(mapped, entries, deadline)
        for i in sorted(set(entries)):
            relative = os.fsdecode(path)
            if relative not in E2E_COMPOSE_PATHS:
                findings.add(
                    f"{display_path}:{i + 1}: anonymous Grafana "
                    f"read enabled outside a canonical e2e Compose file"
                )
                continue
            if not marker_status.get(i, False):
                findings.add(
                    f"{display_path}:{i + 1}: anonymous Grafana "
                    f"read enabled without a same-indent "
                    f"'# e2e-only: anonymous' "
                    f"comment within {ANON_LOOKBACK} lines above"
                )


def _run(root: Path) -> int:
    findings = FindingBudget()
    deadline = time.monotonic() + SCAN_DEADLINE_SECONDS
    try:
        with _tracked_blob_files(root, deadline) as blobs:
            for path, stream in blobs:
                if path.lower().endswith(b".md"):
                    check_docs(((path, stream),), findings, deadline)
                else:
                    check_compose(
                        ((path, stream),), findings, deadline, reference_reader=blobs
                    )
                if findings.exhausted:
                    break
        errs = findings.errors
    except (CheckFailure, OSError) as error:
        classification = (
            "trusted input boundary rejected the repository"
            if isinstance(error, CheckFailure)
            else "operating-system input failure"
        )
        sys.stderr.write("Grafana credential-hygiene check unavailable: " + classification + "\n")
        return 2
    if errs:
        sys.stderr.write("Grafana credential-hygiene check FAILED (#179):\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        sys.stderr.write(
            f"\nFix: add `> **WARNING:** Rotate this password before production` "
            f"adjacent to the\ncredential, or add a same-indent "
            f"`# e2e-only: anonymous ...` comment in a canonical e2e Compose "
            f"file\nwithin {ANON_LOOKBACK} lines above the "
            f"GF_AUTH_ANONYMOUS_ENABLED line.\n"
        )
        return 1
    print("Grafana credential hygiene OK.")
    return 0


def _self_test_git(directory: str, *arguments: str) -> None:
    command = [
        "/usr/bin/git",
        "--no-replace-objects",
        "-c",
        "core.fsmonitor=false",
        "-c",
        "core.hooksPath=/dev/null",
        "-c",
        "protocol.allow=never",
        "-C",
        directory,
        *arguments,
    ]
    environment = {
        "GIT_ALLOW_PROTOCOL": "",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "XDG_CONFIG_HOME": "/nonexistent",
    }
    try:
        result = subprocess.run(
            command,
            cwd="/",
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5.0,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError("self-test Git exceeded its deadline") from error
    if len(result.stdout) > 64 * 1024 or len(result.stderr) > 64 * 1024:
        raise RuntimeError("self-test Git output exceeded its byte limit")
    if result.returncode != 0:
        diagnostic = result.stderr.decode("utf-8", "replace").strip()
        raise RuntimeError("self-test Git failed: " + diagnostic[:1_000])


def _staged_input_self_test() -> int:
    """Embedded unit tests — stdlib only, no pytest (repo has no py test harness)."""
    global _DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT
    _DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT = sys.platform == "darwin"
    cases: list[tuple[str, bool, int, int]] = [
        (
            "declared_invocation_is_isolated",
            bool(sys.flags.isolated),
            int(not sys.flags.isolated),
            0,
        )
    ]

    def case(name: str, files: dict[str, str], want: int) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _self_test_git(d, "init", "-q", "--object-format=sha1")
            for rel, body in files.items():
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(body)
            _self_test_git(d, "add", "--", *files)
            got = _run(root)
            cases.append((name, got == want, got, want))

    def diagnostic_case(
        name: str,
        files: dict[str, str],
        want: int,
        required: tuple[str, ...],
        forbidden: tuple[str, ...],
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _self_test_git(directory, "init", "-q", "--object-format=sha1")
            for relative, body in files.items():
                target = root / relative
                target.parent.mkdir(parents=True, exist_ok=True)
                target.write_text(body, encoding="utf-8")
            _self_test_git(directory, "add", "--", *files)
            stdout = io.StringIO()
            stderr = io.StringIO()
            with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                got = _run(root)
            output = stdout.getvalue() + stderr.getvalue()
            ok = (
                got == want
                and len(output.encode("utf-8")) <= 128 * 1024
                and all(item in output for item in required)
                and all(item not in output for item in forbidden)
            )
            cases.append((name, ok, int(not ok), 0))

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
    case(
        "unrelated_warning_does_not_satisfy",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Rotate logs before production.\n"
            )
        },
        1,
    )
    case(
        "unrelated_default_warning_does_not_satisfy",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the default log rotation policy.\n"
            )
        },
        1,
    )
    case(
        "uppercase_markdown_is_scanned",
        {"unsafe.MD": "Default credentials: `admin / admin`\n"},
        1,
    )
    case(
        "unicode_whitespace_credentials_are_scanned_across_chunks",
        {
            "unicode.md": (
                "Default credentials: admin"
                + "\u00a0" * 40_000
                + "/"
                + "\u2003" * 40_000
                + "admin\n"
            )
        },
        1,
    )
    case(
        "unicode_whitespace_warning_is_accepted",
        {
            "unicode-warning.md": (
                "Default credentials: admin / admin\n"
                "\u00a0> **WARNING:** Rotate these credentials before use.\n"
            )
        },
        0,
    )

    # --- compose rule ---
    case(
        "anon_no_marker_fails",
        {
            "docker-compose.e2e.yml": (
                'environment:\n  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_marker_one_line_above_passes",
        {
            "e2e/docker-compose.cluster.yml": (
                "environment:\n"
                "  # e2e-only: anonymous viewer (no prod data)\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        0,
    )
    case(
        "anon_marker_two_lines_above_passes",  # EXACT shipped layout: marker @ i-2
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
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
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  # e2e-only: marker too far up\n"
                "  # filler comment a\n"
                "  # filler comment b\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_exact_marker_outside_canonical_path_fails",
        {
            "c.yml": (
                "environment:\n"
                "  # e2e-only: anonymous viewer (no prod data)\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_stray_prose_in_canonical_path_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  # This e2e-only note describes a different service.\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_structured_marker_for_other_service_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  # e2e-only: local metrics are exposed here.\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_quoted_environment_list_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n  grafana:\n    environment:\n"
                '      - "GF_AUTH_ANONYMOUS_ENABLED=true"\n'
            )
        },
        1,
    )
    case(
        "anon_quoted_mapping_key_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n  grafana:\n    environment:\n"
                '      "GF_AUTH_ANONYMOUS_ENABLED": "true"\n'
            )
        },
        1,
    )
    case(
        "anon_yaml_escaped_mapping_key_fails",
        {
            "unsafe.yml": (
                "services:\n  grafana:\n    environment:\n"
                '      "GF_AUTH_ANONYMOUS_ENABLE\\u0044": "true"\n'
            )
        },
        1,
    )
    case(
        "anon_interpolated_unknown_fails_closed",
        {
            "docker-compose.e2e.yml": (
                "services:\n  grafana:\n    environment:\n"
                "      # e2e-only: anonymous viewer (no prod data)\n"
                '      GF_AUTH_ANONYMOUS_ENABLED: "${GRAFANA_ANONYMOUS}"\n'
            )
        },
        1,
    )
    case(
        "anon_interpolated_default_true_fails_closed",
        {
            "docker-compose.e2e.yml": (
                "services:\n  grafana:\n    environment:\n"
                "      # e2e-only: anonymous viewer (no prod data)\n"
                "      GF_AUTH_ANONYMOUS_ENABLED: "
                '"${GRAFANA_ANONYMOUS:-true}"\n'
            )
        },
        1,
    )
    case(
        "anon_comment_decoy_and_false_value_pass",
        {
            "docker-compose.e2e.yml": (
                "services:\n  grafana:\n    environment:\n"
                "      # GF_AUTH_ANONYMOUS_ENABLED: true\n"
                '      "GF_AUTH_ANONYMOUS_ENABLED": "false"\n'
            )
        },
        0,
    )
    case(
        "compose_env_file_fails_closed",
        {
            "docker-compose.e2e.yml": (
                "services:\n  grafana:\n    env_file:\n      - grafana.env\n"
            )
        },
        1,
    )
    case(
        "single_yaml_alias_fails_closed",
        {"unsafe.YML": "shared: &shared safe\ncopy: *shared\n"},
        1,
    )

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _self_test_git(directory, "init", "-q", "--object-format=sha1")
        document = root / "staged.md"
        document.write_text("# clean staged documentation\n", encoding="utf-8")
        _self_test_git(directory, "add", "--", "staged.md")
        document.write_text("Default credentials: admin / admin\n", encoding="utf-8")
        got = _run(root)
        cases.append(("staged_blob_not_mutable_worktree", got == 0, got, 0))

    case(
        "large_document_is_scanned",
        {"large.md": "#" + "x" * 1_048_576},
        0,
    )
    case(
        "credential_after_old_document_limit_is_rejected",
        {
            "large.md": (
                "#" + "x" * 1_048_576
                + "\nDefault credentials: admin / admin\n"
            )
        },
        1,
    )
    case(
        "large_yaml_document_is_scanned",
        {"large.yaml": "note: " + "x" * 1_048_576 + "\n"},
        0,
    )
    case(
        "anonymous_access_after_old_yaml_limit_is_rejected",
        {
            "docker-compose.e2e.yml": (
                "note: '" + "x" * 1_048_576 + "'\n"
                "services:\n"
                "  grafana:\n"
                "    environment:\n"
                "      GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "aggregate_large_documents_are_scanned",
        {
            "large-%02d.md" % index: "#" + "x" * 1_048_576
            for index in range(33)
        },
        0,
    )
    aggregate_violation = {
        "large-%02d.md" % index: "#" + "x" * 1_048_576
        for index in range(32)
    }
    aggregate_violation["zz-unsafe.md"] = (
        "Default credentials: admin / admin\n"
    )
    case(
        "credential_after_old_aggregate_limit_is_rejected",
        aggregate_violation,
        1,
    )

    secret = os.urandom(16).hex()
    diagnostic_case(
        "invalid_literal_diagnostic_is_stable_and_secret_free",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment:\n"
                f"      GF_AUTH_ANONYMOUS_ENABLED: '{secret}'\n"
            )
        },
        1,
        ("YAML rejected (invalid anonymous-auth literal)",),
        (secret,),
    )
    diagnostic_case(
        "oversized_invalid_scalar_diagnostic_is_bounded_before_output",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment:\n"
                f"      GF_AUTH_ANONYMOUS_ENABLED: '{secret}"
                + "x" * (2 * 1_048_576)
                + "'\n"
            )
        },
        1,
        ("YAML rejected (invalid anonymous-auth literal)",),
        (secret,),
    )
    diagnostic_case(
        "yaml_syntax_diagnostic_omits_source_snippets",
        {"unsafe.yml": f"items: [{secret}\n"},
        1,
        ("YAML rejected (syntax error)",),
        (secret,),
    )

    def yaml_result_document(count: int, unsafe_tail: bool) -> str:
        lines = ["services:\n"]
        for index in range(count):
            lines.extend(
                (
                    "  service-%04d:\n" % index,
                    "    environment:\n",
                )
            )
            if not unsafe_tail or index + 1 < count:
                lines.append("      # e2e-only: anonymous test viewer\n")
            lines.append("      GF_AUTH_ANONYMOUS_ENABLED: true\n")
        return "".join(lines)

    case(
        "yaml_result_limit_accepts_exact_boundary",
        {
            "docker-compose.e2e.yml": yaml_result_document(
                MAX_YAML_RESULT_LINES,
                False,
            )
        },
        0,
    )
    diagnostic_case(
        "yaml_result_limit_rejects_unsafe_tail_after_boundary",
        {
            "docker-compose.e2e.yml": yaml_result_document(
                MAX_YAML_RESULT_LINES + 1,
                True,
            )
        },
        1,
        ("YAML rejected (worker result limit)",),
        (),
    )
    aliases = ", ".join("*shared" for _ in range(101))
    case(
        "yaml_alias_budget_fails_closed",
        {"unsafe.yml": "shared: &shared safe\nitems: [" + aliases + "]\n"},
        1,
    )

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _self_test_git(directory, "init", "-q", "--object-format=sha1")
        (root / "safe.md").write_text("# safe\n", encoding="utf-8")
        _self_test_git(directory, "add", "--", "safe.md")
        fake_bin = root / "bin"
        fake_bin.mkdir()
        canary = root / "ambient-git-ran"
        fake_git = fake_bin / "git"
        fake_git.write_text(
            "#!/bin/sh\nprintf touched >" + repr(str(canary)) + "\nexit 0\n",
            encoding="utf-8",
        )
        fake_git.chmod(0o755)
        previous_path = os.environ.get("PATH")
        os.environ["PATH"] = str(fake_bin) + ":/usr/bin:/bin"
        try:
            got = _run(root)
        finally:
            if previous_path is None:
                os.environ.pop("PATH", None)
            else:
                os.environ["PATH"] = previous_path
        ok = got == 0 and not canary.exists()
        cases.append(("ambient_git_is_ignored", ok, int(not ok), 0))

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _self_test_git(directory, "init", "-q", "--object-format=sha1")
        for index in range(96):
            (root / ("safe-%03d.md" % index)).write_text(
                "# safe %d\n" % index,
                encoding="utf-8",
            )
        _self_test_git(directory, "add", "--", ".")
        resource_module = __import__("resource")
        original_limit = resource_module.getrlimit(resource_module.RLIMIT_NOFILE)
        hard_limit = original_limit[1]
        reduced_limit = 48
        if hard_limit != resource_module.RLIM_INFINITY:
            reduced_limit = min(reduced_limit, hard_limit)
        try:
            resource_module.setrlimit(
                resource_module.RLIMIT_NOFILE,
                (reduced_limit, hard_limit),
            )
            got = _run(root)
        finally:
            resource_module.setrlimit(
                resource_module.RLIMIT_NOFILE,
                original_limit,
            )
        cases.append(
            (
                "many_unique_blobs_fit_a_bounded_descriptor_budget",
                got == 0,
                got,
                0,
            )
        )

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _self_test_git(directory, "init", "-q", "--object-format=sha1")
        helper = root / "promisor-helper.sh"
        canary = root / "promisor-helper-ran"
        quote = __import__("shlex").quote
        helper.write_text(
            "#!/bin/sh\n/usr/bin/touch " + quote(str(canary)) + "\nexit 1\n",
            encoding="utf-8",
        )
        helper.chmod(0o755)
        missing_object = "1" * 40
        _self_test_git(directory, "config", "extensions.partialClone", "origin")
        _self_test_git(directory, "config", "remote.origin.promisor", "true")
        _self_test_git(
            directory,
            "config",
            "remote.origin.partialCloneFilter",
            "blob:none",
        )
        _self_test_git(
            directory,
            "config",
            "remote.origin.url",
            "ext::" + str(helper),
        )
        _self_test_git(directory, "config", "protocol.ext.allow", "always")
        _self_test_git(
            directory,
            "update-index",
            "--info-only",
            "--add",
            "--cacheinfo",
            "100644,%s,promised.md" % missing_object,
        )
        binding = RepositoryBinding(root)
        run_git_failed = False
        run_git_to_fd_failed = False
        try:
            try:
                _run_git(
                    binding.git_fd,
                    binding.index_fd,
                    ["cat-file", "-s", missing_object],
                    128,
                    time.monotonic() + 5.0,
                )
            except CheckFailure:
                run_git_failed = True
            with tempfile.TemporaryFile() as output:
                try:
                    _run_git_to_fd(
                        binding.git_fd,
                        binding.index_fd,
                        ["cat-file", "blob", missing_object],
                        output.fileno(),
                        0,
                        time.monotonic() + 5.0,
                    )
                except CheckFailure:
                    run_git_to_fd_failed = True
        finally:
            binding.close()
        ok = run_git_failed and run_git_to_fd_failed and not canary.exists()
        cases.append(
            (
                "git_runners_disable_repository_selected_transport",
                ok,
                int(not ok),
                0,
            )
        )

    def retarget_case(
        name: str,
        runner_name: str,
        relative_target: str,
        replacement,
    ) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            _self_test_git(directory, "init", "-q", "--object-format=sha1")
            (root / "safe.md").write_text("# safe\n", encoding="utf-8")
            _self_test_git(directory, "add", "--", "safe.md")
            target = root / relative_target
            moved = target.with_name(target.name + ".bound-test")
            original_runner = globals()[runner_name]
            calls = 0

            def racing_runner(*arguments, **keywords):
                nonlocal calls
                calls += 1
                if calls == 1:
                    os.rename(target, moved)
                    replacement(target, moved)
                return original_runner(*arguments, **keywords)

            globals()[runner_name] = racing_runner
            stdout = io.StringIO()
            stderr = io.StringIO()
            try:
                with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
                    got = _run(root)
            finally:
                globals()[runner_name] = original_runner
                if target.is_dir():
                    os.rmdir(target)
                elif target.exists():
                    target.unlink()
                os.rename(moved, target)
            output = stdout.getvalue() + stderr.getvalue()
            ok = got == 2 and "Grafana credential hygiene OK." not in output
            cases.append((name, ok, int(not ok), 0))

    retarget_case(
        "git_metadata_retarget_cannot_produce_success",
        "_run_git",
        ".git",
        lambda target, _moved: target.mkdir(),
    )
    copyfile = __import__("shutil").copyfile
    retarget_case(
        "git_index_retarget_during_stream_cannot_produce_success",
        "_run_git_to_fd",
        ".git/index",
        lambda target, moved: copyfile(moved, target),
    )

    result_read, result_write = os.pipe()
    pid_read, pid_write = os.pipe()
    leader = os.fork()
    if leader == 0:  # pragma: no cover - observed through the parent assertion
        try:
            os.close(result_read)
            os.close(pid_read)
            os.setsid()
            descendant = os.fork()
            if descendant == 0:
                os.close(result_write)
                os.close(pid_write)
                while True:
                    time.sleep(60.0)
            os.write(pid_write, (str(descendant) + "\n").encode("ascii"))
            os.close(pid_write)
            os.close(result_write)
            os._exit(0)
        except BaseException:
            os._exit(2)

    os.close(result_write)
    os.close(pid_write)
    for descriptor in (result_read, pid_read):
        os.set_blocking(descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(result_read, selectors.EVENT_READ, "result")
    selector.register(pid_read, selectors.EVENT_READ, "pid")
    pid_bytes = bytearray()
    result_eof = False
    setup_deadline = time.monotonic() + 2.0
    while selector.get_map() and time.monotonic() < setup_deadline:
        events = selector.select(setup_deadline - time.monotonic())
        for key, _mask in events:
            try:
                chunk = os.read(key.fd, 128)
            except BlockingIOError:
                continue
            if not chunk:
                selector.unregister(key.fd)
                os.close(key.fd)
                if key.data == "result":
                    result_eof = True
                continue
            if key.data == "pid" and len(pid_bytes) + len(chunk) <= 128:
                pid_bytes.extend(chunk)
    for key in list(selector.get_map().values()):
        selector.unregister(key.fd)
        os.close(key.fd)
    selector.close()
    descendant_pid = None
    try:
        descendant_pid = int(bytes(pid_bytes).strip())
    except ValueError:
        pass
    setup_ok = result_eof and descendant_pid is not None
    status = _finish_yaml_worker(
        leader,
        None,
        True,
        terminate=not setup_ok,
    )

    def worker_group_exists():
        try:
            os.killpg(leader, 0)
            return True
        except ProcessLookupError:
            return False
        except PermissionError:
            return True

    group_extinct_on_return = not worker_group_exists()
    if not group_extinct_on_return:
        try:
            os.killpg(leader, signal.SIGKILL)
        except OSError:
            pass
    if descendant_pid is not None:
        try:
            os.kill(descendant_pid, signal.SIGKILL)
        except OSError:
            pass
    cleanup_deadline = time.monotonic() + 2.0
    while worker_group_exists() and time.monotonic() < cleanup_deadline:
        time.sleep(0.01)
    ok = setup_ok and status is None and group_extinct_on_return
    cases.append(
        (
            "successful_worker_leader_cannot_leave_a_descendant",
            ok,
            int(not ok),
            0,
        )
    )

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        _self_test_git(directory, "init", "-q", "--object-format=sha1")
        (root / "many.md").write_text(
            "Default credentials: admin / admin\n" * 4_000,
            encoding="utf-8",
        )
        _self_test_git(directory, "add", "--", "many.md")
        stdout = io.StringIO()
        stderr = io.StringIO()
        with contextlib.redirect_stdout(stdout), contextlib.redirect_stderr(stderr):
            got = _run(root)
        output = stdout.getvalue() + stderr.getvalue()
        ok = (
            got == 1
            and len(output.encode("utf-8")) <= 128 * 1024
            and "additional findings omitted" in output
        )
        cases.append(("diagnostic_output_is_bounded", ok, int(not ok), 0))

    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        outside = root / "outside.txt"
        outside.write_text("# harmless outside target\n", encoding="utf-8")
        _self_test_git(directory, "init", "-q", "--object-format=sha1")
        (root / "linked.md").symlink_to(outside)
        _self_test_git(directory, "add", "--", "linked.md")
        got = _run(root)
        cases.append(("tracked_symlink_fails_closed", got == 2, got, 2))

    failed = [c for c in cases if not c[1]]
    for name, ok, got, want in cases:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name} (got={got} want={want})")
    if failed:
        sys.stderr.write(f"SELF-TEST FAILED: {len(failed)}/{len(cases)} cases\n")
        _DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT = False
        return 1
    print(f"SELF-TEST OK: {len(cases)}/{len(cases)} cases passed.")
    _DARWIN_SELF_TEST_WITHOUT_MEMORY_RLIMIT = False
    return 0


def _compatibility_self_test() -> int:
    """Embedded unit tests — stdlib only, no pytest (repo has no py test harness)."""
    cases: list[tuple[str, bool, int, int]] = []

    def case(
        name: str,
        files: dict[str, str],
        want: int,
        *,
        missing: frozenset[str] = frozenset(),
        untracked: frozenset[str] = frozenset(),
    ) -> None:
        with tempfile.TemporaryDirectory() as d:
            root = Path(d)
            _self_test_git(d, "init", "-q", "--object-format=sha1")
            for rel, body in files.items():
                p = root / rel
                p.parent.mkdir(parents=True, exist_ok=True)
                p.write_text(body)
            tracked = [relative for relative in files if relative not in untracked]
            _self_test_git(d, "add", "--", *tracked)
            for relative in missing:
                (root / relative).unlink()
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
        "shipped_shared_network_warning_passes",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n\n"
                "> **WARNING:** Rotate this password before any production or "
                "shared-network use.\n"
            )
        },
        0,
    )
    case(
        "loose_word_does_not_satisfy",
        {"doc.md": "Default credentials: `admin / admin`\nWe rotate logs nightly.\n"},
        1,  # bare verb must NOT pass
    )
    case(
        "change_phrase_without_admonition_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "Replace default dashboard panels in examples.\n"
            )
        },
        1,
    )
    case(
        "unrelated_admonition_and_change_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the dashboard theme before production.\n"
            )
        },
        1,
    )
    case(
        "admin_theme_warning_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the admin dashboard theme before production.\n"
            )
        },
        1,
    )
    case(
        "theme_change_then_password_text_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the dashboard theme; the password remains admin/admin.\n"
            )
        },
        1,
    )
    case(
        "negated_rotation_warning_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Do not rotate or change the default password.\n"
            )
        },
        1,
    )
    case(
        "not_necessary_rotation_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** It is not necessary to change the default password.\n"
            )
        },
        1,
    )
    case(
        "refuse_rotation_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Refuse to change this password.\n"
            )
        },
        1,
    )
    case(
        "suffix_negation_warning_fails",
        {
            "doc.md": (
                "Default credentials: `admin / admin`\n"
                "> **WARNING:** Change the default password? No; retain admin/admin.\n"
            )
        },
        1,
    )

    # --- compose rule ---
    case(
        "anon_no_marker_fails",
        {
            "docker-compose.e2e.yml": (
                'environment:\n  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "anon_marker_one_line_above_passes",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: anonymous viewer (no prod data)\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        0,
    )
    case(
        "anon_marker_two_lines_above_passes",  # EXACT shipped layout: marker @ i-2
        {
            "docker-compose.e2e.yml": (
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
            "docker-compose.e2e.yml": (
                "  # e2e-only: marker too far up\n"
                "  # filler comment a\n"
                "  # filler comment b\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "negated_marker_comment_fails",
        {
            "docker-compose.e2e.yml": (
                "  # not e2e-only: this is the production stack\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "marker_text_in_yaml_value_fails",
        {
            "docker-compose.e2e.yml": (
                '  deployment_note: "e2e-only is forbidden here"\n'
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "marker_inside_block_scalar_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: |\n"
                "    # e2e-only: this is scalar data, not a comment\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_after_block_scalar_content_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: |\n"
                "    ordinary scalar line\n"
                "    # e2e-only: still scalar data\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_in_explicit_indent_scalar_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: |2-\n"
                "    # e2e-only: explicit-indent scalar data\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_in_multiline_quote_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  NOTE: \"ordinary text\\\n"
                "    # e2e-only: continued quoted scalar data\"\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true\n"
            )
        },
        1,
    )
    case(
        "marker_in_unclassified_yaml_fails",
        {
            "production.yml": (
                "  # e2e-only: misleading marker in an unclassified path\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "true"\n'
            )
        },
        1,
    )
    case(
        "dynamic_anonymous_value_fails",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                '  GF_AUTH_ANONYMOUS_ENABLED: "${GRAFANA_ANON:-true}"\n'
            )
        },
        1,
    )
    case(
        "dynamic_environment_list_key_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                '  - "${ANON_KEY}=true"\n'
            )
        },
        1,
    )
    case(
        "dynamic_environment_mapping_key_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                '  "${ANON_KEY}": true\n'
            )
        },
        1,
    )
    case(
        "aliased_environment_fragment_fails",
        {
            "docker-compose.e2e.yml": (
                "x-env: &anon_env\n"
                '  - "${ANON_KEY}=true"\n'
                "services:\n"
                "  grafana:\n"
                "    environment: *anon_env\n"
            )
        },
        1,
    )
    case(
        "environment_list_alias_fails",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                "  - *hidden_setting\n"
            )
        },
        1,
    )
    case(
        "dotted_environment_alias_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment: *.hidden\n"
            )
        },
        1,
    )
    case(
        "unicode_environment_alias_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment: *\u914d\u7f6e\n"
            )
        },
        1,
    )
    case(
        "inline_environment_merge_key_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    environment: {<<: {SAFE: false}}\n"
            )
        },
        1,
    )
    case(
        "dynamic_unrelated_environment_value_is_not_a_key",
        {
            "docker-compose.e2e.yml": (
                "environment:\n"
                '  OTHER_SETTING: "${OTHER_VALUE:-safe}"\n'
            )
        },
        0,
    )
    case(
        "quoted_mapping_key_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  "GF_AUTH_ANONYMOUS_ENABLED": "true"\n'
            )
        },
        1,
    )
    case(
        "quoted_list_item_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  - "GF_AUTH_ANONYMOUS_ENABLED=true"\n'
            )
        },
        1,
    )
    case(
        "quoted_list_dynamic_value_fails",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                '  - "GF_AUTH_ANONYMOUS_ENABLED=${GRAFANA_ANON:-true}"\n'
            )
        },
        1,
    )
    case(
        "escaped_mapping_key_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  "GF_AUTH_ANONYMOUS_\\u0045NABLED": "true"\n'
            )
        },
        1,
    )
    case(
        "escaped_list_key_in_unclassified_yaml_fails",
        {
            "production.yml": (
                '  - "GF_AUTH_ANONYMOUS_\\u0045NABLED=true"\n'
            )
        },
        1,
    )
    case(
        "mapping_hash_without_comment_space_is_dynamic",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                "  GF_AUTH_ANONYMOUS_ENABLED: true#suffix\n"
            )
        },
        1,
    )
    case(
        "list_hash_without_comment_space_is_dynamic",
        {
            "docker-compose.e2e.yml": (
                "  # e2e-only: value must still be literal\n"
                "  - GF_AUTH_ANONYMOUS_ENABLED=true#suffix\n"
            )
        },
        1,
    )
    case(
        "escaped_multiline_mapping_key_fails",
        {
            "production.yml": (
                '  "GF_AUTH_ANONYMOUS_ENA\\\n'
                '    BLED": "true"\n'
            )
        },
        1,
    )
    case(
        "escaped_multiline_list_key_fails",
        {
            "production.yml": (
                '  - "GF_AUTH_ANONYMOUS_ENA\\\n'
                '    BLED=true"\n'
            )
        },
        1,
    )
    case(
        "tracked_production_env_file_enablement_fails",
        {
            "production.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file:\n"
                "      - grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
    )
    for image in ("grafana/grafana:11", "grafana/grafana-enterprise:11",
                  "registry.example/grafana/grafana@sha256:example"):
        for image_first in (True, False):
            properties = [f"    image: {image}\n", "    env_file: dashboard.env\n"]
            if not image_first:
                properties.reverse()
            case(
                f"renamed_grafana_service_{image}_{image_first}",
                {
                    "production.yml": "services:\n  dashboards:\n" + "".join(properties),
                    "dashboard.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
                },
                1,
            )
    case(
        "renamed_grafana_literal_false_passes",
        {
            "production.yml": "services:\n  dashboards:\n    env_file: dashboard.env\n    image: grafana/grafana:11\n",
            "dashboard.env": "GF_AUTH_ANONYMOUS_ENABLED=false\n",
        },
        0,
    )
    for image_value in ("*dashboard_image", "!custom grafana/grafana", "|", ">"):
        case(
            f"renamed_grafana_indirect_image_{image_value}",
            {
                "production.yml": (
                    "x-image: &dashboard_image grafana/grafana:11\n"
                    "services:\n  dashboards:\n"
                    f"    image: {image_value}\n"
                    "    env_file: dashboard.env\n"
                ),
                "dashboard.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
            },
            1,
        )
    case(
        "dotted_grafana_service_alias_with_env_file_fails",
        {
            "docker-compose.e2e.yml": (
                "x-grafana: &.shared\n"
                "  env_file: grafana.env\n"
                "services:\n"
                "  grafana: *.shared\n"
            ),
            "grafana.env": (
                "# e2e-only: anonymous viewer for the local demo stack\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        1,
    )
    case(
        "dotted_services_alias_with_env_file_fails",
        {
            "docker-compose.e2e.yml": (
                "x-services: &.shared\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
                "services: *.shared\n"
            ),
            "grafana.env": (
                "# e2e-only: anonymous viewer for the local demo stack\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        1,
    )
    case(
        "tracked_e2e_env_file_with_marker_passes",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": (
                "# e2e-only: anonymous viewer for the local demo stack\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        0,
    )
    case(
        "tracked_e2e_env_file_without_marker_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
    )
    case(
        "env_file_marker_inside_multiline_value_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": (
                "NOTE='ordinary text\n"
                "# e2e-only: quoted value data, not a comment\n"
                "'\n"
                "GF_AUTH_ANONYMOUS_ENABLED=true\n"
            ),
        },
        1,
    )
    case(
        "inline_env_file_collection_fails_closed",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: [grafana.env]\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
            "[grafana.env]": "SAFE=true\n",
        },
        1,
    )
    case(
        "tracked_env_file_literal_false_passes",
        {
            "production.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=false\n",
        },
        0,
    )
    case(
        "nested_compose_binds_env_file_from_its_parent",
        {
            "deploy/production.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: ./grafana.env\n"
            ),
            "deploy/grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=false\n",
        },
        0,
    )
    case(
        "dynamic_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                '    env_file: "${GRAFANA_ENV_FILE}"\n'
            )
        },
        1,
    )
    case(
        "empty_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file:\n"
                "    image: grafana/grafana\n"
            )
        },
        1,
    )
    case(
        "missing_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: missing.env\n"
            ),
            "missing.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
        missing=frozenset({"missing.env"}),
    )
    case(
        "untracked_grafana_env_file_target_fails",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  grafana:\n"
                "    env_file: grafana.env\n"
            ),
            "grafana.env": "GF_AUTH_ANONYMOUS_ENABLED=true\n",
        },
        1,
        untracked=frozenset({"grafana.env"}),
    )
    case(
        "unrelated_service_dynamic_env_file_is_out_of_scope",
        {
            "docker-compose.e2e.yml": (
                "services:\n"
                "  helper:\n"
                '    env_file: "${HELPER_ENV_FILE}"\n'
            )
        },
        0,
    )

    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _self_test_git(d, "init", "-q", "--object-format=sha1")
        compose = root / "docker-compose.e2e.yml"
        compose.write_text(
            "services:\n"
            "  grafana:\n"
            "    env_file: grafana.env\n"
        )
        env_file = root / "grafana.env"
        env_file.write_text("GF_AUTH_ANONYMOUS_ENABLED=false\n")
        _self_test_git(d, "add", "--", compose.name, env_file.name)
        env_file.unlink()
        env_file.symlink_to("missing.env")
        got = _run(root)
        cases.append(("tracked_env_file_symlink_is_unavailable", got == 2, got, 2))

    with tempfile.TemporaryDirectory() as d:
        got = _run(Path(d))
        cases.append(("inventory_failure_is_unavailable", got == 2, got, 2))

    with tempfile.TemporaryDirectory() as d:
        copied = Path(d) / "check_grafana_credentials.py"
        copied.write_bytes(Path(__file__).read_bytes())
        result = subprocess.run(
            [sys.executable, str(copied)], cwd=d, capture_output=True, text=True
        )
        cases.append(
            (
                "missing_shared_reader_is_unavailable",
                result.returncode == 2,
                result.returncode,
                2,
            )
        )

    with tempfile.TemporaryDirectory() as d:
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve())],
            cwd=d,
            capture_output=True,
            text=True,
        )
        cases.append(
            (
                "outside_repo_is_unavailable",
                result.returncode == 2,
                result.returncode,
                2,
            )
        )

    # A tracked deletion remains visible to plain `git ls-files` until it is
    # staged. The worktree gate must scan the current filesystem instead of
    # crashing while a legitimate rename or deletion is under review.
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _self_test_git(d, "init", "-q", "--object-format=sha1")
        deleted = root / "deleted.md"
        deleted.write_text("Default credentials: `admin / admin`\n")
        _self_test_git(d, "add", "deleted.md")
        deleted.unlink()
        try:
            got = _run(root)
        except FileNotFoundError:
            got = 99
        cases.append(("tracked_worktree_deletion_is_ignored", got == 0, got, 0))

    # A tracked file replaced by a symlink is not a deletion. The gate must
    # reject the worktree type change instead of following or silently skipping
    # it, including when the symlink target is missing.
    with tempfile.TemporaryDirectory() as d:
        root = Path(d)
        _self_test_git(d, "init", "-q", "--object-format=sha1")
        replaced = root / "replaced.md"
        replaced.write_text("safe\n")
        _self_test_git(d, "add", "replaced.md")
        replaced.unlink()
        replaced.symlink_to("missing.md")
        got = _run(root)
        cases.append(("tracked_symlink_type_change_fails", got == 2, got, 2))

    failed = [c for c in cases if not c[1]]
    for name, ok, got, want in cases:
        print(f"  [{'PASS' if ok else 'FAIL'}] {name} (got={got} want={want})")
    if failed:
        sys.stderr.write(f"SELF-TEST FAILED: {len(failed)}/{len(cases)} cases\n")
        return 1
    print(f"SELF-TEST OK: {len(cases)}/{len(cases)} cases passed.")
    return 0



def _self_test() -> int:
    """Run both inherited behavior suites without short-circuiting failures."""
    staged_result = _staged_input_self_test()
    compatibility_result = _compatibility_self_test()
    return int(staged_result != 0 or compatibility_result != 0)


def main(argv: list[str]) -> int:
    if not sys.flags.isolated:
        sys.stderr.write(
            "error: Grafana gate requires isolated Python (-I)\n"
        )
        return 2
    if "--self-test" in argv:
        return _self_test()
    root = Path(os.path.realpath(Path(__file__).parent.parent))
    current = Path(os.path.realpath(Path.cwd()))
    if current != root and root not in current.parents:
        sys.stderr.write("Grafana credential-hygiene check unavailable: invocation is outside this repository\n")
        return 2
    return _run(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
