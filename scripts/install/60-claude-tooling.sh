#!/usr/bin/env bash
# Phase 60 — Claude Code Tooling
#
# Steps:
#   1. Validate a pre-provisioned Claude Code CLI
#   2. Merge settings.json: register the Athena marketplace and plugin
#   3. Clone or update Mnemosyne agent brain seed
#
# Idempotent: each step checks state before acting.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Claude Code Tooling"

# ─── Step 1: Claude Code CLI ─────────────────────────────────────────────────
# Claude Code is developer/interactive tooling and is not required for a
# headless worker to run jobs. This phase validates an existing executable but
# deliberately does not pipe a mutable network response into a shell or choose
# a release artifact on the operator's behalf. A missing CLI remains a warning;
# provision a verified, version-pinned artifact through the host's approved
# software-management path.
CLAUDE_VERSION_TIMEOUT_SECONDS=3
CLAUDE_VERSION_MAX_BYTES=65536
CLAUDE_EXECUTABLE_MAX_BYTES=268435456
MNEMOSYNE_GIT_TIMEOUT_SECONDS=5
MNEMOSYNE_GIT_MAX_BYTES=65536
MNEMOSYNE_GIT_EXECUTABLE_MAX_BYTES=536870912

_ODYSSEUS_TOOL_BINDING_FAILURE=false
_ODYSSEUS_TOOL_SNAPSHOT_DIR=""
_ODYSSEUS_BOUND_PYTHON=""
_ODYSSEUS_BOUND_PYTHON_IDENTITY=""
_ODYSSEUS_BOUND_GIT=""
_ODYSSEUS_BOUND_GIT_IDENTITY=""
_ODYSSEUS_BOUND_GIT_INTERPRETER="-"
_ODYSSEUS_BOUND_GIT_INTERPRETER_IDENTITY="-"
_ODYSSEUS_TOOL_SNAPSHOT_IDENTITY=""

