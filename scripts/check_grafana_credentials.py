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
from pathlib import Path

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


_GIT_GUARD = _load_git_guard()
RepositoryBinding = _GIT_GUARD.RepositoryBinding
CheckFailure = _GIT_GUARD.CheckFailure
_run_git = _GIT_GUARD._run_git
_run_git_to_fd = _GIT_GUARD._run_git_to_fd

WARNING_LITERAL_RE = re.compile(
    r"\*\*(warning|caution|important):?\*\*",
    re.IGNORECASE,
)
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


def _parse_tracked_inventory(raw: bytes) -> list[tuple[bytes, str]]:
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
        if not path.lower().endswith(TRACKED_SUFFIXES):
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
        self.current = stream
        return path, stream

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


def _line_quote_prefix(mapped, start, end, deadline):
    blockquote = False
    after_quote = False
    prefix = []
    for text in _decoded_line_chunks(mapped, start, end, deadline):
        for character in text:
            if not blockquote:
                if character.isspace():
                    continue
                if character != ">":
                    return False, False
                blockquote = True
                continue
            if not after_quote:
                if character.isspace():
                    continue
                after_quote = True
            if len(prefix) < 32:
                prefix.append(character)
                if len(prefix) < 32:
                    continue
            return True, WARNING_LITERAL_RE.match("".join(prefix)) is not None
    return blockquote, WARNING_LITERAL_RE.match("".join(prefix)) is not None


def _line_keyword_flags(mapped, start, end, deadline):
    actions = {"rotate", "change", "replace"}
    targets = {"password", "credential", "credentials"}
    has_action = False
    has_target = False
    token = []
    overlong = False

    def finish_token():
        nonlocal has_action, has_target, overlong
        if token and not overlong:
            value = "".join(token)
            has_action = has_action or value in actions
            has_target = has_target or value in targets
        token.clear()
        overlong = False

    for text in _decoded_line_chunks(mapped, start, end, deadline):
        for character in text:
            if character == "_" or character.isalnum():
                folded = character.casefold()
                if not overlong and len(token) + len(folded) <= 16:
                    token.extend(folded)
                else:
                    overlong = True
            else:
                finish_token()
    finish_token()
    return has_action, has_target


def _has_rotation_warning(mapped, lines, deadline) -> bool:
    """Return whether the window contains a credential-specific admonition."""
    for index, (_number, start, end) in enumerate(lines):
        _blockquote, warning = _line_quote_prefix(
            mapped,
            start,
            end,
            deadline,
        )
        if not warning:
            continue
        has_action, has_target = _line_keyword_flags(
            mapped,
            start,
            end,
            deadline,
        )
        for _line_number, continuation_start, continuation_end in lines[index + 1 :]:
            blockquote, _warning = _line_quote_prefix(
                mapped,
                continuation_start,
                continuation_end,
                deadline,
            )
            if not blockquote:
                break
            continuation_action, continuation_target = _line_keyword_flags(
                mapped,
                continuation_start,
                continuation_end,
                deadline,
            )
            has_action = has_action or continuation_action
            has_target = has_target or continuation_target
        if has_action and has_target:
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


def _environment_mark(environment: object, node):
    """Return the source line for one effective enabled setting."""
    source_node = None
    if isinstance(environment, dict):
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
                continue
            name, separator, value = item.partition("=")
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
            if "env_file" in value:
                found = _mapping_lookup(value_node, "env_file")
                raise YamlPolicyError(
                    "Compose env_file is not permitted",
                    found[0] if found is not None else value_node,
                )
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


def _yaml_worker_payload(source, deadline):
    try:
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
        return {"status": "ok", "lines": entries}
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


def _contained_yaml_parse(stream, deadline):
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
            or any(not isinstance(line, int) or line < 0 for line in lines)
        ):
            raise CheckFailure("YAML worker returned invalid source lines")
        return payload
    allowed_kinds = {"encoding", "policy", "resource", "structure", "syntax"}
    allowed_classifications = {
        "Compose env_file is not permitted",
        "YAML merge keys are not permitted",
        "YAML structure limit",
        "duplicate YAML mapping key",
        "invalid UTF-8",
        "invalid anonymous-auth literal",
        "invalid anonymous-auth source",
        "missing anonymous-auth literal",
        "missing anonymous-auth source",
        "missing environment source",
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


def check_compose(blobs, findings: FindingBudget, deadline: float) -> None:
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
                    check_compose(((path, stream),), findings, deadline)
                if findings.exhausted:
                    break
        errs = findings.errors
    except (CheckFailure, OSError) as error:
        classification = (
            "trusted input boundary rejected the repository"
            if isinstance(error, CheckFailure)
            else "operating-system input failure"
        )
        errs = ["validation input failure: " + classification]
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


def _self_test() -> int:
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
            ok = got == 1 and "Grafana credential hygiene OK." not in output
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
        cases.append(("tracked_symlink_fails_closed", got == 1, got, 1))

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


def main(argv: list[str]) -> int:
    if not sys.flags.isolated:
        sys.stderr.write(
            "error: Grafana gate requires isolated Python (-I)\n"
        )
        return 2
    if "--self-test" in argv:
        return _self_test()
    root = Path(os.path.realpath(Path(__file__).parent.parent))
    return _run(root)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
