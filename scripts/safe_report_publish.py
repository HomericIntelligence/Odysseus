#!/usr/bin/env python3
"""Bind and publish reports without name-based replacement or cleanup races."""

import base64
import binascii
from contextlib import contextmanager
import ctypes
import errno
import hashlib
import json
import os
import signal
import stat
import sys


OPERATIONS = {"append", "inject", "replace"}
START_MARKER = "<!-- ECOSYSTEM-CI-TABLE:START -->"
END_MARKER = "<!-- ECOSYSTEM-CI-TABLE:END -->"
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
LINUX_RENAME_NOREPLACE = 1
LINUX_RENAME_EXCHANGE = 2
DARWIN_RENAME_SWAP = 0x00000002
DARWIN_RENAME_EXCL = 0x00000004


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
    """Keep asynchronous termination outside descriptor mutation/rollback."""
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


def atomic_rename(parent_descriptor, source, destination, operation):
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
        flag = {
            "exchange": DARWIN_RENAME_SWAP,
            "noreplace": DARWIN_RENAME_EXCL,
        }[operation]
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
        flag = {
            "exchange": LINUX_RENAME_EXCHANGE,
            "noreplace": LINUX_RENAME_NOREPLACE,
        }[operation]
    else:
        raise NotImplementedError("atomic report publication is unsupported")
    call_rename(function, parent_descriptor, source, destination, flag)


def atomic_noreplace(parent_descriptor, candidate_name, target_name):
    atomic_rename(
        parent_descriptor,
        candidate_name,
        target_name,
        "noreplace",
    )


def atomic_exchange(parent_descriptor, candidate_name, target_name):
    atomic_rename(
        parent_descriptor,
        candidate_name,
        target_name,
        "exchange",
    )


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


def marker_parts(content):
    try:
        text = content.decode("utf-8")
    except UnicodeDecodeError as error:
        raise ValueError("injection target is not UTF-8") from error
    lines = text.splitlines(keepends=True)
    starts = [index for index, line in enumerate(lines) if line.strip() == START_MARKER]
    ends = [index for index, line in enumerate(lines) if line.strip() == END_MARKER]
    if len(starts) != 1 or len(ends) != 1 or starts[0] >= ends[0]:
        raise ValueError("injection target needs one ordered marker pair")
    return lines, starts[0], ends[0]


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
    if existing is None:
        raise OSError("injection target disappeared")
    lines, start, end = marker_parts(existing)
    prefix = "".join(lines[: start + 1]).encode("utf-8")
    suffix = "".join(lines[end:]).encode("utf-8")
    if prefix and not prefix.endswith((b"\n", b"\r")):
        prefix += b"\n"
    if replacement and not replacement.endswith(b"\n"):
        replacement += b"\n"
    require_report_size(len(prefix) + len(replacement) + len(suffix))
    return prefix + replacement + suffix


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
        if operation == "inject":
            if content is None:
                raise OSError("injection target does not exist")
            marker_parts(content)
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


def verify_existing_state(parent_descriptor, name, descriptor, expected):
    before = os.fstat(descriptor)
    content = read_all(descriptor)
    after = os.fstat(descriptor)
    named = os.lstat(name, dir_fd=parent_descriptor)
    require_direct_file(before)
    require_direct_file(after)
    require_direct_file(named)
    if (
        file_record(before, content) != expected
        or file_record(after, content) != expected
    ):
        raise OSError("report destination content changed")
    expected_identity = file_identity(before)
    if (
        file_identity(after) != expected_identity
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
    expected_owner=None,
):
    candidate_name, descriptor = create_candidate(
        parent_descriptor,
        target_name,
        mode,
        len(content),
    )
    try:
        if expected_owner is not None:
            current = os.fstat(descriptor)
            if (
                current.st_uid != expected_owner["uid"]
                or current.st_gid != expected_owner["gid"]
            ):
                os.fchown(
                    descriptor,
                    expected_owner["uid"],
                    expected_owner["gid"],
                )
            os.fchmod(descriptor, stat.S_IMODE(expected_owner["mode"]))
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


def verify_displaced_file(parent_descriptor, name, descriptor, expected):
    expected_identity = {
        key: expected[key]
        for key in ("dev", "gid", "ino", "mode", "nlink", "uid")
    }
    verify_named_file(parent_descriptor, name, descriptor, expected_identity)
    before = os.fstat(descriptor)
    content = read_all(descriptor)
    after = os.fstat(descriptor)
    if (
        file_identity(before) != expected_identity
        or file_identity(after) != expected_identity
        or len(content) != expected["size"]
        or hashlib.sha256(content).hexdigest() != expected["digest"]
    ):
        raise OSError("displaced report object changed")


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


