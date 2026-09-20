#!/usr/bin/env python3
"""Bind and publish reports without name-based replacement or cleanup races."""

import base64
import binascii
import configparser
from contextlib import contextmanager
import ctypes
import errno
import fcntl
import hashlib
import json
import math
import os
import re
import resource
import select
import selectors
import signal
import stat
import struct
import subprocess
import sys
import tempfile
import time


OPERATIONS = {"append", "replace"}
CANDIDATE_TARGETS = {
    "ecosystem-health": ("odysseus-ecosystem-health-candidate.", "ecosystem-status.md"),
    "ecosystem-table": ("odysseus-ecosystem-table-candidate.", "ecosystem-table.md"),
}
TOKEN_VERSION = 2
MAX_REPORT_BYTES = 4 * 1024 * 1024
READ_CHUNK_BYTES = 65536
MAX_PATH_BYTES = 4096
MAX_COMPONENT_BYTES = 255
MAX_ROUTE_COMPONENTS = 256
MAX_TOKEN_BYTES = 128 * 1024
CANDIDATE_ATTEMPTS = 16
CANDIDATE_PREFIX = ".odysseus-report-quarantine-"
MAX_QUARANTINE_FILES = 16
MAX_QUARANTINE_BYTES = 64 * 1024 * 1024
MAX_PARENT_ENTRIES = 4096
MAX_COMMAND_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_COMMAND_TIMEOUT_SECONDS = 300
MAX_OPERATION_TIMEOUT_SECONDS = 900
MAX_EXECUTABLE_BYTES = 128 * 1024 * 1024
MAX_TEST_SCRIPT_BYTES = 64 * 1024
EXECUTABLE_TOKEN_VERSION = 2
LINUX_RENAME_NOREPLACE = 1
DARWIN_RENAME_EXCL = 0x00000004
PROCESS_STATUS_BYTES = 5
PROCESS_ACQUISITION_BYTES = 5
PROCESS_POLL_SECONDS = 0.01
PROCESS_MAX_ADDRESS_SPACE_BYTES = 2 * 1024 * 1024 * 1024
PROCESS_MAX_OPEN_FILES = 256
PROCESS_MAX_PROCESSES = 128


EXECUTABLE_CANDIDATES = {
    "gh": (
        "/usr/bin/gh",
        "/usr/local/bin/gh",
        "/opt/homebrew/bin/gh",
    ),
}
# The first two variables authenticate github.com and are the only credentials
# forwarded by that command profile. Any member blocks the credential-free
# portable test seam.
GITHUB_CREDENTIAL_VARIABLES = (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
)


class ReportUpdateUnavailable(OSError):
    """The runtime cannot atomically move the exact verified report object."""


_PROCESS_SUPERVISOR = r"""
import ctypes
import os
import resource
import select
import signal
import struct
import subprocess
import sys
import time
import traceback

status_descriptor = int(sys.argv[1])
acquisition_descriptor = int(sys.argv[2])
inherited_descriptors = tuple(
    int(value) for value in sys.argv[3].split(",") if value
)
target_executable = sys.argv[4] or None
target_cwd = sys.argv[5] or None
expected_parent = int(sys.argv[6])
target = None
target_returncode = 125
detached_descendant = False
stop_requested = [False]
owned = {}

def request_stop(_signum, _frame):
    stop_requested[0] = True

for signal_number in (
    signal.SIGTERM,
    signal.SIGINT,
    signal.SIGHUP,
    signal.SIGQUIT,
):
    signal.signal(signal_number, request_stop)
if hasattr(signal, "pthread_sigmask"):
    signal.pthread_sigmask(signal.SIG_SETMASK, set())

def bounded_limit(kind, ceiling):
    soft, hard = resource.getrlimit(kind)
    bounded_hard = ceiling if hard == resource.RLIM_INFINITY else min(hard, ceiling)
    bounded_soft = bounded_hard if soft == resource.RLIM_INFINITY else min(soft, bounded_hard)
    resource.setrlimit(kind, (bounded_soft, bounded_hard))

def enable_linux_containment(parent_process_id):
    if not sys.platform.startswith("linux"):
        return False
    if not callable(getattr(os, "pidfd_open", None)) or not callable(
        getattr(signal, "pidfd_send_signal", None)
    ):
        raise RuntimeError("Linux pidfd containment is unavailable")
    library = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(library, "prctl", None)
    if prctl is None:
        raise RuntimeError("Linux subreaper containment is unavailable")
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    if parent_process_id <= 1:
        raise RuntimeError("trusted supervisor parent identity is invalid")
    ctypes.set_errno(0)
    if prctl(1, signal.SIGTERM, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not bind parent death")
    if os.getppid() != parent_process_id:
        raise RuntimeError("trusted supervisor parent exited during acquisition")
    ctypes.set_errno(0)
    if prctl(36, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not enable subreaper")
    state = ctypes.c_int(0)
    ctypes.set_errno(0)
    if prctl(37, ctypes.addressof(state), 0, 0, 0) != 0 or state.value != 1:
        raise OSError(ctypes.get_errno() or 1, "could not verify subreaper")
    return True

def proc_bytes(path, maximum):
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        content = bytearray()
        while len(content) <= maximum:
            block = os.read(descriptor, min(65536, maximum - len(content) + 1))
            if not block:
                return bytes(content)
            content.extend(block)
        raise RuntimeError("process inventory exceeded its byte ceiling")
    finally:
        os.close(descriptor)

def identity(process_id):
    try:
        content = proc_bytes(f"/proc/{process_id}/stat", 65536)
    except (FileNotFoundError, ProcessLookupError):
        return None
    closing = content.rfind(b")")
    fields = content[closing + 2:].split() if closing >= 1 else ()
    if len(fields) <= 19:
        raise RuntimeError("process identity is malformed")
    return process_id, int(fields[19])

def process_group(process_id):
    try:
        content = proc_bytes(f"/proc/{process_id}/stat", 65536)
    except (FileNotFoundError, ProcessLookupError):
        return None
    closing = content.rfind(b")")
    fields = content[closing + 2:].split() if closing >= 1 else ()
    if len(fields) <= 2:
        raise RuntimeError("process identity is malformed")
    return int(fields[2])

def children(process_id):
    root = f"/proc/{process_id}/task"
    try:
        tasks = tuple(entry.name for entry in os.scandir(root) if entry.name.isdecimal())
    except (FileNotFoundError, ProcessLookupError):
        return set()
    result = set()
    for task in tasks:
        try:
            content = proc_bytes(f"{root}/{task}/children", 1024 * 1024)
        except (FileNotFoundError, ProcessLookupError):
            continue
        for value in content.split():
            if not value.isdigit():
                raise RuntimeError("child inventory is malformed")
            child = int(value)
            if child > 1:
                result.add(child)
    return result

def track(process_id):
    current = identity(process_id)
    if current is None:
        return False
    previous = owned.get(process_id)
    if previous is not None and previous[0] == current[1]:
        return False
    descriptor = os.pidfd_open(process_id, 0)
    if identity(process_id) != current:
        os.close(descriptor)
        return False
    if previous is not None:
        os.close(previous[1])
    owned[process_id] = (current[1], descriptor)
    return True

def discover():
    changed_any = False
    while True:
        candidates = set(children(os.getpid()))
        for process_id, (start_time, _descriptor) in tuple(owned.items()):
            if identity(process_id) == (process_id, start_time):
                candidates.update(children(process_id))
        changed = False
        for process_id in candidates:
            try:
                changed = track(process_id) or changed
            except ProcessLookupError:
                pass
        changed_any = changed_any or changed
        if not changed:
            return changed_any

def exited(descriptor):
    readable, _writable, _exceptional = select.select([descriptor], [], [], 0)
    return bool(readable)

def live():
    discover()
    active = tuple(
        (process_id, descriptor)
        for process_id, (_start_time, descriptor) in owned.items()
        if not exited(descriptor)
    )
    if active:
        return active
    unchanged = 0
    while unchanged < 2:
        changed = discover()
        active = tuple(
            (process_id, descriptor)
            for process_id, (_start_time, descriptor) in owned.items()
            if not exited(descriptor)
        )
        if active:
            return active
        unchanged = 0 if changed else unchanged + 1
    return ()

def mark_detached(supervisor_group):
    global detached_descendant
    for process_id, _descriptor in live():
        if target is not None and process_id == target.pid:
            continue
        group = process_group(process_id)
        if group is not None and group != supervisor_group:
            detached_descendant = True

def reap_owned():
    pending = {
        process_id for process_id in owned
        if target is None or process_id != target.pid
    }
    deadline = time.monotonic() + 0.5
    while pending:
        changed = False
        for process_id in tuple(pending):
            try:
                reaped, _status = os.waitpid(process_id, os.WNOHANG)
            except ChildProcessError:
                pending.remove(process_id)
                changed = True
                continue
            if reaped == process_id:
                pending.remove(process_id)
                changed = True
        if not pending:
            return
        if time.monotonic() >= deadline:
            raise RuntimeError("owned descendants could not be reaped")
        if not changed:
            time.sleep(0.005)

def extinguish(supervisor_group):
    mark_detached(supervisor_group)
    for number, interval in ((signal.SIGTERM, 0.1), (signal.SIGKILL, 0.3)):
        deadline = time.monotonic() + interval
        while True:
            mark_detached(supervisor_group)
            active = live()
            if not active:
                break
            for _process_id, descriptor in active:
                try:
                    signal.pidfd_send_signal(descriptor, number, None, 0)
                except ProcessLookupError:
                    pass
            if time.monotonic() >= deadline:
                break
            time.sleep(0.005)
    if live():
        raise RuntimeError("owned descendants survived containment cleanup")
    if target is not None and target.returncode is None:
        target.wait(timeout=0.5)
    reap_owned()

try:
    address_space = int(sys.argv[7])
    cpu_seconds = int(sys.argv[8])
    open_files = int(sys.argv[9])
    process_count = int(sys.argv[10])
    bounded_limit(resource.RLIMIT_AS, address_space)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    bounded_limit(resource.RLIMIT_CPU, cpu_seconds)
    bounded_limit(resource.RLIMIT_NOFILE, open_files)
    bounded_limit(resource.RLIMIT_NPROC, process_count)
    linux_containment = enable_linux_containment(expected_parent)
    if stop_requested[0]:
        raise RuntimeError("trusted supervisor parent exited before target launch")
    target = subprocess.Popen(
        sys.argv[11:], executable=target_executable,
        pass_fds=inherited_descriptors, cwd=target_cwd
    )
    os.write(acquisition_descriptor, struct.pack("!BI", 1, target.pid))
    os.close(acquisition_descriptor)
    acquisition_descriptor = -1
    if linux_containment:
        track(target.pid)
        supervisor_group = os.getpgrp()
        while target.poll() is None and not stop_requested[0]:
            mark_detached(supervisor_group)
            time.sleep(0.005)
        observed_returncode = target.poll()
        extinguish(supervisor_group)
        if observed_returncode is None:
            observed_returncode = target.returncode
        if observed_returncode is None:
            raise RuntimeError("target process status is unavailable")
        target_returncode = observed_returncode
    else:
        target_returncode = target.wait()
except BaseException:
    if target is None:
        try:
            os.write(acquisition_descriptor, struct.pack("!BI", 0, 0))
        except OSError:
            pass
    elif sys.platform.startswith("linux"):
        try:
            extinguish(os.getpgrp())
        except BaseException:
            traceback.print_exc()
    traceback.print_exc()
    target_returncode = 125
if acquisition_descriptor >= 0:
    os.close(acquisition_descriptor)
for _start_time, descriptor in owned.values():
    os.close(descriptor)
os.write(
    status_descriptor,
    struct.pack("!iB", target_returncode, int(detached_descendant)),
)
os.close(status_descriptor)
os.close(1)
os.close(2)
"""


