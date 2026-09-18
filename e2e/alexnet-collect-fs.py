#!/usr/bin/env python3
"""Descriptor-relative filesystem operations for AlexNet results."""

from __future__ import annotations

import os
import re
import secrets
import stat
import sys
import ctypes
import errno


def required_flag(name: str) -> int:
    value = getattr(os, name, None)
    if value is None:
        raise OSError(f"{name} is required")
    return value


O_DIRECTORY = required_flag("O_DIRECTORY")
O_NOFOLLOW = required_flag("O_NOFOLLOW")
O_CLOEXEC = required_flag("O_CLOEXEC")
DIRECTORY_FLAGS = os.O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
FILE_FLAGS = os.O_RDONLY | O_NOFOLLOW | O_CLOEXEC
CREATE_FILE_FLAGS = os.O_WRONLY | os.O_CREAT | os.O_EXCL | O_NOFOLLOW | O_CLOEXEC
HOST_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9.-]*")
RECEIPT_PATTERN = re.compile(r"(?:0|[1-9][0-9]*)[.]detail")


def identity(value: os.stat_result) -> tuple[int, int]:
    return value.st_dev, value.st_ino


def identity_text(value: os.stat_result) -> str:
    return f"{value.st_dev}:{value.st_ino}"


def parse_identity(value: str) -> tuple[int, int]:
    fields = value.split(":")
    if len(fields) != 2 or not all(field.isdigit() for field in fields):
        raise OSError("invalid filesystem identity")
    return int(fields[0]), int(fields[1])


def direct_state(directory_fd: int, name: str) -> os.stat_result:
    return os.stat(name, dir_fd=directory_fd, follow_symlinks=False)


def validate_directory(
    value: os.stat_result, expected: tuple[int, int] | None = None
) -> None:
    if not stat.S_ISDIR(value.st_mode):
        raise OSError("bound object is not a directory")
    if expected is not None and identity(value) != expected:
        raise OSError("directory identity changed")


def validate_private_directory(
    value: os.stat_result, expected: tuple[int, int] | None = None
) -> None:
    validate_directory(value, expected)
    if value.st_uid != os.geteuid() or stat.S_IMODE(value.st_mode) != 0o700:
        raise OSError("owned result directory must have mode 0700")


def validate_owned_directory(
    value: os.stat_result, expected: tuple[int, int] | None = None
) -> None:
    validate_directory(value, expected)
    if value.st_uid != os.geteuid() or stat.S_IMODE(value.st_mode) & 0o022:
        raise OSError("result directory must be owned and not group/world writable")


def validate_private_file(
    value: os.stat_result, expected: tuple[int, int] | None = None
) -> None:
    if (
        not stat.S_ISREG(value.st_mode)
        or value.st_uid != os.geteuid()
        or stat.S_IMODE(value.st_mode) != 0o600
        or value.st_nlink != 1
    ):
        raise OSError("owned result file must be one mode-0600 regular file")
    if expected is not None and identity(value) != expected:
        raise OSError("result file identity changed")


