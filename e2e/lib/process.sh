#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Process Management (T1/T2)
# Manages background processes for non-container topologies.

# Track immutable process receipts for cleanup. The file is shared with Bash
# test subprocesses so a T1 NATS restart can replace its receipt in the parent
# runner's cleanup inventory.
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
_BG_PROCESS_CONTAINMENTS=()
PROCESS_RECEIPT_DIR=""
PROCESS_RECEIPT_FILE=""
PROCESS_RECEIPT_STORAGE_RECEIPT=""
PROCESS_RECEIPT_PARENT_FD=190
PROCESS_RECEIPT_DIRECTORY_FD=191
PROCESS_RECEIPT_FILE_FD=192
REGISTERED_PROCESS_IDENTITY=""
REGISTERED_PROCESS_OWNER=""
BOUND_PYTHON_FD=195
BOUND_CURL_FD=196
SERVICE_EXECUTABLE_FD=197
BOUND_RUNTIME_TOOLS_READY=0
BOUND_PYTHON_EXEC=""
BOUND_CURL_EXEC=""

_close_bound_runtime_tool_fds() {
    if ! { exec 196<&-; } 2>/dev/null; then :; fi
    if ! { exec 195<&-; } 2>/dev/null; then :; fi
    BOUND_RUNTIME_TOOLS_READY=0
    BOUND_PYTHON_EXEC=""
    BOUND_CURL_EXEC=""
}

_ensure_bound_runtime_tools() {
    if [ "$BOUND_RUNTIME_TOOLS_READY" -eq 1 ] \
        && (: <&195) 2>/dev/null && (: <&196) 2>/dev/null; then
        return 0
    fi
    if (: <&195) 2>/dev/null; then
        echo "ERROR: reserved runtime-tool descriptors are unavailable" >&2
        return 1
    elif (: <&196) 2>/dev/null; then
        echo "ERROR: reserved runtime-tool descriptors are unavailable" >&2
        return 1
    fi
    if [ ! -x /usr/bin/python3 ] || [ ! -x /usr/bin/curl ]; then
        echo "ERROR: fixed Python or curl runtime is unavailable" >&2
        return 1
    fi
    if ! exec 195< /usr/bin/python3; then
        echo "ERROR: cannot bind the fixed Python runtime" >&2
        return 1
    fi
    if ! exec 196< /usr/bin/curl; then
        exec 195<&-
        echo "ERROR: cannot bind the fixed curl runtime" >&2
        return 1
    fi
    if [ -d /proc/self/fd ]; then
        BOUND_PYTHON_EXEC=/proc/self/fd/195
        BOUND_CURL_EXEC=/proc/self/fd/196
    else
        # Direct descriptor execution is not available on Darwin. These paths
        # are SIP-protected, root-owned objects and are revalidated below.
        BOUND_PYTHON_EXEC=/usr/bin/python3
        BOUND_CURL_EXEC=/usr/bin/curl
    fi
    export BOUND_PYTHON_FD BOUND_CURL_FD BOUND_PYTHON_EXEC BOUND_CURL_EXEC
    if ! "$BOUND_PYTHON_EXEC" -I -S - \
        "$BOUND_PYTHON_FD" "$BOUND_CURL_FD" <<'PY'
import os
import stat
import sys


for value in sys.argv[1:]:
    descriptor = int(value)
    metadata = os.fstat(descriptor)
    if not stat.S_ISREG(metadata.st_mode) \
            or metadata.st_uid != 0 \
            or stat.S_IMODE(metadata.st_mode) & 0o022 \
            or not stat.S_IMODE(metadata.st_mode) & 0o111:
        raise SystemExit(1)
PY
    then
        _close_bound_runtime_tool_fds
        echo "ERROR: fixed Python or curl runtime metadata is unsafe" >&2
        return 1
    fi
    BOUND_RUNTIME_TOOLS_READY=1
    export BOUND_RUNTIME_TOOLS_READY
}

_run_bound_python() {
    _ensure_bound_runtime_tools || return 1
    "$BOUND_PYTHON_EXEC" -I -S "$@"
}

_exec_bound_python() {
    _ensure_bound_runtime_tools || return 1
    exec "$BOUND_PYTHON_EXEC" -I -S "$@"
}

_run_bound_curl() {
    _run_bound_curl_bounded 30 "$@"
}

_run_bound_curl_bounded() {
    local total="${1:-}" connect=5
    [[ "$total" =~ ^[1-9][0-9]*$ ]] || return 2
    [ "${#total}" -le 5 ] && [ "$total" -le 86400 ] || return 2
    shift
    case "$total" in
        1|2|3|4) connect="$total" ;;
    esac
    _ensure_bound_runtime_tools || return 1
    _run_bound_python - "$total" "$connect" "$BOUND_CURL_FD" \
        "$BOUND_CURL_EXEC" "$@" <<'PY'
import os
import resource
import selectors
import signal
import stat
import subprocess
import sys
import time


MAXIMUM_BYTES = 1024 * 1024 + 4
try:
    total = int(sys.argv[1])
    connect = int(sys.argv[2])
    executable_fd = int(sys.argv[3])
except ValueError:
    raise SystemExit(2)
executable = sys.argv[4]
arguments = sys.argv[5:]
if total <= 0 or connect <= 0 or connect > total or executable_fd < 3:
    raise SystemExit(2)
opened = os.fstat(executable_fd)
if not stat.S_ISREG(opened.st_mode) \
        or stat.S_IMODE(opened.st_mode) & 0o111 == 0:
    raise SystemExit(126)
try:
    named = os.stat(executable)
except OSError:
    raise SystemExit(126)
if (named.st_dev, named.st_ino) != (opened.st_dev, opened.st_ino):
    raise SystemExit(126)

if sys.platform.startswith("linux"):
    import ctypes

    library = ctypes.CDLL(None, use_errno=True)
    if library.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise SystemExit(126)

deadline = time.monotonic() + total
interrupted = None


def catch_signal(signum, _frame):
    global interrupted
    interrupted = signum


for caught in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(caught, catch_signal)


def relay_interruption():
    if interrupted is None:
        return
    signal.signal(interrupted, signal.SIG_DFL)
    os.kill(os.getpid(), interrupted)


def descendants():
    if not sys.platform.startswith("linux"):
        return ()
    parents = {}
    try:
        names = os.listdir("/proc")
    except OSError:
        raise RuntimeError("process inventory is unavailable")
    for name in names:
        if not name.isdecimal():
            continue
        try:
            with open(f"/proc/{name}/stat", encoding="ascii") as stream:
                record = stream.read(8193)
            if len(record) > 8192:
                raise RuntimeError("oversized process inventory record")
            fields = record[record.rfind(")") + 2:].split()
            if len(fields) > 1:
                parents[int(name)] = int(fields[1])
        except FileNotFoundError:
            continue
        except (OSError, UnicodeError, ValueError):
            continue
    if os.getpid() not in parents:
        raise RuntimeError("process inventory omitted the supervisor")
    found = set()
    frontier = {os.getpid()}
    while frontier:
        current = {
            child for child, parent in parents.items()
            if parent in frontier and child not in found
        }
        found.update(current)
        frontier = current
    return tuple(found)


def reap_children():
    while True:
        try:
            child, _ = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if child == 0:
            return


def extinguish_descendants():
    if not sys.platform.startswith("linux"):
        return True
    extinction_deadline = min(deadline, time.monotonic() + 0.5)
    while True:
        reap_children()
        try:
            children = descendants()
        except RuntimeError:
            return False
        if not children:
            return True
        for child in children:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if time.monotonic() >= extinction_deadline:
            return False
        time.sleep(0.01)


if interrupted is not None or time.monotonic() >= deadline:
    relay_interruption()
    raise SystemExit(124)
preexec_fn = None
if not sys.platform.startswith("linux"):
    if not hasattr(resource, "RLIMIT_NPROC") or os.geteuid() == 0:
        raise SystemExit(126)

    def deny_descendants():
        resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))

    preexec_fn = deny_descendants

command = [
    executable,
    "-q",
    "--noproxy",
    "*",
    "--connect-timeout",
    str(connect),
    "--max-time",
    str(total),
    *arguments,
]
process = subprocess.Popen(
    command,
    executable=executable,
    stdin=subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    close_fds=True,
    pass_fds=(executable_fd,),
    env={"LC_ALL": "C", "PATH": "/usr/bin:/bin"},
    preexec_fn=preexec_fn,
)
assert process.stdout is not None
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
output = bytearray()
failure = None
pipe_closed = False