def required_flag(name):
    value = getattr(os, name, None)
    if value is None or value == 0:
        raise OSError(f"{name} is required")
    return value


DIRECTORY_FLAGS = (
    os.O_RDONLY
    | required_flag("O_DIRECTORY")
    | required_flag("O_NOFOLLOW")
    | required_flag("O_CLOEXEC")
)
NONBLOCK = required_flag("O_NONBLOCK")
READ_FLAGS = (
    os.O_RDONLY
    | required_flag("O_NOFOLLOW")
    | required_flag("O_CLOEXEC")
    | NONBLOCK
)
WRITE_FLAGS = (
    os.O_RDWR
    | required_flag("O_NOFOLLOW")
    | required_flag("O_CLOEXEC")
    | NONBLOCK
)


@contextmanager
def defer_termination_signals():
    """Keep asynchronous termination outside descriptor mutation/verification."""
    mask_signals = getattr(signal, "pthread_sigmask", None)
    block = getattr(signal, "SIG_BLOCK", None)
    restore = getattr(signal, "SIG_SETMASK", None)
    guarded = {
        candidate
        for name in ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM")
        if isinstance((candidate := getattr(signal, name, None)), int)
    }
    if mask_signals is None or block is None or restore is None or not guarded:
        raise OSError("termination-signal masking is required")
    previous = mask_signals(block, guarded)
    try:
        yield
    finally:
        mask_signals(restore, previous)


def require_report_size(size):
    if size > MAX_REPORT_BYTES:
        raise OSError("report content exceeds the size ceiling")


def read_all(descriptor):
    chunks = []
    size = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(
            descriptor,
            min(READ_CHUNK_BYTES, MAX_REPORT_BYTES - size + 1),
        )
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        require_report_size(size)
        chunks.append(chunk)


def read_stream(stream):
    chunks = []
    size = 0
    while True:
        chunk = stream.read(min(READ_CHUNK_BYTES, MAX_REPORT_BYTES - size + 1))
        if not chunk:
            return b"".join(chunks)
        size += len(chunk)
        require_report_size(size)
        chunks.append(chunk)


def write_all(descriptor, content):
    remaining = memoryview(content)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("report write made no progress")
        remaining = remaining[written:]


def replace_descriptor_content(descriptor, content):
    """Replace bytes through an already approved descriptor."""
    require_report_size(len(content))
    os.lseek(descriptor, 0, os.SEEK_SET)
    os.ftruncate(descriptor, 0)
    write_all(descriptor, content)
    os.ftruncate(descriptor, len(content))
    os.fsync(descriptor)
    if read_all(descriptor) != content:
        raise OSError("published report content changed")


def rename_function(name, argument_types):
    library = ctypes.CDLL(None, use_errno=True)
    function = getattr(library, name, None)
    if function is None:
        raise NotImplementedError(f"{name} is unavailable")
    function.argtypes = argument_types
    function.restype = ctypes.c_int
    return function


def call_rename(function, parent_descriptor, source, destination, flags):
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    ctypes.set_errno(0)
    result = function(
        parent_descriptor,
        source_bytes,
        parent_descriptor,
        destination_bytes,
        flags,
    )
    if result != 0:
        error_number = ctypes.get_errno() or errno.EIO
        raise OSError(error_number, os.strerror(error_number))


def atomic_noreplace(parent_descriptor, source, destination):
    if sys.platform == "darwin":
        function = rename_function(
            "renameatx_np",
            [
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            ],
        )
        flag = DARWIN_RENAME_EXCL
    elif sys.platform.startswith("linux"):
        function = rename_function(
            "renameat2",
            [
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_int,
                ctypes.c_char_p,
                ctypes.c_uint,
            ],
        )
        flag = LINUX_RENAME_NOREPLACE
    else:
        raise NotImplementedError("atomic report publication is unsupported")
    call_rename(function, parent_descriptor, source, destination, flag)


def file_record(metadata, content):
    return {
        "ctime_ns": metadata.st_ctime_ns,
        "dev": metadata.st_dev,
        "digest": hashlib.sha256(content).hexdigest(),
        "gid": metadata.st_gid,
        "ino": metadata.st_ino,
        "mode": metadata.st_mode,
        "mtime_ns": metadata.st_mtime_ns,
        "nlink": metadata.st_nlink,
        "size": metadata.st_size,
        "uid": metadata.st_uid,
    }


def file_identity(metadata):
    return {
        "dev": metadata.st_dev,
        "gid": metadata.st_gid,
        "ino": metadata.st_ino,
        "mode": metadata.st_mode,
        "nlink": metadata.st_nlink,
        "uid": metadata.st_uid,
    }