def open_absolute_directory(path: str, create: bool) -> int:
    if not os.path.isabs(path):
        raise OSError("directory path is not absolute")
    components = path.split("/")[1:]
    if any(component in {".", ".."} for component in components):
        raise OSError("directory path is not canonical")
    descriptor = os.open("/", DIRECTORY_FLAGS)
    try:
        for component in components:
            if not component:
                continue
            try:
                next_descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            except FileNotFoundError:
                if not create:
                    raise
                os.mkdir(component, mode=0o700, dir_fd=descriptor)
                next_descriptor = os.open(component, DIRECTORY_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
        validate_directory(os.fstat(descriptor))
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def validate_path_binding(
    path: str, descriptor: int, expected: tuple[int, int]
) -> None:
    validate_directory(os.fstat(descriptor), expected)
    rebound = open_absolute_directory(path, create=False)
    try:
        validate_directory(os.fstat(rebound), expected)
    finally:
        os.close(rebound)


def validate_named_directory(
    parent_fd: int,
    name: str,
    descriptor: int,
    expected: tuple[int, int],
    *,
    private: bool,
) -> None:
    validator = validate_private_directory if private else validate_directory
    validator(os.fstat(descriptor), expected)
    validator(direct_state(parent_fd, name), expected)


def open_named_directory(parent_fd: int, name: str) -> int:
    descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    try:
        opened = os.fstat(descriptor)
        validate_directory(opened)
        if identity(direct_state(parent_fd, name)) != identity(opened):
            raise OSError("named directory changed while opening")
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def require_absent(parent_fd: int, name: str) -> None:
    try:
        direct_state(parent_fd, name)
    except FileNotFoundError:
        return
    raise OSError("collection destination already exists")


def rename_noreplace(
    source_fd: int, source_name: str, destination_fd: int, destination_name: str
) -> None:
    """Atomically publish one directory without replacing any raced object."""
    library = ctypes.CDLL(None, use_errno=True)
    source = os.fsencode(source_name)
    destination = os.fsencode(destination_name)
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        result = library.renameat2(
            source_fd, source, destination_fd, destination, ctypes.c_uint(1)
        )
    elif sys.platform == "darwin" and hasattr(library, "renameatx_np"):
        result = library.renameatx_np(
            source_fd, source, destination_fd, destination, ctypes.c_uint(0x4)
        )
    else:
        raise OSError(errno.ENOTSUP, "atomic no-replace directory publication unavailable")
    if result != 0:
        value = ctypes.get_errno()
        raise OSError(value, os.strerror(value), destination_name)


def create_private_directory_fd(
    parent_fd: int, name: str
) -> tuple[int, tuple[int, int]]:
    """Create privately, retain the exact FD, then atomically publish it."""
    require_absent(parent_fd, name)
    isolation_name = ""
    isolation_fd = -1
    descriptor = -1
    for _ in range(128):
        candidate = f".alexnet-create.{secrets.token_hex(16)}"
        try:
            os.mkdir(candidate, mode=0o700, dir_fd=parent_fd)
        except FileExistsError:
            continue
        isolation_name = candidate
        break
    if not isolation_name:
        raise OSError("could not allocate a private creation boundary")
    try:
        isolation_fd = open_named_directory(parent_fd, isolation_name)
        isolation_state = os.fstat(isolation_fd)
        validate_private_directory(isolation_state)
        validate_private_directory(
            direct_state(parent_fd, isolation_name), identity(isolation_state)
        )
        os.mkdir("object", mode=0o700, dir_fd=isolation_fd)
        descriptor = open_named_directory(isolation_fd, "object")
        value = os.fstat(descriptor)
        validate_private_directory(value)
        validate_private_directory(direct_state(isolation_fd, "object"), identity(value))
        rename_noreplace(isolation_fd, "object", parent_fd, name)
        validate_private_directory(direct_state(parent_fd, name), identity(value))
        validate_private_directory(os.fstat(descriptor), identity(value))
        os.rmdir(isolation_name, dir_fd=parent_fd)
        isolation_name = ""
        return descriptor, identity(value)
    except Exception:
        if descriptor >= 0:
            os.close(descriptor)
        raise
    finally:
        if isolation_fd >= 0:
            os.close(isolation_fd)


def create_private_directory(parent_fd: int, name: str) -> tuple[int, int]:
    descriptor, created_identity = create_private_directory_fd(parent_fd, name)
    os.close(descriptor)
    return created_identity


def prepare(parent_path: str, destination_name: str) -> None:
    parent_fd = open_absolute_directory(parent_path, create=True)
    staging_fd = -1
    staging_name = ""
    try:
        parent_state = os.fstat(parent_fd)
        require_absent(parent_fd, destination_name)
        for _ in range(128):
            candidate = f".alexnet-collect.{secrets.token_hex(12)}"
            try:
                os.mkdir(candidate, mode=0o700, dir_fd=parent_fd)
            except FileExistsError:
                continue
            staging_name = candidate
            break
        if not staging_name:
            raise OSError("could not allocate collection staging")
        staging_fd = open_named_directory(parent_fd, staging_name)
        staging_state = os.fstat(staging_fd)
        validate_private_directory(staging_state)
        data_identity = create_private_directory(staging_fd, "data")
        receipts_identity = create_private_directory(staging_fd, "receipts")
        validate_path_binding(parent_path, parent_fd, identity(parent_state))
        validate_named_directory(
            parent_fd,
            staging_name,
            staging_fd,
            identity(staging_state),
            private=True,
        )
        print(
            identity_text(parent_state),
            staging_name,
            identity_text(staging_state),
            f"{data_identity[0]}:{data_identity[1]}",
            f"{receipts_identity[0]}:{receipts_identity[1]}",
            sep="\t",
        )
    finally:
        if staging_fd >= 0:
            os.close(staging_fd)
        os.close(parent_fd)


def verify_bindings(
    parent_path: str,
    parent_identity: str,
    parent_fd: int,
    staging_name: str,
    staging_identity: str,
    staging_fd: int,
    data_identity: str,
    data_fd: int,
    receipts_identity: str,
    receipts_fd: int,
) -> None:
    expected_parent = parse_identity(parent_identity)
    expected_staging = parse_identity(staging_identity)
    validate_path_binding(parent_path, parent_fd, expected_parent)
    validate_named_directory(
        parent_fd,
        staging_name,
        staging_fd,
        expected_staging,
        private=True,
    )
    validate_named_directory(
        staging_fd,
        "data",
        data_fd,
        parse_identity(data_identity),
        private=True,
    )
    validate_named_directory(
        staging_fd,
        "receipts",
        receipts_fd,
        parse_identity(receipts_identity),
        private=True,
    )


def create_host(data_fd: int, host: str) -> None:
    if HOST_PATTERN.fullmatch(host) is None:
        raise OSError("invalid result host")
    require_absent(data_fd, host)
    host_identity = create_private_directory(data_fd, host)
    print(f"{host_identity[0]}:{host_identity[1]}")


def read_file(descriptor: int, limit: int = 1024 * 1024) -> bytes:
    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = os.read(descriptor, min(65536, limit + 1 - total))
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)
        total += len(chunk)
        if total > limit:
            raise OSError("result file is too large")