def group_exists():
    try:
        os.killpg(process.pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def signal_group(signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


try:
    while True:
        now = time.monotonic()
        if interrupted is not None:
            failure = "interrupted"
            break
        if now >= deadline:
            failure = "timeout"
            break
        for key, _ in selector.select(min(0.05, deadline - now)):
            chunk = os.read(
                key.fd, min(65536, MAXIMUM_BYTES - len(output) + 1)
            )
            if chunk:
                output.extend(chunk)
                if len(output) > MAXIMUM_BYTES:
                    failure = "overflow"
                    break
            else:
                pipe_closed = True
                selector.unregister(process.stdout)
        if failure is not None:
            break
        returncode = process.poll()
        if returncode is not None and pipe_closed:
            if group_exists():
                failure = "descendant"
            break
finally:
    selector.close()

if failure is not None:
    signal_group(signal.SIGTERM)
    grace_deadline = min(deadline, time.monotonic() + 0.2)
    while group_exists() and time.monotonic() < grace_deadline:
        time.sleep(0.01)
    if group_exists():
        signal_group(signal.SIGKILL)
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        signal_group(signal.SIGKILL)
        process.wait(timeout=0.5)
    if not extinguish_descendants():
        raise SystemExit(126)
    if interrupted is not None:
        relay_interruption()
    raise SystemExit(125 if failure == "overflow" else 124)

if not extinguish_descendants():
    raise SystemExit(126)
if output:
    os.write(sys.stdout.fileno(), output)
raise SystemExit(process.returncode)
PY
}

_valid_pid() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

_process_receipt_fds_are_available() {
    ! (: <&190) 2>/dev/null \
        && ! (: <&191) 2>/dev/null \
        && ! (: <&192) 2>/dev/null
}

_close_process_receipt_fds() {
    if ! { exec 192>&-; } 2>/dev/null; then :; fi
    if ! { exec 191<&-; } 2>/dev/null; then :; fi
    if ! { exec 190<&-; } 2>/dev/null; then :; fi
}

_open_process_receipt_fds() {
    local parent="${PROCESS_RECEIPT_DIR%/*}"
    if ! _process_receipt_fds_are_available; then
        echo "ERROR: reserved process receipt descriptors are unavailable" >&2
        return 1
    fi
    if ! exec 190< "$parent"; then
        echo "ERROR: cannot open the process receipt parent" >&2
        return 1
    fi
    if ! exec 191< "$PROCESS_RECEIPT_DIR"; then
        exec 190<&-
        echo "ERROR: cannot open the process receipt directory" >&2
        return 1
    fi
    if ! exec 192<> "$PROCESS_RECEIPT_FILE"; then
        exec 191<&-
        exec 190<&-
        echo "ERROR: cannot open the process receipt file" >&2
        return 1
    fi
    export PROCESS_RECEIPT_PARENT_FD PROCESS_RECEIPT_DIRECTORY_FD \
        PROCESS_RECEIPT_FILE_FD
    if ! _process_receipt_store_op verify; then
        _close_process_receipt_fds
        return 1
    fi
}

_bind_process_receipt_store() {
    local candidate_dir="$1" candidate_file="$2" receipt
    local receipt_version bound_parent bound_directory receipt_metadata
    if ! receipt=$(_run_bound_python - "$candidate_dir" "$candidate_file" <<'PY'
import os
import re
import stat
import sys


def abort(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def fd_mount_identity(file_descriptor):
    if sys.platform.startswith("linux"):
        try:
            with open(
                f"/proc/self/fdinfo/{file_descriptor}", encoding="ascii"
            ) as stream:
                for line in stream:
                    if line.startswith("mnt_id:"):
                        value = line.split(":", 1)[1].strip()
                        if value.isdigit():
                            return f"linux:{value}"
        except OSError as error:
            abort(f"mount identity unavailable: {error}")
        abort("mount identity unavailable")
    if sys.platform == "darwin":
        import ctypes
        import hashlib

        class Fsid(ctypes.Structure):
            _fields_ = [("values", ctypes.c_int32 * 2)]

        class Statfs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", Fsid),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32),
                ("f_reserved", ctypes.c_uint32 * 7),
            ]

        metadata = Statfs()
        library = ctypes.CDLL(None, use_errno=True)
        if library.fstatfs(file_descriptor, ctypes.byref(metadata)) != 0:
            abort(
                f"mount identity unavailable: "
                f"{os.strerror(ctypes.get_errno())}"
            )
        payload = b"\0".join(
            (
                bytes(metadata.f_fstypename).split(b"\0", 1)[0],
                bytes(metadata.f_mntonname).split(b"\0", 1)[0],
                bytes(metadata.f_mntfromname).split(b"\0", 1)[0],
                str(tuple(metadata.f_fsid.values)).encode("ascii"),
            )
        )
        if not payload:
            abort("mount identity unavailable")
        return "darwin:" + hashlib.sha256(payload).hexdigest()
    abort(f"mount identity unavailable on {sys.platform}")


directory = os.path.abspath(sys.argv[1])
parent = os.path.realpath(os.path.dirname(directory))
directory_name = os.path.basename(directory)
file_path = os.path.abspath(sys.argv[2])
file_name = os.path.basename(file_path)
if not re.fullmatch(r"hi-process-receipts\.[A-Za-z0-9]{6}", directory_name):
    abort("unsafe process receipt directory name")
if file_name != "receipts" or file_path != os.path.join(directory, file_name):
    abort("unsafe process receipt file name")
if "|" in parent or "\n" in parent or not os.path.isabs(parent):
    abort("unsafe process receipt parent")
if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
    abort("required no-follow receipt controls are unavailable")
directory_flags = os.O_RDONLY | os.O_DIRECTORY \
    | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
file_flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
try:
    parent_fd = os.open(parent, directory_flags)
    directory_fd = os.open(directory_name, directory_flags, dir_fd=parent_fd)
    file_fd = os.open(file_name, file_flags, dir_fd=directory_fd)
except OSError as error:
    abort(f"cannot bind process receipt storage: {error}")
try:
    parent_metadata = os.fstat(parent_fd)
    directory_metadata = os.fstat(directory_fd)
    file_metadata = os.fstat(file_fd)
    if not stat.S_ISDIR(parent_metadata.st_mode):
        abort("process receipt parent is not a directory")
    if not stat.S_ISDIR(directory_metadata.st_mode) \
            or directory_metadata.st_uid != os.geteuid() \
            or stat.S_IMODE(directory_metadata.st_mode) != 0o700 \
            or directory_metadata.st_nlink < 2:
        abort("process receipt directory metadata is unsafe")
    if not stat.S_ISREG(file_metadata.st_mode) \
            or file_metadata.st_uid != os.geteuid() \
            or stat.S_IMODE(file_metadata.st_mode) != 0o600 \
            or file_metadata.st_nlink != 1:
        abort("process receipt file metadata is unsafe")
    print(
        "|".join(
            (
                "v2",
                parent,
                directory_name,
                str(parent_metadata.st_dev),
                str(parent_metadata.st_ino),
                str(parent_metadata.st_uid),
                format(stat.S_IMODE(parent_metadata.st_mode), "o"),
                fd_mount_identity(parent_fd),
                str(directory_metadata.st_dev),
                str(directory_metadata.st_ino),
                str(directory_metadata.st_uid),
                format(stat.S_IMODE(directory_metadata.st_mode), "o"),
                str(directory_metadata.st_nlink),
                fd_mount_identity(directory_fd),
                file_name,
                str(file_metadata.st_dev),
                str(file_metadata.st_ino),
                str(file_metadata.st_uid),
                format(stat.S_IMODE(file_metadata.st_mode), "o"),
                str(file_metadata.st_nlink),
                fd_mount_identity(file_fd),
            )
        )
    )
finally:
    os.close(file_fd)
    os.close(directory_fd)
    os.close(parent_fd)
PY
    ); then
        return 1
    fi
    PROCESS_RECEIPT_STORAGE_RECEIPT="$receipt"
    IFS='|' read -r receipt_version bound_parent bound_directory \
        receipt_metadata <<< "$receipt"
    if [ "$receipt_version" != v2 ] || [ -z "$bound_parent" ] \
        || [ -z "$bound_directory" ] || [ -z "$receipt_metadata" ]; then
        echo "ERROR: malformed process receipt storage receipt" >&2
        return 1
    fi
    PROCESS_RECEIPT_DIR="$bound_parent/$bound_directory"
    PROCESS_RECEIPT_FILE="$PROCESS_RECEIPT_DIR/receipts"
    export PROCESS_RECEIPT_DIR PROCESS_RECEIPT_FILE \
        PROCESS_RECEIPT_STORAGE_RECEIPT
    _open_process_receipt_fds
}

_process_receipt_store_op() {
    local operation="$1" payload="${2:-}"
    [ -n "${PROCESS_RECEIPT_STORAGE_RECEIPT:-}" ] || {
        echo "ERROR: process receipt storage has no immutable receipt" >&2
        return 1
    }
    _run_bound_python - "$operation" "$PROCESS_RECEIPT_STORAGE_RECEIPT" "$payload" \
        "$PROCESS_RECEIPT_PARENT_FD" "$PROCESS_RECEIPT_DIRECTORY_FD" \
        "$PROCESS_RECEIPT_FILE_FD" <<'PY'
import fcntl
import hashlib
import os
import re
import secrets
import stat
import sys


def abort(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


PROCESS_RECEIPT_MAX_BYTES = 65536
PROCESS_RECEIPT_MAX_RECORDS = 256
PROCESS_RECEIPT_SLOT_HEADER_BYTES = 128
PROCESS_RECEIPT_SLOT_BYTES = (
    PROCESS_RECEIPT_SLOT_HEADER_BYTES + PROCESS_RECEIPT_MAX_BYTES
)
PROCESS_RECEIPT_STORE_MAX_BYTES = PROCESS_RECEIPT_SLOT_BYTES * 2
PROCESS_RECEIPT_SLOT_MAGIC = b"hi-receipt-slot-v1"
RECEIPT_PATTERN = re.compile(
    rb"[1-9][0-9]*\|[A-Za-z0-9._:-]+\|[1-9][0-9]*\|"
    rb"(?:cg1:[A-Za-z0-9_-]+)?"
)


def decode_records(data):
    if len(data) > PROCESS_RECEIPT_MAX_BYTES:
        abort("process receipt storage exceeds its byte limit")
    if data and not data.endswith(b"\n"):
        abort("process receipt storage has a partial record")
    records = data.splitlines()
    if len(records) > PROCESS_RECEIPT_MAX_RECORDS:
        abort("process receipt storage exceeds its record limit")
    if any(RECEIPT_PATTERN.fullmatch(record) is None for record in records):
        abort("process receipt storage contains a malformed record")
    pids = [record.split(b"|", 1)[0] for record in records]
    if len(pids) != len(set(pids)):
        abort("process receipt storage contains a duplicate process id")
    return records


def slot_header(generation, data):
    header = b" ".join(
        (
            PROCESS_RECEIPT_SLOT_MAGIC,
            str(generation).encode("ascii"),
            str(len(data)).encode("ascii"),
            hashlib.sha256(data).hexdigest().encode("ascii"),
        )
    ) + b"\n"
    if len(header) > PROCESS_RECEIPT_SLOT_HEADER_BYTES:
        abort("process receipt slot header exceeds its fixed boundary")
    return header.ljust(PROCESS_RECEIPT_SLOT_HEADER_BYTES, b"\0")


def read_slot(file_descriptor, index, file_size):
    offset = index * PROCESS_RECEIPT_SLOT_BYTES
    if file_size < offset + PROCESS_RECEIPT_SLOT_HEADER_BYTES:
        return None
    header = os.pread(
        file_descriptor, PROCESS_RECEIPT_SLOT_HEADER_BYTES, offset
    )
    if len(header) != PROCESS_RECEIPT_SLOT_HEADER_BYTES:
        return None
    header_text = header.rstrip(b"\0")
    try:
        magic, generation_text, length_text, digest = header_text.split()
        generation = int(generation_text)
        length = int(length_text)
    except (ValueError, TypeError):
        return None
    if (
        magic != PROCESS_RECEIPT_SLOT_MAGIC
        or generation < 1
        or generation > (1 << 63) - 1
        or length < 0
        or length > PROCESS_RECEIPT_MAX_BYTES
        or re.fullmatch(rb"[0-9a-f]{64}", digest) is None
        or file_size < offset + PROCESS_RECEIPT_SLOT_HEADER_BYTES + length
    ):
        return None
    data = os.pread(
        file_descriptor,
        length,
        offset + PROCESS_RECEIPT_SLOT_HEADER_BYTES,
    )
    if len(data) != length \
            or hashlib.sha256(data).hexdigest().encode("ascii") != digest:
        return None
    return generation, data, decode_records(data), index


def read_records(file_descriptor):
    file_size = os.fstat(file_descriptor).st_size
    if file_size == 0:
        return b"", [], 0, -1
    if file_size > PROCESS_RECEIPT_STORE_MAX_BYTES:
        abort("process receipt storage exceeds its fixed slot boundary")
    slots = [
        slot
        for index in range(2)
        if (slot := read_slot(file_descriptor, index, file_size)) is not None
    ]
    if not slots:
        abort("process receipt storage has no complete durable generation")
    slots.sort(key=lambda slot: slot[0])
    if len(slots) == 2 and slots[0][0] == slots[1][0]:
        abort("process receipt storage has ambiguous generations")
    return slots[-1][1], slots[-1][2], slots[-1][0], slots[-1][3]


def encode_payload(value):
    try:
        data = value.encode("utf-8")
    except UnicodeError:
        abort("process receipt payload is not UTF-8")
    return data, decode_records(data)


def pwrite_all(file_descriptor, data, offset):
    written_total = 0
    while written_total < len(data):
        written = os.pwrite(
            file_descriptor,
            data[written_total:],
            offset + written_total,
        )
        if written <= 0:
            abort("process receipt storage write made no progress")
        written_total += written


def write_records(file_descriptor, records):
    data = b"" if not records else b"\n".join(records) + b"\n"
    if len(data) > PROCESS_RECEIPT_MAX_BYTES:
        abort("process receipt storage exceeds its byte limit")
    _, _, generation, active_index = read_records(file_descriptor)
    if generation >= (1 << 63) - 1:
        abort("process receipt generation is exhausted")
    target_index = 0 if active_index < 0 else 1 - active_index
    target_offset = target_index * PROCESS_RECEIPT_SLOT_BYTES
    # Payload first, fixed header last: an interrupted inactive-slot update is
    # either checksum-invalid or absent, so readers retain the prior fsynced
    # generation. The active slot is never modified in place.
    pwrite_all(
        file_descriptor,
        data,
        target_offset + PROCESS_RECEIPT_SLOT_HEADER_BYTES,
    )
    pwrite_all(
        file_descriptor,
        slot_header(generation + 1, data),
        target_offset,
    )
    os.fsync(file_descriptor)


def fd_mount_identity(file_descriptor):
    if sys.platform.startswith("linux"):
        try:
            with open(
                f"/proc/self/fdinfo/{file_descriptor}", encoding="ascii"
            ) as stream:
                for line in stream:
                    if line.startswith("mnt_id:"):
                        value = line.split(":", 1)[1].strip()
                        if value.isdigit():
                            return f"linux:{value}"
        except OSError as error:
            abort(f"mount identity unavailable: {error}")
        abort("mount identity unavailable")
    if sys.platform == "darwin":
        import ctypes
        import hashlib

        class Fsid(ctypes.Structure):
            _fields_ = [("values", ctypes.c_int32 * 2)]

        class Statfs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", Fsid),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32),
                ("f_reserved", ctypes.c_uint32 * 7),
            ]

        metadata = Statfs()
        library = ctypes.CDLL(None, use_errno=True)
        if library.fstatfs(file_descriptor, ctypes.byref(metadata)) != 0:
            abort(
                f"mount identity unavailable: "
                f"{os.strerror(ctypes.get_errno())}"
            )
        payload = b"\0".join(
            (
                bytes(metadata.f_fstypename).split(b"\0", 1)[0],
                bytes(metadata.f_mntonname).split(b"\0", 1)[0],
                bytes(metadata.f_mntfromname).split(b"\0", 1)[0],
                str(tuple(metadata.f_fsid.values)).encode("ascii"),
            )
        )
        if not payload:
            abort("mount identity unavailable")
        return "darwin:" + hashlib.sha256(payload).hexdigest()
    abort(f"mount identity unavailable on {sys.platform}")


operation, serialized, payload, parent_fd_text, directory_fd_text, \
    file_fd_text = sys.argv[1:]
fields = serialized.split("|")
if len(fields) != 21 or fields[0] != "v2":
    abort("malformed process receipt storage receipt")
(
    _,
    parent,
    directory_name,
    parent_dev,
    parent_ino,
    parent_uid,
    parent_mode,
    parent_mount,
    directory_dev,
    directory_ino,
    directory_uid,
    directory_mode,
    directory_nlink,
    directory_mount,
    file_name,
    file_dev,
    file_ino,
    file_uid,
    file_mode,
    file_nlink,
    file_mount,
) = fields
if not os.path.isabs(parent):
    abort("process receipt parent is not absolute")
if not re.fullmatch(r"hi-process-receipts\.[A-Za-z0-9]{6}", directory_name) \
        or file_name != "receipts":
    abort("unsafe process receipt storage name")
try:
    parent_dev, parent_ino, parent_uid, directory_dev, directory_ino, \
        directory_uid, \
        directory_nlink, file_dev, file_ino, file_uid, file_nlink = map(
            int,
            (
                parent_dev,
                parent_ino,
                parent_uid,
                directory_dev,
                directory_ino,
                directory_uid,
                directory_nlink,
                file_dev,
                file_ino,
                file_uid,
                file_nlink,
            ),
        )
    parent_mode = int(parent_mode, 8)
    directory_mode = int(directory_mode, 8)
    file_mode = int(file_mode, 8)
except ValueError:
    abort("non-numeric process receipt storage metadata")
if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
    abort("required no-follow receipt controls are unavailable")
try:
    parent_fd, directory_fd, file_fd = map(
        int, (parent_fd_text, directory_fd_text, file_fd_text)
    )
except ValueError:
    abort("invalid process receipt descriptors")
if min(parent_fd, directory_fd, file_fd) < 3:
    abort("unsafe process receipt descriptors")
try:
    try:
        parent_metadata = os.fstat(parent_fd)
        directory_metadata = os.fstat(directory_fd)
        file_metadata = os.fstat(file_fd)
    except OSError as error:
        abort(f"cannot inspect bound process receipt storage: {error}")
    if (
        parent_metadata.st_dev,
        parent_metadata.st_ino,
        parent_metadata.st_uid,
        stat.S_IMODE(parent_metadata.st_mode),
    ) != (
        parent_dev,
        parent_ino,
        parent_uid,
        parent_mode,
    ) or not stat.S_ISDIR(parent_metadata.st_mode) \
            or fd_mount_identity(parent_fd) != parent_mount:
        abort("process receipt parent identity changed")
    if (
        directory_metadata.st_dev,
        directory_metadata.st_ino,
        directory_metadata.st_uid,
        stat.S_IMODE(directory_metadata.st_mode),
        directory_metadata.st_nlink,
    ) != (
        directory_dev,
        directory_ino,
        directory_uid,
        directory_mode,
        directory_nlink,
    ) or not stat.S_ISDIR(directory_metadata.st_mode):
        abort("process receipt directory identity changed")
    if fd_mount_identity(directory_fd) != directory_mount:
        abort("process receipt directory mount identity changed")
    if (
        file_metadata.st_dev,
        file_metadata.st_ino,
        file_metadata.st_uid,
        stat.S_IMODE(file_metadata.st_mode),
        file_metadata.st_nlink,
    ) != (
        file_dev,
        file_ino,
        file_uid,
        file_mode,
        file_nlink,
    ) or not stat.S_ISREG(file_metadata.st_mode):
        abort("process receipt file identity changed")
    if fd_mount_identity(file_fd) != file_mount:
        abort("process receipt file mount identity changed")
    operation_file_fd = -1
    if operation != "path":
        file_flags = os.O_RDWR | os.O_NOFOLLOW \
            | getattr(os, "O_CLOEXEC", 0)
        try:
            operation_file_fd = os.open(
                file_name, file_flags, dir_fd=directory_fd
            )
        except OSError as error:
            abort(f"cannot open exact process receipt file: {error}")
        operation_file_metadata = os.fstat(operation_file_fd)
        if (
            operation_file_metadata.st_dev,
            operation_file_metadata.st_ino,
            operation_file_metadata.st_uid,
            stat.S_IMODE(operation_file_metadata.st_mode),
            operation_file_metadata.st_nlink,
        ) != (
            file_dev,
            file_ino,
            file_uid,
            file_mode,
            file_nlink,
        ) or not stat.S_ISREG(operation_file_metadata.st_mode) \
                or fd_mount_identity(operation_file_fd) != file_mount:
            abort("named process receipt file lost its bound identity")

    def validate_locked_name():
        try:
            named = os.stat(
                file_name, dir_fd=directory_fd, follow_symlinks=False
            )
        except OSError as error:
            abort(f"locked process receipt name is unavailable: {error}")
        active = os.fstat(operation_file_fd)
        if (
            named.st_dev,
            named.st_ino,
            named.st_uid,
            stat.S_IMODE(named.st_mode),
            named.st_nlink,
        ) != (
            file_dev,
            file_ino,
            file_uid,
            file_mode,
            file_nlink,
        ) or (named.st_dev, named.st_ino) != (
            active.st_dev, active.st_ino
        ) or not stat.S_ISREG(named.st_mode):
            abort("locked process receipt name lost its bound identity")

    if operation == "verify":
        fcntl.flock(operation_file_fd, fcntl.LOCK_SH)
        validate_locked_name()
        read_records(operation_file_fd)
    elif operation == "path":
        print(os.path.join(parent, directory_name))
        print(os.path.join(parent, directory_name, file_name))
    elif operation == "read":
        fcntl.flock(operation_file_fd, fcntl.LOCK_SH)
        validate_locked_name()
        data, _, _, _ = read_records(operation_file_fd)
        sys.stdout.buffer.write(data)
    elif operation == "write":
        _, replacement_records = encode_payload(payload)
        fcntl.flock(operation_file_fd, fcntl.LOCK_EX)
        validate_locked_name()
        read_records(operation_file_fd)
        write_records(operation_file_fd, replacement_records)
    elif operation in ("add", "drop"):
        _, mutation_records = encode_payload(payload)
        if len(mutation_records) != 1:
            abort("process receipt mutation requires one exact record")
        mutation = mutation_records[0]
        mutation_pid = mutation.split(b"|", 1)[0]
        fcntl.flock(operation_file_fd, fcntl.LOCK_EX)
        validate_locked_name()
        _, records, _, _ = read_records(operation_file_fd)
        if operation == "add":
            if any(record.split(b"|", 1)[0] == mutation_pid for record in records):
                abort("refusing to replace an existing process cleanup receipt")
            if len(records) >= PROCESS_RECEIPT_MAX_RECORDS:
                abort("process receipt storage exceeds its record limit")
            records.append(mutation)
        else:
            if mutation not in records:
                abort("exact process cleanup receipt is unavailable")
            records.remove(mutation)
        write_records(operation_file_fd, records)
    elif operation == "remove":
        fcntl.flock(operation_file_fd, fcntl.LOCK_EX)
        validate_locked_name()
        _, records, _, _ = read_records(operation_file_fd)
        if records:
            abort("refusing to remove non-empty process receipt storage")
        directory_flags = os.O_RDONLY | os.O_DIRECTORY \
            | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
        named_directory = os.stat(
            directory_name, dir_fd=parent_fd, follow_symlinks=False
        )
        if (
            named_directory.st_dev,
            named_directory.st_ino,
            named_directory.st_uid,
            stat.S_IMODE(named_directory.st_mode),
            named_directory.st_nlink,
        ) != (
            directory_dev,
            directory_ino,
            directory_uid,
            directory_mode,
            directory_nlink,
        ) or not stat.S_ISDIR(named_directory.st_mode):
            abort("process receipt directory name lost its bound identity")
        quarantine_name = (
            f".{directory_name}.cleanup-{secrets.token_hex(16)}"
        )
        try:
            os.stat(
                quarantine_name, dir_fd=parent_fd, follow_symlinks=False
            )
        except FileNotFoundError:
            pass
        else:
            abort("process receipt quarantine name already exists")
        os.rename(
            directory_name,
            quarantine_name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        recovery_path = os.path.join(parent, quarantine_name)
        try:
            quarantine_fd = os.open(
                quarantine_name, directory_flags, dir_fd=parent_fd
            )
        except OSError as error:
            abort(
                "cannot open quarantined process receipt storage; retained "
                f"for operator recovery at {recovery_path}: {error}"
            )
        try:
            quarantined = os.fstat(quarantine_fd)
            if (
                quarantined.st_dev,
                quarantined.st_ino,
                quarantined.st_uid,
                stat.S_IMODE(quarantined.st_mode),
            ) != (
                directory_dev,
                directory_ino,
                directory_uid,
                directory_mode,
            ) or not stat.S_ISDIR(quarantined.st_mode) \
                    or fd_mount_identity(quarantine_fd) != directory_mount:
                abort(
                    "quarantined process receipt identity changed; retained "
                    f"for operator recovery at {recovery_path}"
                )
        finally:
            os.close(quarantine_fd)
        try:
            os.stat(directory_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort(
                "retained quarantined process receipt storage after a "
                "same-name replacement appeared; operator recovery is "
                f"required at {recovery_path}"
            )
        abort(
            "exact inode-bound deletion is unavailable; quarantined process "
            "receipt storage retained for operator recovery at "
            f"{recovery_path}"
        )
    else:
        abort("unknown process receipt storage operation")
finally:
    if "operation_file_fd" in globals() and operation_file_fd >= 0:
        os.close(operation_file_fd)
PY
}

_ensure_process_receipt_store() {
    local canonical_parent candidate location
    if [ -n "$PROCESS_RECEIPT_STORAGE_RECEIPT" ]; then
        if ! location=$(_process_receipt_store_op path); then
            echo "ERROR: process receipt storage is missing or unsafe" >&2
            return 1
        fi
        PROCESS_RECEIPT_DIR="${location%%$'\n'*}"
        PROCESS_RECEIPT_FILE="${location#*$'\n'}"
        export PROCESS_RECEIPT_DIR PROCESS_RECEIPT_FILE
        return 0
    fi
    if ! canonical_parent=$(_run_bound_python - <<'PY'
import os
print(os.path.realpath("/tmp"))
PY
    ) || [ -z "$canonical_parent" ]; then
        echo "ERROR: could not resolve process receipt parent" >&2
        return 1
    fi
    if ! candidate=$(mktemp -d "$canonical_parent/hi-process-receipts.XXXXXX") \
        || [ ! -d "$candidate" ] || [ -L "$candidate" ]; then
        echo "ERROR: could not create a safe process receipt directory" >&2
        return 1
    fi
    PROCESS_RECEIPT_DIR="$candidate"
    PROCESS_RECEIPT_FILE="$candidate/receipts"
    export PROCESS_RECEIPT_DIR PROCESS_RECEIPT_FILE
    if ! (umask 077 && : > "$PROCESS_RECEIPT_FILE"); then
        echo "ERROR: could not create process receipt storage; retained $candidate" >&2
        return 1
    fi
    if ! _bind_process_receipt_store "$candidate" "$PROCESS_RECEIPT_FILE"; then
        echo "ERROR: could not bind process receipt storage; retained $candidate" >&2
        return 1
    fi
    if ! _process_receipt_store_op write ""; then
        echo "ERROR: could not seed durable process receipt storage; retained $candidate" >&2
        return 1
    fi
}

_persist_process_receipts() {
    local index payload=""
    _ensure_process_receipt_store || return 1
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        payload+="${_BG_PIDS[$index]}|${_BG_PID_IDENTITIES[$index]}|"
        payload+="${_BG_PID_OWNERS[$index]}|"
        payload+="${_BG_PROCESS_CONTAINMENTS[$index]:-}"$'\n'
    done
    _process_receipt_store_op write "$payload"
}

_sync_process_receipts() {
    local pid identity owner containment extra receipt_contents
    [ -n "$PROCESS_RECEIPT_STORAGE_RECEIPT" ] || return 0
    if ! receipt_contents=$(_process_receipt_store_op read); then
        return 1
    fi
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    _BG_PROCESS_CONTAINMENTS=()
    while IFS='|' read -r pid identity owner containment extra; do
        [ -n "$pid$identity$owner${containment:-}${extra:-}" ] || continue
        if ! _valid_pid "$pid" \
            || ! [[ "$identity" =~ ^[A-Za-z0-9._:-]+$ ]] \
            || ! _valid_pid "$owner" \
            || { [ -n "${containment:-}" ] \
                && ! [[ "$containment" =~ ^cg1:[A-Za-z0-9_-]+$ ]]; } \
            || [ -n "${extra:-}" ]; then
            echo "ERROR: malformed process cleanup receipt" >&2
            return 1
        fi
        _BG_PIDS+=("$pid")
        _BG_PID_IDENTITIES+=("$identity")
        _BG_PID_OWNERS+=("$owner")
        _BG_PROCESS_CONTAINMENTS+=("${containment:-}")
    done <<< "$receipt_contents"
}

_remove_process_receipt_store() {
    if [ -z "$PROCESS_RECEIPT_STORAGE_RECEIPT" ]; then
        if [ -n "$PROCESS_RECEIPT_DIR$PROCESS_RECEIPT_FILE" ]; then
            echo "ERROR: refusing process receipt cleanup without a receipt" >&2
            return 1
        fi
        return 0
    fi
    _process_receipt_store_op remove || return 1
    _close_process_receipt_fds
    PROCESS_RECEIPT_DIR=""
    PROCESS_RECEIPT_FILE=""
    PROCESS_RECEIPT_STORAGE_RECEIPT=""
    export PROCESS_RECEIPT_DIR PROCESS_RECEIPT_FILE \
        PROCESS_RECEIPT_STORAGE_RECEIPT
}

_process_receipt() {
    local pid="$1" stat_record stat_tail boot_id platform
    local -a stat_fields=()
    local ppid
    _valid_pid "$pid" || return 2
    if [ -r "/proc/$pid/stat" ]; then
        IFS= read -r stat_record < "/proc/$pid/stat" || return 2
        stat_tail="${stat_record##*) }"
        read -r -a stat_fields <<< "$stat_tail"
        [ "${#stat_fields[@]}" -ge 20 ] || return 2
        [ "${stat_fields[0]}" != Z ] || return 1
        ppid="${stat_fields[1]}"
        if [ -r /proc/sys/kernel/random/boot_id ]; then
            IFS= read -r boot_id < /proc/sys/kernel/random/boot_id || return 2
        else
            boot_id=linux
        fi
        printf '%s:%s|%s\n' "$boot_id" "${stat_fields[19]}" "$ppid"
        return 0
    fi
    platform=$(uname -s 2>/dev/null) || return 2
    if [ "$platform" = Linux ]; then
        # Missing or unreadable proc metadata is not itself proof of extinction.
        # A signal-zero probe distinguishes ESRCH from a live inaccessible PID.
        local extinction_result
        _ensure_bound_runtime_tools || return 2
        if ! extinction_result=$(_run_bound_python - "$pid" <<'PY'
import os
import sys

try:
    os.kill(int(sys.argv[1]), 0)
except ProcessLookupError:
    print("extinct")
    raise SystemExit(0)
except (OSError, ValueError):
    raise SystemExit(2)
raise SystemExit(2)
PY
        ); then
            return 2
        fi
        [ "$extinction_result" = extinct ] || return 2
        return 1
    fi
    [ "$platform" = Darwin ] || return 2
    _run_bound_python - "$pid" <<'PY'
import ctypes
import errno
import sys


class ProcBsdInfo(ctypes.Structure):
    _fields_ = [
        ("pbi_flags", ctypes.c_uint32),
        ("pbi_status", ctypes.c_uint32),
        ("pbi_xstatus", ctypes.c_uint32),
        ("pbi_pid", ctypes.c_uint32),
        ("pbi_ppid", ctypes.c_uint32),
        ("pbi_uid", ctypes.c_uint32),
        ("pbi_gid", ctypes.c_uint32),
        ("pbi_ruid", ctypes.c_uint32),
        ("pbi_rgid", ctypes.c_uint32),
        ("pbi_svuid", ctypes.c_uint32),
        ("pbi_svgid", ctypes.c_uint32),
        ("rfu_1", ctypes.c_uint32),
        ("pbi_comm", ctypes.c_char * 16),
        ("pbi_name", ctypes.c_char * 32),
        ("pbi_nfiles", ctypes.c_uint32),
        ("pbi_pgid", ctypes.c_uint32),
        ("pbi_pjobc", ctypes.c_uint32),
        ("e_tdev", ctypes.c_uint32),
        ("e_tpgid", ctypes.c_uint32),
        ("pbi_nice", ctypes.c_int32),
        ("pbi_start_tvsec", ctypes.c_uint64),
        ("pbi_start_tvusec", ctypes.c_uint64),
    ]


pid = int(sys.argv[1])
library = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
library.proc_pidinfo.argtypes = [
    ctypes.c_int,
    ctypes.c_int,
    ctypes.c_uint64,
    ctypes.c_void_p,
    ctypes.c_int,
]
library.proc_pidinfo.restype = ctypes.c_int
metadata = ProcBsdInfo()
result = library.proc_pidinfo(
    pid, 3, 0, ctypes.byref(metadata), ctypes.sizeof(metadata)
)
if result != ctypes.sizeof(metadata):
    error_number = ctypes.get_errno()
    raise SystemExit(1 if error_number in (0, errno.ESRCH) else 2)
if metadata.pbi_status == 5:
    raise SystemExit(1)
if metadata.pbi_pid != pid or metadata.pbi_ppid <= 0 \
        or metadata.pbi_start_tvsec <= 0:
    raise SystemExit(2)
print(
    f"darwin:{metadata.pbi_start_tvsec}:{metadata.pbi_start_tvusec}"
    f"|{metadata.pbi_ppid}"
)
PY
}

_process_identity_status() {
    local pid="$1" expected_identity="$2" expected_parent="${3:-}"
    local receipt status current_identity current_parent
    if receipt=$(_process_receipt "$pid"); then
        current_identity="${receipt%%|*}"
        current_parent="${receipt#*|}"
        if [ "$current_identity" = "$expected_identity" ] \
            && { [ -z "$expected_parent" ] \
                || [ "$current_parent" = "$expected_parent" ]; }; then
            return 0
        fi
        return 1
    else
        status=$?
    fi
    return "$status"
}

_signal_bound_process() {
    local pid="$1" expected_identity="$2" expected_parent="$3" signal_name="$4"
    _run_bound_python - "$pid" "$expected_identity" "$expected_parent" \
        "$signal_name" <<'PY'
import errno
import os
import signal
import sys


pid = int(sys.argv[1])
expected_identity = sys.argv[2]
expected_parent = int(sys.argv[3])
signal_number = {"-TERM": signal.SIGTERM, "-KILL": signal.SIGKILL}.get(
    sys.argv[4]
)
if pid <= 0 or expected_parent <= 0 or signal_number is None:
    raise SystemExit(2)

if sys.platform.startswith("linux"):
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        raise SystemExit(2)
    try:
        process_fd = os.pidfd_open(pid, 0)
    except ProcessLookupError:
        raise SystemExit(1)
    except OSError:
        raise SystemExit(2)
    try:
        try:
            with open(f"/proc/self/fdinfo/{process_fd}", encoding="ascii") as stream:
                pidfd_fields = dict(
                    line.rstrip("\n").split(":", 1)
                    for line in stream
                    if ":" in line
                )
            bound_pid = int(pidfd_fields.get("Pid", "-1").strip())
            with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
                stat_record = stream.read()
            stat_fields = stat_record.rsplit(") ", 1)[1].split()
            parent = int(stat_fields[1])
            start_token = stat_fields[19]
            with open(
                "/proc/sys/kernel/random/boot_id", encoding="ascii"
            ) as stream:
                boot_id = stream.read().strip()
        except (OSError, ValueError, IndexError):
            raise SystemExit(1)
        parent_matches = parent == expected_parent
        if not parent_matches and parent == 1:
            try:
                os.kill(expected_parent, 0)
            except ProcessLookupError:
                parent_matches = True
            except PermissionError:
                parent_matches = False
        if bound_pid != pid or not parent_matches \
                or f"{boot_id}:{start_token}" != expected_identity:
            raise SystemExit(1)
        signal.pidfd_send_signal(process_fd, signal_number, None, 0)
    except ProcessLookupError:
        raise SystemExit(1)
    except PermissionError:
        raise SystemExit(2)
    finally:
        os.close(process_fd)
    raise SystemExit(0)

# Darwin exposes high-resolution observation tokens, but no generally available
# handle-bound signal primitive comparable to Linux pidfds. Fail closed instead
# of reintroducing an identity-check-to-kill PID reuse window.
raise SystemExit(2)
PY
}

_bound_process_signaling_supported() {
    _run_bound_python - <<'PY'
import os
import signal
import sys


if not sys.platform.startswith("linux") \
        or not hasattr(os, "pidfd_open") \
        or not hasattr(signal, "pidfd_send_signal"):
    raise SystemExit(1)
try:
    descriptor = os.pidfd_open(os.getpid(), 0)
    try:
        signal.pidfd_send_signal(descriptor, 0, None, 0)
    finally:
        os.close(descriptor)
except (OSError, ValueError):
    raise SystemExit(1)
PY
}

# Linux cgroup v2 is the containment boundary for every service launched by
# this library.  A cgroup receipt binds the exact kernel object; cgroup.kill is
# the only supported fallback for descendants that leave the leader's session
# or process group.  Hosts without delegated cgroup authority fail before the
# service binary is started.
PENDING_SERVICE_CONTAINMENT=""

_service_containment_op() {
    local operation="$1" receipt="${2:-}" pid="${3:-}"
    _run_bound_python - "$operation" "$receipt" "$pid" <<'PY'
import base64
import json
import os
import re
import secrets
import stat
import sys


def abort(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(2)


def decode_mount_field(value):
    return re.sub(
        r"\\([0-7]{3})",
        lambda match: chr(int(match.group(1), 8)),
        value,
    )


def current_cgroup_parent():
    if not sys.platform.startswith("linux"):
        abort("kernel service containment is Linux-only")
    try:
        with open("/proc/self/cgroup", encoding="ascii") as stream:
            unified = [
                line.rstrip("\n").split(":", 2)[2]
                for line in stream
                if line.startswith("0::")
            ]
        with open("/proc/self/mountinfo", encoding="utf-8") as stream:
            mount_lines = list(stream)
    except OSError as error:
        abort(f"cannot inspect cgroup v2: {error}")
    if len(unified) != 1 or not unified[0].startswith("/"):
        abort("a unique unified cgroup is unavailable")
    cgroup_path = os.path.normpath(unified[0])
    candidates = []
    for line in mount_lines:
        try:
            before, after = line.rstrip("\n").split(" - ", 1)
        except ValueError:
            continue
        post = after.split()
        fields = before.split()
        if not post or post[0] != "cgroup2" or len(fields) < 5:
            continue
        mount_root = os.path.normpath(decode_mount_field(fields[3]))
        mount_point = os.path.normpath(decode_mount_field(fields[4]))
        if cgroup_path == mount_root:
            suffix = ""
        elif cgroup_path.startswith(mount_root.rstrip("/") + "/"):
            suffix = cgroup_path[len(mount_root):].lstrip("/")
        else:
            continue
        candidate = os.path.normpath(os.path.join(mount_point, suffix))
        try:
            if os.path.commonpath((mount_point, candidate)) != mount_point:
                continue
        except ValueError:
            continue
        candidates.append((len(mount_root), candidate))
    if not candidates:
        abort("the unified cgroup v2 mount is unavailable")
    return max(candidates)[1]


def encode_receipt(value):
    data = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return "cg1:" + base64.urlsafe_b64encode(data).decode().rstrip("=")


def decode_receipt(serialized):
    if not re.fullmatch(r"cg1:[A-Za-z0-9_-]+", serialized):
        abort("malformed service containment receipt")
    encoded = serialized[4:]
    try:
        raw = base64.b64decode(
            encoded + "=" * (-len(encoded) % 4),
            altchars=b"-_",
            validate=True,
        )
        value = json.loads(raw)
    except (ValueError, UnicodeError, json.JSONDecodeError) as error:
        abort(f"malformed service containment receipt: {error}")
    expected = {
        "child_dev",
        "child_ino",
        "child_mode",
        "child_uid",
        "name",
        "parent",
        "parent_dev",
        "parent_ino",
        "parent_uid",
    }
    if not isinstance(value, dict) or set(value) != expected:
        abort("malformed service containment fields")
    if not isinstance(value["parent"], str) \
            or not os.path.isabs(value["parent"]):
        abort("unsafe service containment parent")
    if not isinstance(value["name"], str) or not re.fullmatch(
        r"hi-odysseus-[1-9][0-9]*-[0-9a-f]{24}", value["name"]
    ):
        abort("unsafe service containment name")
    for key in expected - {"parent", "name"}:
        if not isinstance(value[key], int) or value[key] < 0:
            abort("invalid service containment metadata")
    return value


directory_flags = os.O_RDONLY | os.O_DIRECTORY \
    | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)


def open_verified(serialized):
    value = decode_receipt(serialized)
    try:
        parent_fd = os.open(value["parent"], directory_flags)
        child_fd = os.open(value["name"], directory_flags, dir_fd=parent_fd)
    except OSError as error:
        abort(f"cannot open service containment: {error}")
    try:
        parent = os.fstat(parent_fd)
        child = os.fstat(child_fd)
        if not stat.S_ISDIR(parent.st_mode) or (
            parent.st_dev,
            parent.st_ino,
            parent.st_uid,
        ) != (
            value["parent_dev"],
            value["parent_ino"],
            value["parent_uid"],
        ):
            abort("service containment parent identity changed")
        if not stat.S_ISDIR(child.st_mode) or (
            child.st_dev,
            child.st_ino,
            child.st_uid,
            stat.S_IMODE(child.st_mode),
        ) != (
            value["child_dev"],
            value["child_ino"],
            value["child_uid"],
            value["child_mode"],
        ):
            abort("service containment identity changed")
        for required in ("cgroup.events", "cgroup.kill", "cgroup.procs"):
            metadata = os.stat(
                required, dir_fd=child_fd, follow_symlinks=False
            )
            if not stat.S_ISREG(metadata.st_mode):
                abort("service containment control is not a regular file")
    except BaseException:
        os.close(child_fd)
        os.close(parent_fd)
        raise
    return value, parent_fd, child_fd


def read_control(child_fd, name, maximum=4096):
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) \
        | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, dir_fd=child_fd)
    try:
        data = os.read(descriptor, maximum + 1)
        if len(data) > maximum:
            abort(f"oversized {name} control response")
        return data
    finally:
        os.close(descriptor)


def write_control(child_fd, name, data):
    flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0) \
        | getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(name, flags, dir_fd=child_fd)
    try:
        if os.write(descriptor, data) != len(data):
            abort(f"short write to {name}")
    finally:
        os.close(descriptor)


def populated(child_fd):
    data = read_control(child_fd, "cgroup.events")
    values = {}
    try:
        for line in data.decode("ascii").splitlines():
            key, value = line.split()
            values[key] = value
    except (UnicodeError, ValueError):
        abort("malformed cgroup.events")
    if values.get("populated") not in {"0", "1"}:
        abort("cgroup.events omitted populated state")
    return values["populated"] == "1"


operation, serialized, pid_text = sys.argv[1:]
if operation == "create":
    parent_path = current_cgroup_parent()
    parent_fd = child_fd = -1
    name = f"hi-odysseus-{os.getpid()}-{secrets.token_hex(12)}"
    created = False
    try:
        parent_fd = os.open(parent_path, directory_flags)
        parent = os.fstat(parent_fd)
        if not stat.S_ISDIR(parent.st_mode):
            abort("service containment parent is not a directory")
        os.mkdir(name, 0o700, dir_fd=parent_fd)
        created = True
        child_fd = os.open(name, directory_flags, dir_fd=parent_fd)
        child = os.fstat(child_fd)
        if not stat.S_ISDIR(child.st_mode) or child.st_uid != os.geteuid():
            abort("created service containment has unsafe ownership")
        for required in ("cgroup.events", "cgroup.kill", "cgroup.procs"):
            metadata = os.stat(
                required, dir_fd=child_fd, follow_symlinks=False
            )
            if not stat.S_ISREG(metadata.st_mode):
                abort("required cgroup v2 control is unavailable")
        print(
            encode_receipt(
                {
                    "parent": parent_path,
                    "parent_dev": parent.st_dev,
                    "parent_ino": parent.st_ino,
                    "parent_uid": parent.st_uid,
                    "name": name,
                    "child_dev": child.st_dev,
                    "child_ino": child.st_ino,
                    "child_uid": child.st_uid,
                    "child_mode": stat.S_IMODE(child.st_mode),
                }
            )
        )
    except BaseException as error:
        if child_fd >= 0:
            os.close(child_fd)
            child_fd = -1
        if created and parent_fd >= 0:
            try:
                quarantine = f".{name}.cleanup-{secrets.token_hex(16)}"
                os.rename(
                    name,
                    quarantine,
                    src_dir_fd=parent_fd,
                    dst_dir_fd=parent_fd,
                )
                print(
                    "ERROR: failed service containment retained for operator "
                    f"recovery at {os.path.join(parent_path, quarantine)}",
                    file=sys.stderr,
                )
            except OSError as cleanup_error:
                print(
                    "ERROR: failed service containment could not be safely "
                    f"quarantined: {cleanup_error}",
                    file=sys.stderr,
                )
        if isinstance(error, OSError):
            abort(f"cannot create delegated service containment: {error}")
        raise
    finally:
        if child_fd >= 0:
            os.close(child_fd)
        if parent_fd >= 0:
            os.close(parent_fd)
    raise SystemExit(0)

value, parent_fd, child_fd = open_verified(serialized)
try:
    if operation == "join":
        try:
            pid = int(pid_text)
        except ValueError:
            abort("invalid service containment process id")
        if pid <= 0 or pid != os.getppid():
            abort("only the direct service launcher may enter containment")
        write_control(child_fd, "cgroup.procs", str(pid).encode("ascii"))
        members = read_control(child_fd, "cgroup.procs", 1024 * 1024)
        if str(pid).encode("ascii") not in members.splitlines():
            abort("service launcher did not enter its containment")
    elif operation == "contains":
        try:
            pid = int(pid_text)
        except ValueError:
            abort("invalid service containment process id")
        members = read_control(child_fd, "cgroup.procs", 1024 * 1024)
        raise SystemExit(
            0 if str(pid).encode("ascii") in members.splitlines() else 1
        )
    elif operation == "state":
        raise SystemExit(0 if populated(child_fd) else 1)
    elif operation == "kill":
        if populated(child_fd):
            write_control(child_fd, "cgroup.kill", b"1")
    elif operation == "remove":
        if populated(child_fd):
            abort("refusing to remove populated service containment")
        quarantine = (
            f".{value['name']}.cleanup-{secrets.token_hex(16)}"
        )
        try:
            os.stat(quarantine, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort("service containment quarantine name already exists")
        os.rename(
            value["name"],
            quarantine,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        recovery_path = os.path.join(value["parent"], quarantine)
        try:
            quarantine_fd = os.open(
                quarantine, directory_flags, dir_fd=parent_fd
            )
        except OSError as error:
            abort(
                "cannot open quarantined service containment; retained for "
                f"operator recovery at {recovery_path}: {error}"
            )
        try:
            quarantined = os.fstat(quarantine_fd)
            if (
                quarantined.st_dev,
                quarantined.st_ino,
                quarantined.st_uid,
                stat.S_IMODE(quarantined.st_mode),
            ) != (
                value["child_dev"],
                value["child_ino"],
                value["child_uid"],
                value["child_mode"],
            ) or not stat.S_ISDIR(quarantined.st_mode):
                abort(
                    "quarantined service containment identity changed; "
                    f"retained for operator recovery at {recovery_path}"
                )
        finally:
            os.close(quarantine_fd)
        try:
            os.stat(value["name"], dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort(
                "same-name service containment replacement preserved; "
                "bound quarantine retained for operator recovery at "
                f"{recovery_path}"
            )
        abort(
            "exact inode-bound deletion is unavailable; service containment "
            "retained for operator recovery at "
            f"{recovery_path}"
        )
    else:
        abort("unknown service containment operation")
finally:
    if child_fd >= 0:
        os.close(child_fd)
    os.close(parent_fd)
PY
}

_prepare_service_containment() {
    local receipt
    PENDING_SERVICE_CONTAINMENT=""
    if ! receipt=$(_service_containment_op create); then
        echo "ERROR: delegated cgroup v2 containment is unavailable" >&2
        return 1
    fi
    [[ "$receipt" =~ ^cg1:[A-Za-z0-9_-]+$ ]] || return 1
    PENDING_SERVICE_CONTAINMENT="$receipt"
}

_join_service_containment() {
    _service_containment_op join "$1" "$2"
}

_service_containment_contains() {
    _service_containment_op contains "$1" "$2" >/dev/null 2>&1
}

_service_containment_state() {
    _service_containment_op state "$1" >/dev/null 2>&1
}

_kill_service_containment() {
    _service_containment_op kill "$1"
}

_remove_service_containment() {
    _service_containment_op remove "$1"
}

_wait_for_service_containment_member() {
    local receipt="$1" pid="$2" identity_status
    for _ in $(seq 1 50); do
        _service_containment_contains "$receipt" "$pid" && return 0
        if _process_identity_status "$pid" \
            "${REGISTERED_PROCESS_IDENTITY:-}" \
            "${REGISTERED_PROCESS_OWNER:-}"; then
            :
        else
            identity_status=$?
            [ "$identity_status" -eq 1 ] && return 1
            [ "$identity_status" -eq 2 ] && return 1
        fi
        /bin/sleep 0.01 || return 1
    done
    return 1
}

_extinguish_service_containment() {
    local receipt="$1" containment_status
    if _service_containment_state "$receipt"; then
        _kill_service_containment "$receipt" || return 1
        for _ in $(seq 1 50); do
            if _service_containment_state "$receipt"; then
                /bin/sleep 0.1 || return 1
            else
                containment_status=$?
                [ "$containment_status" -eq 1 ] && break
                return 1
            fi
        done
    else
        containment_status=$?
        [ "$containment_status" -eq 1 ] || return 1
    fi
    if _service_containment_state "$receipt"; then
        echo "ERROR: service containment remains populated" >&2
        return 1
    else
        containment_status=$?
        [ "$containment_status" -eq 1 ] || return 1
    fi
}

_retire_service_containment() {
    _extinguish_service_containment "$1" \
        && _remove_service_containment "$1"
}

_kill_registered_service_tree() {
    local pid="$1" identity="$2" owner="$3" index containment
    _sync_process_receipts || return 1
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        if [ "${_BG_PIDS[$index]}" = "$pid" ] \
            && [ "${_BG_PID_IDENTITIES[$index]}" = "$identity" ] \
            && [ "${_BG_PID_OWNERS[$index]}" = "$owner" ]; then
            containment="${_BG_PROCESS_CONTAINMENTS[$index]:-}"
            [ -z "$containment" ] && return 0
            _extinguish_service_containment "$containment"
            return
        fi
    done
    echo "ERROR: registered service containment receipt is unavailable" >&2
    return 1
}

# Register a PID for cleanup on exit
register_pid() {
    local pid="${1:-}" containment="${2:-}"
    local receipt identity parent_pid extra record
    local current_shell_pid="${BASHPID:-$$}"
    if ! _valid_pid "$pid"; then
        echo "ERROR: refusing to register an invalid process id" >&2
        return 2
    fi
    if ! receipt=$(_process_receipt "$pid"); then
        echo "ERROR: refusing to register process $pid without an immutable identity" >&2
        return 1
    fi
    IFS='|' read -r identity parent_pid extra <<< "$receipt"
    if ! [[ "$identity" =~ ^[A-Za-z0-9._:-]+$ ]] \
        || [ -n "${extra:-}" ] || [ "$parent_pid" != "$current_shell_pid" ]; then
        echo "ERROR: refusing to register process $pid because it is not a direct child" >&2
        return 1
    fi
    # Publish the validated direct-child identity before reading shared state.
    # A corrupt/unavailable receipt store must not make safe rollback impossible.
    REGISTERED_PROCESS_IDENTITY="$identity"
    REGISTERED_PROCESS_OWNER="$current_shell_pid"
    if [ -n "$containment" ]; then
        if ! [[ "$containment" =~ ^cg1:[A-Za-z0-9_-]+$ ]] \
            || ! _wait_for_service_containment_member "$containment" "$pid"; then
            echo "ERROR: service process $pid did not enter its bound containment" >&2
            return 1
        fi
    fi
    _ensure_process_receipt_store || return 1
    record="$pid|$identity|$current_shell_pid|$containment"$'\n'
    _process_receipt_store_op add "$record" || return 1
    if ! _sync_process_receipts; then
        if ! _process_receipt_store_op drop "$record" >/dev/null 2>&1; then
            echo "ERROR: could not roll back the failed process receipt" >&2
        fi
        return 1
    fi
}

_retire_unregistered_child() {
    local pid="$1" identity="$2" owner="$3" identity_status signal_status
    local containment="${4:-}" wait_status
    if ! _valid_pid "$pid" || ! _valid_pid "$owner" \
        || ! [[ "$identity" =~ ^[A-Za-z0-9._:-]+$ ]]; then
        echo "ERROR: cannot retire a child without its validated identity" >&2
        return 1
    fi
    if _process_identity_status "$pid" "$identity" "$owner"; then
        if _signal_bound_process "$pid" "$identity" "$owner" -TERM; then
            :
        else
            signal_status=$?
            if [ "$signal_status" -ne 1 ] && [ "$signal_status" -ne 2 ]; then
                return 1
            fi
        fi
    else
        identity_status=$?
        [ "$identity_status" -eq 1 ] || return 1
    fi
    for _ in $(seq 1 10); do
        if _process_identity_status "$pid" "$identity"; then
            /bin/sleep 0.1 || return 1
        else
            identity_status=$?
            [ "$identity_status" -eq 1 ] && break
            return 1
        fi
    done
    if _process_identity_status "$pid" "$identity"; then
        if _signal_bound_process "$pid" "$identity" "$owner" -KILL; then
            :
        else
            signal_status=$?
            [ "$signal_status" -eq 1 ] || return 1
        fi
        for _ in $(seq 1 10); do
            if _process_identity_status "$pid" "$identity"; then
                /bin/sleep 0.1 || return 1
            else
                identity_status=$?
                [ "$identity_status" -eq 1 ] && break
                return 1
            fi
        done
    fi
    if _process_identity_status "$pid" "$identity"; then
        echo "ERROR: unregistered child $pid remains alive" >&2
        return 1
    else
        identity_status=$?
        [ "$identity_status" -eq 1 ] || return 1
    fi
    if [ "$owner" = "${BASHPID:-$$}" ]; then
        if builtin wait "$pid" 2>/dev/null; then
            wait_status=0
        else
            wait_status=$?
        fi
        if [ "$wait_status" -eq 127 ]; then
            echo "ERROR: could not reap unregistered child $pid" >&2
            return 1
        fi
    fi
    if [ -n "$containment" ] \
        && ! _retire_service_containment "$containment"; then
        echo "ERROR: unregistered child containment remains live" >&2
        return 1
    fi
}

_rollback_failed_child_registration() {
    local pid="$1" service="$2" containment="${3:-}"
    local identity="${REGISTERED_PROCESS_IDENTITY:-}"
    local owner="${REGISTERED_PROCESS_OWNER:-}"
    if [ -z "$identity" ] || [ -z "$owner" ]; then
        if [ -n "$containment" ] \
            && _retire_service_containment "$containment"; then
            if ! builtin wait "$pid" 2>/dev/null; then :; fi
            return 0
        fi
        echo "ERROR: $service registration failed before identity publication" >&2
        return 1
    fi
    if ! _retire_unregistered_child \
        "$pid" "$identity" "$owner" "$containment"; then
        printf 'ERROR: retained unregistered %s child evidence: pid=%s identity=%s owner=%s\n' \
            "$service" "$pid" "$identity" "$owner" >&2
        return 1
    fi
}

unregister_pid() {
    local pid="${1:-}" expected_identity="${2:-}" index removed=0
    local containment="" containment_status owner="" record
    _valid_pid "$pid" || return 2
    [[ "$expected_identity" =~ ^[A-Za-z0-9._:-]+$ ]] || return 2
    _sync_process_receipts || return 1
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        if [ "${_BG_PIDS[$index]}" = "$pid" ] \
            && [ "${_BG_PID_IDENTITIES[$index]}" = "$expected_identity" ]; then
            removed=1
            containment="${_BG_PROCESS_CONTAINMENTS[$index]:-}"
            owner="${_BG_PID_OWNERS[$index]}"
            continue
        fi
    done
    [ "$removed" -eq 1 ] || return 1
    if [ -n "$containment" ]; then
        if _service_containment_state "$containment"; then
            echo "ERROR: refusing to unregister a populated service containment" >&2
            return 1
        else
            containment_status=$?
            [ "$containment_status" -eq 1 ] || return 1
        fi
        _remove_service_containment "$containment" || return 1
    fi
    record="$pid|$expected_identity|$owner|$containment"$'\n'
    _process_receipt_store_op drop "$record" || return 1
    _sync_process_receipts
}

# Kill all registered PIDs (SIGTERM first, SIGKILL after 5s).
# Each helper is explicit about "process not running" being expected, and
# escalates a real (unexpected) kill failure to stderr instead of swallowing it.
_kill_if_alive() {
    local pid="$1" identity="$2" sig="$3" owner="${4:-${BASHPID:-$$}}"
    local identity_status signal_status
    if ! _valid_pid "$pid"; then
        echo "ERROR: refusing to signal invalid process id: ${pid:-<empty>}" >&2
        return 2
    fi
    if _process_identity_status "$pid" "$identity"; then
        :
    else
        identity_status=$?
        [ "$identity_status" -eq 1 ] && return 0
        echo "ERROR: could not verify process identity for $pid" >&2
        return 1
    fi
    if _signal_bound_process "$pid" "$identity" "$owner" "$sig"; then
        return 0
    else
        signal_status=$?
    fi
    if [ "$signal_status" -eq 1 ]; then
        return 0
    fi
    echo "ERROR: bound signal $sig for process $pid failed" >&2
    return 1
}

cleanup_pids() {
    local pid identity owner containment identity_status wait_status index
    local cleanup_failed=0 store_bound=0 record
    local any_live=0
    local -a remaining_pids=() remaining_identities=() remaining_owners=()
    local -a remaining_containments=()
    local -a receipt_failed=() original_containments=()
    [ -n "$PROCESS_RECEIPT_STORAGE_RECEIPT" ] && store_bound=1
    _sync_process_receipts || return 1
    if [ "${#_BG_PIDS[@]}" -eq 0 ]; then
        return 0
    fi
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        original_containments[index]="${_BG_PROCESS_CONTAINMENTS[$index]:-}"
    done
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        pid="${_BG_PIDS[$index]}"
        identity="${_BG_PID_IDENTITIES[$index]:-}"
        owner="${_BG_PID_OWNERS[$index]:-}"
        containment="${_BG_PROCESS_CONTAINMENTS[$index]:-}"
        if [ -z "$identity" ] || ! _valid_pid "$owner"; then
            receipt_failed[index]=1
            cleanup_failed=1
            continue
        fi
        if _process_identity_status "$pid" "$identity"; then
            any_live=1
            if ! _kill_if_alive "$pid" "$identity" -TERM "$owner"; then
                receipt_failed[index]=1
                cleanup_failed=1
            fi
        else
            identity_status=$?
            if [ "$identity_status" -ne 1 ]; then
                receipt_failed[index]=1
                cleanup_failed=1
            fi
        fi
    done
    if [ "$any_live" -eq 1 ] && ! sleep 5; then
        echo "ERROR: interrupted while waiting for processes to stop" >&2
        cleanup_failed=1
    fi
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        pid="${_BG_PIDS[$index]}"
        identity="${_BG_PID_IDENTITIES[$index]:-}"
        owner="${_BG_PID_OWNERS[$index]:-}"
        containment="${_BG_PROCESS_CONTAINMENTS[$index]:-}"
        if [ "${receipt_failed[$index]:-0}" -ne 0 ] \
            && [ -z "$containment" ]; then
            continue
        fi
        if ! _valid_pid "$pid"; then
            receipt_failed[index]=1
            cleanup_failed=1
            continue
        fi
        if [ "${receipt_failed[$index]:-0}" -eq 0 ]; then
            if _process_identity_status "$pid" "$identity"; then
                if ! _kill_if_alive "$pid" "$identity" -KILL "$owner"; then
                    receipt_failed[index]=1
                    cleanup_failed=1
                fi
            else
                identity_status=$?
                if [ "$identity_status" -ne 1 ]; then
                    receipt_failed[index]=1
                    cleanup_failed=1
                fi
            fi
        fi
        if [ -n "$containment" ]; then
            if _retire_service_containment "$containment"; then
                _BG_PROCESS_CONTAINMENTS[index]=""
            else
                echo "ERROR: could not retire service containment for $pid" >&2
                receipt_failed[index]=1
                cleanup_failed=1
                continue
            fi
        fi
        if [ "$owner" = "${BASHPID:-$$}" ]; then
            if wait "$pid" 2>/dev/null; then
                wait_status=0
            else
                wait_status=$?
            fi
            if [ "$wait_status" -eq 127 ]; then
                echo "ERROR: could not reap registered child $pid" >&2
                receipt_failed[index]=1
                cleanup_failed=1
            fi
        fi
        if [ -z "${_BG_PROCESS_CONTAINMENTS[$index]:-}" ]; then
            if _process_identity_status "$pid" "$identity"; then
                receipt_failed[index]=1
                cleanup_failed=1
            else
                identity_status=$?
                if [ "$identity_status" -eq 1 ]; then
                    receipt_failed[index]=0
                else
                    receipt_failed[index]=1
                    cleanup_failed=1
                fi
            fi
        fi
    done

    # Retain every receipt whose extinction cannot be established. Callers
    # need this state for diagnosis and a later cleanup attempt.
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        pid="${_BG_PIDS[$index]}"
        identity="${_BG_PID_IDENTITIES[$index]:-}"
        owner="${_BG_PID_OWNERS[$index]:-}"
        containment="${_BG_PROCESS_CONTAINMENTS[$index]:-}"
        if ! _valid_pid "$pid"; then
            remaining_pids+=("$pid")
            remaining_identities+=("$identity")
            remaining_owners+=("$owner")
            remaining_containments+=("$containment")
            cleanup_failed=1
        elif [ "${receipt_failed[$index]:-0}" -ne 0 ]; then
            remaining_pids+=("$pid")
            remaining_identities+=("$identity")
            remaining_owners+=("$owner")
            remaining_containments+=("$containment")
        elif _process_identity_status "$pid" "$identity"; then
            echo "ERROR: process $pid remains alive after cleanup" >&2
            remaining_pids+=("$pid")
            remaining_identities+=("$identity")
            remaining_owners+=("$owner")
            remaining_containments+=("$containment")
            cleanup_failed=1
        else
            identity_status=$?
            if [ "$identity_status" -ne 1 ]; then
                remaining_pids+=("$pid")
                remaining_identities+=("$identity")
                remaining_owners+=("$owner")
                remaining_containments+=("$containment")
                cleanup_failed=1
            fi
        fi
    done
    if [ "$store_bound" -eq 1 ]; then
        for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
            [ "${receipt_failed[$index]:-0}" -eq 0 ] || continue
            record="${_BG_PIDS[$index]}|${_BG_PID_IDENTITIES[$index]}|"
            record+="${_BG_PID_OWNERS[$index]}|"
            record+="${original_containments[$index]:-}"$'\n'
            if ! _process_receipt_store_op drop "$record"; then
                echo "ERROR: could not retire exact process cleanup receipt" >&2
                cleanup_failed=1
            fi
        done
        _sync_process_receipts || return 1
    elif [ "${#remaining_pids[@]}" -eq 0 ]; then
        # Bash 3.2 treats an empty-array expansion as an unset variable under
        # `set -u`, even when the array was explicitly initialized.
        _BG_PIDS=()
        _BG_PID_IDENTITIES=()
        _BG_PID_OWNERS=()
        _BG_PROCESS_CONTAINMENTS=()
        _persist_process_receipts || return 1
    else
        _BG_PIDS=("${remaining_pids[@]}")
        _BG_PID_IDENTITIES=("${remaining_identities[@]}")
        _BG_PID_OWNERS=("${remaining_owners[@]}")
        _BG_PROCESS_CONTAINMENTS=("${remaining_containments[@]}")
        if ! _persist_process_receipts; then
            echo "ERROR: could not persist process cleanup receipts" >&2
            return 1
        fi
    fi
    [ "$cleanup_failed" -eq 0 ]
}

# Wait until a TCP port is accepting connections
wait_for_port() {
    local port="$1" max="${2:-30}" name="${3:-service}"
    local attempt
    for ((attempt = 1; attempt <= max; attempt++)); do
        (echo >/dev/tcp/127.0.0.1/"$port") 2>/dev/null && return 0
        sleep 1
    done
    echo "  TIMEOUT: $name did not listen on port $port after ${max}s" >&2
    return 1
}

# ─── NATS Server ─────────────────────────────────────────────────────────────

NATS_PORT="${NATS_PORT:-14222}"
NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-18222}"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
NATS_DATA_PARENT_FD=193
NATS_DATA_FD=194

_nats_data_fds_are_available() {
    ! (: <&193) 2>/dev/null && ! (: <&194) 2>/dev/null
}

_close_nats_data_fds() {
    if ! { exec 194<&-; } 2>/dev/null; then :; fi
    if ! { exec 193<&-; } 2>/dev/null; then :; fi
}

# Background services are outside the harness trust boundary. Bind the selected
# executable before containment hooks can run, and give the final process only
# its explicit runtime variables.
SERVICE_EXECUTABLE_RECEIPT=""

_close_service_executable_fd() {
    if ! { exec 197<&-; } 2>/dev/null; then :; fi
    SERVICE_EXECUTABLE_RECEIPT=""
}

_bind_service_executable() {
    local binary="$1" receipt
    _ensure_bound_runtime_tools || return 1
    case "$binary" in
        /*) ;;
        *) echo "ERROR: service executable must be absolute" >&2; return 1 ;;
    esac
    if (: <&197) 2>/dev/null; then
        echo "ERROR: reserved service executable descriptor is unavailable" >&2
        return 1
    fi
    if ! exec 197< "$binary"; then
        echo "ERROR: cannot open the service executable" >&2
        return 1
    fi
    if ! receipt=$(_run_bound_python - "$binary" "$SERVICE_EXECUTABLE_FD" <<'PY'
import hashlib
import os
import stat
import sys


path = sys.argv[1]
descriptor = int(sys.argv[2])
if not os.path.isabs(path):
    raise SystemExit(1)
opened = os.fstat(descriptor)
named = os.stat(path, follow_symlinks=False)
identity = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_uid,
    stat.S_IMODE(value.st_mode),
    value.st_nlink,
    value.st_size,
    value.st_mtime_ns,
    value.st_ctime_ns,
)
if identity(opened) != identity(named) \
        or not stat.S_ISREG(opened.st_mode) \
        or opened.st_nlink != 1 \
        or stat.S_IMODE(opened.st_mode) & 0o111 == 0 \
        or opened.st_size > 512 * 1024 * 1024:
    raise SystemExit(1)
digest = hashlib.sha256()
offset = 0
while offset < opened.st_size:
    chunk = os.pread(descriptor, min(1024 * 1024, opened.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    digest.update(chunk)
    offset += len(chunk)
after = os.fstat(descriptor)
current = os.stat(path, follow_symlinks=False)
if identity(after) != identity(opened) or identity(current) != identity(opened):
    raise SystemExit(1)
print(
    "svc1:"
    + ":".join(str(value) for value in identity(opened))
    + ":"
    + digest.hexdigest()
)
PY
    ); then
        _close_service_executable_fd
        echo "ERROR: service executable could not be bound safely" >&2
        return 1
    fi
    SERVICE_EXECUTABLE_RECEIPT="$receipt"
    export SERVICE_EXECUTABLE_FD SERVICE_EXECUTABLE_RECEIPT
}

_exec_service_without_harness_capabilities() {
    local binary="$1" receipt="$2"
    shift 2
    _exec_bound_python - "$binary" "$receipt" "$SERVICE_EXECUTABLE_FD" "$@" <<'PY'
import fcntl
import hashlib
import os
import re
import resource
import stat
import sys


binary, serialized, descriptor_text, *names = sys.argv[1:]


def close_nonstdio_descriptors(allowed):
    allowed = {0, 1, 2, *allowed}
    if sys.platform.startswith("linux"):
        try:
            descriptors = tuple(
                int(name)
                for name in os.listdir("/proc/self/fd")
                if name.isdecimal()
            )
        except OSError:
            raise SystemExit(1)
        for inherited in descriptors:
            if inherited in allowed:
                continue
            try:
                os.close(inherited)
            except OSError:
                pass
        return
    soft_limit, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
    if soft_limit == resource.RLIM_INFINITY:
        soft_limit = os.sysconf("SC_OPEN_MAX")
    if not isinstance(soft_limit, int) or soft_limit < 3:
        raise SystemExit(1)
    cursor = 3
    for retained in sorted(value for value in allowed if value >= 3):
        os.closerange(cursor, retained)
        cursor = retained + 1
    os.closerange(cursor, soft_limit)


fields = serialized.split(":")
if len(fields) != 10 or fields[0] != "svc1":
    raise SystemExit(1)
try:
    descriptor = int(descriptor_text)
    expected = tuple(int(value) for value in fields[1:9])
except ValueError:
    raise SystemExit(1)
expected_digest = fields[9]
if not re.fullmatch(r"[0-9a-f]{64}", expected_digest):
    raise SystemExit(1)
opened = os.fstat(descriptor)
identity = (
    opened.st_dev,
    opened.st_ino,
    opened.st_uid,
    stat.S_IMODE(opened.st_mode),
    opened.st_nlink,
    opened.st_size,
    opened.st_mtime_ns,
    opened.st_ctime_ns,
)
# A rename can change ctime without changing the selected object or bytes.
# Linux executes a sealed copy whose digest must match the binding receipt.
linux_snapshot = sys.platform.startswith("linux")
same_identity = identity[:-1] == expected[:-1] if linux_snapshot else identity == expected
if not same_identity \
        or not stat.S_ISREG(opened.st_mode) \
        or opened.st_nlink != 1 \
        or stat.S_IMODE(opened.st_mode) & 0o111 == 0 \
        or opened.st_size > 512 * 1024 * 1024:
    raise SystemExit(1)
snapshot = None
if linux_snapshot:
    snapshot = os.memfd_create(
        "odysseus-service", os.MFD_CLOEXEC | os.MFD_ALLOW_SEALING
    )
    os.fchmod(snapshot, 0o500)
digest = hashlib.sha256()
offset = 0
while offset < opened.st_size:
    chunk = os.pread(descriptor, min(1024 * 1024, opened.st_size - offset), offset)
    if not chunk:
        raise SystemExit(1)
    digest.update(chunk)
    if snapshot is not None:
        pending = memoryview(chunk)
        while pending:
            written = os.write(snapshot, pending)
            if written <= 0:
                raise SystemExit(1)
            pending = pending[written:]
    offset += len(chunk)
if digest.hexdigest() != expected_digest or os.fstat(descriptor) != opened:
    raise SystemExit(1)
if snapshot is not None:
    seals = (
        fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW
        | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
    )
    fcntl.fcntl(snapshot, fcntl.F_ADD_SEALS, seals)
    if fcntl.fcntl(snapshot, fcntl.F_GET_SEALS) & seals != seals:
        raise SystemExit(1)
    os.lseek(snapshot, 0, os.SEEK_SET)
    os.dup2(snapshot, descriptor, inheritable=True)
    os.close(snapshot)
allowed = {
    "AGAMEMNON_API_KEY",
    "MYRMIDON_WORK_DELAY_MS",
    "NATS_URL",
    "PORT",
}
if len(names) != len(set(names)) or any(name not in allowed for name in names):
    raise SystemExit(1)
environment = {}
for name in names:
    if name not in os.environ:
        raise SystemExit(1)
    environment[name] = os.environ[name]
os.set_inheritable(descriptor, True)
close_nonstdio_descriptors({descriptor})
arguments = [binary]
if linux_snapshot:
    if not os.path.isdir("/proc/self/fd"):
        raise SystemExit(1)
    os.execve(f"/proc/self/fd/{descriptor}", arguments, environment)
named = os.stat(binary, follow_symlinks=False)
named_identity = (
    named.st_dev,
    named.st_ino,
    named.st_uid,
    stat.S_IMODE(named.st_mode),
    named.st_nlink,
    named.st_size,
    named.st_mtime_ns,
    named.st_ctime_ns,
)
if named_identity != expected:
    raise SystemExit(1)
os.execve(binary, arguments, environment)
PY
}

_open_nats_data_fds() {
    local parent="${NATS_DATA_DIR%/*}"
    if ! _nats_data_fds_are_available; then
        echo "ERROR: reserved NATS storage descriptors are unavailable" >&2
        return 1
    fi
    if ! exec 193< "$parent"; then
        echo "ERROR: cannot open the NATS storage parent" >&2
        return 1
    fi
    if ! exec 194< "$NATS_DATA_DIR"; then
        exec 193<&-
        echo "ERROR: cannot open the NATS storage directory" >&2
        return 1
    fi
    export NATS_DATA_PARENT_FD NATS_DATA_FD
    if ! _resolve_bound_nats_data_dir >/dev/null; then
        _close_nats_data_fds
        return 1
    fi
}

_bind_nats_data_dir() {
    local candidate="$1" receipt receipt_version bound_parent bound_name
    local receipt_metadata
    if ! receipt=$(_run_bound_python - "$candidate" <<'PY'
import os
import re
import stat
import sys


def fd_mount_identity(file_descriptor):
    if sys.platform.startswith("linux"):
        try:
            with open(
                f"/proc/self/fdinfo/{file_descriptor}", encoding="ascii"
            ) as stream:
                for line in stream:
                    if line.startswith("mnt_id:"):
                        value = line.split(":", 1)[1].strip()
                        if value.isdigit():
                            return f"linux:{value}"
        except OSError as error:
            raise RuntimeError(f"mount identity unavailable: {error}") from error
        raise RuntimeError("mount identity unavailable")
    if sys.platform == "darwin":
        import ctypes
        import hashlib

        class Fsid(ctypes.Structure):
            _fields_ = [("values", ctypes.c_int32 * 2)]

        class Statfs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", Fsid),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32),
                ("f_reserved", ctypes.c_uint32 * 7),
            ]

        metadata = Statfs()
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.fstatfs(file_descriptor, ctypes.byref(metadata)) != 0:
            error_number = ctypes.get_errno()
            raise RuntimeError(os.strerror(error_number))
        payload = b"\0".join(
            (
                bytes(metadata.f_fstypename).split(b"\0", 1)[0],
                bytes(metadata.f_mntonname).split(b"\0", 1)[0],
                bytes(metadata.f_mntfromname).split(b"\0", 1)[0],
                str(tuple(metadata.f_fsid.values)).encode("ascii"),
            )
        )
        if not payload:
            raise RuntimeError("mount identity unavailable")
        return "darwin:" + hashlib.sha256(payload).hexdigest()
    raise RuntimeError(f"mount identity unavailable on {sys.platform}")

candidate = os.path.abspath(sys.argv[1])
parent = os.path.realpath(os.path.dirname(candidate))
name = os.path.basename(candidate)
if not re.fullmatch(r"hi-nats-[A-Za-z0-9]{6}", name):
    raise SystemExit("unsafe NATS storage name")
if "|" in parent or "\n" in parent or not os.path.isabs(parent):
    raise SystemExit("unsafe NATS storage parent")
path = os.path.join(parent, name)
metadata = os.lstat(path)
parent_metadata = os.lstat(parent)
mode = stat.S_IMODE(metadata.st_mode)
if not stat.S_ISDIR(metadata.st_mode) or stat.S_ISLNK(metadata.st_mode):
    raise SystemExit("NATS storage is not a no-follow directory")
if not stat.S_ISDIR(parent_metadata.st_mode) \
        or stat.S_ISLNK(parent_metadata.st_mode):
    raise SystemExit("NATS storage parent is not a no-follow directory")
if metadata.st_uid != os.geteuid() or mode != 0o700 or metadata.st_nlink != 2:
    raise SystemExit("NATS storage creation metadata is unsafe")
if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit("required no-follow directory controls are unavailable")
directory_flags = os.O_RDONLY | os.O_DIRECTORY \
    | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
try:
    parent_fd = os.open(parent, directory_flags)
    storage_fd = os.open(name, directory_flags, dir_fd=parent_fd)
    try:
        opened_parent = os.fstat(parent_fd)
        opened_storage = os.fstat(storage_fd)
        if (opened_parent.st_dev, opened_parent.st_ino) != (
            parent_metadata.st_dev,
            parent_metadata.st_ino,
        ):
            raise RuntimeError("NATS storage parent changed while binding")
        if (
            opened_storage.st_dev,
            opened_storage.st_ino,
            opened_storage.st_uid,
            stat.S_IMODE(opened_storage.st_mode),
            opened_storage.st_nlink,
        ) != (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_uid,
            mode,
            metadata.st_nlink,
        ):
            raise RuntimeError("NATS storage changed while binding")
        parent_mount = fd_mount_identity(parent_fd)
        storage_mount = fd_mount_identity(storage_fd)
    finally:
        os.close(storage_fd)
        os.close(parent_fd)
except (OSError, RuntimeError) as error:
    raise SystemExit(f"cannot bind NATS storage mount identity: {error}") from error
print(
    "|".join(
        (
            "v2",
            parent,
            name,
            str(parent_metadata.st_dev),
            str(parent_metadata.st_ino),
            parent_mount,
            str(metadata.st_dev),
            str(metadata.st_ino),
            str(metadata.st_uid),
            format(mode, "o"),
            str(metadata.st_nlink),
            storage_mount,
        )
    )
)
PY
    ); then
        echo "ERROR: could not bind NATS storage directory: $candidate" >&2
        return 1
    fi
    IFS='|' read -r receipt_version bound_parent bound_name receipt_metadata \
        <<< "$receipt"
    if [ "$receipt_version" != v2 ] || [ -z "$bound_parent" ] \
        || [ -z "$bound_name" ] || [ -z "$receipt_metadata" ]; then
        echo "ERROR: malformed NATS storage receipt" >&2
        return 1
    fi
    NATS_DATA_RECEIPT="$receipt"
    NATS_DATA_DIR="$bound_parent/$bound_name"
    export NATS_DATA_DIR NATS_DATA_RECEIPT
    _open_nats_data_fds
}

_create_nats_data_dir() {
    local canonical_parent candidate
    if ! canonical_parent=$(_run_bound_python - <<'PY'
import os
print(os.path.realpath("/tmp"))
PY
    ) || [ -z "$canonical_parent" ]; then
        echo "ERROR: could not resolve the canonical temporary parent" >&2
        return 1
    fi
    if ! candidate=$(mktemp -d "$canonical_parent/hi-nats-XXXXXX") \
        || [ ! -d "$candidate" ] || [ -L "$candidate" ]; then
        echo "ERROR: could not create NATS storage directory" >&2
        return 1
    fi
    NATS_DATA_DIR="$candidate"
    export NATS_DATA_DIR
    if ! _bind_nats_data_dir "$candidate"; then
        echo "ERROR: could not bind NATS storage; retained $candidate" >&2
        return 1
    fi
}

_resolve_bound_nats_data_dir() {
    if [ -z "${NATS_DATA_RECEIPT:-}" ] || [ -z "${NATS_DATA_DIR:-}" ]; then
        echo "ERROR: NATS storage has no immutable receipt" >&2
        return 1
    fi
    _run_bound_python - "$NATS_DATA_RECEIPT" "$NATS_DATA_DIR" \
        "$NATS_DATA_PARENT_FD" "$NATS_DATA_FD" <<'PY'
import os
import re
import stat
import sys


def abort(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def fd_mount_identity(file_descriptor):
    if sys.platform.startswith("linux"):
        try:
            with open(
                f"/proc/self/fdinfo/{file_descriptor}", encoding="ascii"
            ) as stream:
                for line in stream:
                    if line.startswith("mnt_id:"):
                        value = line.split(":", 1)[1].strip()
                        if value.isdigit():
                            return f"linux:{value}"
        except OSError as error:
            abort(f"mount identity unavailable: {error}")
        abort("mount identity unavailable")
    if sys.platform == "darwin":
        import ctypes
        import hashlib

        class Fsid(ctypes.Structure):
            _fields_ = [("values", ctypes.c_int32 * 2)]

        class Statfs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", Fsid),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32),
                ("f_reserved", ctypes.c_uint32 * 7),
            ]

        metadata = Statfs()
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.fstatfs(file_descriptor, ctypes.byref(metadata)) != 0:
            abort(f"mount identity unavailable: {os.strerror(ctypes.get_errno())}")
        payload = b"\0".join(
            (
                bytes(metadata.f_fstypename).split(b"\0", 1)[0],
                bytes(metadata.f_mntonname).split(b"\0", 1)[0],
                bytes(metadata.f_mntfromname).split(b"\0", 1)[0],
                str(tuple(metadata.f_fsid.values)).encode("ascii"),
            )
        )
        if not payload:
            abort("mount identity unavailable")
        return "darwin:" + hashlib.sha256(payload).hexdigest()
    abort(f"mount identity unavailable on {sys.platform}")


fields = sys.argv[1].split("|")
if len(fields) != 12 or fields[0] != "v2":
    abort("malformed NATS storage receipt")
(
    _,
    parent,
    name,
    parent_dev,
    parent_ino,
    parent_mount,
    device,
    inode,
    owner,
    mode,
    link_count,
    storage_mount,
) = fields
if not os.path.isabs(parent) or os.path.realpath(parent) != parent:
    abort("NATS storage parent is no longer canonical")
if not re.fullmatch(r"hi-nats-[A-Za-z0-9]{6}", name):
    abort("unsafe NATS storage receipt name")
bound_path = os.path.join(parent, name)
if sys.argv[2] != bound_path:
    abort("NATS storage path no longer matches its receipt")
try:
    parent_dev, parent_ino, device, inode, owner, link_count = map(
        int, (parent_dev, parent_ino, device, inode, owner, link_count)
    )
    mode = int(mode, 8)
except ValueError:
    abort("non-numeric NATS storage receipt metadata")

try:
    parent_fd, storage_fd = map(int, sys.argv[3:5])
except ValueError:
    abort("invalid NATS storage descriptors")
if min(parent_fd, storage_fd) < 3:
    abort("unsafe NATS storage descriptors")
try:
    try:
        parent_metadata = os.fstat(parent_fd)
        opened = os.fstat(storage_fd)
    except OSError as error:
        abort(f"cannot inspect bound NATS storage: {error}")
    if (parent_metadata.st_dev, parent_metadata.st_ino) != (
        parent_dev,
        parent_ino,
    ):
        abort("NATS storage parent identity changed")
    if fd_mount_identity(parent_fd) != parent_mount:
        abort("NATS storage parent mount identity changed")
    opened_mode = stat.S_IMODE(opened.st_mode)
    if not stat.S_ISDIR(opened.st_mode) \
            or (opened.st_dev, opened.st_ino, opened.st_uid, opened_mode) != (
                device,
                inode,
                owner,
                mode,
            ) \
            or opened.st_nlink < link_count:
        abort("NATS storage descriptor identity changed")
    if fd_mount_identity(storage_fd) != storage_mount:
        abort("NATS storage mount identity changed")
finally:
    pass
print(bound_path)
PY
}

_nats_port_is_open() {
    (echo >/dev/tcp/127.0.0.1/"$1") 2>/dev/null
}

_nats_health_for_port() {
    local timeout="${2:-2}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 2
    _run_bound_curl_bounded "$timeout" -sf \
        "http://127.0.0.1:$1/healthz" >/dev/null 2>&1
}

_nats_monitor_identity_for_port() {
    local timeout="${2:-2}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 2
    (
        set -o pipefail
        _run_bound_curl_bounded "$timeout" --silent --show-error --fail \
            --write-out '\n%{http_code}' \
            "http://127.0.0.1:$1/varz" 2>/dev/null \
            | _run_bound_python -c '
import json
import re
import sys

maximum_body = 1024 * 1024
raw = sys.stdin.buffer.read(maximum_body + 5)
if len(raw) > maximum_body + 4 or len(raw) < 4 \
        or raw[-4:] != b"\n200":
    raise SystemExit(1)
try:
    value = json.loads(raw[:-4]).get("server_name")
except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
    raise SystemExit(1)
if not isinstance(value, str) \
        or not re.fullmatch(r"odysseus-e2e-[0-9a-f]{32}", value):
    raise SystemExit(1)
print(value)
' 2>/dev/null
    )
}

_nats_monitor_owned_by_process() {
    local monitor_port="$1" pid="$2" timeout="${3:-2}"
    _run_bound_python - "$monitor_port" "$pid" "$timeout" <<'PY'
import os
import re
import subprocess
import sys


try:
    port = int(sys.argv[1])
    pid = int(sys.argv[2])
    timeout = int(sys.argv[3])
except ValueError:
    raise SystemExit(2)
if not 1 <= port <= 65535 or pid <= 0 or timeout <= 0:
    raise SystemExit(2)

if sys.platform.startswith("linux"):
    socket_inodes = set()
    for table, expected_address in (
        ("/proc/net/tcp", "0100007F"),
        ("/proc/net/tcp6", "00000000000000000000000001000000"),
    ):
        try:
            with open(table, encoding="ascii") as stream:
                next(stream, None)
                for line in stream:
                    fields = line.split()
                    if len(fields) < 10 or fields[3] != "0A":
                        continue
                    try:
                        observed_port = int(fields[1].rsplit(":", 1)[1], 16)
                    except (IndexError, ValueError):
                        raise SystemExit(2)
                    if observed_port == port and fields[9].isdigit():
                        socket_inodes.add(fields[9])
        except FileNotFoundError:
            continue
        except OSError:
            raise SystemExit(2)
    if not socket_inodes:
        raise SystemExit(1)
    try:
        descriptor_names = os.listdir(f"/proc/{pid}/fd")
    except FileNotFoundError:
        raise SystemExit(1)
    except OSError:
        raise SystemExit(2)
    for descriptor_name in descriptor_names:
        try:
            target = os.readlink(f"/proc/{pid}/fd/{descriptor_name}")
        except FileNotFoundError:
            continue
        except OSError:
            raise SystemExit(2)
        match = re.fullmatch(r"socket:\[([0-9]+)\]", target)
        if match and match.group(1) in socket_inodes:
            raise SystemExit(0)
    raise SystemExit(1)

if sys.platform == "darwin":
    lsof_binary = "/usr/sbin/lsof"
    if not os.access(lsof_binary, os.X_OK):
        raise SystemExit(2)
    try:
        result = subprocess.run(
            [
                lsof_binary,
                "-nP",
                "-a",
                "-p",
                str(pid),
                f"-iTCP:{port}",
                "-sTCP:LISTEN",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=timeout,
        )
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit(2)
    raise SystemExit(0 if result.returncode == 0 else 1)

raise SystemExit(2)
PY
}

_wait_for_nats_ports_free() {
    local client_port="$1" monitor_port="$2" max="${3:-10}"
    local client_busy monitor_busy
    if ! [[ "$client_port" =~ ^[0-9]+$ ]] \
        || ! [[ "$monitor_port" =~ ^[0-9]+$ ]] \
        || [ "$client_port" -lt 1 ] || [ "$client_port" -gt 65535 ] \
        || [ "$monitor_port" -lt 1 ] || [ "$monitor_port" -gt 65535 ] \
        || [ "$client_port" = "$monitor_port" ]; then
        echo "ERROR: NATS requires distinct valid client and monitor ports" >&2
        return 1
    fi
    for _ in $(seq 1 "$max"); do
        client_busy=0
        monitor_busy=0
        _nats_port_is_open "$client_port" && client_busy=1
        _nats_port_is_open "$monitor_port" && monitor_busy=1
        if [ "$client_busy" -eq 0 ] && [ "$monitor_busy" -eq 0 ]; then
            return 0
        fi
        if ! sleep 1; then
            echo "ERROR: interrupted while waiting for NATS ports" >&2
            return 1
        fi
    done
    echo "ERROR: NATS client or monitor port remains occupied" >&2
    return 1
}

_nats_descriptor_exec_supported() {
    [ "$(/usr/bin/uname -s 2>/dev/null)" = Linux ] \
        && [ -d /proc/self/fd ]
}

_exec_nats_with_bound_store() {
    local nats_bin="$1" client_port="$2" monitor_port="$3"
    local server_identity="$4"
    _exec_bound_python - "$NATS_DATA_RECEIPT" "$NATS_DATA_DIR" "$nats_bin" \
        "$client_port" "$monitor_port" "$server_identity" \
        "$NATS_DATA_PARENT_FD" "$NATS_DATA_FD" <<'PY'
import os
import re
import stat
import sys


def abort(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def close_nonstdio_descriptors(allowed):
    allowed = {0, 1, 2, *allowed}
    try:
        descriptors = tuple(
            int(name)
            for name in os.listdir("/proc/self/fd")
            if name.isdecimal()
        )
    except OSError as error:
        abort(f"descriptor inventory unavailable: {error}")
    for inherited in descriptors:
        if inherited in allowed:
            continue
        try:
            os.close(inherited)
        except OSError:
            pass


def fd_mount_identity(file_descriptor):
    if sys.platform.startswith("linux"):
        try:
            with open(
                f"/proc/self/fdinfo/{file_descriptor}", encoding="ascii"
            ) as stream:
                for line in stream:
                    if line.startswith("mnt_id:"):
                        value = line.split(":", 1)[1].strip()
                        if value.isdigit():
                            return f"linux:{value}"
        except OSError as error:
            abort(f"mount identity unavailable: {error}")
        abort("mount identity unavailable")
    if sys.platform == "darwin":
        import ctypes
        import hashlib

        class Fsid(ctypes.Structure):
            _fields_ = [("values", ctypes.c_int32 * 2)]

        class Statfs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", Fsid),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32),
                ("f_reserved", ctypes.c_uint32 * 7),
            ]

        metadata = Statfs()
        library = ctypes.CDLL(None, use_errno=True)
        if library.fstatfs(file_descriptor, ctypes.byref(metadata)) != 0:
            abort(f"mount identity unavailable: {os.strerror(ctypes.get_errno())}")
        payload = b"\0".join(
            (
                bytes(metadata.f_fstypename).split(b"\0", 1)[0],
                bytes(metadata.f_mntonname).split(b"\0", 1)[0],
                bytes(metadata.f_mntfromname).split(b"\0", 1)[0],
                str(tuple(metadata.f_fsid.values)).encode("ascii"),
            )
        )
        if not payload:
            abort("mount identity unavailable")
        return "darwin:" + hashlib.sha256(payload).hexdigest()
    abort(f"mount identity unavailable on {sys.platform}")


fields = sys.argv[1].split("|")
expected_path, binary, client_port, monitor_port, server_identity, \
    parent_fd_text, storage_fd_text = sys.argv[2:]
if len(fields) != 12 or fields[0] != "v2":
    abort("malformed NATS storage receipt")
(
    _,
    parent,
    name,
    parent_dev,
    parent_ino,
    parent_mount,
    device,
    inode,
    owner,
    mode,
    link_count,
    storage_mount,
) = fields
if not os.path.isabs(parent) or os.path.realpath(parent) != parent:
    abort("NATS storage parent is no longer canonical")
if not re.fullmatch(r"hi-nats-[A-Za-z0-9]{6}", name):
    abort("unsafe NATS storage receipt name")
if expected_path != os.path.join(parent, name):
    abort("NATS storage path no longer matches its receipt")
if not os.path.isabs(binary):
    abort("NATS binary is not an absolute path")
if not re.fullmatch(r"odysseus-e2e-[0-9a-f]{32}", server_identity):
    abort("invalid NATS server identity")
try:
    parent_dev, parent_ino, device, inode, owner, link_count = map(
        int, (parent_dev, parent_ino, device, inode, owner, link_count)
    )
    mode = int(mode, 8)
except ValueError:
    abort("non-numeric NATS storage receipt metadata")
try:
    parent_fd, storage_fd = map(int, (parent_fd_text, storage_fd_text))
except ValueError:
    abort("invalid NATS storage descriptors")
if min(parent_fd, storage_fd) < 3:
    abort("unsafe NATS storage descriptors")
binary_fd = -1
try:
    try:
        parent_metadata = os.fstat(parent_fd)
        storage_metadata = os.fstat(storage_fd)
    except OSError as error:
        abort(f"cannot inspect receipt-bound NATS storage: {error}")
    if (parent_metadata.st_dev, parent_metadata.st_ino) != (
        parent_dev,
        parent_ino,
    ) or fd_mount_identity(parent_fd) != parent_mount:
        abort("NATS storage parent identity changed")
    if (
        storage_metadata.st_dev,
        storage_metadata.st_ino,
        storage_metadata.st_uid,
        stat.S_IMODE(storage_metadata.st_mode),
    ) != (device, inode, owner, mode) \
            or storage_metadata.st_nlink < link_count \
            or not stat.S_ISDIR(storage_metadata.st_mode) \
            or fd_mount_identity(storage_fd) != storage_mount:
        abort("NATS storage identity changed before exec")
    os.fchdir(storage_fd)
    working_metadata = os.stat(".")
    if (working_metadata.st_dev, working_metadata.st_ino) != (device, inode):
        abort("NATS working directory is not receipt-bound")
    # The cwd is derived from the already-open storage object. `.` therefore
    # remains bound across a later rename or same-name replacement without
    # leaking the authority-bearing storage descriptor into nats-server.
    store_path = "."
    binary_flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    if hasattr(os, "O_NOFOLLOW"):
        binary_flags |= os.O_NOFOLLOW
    try:
        binary_fd = os.open(binary, binary_flags)
    except OSError as error:
        abort(f"cannot open the launch-bound NATS binary: {error}")
    binary_metadata = os.fstat(binary_fd)
    if not stat.S_ISREG(binary_metadata.st_mode) \
            or binary_metadata.st_nlink < 1 \
            or stat.S_IMODE(binary_metadata.st_mode) & 0o111 == 0:
        abort("launch-bound NATS binary metadata is unsafe")
    if os.execve not in os.supports_fd:
        abort("descriptor-bound NATS execution is unavailable")
    os.set_inheritable(binary_fd, True)
    os.close(parent_fd)
    parent_fd = -1
    os.close(storage_fd)
    storage_fd = -1
    close_nonstdio_descriptors({binary_fd})
    arguments = [
            binary,
            "-js",
            "-p",
            client_port,
            "-m",
            monitor_port,
            "-n",
            server_identity,
            "--store_dir",
            store_path,
        ]
    os.execve(binary_fd, arguments, {})
finally:
    if parent_fd >= 0:
        os.close(parent_fd)
    if binary_fd >= 0:
        os.close(binary_fd)
    if storage_fd >= 0:
        os.close(storage_fd)
PY
}

_wait_for_registered_nats() {
    local pid="$1" identity="$2" owner="$3" monitor_port="$4" max="$5"
    local expected_server_identity="$6" identity_status monitor_identity
    local ownership_status deadline remaining
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || return 2
    deadline=$((SECONDS + max))
    while [ "$SECONDS" -lt "$deadline" ]; do
        remaining=$((deadline - SECONDS))
        if _process_identity_status "$pid" "$identity" "$owner"; then
            if _nats_health_for_port "$monitor_port" "$remaining"; then
                remaining=$((deadline - SECONDS))
                [ "$remaining" -gt 0 ] || break
                if ! monitor_identity=$(
                    _nats_monitor_identity_for_port "$monitor_port" "$remaining"
                ); then
                    echo "ERROR: healthy NATS monitor did not expose the launch-bound identity" >&2
                    return 1
                fi
                if [ "$monitor_identity" != "$expected_server_identity" ]; then
                    echo "ERROR: NATS health belongs to a foreign server identity" >&2
                    return 1
                fi
                remaining=$((deadline - SECONDS))
                [ "$remaining" -gt 0 ] || break
                if _nats_monitor_owned_by_process \
                    "$monitor_port" "$pid" "$remaining"; then
                    :
                else
                    ownership_status=$?
                    if [ "$ownership_status" -eq 1 ]; then
                        echo "ERROR: NATS monitor socket belongs to a foreign process" >&2
                    else
                        echo "ERROR: could not prove NATS monitor socket ownership" >&2
                    fi
                    return 1
                fi
                if _process_identity_status "$pid" "$identity" "$owner"; then
                    return 0
                fi
                echo "ERROR: registered NATS identity changed during health check" >&2
                return 1
            fi
        else
            identity_status=$?
            if [ "$identity_status" -eq 1 ]; then
                echo "ERROR: registered NATS process identity changed" >&2
            else
                echo "ERROR: could not verify registered NATS process" >&2
            fi
            return 1
        fi
        remaining=$((deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        if ! sleep 1; then
            echo "ERROR: interrupted while waiting for NATS health" >&2
            return 1
        fi
    done
    echo "ERROR: registered NATS process did not become healthy" >&2
    return 1
}

_start_nats_guarded() {
    local nats_bin="$1" health_timeout="$2" child_pid child_identity owner
    local server_identity containment
    if ! _bound_process_signaling_supported; then
        echo "ERROR: handle-bound process signaling is unavailable" >&2
        return 1
    fi
    _wait_for_nats_ports_free "$NATS_PORT" "$NATS_MONITOR_PORT" 10 \
        || return 1
    _resolve_bound_nats_data_dir >/dev/null || return 1
    if ! _nats_descriptor_exec_supported; then
        echo "ERROR: descriptor-bound NATS execution is unavailable" >&2
        return 1
    fi
    if ! server_identity=$(_run_bound_python -c \
        'import secrets; print("odysseus-e2e-" + secrets.token_hex(16))') \
        || ! [[ "$server_identity" =~ ^odysseus-e2e-[0-9a-f]{32}$ ]]; then
        echo "ERROR: could not create a launch-bound NATS server identity" >&2
        return 1
    fi
    if ! _prepare_service_containment; then
        echo "ERROR: cannot start NATS without kernel-owned containment" >&2
        return 1
    fi
    containment="$PENDING_SERVICE_CONTAINMENT"
    (
        _join_service_containment "$containment" "${BASHPID:-$$}" \
            || exit 125
        _exec_nats_with_bound_store "$nats_bin" "$NATS_PORT" \
            "$NATS_MONITOR_PORT" "$server_identity"
    ) >/dev/null &
    child_pid=$!
    REGISTERED_PROCESS_IDENTITY=""
    REGISTERED_PROCESS_OWNER=""
    if ! register_pid "$child_pid" "$containment"; then
        child_identity="$REGISTERED_PROCESS_IDENTITY"
        owner="$REGISTERED_PROCESS_OWNER"
        if [ -n "$child_identity" ] && [ -n "$owner" ]; then
            NATS_BG_PID="$child_pid"
            NATS_BG_IDENTITY="$child_identity"
            NATS_BG_OWNER="$owner"
            export NATS_BG_PID NATS_BG_IDENTITY NATS_BG_OWNER
            if ! _retire_unregistered_child \
                "$child_pid" "$child_identity" "$owner" "$containment"; then
                echo "ERROR: retained unregistered NATS child evidence" >&2
                return 1
            fi
            NATS_BG_PID=""
            NATS_BG_IDENTITY=""
            NATS_BG_OWNER=""
            export NATS_BG_PID NATS_BG_IDENTITY NATS_BG_OWNER
        else
            if ! _retire_service_containment "$containment"; then
                echo "ERROR: NATS child registration failed before identity publication" >&2
                return 1
            fi
            if ! builtin wait "$child_pid" 2>/dev/null; then :; fi
        fi
        return 1
    fi
    child_identity="$REGISTERED_PROCESS_IDENTITY"
    owner="${BASHPID:-$$}"
    NATS_BG_PID="$child_pid"
    NATS_BG_IDENTITY="$child_identity"
    NATS_BG_OWNER="$owner"
    NATS_BG_SERVER_NAME="$server_identity"
    export NATS_BG_PID NATS_BG_IDENTITY NATS_BG_OWNER NATS_BG_SERVER_NAME
    if ! _wait_for_registered_nats "$child_pid" "$child_identity" "$owner" \
        "$NATS_MONITOR_PORT" "$health_timeout" "$server_identity"; then
        return 1
    fi
}

_remove_bound_nats_data_dir() {
    if [ -z "$NATS_DATA_RECEIPT" ]; then
        if [ -n "$NATS_DATA_DIR" ]; then
            echo "ERROR: refusing NATS storage cleanup without an immutable receipt" >&2
            return 1
        fi
        return 0
    fi
if ! _run_bound_python - "$NATS_DATA_RECEIPT" "$NATS_DATA_PARENT_FD" \
    "$NATS_DATA_FD" <<'PY'
import os
import re
import secrets
import stat
import sys


def abort(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(1)


def fd_mount_identity(file_descriptor):
    if sys.platform.startswith("linux"):
        try:
            with open(
                f"/proc/self/fdinfo/{file_descriptor}", encoding="ascii"
            ) as stream:
                for line in stream:
                    if line.startswith("mnt_id:"):
                        value = line.split(":", 1)[1].strip()
                        if value.isdigit():
                            return f"linux:{value}"
        except OSError as error:
            abort(f"mount identity unavailable: {error}")
        abort("mount identity unavailable")
    if sys.platform == "darwin":
        import ctypes
        import hashlib

        class Fsid(ctypes.Structure):
            _fields_ = [("values", ctypes.c_int32 * 2)]

        class Statfs(ctypes.Structure):
            _fields_ = [
                ("f_bsize", ctypes.c_uint32),
                ("f_iosize", ctypes.c_int32),
                ("f_blocks", ctypes.c_uint64),
                ("f_bfree", ctypes.c_uint64),
                ("f_bavail", ctypes.c_uint64),
                ("f_files", ctypes.c_uint64),
                ("f_ffree", ctypes.c_uint64),
                ("f_fsid", Fsid),
                ("f_owner", ctypes.c_uint32),
                ("f_type", ctypes.c_uint32),
                ("f_flags", ctypes.c_uint32),
                ("f_fssubtype", ctypes.c_uint32),
                ("f_fstypename", ctypes.c_char * 16),
                ("f_mntonname", ctypes.c_char * 1024),
                ("f_mntfromname", ctypes.c_char * 1024),
                ("f_flags_ext", ctypes.c_uint32),
                ("f_reserved", ctypes.c_uint32 * 7),
            ]

        metadata = Statfs()
        libc = ctypes.CDLL(None, use_errno=True)
        if libc.fstatfs(file_descriptor, ctypes.byref(metadata)) != 0:
            abort(f"mount identity unavailable: {os.strerror(ctypes.get_errno())}")
        payload = b"\0".join(
            (
                bytes(metadata.f_fstypename).split(b"\0", 1)[0],
                bytes(metadata.f_mntonname).split(b"\0", 1)[0],
                bytes(metadata.f_mntfromname).split(b"\0", 1)[0],
                str(tuple(metadata.f_fsid.values)).encode("ascii"),
            )
        )
        if not payload:
            abort("mount identity unavailable")
        return "darwin:" + hashlib.sha256(payload).hexdigest()
    abort(f"mount identity unavailable on {sys.platform}")


fields = sys.argv[1].split("|")
if len(fields) != 12 or fields[0] != "v2":
    abort("malformed NATS storage receipt")
(
    _,
    parent,
    name,
    parent_dev,
    parent_ino,
    parent_mount,
    device,
    inode,
    owner,
    mode,
    link_count,
    storage_mount,
) = fields
if not os.path.isabs(parent) or os.path.realpath(parent) != parent:
    abort("NATS storage parent is no longer canonical")
if not re.fullmatch(r"hi-nats-[A-Za-z0-9]{6}", name):
    abort("unsafe NATS storage receipt name")
try:
    parent_dev, parent_ino, device, inode, owner, link_count = map(
        int, (parent_dev, parent_ino, device, inode, owner, link_count)
    )
    mode = int(mode, 8)
except ValueError:
    abort("non-numeric NATS storage receipt metadata")

if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
    abort("required no-follow directory controls are unavailable")
directory_flags = os.O_RDONLY | os.O_DIRECTORY \
    | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
try:
    parent_fd, storage_fd = map(int, sys.argv[2:4])
except ValueError:
    abort("invalid NATS storage descriptors")
if min(parent_fd, storage_fd) < 3:
    abort("unsafe NATS storage descriptors")


def lstat_at(directory_fd, entry_name):
    return os.stat(entry_name, dir_fd=directory_fd, follow_symlinks=False)


def ensure_original_absent(recovery_path):
    try:
        lstat_at(parent_fd, name)
    except FileNotFoundError:
        return
    abort(
        "retained quarantined NATS storage after a same-name "
        f"replacement appeared; operator recovery is required at {recovery_path}"
    )


try:
    try:
        bound_parent = os.fstat(parent_fd)
        opened = os.fstat(storage_fd)
    except OSError as error:
        abort(f"cannot inspect bound NATS storage: {error}")
    if (bound_parent.st_dev, bound_parent.st_ino) != (parent_dev, parent_ino):
        abort("NATS storage parent identity changed")
    if fd_mount_identity(parent_fd) != parent_mount:
        abort("NATS storage parent mount identity changed")
    try:
        observed = lstat_at(parent_fd, name)
    except FileNotFoundError:
        abort("bound NATS storage directory is missing")
    observed_mode = stat.S_IMODE(observed.st_mode)
    if not stat.S_ISDIR(observed.st_mode) or stat.S_ISLNK(observed.st_mode):
        abort("bound NATS storage name is not a directory")
    if (observed.st_dev, observed.st_ino, observed.st_uid, observed_mode) != (
        device,
        inode,
        owner,
        mode,
    ) or observed.st_nlink < link_count:
        abort("same-name NATS storage replacement was preserved")
    try:
        if (opened.st_dev, opened.st_ino) != (device, inode):
            abort("NATS storage descriptor identity changed before cleanup")
        if fd_mount_identity(storage_fd) != storage_mount:
            abort("NATS storage mount identity changed")
        quarantine_name = f".{name}.cleanup-{secrets.token_hex(16)}"
        try:
            lstat_at(parent_fd, quarantine_name)
        except FileNotFoundError:
            pass
        else:
            abort("NATS storage quarantine name already exists")
        os.rename(
            name,
            quarantine_name,
            src_dir_fd=parent_fd,
            dst_dir_fd=parent_fd,
        )
        recovery_path = os.path.join(parent, quarantine_name)
        try:
            quarantine_fd = os.open(
                quarantine_name, directory_flags, dir_fd=parent_fd
            )
        except OSError as error:
            abort(
                "cannot open quarantined NATS storage; retained for operator "
                f"recovery at {recovery_path}: {error}"
            )
        try:
            quarantined = os.fstat(quarantine_fd)
            if (
                quarantined.st_dev,
                quarantined.st_ino,
                quarantined.st_uid,
                stat.S_IMODE(quarantined.st_mode),
            ) != (device, inode, owner, mode) \
                    or not stat.S_ISDIR(quarantined.st_mode) \
                    or fd_mount_identity(quarantine_fd) != storage_mount:
                abort(
                    "quarantined NATS storage identity changed; retained for "
                    f"operator recovery at {recovery_path}"
                )
            ensure_original_absent(recovery_path)
            abort(
                "exact inode-bound deletion is unavailable; quarantined NATS "
                "storage retained for operator recovery at "
                f"{recovery_path}"
            )
        finally:
            os.close(quarantine_fd)
    finally:
        os.close(storage_fd)
finally:
    os.close(parent_fd)
PY
    then
        printf 'ERROR: retained NATS storage receipt after cleanup failure: %s\n' \
            "$NATS_DATA_RECEIPT" >&2
        return 1
    fi
    _close_nats_data_fds
    NATS_DATA_DIR=""
    NATS_DATA_RECEIPT=""
    export NATS_DATA_DIR NATS_DATA_RECEIPT
}

start_nats_bg() {
    _create_nats_data_dir || return 1
    local nats_bin
    nats_bin=$(command -v nats-server 2>/dev/null) || {
        echo "ERROR: nats-server not found in PATH" >&2
        return 1
    }
    case "$nats_bin" in
        /*) ;;
        *)
            nats_bin=$(cd "$(dirname "$nats_bin")" \
                && printf '%s/%s\n' "$PWD" "$(basename "$nats_bin")") \
                || return 1
            ;;
    esac
    NATS_BIN="$nats_bin"
    export NATS_BIN NATS_PORT NATS_MONITOR_PORT NATS_DATA_DIR \
        NATS_DATA_RECEIPT
    _start_nats_guarded "$nats_bin" 15 || return 1
    echo "  Started nats-server (PID $NATS_BG_PID, port $NATS_PORT, monitor $NATS_MONITOR_PORT)"
}

# ─── Agamemnon Server ────────────────────────────────────────────────────────

AGAMEMNON_PORT="${AGAMEMNON_PORT:-18080}"

_registered_process_receipt_matches() {
    local pid="$1" identity="$2" owner="$3" containment="$4" index
    _sync_process_receipts || return 2
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        if [ "${_BG_PIDS[$index]}" = "$pid" ] \
            && [ "${_BG_PID_IDENTITIES[$index]}" = "$identity" ] \
            && [ "${_BG_PID_OWNERS[$index]}" = "$owner" ] \
            && [ "${_BG_PROCESS_CONTAINMENTS[$index]:-}" = "$containment" ]; then
            return 0
        fi
    done
    return 1
}

_service_connected_to_port() {
    local port="$1" pid="$2" timeout="${3:-2}"
    _run_bound_python - "$port" "$pid" "$timeout" <<'PY'
import os
import re
import subprocess
import sys


try:
    port = int(sys.argv[1])
    pid = int(sys.argv[2])
    timeout = int(sys.argv[3])
except ValueError:
    raise SystemExit(2)
if not 1 <= port <= 65535 or pid <= 0 or timeout <= 0:
    raise SystemExit(2)
if sys.platform.startswith("linux"):
    socket_inodes = set()
    for table, expected_address in (
        ("/proc/net/tcp", "0100007F"),
        ("/proc/net/tcp6", "00000000000000000000000001000000"),
    ):
        try:
            with open(table, encoding="ascii") as stream:
                next(stream, None)
                for line in stream:
                    fields = line.split()
                    if len(fields) < 10 or fields[3] != "01":
                        continue
                    try:
                        remote_address, remote_port_text = fields[2].rsplit(":", 1)
                        remote_port = int(remote_port_text, 16)
                    except (IndexError, ValueError):
                        raise SystemExit(2)
                    if remote_address == expected_address \
                            and remote_port == port \
                            and fields[9].isdigit():
                        socket_inodes.add(fields[9])
        except FileNotFoundError:
            continue
        except OSError:
            raise SystemExit(2)
    try:
        descriptor_names = os.listdir(f"/proc/{pid}/fd")
    except FileNotFoundError:
        raise SystemExit(1)
    except OSError:
        raise SystemExit(2)
    for descriptor_name in descriptor_names:
        try:
            target = os.readlink(f"/proc/{pid}/fd/{descriptor_name}")
        except FileNotFoundError:
            continue
        except OSError:
            raise SystemExit(2)
        match = re.fullmatch(r"socket:\[([0-9]+)\]", target)
        if match and match.group(1) in socket_inodes:
            raise SystemExit(0)
    raise SystemExit(1)
if sys.platform == "darwin":
    lsof_binary = "/usr/sbin/lsof"
    if not os.access(lsof_binary, os.X_OK):
        raise SystemExit(2)
    try:
        result = subprocess.run(
            [
                lsof_binary,
                "-nP",
                "-a",
                "-p",
                str(pid),
                f"-iTCP@127.0.0.1:{port}",
                "-sTCP:ESTABLISHED",
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
            timeout=timeout,
            env={},
        )
    except (OSError, subprocess.TimeoutExpired):
        raise SystemExit(2)
    raise SystemExit(0 if result.returncode == 0 else 1)
raise SystemExit(2)
PY
}

_wait_for_registered_agamemnon() {
    local pid="$1" identity="$2" owner="$3" containment="$4"
    local port="$5" max="${6:-20}" deadline
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || return 2
    deadline=$((SECONDS + max))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! _process_identity_status "$pid" "$identity" "$owner" \
            || ! _registered_process_receipt_matches \
                "$pid" "$identity" "$owner" "$containment" \
            || ! _service_containment_contains "$containment" "$pid"; then
            return 1
        fi
        if _nats_monitor_owned_by_process "$port" "$pid" 1 \
            && _run_bound_curl_bounded 1 --silent --show-error --fail \
                --output /dev/null \
                "http://127.0.0.1:${port}/v1/health" \
            && _process_identity_status "$pid" "$identity" "$owner" \
            && _registered_process_receipt_matches \
                "$pid" "$identity" "$owner" "$containment" \
            && _service_containment_contains "$containment" "$pid" \
            && _nats_monitor_owned_by_process "$port" "$pid" 1; then
            return 0
        fi
        /bin/sleep 1 || return 1
    done
    return 1
}

_wait_for_registered_myrmidon() {
    local pid="$1" identity="$2" owner="$3" containment="$4"
    local port="$5" max="${6:-20}" deadline
    [[ "$max" =~ ^[1-9][0-9]*$ ]] || return 2
    deadline=$((SECONDS + max))
    while [ "$SECONDS" -lt "$deadline" ]; do
        if ! _process_identity_status "$pid" "$identity" "$owner" \
            || ! _registered_process_receipt_matches \
                "$pid" "$identity" "$owner" "$containment" \
            || ! _service_containment_contains "$containment" "$pid"; then
            return 1
        fi
        if _service_connected_to_port "$port" "$pid" 1 \
            && _process_identity_status "$pid" "$identity" "$owner" \
            && _registered_process_receipt_matches \
                "$pid" "$identity" "$owner" "$containment" \
            && _service_containment_contains "$containment" "$pid" \
            && _service_connected_to_port "$port" "$pid" 1; then
            return 0
        fi
        /bin/sleep 1 || return 1
    done
    return 1
}

_rollback_registered_child() {
    local pid="$1" service="$2" containment="$3"
    local identity="$4" owner="$5" record
    if ! _retire_unregistered_child \
        "$pid" "$identity" "$owner" "$containment"; then
        printf 'ERROR: retained registered %s child evidence: pid=%s identity=%s owner=%s\n' \
            "$service" "$pid" "$identity" "$owner" >&2
        return 1
    fi
    record="$pid|$identity|$owner|$containment"$'\n'
    _process_receipt_store_op drop "$record" || return 1
    _sync_process_receipts
}

start_agamemnon_bg() {
    local bin="" containment executable_receipt child_identity child_owner
    local odysseus_root="${ODYSSEUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    if ! _bound_process_signaling_supported; then
        echo "ERROR: cannot start Agamemnon without handle-bound cleanup" >&2
        return 1
    fi

    # Search for the binary in known locations
    for candidate in \
        "${odysseus_root}/build/Agamemnon/Agamemnon_server" \
        "${odysseus_root}/control/Agamemnon/build/debug/Agamemnon_server" \
        "$(command -v Agamemnon_server 2>/dev/null)"; do
        [ -x "$candidate" ] && bin="$candidate" && break
    done
    [ -z "$bin" ] && { echo "ERROR: Agamemnon_server not found. Run 'just build' first." >&2; return 1; }
    case "$bin" in
        /*) ;;
        *)
            bin=$(cd "$(dirname "$bin")" \
                && printf '%s/%s\n' "$PWD" "$(basename "$bin")") \
                || return 1
            ;;
    esac
    _bind_service_executable "$bin" || return 1
    executable_receipt="$SERVICE_EXECUTABLE_RECEIPT"
    if ! _prepare_service_containment; then
        _close_service_executable_fd
        echo "ERROR: cannot start Agamemnon without kernel-owned containment" >&2
        return 1
    fi
    containment="$PENDING_SERVICE_CONTAINMENT"

    # Agamemnon (server_main.cpp) FATAL-exits if AGAMEMNON_API_KEY is unset/empty,
    # and once set enforces it on non-exempt /v1/* endpoints. Launch with the same
    # key the REST helpers send (e2e/lib/agamemnon.sh AGAMEMNON_AUTH); default to
    # the shared test key so a keyless env still starts.
    (
        _join_service_containment "$containment" "${BASHPID:-$$}" \
            || exit 125
        NATS_URL="nats://127.0.0.1:${NATS_PORT}"
        PORT="$AGAMEMNON_PORT"
        AGAMEMNON_API_KEY="${AGAMEMNON_API_KEY:-e2e-test-key}"
        export NATS_URL PORT AGAMEMNON_API_KEY
        _exec_service_without_harness_capabilities \
            "$bin" "$executable_receipt" \
            NATS_URL PORT AGAMEMNON_API_KEY
    ) >/dev/null 2>&1 &
    local agamemnon_pid=$!
    _close_service_executable_fd
    REGISTERED_PROCESS_IDENTITY=""
    REGISTERED_PROCESS_OWNER=""
    if ! register_pid "$agamemnon_pid" "$containment"; then
        if ! _rollback_failed_child_registration \
            "$agamemnon_pid" Agamemnon "$containment"; then
            return 1
        fi
        return 1
    fi
    child_identity="$REGISTERED_PROCESS_IDENTITY"
    child_owner="$REGISTERED_PROCESS_OWNER"
    if ! _wait_for_registered_agamemnon \
        "$agamemnon_pid" "$child_identity" "$child_owner" \
        "$containment" "$AGAMEMNON_PORT" 20; then
        _rollback_registered_child \
            "$agamemnon_pid" Agamemnon "$containment" \
            "$child_identity" "$child_owner" || return 1
        return 1
    fi
    echo "  Started Agamemnon (PID $agamemnon_pid, port $AGAMEMNON_PORT)"
}

# ─── Hello Myrmidon ──────────────────────────────────────────────────────────

start_myrmidon_bg() {
    local odysseus_root="${ODYSSEUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local bin="" containment executable_receipt child_identity child_owner
    if ! _bound_process_signaling_supported; then
        echo "ERROR: cannot start hello-myrmidon without handle-bound cleanup" >&2
        return 1
    fi
    # Binary name from: provisioning/Myrmidons/hello-world/CMakeLists.txt:35
    #   add_executable(hello_myrmidon main.cpp)
    #   Verified against Myrmidons submodule pin ef3279f.
    for candidate in \
        "${odysseus_root}/build/Myrmidons/hello-world/hello_myrmidon" \
        "${odysseus_root}/provisioning/Myrmidons/hello-world/build/hello_myrmidon" \
        "$(command -v hello_myrmidon 2>/dev/null)"; do
        [ -x "$candidate" ] && bin="$candidate" && break
    done
    [ -z "$bin" ] && { echo "ERROR: hello_myrmidon binary not found. Run 'just build' first." >&2; return 1; }
    case "$bin" in
        /*) ;;
        *)
            bin=$(cd "$(dirname "$bin")" \
                && printf '%s/%s\n' "$PWD" "$(basename "$bin")") \
                || return 1
            ;;
    esac
    _bind_service_executable "$bin" || return 1
    executable_receipt="$SERVICE_EXECUTABLE_RECEIPT"

    if ! _prepare_service_containment; then
        _close_service_executable_fd
        echo "ERROR: cannot start hello-myrmidon without kernel-owned containment" >&2
        return 1
    fi
    containment="$PENDING_SERVICE_CONTAINMENT"

    # MYRMIDON_WORK_DELAY_MS=0: drop the worker's default 1s/task "simulate work"
    # delay so fan-out perf scenarios (B07 50 tasks, B08 100 tasks) drain at real
    # dispatch speed instead of being capped at ~1 task/sec by MaxAckPending=1.
    (
        _join_service_containment "$containment" "${BASHPID:-$$}" \
            || exit 125
        NATS_URL="nats://127.0.0.1:${NATS_PORT}"
        MYRMIDON_WORK_DELAY_MS="${MYRMIDON_WORK_DELAY_MS:-0}"
        export NATS_URL MYRMIDON_WORK_DELAY_MS
        _exec_service_without_harness_capabilities \
            "$bin" "$executable_receipt" \
            NATS_URL MYRMIDON_WORK_DELAY_MS
    ) >/dev/null 2>&1 &
    local myrmidon_pid=$!
    _close_service_executable_fd
    REGISTERED_PROCESS_IDENTITY=""
    REGISTERED_PROCESS_OWNER=""
    if ! register_pid "$myrmidon_pid" "$containment"; then
        if ! _rollback_failed_child_registration \
            "$myrmidon_pid" hello-myrmidon "$containment"; then
            return 1
        fi
        return 1
    fi
    child_identity="$REGISTERED_PROCESS_IDENTITY"
    child_owner="$REGISTERED_PROCESS_OWNER"
    if ! _wait_for_registered_myrmidon \
        "$myrmidon_pid" "$child_identity" "$child_owner" \
        "$containment" "$NATS_PORT" 20; then
        _rollback_registered_child \
            "$myrmidon_pid" hello-myrmidon "$containment" \
            "$child_identity" "$child_owner" || return 1
        return 1
    fi
    echo "  Started hello-myrmidon (PID $myrmidon_pid, bin $bin)"
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup_all() {
    if ! cleanup_pids; then
        return 1
    fi
    _remove_bound_nats_data_dir || return 1
    _remove_process_receipt_store
}

# T1 fault tests execute in a Bash subprocess. Export only the receipt helpers
# they need so a replacement direct child updates the parent's shared store.
export -f _valid_pid _ensure_bound_runtime_tools _run_bound_python \
    _exec_bound_python _run_bound_curl _run_bound_curl_bounded \
    _process_receipt_store_op _ensure_process_receipt_store \
    _persist_process_receipts _sync_process_receipts _process_receipt \
    _process_identity_status _signal_bound_process \
    _bound_process_signaling_supported _retire_unregistered_child \
    _service_containment_op _prepare_service_containment \
    _join_service_containment _service_containment_contains \
    _service_containment_state _kill_service_containment \
    _remove_service_containment _wait_for_service_containment_member \
    _extinguish_service_containment _retire_service_containment \
    _kill_registered_service_tree \
    register_pid unregister_pid \
    _resolve_bound_nats_data_dir _nats_port_is_open _nats_health_for_port \
    _nats_monitor_identity_for_port _nats_monitor_owned_by_process \
    _wait_for_nats_ports_free _nats_descriptor_exec_supported \
    _exec_nats_with_bound_store _wait_for_registered_nats \
    _start_nats_guarded
