#!/usr/bin/env bash
#
# check-hierarchy-sync.sh — Validate separate runtime and instruction roles.
#
# Myrmidons owns runtime-role definitions. Its exact pool tags are the current
# provisioned-consumer references. Odyssey separately owns the nine retained
# repository instruction roles in Proposed ADR-020. A shared role name does not
# create a mapping between these namespaces.
#
# Usage:
#   check-hierarchy-sync.sh            Print a human-readable report.
#   check-hierarchy-sync.sh --ci       Machine-friendly summary only.
#
# Exit codes:
#   0  All required inputs are available and valid.
#   1  Drift detected — an inventory or ownership rule is invalid.
#   2  Comparison unavailable or an invalid invocation.
#
# Used by `just check-hierarchy-sync`.

# Imported Bash functions must not replace the builtins used below.
unset -f -- builtin cd command declare eval exec exit local printf pwd read \
  return set shift source test trap type unset '[' 2>/dev/null || :
set -uo pipefail

# Scrub file-producing diagnostics and dynamic-loader controls before the
# first trusted executable is started; `env -i` cannot protect its own loader.
unset BASH_ENV ENV GIT_TRACE GIT_TRACE2 GIT_TRACE2_EVENT \
  GIT_TRACE2_PERF GIT_TRACE_CURL GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS \
  GIT_TRACE_SETUP GIT_TRACE_SHALLOW LD_PRELOAD LD_LIBRARY_PATH \
  LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
  DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_PRINT_TO_FILE

usage() {
  printf '%s\n' \
    'Usage: check-hierarchy-sync.sh [--ci]' \
    '' \
    'Validate Myrmidons runtime roles and Odyssey instruction roles.' \
    '' \
    'Options:' \
    '  --ci       Print machine-readable availability and drift results.' \
    '  -h, --help Print this help and exit.' \
    '' \
    'Exit codes:' \
    '  0  All required inputs are available and valid.' \
    '  1  Drift was detected.' \
    '  2  The comparison is unavailable or the invocation is invalid.'
}

CI_MODE=0
if [ "$#" -gt 1 ]; then
  printf 'error: unexpected argument: %s\n' "$2" >&2
  exit 2
fi
case "${1:-}" in
  "")        ;;
  --ci)      CI_MODE=1 ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

report_shell_unavailable() {
  local reason="$1"
  if [ "$CI_MODE" -eq 1 ]; then
    printf 'hierarchy_available=false\n'
    printf 'hierarchy_drift=unknown\n'
    printf 'hierarchy_notices=0\n'
  else
    printf 'Hierarchy sync UNAVAILABLE: %s\n' "$reason" >&2
  fi
  printf 'error: %s\n' "$reason" >&2
  exit 2
}

TRUSTED_PYTHON=/usr/bin/python3
TRUSTED_ENV=/usr/bin/env
TOTAL_OPERATION_TIMEOUT_SECONDS=120
HIERARCHY_MAX_OUTPUT_BYTES=2097152
if [ ! -x "$TRUSTED_PYTHON" ] || [ ! -x "$TRUSTED_ENV" ]; then
  report_shell_unavailable \
    "a trusted system runtime is unavailable"
fi

HIERARCHY_PROCESS_RUNNER=""
IFS= read -r -d '' HIERARCHY_PROCESS_RUNNER <<'PY' || :
import os
import select
import selectors
import signal
import subprocess
import sys
import time


timeout = int(sys.argv[1])
output_limit = int(sys.argv[2])
argv = sys.argv[3:]
if timeout < 1 or timeout > 86400 or output_limit < 1024 or not argv:
    raise SystemExit(2)

started = time.monotonic()
source = sys.stdin.buffer.read(output_limit + 1)
if len(source) > output_limit:
    print("error: embedded hierarchy source exceeds its byte limit", file=sys.stderr)
    raise SystemExit(124)
deadline = started + timeout
child_environment = {
    "HOME": "/dev/null",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
    "TZ": "UTC",
}
selector = None
buffers = {"stdout": bytearray(), "stderr": bytearray()}
source_offset = 0
total = 0
failure = None
runner_failure = None
cleanup_failure = None
status = None
leader_observer = {"kind": None, "queue": None, "seen": False}


def prepare_leader_observer(process_id):
    required = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if all(hasattr(os, name) for name in required):
        leader_observer["kind"] = "waitid"
        return
    kqueue_names = (
        "kqueue",
        "kevent",
        "KQ_FILTER_PROC",
        "KQ_EV_ADD",
        "KQ_EV_ENABLE",
        "KQ_NOTE_EXIT",
    )
    if sys.platform != "darwin" or any(
        not hasattr(select, name) for name in kqueue_names
    ):
        raise RuntimeError("safe no-reap process observation is unavailable")
    queue = select.kqueue()
    leader_observer["kind"] = "kqueue"
    leader_observer["queue"] = queue
    event = select.kevent(
        process_id,
        filter=select.KQ_FILTER_PROC,
        flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
        fflags=select.KQ_NOTE_EXIT,
    )
    try:
        queue.control([event], 0, 0)
    except ProcessLookupError:
        leader_observer["seen"] = True