def parent_record(metadata):
    return {
        "dev": metadata.st_dev,
        "gid": metadata.st_gid,
        "ino": metadata.st_ino,
        "mode": metadata.st_mode,
        "uid": metadata.st_uid,
    }


def route_entry(name, metadata):
    return {"name": name, "state": parent_record(metadata)}


def require_private_parent(metadata):
    if not stat.S_ISDIR(metadata.st_mode):
        raise OSError("report parent is not a directory")
    if metadata.st_uid != os.geteuid():
        raise OSError("report parent is not owned by the current user")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise OSError("report parent is writable by another user class")


def require_direct_file(metadata):
    if not stat.S_ISREG(metadata.st_mode):
        raise OSError("report entry is not a direct regular file")
    if metadata.st_uid != os.geteuid() or metadata.st_nlink != 1:
        raise OSError("report entry is not one owner-bound file")


def split_target(target):
    if not isinstance(target, str):
        raise TypeError("report destination must be text")
    absolute = os.path.abspath(target)
    parent = os.path.dirname(absolute)
    name = os.path.basename(absolute)
    if name in {"", ".", ".."}:
        raise OSError("invalid report destination name")
    if len(os.fsencode(absolute)) > MAX_PATH_BYTES:
        raise OSError("report destination path is too long")
    if len(os.fsencode(name)) > MAX_COMPONENT_BYTES:
        raise OSError("report destination name is too long")
    return absolute, parent, name


def candidate_target(kind):
    try:
        prefix, filename = CANDIDATE_TARGETS[kind]
    except KeyError as error:
        raise ValueError("unsupported report candidate kind") from error

    override = os.environ.get("ODYSSEUS_TEST_CANDIDATE_ROOT")
    if override is not None:
        if os.environ.get("ODYSSEUS_TEST_RUNTIME") != "1":
            raise OSError("candidate root override is test-only")
        root = os.path.abspath(override)
    else:
        root = os.path.realpath("/tmp")
    if not os.path.isabs(root) or os.path.realpath(root) != root:
        raise OSError("unsafe report candidate root")
    root_state = os.lstat(root)
    root_mode = stat.S_IMODE(root_state.st_mode)
    private_root = (
        root_state.st_uid == os.geteuid() and not root_mode & 0o022
    )
    shared_sticky_root = (
        root_state.st_uid == 0
        and bool(root_mode & stat.S_ISVTX)
        and bool(root_mode & 0o002)
    )
    if not stat.S_ISDIR(root_state.st_mode) or not (
        private_root or shared_sticky_root
    ):
        raise OSError("unsafe report candidate root")

    previous_umask = os.umask(0o077)
    try:
        directory = tempfile.mkdtemp(prefix=prefix, dir=root)
    finally:
        os.umask(previous_umask)
    directory_state = os.lstat(directory)
    if (
        os.path.dirname(directory) != root
        or os.path.realpath(directory) != directory
        or not stat.S_ISDIR(directory_state.st_mode)
        or directory_state.st_uid != os.geteuid()
        or stat.S_IMODE(directory_state.st_mode) != 0o700
    ):
        raise OSError("unsafe report candidate directory")
    target = os.path.join(directory, filename)
    absolute, _parent, _name = split_target(target)
    if os.path.lexists(absolute):
        raise OSError("report candidate target is not absent")
    return absolute


def parent_components(parent):
    if not os.path.isabs(parent):
        raise OSError("report parent must be absolute")
    components = [component for component in parent.split(os.sep) if component]
    if len(components) > MAX_ROUTE_COMPONENTS:
        raise OSError("report parent has too many components")
    for component in components:
        if component in {".", ".."} or len(os.fsencode(component)) > MAX_COMPONENT_BYTES:
            raise OSError("invalid report parent component")
    return components


def close_route(descriptors):
    for descriptor in reversed(descriptors):
        os.close(descriptor)


def open_parent(parent, expected_route=None):
    components = parent_components(parent)
    descriptors = []
    route = []
    try:
        root_descriptor = os.open(os.sep, DIRECTORY_FLAGS)
        descriptors.append(root_descriptor)
        route.append(route_entry("", os.fstat(root_descriptor)))
        for component in components:
            descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptors[-1])
            descriptors.append(descriptor)
            route.append(route_entry(component, os.fstat(descriptor)))
        require_private_parent(os.fstat(descriptors[-1]))
        if expected_route is not None and route != expected_route:
            raise OSError("report parent route changed")
        return descriptors, route
    except BaseException:
        close_route(descriptors)
        raise


def verify_held_route(descriptors, expected_route):
    if len(descriptors) != len(expected_route):
        raise OSError("report parent route changed")
    for descriptor, expected in zip(descriptors, expected_route):
        if parent_record(os.fstat(descriptor)) != expected["state"]:
            raise OSError("held report parent route changed")


def verify_parent_path(parent, expected_route):
    descriptors, _route = open_parent(parent, expected_route)
    try:
        verify_held_route(descriptors, expected_route)
    finally:
        close_route(descriptors)


def open_bound_file(parent_descriptor, name, flags):
    try:
        named_before = os.lstat(name, dir_fd=parent_descriptor)
    except FileNotFoundError:
        return -1, None, None
    require_direct_file(named_before)
    descriptor = os.open(name, flags, dir_fd=parent_descriptor)
    try:
        opened_before = os.fstat(descriptor)
        require_direct_file(opened_before)
        if file_identity(opened_before) != file_identity(named_before):
            raise OSError("report entry changed while opening")
        content = read_all(descriptor)
        opened_after = os.fstat(descriptor)
        named_after = os.lstat(name, dir_fd=parent_descriptor)
        require_direct_file(opened_after)
        require_direct_file(named_after)
        if file_record(opened_before, content) != file_record(opened_after, content):
            raise OSError("report entry changed while reading")
        if file_identity(opened_after) != file_identity(named_after):
            raise OSError("report entry name changed while reading")
        return descriptor, content, file_record(opened_after, content)
    except Exception:
        os.close(descriptor)
        raise


def build_content(operation, existing, replacement):
    require_report_size(len(replacement))
    if existing is not None:
        require_report_size(len(existing))
    if operation == "replace":
        return replacement
    if operation == "append":
        existing = existing or b""
        require_report_size(len(existing) + len(replacement))
        return existing + replacement
    raise ValueError("unsupported report operation")


def encode_token(token):
    raw = json.dumps(token, sort_keys=True, separators=(",", ":")).encode("utf-8")
    if len(raw) > MAX_TOKEN_BYTES:
        raise ValueError("report binding is too large")
    return base64.urlsafe_b64encode(raw).decode("ascii")


def validate_record(record, keys, label):
    if not isinstance(record, dict) or set(record) != keys:
        raise ValueError(f"invalid report {label} binding")
    for key, value in record.items():
        if key == "digest":
            if (
                not isinstance(value, str)
                or len(value) != 64
                or any(character not in "0123456789abcdef" for character in value)
            ):
                raise ValueError("invalid report destination digest")
            continue
        if isinstance(value, bool) or not isinstance(value, int) or value < 0:
            raise ValueError(f"invalid report {label} state")


def validate_route(route, parent):
    components = parent_components(parent)
    if (
        not isinstance(route, list)
        or len(route) != len(components) + 1
        or len(route) > MAX_ROUTE_COMPONENTS + 1
    ):
        raise ValueError("invalid report parent route")
    expected_names = ["", *components]
    for index, (entry, expected_name) in enumerate(zip(route, expected_names)):
        if not isinstance(entry, dict) or set(entry) != {"name", "state"}:
            raise ValueError("invalid report parent route entry")
        name = entry["name"]
        if not isinstance(name, str) or name != expected_name:
            raise ValueError("invalid report parent route name")
        if index and (
            name in {"", ".", ".."}
            or len(os.fsencode(name)) > MAX_COMPONENT_BYTES
        ):
            raise ValueError("invalid report parent route component")
        validate_record(
            entry["state"],
            {"dev", "gid", "ino", "mode", "uid"},
            "route",
        )


