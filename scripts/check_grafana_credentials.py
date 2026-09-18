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

import os
import re
import stat
import subprocess
import sys
import tempfile
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
        module = types.ModuleType("_odysseus_doc_field_guard")
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
_verify_blob = _GIT_GUARD._verify_blob

CRED_RE = re.compile(r"admin\s*/\s*admin", re.IGNORECASE)
WARNING_PREFIX_RE = re.compile(
    r"^\s*>\s*\*\*(warning|caution|important):?\*\*", re.IGNORECASE
)
ROTATION_ACTION_RE = re.compile(r"\b(rotate|change|replace)\b", re.IGNORECASE)
CREDENTIAL_TARGET_RE = re.compile(r"\b(password|credentials?)\b", re.IGNORECASE)
BLOCKQUOTE_RE = re.compile(r"^\s*>\s?(.*)$")
E2E_MARKER_RE = re.compile(
    r"^(?P<indent>[ \t]*)#\s*e2e-only:\s*anonymous\b", re.IGNORECASE
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
MAX_INPUT_BYTES = 1_048_576
MAX_TOTAL_INPUT_BYTES = 32 * 1024 * 1024
MAX_YAML_DOCUMENTS = 8
MAX_YAML_NODES = 10_000
MAX_YAML_DEPTH = 50
MAX_YAML_ALIASES = 0
SCAN_DEADLINE_SECONDS = 30.0
TRACKED_SUFFIXES = (b".md", b".yml", b".yaml")


class BoundedSafeLoader(yaml.SafeLoader):
    """SafeLoader with explicit structural budgets."""

    def __init__(self, stream):
        super().__init__(stream)
        self._gate_nodes = 0
        self._gate_depth = 0
        self._gate_aliases = 0

    def compose_node(self, parent, index):
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
            return super().compose_node(parent, index)
        finally:
            self._gate_depth -= 1


def _display_path(path: bytes) -> str:
    decoded = os.fsdecode(path)
    if any(ord(character) < 32 or ord(character) == 127 for character in decoded):
        return repr(decoded)
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


def _tracked_blobs(root: Path) -> list[tuple[bytes, bytes]]:
    """Read exact staged blobs through fixed Git with bounded resources."""
    import time

    bound = RepositoryBinding(root)
    deadline = time.monotonic() + SCAN_DEADLINE_SECONDS
    try:
        initial_inventory = _run_git(
            bound.git_fd,
            bound.index_fd,
            ["ls-files", "--stage", "-z"],
            MAX_INVENTORY_BYTES,
            deadline,
        )
        inventory = _parse_tracked_inventory(initial_inventory)
        cache = {}
        total_bytes = 0
        blobs = []
        for path, object_id in inventory:
            if object_id not in cache:
                body = _run_git(
                    bound.git_fd,
                    bound.index_fd,
                    ["cat-file", "blob", object_id],
                    MAX_INPUT_BYTES + 1,
                    deadline,
                )
                if len(body) > MAX_INPUT_BYTES:
                    raise CheckFailure(
                        "%s: tracked validation input exceeds the %d-byte limit"
                        % (_display_path(path), MAX_INPUT_BYTES)
                    )
                _verify_blob(object_id, body)
                cache[object_id] = body
            body = cache[object_id]
            total_bytes += len(body)
            if total_bytes > MAX_TOTAL_INPUT_BYTES:
                raise CheckFailure(
                    "tracked validation inputs exceed the aggregate byte limit"
                )
            blobs.append((path, body))
        final_inventory = _run_git(
            bound.git_fd,
            bound.index_fd,
            ["ls-files", "--stage", "-z"],
            MAX_INVENTORY_BYTES,
            deadline,
        )
        if final_inventory != initial_inventory:
            raise CheckFailure("Git index changed during credential validation")
        bound.revalidate()
        return blobs
    finally:
        bound.close()


def _has_rotation_warning(lines: list[str]) -> bool:
    """Return whether the window contains a credential-specific admonition."""
    for index, line in enumerate(lines):
        if not WARNING_PREFIX_RE.search(line):
            continue
        block = [line]
        for continuation in lines[index + 1 :]:
            match = BLOCKQUOTE_RE.match(continuation)
            if match is None:
                break
            block.append(match.group(1))
        warning = " ".join(block)
        if ROTATION_ACTION_RE.search(warning) and CREDENTIAL_TARGET_RE.search(warning):
            return True
    return False


def check_docs(blobs: list[tuple[bytes, bytes]]) -> list[str]:
    """Check staged Markdown blobs for unsafe documented credentials."""
    errs: list[str] = []
    for path, body in blobs:
        if not path.lower().endswith(b".md"):
            continue
        lines = body.decode("utf-8", "replace").splitlines()
        for i, line in enumerate(lines):
            if CRED_RE.search(line):
                window = lines[i : i + 1 + WARN_WINDOW]
                if not _has_rotation_warning(window):
                    errs.append(
                        f"{_display_path(path)}:{i + 1}: 'admin/admin' "
                        f"with no credential-rotation warning within "
                        f"{WARN_WINDOW} lines"
                    )
    return errs


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


def _literal_enabled(value: object) -> bool:
    """Return a literal anonymous-auth state or reject an unresolved value."""
    if isinstance(value, bool):
        return value
    if isinstance(value, str):
        normalized = value.strip().casefold()
        if normalized == "true":
            return True
        if normalized == "false":
            return False
    raise ValueError(
        f"{ANON_SETTING} must be a literal true or false value, got {value!r}"
    )


def _environment_mark(environment: object, node, lines: list[str]):
    """Return the source line/indent for one effective enabled setting."""
    source_node = None
    if isinstance(environment, dict):
        if ANON_SETTING not in environment:
            return None
        found = _mapping_lookup(node, ANON_SETTING)
        if found is None:
            raise ValueError("anonymous Grafana setting has no YAML source")
        if not _literal_enabled(environment[ANON_SETTING]):
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
                raise ValueError(
                    f"{ANON_SETTING} must include a literal true or false value"
                )
            enabled_index = index if _literal_enabled(value) else None
        if enabled_index is None or not isinstance(node, yaml.SequenceNode):
            return None
        if enabled_index < len(node.value):
            source_node = node.value[enabled_index]
    if source_node is None:
        raise ValueError("enabled anonymous Grafana setting has no YAML source")
    line_number = source_node.start_mark.line
    if line_number < 0 or line_number >= len(lines):
        raise ValueError("anonymous Grafana YAML source line is invalid")
    indent = re.match(r"^[ \t]*", lines[line_number]).group(0)
    return line_number, indent


def _anonymous_entries(document: object, node, lines: list[str]):
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
                raise ValueError(
                    "Compose env_file is not permitted in credential validation"
                )
            if "environment" in value:
                found = _mapping_lookup(value_node, "environment")
                if found is None:
                    raise ValueError("environment mapping has no YAML source")
                mark = _environment_mark(value["environment"], found[1], lines)
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
                        raise yaml.YAMLError("YAML merge keys are not permitted")
                    identity = (key_node.tag, key_node.value)
                    if identity in keys:
                        raise yaml.YAMLError(
                            "duplicate YAML mapping key %r" % key_node.value
                        )
                    keys.add(identity)
                pending.extend((key_node, value_node))
        elif isinstance(current, yaml.SequenceNode):
            pending.extend(current.value)


def _load_bounded_yaml(source: str):
    loader = BoundedSafeLoader(source)
    documents = []
    try:
        while loader.check_node():
            if len(documents) >= MAX_YAML_DOCUMENTS:
                raise yaml.YAMLError("YAML document limit exceeded")
            node = loader.get_node()
            _reject_duplicate_yaml_keys(node)
            document = loader.construct_document(node)
            documents.append((document, node))
    finally:
        loader.dispose()
    return documents


def check_compose(blobs: list[tuple[bytes, bytes]]) -> list[str]:
    """Parse staged YAML and enforce the anonymous Grafana e2e marker."""
    errs: list[str] = []
    for path, body in blobs:
        if not path.lower().endswith((b".yml", b".yaml")):
            continue
        display_path = _display_path(path)
        try:
            source = body.decode("utf-8")
        except UnicodeError as error:
            errs.append(f"{display_path}: cannot decode YAML: {error}")
            continue
        lines = source.splitlines()
        try:
            entries = []
            for document, node in _load_bounded_yaml(source):
                entries.extend(_anonymous_entries(document, node, lines))
        except (ValueError, yaml.YAMLError) as error:
            errs.append(f"{display_path}: YAML parse error: {error}")
            continue
        for i, indent in sorted(set(entries)):
            relative = os.fsdecode(path)
            if relative not in E2E_COMPOSE_PATHS:
                errs.append(
                    f"{display_path}:{i + 1}: anonymous Grafana "
                    f"read enabled outside a canonical e2e Compose file"
                )
                continue
            context = lines[max(0, i - ANON_LOOKBACK) : i]
            markers = (E2E_MARKER_RE.match(candidate) for candidate in context)
            if not any(
                marker is not None and marker.group("indent") == indent
                for marker in markers
            ):
                errs.append(
                    f"{display_path}:{i + 1}: anonymous Grafana "
                    f"read enabled without a same-indent "
                    f"'# e2e-only: anonymous' "
                    f"comment within {ANON_LOOKBACK} lines above"
                )
    return errs


def _run(root: Path) -> int:
    try:
        blobs = _tracked_blobs(root)
        errs = check_docs(blobs) + check_compose(blobs)
    except (CheckFailure, OSError) as error:
        errs = [f"validation input failure: {error}"]
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
        "oversized_document_fails_closed",
        {"oversized.md": "#" + "x" * 1_048_576},
        1,
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
        return 1
    print(f"SELF-TEST OK: {len(cases)}/{len(cases)} cases passed.")
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