def leader_has_exited_without_reaping(process_id, timeout=0.0):
    if leader_observer["seen"]:
        return True
    if leader_observer["kind"] == "waitid":
        observation = os.waitid(
            os.P_PID,
            process_id,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
        leader_observer["seen"] = (
            observation is not None
            and getattr(observation, "si_pid", 0) == process_id
        )
    elif leader_observer["kind"] == "kqueue":
        leader_observer["seen"] = bool(
            leader_observer["queue"].control(None, 1, timeout)
        )
    return leader_observer["seen"]


def close_leader_observer():
    queue = leader_observer["queue"]
    leader_observer["queue"] = None
    if queue is not None:
        queue.close()

try:
    process = subprocess.Popen(
        argv,
        cwd=os.getcwd(),
        env=child_environment,
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
except OSError as error:
    print(f"error: could not start trusted Python: {error}", file=sys.stderr)
    raise SystemExit(127) from error

try:
    prepare_leader_observer(process.pid)
    if process.stdin is None or process.stdout is None or process.stderr is None:
        raise RuntimeError("trusted Python pipes are unavailable")
    selector = selectors.DefaultSelector()
    os.set_blocking(process.stdin.fileno(), False)
    selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            failure = "hierarchy operation deadline expired"
            break
        events = selector.select(remaining)
        if not events:
            failure = "hierarchy operation deadline expired"
            break
        for key, _ in events:
            stream = key.fileobj
            if key.data == "stdin":
                try:
                    written = os.write(
                        stream.fileno(),
                        source[source_offset : source_offset + 65536],
                    )
                except BrokenPipeError:
                    written = 0
                    source_offset = len(source)
                else:
                    source_offset += written
                if source_offset == len(source):
                    selector.unregister(stream)
                    stream.close()
                continue
            chunk = os.read(stream.fileno(), 65536)
            if not chunk:
                selector.unregister(stream)
                stream.close()
                continue
            total += len(chunk)
            if total > output_limit:
                failure = (
                    f"embedded hierarchy comparison exceeded the "
                    f"{output_limit}-byte output limit"
                )
                break
            buffers[key.data].extend(chunk)
        if failure is not None:
            break
    if failure is None:
        # Let a child that closed both output pipes finish exiting without
        # polling or reaping it; its PID remains reserved through both signals.
        grace = min(0.1, max(0.0, deadline - time.monotonic()))
        if grace:
            time.sleep(grace)
except BaseException as error:
    runner_failure = (
        f"embedded hierarchy runner failed: {type(error).__name__}: {error}"
    )
finally:
    if selector is not None:
        try:
            selector.close()
        except BaseException as error:
            cleanup_failure = (
                f"could not close trusted Python selector: {error}"
            )
    if process.stdin is not None and not process.stdin.closed:
        try:
            process.stdin.close()
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not close trusted Python input: {error}"
            )
    term_sent = False
    group_permission_errors = []
    try:
        os.killpg(process.pid, signal.SIGTERM)
        term_sent = True
    except ProcessLookupError:
        pass
    except PermissionError as error:
        if sys.platform == "darwin":
            group_permission_errors.append(("terminate", error))
        else:
            cleanup_failure = (
                f"could not terminate hierarchy process group: {error}"
            )
    except OSError as error:
        cleanup_failure = f"could not terminate hierarchy process group: {error}"
    except BaseException as error:
        cleanup_failure = f"could not terminate hierarchy process group: {error}"
    if term_sent:
        try:
            time.sleep(0.05)
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not pause before killing hierarchy process group: {error}"
            )
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        if sys.platform == "darwin":
            group_permission_errors.append(("kill", error))
        else:
            cleanup_failure = cleanup_failure or (
                f"could not kill hierarchy process group: {error}"
            )
    except OSError as error:
        cleanup_failure = cleanup_failure or (
            f"could not kill hierarchy process group: {error}"
        )
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not kill hierarchy process group: {error}"
        )
    if group_permission_errors:
        leader_exited = False
        try:
            leader_exited = leader_has_exited_without_reaping(process.pid, 0.05)
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not observe trusted Python without reaping: {error}"
            )
        if not leader_exited:
            action, error = group_permission_errors[0]
            cleanup_failure = cleanup_failure or (
                f"could not {action} hierarchy process group: {error}"
            )
    try:
        close_leader_observer()
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not close trusted Python observer: {error}"
        )
    if cleanup_failure is not None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not kill trusted Python leader: {error}"
            )
    try:
        status = process.wait(timeout=1)
    except subprocess.TimeoutExpired as error:
        cleanup_failure = cleanup_failure or (
            f"could not reap trusted Python: {error}"
        )
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not reap trusted Python: {error}"
        )
    for stream in (process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except BaseException as error:
                cleanup_failure = cleanup_failure or (
                    f"could not close trusted Python output: {error}"
                )

if cleanup_failure is not None:
    print(f"error: {cleanup_failure}", file=sys.stderr)
    raise SystemExit(125)
if runner_failure is not None:
    print(f"error: {runner_failure}", file=sys.stderr)
    raise SystemExit(125)
if failure is not None:
    print(f"error: {failure}", file=sys.stderr)
    raise SystemExit(124)
if status is None:
    print("error: trusted Python status is unavailable", file=sys.stderr)
    raise SystemExit(125)
if status < 0:
    print("error: embedded Python closed output before it terminated", file=sys.stderr)
    raise SystemExit(124)
sys.stdout.buffer.write(buffers["stdout"])
sys.stderr.buffer.write(buffers["stderr"])
raise SystemExit(status)
PY

# Python's descriptor-relative APIs bind every required path, reject symlinks,
# and verify that an input did not change while it was read. Each definition
# and current runtime-consumer manifest is decoded and parsed exactly once.
run_embedded_comparison() {
"$TRUSTED_ENV" -i \
  HOME=/dev/null PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
  "$TRUSTED_PYTHON" -I -S -c "$HIERARCHY_PROCESS_RUNNER" \
  "$TOTAL_OPERATION_TIMEOUT_SECONDS" "$HIERARCHY_MAX_OUTPUT_BYTES" \
  "$TRUSTED_PYTHON" -I -S - "$CI_MODE" <<'PY'
from __future__ import annotations

import json
import os
import re
import stat
import sys
from dataclasses import dataclass
from types import MappingProxyType
from typing import Mapping, Any


RUNTIME_DEFINITION_PARTS = (
    "provisioning",
    "Myrmidons",
    "agents",
    "hierarchy",
)
RUNTIME_DEFINITION_DISPLAY = "/".join(RUNTIME_DEFINITION_PARTS)
MYRMIDONS_AGENTS_PARTS = ("provisioning", "Myrmidons", "agents")
MYRMIDONS_AGENTS_DISPLAY = "/".join(MYRMIDONS_AGENTS_PARTS)
ODYSSEY_INSTRUCTION_PARTS = (
    "research",
    "Odyssey",
    ".claude",
    "agents",
)
ODYSSEY_INSTRUCTION_DISPLAY = "/".join(ODYSSEY_INSTRUCTION_PARTS)
RETAINED_ODYSSEY_ROLES = frozenset(
    {
        "chief-architect",
        "implementation-engineer",
        "ci-failure-analyzer",
        "code-review-orchestrator",
        "general-review-specialist",
        "mojo-language-review-specialist",
        "numerical-stability-specialist",
        "security-review-specialist",
        "test-review-specialist",
    }
)
ROLE_NAME = re.compile(r"[a-z0-9][a-z0-9-]*$")
POOL_REFERENCE = re.compile(
    r"pool:([a-z0-9][a-z0-9-]*)\.([a-z0-9][a-z0-9-]*)$"
)
MAPPING_ENTRY = re.compile(r"^([A-Za-z_][A-Za-z0-9_-]*):([ \t].*|)$")
SEQUENCE_MAPPING_ENTRY = re.compile(
    r'''^(?P<key>[A-Za-z_][A-Za-z0-9_-]*|"(?:\\.|[^"\\])*"|'(?:''|[^'])*')'''
    r'''[ \t]*:(?P<value>.*)$'''
)
FRONTMATTER_DELIMITER = re.compile(r"---[ \t]*$")
INTEGER = re.compile(r"[-+]?(?:0|[1-9][0-9_]*)$")
FLOAT = re.compile(
    r"[-+]?(?:(?:[0-9][0-9_]*)?\.[0-9][0-9_]*|[0-9][0-9_]*[eE][-+]?[0-9]+)$"
)
MAX_FILE_BYTES = 1024 * 1024
MAX_TOTAL_INPUT_BYTES = 16 * 1024 * 1024
MAX_INPUT_FILES = 512
MAX_DIRECTORY_ENTRIES = 4096
MAX_REPORT_BYTES = 1024 * 1024
_input_bytes = 0
_input_files = 0


class UnavailableError(Exception):
    """The comparison could not bind or read its required inputs safely."""


@dataclass(frozen=True)
class Definition:
    path: str
    name: str
    unapproved_references: tuple[str, ...]


@dataclass(frozen=True)
class Inventory:
    definitions: Mapping[str, Definition]
    issues: tuple[str, ...]


@dataclass(frozen=True)
class RuntimeConsumer:
    path: str
    reference: str
    domain: str
    role: str


@dataclass(frozen=True)
class YamlLine:
    indent: int
    content: str
    number: int


class FrontmatterSyntaxError(ValueError):
    """The supported agent-frontmatter YAML structure is invalid or ambiguous."""


def display(value: str) -> str:
    """Keep ordinary paths readable without allowing control-sequence output."""
    return value.encode("unicode_escape").decode("ascii")


def object_identity(metadata: os.stat_result) -> tuple[int, int, int]:
    return (metadata.st_dev, metadata.st_ino, stat.S_IFMT(metadata.st_mode))


def stable_identity(metadata: os.stat_result) -> tuple[int, int, int, int, int, int]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        stat.S_IFMT(metadata.st_mode),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def require_descriptor_apis() -> None:
    required_constants = ("O_NOFOLLOW", "O_DIRECTORY")
    missing = [name for name in required_constants if not hasattr(os, name)]
    if os.open not in os.supports_dir_fd:
        missing.append("open(dir_fd=...) ")
    if os.stat not in os.supports_dir_fd or os.stat not in os.supports_follow_symlinks:
        missing.append("stat(dir_fd=..., follow_symlinks=False)")
    if os.listdir not in os.supports_fd:
        missing.append("listdir(fd)")
    if os.scandir not in os.supports_fd:
        missing.append("scandir(fd)")
    if missing:
        raise UnavailableError(
            "required descriptor-relative filesystem APIs are unavailable: "
            + ", ".join(missing)
        )


def checked_lstat(name: str, parent_fd: int, label: str) -> os.stat_result:
    try:
        return os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise UnavailableError(f"cannot inspect {label}: {error}") from error


def open_repository_root() -> int:
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        current_fd = os.open(".", flags)
    except OSError as error:
        raise UnavailableError(
            f"cannot bind the current directory: {error}"
        ) from error

    try:
        for _ in range(256):
            current = os.fstat(current_fd)
            if not stat.S_ISDIR(current.st_mode):
                raise UnavailableError("repository search reached a non-directory")
            try:
                marker = os.stat(".git", dir_fd=current_fd, follow_symlinks=False)
            except FileNotFoundError:
                marker = None
            except OSError as error:
                raise UnavailableError(
                    f"cannot inspect repository marker: {error}"
                ) from error
            if marker is not None:
                if not (stat.S_ISDIR(marker.st_mode) or stat.S_ISREG(marker.st_mode)):
                    raise UnavailableError(
                        "repository .git marker is not a direct file or directory"
                    )
                return_fd = current_fd
                current_fd = -1
                return return_fd

            parent_fd = os.open("..", flags, dir_fd=current_fd)
            parent = os.fstat(parent_fd)
            if object_identity(parent) == object_identity(current):
                os.close(parent_fd)
                raise UnavailableError("not inside a Git repository")
            os.close(current_fd)
            current_fd = parent_fd
        raise UnavailableError("repository search exceeded its depth limit")
    except OSError as error:
        raise UnavailableError(f"cannot search for repository root: {error}") from error
    finally:
        if current_fd >= 0:
            os.close(current_fd)


def bounded_directory_names(directory_fd: int, label: str) -> list[str]:
    names: list[str] = []
    try:
        with os.scandir(directory_fd) as entries:
            for entry in entries:
                names.append(entry.name)
                if len(names) > MAX_DIRECTORY_ENTRIES:
                    raise UnavailableError(
                        f"hierarchy directory has more than "
                        f"{MAX_DIRECTORY_ENTRIES} entries: {display(label)}"
                    )
    except UnavailableError:
        raise
    except OSError as error:
        raise UnavailableError(
            f"cannot list hierarchy directory {display(label)}: {error}"
        ) from error
    return sorted(names)


def open_relative_directory(root_fd: int, parts: tuple[str, ...], label: str) -> int:
    current_fd = os.dup(root_fd)
    traversed: list[str] = []
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    try:
        for component in parts:
            traversed.append(component)
            component_label = "/".join(traversed)
            before = checked_lstat(component, current_fd, component_label)
            if stat.S_ISLNK(before.st_mode) or not stat.S_ISDIR(before.st_mode):
                raise UnavailableError(
                    f"hierarchy path component is not a direct regular directory: "
                    f"{display(component_label)}"
                )
            try:
                next_fd = os.open(component, flags, dir_fd=current_fd)
                opened = os.fstat(next_fd)
            except OSError as error:
                raise UnavailableError(
                    f"cannot bind hierarchy directory {display(component_label)}: {error}"
                ) from error
            after = checked_lstat(component, current_fd, component_label)
            if (
                not stat.S_ISDIR(opened.st_mode)
                or object_identity(before) != object_identity(opened)
                or object_identity(opened) != object_identity(after)
            ):
                os.close(next_fd)
                raise UnavailableError(
                    f"hierarchy directory changed while it was opened: "
                    f"{display(component_label)}"
                )
            os.close(current_fd)
            current_fd = next_fd
    except Exception:
        os.close(current_fd)
        raise
    return current_fd


def read_regular_file(directory_fd: int, name: str, relative_path: str) -> str:
    global _input_bytes, _input_files
    before = checked_lstat(name, directory_fd, relative_path)
    if stat.S_ISLNK(before.st_mode) or not stat.S_ISREG(before.st_mode):
        raise UnavailableError(
            f"hierarchy definition is not a direct regular file: {display(relative_path)}"
        )

    flags = os.O_RDONLY | os.O_NOFOLLOW
    if hasattr(os, "O_CLOEXEC"):
        flags |= os.O_CLOEXEC
    file_fd = -1
    try:
        file_fd = os.open(name, flags, dir_fd=directory_fd)
        opened = os.fstat(file_fd)
        if (
            not stat.S_ISREG(opened.st_mode)
            or object_identity(before) != object_identity(opened)
        ):
            raise UnavailableError(
                f"hierarchy definition changed while it was opened: {display(relative_path)}"
            )
        if opened.st_size > MAX_FILE_BYTES:
            raise UnavailableError(
                f"hierarchy definition exceeds the {MAX_FILE_BYTES}-byte limit: "
                f"{display(relative_path)}"
            )

        chunks: list[bytes] = []
        bytes_read = 0
        while True:
            chunk = os.read(file_fd, 65536)
            if not chunk:
                break
            bytes_read += len(chunk)
            if bytes_read > MAX_FILE_BYTES:
                raise UnavailableError(
                    f"hierarchy definition exceeds the {MAX_FILE_BYTES}-byte limit: "
                    f"{display(relative_path)}"
                )
            chunks.append(chunk)
        opened_after = os.fstat(file_fd)
    except UnavailableError:
        raise
    except OSError as error:
        raise UnavailableError(
            f"cannot read hierarchy definition {display(relative_path)}: {error}"
        ) from error
    finally:
        if file_fd >= 0:
            os.close(file_fd)

    after = checked_lstat(name, directory_fd, relative_path)
    if (
        stable_identity(before) != stable_identity(opened)
        or stable_identity(opened) != stable_identity(opened_after)
        or stable_identity(opened_after) != stable_identity(after)
    ):
        raise UnavailableError(
            f"hierarchy definition changed while it was read: {display(relative_path)}"
        )
    if _input_files >= MAX_INPUT_FILES:
        raise UnavailableError(
            f"hierarchy input has more than {MAX_INPUT_FILES} files"
        )
    if _input_bytes + bytes_read > MAX_TOTAL_INPUT_BYTES:
        raise UnavailableError(
            f"hierarchy input exceeds the {MAX_TOTAL_INPUT_BYTES}-byte total limit"
        )
    _input_files += 1
    _input_bytes += bytes_read
    try:
        return b"".join(chunks).decode("utf-8")
    except UnicodeDecodeError as error:
        raise UnavailableError(
            f"hierarchy definition is not valid UTF-8: {display(relative_path)}"
        ) from error


def strip_inline_comment(value: str) -> str:
    """Remove a YAML comment without treating quoted hashes as comments."""
    quote: str | None = None
    index = 0
    while index < len(value):
        character = value[index]
        if quote == '"':
            if character == "\\":
                index += 2
                continue
            if character == '"':
                quote = None
        elif quote == "'":
            if character == "'" and index + 1 < len(value) and value[index + 1] == "'":
                index += 2
                continue
            if character == "'":
                quote = None
        elif character in ('"', "'"):
            quote = character
        elif character == "#" and (index == 0 or value[index - 1].isspace()):
            return value[:index].rstrip()
        index += 1
    return value.rstrip()


class FlowParser:
    """Parse the conservative flow/scalar subset used by agent frontmatter."""

    def __init__(self, text: str, line_number: int):
        self.text = strip_inline_comment(text)
        self.line_number = line_number
        self.index = 0

    def error(self, message: str) -> FrontmatterSyntaxError:
        return FrontmatterSyntaxError(f"line {self.line_number}: {message}")

    def skip_space(self) -> None:
        while self.index < len(self.text) and self.text[self.index] == " ":
            self.index += 1

    def parse(self) -> Any:
        value = self.parse_value(frozenset())
        self.skip_space()
        if self.index != len(self.text):
            raise self.error(f"unexpected character {self.text[self.index]!r}")
        return value

    def parse_value(self, stop: frozenset[str]) -> Any:
        self.skip_space()
        if self.index >= len(self.text):
            raise self.error("expected a value")
        character = self.text[self.index]
        if character == "[":
            return self.parse_sequence()
        if character == "{":
            return self.parse_mapping()
        if character == '"':
            return self.parse_double_quoted()
        if character == "'":
            return self.parse_single_quoted()
        return self.parse_plain(stop)

    def parse_double_quoted(self) -> str:
        self.index += 1
        characters: list[str] = []
        simple_escapes = {
            "0": "\0",
            "a": "\a",
            "b": "\b",
            "t": "\t",
            "\t": "\t",
            "n": "\n",
            "v": "\v",
            "f": "\f",
            "r": "\r",
            "e": "\x1b",
            " ": " ",
            '"': '"',
            "/": "/",
            "\\": "\\",
            "N": "\u0085",
            "_": "\u00a0",
            "L": "\u2028",
            "P": "\u2029",
        }
        hex_widths = {"x": 2, "u": 4, "U": 8}

        while self.index < len(self.text):
            character = self.text[self.index]
            if character == '"':
                self.index += 1
                return "".join(characters)
            if character != "\\":
                if ord(character) < 32:
                    raise self.error("invalid control character in double-quoted scalar")
                characters.append(character)
                self.index += 1
                continue

            self.index += 1
            if self.index >= len(self.text):
                raise self.error("unterminated escape in double-quoted scalar")
            escape = self.text[self.index]
            self.index += 1
            if escape in simple_escapes:
                characters.append(simple_escapes[escape])
                continue
            if escape not in hex_widths:
                raise self.error("invalid escape in double-quoted scalar")

            width = hex_widths[escape]
            digits = self.text[self.index : self.index + width]
            if len(digits) != width or re.fullmatch(
                rf"[0-9A-Fa-f]{{{width}}}", digits
            ) is None:
                raise self.error("invalid hexadecimal escape in double-quoted scalar")
            codepoint = int(digits, 16)
            if codepoint > 0x10FFFF or 0xD800 <= codepoint <= 0xDFFF:
                raise self.error("invalid Unicode escape in double-quoted scalar")
            characters.append(chr(codepoint))
            self.index += width

        raise self.error("unterminated double-quoted scalar")

    def parse_single_quoted(self) -> str:
        self.index += 1
        characters: list[str] = []
        while self.index < len(self.text):
            character = self.text[self.index]
            if character != "'":
                characters.append(character)
                self.index += 1
                continue
            if self.index + 1 < len(self.text) and self.text[self.index + 1] == "'":
                characters.append("'")
                self.index += 2
                continue
            self.index += 1
            return "".join(characters)
        raise self.error("unterminated single-quoted scalar")

    def parse_plain(self, stop: frozenset[str]) -> Any:
        start = self.index
        while self.index < len(self.text) and self.text[self.index] not in stop:
            self.index += 1
        value = self.text[start : self.index].strip()
        if not value:
            raise self.error("expected a scalar")
        if value[0] in ",[]{}#&*!|>'\"%@`" or any(
            character in value for character in "[]{}"
        ):
            raise self.error(f"unsupported or ambiguous plain scalar {value!r}")
        if value[0] in "-?:" and (
            len(value) == 1 or value[1].isspace()
        ):
            raise self.error(
                f"plain scalar starts with a reserved YAML indicator: {value!r}"
            )
        if re.search(r":(?:\s|$)", value):
            raise self.error(f"plain scalar contains an ambiguous colon: {value!r}")
        lowered = value.lower()
        if lowered in {"null", "~"}:
            return None
        if lowered in {"true", "false"}:
            return lowered == "true"
        if lowered in {"yes", "no", "on", "off"}:
            raise self.error(f"ambiguous implicit boolean {value!r} must be quoted")
        if INTEGER.fullmatch(value):
            return int(value.replace("_", ""))
        if FLOAT.fullmatch(value):
            return float(value.replace("_", ""))
        return value

    def parse_sequence(self) -> list[Any]:
        self.index += 1
        values: list[Any] = []
        self.skip_space()
        if self.index < len(self.text) and self.text[self.index] == "]":
            self.index += 1
            return values
        while True:
            values.append(self.parse_value(frozenset({",", "]"})))
            self.skip_space()
            if self.index >= len(self.text):
                raise self.error("unterminated flow sequence")
            character = self.text[self.index]
            self.index += 1
            if character == "]":
                return values
            if character != ",":
                raise self.error("flow sequence requires a comma or closing bracket")
            self.skip_space()
            if self.index < len(self.text) and self.text[self.index] == "]":
                self.index += 1
                return values

    def parse_mapping_key(self) -> str:
        self.skip_space()
        if self.index >= len(self.text):
            raise self.error("flow mapping is missing a key")
        if self.text[self.index] == '"':
            return self.parse_double_quoted()
        if self.text[self.index] == "'":
            return self.parse_single_quoted()
        start = self.index
        while self.index < len(self.text) and self.text[self.index] != ":":
            if self.text[self.index] in ",{}[]":
                raise self.error("invalid flow mapping key")
            self.index += 1
        key = self.text[start : self.index].strip()
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_-]*", key):
            raise self.error(f"unsupported flow mapping key {key!r}")
        return key

    def parse_mapping(self) -> dict[str, Any]:
        self.index += 1
        values: dict[str, Any] = {}
        self.skip_space()
        if self.index < len(self.text) and self.text[self.index] == "}":
            self.index += 1
            return values
        while True:
            key = self.parse_mapping_key()
            self.skip_space()
            if self.index >= len(self.text) or self.text[self.index] != ":":
                raise self.error("flow mapping key is missing a colon")
            self.index += 1
            if (
                self.index >= len(self.text)
                or self.text[self.index] not in " \t"
            ):
                raise self.error(
                    "flow mapping value must be separated from its colon"
                )
            if key in values:
                raise self.error(f"duplicate mapping key {key!r}")
            values[key] = self.parse_value(frozenset({",", "}"}))
            self.skip_space()
            if self.index >= len(self.text):
                raise self.error("unterminated flow mapping")
            character = self.text[self.index]
            self.index += 1
            if character == "}":
                return values
            if character != ",":
                raise self.error("flow mapping requires a comma or closing brace")
            self.skip_space()
            if self.index < len(self.text) and self.text[self.index] == "}":
                self.index += 1
                return values


class FrontmatterParser:
    """Parse one YAML document with a mapping root and unambiguous keys."""

    def __init__(self, raw_lines: list[str], start_line: int = 2):
        self.lines = self.tokenize(raw_lines, start_line)

    @staticmethod
    def tokenize(
        raw_lines: list[str], start_line: int
    ) -> tuple[YamlLine, ...]:
        tokens: list[YamlLine] = []
        for number, raw_line in enumerate(raw_lines, start=start_line):
            if any(
                ord(character) < 32 and character != "\t" for character in raw_line
            ):
                raise FrontmatterSyntaxError(
                    f"line {number}: control characters are not allowed in YAML"
                )
            prefix = raw_line[: len(raw_line) - len(raw_line.lstrip(" \t"))]
            if "\t" in prefix:
                raise FrontmatterSyntaxError(
                    f"line {number}: tabs cannot be used for YAML indentation"
                )
            content = raw_line[len(prefix) :].rstrip()
            if not content or content.startswith("#"):
                continue
            if content in {"---", "..."} or content.startswith("%"):
                raise FrontmatterSyntaxError(
                    f"line {number}: multiple documents or YAML directives are not allowed"
                )
            tokens.append(YamlLine(len(prefix), content, number))
        return tuple(tokens)

    def parse(self) -> dict[str, Any]:
        if not self.lines:
            raise FrontmatterSyntaxError("frontmatter document is empty")
        if self.lines[0].indent != 0:
            raise FrontmatterSyntaxError(
                f"line {self.lines[0].number}: root mapping must start at column 1"
            )
        value, index = self.parse_block(0, 0)
        if index != len(self.lines):
            raise FrontmatterSyntaxError(
                f"line {self.lines[index].number}: unexpected trailing YAML content"
            )
        if not isinstance(value, dict):
            raise FrontmatterSyntaxError("frontmatter must contain exactly one mapping document")
        return value

    def parse_block(self, index: int, indent: int) -> tuple[Any, int]:
        if index >= len(self.lines) or self.lines[index].indent != indent:
            line_number = self.lines[index].number if index < len(self.lines) else "end"
            raise FrontmatterSyntaxError(
                f"line {line_number}: invalid YAML indentation"
            )
        content = self.lines[index].content
        if content == "-" or content.startswith("- "):
            return self.parse_block_sequence(index, indent)
        return self.parse_block_mapping(index, indent)

    def parse_block_mapping(self, index: int, indent: int) -> tuple[dict[str, Any], int]:
        values: dict[str, Any] = {}
        while index < len(self.lines) and self.lines[index].indent >= indent:
            token = self.lines[index]
            if token.indent != indent:
                raise FrontmatterSyntaxError(
                    f"line {token.number}: unexpected mapping indentation"
                )
            match = MAPPING_ENTRY.fullmatch(token.content)
            if not match:
                raise FrontmatterSyntaxError(
                    f"line {token.number}: expected a simple mapping key"
                )
            key, raw_value = match.groups()
            if key in values:
                raise FrontmatterSyntaxError(
                    f"line {token.number}: duplicate mapping key {key!r}"
                )
            inline_value = strip_inline_comment(raw_value).strip()
            index += 1
            if inline_value:
                values[key] = FlowParser(raw_value, token.number).parse()
                if index < len(self.lines) and self.lines[index].indent > indent:
                    raise FrontmatterSyntaxError(
                        f"line {self.lines[index].number}: scalar cannot own a nested block"
                    )
                continue
            if index < len(self.lines) and self.lines[index].indent > indent:
                values[key], index = self.parse_block(index, self.lines[index].indent)
            else:
                values[key] = None
        return values, index

    def parse_block_sequence(self, index: int, indent: int) -> tuple[list[Any], int]:
        values: list[Any] = []
        while index < len(self.lines) and self.lines[index].indent >= indent:
            token = self.lines[index]
            if token.indent != indent:
                raise FrontmatterSyntaxError(
                    f"line {token.number}: unexpected sequence indentation"
                )
            if token.content == "-":
                raw_value = ""
            elif token.content.startswith("- "):
                raw_value = token.content[2:]
            else:
                raise FrontmatterSyntaxError(
                    f"line {token.number}: cannot mix mapping and sequence entries"
                )
            index += 1
            if not strip_inline_comment(raw_value).strip():
                if index >= len(self.lines) or self.lines[index].indent <= indent:
                    raise FrontmatterSyntaxError(
                        f"line {token.number}: sequence entry is missing a value"
                    )
                nested, index = self.parse_block(index, self.lines[index].indent)
                values.append(nested)
                continue

            mapping_match = SEQUENCE_MAPPING_ENTRY.fullmatch(raw_value)
            mapping_value = mapping_match.group("value") if mapping_match else None
            if mapping_match and (
                not mapping_value or mapping_value[0].isspace()
            ):
                key_token = mapping_match.group("key")
                if key_token[0] in ('"', "'"):
                    key = FlowParser(key_token, token.number).parse()
                else:
                    key = key_token
                first_raw_value = mapping_value
                if not strip_inline_comment(first_raw_value).strip():
                    raise FrontmatterSyntaxError(
                        f"line {token.number}: nested sequence mappings require an inline first value"
                    )
                item: dict[str, Any] = {
                    key: FlowParser(first_raw_value, token.number).parse()
                }
                if index < len(self.lines) and self.lines[index].indent > indent:
                    continuation, index = self.parse_block(
                        index, self.lines[index].indent
                    )
                    if not isinstance(continuation, dict):
                        raise FrontmatterSyntaxError(
                            f"line {token.number}: mapping continuation must be a mapping"
                        )
                    duplicate_keys = set(item).intersection(continuation)
                    if duplicate_keys:
                        duplicate = sorted(duplicate_keys)[0]
                        raise FrontmatterSyntaxError(
                            f"line {token.number}: duplicate mapping key {duplicate!r}"
                        )
                    item.update(continuation)
                values.append(item)
                continue

            values.append(FlowParser(raw_value, token.number).parse())
            if index < len(self.lines) and self.lines[index].indent > indent:
                raise FrontmatterSyntaxError(
                    f"line {self.lines[index].number}: scalar cannot own a nested block"
                )
        return values, index


def validate_string(value: Any, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or any(
        ord(character) < 32 for character in value
    ):
        raise FrontmatterSyntaxError(
            f"field {field} must be a non-empty text scalar"
        )
    return value


def references_odyssey_instruction(value: str) -> bool:
    normalized = value.casefold().replace("\\", "/")
    return (
        "research/odyssey/.claude/agents" in normalized
        or "odyssey.instruction" in normalized
        or "odyssey/instruction" in normalized
    )


def find_unapproved_instruction_references(
    value: Any, location: str = "document"
) -> tuple[str, ...]:
    references: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            item_location = f"{location}.{key}"
            normalized_key = re.sub(r"[^a-z0-9]", "", key.casefold())
            direct_odyssey_owner = normalized_key == "odyssey"
            instruction_owner_is_odyssey = (
                normalized_key == "instructionowner"
                and isinstance(item, str)
                and item.strip().casefold() == "odyssey"
            )
            named_odyssey_mapping = "odyssey" in normalized_key and any(
                marker in normalized_key
                for marker in ("instruction", "role", "agent")
            )
            if (
                direct_odyssey_owner
                or instruction_owner_is_odyssey
                or named_odyssey_mapping
            ):
                references.append(item_location)
            references.extend(
                find_unapproved_instruction_references(item, item_location)
            )
    elif isinstance(value, list):
        for index, item in enumerate(value):
            references.extend(
                find_unapproved_instruction_references(
                    item, f"{location}[{index}]"
                )
            )
    elif isinstance(value, str) and references_odyssey_instruction(value):
        references.append(location)
    return tuple(dict.fromkeys(references))


def parse_definition(
    text: str, relative_path: str
) -> tuple[Definition | None, tuple[str, ...]]:
    lines = text.splitlines()
    if not lines or not FRONTMATTER_DELIMITER.fullmatch(lines[0]):
        return None, (f"DRIFT {display(relative_path)}: no valid frontmatter found",)

    closing_index = next(
        (
            index
            for index, line in enumerate(lines[1:], start=1)
            if FRONTMATTER_DELIMITER.fullmatch(line)
        ),
        None,
    )
    if closing_index is None:
        return None, (f"DRIFT {display(relative_path)}: unterminated frontmatter",)

    try:
        frontmatter = FrontmatterParser(lines[1:closing_index]).parse()
        if "name" not in frontmatter:
            raise FrontmatterSyntaxError("missing required field: name")
        name = validate_string(frontmatter["name"], "name")
        if not ROLE_NAME.fullmatch(name):
            raise FrontmatterSyntaxError(
                "field name must be a lowercase role identifier"
            )
    except FrontmatterSyntaxError as error:
        if str(error).startswith("missing required field: name"):
            message = f"DRIFT {display(relative_path)}: no frontmatter name found"
        else:
            message = (
                f"DRIFT {display(relative_path)}: invalid YAML frontmatter: {error}"
            )
        return None, (message,)

    unapproved_references = list(
        find_unapproved_instruction_references(frontmatter, "frontmatter")
    )
    if references_odyssey_instruction(text):
        unapproved_references.append("definition text")
    return Definition(
        relative_path,
        name,
        tuple(dict.fromkeys(unapproved_references)),
    ), ()


def load_inventory(
    root_fd: int,
    parts: tuple[str, ...],
    label: str,
    kind: str,
) -> Inventory:
    directory_fd = open_relative_directory(root_fd, parts, label)
    try:
        directory_before = os.fstat(directory_fd)
        try:
            names = [
                name
                for name in bounded_directory_names(directory_fd, label)
                if name.endswith(".md")
            ]
        except OSError as error:
            raise UnavailableError(
                f"cannot list hierarchy directory {display(label)}: {error}"
            ) from error
        names = [name for name in names if name != "README.md"]
        if not names:
            raise UnavailableError(
                f"{kind} hierarchy has no agent definitions: {display(label)}"
            )

        definitions: dict[str, Definition] = {}
        issues: list[str] = []
        for name in names:
            relative_path = f"{label}/{name}"
            text = read_regular_file(directory_fd, name, relative_path)
            definition, parse_issues = parse_definition(text, relative_path)
            issues.extend(parse_issues)
            if definition is None:
                continue
            if definition.name in definitions:
                if kind == "runtime":
                    issues.append(
                        "DRIFT duplicate Myrmidons runtime frontmatter name "
                        + display(definition.name)
                    )
                else:
                    issues.append(
                        f"DRIFT duplicate frontmatter name {display(definition.name)} "
                        f"in {display(label)}"
                    )
                continue
            definitions[definition.name] = definition

        directory_after = os.fstat(directory_fd)
        if stable_identity(directory_before) != stable_identity(directory_after):
            raise UnavailableError(
                f"hierarchy directory changed while it was read: {display(label)}"
            )
        rebound_fd = open_relative_directory(root_fd, parts, label)
        try:
            if object_identity(directory_after) != object_identity(os.fstat(rebound_fd)):
                raise UnavailableError(
                    f"hierarchy directory was replaced while it was read: {display(label)}"
                )
        finally:
            os.close(rebound_fd)
    finally:
        os.close(directory_fd)

    return Inventory(MappingProxyType(dict(definitions)), tuple(issues))


def find_pool_references(
    value: Any, location: str = "document"
) -> tuple[str, ...]:
    references: list[str] = []
    if isinstance(value, dict):
        for key, item in value.items():
            item_location = f"{location}.{key}"
            if key == "pool":
                references.append(item_location)
            references.extend(find_pool_references(item, item_location))
    elif isinstance(value, list):
        for index, item in enumerate(value):
            references.extend(
                find_pool_references(item, f"{location}[{index}]")
            )
    elif isinstance(value, str) and value.startswith("pool:"):
        references.append(location)
    return tuple(dict.fromkeys(references))


def parse_runtime_manifest(
    text: str, relative_path: str
) -> tuple[tuple[RuntimeConsumer, ...], tuple[str, ...]]:
    try:
        document = FrontmatterParser(text.splitlines(), start_line=1).parse()
    except FrontmatterSyntaxError as error:
        return (), (
            f"DRIFT {display(relative_path)}: invalid runtime manifest YAML: {error}",
        )

    if not find_pool_references(document):
        return (), ()

    spec = document.get("spec")
    if not isinstance(spec, dict):
        return (), (
            f"DRIFT {display(relative_path)}: runtime manifest has no spec mapping",
        )
    tags = spec.get("tags")
    if not isinstance(tags, list):
        return (), (
            f"DRIFT {display(relative_path)}: runtime manifest tags must be a sequence",
        )

    consumers: list[RuntimeConsumer] = []
    issues: list[str] = []
    for index, tag in enumerate(tags):
        if not isinstance(tag, str):
            issues.append(
                f"DRIFT {display(relative_path)}: pool-like tag must be a text "
                f"scalar at spec.tags[{index}]"
            )
            continue
        if not tag.startswith("pool:"):
            continue
        match = POOL_REFERENCE.fullmatch(tag)
        if match is None:
            issues.append(
                f"DRIFT {display(relative_path)}: invalid pool consumer reference "
                + display(tag)
            )
            continue
        domain, role = match.groups()
        consumers.append(RuntimeConsumer(relative_path, tag[5:], domain, role))

    document_without_tags = dict(document)
    spec_without_tags = dict(spec)
    spec_without_tags.pop("tags", None)
    document_without_tags["spec"] = spec_without_tags
    for reference in find_pool_references(
        document_without_tags, "manifest"
    ):
        issues.append(
            f"DRIFT {display(relative_path)}: pool consumer reference is "
            f"outside spec.tags at {display(reference)}"
        )

    if consumers:
        references = list(
            find_unapproved_instruction_references(document, "manifest")
        )
        if references_odyssey_instruction(text):
            references.append("manifest text")
        for reference in dict.fromkeys(references):
            issues.append(
                f"DRIFT {display(relative_path)}: unapproved Odyssey instruction "
                f"reference at {display(reference)}"
            )
    return tuple(consumers), tuple(issues)


def load_manifest_directory(
    root_fd: int, parts: tuple[str, ...], label: str
) -> tuple[tuple[RuntimeConsumer, ...], tuple[str, ...]]:
    directory_fd = open_relative_directory(root_fd, parts, label)
    try:
        directory_before = os.fstat(directory_fd)
        try:
            names = [
                name
                for name in bounded_directory_names(directory_fd, label)
                if name.endswith((".yaml", ".yml"))
            ]
        except OSError as error:
            raise UnavailableError(
                f"cannot list runtime manifest directory {display(label)}: {error}"
            ) from error

        consumers: list[RuntimeConsumer] = []
        issues: list[str] = []
        for name in names:
            relative_path = f"{label}/{name}"
            text = read_regular_file(directory_fd, name, relative_path)
            parsed_consumers, parse_issues = parse_runtime_manifest(
                text, relative_path
            )
            consumers.extend(parsed_consumers)
            issues.extend(parse_issues)

        directory_after = os.fstat(directory_fd)
        if stable_identity(directory_before) != stable_identity(directory_after):
            raise UnavailableError(
                f"runtime manifest directory changed while it was read: "
                f"{display(label)}"
            )
        rebound_fd = open_relative_directory(root_fd, parts, label)
        try:
            if object_identity(directory_after) != object_identity(os.fstat(rebound_fd)):
                raise UnavailableError(
                    f"runtime manifest directory was replaced while it was read: "
                    f"{display(label)}"
                )
        finally:
            os.close(rebound_fd)
    finally:
        os.close(directory_fd)
    return tuple(consumers), tuple(issues)


def load_runtime_consumers(
    root_fd: int,
) -> tuple[tuple[RuntimeConsumer, ...], tuple[str, ...]]:
    directory_fd = open_relative_directory(
        root_fd, MYRMIDONS_AGENTS_PARTS, MYRMIDONS_AGENTS_DISPLAY
    )
    try:
        directory_before = os.fstat(directory_fd)
        try:
            names = bounded_directory_names(
                directory_fd, MYRMIDONS_AGENTS_DISPLAY
            )
        except OSError as error:
            raise UnavailableError(
                f"cannot list Myrmidons agent manifests: {error}"
            ) from error

        consumers: list[RuntimeConsumer] = []
        issues: list[str] = []
        for name in names:
            if name == "hierarchy":
                continue
            relative_path = f"{MYRMIDONS_AGENTS_DISPLAY}/{name}"
            metadata = checked_lstat(name, directory_fd, relative_path)
            if stat.S_ISLNK(metadata.st_mode):
                raise UnavailableError(
                    f"runtime manifest path is a symlink: {display(relative_path)}"
                )
            if stat.S_ISDIR(metadata.st_mode):
                nested_consumers, nested_issues = load_manifest_directory(
                    root_fd,
                    MYRMIDONS_AGENTS_PARTS + (name,),
                    relative_path,
                )
                consumers.extend(nested_consumers)
                issues.extend(nested_issues)
                continue
            if name.endswith((".yaml", ".yml")):
                if not stat.S_ISREG(metadata.st_mode):
                    raise UnavailableError(
                        f"runtime manifest is not a direct regular file: "
                        f"{display(relative_path)}"
                    )
                text = read_regular_file(directory_fd, name, relative_path)
                parsed_consumers, parse_issues = parse_runtime_manifest(
                    text, relative_path
                )
                consumers.extend(parsed_consumers)
                issues.extend(parse_issues)

        directory_after = os.fstat(directory_fd)
        if stable_identity(directory_before) != stable_identity(directory_after):
            raise UnavailableError(
                "Myrmidons agent manifest directory changed while it was read"
            )
        rebound_fd = open_relative_directory(
            root_fd, MYRMIDONS_AGENTS_PARTS, MYRMIDONS_AGENTS_DISPLAY
        )
        try:
            if object_identity(directory_after) != object_identity(os.fstat(rebound_fd)):
                raise UnavailableError(
                    "Myrmidons agent manifest directory was replaced while it was read"
                )
        finally:
            os.close(rebound_fd)
    finally:
        os.close(directory_fd)

    if not consumers:
        raise UnavailableError(
            "Myrmidons has no provisioned pool consumer references"
        )
    return tuple(consumers), tuple(issues)


def compare() -> tuple[tuple[str, ...], int, int, int]:
    require_descriptor_apis()
    root_fd = open_repository_root()
    try:
        runtime_definitions = load_inventory(
            root_fd,
            RUNTIME_DEFINITION_PARTS,
            RUNTIME_DEFINITION_DISPLAY,
            "runtime",
        )
        runtime_consumers, consumer_issues = load_runtime_consumers(root_fd)
        instruction_roles = load_inventory(
            root_fd,
            ODYSSEY_INSTRUCTION_PARTS,
            ODYSSEY_INSTRUCTION_DISPLAY,
            "instruction",
        )
    finally:
        os.close(root_fd)

    output: list[str] = ["## Myrmidons runtime roles", ""]
    output.extend(runtime_definitions.issues)
    output.extend(consumer_issues)
    for definition in runtime_definitions.definitions.values():
        for reference in definition.unapproved_references:
            output.append(
                f"DRIFT {display(definition.path)}: unapproved Odyssey "
                f"instruction reference at {display(reference)}"
            )

    consumer_roles: dict[str, list[RuntimeConsumer]] = {}
    for consumer in runtime_consumers:
        consumer_roles.setdefault(consumer.role, []).append(consumer)
        if consumer.role not in runtime_definitions.definitions:
            output.append(
                f"DRIFT pool consumer {display(consumer.reference)} has no "
                "Myrmidons runtime definition"
            )
    for name in sorted(runtime_definitions.definitions):
        if name not in consumer_roles:
            output.append(
                f"DRIFT Myrmidons runtime role {display(name)} has no "
                "provisioned pool consumer"
            )

    output.extend(("", "## Odyssey instruction roles", ""))
    output.extend(instruction_roles.issues)
    actual_instruction_roles = frozenset(instruction_roles.definitions)
    for name in sorted(RETAINED_ODYSSEY_ROLES - actual_instruction_roles):
        output.append(
            f"DRIFT missing retained Odyssey instruction role {display(name)}"
        )
    for name in sorted(actual_instruction_roles - RETAINED_ODYSSEY_ROLES):
        output.append(
            f"DRIFT surplus Odyssey instruction role {display(name)}"
        )
    output.append("")

    report_size = sum(len(line.encode("utf-8")) + 1 for line in output)
    if report_size > MAX_REPORT_BYTES:
        raise UnavailableError(
            f"hierarchy report exceeds the {MAX_REPORT_BYTES}-byte output limit"
        )

    notice_count = 0
    return (
        tuple(output),
        notice_count,
        len(runtime_consumers),
        len(actual_instruction_roles),
    )


def report_unavailable(reason: str) -> None:
    if CI_MODE:
        print("hierarchy_available=false")
        print("hierarchy_drift=unknown")
        print("hierarchy_notices=0")
    else:
        print(f"Hierarchy sync UNAVAILABLE: {reason}", file=sys.stderr)
    print(f"error: {reason}", file=sys.stderr)


CI_MODE = sys.argv[1] == "1"
try:
    report_lines, notices, runtime_consumer_count, instruction_role_count = compare()
except UnavailableError as error:
    report_unavailable(str(error))
    result = "unavailable"
except Exception as error:
    report_unavailable(
        f"internal hierarchy comparison failure: {type(error).__name__}: {error}"
    )
    result = "unavailable"
else:
    for report_line in report_lines:
        print(report_line)
    drift_count = sum(line.startswith("DRIFT ") for line in report_lines)
    if CI_MODE:
        print("hierarchy_available=true")
        print(f"hierarchy_drift={'true' if drift_count else 'false'}")
        print(f"hierarchy_notices={notices}")
        print(f"hierarchy_runtime_consumers={runtime_consumer_count}")
        print(f"hierarchy_instruction_roles={instruction_role_count}")
    elif drift_count:
        print(f"Hierarchy sync FAILED: {drift_count} drift item(s).", file=sys.stderr)
    else:
        print(f"Hierarchy sync OK ({notices} notice(s)).")
    result = "drift" if drift_count else "clean"

receipt = {
    "schema": "odysseus.hierarchy-check",
    "version": 1,
    "result": result,
}
print("hierarchy_receipt=" + json.dumps(receipt, sort_keys=True, separators=(",", ":")))
raise SystemExit(0)
PY
}

PYTHON_OUTPUT="$(run_embedded_comparison)"
PYTHON_STATUS=$?
if [ "$PYTHON_STATUS" -ne 0 ]; then
  report_shell_unavailable \
    "embedded Python hierarchy comparison failed with status $PYTHON_STATUS"
fi

RECEIPT_NEWLINE='
'
PYTHON_RECEIPT="${PYTHON_OUTPUT##*"$RECEIPT_NEWLINE"}"
if [ "$PYTHON_OUTPUT" = "$PYTHON_RECEIPT" ]; then
  PYTHON_REPORT=''
else
  PYTHON_REPORT="${PYTHON_OUTPUT%"$RECEIPT_NEWLINE$PYTHON_RECEIPT"}"
fi

CLEAN_RECEIPT='hierarchy_receipt={"result":"clean","schema":"odysseus.hierarchy-check","version":1}'
DRIFT_RECEIPT='hierarchy_receipt={"result":"drift","schema":"odysseus.hierarchy-check","version":1}'
UNAVAILABLE_RECEIPT='hierarchy_receipt={"result":"unavailable","schema":"odysseus.hierarchy-check","version":1}'
case "$PYTHON_RECEIPT" in
  "$CLEAN_RECEIPT")       RESULT_STATUS=0 ;;
  "$DRIFT_RECEIPT")       RESULT_STATUS=1 ;;
  "$UNAVAILABLE_RECEIPT") RESULT_STATUS=2 ;;
  *)
    report_shell_unavailable \
      "embedded Python hierarchy comparison returned no valid completion receipt"
    ;;
esac

if [ -n "$PYTHON_REPORT" ]; then
  printf '%s\n' "$PYTHON_REPORT"
fi
exit "$RESULT_STATUS"