def decode_token(encoded):
    if not isinstance(encoded, str) or len(encoded.encode("utf-8")) > (
        (MAX_TOKEN_BYTES * 4 // 3) + 8
    ):
        raise ValueError("invalid report binding size")
    raw = base64.b64decode(encoded.encode("ascii"), altchars=b"-_", validate=True)
    if len(raw) > MAX_TOKEN_BYTES:
        raise ValueError("invalid report binding size")
    token = json.loads(raw.decode("utf-8"))
    if not isinstance(token, dict) or set(token) != {
        "destination",
        "name",
        "operation",
        "parent",
        "path",
        "route",
        "version",
    }:
        raise ValueError("invalid report binding")
    if token["version"] != TOKEN_VERSION or token["operation"] not in OPERATIONS:
        raise ValueError("invalid report binding version or operation")
    if not isinstance(token["path"], str) or not isinstance(token["name"], str):
        raise ValueError("invalid report binding path")
    absolute, parent, name = split_target(token["path"])
    if absolute != token["path"] or name != token["name"]:
        raise ValueError("invalid report binding path")
    validate_record(token["parent"], {"dev", "gid", "ino", "mode", "uid"}, "parent")
    validate_route(token["route"], parent)
    if token["route"][-1]["state"] != token["parent"]:
        raise ValueError("invalid report parent binding")
    if token["destination"] is not None:
        validate_record(
            token["destination"],
            {
                "ctime_ns",
                "dev",
                "digest",
                "gid",
                "ino",
                "mode",
                "mtime_ns",
                "nlink",
                "size",
                "uid",
            },
            "destination",
        )
    return token


def executable_record(metadata):
    return {
        "ctime_ns": metadata.st_ctime_ns,
        "dev": metadata.st_dev,
        "gid": metadata.st_gid,
        "ino": metadata.st_ino,
        "mode": metadata.st_mode,
        "mtime_ns": metadata.st_mtime_ns,
        "nlink": metadata.st_nlink,
        "size": metadata.st_size,
        "uid": metadata.st_uid,
    }


def validate_executable_metadata(metadata):
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_nlink != 1
        or metadata.st_uid not in {0, os.geteuid()}
        or stat.S_IMODE(metadata.st_mode) & 0o022
        or stat.S_IMODE(metadata.st_mode) & 0o111 == 0
    ):
        raise OSError("unsafe command executable")


def open_executable(path, expected=None):
    if (
        not isinstance(path, str)
        or not os.path.isabs(path)
        or len(os.fsencode(path)) > MAX_PATH_BYTES
        or os.path.realpath(path) != path
    ):
        raise OSError("unsafe command executable path")
    parent, name = os.path.dirname(path), os.path.basename(path)
    descriptors, route = open_parent_for_execution(parent)
    parent_descriptor = descriptors[-1]
    executable_descriptor = -1
    try:
        named = os.lstat(name, dir_fd=parent_descriptor)
        validate_executable_metadata(named)
        executable_descriptor = os.open(name, READ_FLAGS, dir_fd=parent_descriptor)
        opened = os.fstat(executable_descriptor)
        validate_executable_metadata(opened)
        current = executable_record(opened)
        if current != executable_record(named):
            raise OSError("command executable changed while opening")
        if expected is not None and current != expected:
            raise OSError("command executable changed after binding")
        rebound = os.lstat(name, dir_fd=parent_descriptor)
        if executable_record(rebound) != current:
            raise OSError("command executable name changed while opening")
        return executable_descriptor, descriptors, route, current
    except BaseException:
        if executable_descriptor >= 0:
            os.close(executable_descriptor)
        close_route(descriptors)
        raise


def require_execution_directory(metadata):
    mode = stat.S_IMODE(metadata.st_mode)
    sticky_root = metadata.st_uid == 0 and mode & stat.S_ISVTX
    owner_group = metadata.st_uid == os.geteuid() and metadata.st_gid in {
        os.getegid(),
        *os.getgroups(),
    }
    writable_by_other = bool(mode & 0o002)
    writable_by_group = bool(mode & 0o020)
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in {
        0,
        os.geteuid(),
    }:
        raise OSError("unsafe command executable route")
    if writable_by_other and not sticky_root:
        raise OSError("unsafe command executable route")
    if writable_by_group and not owner_group and not sticky_root:
        raise OSError("unsafe command executable route")


def open_parent_for_execution(parent):
    components = parent_components(parent)
    descriptors = []
    route = []
    try:
        descriptor = os.open(os.sep, DIRECTORY_FLAGS)
        descriptors.append(descriptor)
        require_execution_directory(os.fstat(descriptor))
        route.append(route_entry("", os.fstat(descriptor)))
        for component in components:
            descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptors[-1])
            descriptors.append(descriptor)
            require_execution_directory(os.fstat(descriptor))
            route.append(route_entry(component, os.fstat(descriptor)))
        return descriptors, route
    except BaseException:
        close_route(descriptors)
        raise


def read_executable_digest(descriptor):
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
            raise OSError("command executable exceeds the size ceiling")
        digest.update(chunk)


def copy_executable(source, destination):
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
            raise OSError("command executable exceeds the size ceiling")
        digest.update(chunk)
        remaining = memoryview(chunk)
        while remaining:
            written = os.write(destination, remaining)
            if written <= 0:
                raise OSError("command executable snapshot made no progress")
            remaining = remaining[written:]


def required_seals():
    names = (
        "F_ADD_SEALS",
        "F_GET_SEALS",
        "F_SEAL_GROW",
        "F_SEAL_SEAL",
        "F_SEAL_SHRINK",
        "F_SEAL_WRITE",
    )
    values = {name: getattr(fcntl, name, None) for name in names}
    if any(not isinstance(value, int) for value in values.values()):
        raise NotImplementedError("sealed command execution is unavailable")
    seals = (
        values["F_SEAL_GROW"]
        | values["F_SEAL_SEAL"]
        | values["F_SEAL_SHRINK"]
        | values["F_SEAL_WRITE"]
    )
    return values["F_ADD_SEALS"], values["F_GET_SEALS"], seals


def verify_sealed_executable(descriptor, size, digest):
    _add_operation, get_operation, required = required_seals()
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_size != size
        or stat.S_IMODE(metadata.st_mode) & 0o111 == 0
        or fcntl.fcntl(descriptor, get_operation) & required != required
    ):
        raise OSError("unsafe sealed command executable")
    current_size, current_digest = read_executable_digest(descriptor)
    if current_size != size or current_digest != digest:
        raise OSError("sealed command executable content changed")
    if fcntl.fcntl(descriptor, get_operation) & required != required:
        raise OSError("sealed command executable seals changed")


def create_sealed_executable(source, expected):
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("sealed command execution is unsupported")
    creator = getattr(os, "memfd_create", None)
    cloexec = getattr(os, "MFD_CLOEXEC", None)
    allow_sealing = getattr(os, "MFD_ALLOW_SEALING", None)
    if (
        creator is None
        or not isinstance(cloexec, int)
        or not isinstance(allow_sealing, int)
    ):
        raise NotImplementedError("sealed command execution is unavailable")
    add_operation, _get_operation, seals = required_seals()
    if executable_record(os.fstat(source)) != expected:
        raise OSError("command executable changed before sealing")
    descriptor = creator("odysseus-gh", cloexec | allow_sealing)
    try:
        size, digest = copy_executable(source, descriptor)
        if executable_record(os.fstat(source)) != expected:
            raise OSError("command executable changed while sealing")
        os.fchmod(descriptor, 0o500)
        fcntl.fcntl(descriptor, add_operation, seals)
        verify_sealed_executable(descriptor, size, digest)
        return descriptor, size, digest
    except BaseException:
        os.close(descriptor)
        raise


@contextmanager
def executable_launch(descriptor, expected):
    sealed_descriptor = -1
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("sealed command execution is unsupported")
    try:
        sealed_descriptor, size, digest = create_sealed_executable(
            descriptor,
            expected,
        )
        launch_path = f"/proc/self/fd/{sealed_descriptor}"
        try:
            linked = os.stat(launch_path)
        except OSError as error:
            raise NotImplementedError(
                "sealed descriptor execution is unavailable"
            ) from error
        held = os.fstat(sealed_descriptor)
        if held.st_dev != linked.st_dev or held.st_ino != linked.st_ino:
            raise OSError("sealed command descriptor route changed")
        verify_sealed_executable(sealed_descriptor, size, digest)
        yield launch_path, (sealed_descriptor,)
    finally:
        if sealed_descriptor >= 0:
            os.close(sealed_descriptor)