def open_regular_file(parent_fd: int, name: str) -> tuple[int, os.stat_result]:
    named = direct_state(parent_fd, name)
    if not stat.S_ISREG(named.st_mode) or named.st_nlink != 1:
        raise OSError("result file is not one direct regular file")
    descriptor = os.open(name, FILE_FLAGS, dir_fd=parent_fd)
    try:
        opened = os.fstat(descriptor)
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_nlink != 1
            or identity(opened) != identity(named)
            or identity(direct_state(parent_fd, name)) != identity(opened)
        ):
            raise OSError("result file identity changed")
        return descriptor, opened
    except Exception:
        os.close(descriptor)
        raise


def read_receipt(receipts_fd: int, name: str) -> None:
    if RECEIPT_PATTERN.fullmatch(name) is None:
        raise OSError("invalid transfer receipt name")
    descriptor, opened = open_regular_file(receipts_fd, name)
    try:
        validate_private_file(opened)
        sys.stdout.buffer.write(read_file(descriptor))
        validate_private_file(direct_state(receipts_fd, name), identity(opened))
    finally:
        os.close(descriptor)


def validate_tree(directory_fd: int) -> int:
    count = 0
    with os.scandir(directory_fd) as entries:
        names = sorted(entry.name for entry in entries)
    for name in names:
        value = direct_state(directory_fd, name)
        if stat.S_ISDIR(value.st_mode):
            child_fd = open_named_directory(directory_fd, name)
            try:
                child_identity = identity(os.fstat(child_fd))
                count += validate_tree(child_fd)
                validate_named_directory(
                    directory_fd,
                    name,
                    child_fd,
                    child_identity,
                    private=False,
                )
            finally:
                os.close(child_fd)
        elif stat.S_ISREG(value.st_mode):
            descriptor, opened = open_regular_file(directory_fd, name)
            os.close(descriptor)
            if opened.st_uid != os.geteuid():
                raise OSError("result file is not owned by the invoking user")
            count += 1
        else:
            raise OSError("unsupported result-tree node")
    return count


def validate_launch_header(host_fd: int, run_id: str) -> None:
    descriptor, opened = open_regular_file(host_fd, "training.log")
    try:
        payload = read_file(descriptor)
        lines = payload.splitlines()
        if not any(line.startswith(b"=== AlexNet Training on ") for line in lines):
            raise OSError("launch header marker is absent")
        expected = f"Run ID:   {run_id}".encode()
        if expected not in lines:
            raise OSError("launch header has another run identity")
        if identity(direct_state(host_fd, "training.log")) != identity(opened):
            raise OSError("launch header changed while reading")
    finally:
        os.close(descriptor)


