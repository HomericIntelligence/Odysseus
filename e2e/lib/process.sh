#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Process Management (T1/T2)
# Manages background processes for non-container topologies.

# Track immutable process receipts for cleanup. The file is shared with Bash
# test subprocesses so a T1 NATS restart can replace its receipt in the parent
# runner's cleanup inventory.
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
PROCESS_RECEIPT_DIR=""
PROCESS_RECEIPT_FILE=""
PROCESS_RECEIPT_STORAGE_RECEIPT=""
REGISTERED_PROCESS_IDENTITY=""
REGISTERED_PROCESS_OWNER=""

_valid_pid() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

_bind_process_receipt_store() {
    local candidate_dir="$1" candidate_file="$2" receipt
    local receipt_version bound_parent bound_directory receipt_metadata
    if ! receipt=$(python3 - "$candidate_dir" "$candidate_file" <<'PY'
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
}

_process_receipt_store_op() {
    local operation="$1" payload="${2:-}"
    [ -n "${PROCESS_RECEIPT_STORAGE_RECEIPT:-}" ] || {
        echo "ERROR: process receipt storage has no immutable receipt" >&2
        return 1
    }
    python3 - "$operation" "$PROCESS_RECEIPT_STORAGE_RECEIPT" "$payload" <<'PY'
import fcntl
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


operation, serialized, payload = sys.argv[1:]
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
if not os.path.isabs(parent) or os.path.realpath(parent) != parent:
    abort("process receipt parent is no longer canonical")
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
directory_flags = os.O_RDONLY | os.O_DIRECTORY \
    | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
file_flags = os.O_RDWR | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
try:
    parent_fd = os.open(parent, directory_flags)
    directory_fd = os.open(directory_name, directory_flags, dir_fd=parent_fd)
    file_fd = os.open(file_name, file_flags, dir_fd=directory_fd)
except OSError as error:
    abort(f"cannot open bound process receipt storage: {error}")
try:
    parent_metadata = os.fstat(parent_fd)
    directory_metadata = os.fstat(directory_fd)
    file_metadata = os.fstat(file_fd)
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
    if operation == "path":
        print(os.path.join(parent, directory_name))
        print(os.path.join(parent, directory_name, file_name))
    elif operation == "read":
        fcntl.flock(file_fd, fcntl.LOCK_SH)
        os.lseek(file_fd, 0, os.SEEK_SET)
        chunks = []
        while True:
            chunk = os.read(file_fd, 65536)
            if not chunk:
                break
            chunks.append(chunk)
        sys.stdout.buffer.write(b"".join(chunks))
    elif operation == "write":
        data = payload.encode("utf-8")
        fcntl.flock(file_fd, fcntl.LOCK_EX)
        os.lseek(file_fd, 0, os.SEEK_SET)
        os.ftruncate(file_fd, 0)
        offset = 0
        while offset < len(data):
            offset += os.write(file_fd, data[offset:])
        os.fsync(file_fd)
    elif operation == "remove":
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
        try:
            quarantine_fd = os.open(
                quarantine_name, directory_flags, dir_fd=parent_fd
            )
        except OSError as error:
            abort(f"cannot open quarantined process receipt storage: {error}")
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
                abort("quarantined process receipt identity changed")
        finally:
            os.close(quarantine_fd)
        try:
            os.stat(directory_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort(
                "retained quarantined process receipt storage after a "
                "same-name replacement appeared"
            )
        fcntl.flock(file_fd, fcntl.LOCK_EX)
        try:
            os.stat(directory_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort(
                "retained quarantined process receipt storage after a "
                "same-name replacement appeared"
            )
        if os.fstat(file_fd).st_size != 0:
            abort("refusing to remove non-empty process receipt storage")
        named_file = os.stat(
            file_name, dir_fd=directory_fd, follow_symlinks=False
        )
        if (
            named_file.st_dev,
            named_file.st_ino,
            named_file.st_uid,
            stat.S_IMODE(named_file.st_mode),
            named_file.st_nlink,
        ) != (
            file_dev,
            file_ino,
            file_uid,
            file_mode,
            file_nlink,
        ) or not stat.S_ISREG(named_file.st_mode):
            abort("process receipt file name no longer has the bound identity")
        if os.listdir(directory_fd) != [file_name]:
            abort("process receipt directory contains unbound entries")
        os.unlink(file_name, dir_fd=directory_fd)
        os.close(file_fd)
        file_fd = -1
        if os.listdir(directory_fd):
            abort("process receipt directory contains unbound entries")
        named_directory = os.stat(
            quarantine_name, dir_fd=parent_fd, follow_symlinks=False
        )
        if (
            named_directory.st_dev,
            named_directory.st_ino,
            named_directory.st_uid,
            stat.S_IMODE(named_directory.st_mode),
        ) != (
            directory_dev,
            directory_ino,
            directory_uid,
            directory_mode,
        ) or not stat.S_ISDIR(named_directory.st_mode):
            abort("process receipt directory name lost its bound identity")
        os.close(directory_fd)
        directory_fd = -1
        os.rmdir(quarantine_name, dir_fd=parent_fd)
        try:
            os.stat(quarantine_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort("process receipt quarantine remains after removal")
        try:
            os.stat(directory_name, dir_fd=parent_fd, follow_symlinks=False)
        except FileNotFoundError:
            pass
        else:
            abort("same-name process receipt replacement was preserved")
    else:
        abort("unknown process receipt storage operation")
finally:
    if file_fd >= 0:
        os.close(file_fd)
    if directory_fd >= 0:
        os.close(directory_fd)
    os.close(parent_fd)
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
    if ! canonical_parent=$(python3 - <<'PY'
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
    PROCESS_RECEIPT_FILE="$candidate/receipts"
    if ! (umask 077 && : > "$PROCESS_RECEIPT_FILE") \
        || ! _bind_process_receipt_store "$candidate" "$PROCESS_RECEIPT_FILE"; then
        rm -f -- "$candidate/receipts" 2>/dev/null || :
        rmdir -- "$candidate" 2>/dev/null || :
        PROCESS_RECEIPT_DIR=""
        PROCESS_RECEIPT_FILE=""
        return 1
    fi
}

_persist_process_receipts() {
    local index payload=""
    _ensure_process_receipt_store || return 1
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        payload+="${_BG_PIDS[$index]}|${_BG_PID_IDENTITIES[$index]}|"
        payload+="${_BG_PID_OWNERS[$index]}"$'\n'
    done
    _process_receipt_store_op write "$payload"
}

_sync_process_receipts() {
    local pid identity owner extra receipt_contents
    [ -n "$PROCESS_RECEIPT_STORAGE_RECEIPT" ] || return 0
    if ! receipt_contents=$(_process_receipt_store_op read); then
        return 1
    fi
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    while IFS='|' read -r pid identity owner extra; do
        [ -n "$pid$identity$owner${extra:-}" ] || continue
        if ! _valid_pid "$pid" \
            || ! [[ "$identity" =~ ^[A-Za-z0-9._:-]+$ ]] \
            || ! _valid_pid "$owner" || [ -n "${extra:-}" ]; then
            echo "ERROR: malformed process cleanup receipt" >&2
            return 1
        fi
        _BG_PIDS+=("$pid")
        _BG_PID_IDENTITIES+=("$identity")
        _BG_PID_OWNERS+=("$owner")
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
    [ "$platform" = Darwin ] || return 2
    python3 - "$pid" <<'PY'
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
    python3 - "$pid" "$expected_identity" "$expected_parent" \
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

# Register a PID for cleanup on exit
register_pid() {
    local pid="${1:-}" receipt identity parent_pid extra index
    local current_shell_pid="${BASHPID:-$$}"
    local -a kept_pids=() kept_identities=() kept_owners=()
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
    _sync_process_receipts || return 1
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        [ "${_BG_PIDS[$index]}" = "$pid" ] && continue
        kept_pids+=("${_BG_PIDS[$index]}")
        kept_identities+=("${_BG_PID_IDENTITIES[$index]}")
        kept_owners+=("${_BG_PID_OWNERS[$index]}")
    done
    _BG_PIDS=("${kept_pids[@]}" "$pid")
    _BG_PID_IDENTITIES=("${kept_identities[@]}" "$identity")
    _BG_PID_OWNERS=("${kept_owners[@]}" "$current_shell_pid")
    _persist_process_receipts
}

_retire_unregistered_child() {
    local pid="$1" identity="$2" owner="$3" identity_status signal_status
    local wait_status
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
}

unregister_pid() {
    local pid="${1:-}" expected_identity="${2:-}" index removed=0
    local -a kept_pids=() kept_identities=() kept_owners=()
    _valid_pid "$pid" || return 2
    [[ "$expected_identity" =~ ^[A-Za-z0-9._:-]+$ ]] || return 2
    _sync_process_receipts || return 1
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        if [ "${_BG_PIDS[$index]}" = "$pid" ] \
            && [ "${_BG_PID_IDENTITIES[$index]}" = "$expected_identity" ]; then
            removed=1
            continue
        fi
        kept_pids+=("${_BG_PIDS[$index]}")
        kept_identities+=("${_BG_PID_IDENTITIES[$index]}")
        kept_owners+=("${_BG_PID_OWNERS[$index]}")
    done
    [ "$removed" -eq 1 ] || return 1
    _BG_PIDS=("${kept_pids[@]}")
    _BG_PID_IDENTITIES=("${kept_identities[@]}")
    _BG_PID_OWNERS=("${kept_owners[@]}")
    _persist_process_receipts
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
    local pid identity owner identity_status wait_status index cleanup_failed=0
    local any_live=0
    local -a remaining_pids=() remaining_identities=() remaining_owners=()
    local -a receipt_failed=()
    _sync_process_receipts || return 1
    if [ "${#_BG_PIDS[@]}" -eq 0 ]; then
        return 0
    fi
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        pid="${_BG_PIDS[$index]}"
        identity="${_BG_PID_IDENTITIES[$index]:-}"
        owner="${_BG_PID_OWNERS[$index]:-}"
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
        [ "${receipt_failed[$index]:-0}" -eq 0 ] || continue
        if ! _valid_pid "$pid"; then
            receipt_failed[index]=1
            cleanup_failed=1
            continue
        fi
        if _process_identity_status "$pid" "$identity"; then
            if ! _kill_if_alive "$pid" "$identity" -KILL "$owner"; then
                receipt_failed[index]=1
                cleanup_failed=1
                continue
            fi
        else
            identity_status=$?
            if [ "$identity_status" -ne 1 ]; then
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
    done

    # Retain every receipt whose extinction cannot be established. Callers
    # need this state for diagnosis and a later cleanup attempt.
    for ((index = 0; index < ${#_BG_PIDS[@]}; index++)); do
        pid="${_BG_PIDS[$index]}"
        identity="${_BG_PID_IDENTITIES[$index]:-}"
        owner="${_BG_PID_OWNERS[$index]:-}"
        if ! _valid_pid "$pid"; then
            remaining_pids+=("$pid")
            remaining_identities+=("$identity")
            remaining_owners+=("$owner")
            cleanup_failed=1
        elif [ "${receipt_failed[$index]:-0}" -ne 0 ]; then
            remaining_pids+=("$pid")
            remaining_identities+=("$identity")
            remaining_owners+=("$owner")
        elif _process_identity_status "$pid" "$identity"; then
            echo "ERROR: process $pid remains alive after cleanup" >&2
            remaining_pids+=("$pid")
            remaining_identities+=("$identity")
            remaining_owners+=("$owner")
            cleanup_failed=1
        else
            identity_status=$?
            if [ "$identity_status" -ne 1 ]; then
                remaining_pids+=("$pid")
                remaining_identities+=("$identity")
                remaining_owners+=("$owner")
                cleanup_failed=1
            fi
        fi
    done
    _BG_PIDS=("${remaining_pids[@]}")
    _BG_PID_IDENTITIES=("${remaining_identities[@]}")
    _BG_PID_OWNERS=("${remaining_owners[@]}")
    if ! _persist_process_receipts; then
        echo "ERROR: could not persist process cleanup receipts" >&2
        return 1
    fi
    [ "$cleanup_failed" -eq 0 ]
}

# Wait until a TCP port is accepting connections
wait_for_port() {
    local port="$1" max="${2:-30}" name="${3:-service}"
    for _ in $(seq 1 "$max"); do
        (echo >/dev/tcp/localhost/"$port") 2>/dev/null && return 0
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

_bind_nats_data_dir() {
    local candidate="$1" receipt receipt_version bound_parent bound_name
    local receipt_metadata
    if ! receipt=$(python3 - "$candidate" <<'PY'
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
}

_create_nats_data_dir() {
    local canonical_parent candidate
    if ! canonical_parent=$(python3 - <<'PY'
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
    if ! _bind_nats_data_dir "$candidate"; then
        rmdir -- "$candidate" 2>/dev/null || :
        return 1
    fi
}

_resolve_bound_nats_data_dir() {
    if [ -z "${NATS_DATA_RECEIPT:-}" ] || [ -z "${NATS_DATA_DIR:-}" ]; then
        echo "ERROR: NATS storage has no immutable receipt" >&2
        return 1
    fi
    python3 - "$NATS_DATA_RECEIPT" "$NATS_DATA_DIR" <<'PY'
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

if not hasattr(os, "O_DIRECTORY") or not hasattr(os, "O_NOFOLLOW"):
    abort("required no-follow directory controls are unavailable")
directory_flags = os.O_RDONLY | os.O_DIRECTORY \
    | getattr(os, "O_CLOEXEC", 0) | os.O_NOFOLLOW
try:
    parent_fd = os.open(parent, directory_flags)
except OSError as error:
    abort(f"cannot open bound NATS storage parent: {error}")
try:
    parent_metadata = os.fstat(parent_fd)
    if (parent_metadata.st_dev, parent_metadata.st_ino) != (
        parent_dev,
        parent_ino,
    ):
        abort("NATS storage parent identity changed")
    if fd_mount_identity(parent_fd) != parent_mount:
        abort("NATS storage parent mount identity changed")
    try:
        observed = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        abort(f"cannot inspect bound NATS storage: {error}")
    observed_mode = stat.S_IMODE(observed.st_mode)
    if not stat.S_ISDIR(observed.st_mode) or stat.S_ISLNK(observed.st_mode):
        abort("bound NATS storage name is not a directory")
    if (observed.st_dev, observed.st_ino, observed.st_uid, observed_mode) != (
        device,
        inode,
        owner,
        mode,
    ) or observed.st_nlink < link_count:
        abort("NATS storage identity changed")
    try:
        storage_fd = os.open(name, directory_flags, dir_fd=parent_fd)
    except OSError as error:
        abort(f"cannot open bound NATS storage: {error}")
    try:
        opened = os.fstat(storage_fd)
        if (opened.st_dev, opened.st_ino) != (device, inode):
            abort("NATS storage changed during validation")
        if fd_mount_identity(storage_fd) != storage_mount:
            abort("NATS storage mount identity changed")
    finally:
        os.close(storage_fd)
finally:
    os.close(parent_fd)
print(bound_path)
PY
}

_nats_port_is_open() {
    (echo >/dev/tcp/localhost/"$1") 2>/dev/null
}

_nats_health_for_port() {
    local timeout="${2:-2}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 2
    curl -sf --connect-timeout "$timeout" --max-time "$timeout" \
        "http://localhost:$1/healthz" >/dev/null 2>&1
}

_nats_monitor_identity_for_port() {
    local response timeout="${2:-2}"
    [[ "$timeout" =~ ^[1-9][0-9]*$ ]] || return 2
    response=$(curl -sf --connect-timeout "$timeout" --max-time "$timeout" \
        "http://localhost:$1/varz" 2>/dev/null) || return 1
    printf '%s' "$response" | python3 -c '
import json
import re
import sys

value = json.load(sys.stdin).get("server_name")
if not isinstance(value, str) \
        or not re.fullmatch(r"odysseus-e2e-[0-9a-f]{32}", value):
    raise SystemExit(1)
print(value)
' 2>/dev/null
}

_nats_monitor_owned_by_process() {
    local monitor_port="$1" pid="$2" timeout="${3:-2}"
    python3 - "$monitor_port" "$pid" "$timeout" <<'PY'
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
    for table in ("/proc/net/tcp", "/proc/net/tcp6"):
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

_exec_nats_with_bound_store() {
    local nats_bin="$1" client_port="$2" monitor_port="$3"
    local server_identity="$4"
    exec python3 - "$NATS_DATA_RECEIPT" "$NATS_DATA_DIR" "$nats_bin" \
        "$client_port" "$monitor_port" "$server_identity" <<'PY'
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
expected_path, binary, client_port, monitor_port, server_identity = sys.argv[2:]
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
if not os.path.isabs(binary) or not os.access(binary, os.X_OK):
    abort("NATS binary is not an executable absolute path")
if not re.fullmatch(r"odysseus-e2e-[0-9a-f]{32}", server_identity):
    abort("invalid NATS server identity")
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
    parent_fd = os.open(parent, directory_flags)
    storage_fd = os.open(name, directory_flags, dir_fd=parent_fd)
except OSError as error:
    abort(f"cannot open receipt-bound NATS storage: {error}")
try:
    parent_metadata = os.fstat(parent_fd)
    storage_metadata = os.fstat(storage_fd)
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
    os.set_inheritable(storage_fd, True)
    os.fchdir(storage_fd)
    working_metadata = os.stat(".")
    if (working_metadata.st_dev, working_metadata.st_ino) != (device, inode):
        abort("NATS working directory is not receipt-bound")
    if sys.platform.startswith("linux"):
        store_path = f"/proc/self/fd/{storage_fd}"
        linked_metadata = os.stat(store_path)
        if (linked_metadata.st_dev, linked_metadata.st_ino) != (device, inode):
            abort("inherited NATS storage descriptor is not receipt-bound")
    else:
        # Darwin's fdesc filesystem does not permit `/dev/fd/N/child`
        # traversal. The cwd itself is the already-open directory object, so
        # `.` remains bound across a later rename or same-name replacement.
        store_path = "."
    os.close(parent_fd)
    parent_fd = -1
    os.execv(
        binary,
        [
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
        ],
    )
finally:
    if parent_fd >= 0:
        os.close(parent_fd)
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
    local server_identity
    _wait_for_nats_ports_free "$NATS_PORT" "$NATS_MONITOR_PORT" 10 \
        || return 1
    _resolve_bound_nats_data_dir >/dev/null || return 1
    if ! server_identity=$(python3 -c \
        'import secrets; print("odysseus-e2e-" + secrets.token_hex(16))') \
        || ! [[ "$server_identity" =~ ^odysseus-e2e-[0-9a-f]{32}$ ]]; then
        echo "ERROR: could not create a launch-bound NATS server identity" >&2
        return 1
    fi
    _exec_nats_with_bound_store "$nats_bin" "$NATS_PORT" \
        "$NATS_MONITOR_PORT" "$server_identity" >/dev/null &
    child_pid=$!
    REGISTERED_PROCESS_IDENTITY=""
    REGISTERED_PROCESS_OWNER=""
    if ! register_pid "$child_pid"; then
        child_identity="$REGISTERED_PROCESS_IDENTITY"
        owner="$REGISTERED_PROCESS_OWNER"
        if [ -n "$child_identity" ] && [ -n "$owner" ]; then
            NATS_BG_PID="$child_pid"
            NATS_BG_IDENTITY="$child_identity"
            NATS_BG_OWNER="$owner"
            export NATS_BG_PID NATS_BG_IDENTITY NATS_BG_OWNER
            if ! _retire_unregistered_child \
                "$child_pid" "$child_identity" "$owner"; then
                echo "ERROR: retained unregistered NATS child evidence" >&2
                return 1
            fi
            NATS_BG_PID=""
            NATS_BG_IDENTITY=""
            NATS_BG_OWNER=""
            export NATS_BG_PID NATS_BG_IDENTITY NATS_BG_OWNER
        else
            echo "ERROR: NATS child registration failed before identity publication" >&2
            return 1
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
if ! python3 - "$NATS_DATA_RECEIPT" <<'PY'
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
    parent_fd = os.open(parent, directory_flags)
except OSError as error:
    abort(f"cannot open bound NATS storage parent: {error}")


def lstat_at(directory_fd, entry_name):
    return os.stat(entry_name, dir_fd=directory_fd, follow_symlinks=False)


def ensure_original_absent():
    try:
        lstat_at(parent_fd, name)
    except FileNotFoundError:
        return
    abort(
        "retained quarantined NATS storage after a same-name "
        "replacement appeared"
    )


def clear_directory(directory_fd, root_device, root_mount):
    ensure_original_absent()
    for entry_name in os.listdir(directory_fd):
        ensure_original_absent()
        before = lstat_at(directory_fd, entry_name)
        if before.st_dev != root_device:
            abort(f"refusing to cross a filesystem boundary at {entry_name}")
        if stat.S_ISDIR(before.st_mode):
            child_fd = os.open(entry_name, directory_flags, dir_fd=directory_fd)
            try:
                opened = os.fstat(child_fd)
                if (opened.st_dev, opened.st_ino) != (before.st_dev, before.st_ino):
                    abort(f"directory changed before cleanup: {entry_name}")
                child_mount = fd_mount_identity(child_fd)
                if child_mount != root_mount:
                    abort(f"refusing to cross a mount boundary at {entry_name}")
                clear_directory(child_fd, root_device, root_mount)
            finally:
                os.close(child_fd)
            after = lstat_at(directory_fd, entry_name)
            if (after.st_dev, after.st_ino) != (before.st_dev, before.st_ino):
                abort(f"directory changed during cleanup: {entry_name}")
            os.rmdir(entry_name, dir_fd=directory_fd)
        else:
            after = lstat_at(directory_fd, entry_name)
            if (after.st_dev, after.st_ino, stat.S_IFMT(after.st_mode)) != (
                before.st_dev,
                before.st_ino,
                stat.S_IFMT(before.st_mode),
            ):
                abort(f"entry changed during cleanup: {entry_name}")
            os.unlink(entry_name, dir_fd=directory_fd)
    ensure_original_absent()


try:
    bound_parent = os.fstat(parent_fd)
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
    storage_fd = os.open(name, directory_flags, dir_fd=parent_fd)
    try:
        opened = os.fstat(storage_fd)
        if (opened.st_dev, opened.st_ino) != (device, inode):
            abort("NATS storage changed before no-follow cleanup")
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
        quarantine_fd = os.open(
            quarantine_name, directory_flags, dir_fd=parent_fd
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
                abort("quarantined NATS storage identity changed")
            ensure_original_absent()
            clear_directory(quarantine_fd, device, storage_mount)
        finally:
            os.close(quarantine_fd)
    finally:
        os.close(storage_fd)
    final = lstat_at(parent_fd, quarantine_name)
    if (final.st_dev, final.st_ino, final.st_uid, stat.S_IMODE(final.st_mode)) != (
        device,
        inode,
        owner,
        mode,
    ) or final.st_nlink != link_count:
        abort("NATS storage changed before final removal")
    ensure_original_absent()
    os.rmdir(quarantine_name, dir_fd=parent_fd)
    try:
        lstat_at(parent_fd, quarantine_name)
    except FileNotFoundError:
        pass
    else:
        abort("NATS storage quarantine remains after cleanup")
    ensure_original_absent()
finally:
    os.close(parent_fd)
PY
    then
        printf 'ERROR: retained NATS storage receipt after cleanup failure: %s\n' \
            "$NATS_DATA_RECEIPT" >&2
        return 1
    fi
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

start_agamemnon_bg() {
    local bin=""
    local odysseus_root="${ODYSSEUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    # Search for the binary in known locations
    for candidate in \
        "${odysseus_root}/build/Agamemnon/Agamemnon_server" \
        "${odysseus_root}/control/Agamemnon/build/debug/Agamemnon_server" \
        "$(command -v Agamemnon_server 2>/dev/null)"; do
        [ -x "$candidate" ] && bin="$candidate" && break
    done
    [ -z "$bin" ] && { echo "ERROR: Agamemnon_server not found. Run 'just build' first." >&2; return 1; }

    # Agamemnon (server_main.cpp) FATAL-exits if AGAMEMNON_API_KEY is unset/empty,
    # and once set enforces it on non-exempt /v1/* endpoints. Launch with the same
    # key the REST helpers send (e2e/lib/agamemnon.sh AGAMEMNON_AUTH); default to
    # the shared test key so a keyless env still starts.
    NATS_URL="nats://localhost:${NATS_PORT}" PORT="$AGAMEMNON_PORT" \
        AGAMEMNON_API_KEY="${AGAMEMNON_API_KEY:-e2e-test-key}" "$bin" >/dev/null 2>&1 &
    local agamemnon_pid=$!
    if ! register_pid "$agamemnon_pid"; then
        kill -KILL "$agamemnon_pid" 2>/dev/null || :
        wait "$agamemnon_pid" 2>/dev/null || :
        return 1
    fi
    echo "  Started Agamemnon (PID $agamemnon_pid, port $AGAMEMNON_PORT)"
    wait_for "http://localhost:${AGAMEMNON_PORT}/v1/health" "Agamemnon" 20
}

# ─── Hello Myrmidon ──────────────────────────────────────────────────────────

start_myrmidon_bg() {
    local odysseus_root="${ODYSSEUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local bin=""
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

    # MYRMIDON_WORK_DELAY_MS=0: drop the worker's default 1s/task "simulate work"
    # delay so fan-out perf scenarios (B07 50 tasks, B08 100 tasks) drain at real
    # dispatch speed instead of being capped at ~1 task/sec by MaxAckPending=1.
    NATS_URL="nats://localhost:${NATS_PORT}" MYRMIDON_WORK_DELAY_MS="${MYRMIDON_WORK_DELAY_MS:-0}" \
        "$bin" >/dev/null 2>&1 &
    local myrmidon_pid=$!
    if ! register_pid "$myrmidon_pid"; then
        kill -KILL "$myrmidon_pid" 2>/dev/null || :
        wait "$myrmidon_pid" 2>/dev/null || :
        return 1
    fi
    echo "  Started hello-myrmidon (PID $myrmidon_pid, bin $bin)"
    sleep 2  # Allow subscription to establish
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
export -f _valid_pid _process_receipt_store_op _ensure_process_receipt_store \
    _persist_process_receipts _sync_process_receipts _process_receipt \
    _process_identity_status _signal_bound_process _retire_unregistered_child \
    register_pid unregister_pid \
    _resolve_bound_nats_data_dir _nats_port_is_open _nats_health_for_port \
    _nats_monitor_identity_for_port _nats_monitor_owned_by_process \
    _wait_for_nats_ports_free \
    _exec_nats_with_bound_store _wait_for_registered_nats \
    _start_nats_guarded