def resolve_executable(tool, override=""):
    if tool not in EXECUTABLE_CANDIDATES or not isinstance(override, str):
        raise ValueError("unsupported command executable")
    if override:
        candidates = (override,)
    else:
        candidates = EXECUTABLE_CANDIDATES[tool]
    for candidate in candidates:
        resolved = os.path.realpath(candidate)
        try:
            descriptor, descriptors, route, record = open_executable(resolved)
        except (FileNotFoundError, NotADirectoryError, OSError):
            continue
        try:
            return encode_token(
                {
                    "path": resolved,
                    "record": record,
                    "route": route,
                    "test_only": bool(override),
                    "tool": tool,
                    "version": EXECUTABLE_TOKEN_VERSION,
                }
            )
        finally:
            os.close(descriptor)
            close_route(descriptors)
    raise OSError(f"trusted {tool} executable is unavailable")


def decode_executable_token(encoded, tool):
    if not isinstance(encoded, str) or len(encoded.encode("utf-8")) > (
        (MAX_TOKEN_BYTES * 4 // 3) + 8
    ):
        raise ValueError("invalid command binding size")
    raw = base64.b64decode(encoded.encode("ascii"), altchars=b"-_", validate=True)
    if len(raw) > MAX_TOKEN_BYTES:
        raise ValueError("invalid command binding size")
    token = json.loads(raw.decode("utf-8"))
    if not isinstance(token, dict) or set(token) != {
        "path",
        "record",
        "route",
        "test_only",
        "tool",
        "version",
    }:
        raise ValueError("invalid command binding")
    if token["version"] != EXECUTABLE_TOKEN_VERSION or token["tool"] != tool:
        raise ValueError("invalid command binding version or tool")
    if not isinstance(token["test_only"], bool):
        raise ValueError("invalid command binding test scope")
    if not isinstance(token["path"], str):
        raise ValueError("invalid command binding path")
    validate_record(
        token["record"],
        {
            "ctime_ns",
            "dev",
            "gid",
            "ino",
            "mode",
            "mtime_ns",
            "nlink",
            "size",
            "uid",
        },
        "command",
    )
    _absolute, parent, _name = split_target(token["path"])
    validate_route(token["route"], parent)
    return token


def operation_deadline(seconds):
    try:
        value = int(seconds)
    except (TypeError, ValueError) as error:
        raise ValueError("invalid operation timeout") from error
    if value < 1 or value > MAX_OPERATION_TIMEOUT_SECONDS:
        raise ValueError("invalid operation timeout")
    return time.monotonic_ns() + value * 1_000_000_000


def command_environment(profile):
    if profile != "gh":
        raise ValueError("unsupported command profile")
    environment = {
        "GH_HOST": "github.com",
        "GH_PROMPT_DISABLED": "1",
        "HOME": "/dev/null",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TZ": "UTC",
        "XDG_CONFIG_HOME": "/dev/null",
    }
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if token:
        environment["GH_TOKEN"] = token
    if os.environ.get("ODYSSEUS_TEST_RUNTIME") == "1":
        for name, value in os.environ.items():
            if name.startswith("ODYSSEUS_TEST_"):
                environment[name] = value
    return environment


def read_exact_test_script(descriptor, expected):
    """Read one bounded test script from its still-bound executable object."""
    if executable_record(os.fstat(descriptor)) != expected:
        raise OSError("test command executable changed before reading")
    chunks = []
    size = 0
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(
            descriptor,
            min(READ_CHUNK_BYTES, MAX_TEST_SCRIPT_BYTES - size + 1),
        )
        if not chunk:
            break
        size += len(chunk)
        if size > MAX_TEST_SCRIPT_BYTES:
            raise OSError("test command script exceeds the size ceiling")
        chunks.append(chunk)
    content = b"".join(chunks)
    os.lseek(descriptor, 0, os.SEEK_SET)
    if executable_record(os.fstat(descriptor)) != expected:
        raise OSError("test command executable changed while reading")
    if not content.startswith(b"#!/usr/bin/env bash\n") or b"\x00" in content:
        raise OSError("test command is not a supported Bash script")
    return content


def verified_system_bash():
    """Return the fixed root-owned Bash interpreter used by the Darwin test seam."""
    path = "/bin/bash"
    read_only = getattr(os, "ST_RDONLY", None)
    if (
        os.geteuid() == 0
        or not isinstance(read_only, int)
        or os.statvfs(path).f_flag & read_only != read_only
    ):
        raise OSError("system Bash filesystem is not immutable to this process")
    descriptor, descriptors, route, record = open_executable(path)
    try:
        if record["uid"] != 0 or stat.S_IMODE(record["mode"]) & 0o022:
            raise OSError("system Bash executable is not root-controlled")
        for entry in route:
            state = entry["state"]
            if state["uid"] != 0 or stat.S_IMODE(state["mode"]) & 0o022:
                raise OSError("system Bash route is not root-controlled")
        return path
    finally:
        os.close(descriptor)
        close_route(descriptors)


def terminate_process_group(process, observer=None):
    # Keep the leader unreaped until every signal has been sent. Its retained
    # PID prevents this process group ID from being recycled underneath the
    # supervisor while descendants are still being extinguished.
    leader_exited = (
        exit_observed(observer, process.pid)
        if observer is not None
        else False
    )
    if not leader_exited:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        except PermissionError:
            if observer is None or not exit_observed(observer, process.pid):
                raise
        time.sleep(0.25)
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError:
        if observer is None or not exit_observed(observer, process.pid):
            raise
    try:
        process.wait(timeout=1.0)
    except subprocess.TimeoutExpired as error:
        raise OSError("trusted command process group did not terminate") from error


def prepare_exit_observer(process_id):
    required = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if all(hasattr(os, name) for name in required):
        return {"kind": "waitid", "queue": None, "seen": False}
    names = (
        "kqueue",
        "kevent",
        "KQ_FILTER_PROC",
        "KQ_EV_ADD",
        "KQ_EV_ENABLE",
        "KQ_NOTE_EXIT",
    )
    if sys.platform != "darwin" or any(not hasattr(select, name) for name in names):
        raise OSError("safe command exit observation is unavailable")
    queue = select.kqueue()
    observer = {"kind": "kqueue", "queue": queue, "seen": False}
    event = select.kevent(
        process_id,
        filter=select.KQ_FILTER_PROC,
        flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
        fflags=select.KQ_NOTE_EXIT,
    )
    try:
        queue.control([event], 0, 0)
    except ProcessLookupError:
        observer["seen"] = True
    return observer


def exit_observed(observer, process_id, timeout=0.0):
    if observer["seen"]:
        return True
    if observer["kind"] == "waitid":
        result = os.waitid(
            os.P_PID,
            process_id,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
        observer["seen"] = result is not None and result.si_pid == process_id
    else:
        observer["seen"] = bool(observer["queue"].control(None, 1, timeout))
    return observer["seen"]


def close_exit_observer(observer):
    queue = observer.get("queue")
    observer["queue"] = None
    if queue is not None:
        queue.close()


class OwnedSupervisor:
    """Expose the bounded wait surface needed for a posix-spawned supervisor."""

    def __init__(self, process_id, stdout_descriptor, stderr_descriptor):
        self.pid = process_id
        self.stdout = os.fdopen(stdout_descriptor, "rb", buffering=0)
        self.stderr = os.fdopen(stderr_descriptor, "rb", buffering=0)
        self.returncode = None

    def wait(self, timeout=None):
        if self.returncode is not None:
            return self.returncode
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            try:
                process_id, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                if self.returncode is None:
                    raise
                return self.returncode
            if process_id == self.pid:
                self.returncode = os.waitstatus_to_exitcode(status)
                return self.returncode
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(["report-helper-supervisor"], timeout)
            time.sleep(PROCESS_POLL_SECONDS)


def spawn_trusted_supervisor(
    command,
    launch_path,
    inherited_descriptors,
    environment,
    effective_deadline_ns,
    status_descriptor,
    input_descriptor,
):
    """Acquire an owned supervisor before it can launch the trusted target."""
    required = ("posix_spawn", "POSIX_SPAWN_DUP2", "POSIX_SPAWN_OPEN")
    if any(not hasattr(os, name) for name in required) or not hasattr(
        signal, "pthread_sigmask"
    ):
        raise OSError("killable report-helper acquisition is unavailable")
    now_ns = time.monotonic_ns()
    if effective_deadline_ns <= now_ns:
        raise TimeoutError("trusted command operation deadline expired")
    remaining_seconds = (effective_deadline_ns - now_ns) / 1_000_000_000
    cpu_seconds = max(1, math.ceil(remaining_seconds) + 1)
    if sys.platform.startswith("linux"):
        address_space_bytes = PROCESS_MAX_ADDRESS_SPACE_BYTES
        process_count = PROCESS_MAX_PROCESSES
    else:
        # Darwin cannot lower RLIMIT_AS to 2 GiB after the interpreter has
        # reserved its large virtual arena, and a per-user RLIMIT_NPROC below
        # the current GUI session count prevents the owned target from starting.
        address_space_bytes = sys.maxsize - 1
        _soft_processes, hard_processes = resource.getrlimit(
            resource.RLIMIT_NPROC
        )
        process_count = (
            PROCESS_MAX_PROCESSES
            if hard_processes == resource.RLIM_INFINITY
            else hard_processes
        )

    acquisition_read, acquisition_write = os.pipe()
    stdout_read, stdout_write = os.pipe()
    stderr_read, stderr_write = os.pipe()
    process = None
    receipt = bytearray()
    try:
        sources = {
            status_descriptor,
            acquisition_write,
            stdout_write,
            stderr_write,
            *inherited_descriptors,
        }
        file_actions = []
        if input_descriptor is None:
            file_actions.append(
                (os.POSIX_SPAWN_OPEN, 0, "/dev/null", os.O_RDONLY, 0)
            )
        else:
            sources.add(input_descriptor)
            file_actions.append(
                (os.POSIX_SPAWN_DUP2, input_descriptor, 0)
            )
        file_actions.extend((
            (os.POSIX_SPAWN_DUP2, stdout_write, 1),
            (os.POSIX_SPAWN_DUP2, stderr_write, 2),
        ))

        mapped_descriptors = {}
        candidate = 64
        for descriptor in (
            status_descriptor,
            acquisition_write,
            *inherited_descriptors,
        ):
            while candidate in sources or candidate in {0, 1, 2}:
                candidate += 1
            if candidate >= PROCESS_MAX_OPEN_FILES:
                raise OSError("trusted command descriptor budget is exhausted")
            mapped_descriptors[descriptor] = candidate
            file_actions.append((os.POSIX_SPAWN_DUP2, descriptor, candidate))
            candidate += 1

        def remap_reference(value):
            for source, destination in mapped_descriptors.items():
                if value == f"/proc/self/fd/{source}":
                    return f"/proc/self/fd/{destination}"
            return value

        child_environment = dict(environment)
        for name, value in tuple(child_environment.items()):
            if not name.endswith("_FD"):
                continue
            for source, destination in mapped_descriptors.items():
                if value == str(source):
                    child_environment[name] = str(destination)
                    break
        child_pass_fds = tuple(
            mapped_descriptors[descriptor]
            for descriptor in inherited_descriptors
        )
        supervisor_command = [
            sys.executable,
            "-I",
            "-S",
            "-B",
            "-c",
            _PROCESS_SUPERVISOR,
            str(mapped_descriptors[status_descriptor]),
            str(mapped_descriptors[acquisition_write]),
            ",".join(str(descriptor) for descriptor in child_pass_fds),
            remap_reference(launch_path or ""),
            "/",
            str(os.getpid()),
            str(address_space_bytes),
            str(cpu_seconds),
            str(PROCESS_MAX_OPEN_FILES),
            str(process_count),
            *(remap_reference(argument) for argument in command),
        ]
        if time.monotonic_ns() >= effective_deadline_ns:
            raise TimeoutError("trusted command operation deadline expired")
        with defer_termination_signals():
            spawn_options = (
                {"setsid": True}
                if sys.platform.startswith("linux")
                else {"setpgroup": 0}
            )
            try:
                process_id = os.posix_spawn(
                    sys.executable,
                    supervisor_command,
                    child_environment,
                    file_actions=file_actions,
                    **spawn_options,
                )
            except (NotImplementedError, TypeError):
                process_id = os.posix_spawn(
                    sys.executable,
                    supervisor_command,
                    child_environment,
                    file_actions=file_actions,
                    setpgroup=0,
                )
            os.close(stdout_write)
            stdout_write = -1
            os.close(stderr_write)
            stderr_write = -1
            os.close(acquisition_write)
            acquisition_write = -1
            process = OwnedSupervisor(process_id, stdout_read, stderr_read)
            stdout_read = -1
            stderr_read = -1

            while len(receipt) < PROCESS_ACQUISITION_BYTES:
                remaining = (
                    effective_deadline_ns - time.monotonic_ns()
                ) / 1_000_000_000
                if remaining <= 0:
                    raise TimeoutError(
                        "trusted command operation deadline expired"
                    )
                readable, _writable, _exceptional = select.select(
                    [acquisition_read], [], [], remaining
                )
                if not readable:
                    raise TimeoutError(
                        "trusted command operation deadline expired"
                    )
                block = os.read(
                    acquisition_read,
                    PROCESS_ACQUISITION_BYTES - len(receipt),
                )
                if not block:
                    raise OSError(
                        "trusted command acquisition receipt is incomplete"
                    )
                receipt.extend(block)
            acquired, target_process_id = struct.unpack("!BI", receipt)
            if acquired != 1 or target_process_id <= 1:
                raise OSError("trusted command process was not acquired")
        return process
    except BaseException:
        if process is not None:
            cleanup_complete = False
            cleanup_observer = None
            try:
                cleanup_observer = prepare_exit_observer(process.pid)
                terminate_process_group(process, cleanup_observer)
                cleanup_complete = True
            finally:
                if cleanup_observer is not None:
                    close_exit_observer(cleanup_observer)
                if cleanup_complete:
                    for stream in (process.stdout, process.stderr):
                        try:
                            stream.close()
                        except OSError:
                            pass
        raise
    finally:
        for descriptor in (
            acquisition_read,
            acquisition_write,
            stdout_read,
            stdout_write,
            stderr_read,
            stderr_write,
        ):
            if descriptor < 0:
                continue
            try:
                os.close(descriptor)
            except OSError:
                pass


def supervise_trusted_command(
    command,
    launch_path,
    inherited_descriptors,
    environment,
    effective_deadline_ns,
    output_limit,
    input_content=None,
):
    """Run a target behind an acquisition-bounded, resource-limited supervisor."""
    credential_bearing = any(
        environment.get(name) for name in GITHUB_CREDENTIAL_VARIABLES
    )
    if credential_bearing and not sys.platform.startswith("linux"):
        raise NotImplementedError(
            "Linux credential-bearing descendant containment is required"
        )
    if effective_deadline_ns <= time.monotonic_ns():
        raise TimeoutError("trusted command operation deadline expired")

    process = None
    observer = None
    input_stream = None
    status_read = -1
    status_write = -1
    selector = selectors.DefaultSelector()
    output = {"stdout": bytearray(), "stderr": bytearray()}
    status_payload = bytearray()
    total = 0
    failure = None
    try:
        try:
            status_read, status_write = os.pipe()
            if input_content is not None:
                input_stream = tempfile.TemporaryFile()
                input_stream.write(input_content)
                input_stream.seek(0)
            process = spawn_trusted_supervisor(
                command,
                launch_path,
                inherited_descriptors,
                environment,
                effective_deadline_ns,
                status_write,
                input_stream.fileno() if input_stream is not None else None,
            )
            os.close(status_write)
            status_write = -1
            observer = prepare_exit_observer(process.pid)
            selector.register(process.stdout, selectors.EVENT_READ, "stdout")
            selector.register(process.stderr, selectors.EVENT_READ, "stderr")
            while selector.get_map():
                remaining = (
                    effective_deadline_ns - time.monotonic_ns()
                ) / 1_000_000_000
                if remaining <= 0:
                    failure = "trusted command timed out"
                    break
                events = selector.select(remaining)
                if not events:
                    failure = "trusted command timed out"
                    break
                for key, _mask in events:
                    chunk = os.read(key.fileobj.fileno(), READ_CHUNK_BYTES)
                    if not chunk:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                        continue
                    total += len(chunk)
                    if total > output_limit:
                        failure = (
                            "trusted command exceeded the "
                            f"{output_limit}-byte output limit"
                        )
                        break
                    output[key.data].extend(chunk)
                if failure is not None:
                    break
            if failure is None:
                while True:
                    remaining = (
                        effective_deadline_ns - time.monotonic_ns()
                    ) / 1_000_000_000
                    if remaining <= 0:
                        failure = "trusted command timed out"
                        break
                    if exit_observed(
                        observer,
                        process.pid,
                        min(PROCESS_POLL_SECONDS, remaining),
                    ):
                        break
                    time.sleep(min(PROCESS_POLL_SECONDS, remaining))
        finally:
            selector.close()
            try:
                if process is not None:
                    terminate_process_group(process, observer)
            finally:
                if observer is not None:
                    close_exit_observer(observer)

        if failure is not None:
            return 124, output, failure
        while len(status_payload) < PROCESS_STATUS_BYTES:
            remaining = (
                effective_deadline_ns - time.monotonic_ns()
            ) / 1_000_000_000
            if remaining <= 0:
                return 124, output, "trusted command timed out"
            readable, _writable, _exceptional = select.select(
                [status_read], [], [], remaining
            )
            if not readable:
                return 124, output, "trusted command timed out"
            block = os.read(
                status_read,
                PROCESS_STATUS_BYTES - len(status_payload),
            )
            if not block:
                raise OSError("trusted command status is incomplete")
            status_payload.extend(block)
        returncode, detached_descendant = struct.unpack(
            "!iB", status_payload
        )
        if detached_descendant not in {0, 1}:
            raise OSError("trusted command status is malformed")
        if detached_descendant:
            failure = "trusted command left a detached descendant"
        return returncode, output, failure
    finally:
        if input_stream is not None:
            input_stream.close()
        for descriptor in (status_read, status_write):
            if descriptor < 0:
                continue
            try:
                os.close(descriptor)
            except OSError:
                pass


def run_trusted_command(
    profile,
    deadline_text,
    timeout_text,
    output_limit_text,
    executable_binding,
    arguments,
):
    if profile != "gh" or not arguments:
        raise ValueError("invalid trusted command invocation")
    try:
        deadline_ns = int(deadline_text)
        timeout = int(timeout_text)
        output_limit = int(output_limit_text)
    except (TypeError, ValueError) as error:
        raise ValueError("invalid trusted command bounds") from error
    if (
        deadline_ns < 1
        or timeout < 1
        or timeout > MAX_COMMAND_TIMEOUT_SECONDS
        or output_limit < 1024
        or output_limit > MAX_COMMAND_OUTPUT_BYTES
    ):
        raise ValueError("invalid trusted command bounds")
    token = decode_executable_token(executable_binding, profile)
    if token["test_only"] and os.environ.get("ODYSSEUS_TEST_RUNTIME") != "1":
        raise OSError("command executable override is test-only")
    if len(arguments) > 128 or any(
        not isinstance(argument, str)
        or len(os.fsencode(argument)) > MAX_PATH_BYTES
        or "\x00" in argument
        for argument in arguments
    ):
        raise ValueError("invalid trusted command arguments")
    descriptor, descriptors, route, _record = open_executable(
        token["path"], token["record"]
    )
    try:
        if route != token["route"]:
            raise OSError("command executable route changed after binding")
        now_ns = time.monotonic_ns()
        call_deadline_ns = now_ns + timeout * 1_000_000_000
        effective_deadline_ns = min(deadline_ns, call_deadline_ns)
        if effective_deadline_ns <= now_ns:
            raise TimeoutError("trusted command operation deadline expired")
        portable_test_script = (
            sys.platform == "darwin"
            and token["test_only"]
            and os.environ.get("ODYSSEUS_TEST_RUNTIME") == "1"
            and not any(os.environ.get(name) for name in GITHUB_CREDENTIAL_VARIABLES)
        )
        if portable_test_script:
            script = read_exact_test_script(descriptor, token["record"])
            launch_path = verified_system_bash()
            command = [launch_path, "-s", "--", *arguments]
            verify_held_route(descriptors, token["route"])
            status, output, failure = supervise_trusted_command(
                command,
                launch_path,
                (),
                command_environment(profile),
                effective_deadline_ns,
                output_limit,
                script,
            )
        else:
            with executable_launch(descriptor, token["record"]) as (
                launch_path,
                inherited_descriptors,
            ):
                verify_held_route(descriptors, token["route"])
                status, output, failure = supervise_trusted_command(
                    [token["path"], *arguments],
                    launch_path,
                    inherited_descriptors,
                    command_environment(profile),
                    effective_deadline_ns,
                    output_limit,
                )
    finally:
        os.close(descriptor)
        close_route(descriptors)
    if failure is not None:
        print(f"error: {failure}", file=sys.stderr)
        raise SystemExit(124)
    descriptor, descriptors, route, _record = open_executable(
        token["path"], token["record"]
    )
    if route != token["route"]:
        os.close(descriptor)
        close_route(descriptors)
        raise OSError("command executable route changed during execution")
    os.close(descriptor)
    close_route(descriptors)
    sys.stdout.buffer.write(output["stdout"])
    sys.stderr.buffer.write(output["stderr"])
    raise SystemExit(status)


def bind(target, operation):
    if operation not in OPERATIONS:
        raise ValueError("unsupported report operation")
    absolute, parent, name = split_target(target)
    parent_descriptors, parent_route = open_parent(parent)
    parent_descriptor = parent_descriptors[-1]
    parent_state = parent_route[-1]["state"]
    destination_descriptor = -1
    try:
        destination_descriptor, content, destination_state = open_bound_file(
            parent_descriptor, name, READ_FLAGS
        )
        if destination_state is not None:
            raise ReportUpdateUnavailable(
                "existing report update is unavailable because an exact-object "
                "move cannot be guaranteed"
            )
        verify_held_route(parent_descriptors, parent_route)
        verify_parent_path(parent, parent_route)
        return encode_token(
            {
                "destination": destination_state,
                "name": name,
                "operation": operation,
                "parent": parent_state,
                "path": absolute,
                "route": parent_route,
                "version": TOKEN_VERSION,
            }
        )
    finally:
        if destination_descriptor >= 0:
            os.close(destination_descriptor)
        close_route(parent_descriptors)


def submodule_repositories(target):
    absolute, parent, name = split_target(target)
    parent_descriptors, parent_route = open_parent(parent)
    parent_descriptor = parent_descriptors[-1]
    descriptor = -1
    try:
        descriptor, content, _state = open_bound_file(
            parent_descriptor,
            name,
            READ_FLAGS,
        )
        if descriptor < 0 or content is None:
            raise OSError("canonical submodule inventory is unavailable")
        parser = configparser.RawConfigParser(interpolation=None, strict=True)
        parser.optionxform = str
        parser.read_string(content.decode("utf-8"), source=absolute)
        if not parser.sections():
            raise ValueError("canonical submodule inventory is empty")
        seen_paths = set()
        seen_repositories = set()
        repositories = []
        for section in parser.sections():
            match = re.fullmatch(r'submodule "([A-Za-z0-9._/-]+)"', section)
            if match is None or set(parser[section]) != {"path", "url"}:
                raise ValueError("malformed canonical submodule section")
            submodule = match.group(1)
            path = parser[section]["path"]
            url = parser[section]["url"]
            segments = path.split("/")
            if (
                path != submodule
                or not segments
                or any(not value or value in {".", ".."} for value in segments)
                or re.fullmatch(r"[A-Za-z0-9._/-]+", path) is None
                or path in seen_paths
            ):
                raise ValueError("unsafe or duplicate canonical submodule path")
            url_match = re.fullmatch(
                r"(?:https://github\.com/HomericIntelligence/|"
                r"git@github\.com:HomericIntelligence/)"
                r"([A-Za-z0-9_.-]+)\.git",
                url,
            )
            repository = url_match.group(1) if url_match is not None else ""
            if not repository or repository in seen_repositories:
                raise ValueError("unsafe or duplicate canonical repository URL")
            seen_paths.add(path)
            seen_repositories.add(repository)
            repositories.append("HomericIntelligence/" + repository)
        verify_held_route(parent_descriptors, parent_route)
        verify_parent_path(parent, parent_route)
        return repositories
    finally:
        if descriptor >= 0:
            os.close(descriptor)
        close_route(parent_descriptors)


def verify_named_file(parent_descriptor, name, descriptor, expected_identity):
    held = os.fstat(descriptor)
    named = os.lstat(name, dir_fd=parent_descriptor)
    require_direct_file(held)
    require_direct_file(named)
    if (
        file_identity(held) != expected_identity
        or file_identity(named) != expected_identity
    ):
        raise OSError("report destination name changed")


def require_quarantine_capacity(parent_descriptor, incoming_size):
    entries = 0
    quarantine_files = 0
    quarantine_bytes = 0
    with os.scandir(parent_descriptor) as directory:
        for entry in directory:
            entries += 1
            if entries > MAX_PARENT_ENTRIES:
                raise OSError("report parent entry ceiling exceeded")
            if not entry.name.startswith(CANDIDATE_PREFIX):
                continue
            metadata = os.lstat(entry.name, dir_fd=parent_descriptor)
            require_direct_file(metadata)
            if metadata.st_size > MAX_REPORT_BYTES:
                raise OSError("quarantined report exceeds the size ceiling")
            quarantine_files += 1
            quarantine_bytes += metadata.st_size
            if (
                quarantine_files > MAX_QUARANTINE_FILES
                or quarantine_bytes > MAX_QUARANTINE_BYTES
            ):
                raise OSError("report quarantine budget is already exceeded")
    if (
        quarantine_files >= MAX_QUARANTINE_FILES
        or quarantine_bytes + incoming_size > MAX_QUARANTINE_BYTES
    ):
        raise OSError("report quarantine budget is exhausted")


def create_candidate(parent_descriptor, target_name, mode, incoming_size):
    require_quarantine_capacity(parent_descriptor, incoming_size)
    for _attempt in range(CANDIDATE_ATTEMPTS):
        candidate_name = CANDIDATE_PREFIX + os.urandom(24).hex()
        if candidate_name == target_name:
            continue
        try:
            descriptor = os.open(
                candidate_name,
                WRITE_FLAGS | os.O_CREAT | os.O_EXCL,
                mode,
                dir_fd=parent_descriptor,
            )
        except FileExistsError:
            continue
        try:
            created = os.fstat(descriptor)
            require_direct_file(created)
            identity = file_identity(created)
            verify_named_file(
                parent_descriptor,
                candidate_name,
                descriptor,
                identity,
            )
            return candidate_name, descriptor
        except BaseException:
            os.close(descriptor)
            raise
    raise OSError("could not reserve a private report candidate")


def prepare_candidate(
    parent_descriptor,
    target_name,
    content,
    mode,
):
    candidate_name, descriptor = create_candidate(
        parent_descriptor,
        target_name,
        mode,
        len(content),
    )
    try:
        replace_descriptor_content(descriptor, content)
        identity = file_identity(os.fstat(descriptor))
        verify_named_file(
            parent_descriptor,
            candidate_name,
            descriptor,
            identity,
        )
        os.fsync(parent_descriptor)
        return candidate_name, descriptor, identity
    except BaseException:
        # The candidate name is deliberately retained. Deleting it by name
        # after an error would let a concurrent replacement become the victim.
        os.close(descriptor)
        raise


def verify_published_content(
    parent_descriptor,
    name,
    descriptor,
    identity,
    content,
):
    verify_named_file(parent_descriptor, name, descriptor, identity)
    if read_all(descriptor) != content:
        raise OSError("published report content changed")
    verify_named_file(parent_descriptor, name, descriptor, identity)


def require_absent(parent_descriptor, name):
    try:
        os.lstat(name, dir_fd=parent_descriptor)
    except FileNotFoundError:
        return
    raise FileExistsError(errno.EEXIST, "report destination appeared")


def publish_absent(
    parent_descriptor,
    name,
    operation,
    replacement,
    verify_route,
):
    content = build_content(operation, None, replacement)
    candidate_name, descriptor, identity = prepare_candidate(
        parent_descriptor,
        name,
        content,
        0o644,
    )
    try:
        verify_route()
        require_absent(parent_descriptor, name)
        verify_named_file(
            parent_descriptor,
            candidate_name,
            descriptor,
            identity,
        )
        atomic_noreplace(parent_descriptor, candidate_name, name)
        os.fsync(parent_descriptor)
        verify_published_content(
            parent_descriptor,
            name,
            descriptor,
            identity,
            content,
        )
        verify_route()
    finally:
        # On failure, retain the exact object for forensic recovery. After the
        # commit syscall its current pathname is uncertain and must not be used
        # as authority for another mutation.
        os.close(descriptor)


def publish(target, operation, encoded_token, replacement):
    require_report_size(len(replacement))
    token = decode_token(encoded_token)
    absolute, parent, name = split_target(target)
    if (
        operation != token["operation"]
        or absolute != token["path"]
        or name != token["name"]
    ):
        raise ValueError("report binding does not match publication")
    parent_descriptors, parent_route = open_parent(parent, token["route"])
    parent_descriptor = parent_descriptors[-1]
    try:
        if parent_route[-1]["state"] != token["parent"]:
            raise OSError("report parent changed after binding")

        def verify_route():
            verify_held_route(parent_descriptors, token["route"])
            verify_parent_path(parent, token["route"])

        verify_route()
        if token["destination"] is not None:
            raise ReportUpdateUnavailable(
                "existing report update is unavailable because an exact-object "
                "move cannot be guaranteed"
            )
        with defer_termination_signals():
            publish_absent(
                parent_descriptor,
                name,
                operation,
                replacement,
                verify_route,
            )
            os.fsync(parent_descriptor)
        verify_route()
    finally:
        close_route(parent_descriptors)


def ensure_distinct(first, second):
    first_token = decode_token(first)
    second_token = decode_token(second)
    first_key = (
        first_token["parent"]["dev"],
        first_token["parent"]["ino"],
        first_token["name"],
    )
    second_key = (
        second_token["parent"]["dev"],
        second_token["parent"]["ino"],
        second_token["name"],
    )
    if first_key == second_key:
        raise OSError("report sinks are the same entry")


def main():
    if len(sys.argv) == 4 and sys.argv[1] == "resolve":
        print(resolve_executable(sys.argv[2], sys.argv[3]))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "deadline":
        print(operation_deadline(sys.argv[2]))
        return
    if len(sys.argv) == 3 and sys.argv[1] == "candidate":
        print(candidate_target(sys.argv[2]))
        return
    if len(sys.argv) >= 8 and sys.argv[1] == "run":
        run_trusted_command(
            sys.argv[2],
            sys.argv[3],
            sys.argv[4],
            sys.argv[5],
            sys.argv[6],
            sys.argv[7:],
        )
        return
    if len(sys.argv) == 3 and sys.argv[1] == "inventory":
        for repository in submodule_repositories(sys.argv[2]):
            print(repository)
        return
    if len(sys.argv) == 4 and sys.argv[1] == "bind":
        print(bind(sys.argv[2], sys.argv[3]))
        return
    if len(sys.argv) == 5 and sys.argv[1] == "publish":
        publish(sys.argv[2], sys.argv[3], sys.argv[4], read_stream(sys.stdin.buffer))
        return
    if len(sys.argv) == 4 and sys.argv[1] == "distinct":
        ensure_distinct(sys.argv[2], sys.argv[3])
        return
    raise ValueError("invalid safe report publisher invocation")


if __name__ == "__main__":
    try:
        main()
    except ReportUpdateUnavailable as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(2)
    except TimeoutError as error:
        print(f"error: {error}", file=sys.stderr)
        raise SystemExit(124)
    except (
        binascii.Error,
        configparser.Error,
        NotImplementedError,
        OSError,
        subprocess.SubprocessError,
        TypeError,
        UnicodeError,
        ValueError,
    ):
        print("error: unsafe report publication target", file=sys.stderr)
        raise SystemExit(2)