def validate_host(host_fd: int, host_identity: str, run_id: str) -> None:
    expected = parse_identity(host_identity)
    host_state = os.fstat(host_fd)
    validate_owned_directory(host_state, expected)
    if validate_tree(host_fd) == 0:
        raise OSError("result tree is empty")
    validate_launch_header(host_fd, run_id)
    validate_owned_directory(os.fstat(host_fd), expected)


def identify_host(data_fd: int, host: str, run_id: str) -> None:
    host_fd = open_named_directory(data_fd, host)
    try:
        host_state = os.fstat(host_fd)
        validate_directory(host_state)
        if host_state.st_uid != os.geteuid():
            raise OSError("result host is not owned by the invoking user")
        host_identity = identity_text(host_state)
        validate_host(host_fd, host_identity, run_id)
        print(host_identity)
    finally:
        os.close(host_fd)


def create_receipt(receipts_fd: int, name: str) -> int:
    if RECEIPT_PATTERN.fullmatch(name) is None:
        raise OSError("invalid transfer receipt name")
    try:
        descriptor = os.open(
            name,
            CREATE_FILE_FLAGS,
            0o600,
            dir_fd=receipts_fd,
        )
    except OSError as error:
        raise OSError("transfer receipt could not be created") from error
    try:
        os.fchmod(descriptor, 0o600)
        opened = os.fstat(descriptor)
        validate_private_file(opened)
        validate_private_file(direct_state(receipts_fd, name), identity(opened))
        return descriptor
    except Exception:
        os.close(descriptor)
        raise


def execute_transfer(
    data_fd: int,
    host: str,
    host_identity: str,
    receipts_fd: int,
    receipt_name: str,
    command: list[str],
) -> None:
    expected = parse_identity(host_identity)
    host_fd = open_named_directory(data_fd, host)
    receipt_fd = -1
    try:
        validate_named_directory(
            data_fd,
            host,
            host_fd,
            expected,
            private=True,
        )
        receipt_fd = create_receipt(receipts_fd, receipt_name)
        os.fchdir(host_fd)
        validate_private_directory(os.fstat(host_fd), expected)
        os.dup2(receipt_fd, 1)
        os.dup2(receipt_fd, 2)
        os.execvp(command[0], command)
    finally:
        if receipt_fd >= 0:
            os.close(receipt_fd)
        os.close(host_fd)


def transfer_local(values: list[str]) -> None:
    if len(values) != 6:
        raise OSError("invalid local transfer request")
    source = values[5]
    if not os.path.isabs(source):
        raise OSError("local result source is not absolute")
    execute_transfer(
        int(values[0]),
        values[1],
        values[2],
        int(values[3]),
        values[4],
        ["cp", "-a", f"{source.rstrip('/')}/.", "."],
    )


def transfer_remote(values: list[str]) -> None:
    if len(values) != 6:
        raise OSError("invalid remote transfer request")
    remote_source = values[5]
    if not remote_source or "\n" in remote_source or "\0" in remote_source:
        raise OSError("invalid remote result source")
    execute_transfer(
        int(values[0]),
        values[1],
        values[2],
        int(values[3]),
        values[4],
        [
            "rsync",
            "-az",
            "--timeout=60",
            "-e",
            "ssh -o ConnectTimeout=5 -o BatchMode=yes",
            "--",
            remote_source,
            ".",
        ],
    )


def write_all(descriptor: int, payload: bytes) -> None:
    remaining = memoryview(payload)
    while remaining:
        written = os.write(descriptor, remaining)
        if written <= 0:
            raise OSError("result write made no progress")
        remaining = remaining[written:]


def copy_regular_file(source_fd: int, destination_fd: int, name: str) -> None:
    source, source_state = open_regular_file(source_fd, name)
    destination = -1
    try:
        destination = os.open(
            name,
            CREATE_FILE_FLAGS,
            0o600,
            dir_fd=destination_fd,
        )
        os.fchmod(destination, 0o600)
        while True:
            chunk = os.read(source, 65536)
            if not chunk:
                break
            write_all(destination, chunk)
        os.fsync(destination)
        destination_state = os.fstat(destination)
        validate_private_file(destination_state)
        validate_private_file(
            direct_state(destination_fd, name), identity(destination_state)
        )
        if identity(direct_state(source_fd, name)) != identity(source_state):
            raise OSError("source result file changed during publication")
        current_source = os.fstat(source)
        if (
            identity(current_source) != identity(source_state)
            or current_source.st_nlink != 1
        ):
            raise OSError("source result file identity changed during publication")
    finally:
        if destination >= 0:
            os.close(destination)
        os.close(source)