def open_named_identity(parent_descriptor, name):
    named = os.lstat(name, dir_fd=parent_descriptor)
    require_direct_file(named)
    descriptor = os.open(name, READ_FLAGS, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        require_direct_file(opened)
        identity = file_identity(opened)
        if identity != file_identity(named):
            raise OSError("report entry changed while opening")
        verify_named_file(parent_descriptor, name, descriptor, identity)
        return descriptor, identity
    except BaseException:
        os.close(descriptor)
        raise


def reserve_quarantine_name(parent_descriptor, target_name):
    for _attempt in range(CANDIDATE_ATTEMPTS):
        name = CANDIDATE_PREFIX + os.urandom(24).hex()
        if name == target_name:
            continue
        try:
            os.lstat(name, dir_fd=parent_descriptor)
        except FileNotFoundError:
            return name
    raise OSError("could not reserve a report quarantine name")


def rollback_existing_commit(
    parent_descriptor,
    candidate_name,
    target_name,
    prior_descriptor,
    expected,
):
    atomic_exchange(parent_descriptor, candidate_name, target_name)
    os.fsync(parent_descriptor)
    verify_displaced_file(
        parent_descriptor,
        target_name,
        prior_descriptor,
        expected,
    )
    quarantine_descriptor, quarantine_identity = open_named_identity(
        parent_descriptor,
        candidate_name,
    )
    try:
        verify_named_file(
            parent_descriptor,
            candidate_name,
            quarantine_descriptor,
            quarantine_identity,
        )
    finally:
        os.close(quarantine_descriptor)


def rollback_absent_commit(parent_descriptor, target_name):
    published_descriptor, published_identity = open_named_identity(
        parent_descriptor,
        target_name,
    )
    try:
        quarantine_name = reserve_quarantine_name(parent_descriptor, target_name)
        atomic_noreplace(
            parent_descriptor,
            target_name,
            quarantine_name,
        )
        os.fsync(parent_descriptor)
        require_absent(parent_descriptor, target_name)
        verify_named_file(
            parent_descriptor,
            quarantine_name,
            published_descriptor,
            published_identity,
        )
    finally:
        os.close(published_descriptor)


def publish_existing(
    parent_descriptor,
    name,
    expected,
    operation,
    replacement,
    verify_route,
):
    descriptor, existing, current = open_bound_file(
        parent_descriptor, name, READ_FLAGS
    )
    if descriptor < 0 or current != expected:
        if descriptor >= 0:
            os.close(descriptor)
        raise OSError("report destination changed")
    candidate_descriptor = -1
    try:
        content = build_content(operation, existing, replacement)
        verify_existing_state(parent_descriptor, name, descriptor, expected)
        candidate_name, candidate_descriptor, candidate_identity = prepare_candidate(
            parent_descriptor,
            name,
            content,
            stat.S_IMODE(expected["mode"]),
            expected,
        )
        verify_route()
        verify_existing_state(parent_descriptor, name, descriptor, expected)
        verify_named_file(
            parent_descriptor,
            candidate_name,
            candidate_descriptor,
            candidate_identity,
        )
        committed = False
        try:
            atomic_exchange(parent_descriptor, candidate_name, name)
            committed = True
            os.fsync(parent_descriptor)
            verify_published_content(
                parent_descriptor,
                name,
                candidate_descriptor,
                candidate_identity,
                content,
            )
            verify_displaced_file(
                parent_descriptor,
                candidate_name,
                descriptor,
                expected,
            )
            verify_route()
        except BaseException as commit_error:
            if committed:
                try:
                    rollback_existing_commit(
                        parent_descriptor,
                        candidate_name,
                        name,
                        descriptor,
                        expected,
                    )
                except BaseException as rollback_error:
                    raise OSError(
                        "report commit failed and rollback is uncertain"
                    ) from rollback_error
            raise commit_error
    finally:
        if candidate_descriptor >= 0:
            os.close(candidate_descriptor)
        os.close(descriptor)


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
        committed = False
        try:
            atomic_noreplace(parent_descriptor, candidate_name, name)
            committed = True
            os.fsync(parent_descriptor)
            verify_published_content(
                parent_descriptor,
                name,
                descriptor,
                identity,
                content,
            )
            verify_route()
        except BaseException as commit_error:
            if committed:
                try:
                    rollback_absent_commit(parent_descriptor, name)
                except BaseException as rollback_error:
                    raise OSError(
                        "report commit failed and rollback is uncertain"
                    ) from rollback_error
            raise commit_error
    finally:
        # On failure, retain the exact candidate object for forensic recovery.
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
        with defer_termination_signals():
            if token["destination"] is None:
                publish_absent(
                    parent_descriptor,
                    name,
                    operation,
                    replacement,
                    verify_route,
                )
            else:
                publish_existing(
                    parent_descriptor,
                    name,
                    token["destination"],
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
    except (
        binascii.Error,
        NotImplementedError,
        OSError,
        TypeError,
        UnicodeError,
        ValueError,
    ):
        print("error: unsafe report publication target", file=sys.stderr)
        raise SystemExit(2)