_trusted_root_object() {
    local path="$1" expected="$2" record owner mode kind
    [[ "$path" == /* && "$path" != *$'\n'* && ! -L "$path" ]] || return 1
    if [[ "$OSTYPE" == darwin* ]]; then
        record=$(/usr/bin/stat -Lf '%u:%Lp:%HT' "$path" 2>/dev/null) \
            || return 1
    else
        record=$(/usr/bin/stat -Lc '%u:%a:%F' "$path" 2>/dev/null) \
            || return 1
    fi
    IFS=: read -r owner mode kind <<< "$record"
    [[ "$owner" == 0 && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    case "$expected:$kind" in
        file:'Regular File'|file:'regular file'|directory:'Directory'|directory:directory)
            return 0
            ;;
    esac
    return 1
}

_select_trusted_python() {
    local candidate parent prefix
    for candidate in \
        /usr/bin/python3 \
        /usr/bin/python3.14 /usr/bin/python3.13 /usr/bin/python3.12 \
        /usr/bin/python3.11 /usr/bin/python3.10 /usr/bin/python3.9 \
        /usr/local/bin/python3.14 /usr/local/bin/python3.13 \
        /usr/local/bin/python3.12 /usr/local/bin/python3.11 \
        /usr/local/bin/python3.10 /usr/local/bin/python3.9; do
        [[ -f "$candidate" && -x "$candidate" ]] || continue
        _trusted_root_object "$candidate" file || continue
        # Bash 3.2 (the system shell on supported Darwin hosts) provides
        # `read -n`, while `read -N` is a later Bash extension.
        IFS= read -r -n 2 prefix < "$candidate" || continue
        # The trust bootstrap itself must be a native fixed executable. A
        # script would reopen an otherwise-unbound shebang chain before Python
        # could establish descriptor-backed tool bindings.
        [[ "$prefix" != '#!' ]] || continue
        parent=${candidate%/*}
        while [[ "$parent" != / ]]; do
            _trusted_root_object "$parent" directory || break
            parent=${parent%/*}
            [[ -n "$parent" ]] || parent=/
        done
        [[ "$parent" == / ]] || continue
        _trusted_root_object / directory || continue
        _ODYSSEUS_BOUND_PYTHON="$candidate"
        return 0
    done
    return 1
}

_trusted_python() (
    # Bash's exec builtin creates the environment from empty, including when
    # the caller has exported a readonly variable that cannot be unset. No
    # PATH-selected `env` program becomes part of the trust root.
    exec -c "$_ODYSSEUS_BOUND_PYTHON" -I -S "$@"
)

_trusted_python_exec() {
    exec -c "$_ODYSSEUS_BOUND_PYTHON" -I -S "$@"
}

_initialize_tool_bindings() {
    local git_candidate binding
    _select_trusted_python || return 1
    git_candidate=$(command -v git 2>/dev/null) || return 1
    [[ "$git_candidate" == /* && "$git_candidate" != *$'\n'* ]] \
        || return 1
    binding=$(
        _trusted_python - \
            "$_ODYSSEUS_BOUND_PYTHON" "$git_candidate" \
            "$MNEMOSYNE_GIT_EXECUTABLE_MAX_BYTES" <<'PYEOF'
import hashlib
import os
import stat
import sys
import tempfile


class ToolBindingError(RuntimeError):
    pass


python_source, git_source, maximum_size_text = sys.argv[1:]
maximum_size = int(maximum_size_text)


def identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def node_identity(value):
    return value.st_dev, value.st_ino


def validate_root_chain(path, label):
    current = os.path.dirname(path)
    while True:
        state = os.stat(current, follow_symlinks=False)
        if (
            not stat.S_ISDIR(state.st_mode)
            or state.st_uid != 0
            or stat.S_IMODE(state.st_mode) & 0o022
        ):
            raise ToolBindingError(f"{label} executable ancestry is not trusted")
        if current == "/":
            return
        current = os.path.dirname(current)


def open_verified(path, label, root_only=False):
    resolved = os.path.realpath(os.path.abspath(path))
    if not os.path.isabs(resolved) or "\n" in resolved or "\t" in resolved:
        raise ToolBindingError(f"{label} executable path is invalid")
    descriptor = os.open(
        resolved,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        opened = os.fstat(descriptor)
        named = os.stat(resolved, follow_symlinks=False)
        if identity(opened) != identity(named):
            raise ToolBindingError(f"{label} executable changed while opening")
        if not stat.S_ISREG(opened.st_mode):
            raise ToolBindingError(f"{label} executable is not a regular file")
        permitted_owners = {0} if root_only else {0, os.geteuid()}
        if opened.st_uid not in permitted_owners:
            raise ToolBindingError(f"{label} executable owner is not trusted")
        if opened.st_nlink < 1:
            raise ToolBindingError(f"{label} executable has no stable link")
        if stat.S_IMODE(opened.st_mode) & 0o022:
            raise ToolBindingError(f"{label} executable is writable by another identity")
        if not stat.S_IMODE(opened.st_mode) & 0o111:
            raise ToolBindingError(f"{label} executable is not executable")
        if opened.st_size <= 0 or opened.st_size > maximum_size:
            raise ToolBindingError(f"{label} executable size is outside its bound")
        if root_only:
            validate_root_chain(resolved, label)
        return resolved, descriptor, opened
    except BaseException:
        os.close(descriptor)
        raise


def copy_snapshot(source_descriptor, source_state, directory_descriptor, name):
    target = os.open(
        name,
        os.O_WRONLY
        | os.O_CREAT
        | os.O_EXCL
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_CLOEXEC", 0),
        0o500,
        dir_fd=directory_descriptor,
    )
    created_snapshots[name] = node_identity(os.fstat(target))
    digest = hashlib.sha256()
    copied = 0
    try:
        while True:
            chunk = os.read(source_descriptor, min(65536, maximum_size + 1 - copied))
            if not chunk:
                break
            copied += len(chunk)
            if copied > maximum_size:
                raise ToolBindingError("tool executable exceeded its byte bound")
            digest.update(chunk)
            offset = 0
            while offset < len(chunk):
                written = os.write(target, chunk[offset:])
                if written <= 0:
                    raise ToolBindingError("tool snapshot write made no progress")
                offset += written
        if copied != source_state.st_size:
            raise ToolBindingError("tool executable changed while it was copied")
        os.fchmod(target, 0o500)
        os.fsync(target)
        target_state = os.fstat(target)
        named = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
        if identity(named) != identity(target_state):
            raise ToolBindingError("tool snapshot name changed during publication")
        return target_state, digest.hexdigest()
    finally:
        os.close(target)


snapshot_directory = os.path.realpath(
    tempfile.mkdtemp(prefix=".odysseus-tooling-", dir="/tmp")
)
os.chmod(snapshot_directory, 0o700)
directory_descriptor = os.open(
    snapshot_directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
snapshot_directory_identity = node_identity(os.fstat(directory_descriptor))
created_snapshots = {}
try:
    python_path, python_descriptor, python_state = open_verified(
        python_source, "Python", root_only=True
    )
    try:
        python_snapshot = python_path
        bound_python_state = python_state
        if identity(os.fstat(python_descriptor)) != identity(python_state):
            raise ToolBindingError("Python executable changed during binding")
        if identity(os.stat(python_path, follow_symlinks=False)) != identity(
            python_state
        ):
            raise ToolBindingError("Python executable name changed during binding")
    finally:
        os.close(python_descriptor)

    git_path, git_descriptor, git_state = open_verified(git_source, "Git")
    try:
        header = os.pread(git_descriptor, 4096, 0)
        git_snapshot_state, _git_digest = copy_snapshot(
            git_descriptor, git_state, directory_descriptor, "git"
        )
        bound_git = os.path.join(snapshot_directory, "git")
        bound_git_state = git_snapshot_state
        interpreter_path = "-"
        interpreter_state = None
        if header.startswith(b"#!"):
            first_line = header.split(b"\n", 1)[0]
            try:
                interpreter_fields = first_line[2:].decode("ascii").strip().split()
            except UnicodeError as error:
                raise ToolBindingError("Git shebang is not ASCII") from error
            if len(interpreter_fields) != 1 or interpreter_fields[0] not in {
                "/bin/bash",
                "/usr/bin/bash",
            }:
                raise ToolBindingError("Git shebang interpreter is not supported")
            (
                _resolved_interpreter,
                interpreter_descriptor,
                source_interpreter_state,
            ) = open_verified(
                interpreter_fields[0], "Git shebang interpreter", root_only=True
            )
            try:
                interpreter_state, _interpreter_digest = copy_snapshot(
                    interpreter_descriptor,
                    source_interpreter_state,
                    directory_descriptor,
                    "git-interpreter",
                )
                if identity(os.fstat(interpreter_descriptor)) != identity(
                    source_interpreter_state
                ):
                    raise ToolBindingError(
                        "Git shebang interpreter changed during binding"
                    )
            finally:
                os.close(interpreter_descriptor)
            interpreter_path = os.path.join(
                snapshot_directory, "git-interpreter"
            )
        if identity(os.fstat(git_descriptor)) != identity(git_state):
            raise ToolBindingError("Git executable changed during binding")
        if identity(os.stat(git_path, follow_symlinks=False)) != identity(git_state):
            raise ToolBindingError("Git executable name changed during binding")
    finally:
        os.close(git_descriptor)

    os.chmod(snapshot_directory, 0o500)
    git_fields = (
        bound_git_state.st_dev,
        bound_git_state.st_ino,
        bound_git_state.st_uid,
        bound_git_state.st_mode,
        bound_git_state.st_nlink,
        bound_git_state.st_size,
        bound_git_state.st_mtime_ns,
        bound_git_state.st_ctime_ns,
    )
    python_fields = (
        bound_python_state.st_dev,
        bound_python_state.st_ino,
        bound_python_state.st_uid,
        bound_python_state.st_mode,
        bound_python_state.st_nlink,
        bound_python_state.st_size,
        bound_python_state.st_mtime_ns,
        bound_python_state.st_ctime_ns,
    )
    directory_state = os.fstat(directory_descriptor)
    directory_fields = (
        directory_state.st_dev,
        directory_state.st_ino,
        directory_state.st_uid,
        directory_state.st_mode,
    )
    if interpreter_state is None:
        interpreter_fields = "-"
    else:
        interpreter_fields = ":".join(
            map(
                str,
                (
                    interpreter_state.st_dev,
                    interpreter_state.st_ino,
                    interpreter_state.st_uid,
                    interpreter_state.st_mode,
                    interpreter_state.st_nlink,
                    interpreter_state.st_size,
                    interpreter_state.st_mtime_ns,
                    interpreter_state.st_ctime_ns,
                ),
            )
        )
    print(
        "\t".join(
            (
                snapshot_directory,
                python_snapshot,
                ":".join(map(str, python_fields)),
                bound_git,
                ":".join(map(str, git_fields)),
                interpreter_path,
                interpreter_fields,
                ":".join(map(str, directory_fields)),
            )
        )
    )
except BaseException:
    cleanup_error = None
    try:
        os.fchmod(directory_descriptor, 0o700)
        for name, expected_identity in created_snapshots.items():
            try:
                current = os.stat(
                    name,
                    dir_fd=directory_descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            if node_identity(current) == expected_identity:
                os.unlink(name, dir_fd=directory_descriptor)
        os.fsync(directory_descriptor)
        try:
            named_directory = os.stat(
                snapshot_directory, follow_symlinks=False
            )
        except FileNotFoundError:
            named_directory = None
        if (
            named_directory is not None
            and node_identity(named_directory) == snapshot_directory_identity
            and not os.listdir(directory_descriptor)
        ):
            os.rmdir(snapshot_directory)
    except BaseException as error:
        cleanup_error = error
    if cleanup_error is not None:
        raise ToolBindingError(
            "failed tool snapshot could not be retired exactly"
        ) from cleanup_error
    raise
finally:
    os.close(directory_descriptor)
PYEOF
    ) || return 1
    IFS=$'\t' read -r _ODYSSEUS_TOOL_SNAPSHOT_DIR \
        _ODYSSEUS_BOUND_PYTHON _ODYSSEUS_BOUND_PYTHON_IDENTITY \
        _ODYSSEUS_BOUND_GIT _ODYSSEUS_BOUND_GIT_IDENTITY \
        _ODYSSEUS_BOUND_GIT_INTERPRETER \
        _ODYSSEUS_BOUND_GIT_INTERPRETER_IDENTITY \
        _ODYSSEUS_TOOL_SNAPSHOT_IDENTITY <<< "$binding"
    [[ "$_ODYSSEUS_TOOL_SNAPSHOT_DIR" == /tmp/.odysseus-tooling-* \
        || "$_ODYSSEUS_TOOL_SNAPSHOT_DIR" == \
            /private/tmp/.odysseus-tooling-* ]] \
        || return 1
    [[ -x "$_ODYSSEUS_BOUND_PYTHON" && -x "$_ODYSSEUS_BOUND_GIT" ]] || return 1
    if [[ "$_ODYSSEUS_BOUND_GIT_INTERPRETER" != - ]]; then
        [[ -x "$_ODYSSEUS_BOUND_GIT_INTERPRETER" ]] || return 1
    fi
}

if ! _initialize_tool_bindings; then
    check_fail "tooling executable identities could not be bound"
    _ODYSSEUS_TOOL_BINDING_FAILURE=true
fi

_probe_claude_version() {
    local executable="$1" output status
    [[ -n "$_ODYSSEUS_BOUND_PYTHON" ]] || return 1
    output=$(
        _trusted_python - \
            "$executable" \
            "$CLAUDE_VERSION_TIMEOUT_SECONDS" \
            "$CLAUDE_VERSION_MAX_BYTES" \
            "$CLAUDE_EXECUTABLE_MAX_BYTES" \
            2>/dev/null <<'PYEOF'
import ctypes
import os
import re
import select
import selectors
import signal
import stat
import subprocess
import sys
import tempfile
import time


class ProbeFailure(RuntimeError):
    pass


source_argument = sys.argv[1]
timeout_seconds = int(sys.argv[2])
maximum_output_bytes = int(sys.argv[3])
maximum_executable_bytes = int(sys.argv[4])
deadline = time.monotonic() + timeout_seconds
semantic_version = re.compile(
    rb"(^|[^0-9])[0-9]+\.[0-9]+(?:\.[0-9]+)?(?:[^0-9]|$)"
)


def remaining():
    if interrupted is not None:
        raise ProbeFailure("Claude version probe was interrupted")
    value = deadline - time.monotonic()
    if value <= 0:
        raise ProbeFailure("Claude version probe timed out")
    return value


def source_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def validate_executable(value):
    if not stat.S_ISREG(value.st_mode):
        raise ProbeFailure("Claude executable is not a regular file")
    if value.st_uid not in {0, os.geteuid()}:
        raise ProbeFailure("Claude executable has an untrusted owner")
    if value.st_nlink != 1:
        raise ProbeFailure("Claude executable must have exactly one link")
    if stat.S_IMODE(value.st_mode) & 0o022:
        raise ProbeFailure("Claude executable is writable by another identity")
    if not stat.S_IMODE(value.st_mode) & 0o111:
        raise ProbeFailure("Claude executable is not executable")
    if value.st_size <= 0 or value.st_size > maximum_executable_bytes:
        raise ProbeFailure("Claude executable size is outside the allowed range")


def linux_process_identity(process_id):
    try:
        with open(
            f"/proc/{process_id}/stat", "rb", buffering=0
        ) as stream:
            record = stream.read(65537)
    except (FileNotFoundError, ProcessLookupError):
        return None
    if len(record) > 65536:
        raise ProbeFailure("process identity exceeds its byte limit")
    closing = record.rfind(b")")
    fields = record[closing + 2 :].split() if closing >= 1 else ()
    if len(fields) <= 19:
        raise ProbeFailure("process identity is malformed")
    return process_id, int(fields[19])


def linux_child_pids(process_id):
    task_root = f"/proc/{process_id}/task"
    try:
        tasks = tuple(
            entry.name
            for entry in os.scandir(task_root)
            if entry.name.isdecimal()
        )
    except (FileNotFoundError, ProcessLookupError):
        return set()
    children = set()
    for task in tasks:
        try:
            with open(
                f"{task_root}/{task}/children", "rb", buffering=0
            ) as stream:
                payload = stream.read(1048577)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if len(payload) > 1048576:
            raise ProbeFailure("child inventory exceeds its byte limit")
        for item in payload.split():
            if not item.isdigit():
                raise ProbeFailure("child inventory is malformed")
            child = int(item)
            if child > 1:
                children.add(child)
    return children


class LinuxScope:
    def __init__(self):
        if not hasattr(os, "pidfd_open") or not hasattr(
            signal, "pidfd_send_signal"
        ):
            raise ProbeFailure("Linux pidfd containment is unavailable")
        library = ctypes.CDLL(None, use_errno=True)
        operation = library.prctl
        operation.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        operation.restype = ctypes.c_int
        if operation(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            number = ctypes.get_errno() or 1
            raise ProbeFailure(
                f"Linux subreaper containment failed with errno {number}"
            )
        self.supervisor = os.getpid()
        self.processes = {}
        self.root = None

    def track(self, process_id):
        identity = linux_process_identity(process_id)
        if identity is None:
            return False
        previous = self.processes.get(process_id)
        if previous is not None and previous[0] == identity[1]:
            return False
        if previous is not None:
            os.close(previous[1])
        descriptor = os.pidfd_open(process_id, 0)
        if linux_process_identity(process_id) != identity:
            os.close(descriptor)
            raise ProbeFailure("process identity changed during binding")
        self.processes[process_id] = (identity[1], descriptor)
        return True

    def track_root(self, process_id):
        if not self.track(process_id):
            raise ProbeFailure("could not bind the Claude probe process")
        self.root = process_id

    def discover(self):
        while True:
            candidates = set(linux_child_pids(self.supervisor))
            for process_id, (start_time, _descriptor) in tuple(
                self.processes.items()
            ):
                if linux_process_identity(process_id) == (
                    process_id,
                    start_time,
                ):
                    candidates.update(linux_child_pids(process_id))
            changed = False
            for process_id in candidates:
                changed = self.track(process_id) or changed
            if not changed:
                return

    @staticmethod
    def exited(descriptor):
        readable, _writable, _exceptional = select.select(
            [descriptor], [], [], 0
        )
        return bool(readable)

    def live(self):
        self.discover()
        return self.retained_live()

    def retained_live(self):
        active = []
        for process_id, (_start_time, descriptor) in self.processes.items():
            try:
                if self.exited(descriptor):
                    continue
            except OSError:
                pass
            try:
                signal.pidfd_send_signal(descriptor, 0, None, 0)
            except ProcessLookupError:
                continue
            active.append((process_id, descriptor))
        return tuple(active)

    def descendants(self, root):
        return tuple(item for item in self.live() if item[0] != root)

    def reap(self):
        for process_id in tuple(self.processes):
            if process_id == self.root:
                continue
            try:
                os.waitpid(process_id, os.WNOHANG)
            except ChildProcessError:
                pass

    def terminate(self, process):
        cleanup_error = None
        for number, grace in (
            (signal.SIGTERM, 0.2),
            (signal.SIGKILL, 0.8),
        ):
            signal_deadline = time.monotonic() + grace
            while True:
                try:
                    active = self.live()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
                    active = self.retained_live()
                if any(process_id == process.pid for process_id, _fd in active):
                    try:
                        os.killpg(process.pid, number)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        cleanup_error = cleanup_error or error
                if not active:
                    self.reap()
                    if cleanup_error is not None:
                        raise ProbeFailure(
                            "Claude containment inventory failed during cleanup"
                        ) from cleanup_error
                    return
                for _process_id, descriptor in active:
                    try:
                        signal.pidfd_send_signal(descriptor, number, None, 0)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        cleanup_error = cleanup_error or error
                if time.monotonic() >= signal_deadline:
                    break
                time.sleep(0.01)
        try:
            active = self.live()
        except BaseException as error:
            cleanup_error = cleanup_error or error
            active = self.retained_live()
        if active:
            raise ProbeFailure("Claude probe descendants survived cleanup")
        self.reap()
        if cleanup_error is not None:
            raise ProbeFailure(
                "Claude containment inventory failed during cleanup"
            ) from cleanup_error

    def close(self):
        for _start_time, descriptor in self.processes.values():
            os.close(descriptor)
        self.processes.clear()
        self.root = None


class DarwinScope:
    def __init__(self):
        if os.geteuid() == 0:
            raise ProbeFailure(
                "Darwin process containment is unavailable for root"
            )
        self.process_id = None

    def track_root(self, process_id):
        self.process_id = process_id

    def poll(self, timeout=0.0):
        if timeout > 0:
            time.sleep(timeout)

    def descendants(self, root):
        # The gate wrapper applies RLIMIT_NPROC=0 before it executes Claude.
        # A non-root Darwin process cannot create a descendant after that
        # point. If the kernel cannot apply and verify this limit, the wrapper
        # exits before it invokes the executable.
        return ()

    def terminate(self, process):
        if self.process_id is None:
            return
        if process.poll() is not None:
            return
        for number, grace in (
            (signal.SIGTERM, 0.2),
            (signal.SIGKILL, 0.8),
        ):
            try:
                os.killpg(self.process_id, number)
            except ProcessLookupError:
                return
            try:
                process.wait(timeout=grace)
                return
            except subprocess.TimeoutExpired:
                pass
        raise ProbeFailure("Claude probe process survived cleanup")

    def close(self):
        self.process_id = None


def make_scope():
    if sys.platform.startswith("linux"):
        return LinuxScope()
    if sys.platform == "darwin":
        return DarwinScope()
    raise ProbeFailure("exact Claude process containment is unavailable")


def check_snapshot_name(directory_descriptor, name, expected):
    current = os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)
    if (current.st_dev, current.st_ino) != (expected.st_dev, expected.st_ino):
        raise ProbeFailure("Claude executable snapshot name changed")


source_descriptor = None
snapshot_directory = None
snapshot_directory_descriptor = None
snapshot_directory_state = None
snapshot_write_descriptor = None
snapshot_descriptor = None
snapshot_state = None
gate_read = None
gate_write = None
process = None
scope = None
selector = None
interrupted = None
output = bytearray()
probe_error = None
process_status = None


def catch_signal(number, _frame):
    global interrupted
    interrupted = number


try:
    if timeout_seconds <= 0 or maximum_output_bytes <= 0:
        raise ProbeFailure("Claude probe bounds are invalid")
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        signal.signal(number, catch_signal)
    if not getattr(os, "O_NOFOLLOW", 0) or not getattr(
        os, "O_DIRECTORY", 0
    ):
        raise ProbeFailure("descriptor-bound executable inspection is unavailable")
    resolved_source = os.path.realpath(os.path.abspath(source_argument))
    if not os.path.isabs(resolved_source):
        raise ProbeFailure("Claude executable did not resolve to an absolute path")
    source_descriptor = os.open(
        resolved_source,
        os.O_RDONLY | os.O_NOFOLLOW | getattr(os, "O_CLOEXEC", 0),
    )
    initial_source = os.fstat(source_descriptor)
    validate_executable(initial_source)

    snapshot_directory = tempfile.mkdtemp(
        prefix=".odysseus-claude-probe-", dir="/tmp"
    )
    snapshot_directory_descriptor = os.open(
        snapshot_directory,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
    )
    snapshot_directory_state = os.fstat(snapshot_directory_descriptor)
    snapshot_write_descriptor = os.open(
        "claude",
        os.O_RDWR | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o500,
        dir_fd=snapshot_directory_descriptor,
    )
    copied = 0
    while True:
        remaining()
        chunk = os.read(
            source_descriptor,
            min(65536, maximum_executable_bytes + 1 - copied),
        )
        if not chunk:
            break
        copied += len(chunk)
        if copied > maximum_executable_bytes:
            raise ProbeFailure("Claude executable exceeds its byte limit")
        offset = 0
        while offset < len(chunk):
            written = os.write(snapshot_write_descriptor, chunk[offset:])
            if written <= 0:
                raise ProbeFailure("Claude executable snapshot made no progress")
            offset += written
    if copied != initial_source.st_size:
        raise ProbeFailure("Claude executable changed during snapshot")
    if source_identity(os.fstat(source_descriptor)) != source_identity(
        initial_source
    ):
        raise ProbeFailure("Claude executable changed during snapshot")
    os.fchmod(snapshot_write_descriptor, 0o500)
    os.fsync(snapshot_write_descriptor)
    snapshot_state = os.fstat(snapshot_write_descriptor)
    check_snapshot_name(
        snapshot_directory_descriptor, "claude", snapshot_state
    )
    os.close(snapshot_write_descriptor)
    snapshot_write_descriptor = None
    snapshot_descriptor = os.open(
        "claude",
        os.O_RDONLY | os.O_NOFOLLOW,
        dir_fd=snapshot_directory_descriptor,
    )
    if source_identity(os.fstat(snapshot_descriptor))[:6] != source_identity(
        snapshot_state
    )[:6]:
        raise ProbeFailure("Claude executable snapshot changed before binding")
    snapshot_path = os.path.join(snapshot_directory, "claude")

    scope = make_scope()
    gate_read, gate_write = os.pipe()
    child_environment = {
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "XDG_CACHE_HOME": "/nonexistent",
        "XDG_CONFIG_HOME": "/nonexistent",
        "XDG_DATA_HOME": "/nonexistent",
        "XDG_STATE_HOME": "/nonexistent",
    }
    if sys.platform.startswith("linux"):
        execution_path = f"/proc/self/fd/{snapshot_descriptor}"
    else:
        execution_path = snapshot_path
    gate_source = r'''
import os
import resource
import sys

gate = int(sys.argv[1])
execution_path = sys.argv[2]
snapshot = int(sys.argv[3])
expected_device = int(sys.argv[4])
expected_inode = int(sys.argv[5])
if os.read(gate, 1) != b"1":
    raise SystemExit(126)
state = os.fstat(snapshot)
if (state.st_dev, state.st_ino) != (expected_device, expected_inode):
    raise SystemExit(126)
if sys.platform == "darwin":
    if os.geteuid() == 0 or not hasattr(resource, "RLIMIT_NPROC"):
        raise SystemExit(126)
    resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))
    if resource.getrlimit(resource.RLIMIT_NPROC) != (0, 0):
        raise SystemExit(126)
os.execve(execution_path, [execution_path, "--version"], os.environ)
'''
    process = subprocess.Popen(
        [
            sys.executable,
            "-I",
            "-S",
            "-c",
            gate_source,
            str(gate_read),
            execution_path,
            str(snapshot_descriptor),
            str(snapshot_state.st_dev),
            str(snapshot_state.st_ino),
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        pass_fds=(gate_read, snapshot_descriptor),
        start_new_session=True,
        close_fds=True,
        env=child_environment,
    )
    scope.track_root(process.pid)
    check_snapshot_name(
        snapshot_directory_descriptor, "claude", snapshot_state
    )
    os.write(gate_write, b"1")
    os.close(gate_write)
    gate_write = None
    os.close(gate_read)
    gate_read = None

    if process.stdout is None:
        raise ProbeFailure("Claude probe output pipe is unavailable")
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)

    pipe_closed = False
    while True:
        wait = min(0.02, remaining())
        if isinstance(scope, LinuxScope):
            scope.discover()
        else:
            scope.poll(0.0)
        if interrupted is not None:
            raise ProbeFailure("Claude version probe was interrupted")
        if selector.get_map():
            events = selector.select(wait)
        else:
            time.sleep(wait)
            events = ()
        for key, _mask in events:
            chunk = os.read(
                key.fd,
                min(65536, maximum_output_bytes - len(output) + 1),
            )
            if chunk:
                output.extend(chunk)
                if len(output) > maximum_output_bytes:
                    raise ProbeFailure("Claude version output exceeds its byte limit")
            else:
                selector.unregister(key.fileobj)
                pipe_closed = True
        process_status = process.poll()
        if process_status is not None and pipe_closed:
            if isinstance(scope, LinuxScope):
                scope.discover()
                time.sleep(min(0.02, remaining()))
                scope.discover()
            else:
                scope.poll(min(0.02, remaining()))
            if scope.descendants(process.pid):
                raise ProbeFailure("Claude version probe left a descendant")
            break

    if process_status != 0:
        raise ProbeFailure("Claude version command failed")
    first_line = bytes(output).splitlines()[0] if output.splitlines() else b""
    if (
        not first_line
        or len(first_line) > 512
        or any(character < 0x20 or character > 0x7E for character in first_line)
        or semantic_version.search(first_line) is None
    ):
        raise ProbeFailure("Claude version output is invalid")
except BaseException as error:
    probe_error = error
finally:
    if selector is not None:
        selector.close()
    cleanup_error = None
    if process is not None and scope is not None:
        try:
            scope.terminate(process)
        except BaseException as error:
            cleanup_error = error
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            cleanup_error = cleanup_error or ProbeFailure(
                "Claude probe leader survived cleanup"
            )
    if scope is not None:
        try:
            scope.close()
        except BaseException as error:
            cleanup_error = cleanup_error or error
    for descriptor_name in ("gate_write", "gate_read"):
        descriptor = locals()[descriptor_name]
        if descriptor is not None:
            try:
                os.close(descriptor)
            except OSError:
                pass
    if snapshot_descriptor is not None:
        if snapshot_state is not None and source_identity(
            os.fstat(snapshot_descriptor)
        ) != source_identity(snapshot_state):
            cleanup_error = cleanup_error or ProbeFailure(
                "Claude executable snapshot changed during execution"
            )
        os.close(snapshot_descriptor)
    if snapshot_write_descriptor is not None:
        os.close(snapshot_write_descriptor)
    if source_descriptor is not None:
        os.close(source_descriptor)
    if snapshot_directory_descriptor is not None:
        try:
            if snapshot_state is None:
                raise ProbeFailure(
                    "Claude executable snapshot was not bound"
                )
            check_snapshot_name(
                snapshot_directory_descriptor, "claude", snapshot_state
            )
            os.unlink("claude", dir_fd=snapshot_directory_descriptor)
        except (FileNotFoundError, ProbeFailure) as error:
            cleanup_error = cleanup_error or error
        os.close(snapshot_directory_descriptor)
    if snapshot_directory is not None:
        try:
            named_directory_state = os.lstat(snapshot_directory)
            if (
                snapshot_directory_state is None
                or (
                    named_directory_state.st_dev,
                    named_directory_state.st_ino,
                )
                != (
                    snapshot_directory_state.st_dev,
                    snapshot_directory_state.st_ino,
                )
            ):
                raise ProbeFailure(
                    "Claude snapshot directory name changed"
                )
            os.rmdir(snapshot_directory)
        except (OSError, ProbeFailure) as error:
            cleanup_error = cleanup_error or error
    if cleanup_error is not None:
        probe_error = probe_error or cleanup_error

if interrupted is not None:
    signal.signal(interrupted, signal.SIG_DFL)
    os.kill(os.getpid(), interrupted)
if probe_error is not None:
    raise SystemExit(1)
os.write(sys.stdout.fileno(), first_line + b"\n")
PYEOF
    )
    status=$?
    if [[ "$status" -ne 0 ]] || [[ "$output" == *$'\n'* ]] || \
       [[ ! "$output" =~ (^|[^0-9])[0-9]+\.[0-9]+(\.[0-9]+)?([^0-9]|$) ]]; then
        return 1
    fi
    _claude_version_line="$output"
    return 0
}

if has_cmd claude; then
    if [[ "${INSTALL:-false}" != "true" ]]; then
        check_pass "claude — present (version probe deferred to --install)"
    elif _probe_claude_version "$(command -v claude)"; then
        check_pass "claude $_claude_version_line"
    else
        check_fail "claude — version check failed (expected a successful semantic version)"
    fi
else
    if [[ "${INSTALL:-false}" == "true" ]]; then
        check_warn "claude — not installed; pre-provision a verified Claude Code CLI"
    else
        # Detect / check-only mode: warn (not fail) so this phase is flagged
        # for install without counting toward the exit gate.
        check_warn "claude — not installed (pre-provision a verified CLI)"
    fi
fi

# ─── Step 2: settings.json merge ─────────────────────────────────────────────
SETTINGS="$HOME/.claude/settings.json"
SETTINGS_MAX_BYTES=1048576

# The Athena marketplace + plugin is the sole Claude Code surface registered
# by this install script. The Hephaestus marketplace registration that this
# script previously wrote has been removed per the user's directive; the
# `hephaestus` orchestrator library remains installable directly from the
# Hephaestus repo (pip install hephaestus[automation]) without any Claude
# Code marketplace registration required.
# URL matches .gitmodules [submodule "agentic/Athena"].
ATHENA_MARKETPLACE_NAME="Athena"
ATHENA_MARKETPLACE_URL="https://github.com/HomericIntelligence/Athena.git"
ATHENA_PLUGIN_KEY="athena@Athena"

# Plugin keys from PRE-ADR-016 installs (dead marketplace names), the
# non-canonical `hephaestus@Athena` mapping (Claude Code auto-resolved
# `hephaestus` to the Athena marketplace at some point), and the canonical
# `hephaestus@Hephaestus` key that this install script used to register but
# no longer does (per the user's directive). All three are now cleaned
# on --install — leaving any of them in enabledPlugins causes noise-level
# 404s on every plugin enumeration. Space-separated so it can be .split()
# into a Python tuple. Single source of truth — both the precondition
# diagnostic AND the merge purge derive from this; add new legacy keys
# here only.
LEGACY_PLUGIN_KEYS_CSV="hephaestus@ProjectHephaestus hephaestus@Hephaestus hephaestus@Athena"
LEGACY_MARKETPLACE_KEYS_CSV="ProjectHephaestus Hephaestus"
_do_settings_merge=false
_settings_hard_failure="$_ODYSSEUS_TOOL_BINDING_FAILURE"
_settings_binding="settings-binding-v1:absent"

if [[ -L "$SETTINGS" ]]; then
    _settings_hard_failure=true
    check_fail "settings.json — symbolic links are not permitted"
elif [[ -e "$SETTINGS" && ! -f "$SETTINGS" ]]; then
    _settings_hard_failure=true
    check_fail "settings.json — path must be a regular file"
elif [[ -f "$SETTINGS" ]]; then
    # Per-item diagnostic (Athena marketplace + plugin conformance). Python's
    # stdout is captured into DIAGNOSTICS via command substitution. Safe
    # because the data flows through the COMMAND (stdout -> bash variable via
    # $()), not through Python-to-bash variable scope (which doesn't work;
    # see bug note in the merge block below). Detects canonical-marketplace
    # presence, missing plugin keys, and any non-canonical legacy plugin
    # keys. URL comparison tolerates trailing-slash and with/without-.git
    # variants.
    if DIAGNOSTICS=$(_trusted_python - \
        "$SETTINGS" \
        "$ATHENA_MARKETPLACE_NAME" \
        "$ATHENA_MARKETPLACE_URL" \
        "$ATHENA_PLUGIN_KEY" \
        "$LEGACY_PLUGIN_KEYS_CSV" \
        "$LEGACY_MARKETPLACE_KEYS_CSV" \
        "$SETTINGS_MAX_BYTES" \
        2>/dev/null <<'PYEOF'
import hashlib
import json
import os
import stat
import sys
(
    settings_path,
    athena_marketplace_name,
    athena_marketplace_url,
    athena_plugin_key,
    legacy_plugin_keys_csv,
    legacy_marketplace_keys_csv,
    settings_max_bytes_text,
) = sys.argv[1:]
settings_max_bytes = int(settings_max_bytes_text)

class SettingsSecurityError(RuntimeError):
    pass

def inspection_failure(message):
    print(f"inspection failed: {message}")
    sys.exit(2)

def descriptor_flags():
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if (
        not no_follow
        or not directory
        or os.open not in getattr(os, "supports_dir_fd", set())
    ):
        raise SettingsSecurityError(
            "settings.json requires descriptor-relative O_NOFOLLOW support"
        )
    return no_follow, directory

def read_settings_safely(path):
    no_follow, directory = descriptor_flags()
    settings_directory = os.path.dirname(path)
    home_directory = os.path.dirname(settings_directory)
    parent_name = os.path.basename(settings_directory)
    settings_name = os.path.basename(path)
    if (
        not os.path.isabs(path)
        or not home_directory
        or parent_name != ".claude"
        or settings_name != "settings.json"
    ):
        raise SettingsSecurityError("settings.json path is not canonical")

    home_descriptor = None
    parent_descriptor = None
    settings_descriptor = None
    try:
        home_descriptor = os.open(
            home_directory, os.O_RDONLY | directory | no_follow
        )
        parent_descriptor = os.open(
            parent_name,
            os.O_RDONLY | directory | no_follow,
            dir_fd=home_descriptor,
        )
        parent_state = os.fstat(parent_descriptor)
        if (
            not stat.S_ISDIR(parent_state.st_mode)
            or parent_state.st_uid != os.geteuid()
            or stat.S_IMODE(parent_state.st_mode) not in (0o700, 0o755)
        ):
            raise SettingsSecurityError(
                "settings.json parent must be an owner-private direct directory "
                "or the owner-owned legacy mode 0755"
            )
        settings_descriptor = os.open(
            settings_name,
            os.O_RDONLY | no_follow,
            dir_fd=parent_descriptor,
        )
        settings_state = os.fstat(settings_descriptor)
        if not stat.S_ISREG(settings_state.st_mode):
            raise SettingsSecurityError("settings.json must be a regular file")
        if settings_state.st_uid != os.geteuid():
            raise SettingsSecurityError("settings.json must be owned by this user")
        if settings_state.st_nlink != 1:
            raise SettingsSecurityError("settings.json must have exactly one link")
        chunks = []
        payload_size = 0
        while True:
            chunk = os.read(
                settings_descriptor,
                min(65536, settings_max_bytes + 1 - payload_size),
            )
            if not chunk:
                break
            chunks.append(chunk)
            payload_size += len(chunk)
            if payload_size > settings_max_bytes:
                raise SettingsSecurityError(
                    "settings.json exceeds the "
                    f"{settings_max_bytes}-byte limit"
                )
        payload = b"".join(chunks)
        settings = json.loads(payload.decode("utf-8"))
        return (
            settings,
            parent_state,
            settings_state,
            hashlib.sha256(payload).hexdigest(),
        )
    except SettingsSecurityError:
        raise
    except (OSError, UnicodeError, json.JSONDecodeError) as error:
        raise SettingsSecurityError(
            f"settings.json parent or source could not be read safely: "
            f"{type(error).__name__}: {error}"
        ) from error
    finally:
        if settings_descriptor is not None:
            os.close(settings_descriptor)
        if parent_descriptor is not None:
            os.close(parent_descriptor)
        if home_descriptor is not None:
            os.close(home_descriptor)

try:
    s, parent_state, settings_state, settings_digest = read_settings_safely(
        settings_path
    )
except SettingsSecurityError as error:
    inspection_failure(str(error))
if not isinstance(s, dict):
    print("inspection failed: settings root must be a JSON object")
    sys.exit(2)
mp = s.get("extraKnownMarketplaces", {})
pl = s.get("enabledPlugins", {})
if not isinstance(mp, dict) or not isinstance(pl, dict):
    print("inspection failed: marketplace and plugin settings must be JSON objects")
    sys.exit(2)

def malformed_field(field, expected):
    print(f"inspection failed: {field} must be {expected}")
    sys.exit(2)

def get_source(name):
    if name not in mp:
        return {}
    e = mp[name]
    if not isinstance(e, dict):
        malformed_field(f"extraKnownMarketplaces.{name}", "a JSON object")
    if "source" not in e:
        return {}
    src = e["source"]
    if not isinstance(src, dict):
        malformed_field(
            f"extraKnownMarketplaces.{name}.source", "a JSON object"
        )
    return src

def get_url(name):
    src = get_source(name)
    if "url" not in src:
        return ""
    url = src["url"]
    if not isinstance(url, str):
        malformed_field(
            f"extraKnownMarketplaces.{name}.source.url", "a string"
        )
    return url

def get_source_kind(name):
    src = get_source(name)
    if "source" not in src:
        return ""
    source_kind = src["source"]
    if not isinstance(source_kind, str):
        malformed_field(
            f"extraKnownMarketplaces.{name}.source.source", "a string"
        )
    return source_kind

def norm(u):
    return u.rstrip("/").removesuffix(".git") if u else ""

actual_url = get_url(athena_marketplace_name)
actual_source_kind = get_source_kind(athena_marketplace_name)
url_ok = norm(actual_url) == norm(athena_marketplace_url)
source_kind_ok = actual_source_kind == "git"
a_ok = url_ok and source_kind_ok
p_a = pl.get(athena_plugin_key) is True
legacy = [k for k in legacy_plugin_keys_csv.split() if k in pl]
legacy_marketplaces = [k for k in legacy_marketplace_keys_csv.split() if k in mp]
legacy_parent_mode = stat.S_IMODE(parent_state.st_mode) == 0o755

if a_ok and p_a and not legacy and not legacy_marketplaces and not legacy_parent_mode:
    sys.exit(0)

print(
    "settings-binding-v1:"
    f"{parent_state.st_dev}:{parent_state.st_ino}:"
    f"{settings_state.st_dev}:{settings_state.st_ino}:{settings_digest}"
)

def fmt_marketplace(name, url_matches, actual, source_kind_matches, source_kind):
    if url_matches and source_kind_matches:
        return "marketplace " + name + ": present"
    problems = []
    if not source_kind_matches:
        problems.append(
            "wrong source kind (found: "
            + (source_kind or "not configured")
            + "; expected: git)"
        )
    if not url_matches:
        problems.append(
            "missing or wrong URL (found: " + (actual or "not configured") + ")"
        )
    return "marketplace " + name + ": " + "; ".join(problems)

out = []
out.append(
    fmt_marketplace(
        athena_marketplace_name,
        url_ok,
        actual_url,
        source_kind_ok,
        actual_source_kind,
    )
)
out.append("plugin " + athena_plugin_key + ": " + ("enabled" if p_a else "missing or disabled"))
if legacy:
    out.append("non-canonical plugin keys present (will be cleaned on --install): " + ", ".join(legacy))
if legacy_marketplaces:
    out.append("retired marketplaces present (will be cleaned on --install): " + ", ".join(legacy_marketplaces))
if legacy_parent_mode:
    out.append(
        "settings parent mode 0755 requires --install migration to 0700"
    )
print("\n".join(out))
sys.exit(1)
PYEOF
); then
        check_pass "settings.json — Athena marketplace and plugin configured"
    else
        _settings_diagnostic_status=$?
        if [[ "$_settings_diagnostic_status" -ne 1 ]]; then
            _settings_hard_failure=true
            check_fail "settings.json — inspection failed:
$DIAGNOSTICS"
        else
            _settings_binding="${DIAGNOSTICS%%$'\n'*}"
            if [[ "$DIAGNOSTICS" != *$'\n'* ]] || \
               [[ ! "$_settings_binding" =~ ^settings-binding-v1:[0-9]+:[0-9]+:[0-9]+:[0-9]+:[0-9a-f]{64}$ ]]; then
                _settings_hard_failure=true
                check_fail "settings.json — inspection returned an invalid source binding"
            else
                DIAGNOSTICS="${DIAGNOSTICS#*$'\n'}"
                if [[ "${INSTALL:-false}" == "true" ]]; then
                    _do_settings_merge=true
                    echo -e "    ${BLUE}→${NC} Reconciling the Athena marketplace and plugin"
                else
                    check_warn "settings.json — Athena marketplace+plugin gap detected:
$DIAGNOSTICS
tip: re-run with --install to apply the canonical fix; or manually edit ~/.claude/settings.json"
                fi
            fi
        fi
    fi
else
    if [[ "${INSTALL:-false}" == "true" ]]; then
        _do_settings_merge=true
        echo -e "    ${BLUE}→${NC} Creating the Athena marketplace and plugin settings"
    else
        check_warn "settings.json — not found (will create with --install)"
    fi
fi

if [[ "${_do_settings_merge:-false}" == "true" ]]; then
    if _trusted_python - \
        "$SETTINGS" \
        "$ATHENA_MARKETPLACE_NAME" \
        "$ATHENA_MARKETPLACE_URL" \
        "$ATHENA_PLUGIN_KEY" \
        "$LEGACY_PLUGIN_KEYS_CSV" \
        "$LEGACY_MARKETPLACE_KEYS_CSV" \
        "$_settings_binding" \
        "$SETTINGS_MAX_BYTES" \
        <<'PYEOF'
import ctypes
import errno
import hashlib
import json
import os
import secrets
import stat
import sys

(
    settings_path,
    athena_marketplace_name,
    athena_marketplace_url,
    athena_plugin_key,
    legacy_plugin_keys_csv,
    legacy_marketplace_keys_csv,
    expected_binding_text,
    settings_max_bytes_text,
) = sys.argv[1:]
settings_max_bytes = int(settings_max_bytes_text)

class SettingsReconciliationError(RuntimeError):
    pass

def norm(u):
    return u.rstrip("/").removesuffix(".git") if u else ""

def reconciliation_failure(field, expected):
    raise SettingsReconciliationError(f"{field} must be {expected}")

def parse_expected_binding(value):
    if value == "settings-binding-v1:absent":
        return None
    parts = value.split(":")
    if (
        len(parts) != 6
        or parts[0] != "settings-binding-v1"
        or any(not item.isascii() or not item.isdigit() for item in parts[1:5])
        or len(parts[5]) != 64
        or any(character not in "0123456789abcdef" for character in parts[5])
    ):
        raise SettingsReconciliationError(
            "settings.json source binding is malformed"
        )
    return tuple(int(item) for item in parts[1:5]) + (parts[5],)

def descriptor_flags():
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if (
        not no_follow
        or not directory
        or os.open not in getattr(os, "supports_dir_fd", set())
        or os.mkdir not in getattr(os, "supports_dir_fd", set())
    ):
        raise SettingsReconciliationError(
            "descriptor-relative O_NOFOLLOW settings storage is required"
        )
    return no_follow, directory

def rename_with_flags(
    source_directory, source_name, target_directory, target_name, operation
):
    library = ctypes.CDLL(None, use_errno=True)
    encoded_source = os.fsencode(source_name)
    encoded_target = os.fsencode(target_name)
    if sys.platform.startswith("linux"):
        renameat2 = getattr(library, "renameat2", None)
        if renameat2 is None:
            raise SettingsReconciliationError(
                "atomic settings publication is unavailable"
            )
        renameat2.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameat2.restype = ctypes.c_int
        flags = {"no-replace": 1, "exchange": 2}[operation]
        ctypes.set_errno(0)
        result = renameat2(
            source_directory,
            encoded_source,
            target_directory,
            encoded_target,
            flags,
        )
    elif sys.platform == "darwin":
        renameatx = getattr(library, "renameatx_np", None)
        if renameatx is None:
            raise SettingsReconciliationError(
                "atomic settings publication is unavailable"
            )
        renameatx.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        ]
        renameatx.restype = ctypes.c_int
        flags = {"no-replace": 4, "exchange": 2}[operation]
        ctypes.set_errno(0)
        result = renameatx(
            source_directory,
            encoded_source,
            target_directory,
            encoded_target,
            flags,
        )
    else:
        raise SettingsReconciliationError(
            "atomic settings publication is unavailable"
        )
    if result != 0:
        number = ctypes.get_errno() or errno.EIO
        raise OSError(number, os.strerror(number), target_name)

def named_state(directory_descriptor, name):
    return os.stat(name, dir_fd=directory_descriptor, follow_symlinks=False)

def same_object(first, second):
    return (first.st_dev, first.st_ino) == (second.st_dev, second.st_ino)

def optional_named_state(directory_descriptor, name):
    try:
        return named_state(directory_descriptor, name)
    except FileNotFoundError:
        return None

def publish_settings_atomically(
    home_descriptor,
    parent_descriptor,
    parent_name,
    parent_state,
    settings_name,
    output_name,
    source_state,
    source_payload,
    output_state,
    output_payload,
    output_mode,
):
    def verify_parent_and_sync():
        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )
        os.fsync(parent_descriptor)
        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )

    def rollback_absent(publication_error):
        try:
            current_target = optional_named_state(
                parent_descriptor, settings_name
            )
            if current_target is None or not same_object(
                current_target, output_state
            ):
                raise SettingsReconciliationError(
                    "settings publication could not bind rollback target"
                )
            current_output = optional_named_state(
                parent_descriptor, output_name
            )
            if current_output is None:
                rollback_name = output_name
            else:
                rollback_name = (
                    ".settings.json.rollback." + secrets.token_hex(16)
                )
            rename_with_flags(
                parent_descriptor,
                settings_name,
                parent_descriptor,
                rollback_name,
                "no-replace",
            )
            verify_named_payload(
                parent_descriptor,
                rollback_name,
                output_state,
                output_payload,
                output_mode,
            )
            if optional_named_state(parent_descriptor, settings_name) is not None:
                raise SettingsReconciliationError(
                    "settings publication rollback left a target"
                )
            verify_parent_and_sync()
            verify_named_payload(
                parent_descriptor,
                rollback_name,
                output_state,
                output_payload,
                output_mode,
            )
        except BaseException as rollback_error:
            raise SettingsReconciliationError(
                "settings publication failed and rollback was not exact"
            ) from rollback_error
        raise SettingsReconciliationError(
            "settings publication failed before durable completion"
        ) from publication_error

    if source_state is None:
        published = False
        try:
            rename_with_flags(
                parent_descriptor,
                output_name,
                parent_descriptor,
                settings_name,
                "no-replace",
            )
            published = True
            verify_named_payload(
                parent_descriptor,
                settings_name,
                output_state,
                output_payload,
                output_mode,
            )
            verify_parent_and_sync()
            verify_named_payload(
                parent_descriptor,
                settings_name,
                output_state,
                output_payload,
                output_mode,
            )
            return None
        except BaseException as publication_error:
            if not published:
                raise SettingsReconciliationError(
                    "settings publication failed before commit"
                ) from publication_error
            rollback_absent(publication_error)

    exchanged = False
    displaced_state = None
    quarantine_name = None
    try:
        current_source = named_state(parent_descriptor, settings_name)
        if not same_object(current_source, source_state):
            raise SettingsReconciliationError(
                "settings publication source changed before exchange"
            )
        rename_with_flags(
            parent_descriptor,
            output_name,
            parent_descriptor,
            settings_name,
            "exchange",
        )
        exchanged = True
        displaced_state = named_state(parent_descriptor, output_name)
        published_state = named_state(parent_descriptor, settings_name)
        if not same_object(published_state, output_state):
            raise SettingsReconciliationError(
                "settings publication target changed during exchange"
            )
        if not same_object(displaced_state, source_state):
            raise SettingsReconciliationError(
                "settings publication source changed during exchange"
            )
        verify_named_payload(
            parent_descriptor,
            settings_name,
            output_state,
            output_payload,
            output_mode,
        )
        verify_named_payload(
            parent_descriptor,
            output_name,
            source_state,
            source_payload,
            stat.S_IMODE(source_state.st_mode),
        )
        quarantine_name = "settings.json.replaced." + secrets.token_hex(16)
        rename_with_flags(
            parent_descriptor,
            output_name,
            parent_descriptor,
            quarantine_name,
            "no-replace",
        )
        verify_named_payload(
            parent_descriptor,
            quarantine_name,
            source_state,
            source_payload,
            stat.S_IMODE(source_state.st_mode),
        )
        verify_named_payload(
            parent_descriptor,
            settings_name,
            output_state,
            output_payload,
            output_mode,
        )
        verify_parent_and_sync()
        verify_named_payload(
            parent_descriptor,
            quarantine_name,
            source_state,
            source_payload,
            stat.S_IMODE(source_state.st_mode),
        )
        verify_named_payload(
            parent_descriptor,
            settings_name,
            output_state,
            output_payload,
            output_mode,
        )
        return quarantine_name
    except BaseException as publication_error:
        if not exchanged:
            raise SettingsReconciliationError(
                "settings publication failed before exchange"
            ) from publication_error
        try:
            current_target = optional_named_state(
                parent_descriptor, settings_name
            )
            if current_target is None or not same_object(
                current_target, output_state
            ):
                raise SettingsReconciliationError(
                    "settings publication could not bind rollback target"
                )
            rollback_name = None
            rollback_state = None
            current_output = optional_named_state(
                parent_descriptor, output_name
            )
            if current_output is not None and same_object(
                current_output, source_state
            ):
                rollback_name = output_name
                rollback_state = source_state
            elif quarantine_name is not None:
                current_quarantine = optional_named_state(
                    parent_descriptor, quarantine_name
                )
                if current_quarantine is not None and same_object(
                    current_quarantine, source_state
                ):
                    rollback_name = quarantine_name
                    rollback_state = source_state
            if rollback_name is None:
                raise SettingsReconciliationError(
                    "settings publication could not bind displaced source"
                )
            rename_with_flags(
                parent_descriptor,
                settings_name,
                parent_descriptor,
                rollback_name,
                "exchange",
            )
            restored_state = named_state(parent_descriptor, settings_name)
            if rollback_state is None or not same_object(
                restored_state, rollback_state
            ):
                raise SettingsReconciliationError(
                    "settings publication rollback changed displaced identity"
                )
            verify_named_payload(
                parent_descriptor,
                settings_name,
                source_state,
                source_payload,
                stat.S_IMODE(source_state.st_mode),
            )
            verify_named_payload(
                parent_descriptor,
                rollback_name,
                output_state,
                output_payload,
                output_mode,
            )
            verify_parent_and_sync()
            restored_state = named_state(parent_descriptor, settings_name)
            if rollback_state is None or not same_object(
                restored_state, rollback_state
            ):
                raise SettingsReconciliationError(
                    "settings publication rollback changed displaced identity"
                )
            verify_named_payload(
                parent_descriptor,
                settings_name,
                source_state,
                source_payload,
                stat.S_IMODE(source_state.st_mode),
            )
            verify_named_payload(
                parent_descriptor,
                rollback_name,
                output_state,
                output_payload,
                output_mode,
            )
        except BaseException as rollback_error:
            raise SettingsReconciliationError(
                "settings publication failed and rollback was not exact"
            ) from rollback_error
        raise SettingsReconciliationError(
            "settings publication failed before durable completion"
        ) from publication_error

def settings_components(path):
    settings_directory = os.path.dirname(path)
    home_directory = os.path.dirname(settings_directory)
    parent_name = os.path.basename(settings_directory)
    settings_name = os.path.basename(path)
    if (
        not os.path.isabs(path)
        or not home_directory
        or parent_name != ".claude"
        or settings_name != "settings.json"
    ):
        raise SettingsReconciliationError("settings.json path is not canonical")
    return home_directory, parent_name, settings_name

def validate_parent(state, allow_legacy=False):
    mode = stat.S_IMODE(state.st_mode)
    if (
        not stat.S_ISDIR(state.st_mode)
        or state.st_uid != os.geteuid()
        or (mode != 0o700 and not (allow_legacy and mode == 0o755))
    ):
        raise SettingsReconciliationError(
            "settings.json parent must be an owner-private direct directory"
        )

def migrate_legacy_parent(
    home_descriptor, parent_descriptor, parent_name, parent_state
):
    mode = stat.S_IMODE(parent_state.st_mode)
    if mode == 0o700:
        return parent_state, False
    validate_parent(parent_state, allow_legacy=True)
    if mode != 0o755:
        raise SettingsReconciliationError(
            "settings.json parent is not the supported legacy mode 0755"
        )
    os.fchmod(parent_descriptor, 0o700)
    os.fsync(parent_descriptor)
    migrated_state = os.fstat(parent_descriptor)
    validate_parent(migrated_state)
    if (migrated_state.st_dev, migrated_state.st_ino) != (
        parent_state.st_dev,
        parent_state.st_ino,
    ):
        raise SettingsReconciliationError(
            "settings.json parent changed during mode migration"
        )

    no_follow, directory = descriptor_flags()
    rebound_descriptor = None
    try:
        rebound_descriptor = os.open(
            parent_name,
            os.O_RDONLY | directory | no_follow,
            dir_fd=home_descriptor,
        )
        rebound_state = os.fstat(rebound_descriptor)
        validate_parent(rebound_state)
        if (rebound_state.st_dev, rebound_state.st_ino) != (
            migrated_state.st_dev,
            migrated_state.st_ino,
        ):
            raise SettingsReconciliationError(
                "settings.json parent changed during mode migration"
            )
    except SettingsReconciliationError:
        raise
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json parent changed during mode migration"
        ) from error
    finally:
        if rebound_descriptor is not None:
            os.close(rebound_descriptor)
    return migrated_state, True

def open_parent(path):
    no_follow, directory = descriptor_flags()
    home_directory, parent_name, settings_name = settings_components(path)
    home_descriptor = None
    parent_descriptor = None
    try:
        home_descriptor = os.open(
            home_directory, os.O_RDONLY | directory | no_follow
        )
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json home could not be opened safely"
        ) from error
    try:
        try:
            os.mkdir(parent_name, mode=0o700, dir_fd=home_descriptor)
            os.fsync(home_descriptor)
        except FileExistsError:
            pass
        try:
            parent_descriptor = os.open(
                parent_name,
                os.O_RDONLY | directory | no_follow,
                dir_fd=home_descriptor,
            )
        except OSError as error:
            raise SettingsReconciliationError(
                "settings.json parent could not be opened safely"
            ) from error
        parent_state, parent_migrated = migrate_legacy_parent(
            home_descriptor,
            parent_descriptor,
            parent_name,
            os.fstat(parent_descriptor),
        )
        return (
            home_descriptor,
            parent_descriptor,
            parent_name,
            settings_name,
            parent_state,
            parent_migrated,
        )
    except BaseException:
        if parent_descriptor is not None:
            os.close(parent_descriptor)
        os.close(home_descriptor)
        raise

def read_all(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    payload_size = 0
    while True:
        chunk = os.read(
            descriptor,
            min(65536, settings_max_bytes + 1 - payload_size),
        )
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        payload_size += len(chunk)
        if payload_size > settings_max_bytes:
            raise SettingsReconciliationError(
                "settings.json exceeds the "
                f"{settings_max_bytes}-byte limit"
            )

def write_all(descriptor, payload):
    offset = 0
    while offset < len(payload):
        written = os.write(descriptor, payload[offset:])
        if written <= 0:
            raise SettingsReconciliationError("settings write made no progress")
        offset += written

def serialize_settings(value):
    chunks = []
    payload_size = 1  # Account for the final newline.
    encoder = json.JSONEncoder(indent=2, ensure_ascii=True)
    for fragment in encoder.iterencode(value):
        chunk = fragment.encode("utf-8")
        payload_size += len(chunk)
        if payload_size > settings_max_bytes:
            raise SettingsReconciliationError(
                "reconciled settings exceed the "
                f"{settings_max_bytes}-byte limit"
            )
        chunks.append(chunk)
    chunks.append(b"\n")
    return b"".join(chunks)

def validate_source(state):
    if not stat.S_ISREG(state.st_mode):
        raise SettingsReconciliationError("settings.json must be a regular file")
    if state.st_uid != os.geteuid():
        raise SettingsReconciliationError("settings.json must be owned by this user")
    if state.st_nlink != 1:
        raise SettingsReconciliationError(
            "settings.json must have exactly one link"
        )

def open_source(parent_descriptor, settings_name, required):
    no_follow, _ = descriptor_flags()
    try:
        descriptor = os.open(
            settings_name,
            os.O_RDONLY | no_follow,
            dir_fd=parent_descriptor,
        )
    except FileNotFoundError:
        if required:
            raise SettingsReconciliationError(
                "settings.json disappeared during reconciliation"
            )
        return None, None, None
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json could not be opened without following links"
        ) from error
    try:
        state = os.fstat(descriptor)
        validate_source(state)
        return descriptor, state, read_all(descriptor)
    except BaseException:
        os.close(descriptor)
        raise

def verify_parent_binding(
    home_descriptor, parent_descriptor, parent_name, expected_state
):
    no_follow, directory = descriptor_flags()
    current_descriptor = None
    try:
        current_descriptor = os.open(
            parent_name,
            os.O_RDONLY | directory | no_follow,
            dir_fd=home_descriptor,
        )
        current_state = os.fstat(current_descriptor)
        validate_parent(current_state)
        if (current_state.st_dev, current_state.st_ino) != (
            expected_state.st_dev,
            expected_state.st_ino,
        ):
            raise SettingsReconciliationError(
                "settings.json parent changed during reconciliation"
            )
    except SettingsReconciliationError:
        raise
    except OSError as error:
        raise SettingsReconciliationError(
            "settings.json parent changed during reconciliation"
        ) from error
    finally:
        if current_descriptor is not None:
            os.close(current_descriptor)

def verify_source_binding(
    parent_descriptor, settings_name, source_state, source_payload
):
    descriptor, current_state, current_payload = open_source(
        parent_descriptor, settings_name, source_state is not None
    )
    try:
        if source_state is None:
            if descriptor is not None:
                raise SettingsReconciliationError(
                    "settings.json appeared during reconciliation"
                )
            return
        if descriptor is None or current_state is None:
            raise SettingsReconciliationError(
                "settings.json disappeared during reconciliation"
            )
        validate_source(current_state)
        if (
            (current_state.st_dev, current_state.st_ino)
            != (source_state.st_dev, source_state.st_ino)
            or current_payload != source_payload
        ):
            raise SettingsReconciliationError(
                "settings.json changed during reconciliation"
            )
    finally:
        if descriptor is not None:
            os.close(descriptor)

def create_exclusive_file(parent_descriptor, prefix, mode):
    no_follow, _ = descriptor_flags()
    for _ in range(128):
        name = prefix + secrets.token_hex(16)
        try:
            descriptor = os.open(
                name,
                os.O_RDWR | os.O_CREAT | os.O_EXCL | no_follow,
                mode,
                dir_fd=parent_descriptor,
            )
            return name, descriptor
        except FileExistsError:
            continue
    raise SettingsReconciliationError(
        "could not allocate an exclusive settings artifact"
    )

def verify_named_payload(
    parent_descriptor, name, expected_state, expected_payload, expected_mode
):
    no_follow, _ = descriptor_flags()
    descriptor = None
    try:
        descriptor = os.open(
            name, os.O_RDONLY | no_follow, dir_fd=parent_descriptor
        )
        state = os.fstat(descriptor)
        if (
            not stat.S_ISREG(state.st_mode)
            or state.st_uid != os.geteuid()
            or state.st_nlink != 1
            or stat.S_IMODE(state.st_mode) != expected_mode
            or (state.st_dev, state.st_ino)
            != (expected_state.st_dev, expected_state.st_ino)
            or read_all(descriptor) != expected_payload
        ):
            raise SettingsReconciliationError(
                "published settings artifact did not match its bound content"
            )
    except SettingsReconciliationError:
        raise
    except OSError as error:
        raise SettingsReconciliationError(
            "published settings artifact could not be read safely"
        ) from error
    finally:
        if descriptor is not None:
            os.close(descriptor)

def reconcile():
    expected_binding = parse_expected_binding(expected_binding_text)
    (
        home_descriptor,
        parent_descriptor,
        parent_name,
        settings_name,
        parent_state,
        parent_migrated,
    ) = open_parent(settings_path)
    source_descriptor = None
    backup_descriptor = None
    output_descriptor = None
    try:
        source_descriptor, source_state, source_payload = open_source(
            parent_descriptor, settings_name, required=False
        )
        if expected_binding is None:
            if source_state is not None:
                raise SettingsReconciliationError(
                    "settings.json appeared after the inspected state"
                )
        elif source_state is None or source_payload is None:
            raise SettingsReconciliationError(
                "settings.json disappeared after inspection"
            )
        else:
            actual_binding = (
                parent_state.st_dev,
                parent_state.st_ino,
                source_state.st_dev,
                source_state.st_ino,
                hashlib.sha256(source_payload).hexdigest(),
            )
            if actual_binding != expected_binding:
                raise SettingsReconciliationError(
                    "settings.json parent or source changed after inspection"
                )
        output_mode = (
            stat.S_IMODE(source_state.st_mode)
            if source_state is not None
            else 0o600
        )
        if source_payload is None:
            s = {}
        else:
            try:
                s = json.loads(source_payload.decode("utf-8"))
            except (UnicodeError, json.JSONDecodeError) as error:
                raise SettingsReconciliationError(
                    f"{type(error).__name__}: {error}"
                ) from error

        if not isinstance(s, dict):
            reconciliation_failure("settings root", "a JSON object")
        mp = s.get("extraKnownMarketplaces", {})
        plugins = s.get("enabledPlugins", {})
        if not isinstance(mp, dict):
            reconciliation_failure("extraKnownMarketplaces", "a JSON object")
        if not isinstance(plugins, dict):
            reconciliation_failure("enabledPlugins", "a JSON object")
        s["extraKnownMarketplaces"] = mp
        s["enabledPlugins"] = plugins

        if athena_marketplace_name in mp:
            existing_a = mp[athena_marketplace_name]
            if not isinstance(existing_a, dict):
                reconciliation_failure(
                    f"extraKnownMarketplaces.{athena_marketplace_name}",
                    "a JSON object",
                )
            if "source" in existing_a:
                source = existing_a["source"]
                if not isinstance(source, dict):
                    reconciliation_failure(
                        f"extraKnownMarketplaces.{athena_marketplace_name}.source",
                        "a JSON object",
                    )
                if "url" in source and not isinstance(source["url"], str):
                    reconciliation_failure(
                        f"extraKnownMarketplaces.{athena_marketplace_name}.source.url",
                        "a string",
                    )
                if "source" in source and not isinstance(
                    source["source"], str
                ):
                    reconciliation_failure(
                        f"extraKnownMarketplaces.{athena_marketplace_name}.source.source",
                        "a string",
                    )

        existing_a = mp.get(athena_marketplace_name)
        a_shape_match = (
            isinstance(existing_a, dict)
            and isinstance(existing_a.get("source"), dict)
            and existing_a["source"].get("source") == "git"
            and norm(existing_a["source"].get("url"))
            == norm(athena_marketplace_url)
        )
        if not a_shape_match:
            mp[athena_marketplace_name] = {
                "source": {
                    "source": "git",
                    "url": athena_marketplace_url,
                }
            }
        plugins[athena_plugin_key] = True

        purged_entries = 0
        for legacy_key in legacy_plugin_keys_csv.split():
            if plugins.pop(legacy_key, None) is not None:
                purged_entries += 1
        for legacy_key in legacy_marketplace_keys_csv.split():
            if mp.pop(legacy_key, None) is not None:
                purged_entries += 1

        output_payload = serialize_settings(s)
        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )
        verify_source_binding(
            parent_descriptor, settings_name, source_state, source_payload
        )

        if source_payload == output_payload:
            return purged_entries, False, parent_migrated

        if source_state is not None:
            backup_name, backup_descriptor = create_exclusive_file(
                parent_descriptor, "settings.json.bak.", output_mode
            )
            write_all(backup_descriptor, source_payload)
            os.fchmod(backup_descriptor, output_mode)
            os.fsync(backup_descriptor)
            backup_state = os.fstat(backup_descriptor)
            verify_named_payload(
                parent_descriptor,
                backup_name,
                backup_state,
                source_payload,
                output_mode,
            )
            os.fsync(parent_descriptor)

        output_name, output_descriptor = create_exclusive_file(
            parent_descriptor, ".settings.json.", 0o600
        )
        write_all(output_descriptor, output_payload)
        os.fchmod(output_descriptor, output_mode)
        os.fsync(output_descriptor)
        output_state = os.fstat(output_descriptor)

        verify_parent_binding(
            home_descriptor, parent_descriptor, parent_name, parent_state
        )
        verify_source_binding(
            parent_descriptor, settings_name, source_state, source_payload
        )
        publish_settings_atomically(
            home_descriptor,
            parent_descriptor,
            parent_name,
            parent_state,
            settings_name,
            output_name,
            source_state,
            source_payload,
            output_state,
            output_payload,
            output_mode,
        )
        return purged_entries, True, parent_migrated
    finally:
        # If publication fails after the output file is created, retain its
        # directory entry. The name can change after the last identity check.
        # Unlinking that mutable name here could delete an unrelated entry.
        # The file stays owner-private and provides failure evidence.
        if output_descriptor is not None:
            os.close(output_descriptor)
        if backup_descriptor is not None:
            os.close(backup_descriptor)
        if source_descriptor is not None:
            os.close(source_descriptor)
        os.close(parent_descriptor)
        os.close(home_descriptor)

try:
    purged_entries, settings_changed, parent_migrated = reconcile()
except (OSError, SettingsReconciliationError) as error:
    print(f"settings.json reconciliation failed: {error}", file=sys.stderr)
    sys.exit(2)

if parent_migrated:
    print("    settings parent migrated from mode 0755 to 0700")
if purged_entries:
    print(
        "    settings.json updated — Athena marketplace and plugin reconciled "
        f"({purged_entries} retired entries removed)"
    )
elif settings_changed:
    print("    settings.json updated — Athena marketplace and plugin reconciled")
PYEOF
    then
        # Python's print above carries the per-action detail, including the
        # retired-entry count when applicable.
        check_pass "settings.json — Athena marketplace and plugin reconciled"
    else
        _settings_hard_failure=true
        check_fail "settings.json — Athena marketplace and plugin reconciliation failed"
    fi
fi

# ─── Step 3: Mnemosyne agent brain seed ──────────────────────────────────────
MNEMOSYNE_PARENT="$HOME/.agent_brain"
MNEMOSYNE_DIR="$HOME/.agent_brain/knowledge"
MNEMOSYNE_URL="https://github.com/HomericIntelligence/Mnemosyne.git"

_mnemosyne_directories_are_safe() {
    if [[ -L "$MNEMOSYNE_PARENT" ]] || \
       [[ -e "$MNEMOSYNE_PARENT" && ! -d "$MNEMOSYNE_PARENT" ]]; then
        _mnemosyne_error="Mnemosyne parent must be a direct directory: $MNEMOSYNE_PARENT"
        return 1
    fi
    if [[ -L "$MNEMOSYNE_DIR" ]] || \
       [[ -e "$MNEMOSYNE_DIR" && ! -d "$MNEMOSYNE_DIR" ]]; then
        _mnemosyne_error="Mnemosyne checkout must be a direct directory: $MNEMOSYNE_DIR"
        return 1
    fi
    return 0
}

_mnemosyne_git() (
    # Repository routing and config injection are ambient process state, not
    # authority to select a different checkout or rewrite the approved URL.
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_NAMESPACE GIT_TEMPLATE_DIR \
        GIT_PREFIX GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
        GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND \
        GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_SSL_NO_VERIFY \
        GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_ATTR_SOURCE GIT_REPLACE_REF_BASE \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy no_proxy \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE \
        AWS_CA_BUNDLE NODE_EXTRA_CA_CERTS SSLKEYLOGFILE \
        GIT_CURL_VERBOSE GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA \
        GIT_HTTP_PROXY_AUTHMETHOD GIT_HTTP_LOW_SPEED_LIMIT \
        GIT_HTTP_LOW_SPEED_TIME GIT_HTTP_MAX_REQUESTS GIT_HTTP_USER_AGENT \
        GIT_SSL_CIPHER GIT_SSL_VERSION GIT_SSL_BACKEND \
        || return 80
    # GIT_CONFIG selects the input for `git config`; other Git commands still
    # read repository config. Direct validation below therefore names the
    # bound config explicitly, while pull effects also receive command-scope
    # overrides for selected execution-capable settings.
    export GIT_CONFIG=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_COUNT=0
    export GIT_ATTR_NOSYSTEM=1
    export GIT_TERMINAL_PROMPT=0
    _trusted_python_exec - \
        "$_ODYSSEUS_BOUND_GIT" \
        "$_ODYSSEUS_BOUND_GIT_IDENTITY" \
        "$_ODYSSEUS_BOUND_GIT_INTERPRETER" \
        "$_ODYSSEUS_BOUND_GIT_INTERPRETER_IDENTITY" \
        "$MNEMOSYNE_GIT_TIMEOUT_SECONDS" \
        "$MNEMOSYNE_GIT_MAX_BYTES" \
        "$MNEMOSYNE_GIT_EXECUTABLE_MAX_BYTES" \
        -c core.attributesFile=/dev/null \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        -c credential.helper= \
        -c credential.interactive=false \
        -c protocol.allow=never \
        -c protocol.https.allow=always \
        -c protocol.file.allow=never \
        -c http.sslVerify=true \
        -c "http.$MNEMOSYNE_URL.sslVerify=true" \
        -c http.sslCAInfo= \
        -c http.sslCAPath= \
        -c http.proxy= \
        -c "http.$MNEMOSYNE_URL.proxy=" \
        -c http.curloptResolve= "$@" <<'PYEOF'
import ctypes
import fcntl
import os
import select
import selectors
import signal
import stat
import subprocess
import sys
import time


class GitSupervisorError(RuntimeError):
    pass


git_path = sys.argv[1]
expected_identity = tuple(int(value) for value in sys.argv[2].split(":"))
interpreter_path = sys.argv[3]
interpreter_identity_text = sys.argv[4]
expected_interpreter_identity = (
    None
    if interpreter_identity_text == "-"
    else tuple(int(value) for value in interpreter_identity_text.split(":"))
)
timeout_seconds = int(sys.argv[5])
maximum_output_bytes = int(sys.argv[6])
maximum_executable_bytes = int(sys.argv[7])
arguments = sys.argv[8:]
deadline = time.monotonic() + timeout_seconds
quiescent_scans = 3
interrupted = None


def catch_signal(number, _frame):
    global interrupted
    interrupted = number


def file_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def linux_process_identity(process_id):
    try:
        with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
            content = stream.read(65537)
    except (FileNotFoundError, ProcessLookupError):
        return None
    if len(content) > 65536:
        raise GitSupervisorError("Git process identity exceeds its byte bound")
    closing = content.rfind(b")")
    fields = content[closing + 2 :].split() if closing >= 1 else ()
    if len(fields) <= 19:
        raise GitSupervisorError("Git process identity is malformed")
    return process_id, int(fields[19])


def linux_child_pids(process_id):
    task_root = f"/proc/{process_id}/task"
    try:
        tasks = tuple(
            entry.name for entry in os.scandir(task_root) if entry.name.isdecimal()
        )
    except (FileNotFoundError, ProcessLookupError):
        return set()
    children = set()
    for task in tasks:
        try:
            with open(
                f"{task_root}/{task}/children", "rb", buffering=0
            ) as stream:
                content = stream.read(1048577)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if len(content) > 1048576:
            raise GitSupervisorError("Git child inventory exceeds its byte bound")
        for value in content.split():
            if not value.isdigit():
                raise GitSupervisorError("Git child inventory is malformed")
            child = int(value)
            if child > 1:
                children.add(child)
    return children


class LinuxProcessScope:
    def __init__(self):
        if not hasattr(os, "pidfd_open") or not hasattr(
            signal, "pidfd_send_signal"
        ):
            raise GitSupervisorError("Linux pidfd containment is unavailable")
        library = ctypes.CDLL(None, use_errno=True)
        operation = getattr(library, "prctl", None)
        if operation is None:
            raise GitSupervisorError("Linux subreaper containment is unavailable")
        operation.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        operation.restype = ctypes.c_int
        if operation(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
            number = ctypes.get_errno() or 1
            raise GitSupervisorError(
                f"Linux subreaper containment failed with errno {number}"
            )
        self.supervisor = os.getpid()
        self.baseline = {
            identity
            for process_id in linux_child_pids(self.supervisor)
            if (identity := linux_process_identity(process_id)) is not None
        }
        self.processes = {}
        self.root = None

    def track(self, process_id, root=False):
        identity = linux_process_identity(process_id)
        if identity is None or (not root and identity in self.baseline):
            return False
        previous = self.processes.get(process_id)
        if previous is not None and previous[0] == identity[1]:
            return False
        if previous is not None:
            os.close(previous[1])
        descriptor = os.pidfd_open(process_id, 0)
        if linux_process_identity(process_id) != identity:
            os.close(descriptor)
            raise GitSupervisorError("Git process identity changed during binding")
        self.processes[process_id] = (identity[1], descriptor)
        return True

    def track_root(self, process_id):
        if not self.track(process_id, root=True):
            raise GitSupervisorError("could not bind the Git process")
        self.root = process_id

    def discover(self):
        discovered = False
        while True:
            candidates = set(linux_child_pids(self.supervisor))
            for process_id, (start_time, _descriptor) in tuple(
                self.processes.items()
            ):
                if linux_process_identity(process_id) == (
                    process_id,
                    start_time,
                ):
                    candidates.update(linux_child_pids(process_id))
            changed = False
            for process_id in candidates:
                changed = self.track(process_id) or changed
            discovered = discovered or changed
            if not changed:
                return discovered

    @staticmethod
    def exited(descriptor):
        readable, _writable, _exceptional = select.select(
            [descriptor], [], [], 0
        )
        return bool(readable)

    def live_snapshot(self):
        active = []
        for process_id, (_start_time, descriptor) in self.processes.items():
            try:
                if self.exited(descriptor):
                    continue
            except OSError:
                pass
            try:
                signal.pidfd_send_signal(descriptor, 0, None, 0)
            except ProcessLookupError:
                continue
            active.append((process_id, descriptor))
        return tuple(active)

    def live(self):
        self.discover()
        active = self.live_snapshot()
        if active:
            return active
        unchanged = 0
        while unchanged < quiescent_scans:
            changed = self.discover()
            active = self.live_snapshot()
            if active:
                return active
            unchanged = 0 if changed else unchanged + 1
        return ()

    def descendants(self):
        return tuple(item for item in self.live() if item[0] != self.root)

    def reap(self):
        for process_id in tuple(self.processes):
            if process_id == self.root:
                continue
            try:
                os.waitpid(process_id, os.WNOHANG)
            except (ChildProcessError, ProcessLookupError):
                pass

    def terminate(self, process):
        cleanup_error = None
        for number, grace in (
            (signal.SIGTERM, 0.2),
            (signal.SIGKILL, 1.0),
        ):
            signal_deadline = time.monotonic() + grace
            while True:
                try:
                    active = self.live()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
                    active = self.live_snapshot()
                if any(process_id == process.pid for process_id, _fd in active):
                    try:
                        os.killpg(process.pid, number)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        cleanup_error = cleanup_error or error
                if not active:
                    self.reap()
                    if cleanup_error is not None:
                        raise GitSupervisorError(
                            "Git containment inventory failed during cleanup"
                        ) from cleanup_error
                    return
                for _process_id, descriptor in active:
                    try:
                        signal.pidfd_send_signal(descriptor, number, None, 0)
                    except ProcessLookupError:
                        pass
                    except OSError as error:
                        cleanup_error = cleanup_error or error
                if time.monotonic() >= signal_deadline:
                    break
                time.sleep(0.01)
        try:
            active = self.live()
        except BaseException as error:
            cleanup_error = cleanup_error or error
            active = self.live_snapshot()
        if active:
            raise GitSupervisorError("Git descendants survived cleanup")
        self.reap()
        if cleanup_error is not None:
            raise GitSupervisorError(
                "Git containment inventory failed during cleanup"
            ) from cleanup_error

    def close(self):
        for _start_time, descriptor in self.processes.values():
            os.close(descriptor)
        self.processes.clear()


def make_environment():
    return {
        "GIT_ATTR_NOSYSTEM": "1",
        "GIT_CONFIG": "/dev/null",
        "GIT_CONFIG_COUNT": "0",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "XDG_CACHE_HOME": "/nonexistent",
        "XDG_CONFIG_HOME": "/nonexistent",
        "XDG_DATA_HOME": "/nonexistent",
        "XDG_STATE_HOME": "/nonexistent",
    }


source_descriptor = -1
interpreter_source_descriptor = -1
sealed_descriptor = -1
sealed_interpreter_descriptor = -1
process = None
scope = None
selector = None
stdout = bytearray()
stderr = bytearray()
failure = None
result = 125
previous_handlers = {}


def open_bound_executable(path, expected, label):
    descriptor = os.open(
        path,
        os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0) | getattr(os, "O_CLOEXEC", 0),
    )
    try:
        opened = os.fstat(descriptor)
        named = os.stat(path, follow_symlinks=False)
        if file_identity(opened) != expected or file_identity(named) != expected:
            raise GitSupervisorError(f"bound {label} identity changed")
        if opened.st_size <= 0 or opened.st_size > maximum_executable_bytes:
            raise GitSupervisorError(f"bound {label} size is outside its limit")
        return descriptor, opened
    except BaseException:
        os.close(descriptor)
        raise


def seal_executable(source, source_state, expected, label):
    creator = getattr(os, "memfd_create", None)
    allow_sealing = getattr(os, "MFD_ALLOW_SEALING", None)
    if creator is None or allow_sealing is None:
        raise GitSupervisorError("sealed executable support is unavailable")
    sealed = creator(f"odysseus-{label}", allow_sealing)
    try:
        os.lseek(source, 0, os.SEEK_SET)
        copied = 0
        while True:
            chunk = os.read(
                source,
                min(65536, maximum_executable_bytes + 1 - copied),
            )
            if not chunk:
                break
            copied += len(chunk)
            if copied > maximum_executable_bytes:
                raise GitSupervisorError(f"{label} exceeded its byte limit")
            offset = 0
            while offset < len(chunk):
                written = os.write(sealed, chunk[offset:])
                if written <= 0:
                    raise GitSupervisorError(
                        f"{label} sealed copy made no progress"
                    )
                offset += written
        if copied != source_state.st_size:
            raise GitSupervisorError(f"{label} changed while it was copied")
        if file_identity(os.fstat(source)) != expected:
            raise GitSupervisorError(f"{label} changed during sealed copy")
        os.fchmod(sealed, 0o500)
        required_seals = (
            fcntl.F_SEAL_WRITE
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_SEAL
        )
        fcntl.fcntl(sealed, fcntl.F_ADD_SEALS, required_seals)
        if (
            fcntl.fcntl(sealed, fcntl.F_GET_SEALS) & required_seals
            != required_seals
        ):
            raise GitSupervisorError(f"{label} could not be sealed")
        return sealed
    except BaseException:
        os.close(sealed)
        raise

try:
    for number in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
        previous_handlers[number] = signal.getsignal(number)
        signal.signal(number, catch_signal)
    if (
        len(expected_identity) != 8
        or (
            expected_interpreter_identity is not None
            and len(expected_interpreter_identity) != 8
        )
        or timeout_seconds <= 0
        or maximum_output_bytes <= 0
        or maximum_executable_bytes <= 0
    ):
        raise GitSupervisorError("Git supervisor bounds are invalid")
    if (interpreter_path == "-") != (expected_interpreter_identity is None):
        raise GitSupervisorError("Git interpreter binding is inconsistent")
    source_descriptor, source_state = open_bound_executable(
        git_path, expected_identity, "Git executable"
    )

    pass_descriptors = ()
    executable = git_path
    command = [executable, *arguments]
    if sys.platform.startswith("linux"):
        sealed_descriptor = seal_executable(
            source_descriptor, source_state, expected_identity, "mnemosyne-git"
        )
        executable = f"/proc/self/fd/{sealed_descriptor}"
        command = [executable, *arguments]
        pass_descriptors = [sealed_descriptor]
        if expected_interpreter_identity is not None:
            interpreter_source_descriptor, interpreter_source_state = (
                open_bound_executable(
                    interpreter_path,
                    expected_interpreter_identity,
                    "Git shebang interpreter",
                )
            )
            sealed_interpreter_descriptor = seal_executable(
                interpreter_source_descriptor,
                interpreter_source_state,
                expected_interpreter_identity,
                "mnemosyne-git-interpreter",
            )
            sealed_interpreter = (
                f"/proc/self/fd/{sealed_interpreter_descriptor}"
            )
            command = [sealed_interpreter, executable, *arguments]
            pass_descriptors.append(sealed_interpreter_descriptor)
        pass_descriptors = tuple(pass_descriptors)
        scope = LinuxProcessScope()
    elif sys.platform == "darwin":
        # Darwin has no pidfd/subreaper equivalent here that can bind and
        # extinguish a credential helper after it detaches with setsid(2).
        # Fail before Popen rather than claiming process-group cleanup proves
        # full descendant extinction.
        raise GitSupervisorError(
            "exact Git process containment is unavailable on Darwin"
        )
    else:
        raise GitSupervisorError("Git process containment is unavailable")

    if interrupted is not None:
        raise GitSupervisorError("Git command was interrupted")
    process = subprocess.Popen(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
        close_fds=True,
        pass_fds=pass_descriptors,
        env=make_environment(),
    )
    scope.track_root(process.pid)
    selector = selectors.DefaultSelector()
    for stream, channel in ((process.stdout, "stdout"), (process.stderr, "stderr")):
        os.set_blocking(stream.fileno(), False)
        selector.register(stream, selectors.EVENT_READ, channel)

    while selector.get_map() or process.poll() is None:
        if interrupted is not None:
            failure = "Git command was interrupted"
            break
        if time.monotonic() >= deadline:
            failure = "Git command timed out"
            break
        for key, _mask in selector.select(
            min(0.05, max(0.0, deadline - time.monotonic()))
        ):
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                selector.unregister(key.fileobj)
                continue
            target = stdout if key.data == "stdout" else stderr
            target.extend(chunk)
            if len(stdout) + len(stderr) > maximum_output_bytes:
                failure = "Git command output exceeded its byte limit"
                break
        if failure is not None:
            break

    if failure is not None:
        scope.terminate(process)
        try:
            process.wait(timeout=1.0)
        except subprocess.TimeoutExpired:
            failure = "Git root process survived cleanup"
        result = 125
    else:
        result = process.wait(timeout=max(0.1, deadline - time.monotonic()))
        settle_deadline = min(deadline, time.monotonic() + 0.05)
        while time.monotonic() < settle_deadline:
            if not scope.descendants():
                time.sleep(0.005)
                continue
            break
        if scope.descendants():
            scope.terminate(process)
            failure = "Git command left a live descendant"
            result = 125
except BaseException as error:
    failure = str(error) or error.__class__.__name__
    result = 125
finally:
    if process is not None:
        try:
            if scope is None:
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                    process.wait(timeout=1)
            else:
                scope.terminate(process)
        except BaseException as error:
            failure = failure or (str(error) or error.__class__.__name__)
            result = 125
    if selector is not None:
        selector.close()
    if scope is not None:
        scope.close()
    for descriptor in (
        sealed_interpreter_descriptor,
        sealed_descriptor,
        interpreter_source_descriptor,
        source_descriptor,
    ):
        if descriptor >= 0:
            os.close(descriptor)
    for number, previous in previous_handlers.items():
        signal.signal(number, previous)

if len(stdout) <= maximum_output_bytes:
    os.write(1, stdout)
if len(stderr) <= maximum_output_bytes:
    os.write(2, stderr)
if failure is not None:
    os.write(2, f"Mnemosyne Git supervision failed: {failure}\n".encode())
if interrupted is not None:
    signal.signal(interrupted, signal.SIG_DFL)
    os.kill(os.getpid(), interrupted)
raise SystemExit(result)
PYEOF
)

_mnemosyne_bound_git() {
    # The caller has entered the bound .git directory. Relative operands stay
    # on that directory and its worktree even if an attacker replaces a named
    # checkout or .git path after validation.
    _mnemosyne_git --git-dir=. --work-tree=.. "$@"
}

_mnemosyne_pull_git() {
    local nonce source_url
    if ! nonce=$(_trusted_python - <<'PYEOF'
import secrets

print(secrets.token_hex(16))
PYEOF
    ) || [[ ! "$nonce" =~ ^[0-9a-f]{32}$ ]]; then
        return 80
    fi
    # The random source alias is longer than the approved URL. Its command-
    # scope rewrite maps to the approved URL. Thus, a config that is replaced
    # after validation cannot redirect this invocation with a shorter rule.
    source_url="$MNEMOSYNE_URL/.homeric-bound-$nonce"
    _mnemosyne_bound_git \
        -c "url.$MNEMOSYNE_URL.insteadOf=$source_url" \
        pull --ff-only --no-recurse-submodules "$source_url" main
}

_mnemosyne_path_guard() {
    _trusted_python - "$@" <<'PYEOF'
import ctypes
import errno
import hashlib
import os
import secrets
import stat
import sys


class UnsafePath(RuntimeError):
    pass


def rename_noreplace(directory_descriptor, source_name, target_name):
    library = ctypes.CDLL(None, use_errno=True)
    encoded_source = os.fsencode(source_name)
    encoded_target = os.fsencode(target_name)
    if sys.platform.startswith("linux"):
        operation = getattr(library, "renameat2", None)
        flags = 1
    elif sys.platform == "darwin":
        operation = getattr(library, "renameatx_np", None)
        flags = 4
    else:
        operation = None
        flags = 0
    if operation is None:
        raise UnsafePath("atomic failed-clone retirement is unavailable")
    operation.argtypes = [
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_int,
        ctypes.c_char_p,
        ctypes.c_uint,
    ]
    operation.restype = ctypes.c_int
    ctypes.set_errno(0)
    result = operation(
        directory_descriptor,
        encoded_source,
        directory_descriptor,
        encoded_target,
        flags,
    )
    if result != 0:
        number = ctypes.get_errno() or errno.EIO
        raise OSError(number, os.strerror(number), target_name)


def retire_failed_checkout(parent_descriptor, retired_name, expected_identity):
    rename_noreplace(parent_descriptor, "knowledge", retired_name)
    retired = os.stat(
        retired_name,
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    if (retired.st_dev, retired.st_ino) == expected_identity:
        return
    try:
        rename_noreplace(parent_descriptor, retired_name, "knowledge")
        restored = os.stat(
            "knowledge",
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    except BaseException as recovery_error:
        raise UnsafePath(
            "failed Mnemosyne retirement could not recover a replacement"
        ) from recovery_error
    if (restored.st_dev, restored.st_ino) != (retired.st_dev, retired.st_ino):
        raise UnsafePath(
            "failed Mnemosyne retirement recovery changed identity"
        )
    raise UnsafePath("failed Mnemosyne checkout binding changed before retirement")


def direct_directory(path, label):
    value = os.lstat(path)
    if (
        not stat.S_ISDIR(value.st_mode)
        or value.st_uid != os.geteuid()
        or stat.S_IMODE(value.st_mode) & 0o022
    ):
        raise UnsafePath(f"{label} is not an owner-bound direct directory")
    return value


def config_record(path):
    try:
        value = os.lstat(path)
    except FileNotFoundError:
        return (-1, -1, "absent")
    if (
        not stat.S_ISREG(value.st_mode)
        or value.st_uid != os.geteuid()
        or value.st_nlink != 1
        or stat.S_IMODE(value.st_mode) & 0o022
    ):
        raise UnsafePath("Mnemosyne config is not one direct regular file")
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        opened = os.fstat(descriptor)
        if (opened.st_dev, opened.st_ino) != (value.st_dev, value.st_ino):
            raise UnsafePath("Mnemosyne config changed while opening")
        digest = hashlib.sha256()
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            digest.update(chunk)
        current = os.fstat(descriptor)
        named = os.lstat(path)
        if (
            (current.st_dev, current.st_ino) != (value.st_dev, value.st_ino)
            or (named.st_dev, named.st_ino) != (value.st_dev, value.st_ino)
        ):
            raise UnsafePath("Mnemosyne config changed while reading")
        return value.st_dev, value.st_ino, digest.hexdigest()
    finally:
        os.close(descriptor)


def record(parent, checkout, require_git, allow_contents=False):
    parent_state = direct_directory(parent, "Mnemosyne parent")
    checkout_state = direct_directory(checkout, "Mnemosyne checkout")
    if os.path.dirname(checkout) != parent or os.path.basename(checkout) != "knowledge":
        raise UnsafePath("Mnemosyne checkout path is not canonical")
    git_path = os.path.join(checkout, ".git")
    git_state = None
    config_state = (-1, -1, "absent")
    if require_git:
        git_state = direct_directory(git_path, "Mnemosyne .git")
        config_state = config_record(os.path.join(git_path, "config"))
    elif not allow_contents:
        try:
            next(os.scandir(checkout))
        except StopIteration:
            pass
        else:
            raise UnsafePath("new Mnemosyne checkout directory is not empty")
    return (
        parent_state.st_dev,
        parent_state.st_ino,
        checkout_state.st_dev,
        checkout_state.st_ino,
        -1 if git_state is None else git_state.st_dev,
        -1 if git_state is None else git_state.st_ino,
        *config_state,
    )


def encode(values):
    return "mnemosyne-binding-v1:" + ":".join(str(value) for value in values)


def decode(value):
    parts = value.split(":")
    if len(parts) != 10 or parts[0] != "mnemosyne-binding-v1":
        raise UnsafePath("invalid Mnemosyne path binding")
    numeric = []
    for item in parts[1:9]:
        if item == "-1":
            numeric.append(-1)
        elif item.isascii() and item.isdigit():
            numeric.append(int(item))
        else:
            raise UnsafePath("invalid Mnemosyne path binding")
    digest = parts[9]
    if digest != "absent" and (
        len(digest) != 64
        or any(character not in "0123456789abcdef" for character in digest)
    ):
        raise UnsafePath("invalid Mnemosyne config binding")
    return (*numeric, digest)


mode, parent, checkout = sys.argv[1:4]
if mode == "bind":
    print(encode(record(parent, checkout, True)))
elif mode == "bind-empty":
    print(encode(record(parent, checkout, False)))
elif mode == "retire-failed":
    expected = decode(sys.argv[4])
    current = record(parent, checkout, False, allow_contents=True)
    if current[:4] != expected[:4]:
        raise UnsafePath("failed Mnemosyne checkout binding changed")
    cwd = os.lstat(".")
    if (
        not stat.S_ISDIR(cwd.st_mode)
        or (cwd.st_dev, cwd.st_ino) != expected[2:4]
    ):
        raise UnsafePath("failed Mnemosyne clone left its bound directory")

    parent_descriptor = os.open(
        parent,
        os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
    )
    try:
        opened_parent = os.fstat(parent_descriptor)
        if (opened_parent.st_dev, opened_parent.st_ino) != expected[:2]:
            raise UnsafePath("Mnemosyne parent binding changed")
        checkout_descriptor = os.open(
            "knowledge",
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
            dir_fd=parent_descriptor,
        )
        try:
            opened_checkout = os.fstat(checkout_descriptor)
            if (opened_checkout.st_dev, opened_checkout.st_ino) != expected[2:4]:
                raise UnsafePath("failed Mnemosyne checkout binding changed")

            while True:
                retired_name = ".knowledge.clone-failed." + secrets.token_hex(16)
                try:
                    os.stat(
                        retired_name,
                        dir_fd=parent_descriptor,
                        follow_symlinks=False,
                    )
                except FileNotFoundError:
                    break
            retire_failed_checkout(
                parent_descriptor,
                retired_name,
                expected[2:4],
            )
            retired = os.stat(
                retired_name,
                dir_fd=parent_descriptor,
                follow_symlinks=False,
            )
            if (retired.st_dev, retired.st_ino) != expected[2:4]:
                raise UnsafePath("failed Mnemosyne checkout retirement changed target")
        finally:
            os.close(checkout_descriptor)
    finally:
        os.close(parent_descriptor)
elif mode in {"verify", "verify-container", "verify-git"}:
    expected = decode(sys.argv[4])
    current = record(
        parent,
        checkout,
        mode != "verify-container",
        allow_contents=mode == "verify-container",
    )
    compared = 4 if mode == "verify-container" else len(expected)
    if current[:compared] != expected[:compared]:
        raise UnsafePath("Mnemosyne path binding changed")
    cwd = os.lstat(".")
    expected_cwd = expected[4:6] if mode == "verify-git" else expected[2:4]
    if (
        not stat.S_ISDIR(cwd.st_mode)
        or (cwd.st_dev, cwd.st_ino) != expected_cwd
    ):
        raise UnsafePath("Mnemosyne operation left its bound directory")
    if len(sys.argv) == 6:
        root = os.lstat(sys.argv[5])
        if (
            not stat.S_ISDIR(root.st_mode)
            or (root.st_dev, root.st_ino) != expected[2:4]
        ):
            raise UnsafePath("Git reported a different Mnemosyne root")
else:
    raise UnsafePath("invalid Mnemosyne path guard operation")
PYEOF
}

_mnemosyne_validate_checkout() {
    local binding="$1" checkout_root origin_url branch
    local forbidden_config_pattern rewrite_status
    forbidden_config_pattern='^('
    forbidden_config_pattern+='url\..*\.insteadof|include\.path|includeif\..*\.path|'
    forbidden_config_pattern+='core\.(worktree|fsmonitor|hookspath|sshcommand|attributesfile)|'
    forbidden_config_pattern+='extensions\.worktreeconfig|filter\..*\.(clean|smudge|process)|'
    forbidden_config_pattern+='credential\..*|http(\..*)?\..*|'
    forbidden_config_pattern+='remote\..*\.(uploadpack|proxy|receivepack)|'
    forbidden_config_pattern+='diff\..*\.(command|textconv)|merge\..*\.driver|'
    forbidden_config_pattern+='protocol\..*\.allow|submodule\..*\.update)$'
    if ! _mnemosyne_path_guard verify-git \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" "$binding"; then
        return 80
    fi
    if ! checkout_root=$(_mnemosyne_bound_git rev-parse --show-toplevel 2>/dev/null) \
        || [[ "$checkout_root" == *$'\n'* ]]; then
        return 80
    fi
    if ! origin_url=$(_mnemosyne_bound_git config --file ./config --no-includes \
        --get-all remote.origin.url 2>/dev/null) \
        || [[ "$origin_url" == *$'\n'* ]] \
        || [[ "$origin_url" != "$MNEMOSYNE_URL" ]]; then
        return 80
    fi
    if ! branch=$(_mnemosyne_bound_git symbolic-ref --quiet --short HEAD 2>/dev/null) \
        || [[ "$branch" != main ]]; then
        return 80
    fi
    _mnemosyne_bound_git config --file ./config --no-includes \
        --get-regexp "$forbidden_config_pattern" \
        >/dev/null 2>&1
    rewrite_status=$?
    if [[ "$rewrite_status" -eq 0 ]] || [[ "$rewrite_status" -ne 1 ]]; then
        return 80
    fi
    if ! _mnemosyne_path_guard verify-git \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" "$binding" \
        "$checkout_root"; then
        return 80
    fi
    return 0
}

_mnemosyne_checkout_operation() {
    local operation="$1" binding pull_status
    if ! binding=$(_mnemosyne_path_guard bind \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" 2>/dev/null); then
        return 80
    fi
    (
        cd "$MNEMOSYNE_DIR" || exit 80
        cd .git || exit 80
        _mnemosyne_validate_checkout "$binding" || exit 80
        if [[ "$operation" == pull ]]; then
            _mnemosyne_pull_git >/dev/null 2>&1
            pull_status=$?
            _mnemosyne_validate_checkout "$binding" || exit 80
            if [[ "$pull_status" -eq 124 ]] \
                || [[ "$pull_status" -eq 125 ]] \
                || [[ "$pull_status" -eq 126 ]]; then
                exit 80
            fi
            [[ "$pull_status" -eq 0 ]] || exit 81
        fi
    )
}

_mnemosyne_retire_failed_clone() (
    local binding="$1"
    cd "$MNEMOSYNE_DIR" || exit 80
    _mnemosyne_path_guard retire-failed \
        "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" "$binding" \
        >/dev/null 2>&1 || exit 80
)

if [[ "${_settings_hard_failure:-false}" == "true" ]]; then
    check_skip "Mnemosyne — skipped because settings inspection failed"
elif ! _mnemosyne_directories_are_safe; then
    _settings_hard_failure=true
    check_fail "$_mnemosyne_error"
elif [[ -e "$MNEMOSYNE_DIR" || -L "$MNEMOSYNE_DIR" ]]; then
    if ! _mnemosyne_checkout_operation inspect; then
        _settings_hard_failure=true
        check_fail "canonical Mnemosyne checkout, branch, remote, or path binding is unavailable"
    elif [[ "${INSTALL:-false}" == "true" ]]; then
        _mnemosyne_checkout_operation pull
        _mnemosyne_status=$?
        if [[ "$_mnemosyne_status" -eq 0 ]]; then
            check_pass "Mnemosyne — up to date"
        elif [[ "$_mnemosyne_status" -eq 81 ]]; then
            check_warn "Mnemosyne pull failed (offline? non-fast-forward?)"
        else
            _settings_hard_failure=true
            check_fail "canonical Mnemosyne checkout changed during pull"
        fi
    else
        check_pass "Mnemosyne — canonical checkout present (not updated in check-only mode)"
    fi
else
    check_warn "Mnemosyne — not seeded at $MNEMOSYNE_DIR"
    if [[ "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Seeding Mnemosyne..."
        if ! mkdir -p "$MNEMOSYNE_PARENT" || \
           ! _mnemosyne_directories_are_safe; then
            _settings_hard_failure=true
            check_fail "${_mnemosyne_error:-cannot create the direct Mnemosyne parent directory}"
        elif ! mkdir "$MNEMOSYNE_DIR"; then
            _settings_hard_failure=true
            check_fail "cannot reserve the direct Mnemosyne checkout directory"
        else
            if ! _mnemosyne_empty_binding=$(_mnemosyne_path_guard bind-empty \
                "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" 2>/dev/null); then
                _settings_hard_failure=true
                check_fail "cannot bind the reserved Mnemosyne checkout directory"
            else
                (
                cd "$MNEMOSYNE_DIR" || exit 80
                _mnemosyne_path_guard verify-container \
                    "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" \
                    "$_mnemosyne_empty_binding" || exit 80
                _mnemosyne_git clone --depth 1 --branch main --single-branch \
                    -- "$MNEMOSYNE_URL" . >/dev/null 2>&1
                clone_status=$?
                if [[ "$clone_status" -eq 124 ]] \
                    || [[ "$clone_status" -eq 125 ]] \
                    || [[ "$clone_status" -eq 126 ]]; then
                    exit 80
                fi
                [[ "$clone_status" -eq 0 ]] || exit 81
                _mnemosyne_path_guard verify-container \
                    "$MNEMOSYNE_PARENT" "$MNEMOSYNE_DIR" \
                    "$_mnemosyne_empty_binding" || exit 80
                )
                _mnemosyne_clone_status=$?
                if [[ "$_mnemosyne_clone_status" -eq 0 ]] && \
                    _mnemosyne_checkout_operation inspect; then
                    check_pass "Mnemosyne — seeded to $MNEMOSYNE_DIR"
                elif [[ "$_mnemosyne_clone_status" -eq 81 ]] && \
                    _mnemosyne_retire_failed_clone \
                        "$_mnemosyne_empty_binding"; then
                    check_warn "Mnemosyne clone failed (offline? check network)"
                elif [[ "$_mnemosyne_clone_status" -eq 81 ]]; then
                    _settings_hard_failure=true
                    check_fail "failed Mnemosyne clone could not be retired safely"
                else
                    _settings_hard_failure=true
                    check_fail "seeded Mnemosyne checkout or path binding failed canonical validation"
                fi
            fi
        fi
    fi
fi

_cleanup_tool_bindings() {
    [[ -n "$_ODYSSEUS_TOOL_SNAPSHOT_DIR" ]] || return 0
    [[ -n "$_ODYSSEUS_BOUND_PYTHON" ]] || return 1
    _trusted_python - \
        "$_ODYSSEUS_TOOL_SNAPSHOT_DIR" \
        "$_ODYSSEUS_BOUND_PYTHON" \
        "$_ODYSSEUS_BOUND_PYTHON_IDENTITY" \
        "$_ODYSSEUS_BOUND_GIT" \
        "$_ODYSSEUS_BOUND_GIT_IDENTITY" \
        "$_ODYSSEUS_BOUND_GIT_INTERPRETER" \
        "$_ODYSSEUS_BOUND_GIT_INTERPRETER_IDENTITY" \
        "$_ODYSSEUS_TOOL_SNAPSHOT_IDENTITY" <<'PYEOF'
import os
import stat
import sys


class CleanupError(RuntimeError):
    pass


(
    snapshot_directory,
    python_path,
    python_identity_text,
    git_path,
    git_identity_text,
    interpreter_path,
    interpreter_identity_text,
    directory_identity_text,
) = sys.argv[1:]
python_identity = tuple(int(value) for value in python_identity_text.split(":"))
git_identity = tuple(int(value) for value in git_identity_text.split(":"))
interpreter_identity = (
    None
    if interpreter_identity_text == "-"
    else tuple(int(value) for value in interpreter_identity_text.split(":"))
)
directory_identity = tuple(
    int(value) for value in directory_identity_text.split(":")
)


def file_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_uid,
        value.st_mode,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def directory_identity_of(value):
    return (value.st_dev, value.st_ino, value.st_uid, value.st_mode)


snapshot_parent = os.path.dirname(snapshot_directory)
if (
    snapshot_parent not in {"/tmp", "/private/tmp"}
    or not os.path.basename(snapshot_directory).startswith(".odysseus-tooling-")
):
    raise CleanupError("tool snapshot cleanup path is invalid")
parent_descriptor = os.open(
    snapshot_parent,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
directory_descriptor = os.open(
    os.path.basename(snapshot_directory),
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
    dir_fd=parent_descriptor,
)
try:
    opened_directory = os.fstat(directory_descriptor)
    if directory_identity_of(opened_directory) != directory_identity:
        raise CleanupError("tool snapshot directory identity changed")
    if opened_directory.st_uid != os.geteuid():
        raise CleanupError("tool snapshot directory owner changed")
    os.fchmod(directory_descriptor, 0o700)
    snapshots = []
    if os.path.dirname(python_path) == snapshot_directory:
        snapshots.append(("python3", python_identity))
    if os.path.dirname(git_path) == snapshot_directory:
        snapshots.append(("git", git_identity))
    if interpreter_path != "-" and os.path.dirname(interpreter_path) == snapshot_directory:
        snapshots.append(("git-interpreter", interpreter_identity))
    for name, expected in snapshots:
        current = os.stat(
            name, dir_fd=directory_descriptor, follow_symlinks=False
        )
        if file_identity(current) != expected or not stat.S_ISREG(current.st_mode):
            raise CleanupError("tool snapshot identity changed before cleanup")
        os.unlink(name, dir_fd=directory_descriptor)
    os.fsync(directory_descriptor)
finally:
    os.close(directory_descriptor)
try:
    current_directory = os.stat(
        os.path.basename(snapshot_directory),
        dir_fd=parent_descriptor,
        follow_symlinks=False,
    )
    if (
        directory_identity_of(current_directory)[:3] != directory_identity[:3]
        or not stat.S_ISDIR(current_directory.st_mode)
        or stat.S_IMODE(current_directory.st_mode) != 0o700
    ):
        raise CleanupError("tool snapshot directory changed before removal")
    os.rmdir(os.path.basename(snapshot_directory), dir_fd=parent_descriptor)
finally:
    os.close(parent_descriptor)
PYEOF
}

if ! _cleanup_tool_bindings; then
    check_fail "tooling executable snapshots could not be removed safely"
fi

# This file is also exposed directly through `just claude-setup`. Preserve the
# aggregate installer's sourced phase contract, but propagate hard failures
# when this phase is the process entry point.
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    [[ "${_FAIL:-0}" -eq 0 ]]
fi