def copy_tree(source_fd: int, destination_fd: int) -> None:
    with os.scandir(source_fd) as entries:
        names = sorted(entry.name for entry in entries)
    for name in names:
        source_state = direct_state(source_fd, name)
        if stat.S_ISREG(source_state.st_mode):
            copy_regular_file(source_fd, destination_fd, name)
        elif stat.S_ISDIR(source_state.st_mode):
            source_child = open_named_directory(source_fd, name)
            destination_child = -1
            try:
                source_identity = identity(os.fstat(source_child))
                destination_child, destination_identity = create_private_directory_fd(
                    destination_fd, name
                )
                validate_private_directory(
                    os.fstat(destination_child), destination_identity
                )
                copy_tree(source_child, destination_child)
                validate_named_directory(
                    source_fd,
                    name,
                    source_child,
                    source_identity,
                    private=False,
                )
                validate_named_directory(
                    destination_fd,
                    name,
                    destination_child,
                    destination_identity,
                    private=True,
                )
            finally:
                if destination_child >= 0:
                    os.close(destination_child)
                os.close(source_child)
        else:
            raise OSError("unsupported result-tree node")


def publish_host(
    data_fd: int,
    central_fd: int,
    host: str,
    host_identity: str,
    run_id: str,
) -> None:
    expected = parse_identity(host_identity)
    source_fd = open_named_directory(data_fd, host)
    destination_fd = -1
    try:
        validate_owned_directory(os.fstat(source_fd), expected)
        validate_host(source_fd, host_identity, run_id)
        require_absent(central_fd, host)
        destination_fd, destination_identity = create_private_directory_fd(
            central_fd, host
        )
        validate_private_directory(os.fstat(destination_fd), destination_identity)
        copy_tree(source_fd, destination_fd)
        validate_named_directory(
            data_fd,
            host,
            source_fd,
            expected,
            private=False,
        )
        validate_host(source_fd, host_identity, run_id)
        validate_named_directory(
            central_fd,
            host,
            destination_fd,
            destination_identity,
            private=True,
        )
        validate_host(destination_fd, identity_text(os.fstat(destination_fd)), run_id)
    finally:
        if destination_fd >= 0:
            os.close(destination_fd)
        os.close(source_fd)


def create_central(
    parent_path: str,
    parent_identity: str,
    parent_fd: int,
    destination_name: str,
) -> None:
    expected_parent = parse_identity(parent_identity)
    validate_path_binding(parent_path, parent_fd, expected_parent)
    require_absent(parent_fd, destination_name)
    destination_identity = create_private_directory(parent_fd, destination_name)
    validate_path_binding(parent_path, parent_fd, expected_parent)
    print(f"{destination_identity[0]}:{destination_identity[1]}")


def verify_central(
    parent_path: str,
    parent_identity: str,
    parent_fd: int,
    destination_name: str,
    destination_identity: str,
    destination_fd: int,
) -> None:
    expected_parent = parse_identity(parent_identity)
    expected_destination = parse_identity(destination_identity)
    validate_path_binding(parent_path, parent_fd, expected_parent)
    validate_named_directory(
        parent_fd,
        destination_name,
        destination_fd,
        expected_destination,
        private=True,
    )


def receipt(central_fd: int, host: str, run_id: str) -> None:
    host_fd = open_named_directory(central_fd, host)
    try:
        host_state = os.fstat(host_fd)
        validate_private_directory(host_state)
        validate_host(host_fd, identity_text(host_state), run_id)
        file_count = validate_tree(host_fd)
        try:
            weights_fd = open_named_directory(host_fd, "alexnet_weights")
        except FileNotFoundError:
            weight_count = 0
        else:
            try:
                weight_count = validate_tree(weights_fd)
            finally:
                os.close(weights_fd)
        print(f"files={file_count} launch-header=present weights={weight_count}")
    finally:
        os.close(host_fd)


def create_train_directory(path: str) -> None:
    parent_path = os.path.dirname(path)
    name = os.path.basename(path)
    if name in {"", ".", ".."}:
        raise OSError("invalid result directory name")
    parent_fd = open_absolute_directory(parent_path, create=True)
    result_fd = -1
    try:
        require_absent(parent_fd, name)
        result_fd, result_identity = create_private_directory_fd(parent_fd, name)
        result_state = os.fstat(result_fd)
        validate_private_directory(result_state, result_identity)
        validate_private_directory(
            direct_state(parent_fd, name), identity(result_state)
        )
        print(identity_text(result_state))
    finally:
        if result_fd >= 0:
            os.close(result_fd)
        os.close(parent_fd)


def publish_train_header(
    directory_fd: int, directory_identity: str, payload: str
) -> None:
    expected_directory = parse_identity(directory_identity)
    validate_private_directory(os.fstat(directory_fd), expected_directory)
    descriptor = -1
    try:
        descriptor = os.open(
            "training.log",
            CREATE_FILE_FLAGS,
            0o600,
            dir_fd=directory_fd,
        )
        os.fchmod(descriptor, 0o600)
        write_all(descriptor, payload.encode("utf-8") + b"\n")
        os.fsync(descriptor)
        header_state = os.fstat(descriptor)
        validate_private_file(header_state)
        validate_private_file(
            direct_state(directory_fd, "training.log"), identity(header_state)
        )
        print(identity_text(header_state))
    finally:
        if descriptor >= 0:
            os.close(descriptor)


def verify_train_directory(
    path: str, directory_identity: str, directory_fd: int
) -> None:
    expected = parse_identity(directory_identity)
    validate_path_binding(path, directory_fd, expected)
    validate_private_directory(os.fstat(directory_fd), expected)


def verify_train_header(
    path: str,
    directory_identity: str,
    directory_fd: int,
    header_identity: str,
) -> None:
    verify_train_directory(path, directory_identity, directory_fd)
    expected_header = parse_identity(header_identity)
    descriptor, opened = open_regular_file(directory_fd, "training.log")
    try:
        validate_private_file(opened, expected_header)
        validate_private_file(
            direct_state(directory_fd, "training.log"), expected_header
        )
    finally:
        os.close(descriptor)


def main(arguments: list[str]) -> None:
    if not arguments:
        raise OSError("safe-filesystem action is required")
    action = arguments[0]
    values = arguments[1:]
    if action == "prepare" and len(values) == 2:
        prepare(values[0], values[1])
    elif action == "verify-bindings" and len(values) == 10:
        verify_bindings(
            values[0],
            values[1],
            int(values[2]),
            values[3],
            values[4],
            int(values[5]),
            values[6],
            int(values[7]),
            values[8],
            int(values[9]),
        )
    elif action == "create-host" and len(values) == 2:
        create_host(int(values[0]), values[1])
    elif action == "read-receipt" and len(values) == 2:
        read_receipt(int(values[0]), values[1])
    elif action == "validate-host" and len(values) == 3:
        validate_host(int(values[0]), values[1], values[2])
    elif action == "identify-host" and len(values) == 3:
        identify_host(int(values[0]), values[1], values[2])
    elif action == "transfer-local":
        transfer_local(values)
    elif action == "transfer-remote":
        transfer_remote(values)
    elif action == "create-central" and len(values) == 4:
        create_central(values[0], values[1], int(values[2]), values[3])
    elif action == "publish-host" and len(values) == 5:
        publish_host(int(values[0]), int(values[1]), values[2], values[3], values[4])
    elif action == "verify-central" and len(values) == 6:
        verify_central(
            values[0], values[1], int(values[2]), values[3], values[4], int(values[5])
        )
    elif action == "receipt" and len(values) == 3:
        receipt(int(values[0]), values[1], values[2])
    elif action == "train-create" and len(values) == 1:
        create_train_directory(values[0])
    elif action == "train-verify-directory" and len(values) == 3:
        verify_train_directory(values[0], values[1], int(values[2]))
    elif action == "train-publish-header" and len(values) == 3:
        publish_train_header(int(values[1]), values[0], values[2])
    elif action == "train-verify-header" and len(values) == 4:
        verify_train_header(values[0], values[1], int(values[2]), values[3])
    else:
        raise OSError("invalid safe-filesystem action")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except (
        FileNotFoundError,
        FileExistsError,
        NotADirectoryError,
        OSError,
        ValueError,
    ) as error:
        print(f"ERROR: unsafe result filesystem state: {error}", file=sys.stderr)
        raise SystemExit(1)
