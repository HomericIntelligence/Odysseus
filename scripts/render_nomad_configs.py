#!/usr/bin/env python3
"""Render and safely publish the canonical Nomad configuration pair."""

from __future__ import annotations

import argparse
from collections.abc import Callable
from contextlib import contextmanager
import ctypes
import hashlib
import ipaddress
import os
from pathlib import Path
import selectors
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from typing import Iterator, NamedTuple, NoReturn


CONFIG_NAMES = ("client.hcl", "server.hcl")
PLACEHOLDERS = {
    "client.hcl": {b"${NOMAD_SERVER_IP}": 1},
    "server.hcl": {b"${NOMAD_ADVERTISE_ADDR}": 4},
}
COMMAND_TIMEOUT_SECONDS = 10.0
TERM_GRACE_SECONDS = 0.5
KILL_GRACE_SECONDS = 1.0
OUTPUT_LIMIT_BYTES = 256 * 1024
MAX_NOMAD_CONFIG_BYTES = 1024 * 1024
MAX_EXECUTABLE_BYTES = 64 * 1024 * 1024


class DeferredSignal(BaseException):
    def __init__(self, signal_number: int) -> None:
        self.signal_number = signal_number


@contextmanager
def deferred_termination() -> Iterator[None]:
    """Defer TERM/HUP until owned children and files have been cleaned up."""
    caught: int | None = None
    previous: dict[int, signal.Handlers] = {}

    def handle(signal_number: int, _frame: object) -> None:
        nonlocal caught
        if caught is None:
            caught = signal_number
            raise DeferredSignal(signal_number)

    for signal_number in (signal.SIGTERM, signal.SIGHUP):
        previous[signal_number] = signal.getsignal(signal_number)
        signal.signal(signal_number, handle)
    try:
        yield
    except DeferredSignal as cancellation:
        caught = cancellation.signal_number
    finally:
        for signal_number, handler in previous.items():
            signal.signal(signal_number, handler)
    if caught is not None:
        signal.raise_signal(caught)
        raise SystemExit(128 + caught)


class CommandResult(NamedTuple):
    returncode: int
    stdout: bytes
    stderr: bytes


def run_cleanup_actions(
    *actions: Callable[[], None],
    pending_primary: BaseException | None = None,
) -> None:
    """Attempt every cleanup and keep an active primary failure authoritative."""
    primary = sys.exc_info()[1] or pending_primary
    first_cleanup_error: BaseException | None = None
    for action in actions:
        try:
            action()
        except BaseException as error:
            if first_cleanup_error is None:
                first_cleanup_error = error
    if primary is None and first_cleanup_error is not None:
        raise first_cleanup_error


class BoundExecutable:
    def __init__(
        self,
        *,
        name: str,
        selected_path: str,
        snapshot_directory: str,
        directory_descriptor: int,
        snapshot_name: str,
        snapshot_state: os.stat_result,
        directory_state: os.stat_result,
        digest: bytes,
        parent_descriptor: int = -1,
        snapshot_directory_name: str = "",
        interpreter: BoundExecutable | None = None,
    ) -> None:
        self.name = name
        self.selected_path = selected_path
        self.snapshot_directory = snapshot_directory
        self.directory_descriptor = directory_descriptor
        self.snapshot_name = snapshot_name
        self.snapshot_state = snapshot_state
        self.directory_state = directory_state
        self.digest = digest
        self.parent_descriptor = parent_descriptor
        self.snapshot_directory_name = snapshot_directory_name
        self.interpreter = interpreter

    @property
    def path(self) -> str:
        return os.path.join(self.snapshot_directory, self.snapshot_name)

    def verify(self) -> None:
        """Verify that the private executable snapshot is unchanged."""
        current_directory = os.fstat(self.directory_descriptor)
        if (
            not stat.S_ISDIR(current_directory.st_mode)
            or current_directory.st_uid != os.geteuid()
            or stat.S_IMODE(current_directory.st_mode) != 0o500
            or not same_object(self.directory_state, current_directory)
            or set(os.listdir(self.directory_descriptor)) != {self.snapshot_name}
        ):
            fail(f"private executable snapshot directory changed: {self.name}")
        content, current = read_bound_regular(
            self.directory_descriptor,
            self.snapshot_name,
            max_bytes=MAX_EXECUTABLE_BYTES,
        )
        if (
            current.st_uid != os.geteuid()
            or stat.S_IMODE(current.st_mode) != 0o500
            or not same_file_state(self.snapshot_state, current)
            or hashlib.sha256(content).digest() != self.digest
        ):
            fail(f"private executable snapshot changed: {self.name}")
        if self.interpreter is not None:
            self.interpreter.verify()

    def close(self) -> None:
        """Remove only the descriptor-bound private snapshot."""
        actions: list[Callable[[], None]] = [
            lambda: cleanup_private_snapshot(
                self.directory_descriptor,
                self.snapshot_directory,
                self.snapshot_name,
                self.snapshot_state,
            ),
            lambda: cleanup_private_snapshot_directory(
                self.parent_descriptor,
                self.snapshot_directory_name,
                self.directory_descriptor,
            ),
            lambda: os.close(self.directory_descriptor),
        ]
        if self.parent_descriptor >= 0:
            actions.append(lambda: os.close(self.parent_descriptor))
        if self.interpreter is not None:
            actions.append(self.interpreter.close)
        run_cleanup_actions(*actions)


class BoundCommand(NamedTuple):
    executable: BoundExecutable
    arguments: tuple[str, ...]


def fail(message: str) -> NoReturn:
    raise RuntimeError(message)


def literal_ip(variable: str) -> str:
    value = os.environ.get(variable)
    if not value:
        fail(f"set one operator-verified literal {variable}")
    if "%" in value or any(character.isspace() or ord(character) < 32 for character in value):
        fail(f"{variable} must be one canonical literal IP address")
    try:
        parsed = ipaddress.ip_address(value)
    except ValueError as error:
        fail(f"{variable} must be one canonical literal IP address: {error}")
    if not isinstance(parsed, ipaddress.IPv4Address):
        fail(
            f"{variable} must be a canonical IPv4 address because the "
            "current Nomad templates append ports without IPv6 brackets"
        )
    canonical = str(parsed)
    if value != canonical:
        fail(f"{variable} is not canonical; use {canonical}")
    return canonical


def open_bound_directory(path: str, *, require_private_owner: bool) -> int:
    """Open an absolute directory one no-follow component at a time."""
    resolved = os.path.realpath(path)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(os.path.sep, flags)
    try:
        for component in [part for part in resolved.split(os.path.sep) if part]:
            next_descriptor = os.open(
                component,
                flags | nofollow,
                dir_fd=descriptor,
            )
            os.close(descriptor)
            descriptor = next_descriptor
        metadata = os.fstat(descriptor)
        if not stat.S_ISDIR(metadata.st_mode):
            fail(f"not a directory: {path}")
        if require_private_owner and (
            metadata.st_uid != os.geteuid() or stat.S_IMODE(metadata.st_mode) & 0o022
        ):
            fail(
                f"directory must be owned by this user and not group/world writable: {path}"
            )
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def same_object(left: os.stat_result, right: os.stat_result) -> bool:
    return left.st_dev == right.st_dev and left.st_ino == right.st_ino


def _rename_noreplace(directory: int, source: str, destination: str) -> None:
    """Atomically rename one direct entry without replacing another entry."""
    library = ctypes.CDLL(None, use_errno=True)
    source_bytes = os.fsencode(source)
    destination_bytes = os.fsencode(destination)
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        operation = library.renameat2
        operation.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        operation.restype = ctypes.c_int
        result = operation(
            directory,
            source_bytes,
            directory,
            destination_bytes,
            1,
        )
    elif hasattr(library, "renameatx_np"):
        operation = library.renameatx_np
        operation.argtypes = (
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_uint,
        )
        operation.restype = ctypes.c_int
        result = operation(
            directory,
            source_bytes,
            directory,
            destination_bytes,
            0x00000004,
        )
    else:
        fail("atomic no-replace cleanup is unavailable")
    if result != 0:
        number = ctypes.get_errno()
        raise OSError(number, os.strerror(number), source)


def _restore_quarantined_entry(
    directory: int,
    quarantine: str,
    original: str,
) -> None:
    try:
        _rename_noreplace(directory, quarantine, original)
    except FileExistsError:
        return
    os.fsync(directory)


def _quarantine_owned_entry(
    directory: int,
    name: str,
    expected: os.stat_result,
    *,
    is_directory: bool = False,
) -> bool:
    """Retain a regular file so inode reuse cannot redirect cleanup."""
    if is_directory:
        return _quarantine_bound_entry(directory, name, expected, is_directory=True)
    try:
        descriptor = os.open(
            name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC | os.O_NONBLOCK,
            dir_fd=directory,
        )
    except FileNotFoundError:
        return False
    except OSError as error:
        if error.errno == errno.ELOOP:
            return False
        raise
    try:
        if not same_file_state(expected, os.fstat(descriptor)):
            return False
        return _quarantine_bound_entry(directory, name, expected)
    finally:
        os.close(descriptor)


def _quarantine_bound_entry(
    directory: int,
    name: str,
    expected: os.stat_result,
    *,
    is_directory: bool = False,
) -> bool:
    """Atomically isolate and delete only the exact expected direct entry."""
    quarantine = ".odysseus-cleanup-" + secrets.token_hex(16)
    try:
        _rename_noreplace(directory, name, quarantine)
    except FileNotFoundError:
        return False
    moved = os.stat(quarantine, dir_fd=directory, follow_symlinks=False)
    if not same_object(expected, moved):
        _restore_quarantined_entry(directory, quarantine, name)
        return False
    try:
        if is_directory:
            flags = (
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0)
            )
            descriptor = os.open(quarantine, flags, dir_fd=directory)
            try:
                opened = os.fstat(descriptor)
                if (
                    not stat.S_ISDIR(opened.st_mode)
                    or not same_object(expected, opened)
                    or os.listdir(descriptor)
                ):
                    _restore_quarantined_entry(directory, quarantine, name)
                    return False
                os.rmdir(quarantine, dir_fd=directory)
            except BaseException:
                try:
                    _restore_quarantined_entry(directory, quarantine, name)
                finally:
                    try:
                        os.close(descriptor)
                    except BaseException:
                        pass
                raise
            else:
                os.close(descriptor)
        else:
            terminal = os.stat(quarantine, dir_fd=directory, follow_symlinks=False)
            if (
                not stat.S_ISREG(terminal.st_mode)
                or not same_object(expected, terminal)
                or terminal.st_uid != os.geteuid()
                or terminal.st_nlink != 1
            ):
                _restore_quarantined_entry(directory, quarantine, name)
                return False
            os.unlink(quarantine, dir_fd=directory)
        os.fsync(directory)
        return True
    except BaseException:
        try:
            _restore_quarantined_entry(directory, quarantine, name)
        except (FileExistsError, FileNotFoundError):
            pass
        raise


def parse_identity(value: str, variable: str) -> tuple[int, int]:
    fields = value.split(":")
    if len(fields) != 2 or not all(field.isdigit() for field in fields):
        fail(f"{variable} must be the approved output device:inode receipt")
    return int(fields[0]), int(fields[1])


def same_file_state(left: os.stat_result, right: os.stat_result) -> bool:
    fields = (
        "st_dev",
        "st_ino",
        "st_nlink",
        "st_size",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    return all(getattr(left, field) == getattr(right, field) for field in fields)


def same_directory_state(left: os.stat_result, right: os.stat_result) -> bool:
    fields = (
        "st_dev",
        "st_ino",
        "st_nlink",
        "st_uid",
        "st_mode",
        "st_mtime_ns",
        "st_ctime_ns",
    )
    return all(getattr(left, field) == getattr(right, field) for field in fields)


def directory_path_matches(descriptor: int, path: str) -> bool:
    try:
        current = os.stat(path, follow_symlinks=False)
    except FileNotFoundError:
        return False
    return stat.S_ISDIR(current.st_mode) and same_object(current, os.fstat(descriptor))


def cleanup_private_snapshot(
    directory: int,
    path: str,
    name: str,
    created: os.stat_result | None,
) -> None:
    """Remove owned snapshot entries without deleting replacement objects."""

    def restore_directory_mode() -> None:
        os.fchmod(directory, 0o700)

    def remove_owned_leaf() -> None:
        if created is not None:
            _quarantine_owned_entry(directory, name, created)

    run_cleanup_actions(
        restore_directory_mode,
        remove_owned_leaf,
    )


def cleanup_private_snapshot_directory(
    parent: int,
    name: str,
    directory: int,
) -> None:
    """Remove the private snapshot directory only through its retained parent."""
    if parent >= 0 and name:
        _quarantine_owned_entry(
            parent,
            name,
            os.fstat(directory),
            is_directory=True,
        )


def verify_approved_output(
    directory: int,
    approved_identity: tuple[int, int],
) -> os.stat_result:
    """Verify the bound output directory identity and private metadata."""
    metadata = os.fstat(directory)
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or stat.S_IMODE(metadata.st_mode) != 0o700
        or (metadata.st_dev, metadata.st_ino) != approved_identity
    ):
        fail("approved output directory identity or private metadata does not match")
    return metadata


def verify_bound_parent_and_output(
    parent: int,
    parent_path: str,
    expected_parent_state: os.stat_result,
    output_name: str,
    output: int,
    approved_identity: tuple[int, int],
    expected_output_state: os.stat_result,
    boundary: str,
) -> None:
    """Revalidate the parent and directly bind its approved output entry."""
    current_parent = os.fstat(parent)
    if (
        not stat.S_ISDIR(current_parent.st_mode)
        or current_parent.st_uid != os.geteuid()
        or stat.S_IMODE(current_parent.st_mode) & 0o022
        or not same_directory_state(expected_parent_state, current_parent)
        or not directory_path_matches(parent, parent_path)
    ):
        fail(f"output parent changed after {boundary}")

    current_output = verify_approved_output(output, approved_identity)
    direct_output = entry_state(parent, output_name)
    if (
        direct_output is None
        or not stat.S_ISDIR(direct_output.st_mode)
        or not same_directory_state(expected_output_state, current_output)
        or not same_directory_state(current_output, direct_output)
    ):
        fail(f"approved output dentry changed after {boundary}")


def entry_state(directory: int, name: str) -> os.stat_result | None:
    try:
        return os.stat(name, dir_fd=directory, follow_symlinks=False)
    except FileNotFoundError:
        return None


def read_bound_regular(
    directory: int,
    name: str,
    *,
    max_bytes: int = MAX_NOMAD_CONFIG_BYTES,
) -> tuple[bytes, os.stat_result]:
    before = entry_state(directory, name)
    if before is None:
        fail(f"required input is missing: {name}")
    if (
        stat.S_ISLNK(before.st_mode)
        or not stat.S_ISREG(before.st_mode)
        or before.st_nlink != 1
        or before.st_uid != os.geteuid()
    ):
        fail(f"input must be a direct, singly linked, owner-bound regular file: {name}")
    if before.st_size > max_bytes:
        fail(f"input exceeds the {max_bytes}-byte limit: {name}")
    descriptor = os.open(
        name,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0),
        dir_fd=directory,
    )
    try:
        opened = os.fstat(descriptor)
        if not stat.S_ISREG(opened.st_mode) or not same_object(before, opened):
            fail(f"input changed while it was bound: {name}")
        chunks: list[bytes] = []
        total = 0
        while total <= max_bytes:
            chunk = os.read(descriptor, min(1024 * 1024, max_bytes + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
        if total > max_bytes:
            fail(f"input exceeds the {max_bytes}-byte limit: {name}")
        after = os.fstat(descriptor)
        if not same_file_state(opened, after):
            fail(f"input changed while it was read: {name}")
        first = b"".join(chunks)
        reread = bytearray()
        offset = 0
        while len(reread) <= max_bytes:
            chunk = os.pread(
                descriptor,
                min(1024 * 1024, max_bytes + 1 - len(reread)),
                offset,
            )
            if not chunk:
                break
            reread.extend(chunk)
            offset += len(chunk)
        terminal = os.fstat(descriptor)
        named = entry_state(directory, name)
        if (
            len(reread) > max_bytes
            or not same_file_state(after, terminal)
            or named is None
            or not same_file_state(terminal, named)
            or bytes(reread) != first
        ):
            fail(f"input changed while it was read: {name}")
        return first, terminal
    finally:
        os.close(descriptor)


def executable_for_current_user(metadata: os.stat_result) -> bool:
    """Return whether mode bits permit this process to execute the file."""
    mode = stat.S_IMODE(metadata.st_mode)
    if os.geteuid() == 0:
        return bool(mode & 0o111)
    if metadata.st_uid == os.geteuid():
        return bool(mode & stat.S_IXUSR)
    if metadata.st_gid == os.getegid() or metadata.st_gid in os.getgroups():
        return bool(mode & stat.S_IXGRP)
    return bool(mode & stat.S_IXOTH)


def adhoc_sign_darwin_system_snapshot(selected: str, snapshot_path: str) -> bool:
    """Make a copied Darwin platform binary executable off the system volume."""
    selected_real = os.path.realpath(selected)
    if sys.platform != "darwin" or not selected_real.startswith(
        ("/usr/bin/", "/bin/")
    ):
        return False
    signer = "/usr/bin/codesign"
    before = os.stat(signer, follow_symlinks=True)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != 0
        or stat.S_IMODE(before.st_mode) & 0o022
    ):
        fail("fixed Darwin code-signing boundary is unsafe")
    process = subprocess.Popen(
        [signer, "--force", "--sign", "-", snapshot_path],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        start_new_session=True,
    )
    try:
        returncode = process.wait(timeout=COMMAND_TIMEOUT_SECONDS)
    except subprocess.TimeoutExpired as error:
        terminate_process_group(process)
        raise RuntimeError("Darwin snapshot code signing timed out") from error
    except BaseException:
        terminate_process_group(process)
        raise
    after = os.stat(signer, follow_symlinks=True)
    if not same_file_state(before, after):
        fail("fixed Darwin code-signing boundary changed")
    if returncode != 0:
        fail("could not ad-hoc sign Darwin executable snapshot")
    return True


def bind_executable(name: str, unavailable_message: str) -> BoundExecutable:
    """Copy one stable selected executable into an owner-private snapshot."""
    selected = shutil.which(name)
    if not selected:
        fail(unavailable_message)
    before = os.stat(selected, follow_symlinks=False)
    source = os.open(
        selected,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0),
    )
    snapshot_directory = ""
    snapshot_directory_name = ""
    parent_descriptor = -1
    directory_descriptor = -1
    snapshot_name = "executable"
    snapshot_state: os.stat_result | None = None
    interpreter: BoundExecutable | None = None
    try:
        opened = os.fstat(source)
        if (
            not stat.S_ISREG(opened.st_mode)
            or not same_file_state(before, opened)
            or not executable_for_current_user(opened)
            or opened.st_size > MAX_EXECUTABLE_BYTES
        ):
            fail(f"selected executable is not a stable executable file: {name}")

        first_line = os.read(source, 4096).split(b"\n", 1)[0]
        os.lseek(source, 0, os.SEEK_SET)
        if first_line.startswith(b"#!"):
            try:
                shebang = first_line[2:].decode("utf-8").strip().split()
            except UnicodeDecodeError as error:
                raise RuntimeError(f"selected {name} has an invalid shebang") from error
            if not shebang:
                fail(f"selected {name} has an empty shebang")
            if shebang[0] == "/usr/bin/env":
                if len(shebang) != 2 or shebang[1] not in {"sh", "bash", "python3"}:
                    fail(f"selected {name} has an unbound env shebang")
                interpreter_path = shutil.which(shebang[1], path=os.defpath)
                if interpreter_path is not None:
                    # Bind the canonical target of the fixed system alias.
                    interpreter_path = os.path.realpath(interpreter_path, strict=True)
            elif len(shebang) == 1 and os.path.isabs(shebang[0]):
                interpreter_path = shebang[0]
            else:
                fail(f"selected {name} has an unsupported shebang")
            if interpreter_path is None:
                fail(f"selected {name} shebang interpreter is unavailable")
            original_path = os.environ.get("PATH")
            try:
                os.environ["PATH"] = os.path.dirname(interpreter_path)
                candidate_interpreter = bind_executable(
                    os.path.basename(interpreter_path),
                    f"selected {name} shebang interpreter is unavailable",
                )
                if candidate_interpreter.interpreter is not None:
                    candidate_interpreter.close()
                    fail(
                        f"selected {name} has a nested script interpreter chain"
                    )
                interpreter = candidate_interpreter
            finally:
                if original_path is None:
                    os.environ.pop("PATH", None)
                else:
                    os.environ["PATH"] = original_path

        snapshot_directory = tempfile.mkdtemp(
            prefix=f"odysseus-nomad-{name}-"
        )
        snapshot_directory_name = os.path.basename(snapshot_directory)
        os.chmod(snapshot_directory, 0o700)
        parent_descriptor = os.open(
            os.path.dirname(snapshot_directory),
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_DIRECTORY", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
        directory_descriptor = os.open(
            snapshot_directory_name,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            dir_fd=parent_descriptor,
        )
        snapshot = os.open(
            snapshot_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
            0o400,
            dir_fd=directory_descriptor,
        )
        snapshot_state = os.fstat(snapshot)
        digest = hashlib.sha256()
        copied = 0
        try:
            while True:
                chunk = os.read(source, 1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > MAX_EXECUTABLE_BYTES:
                    fail(
                        f"selected executable exceeds the byte limit: {name}"
                    )
                digest.update(chunk)
                offset = 0
                while offset < len(chunk):
                    written = os.write(snapshot, chunk[offset:])
                    if written <= 0:
                        fail(f"short write while snapshotting executable: {name}")
                    offset += written
            source_after = os.fstat(source)
            try:
                path_after = os.stat(selected, follow_symlinks=True)
            except FileNotFoundError:
                fail(f"selected executable changed while it was bound: {name}")
            if (
                not same_file_state(opened, source_after)
                or not same_file_state(source_after, path_after)
            ):
                fail(f"selected executable changed while it was bound: {name}")
            os.fchmod(snapshot, 0o500)
            os.fsync(snapshot)
            snapshot_state = os.fstat(snapshot)
        finally:
            os.close(snapshot)
        snapshot_path = os.path.join(snapshot_directory, snapshot_name)
        signed = adhoc_sign_darwin_system_snapshot(selected, snapshot_path)
        if signed:
            reader = os.open(
                snapshot_name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=directory_descriptor,
            )
            try:
                if not stat.S_ISREG(os.fstat(reader).st_mode):
                    fail(f"signed executable snapshot is not regular: {name}")
                snapshot_content = bytearray()
                while True:
                    chunk = os.read(reader, 1024 * 1024)
                    if not chunk:
                        break
                    snapshot_content.extend(chunk)
                    if len(snapshot_content) > MAX_EXECUTABLE_BYTES:
                        fail(
                            f"signed executable snapshot exceeds the byte limit: {name}"
                        )
                snapshot_state = os.fstat(reader)
                digest = hashlib.sha256(snapshot_content)
            finally:
                os.close(reader)
        os.fchmod(directory_descriptor, 0o500)
        directory_state = os.fstat(directory_descriptor)
        bound = BoundExecutable(
            name=name,
            selected_path=selected,
            snapshot_directory=snapshot_directory,
            directory_descriptor=directory_descriptor,
            snapshot_name=snapshot_name,
            snapshot_state=snapshot_state,
            directory_state=directory_state,
            digest=digest.digest(),
            parent_descriptor=parent_descriptor,
            snapshot_directory_name=snapshot_directory_name,
            interpreter=interpreter,
        )
        bound.verify()
        directory_descriptor = -1
        parent_descriptor = -1
        snapshot_directory = ""
        interpreter = None
        return bound
    finally:
        actions: list[Callable[[], None]] = [lambda: os.close(source)]
        if directory_descriptor >= 0:
            actions.extend(
                (
                    lambda: cleanup_private_snapshot(
                        directory_descriptor,
                        snapshot_directory,
                        snapshot_name,
                        snapshot_state,
                    ),
                    lambda: cleanup_private_snapshot_directory(
                        parent_descriptor,
                        snapshot_directory_name,
                        directory_descriptor,
                    ),
                    lambda: os.close(directory_descriptor),
                )
            )
        if parent_descriptor >= 0:
            actions.append(lambda: os.close(parent_descriptor))
        if interpreter is not None:
            actions.append(interpreter.close)
        run_cleanup_actions(*actions)


def popen_bound(
    executable: BoundExecutable,
    arguments: tuple[str, ...],
    *,
    deadline: float | None = None,
    **kwargs: object,
) -> subprocess.Popen[bytes]:
    """Execute through already-open objects, never the snapshot pathname."""
    if not sys.platform.startswith("linux"):
        fail("Linux descriptor execution is required; this platform is unsupported")
    script_descriptor = -1
    launch = executable.interpreter or executable
    launch_descriptor = os.open(
        launch.snapshot_name,
        os.O_RDONLY
        | getattr(os, "O_CLOEXEC", 0)
        | getattr(os, "O_NOFOLLOW", 0)
        | getattr(os, "O_NONBLOCK", 0),
        dir_fd=launch.directory_descriptor,
    )
    try:
        if not stat.S_ISREG(os.fstat(launch_descriptor).st_mode):
            fail(f"newly opened executable is not regular: {launch.name}")
        verify_open_executable(launch, launch_descriptor)
        command = [executable.name]
        inherited = [launch_descriptor, launch.directory_descriptor]
        if executable.interpreter is not None:
            script_descriptor = os.open(
                executable.snapshot_name,
                os.O_RDONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0)
                | getattr(os, "O_NONBLOCK", 0),
                dir_fd=executable.directory_descriptor,
            )
            if not stat.S_ISREG(os.fstat(script_descriptor).st_mode):
                fail(f"newly opened script is not regular: {executable.name}")
            verify_open_executable(executable, script_descriptor)
            inherited.append(script_descriptor)
            command.append(f"/dev/fd/{script_descriptor}")
        command.extend(arguments)
        environment = {
            "PATH": os.defpath,
            "LANG": "C",
            "LC_ALL": "C",
        }
        for variable in ("NOMAD_SERVER_IP", "NOMAD_ADVERTISE_ADDR"):
            value = os.environ.get(variable)
            if value is not None:
                environment[variable] = value
        launch_path = f"/proc/self/fd/{launch_descriptor}"
        if deadline is not None and time.monotonic() >= deadline:
            fail(f"{executable.name} operation deadline expired before launch")
        return subprocess.Popen(
            command,
            executable=launch_path,
            env=environment,
            pass_fds=tuple(inherited),
            preexec_fn=None,
            **kwargs,
        )
    finally:
        os.close(launch_descriptor)
        if script_descriptor >= 0:
            os.close(script_descriptor)


def verify_open_executable(executable: BoundExecutable, descriptor: int) -> None:
    """Verify the exact newly opened inode that will reach exec or an interpreter."""
    content = bytearray()
    os.lseek(descriptor, 0, os.SEEK_SET)
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        content.extend(chunk)
        if len(content) > MAX_EXECUTABLE_BYTES:
            fail(f"newly opened executable exceeds the byte limit: {executable.name}")
    current = os.fstat(descriptor)
    os.lseek(descriptor, 0, os.SEEK_SET)
    if (
        not stat.S_ISREG(current.st_mode)
        or current.st_uid != os.geteuid()
        or current.st_nlink != 1
        or stat.S_IMODE(current.st_mode) != 0o500
        or not same_file_state(executable.snapshot_state, current)
        or hashlib.sha256(content).digest() != executable.digest
    ):
        fail(f"newly opened executable snapshot changed: {executable.name}")


def process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def signal_process_group(process_group: int, signal_number: int) -> None:
    try:
        os.killpg(process_group, signal_number)
    except ProcessLookupError:
        pass


def wait_for_process_group_exit(
    process_group: int,
    seconds: float,
    process: subprocess.Popen[bytes],
) -> bool:
    deadline = time.monotonic() + seconds
    while process_group_exists(process_group):
        process.poll()
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)
    return True


def terminate_process_group(process: subprocess.Popen[bytes]) -> bool:
    """Terminate the owned process group and reap the direct child."""
    signal_process_group(process.pid, signal.SIGTERM)
    extinct = wait_for_process_group_exit(
        process.pid, TERM_GRACE_SECONDS, process
    )
    if not extinct:
        signal_process_group(process.pid, signal.SIGKILL)
        extinct = wait_for_process_group_exit(
            process.pid, KILL_GRACE_SECONDS, process
        )
    try:
        process.wait(timeout=KILL_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        process.kill()
        try:
            process.wait(timeout=KILL_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            return False
    return extinct and not process_group_exists(process.pid)


def run_supervised(
    executable: BoundExecutable,
    arguments: tuple[str, ...],
    content: bytes,
    child_boundary: Callable[[], None],
    *,
    deadline: float | None = None,
) -> CommandResult:
    """Run one snapshot with finite time, output, and descendant ownership."""
    if deadline is None:
        deadline = time.monotonic() + COMMAND_TIMEOUT_SECONDS
    if time.monotonic() >= deadline:
        fail(f"{executable.name} operation deadline expired before launch")
    executable.verify()
    stdin = tempfile.TemporaryFile()
    stdin.write(content)
    stdin.seek(0)
    process: subprocess.Popen[bytes] | None = None
    stream_selector = selectors.DefaultSelector()
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    failure: str | None = None
    try:
        if time.monotonic() >= deadline:
            fail(f"{executable.name} operation deadline expired before launch")
        process = popen_bound(
            executable,
            arguments,
            deadline=deadline,
            stdin=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            start_new_session=True,
        )
        if process.stdout is None or process.stderr is None:
            fail(f"could not capture child output: {executable.name}")
        stream_selector.register(process.stdout, selectors.EVENT_READ, "stdout")
        stream_selector.register(process.stderr, selectors.EVENT_READ, "stderr")
        while process.poll() is None or stream_selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = (
                    f"{executable.name} timed out at the shared operation deadline"
                )
                break
            events = stream_selector.select(min(0.05, remaining))
            for key, _ in events:
                chunk = os.read(key.fd, 64 * 1024)
                if not chunk:
                    stream_selector.unregister(key.fileobj)
                    continue
                buffer = buffers[key.data]
                available = OUTPUT_LIMIT_BYTES - len(buffer)
                if available > 0:
                    buffer.extend(chunk[:available])
                if len(chunk) > available:
                    failure = (
                        f"{executable.name} exceeded the "
                        f"{OUTPUT_LIMIT_BYTES}-byte output limit"
                    )
                    break
            if failure is not None:
                break

        if failure is not None:
            def terminate_after_failure() -> None:
                nonlocal failure
                if not terminate_process_group(process):
                    failure += "; process group did not become extinct"

            run_cleanup_actions(
                terminate_after_failure,
                pending_primary=RuntimeError(failure),
            )
        else:
            process.wait(timeout=KILL_GRACE_SECONDS)
            if process_group_exists(process.pid):
                failure = f"{executable.name} left running descendants"
                def terminate_after_failure() -> None:
                    nonlocal failure
                    if not terminate_process_group(process):
                        failure += "; process group did not become extinct"

                run_cleanup_actions(
                    terminate_after_failure,
                    pending_primary=RuntimeError(failure),
                )
    except BaseException:
        if process is not None:
            run_cleanup_actions(lambda: terminate_process_group(process))
        raise
    finally:
        actions: list[Callable[[], None]] = [stream_selector.close, stdin.close]
        if process is not None:
            if process.stdout is not None:
                actions.append(process.stdout.close)
            if process.stderr is not None:
                actions.append(process.stderr.close)
            actions.extend((executable.verify, child_boundary))
        pending = RuntimeError(failure) if failure is not None else None
        run_cleanup_actions(*actions, pending_primary=pending)

    if failure is not None:
        fail(failure)
    if process is None:
        fail(f"could not start child process: {executable.name}")
    return CommandResult(
        returncode=process.returncode,
        stdout=bytes(buffers["stdout"]),
        stderr=bytes(buffers["stderr"]),
    )


def write_new_regular(directory: int, name: str, content: bytes) -> os.stat_result:
    descriptor = os.open(
        name,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0),
        0o600,
        dir_fd=directory,
    )
    try:
        offset = 0
        while offset < len(content):
            written = os.write(descriptor, content[offset:])
            if written <= 0:
                fail(f"short write while publishing {name}")
            offset += written
        os.fchmod(descriptor, 0o644)
        os.fsync(descriptor)
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
            fail(f"published file identity is unsafe: {name}")
        return metadata
    except BaseException:
        try:
            owned = os.fstat(descriptor)
            current = entry_state(directory, name)
            if (
                current is not None
                and stat.S_ISREG(owned.st_mode)
                and owned.st_uid == os.geteuid()
                and same_object(owned, current)
            ):
                _quarantine_owned_entry(directory, name, owned)
                os.fsync(directory)
        except OSError:
            pass
        raise
    finally:
        os.close(descriptor)


def remove_exact_publication(
    directory: int,
    name: str,
    identity: os.stat_result,
) -> bool:
    """Unlink only the direct entry whose inode this run created."""
    return _quarantine_owned_entry(directory, name, identity)


def published_file_state_matches(
    expected: os.stat_result,
    current: os.stat_result,
) -> bool:
    return (
        stat.S_ISREG(current.st_mode)
        and current.st_uid == os.geteuid()
        and current.st_nlink == 1
        and stat.S_IMODE(current.st_mode) == 0o644
        and same_object(expected, current)
        and same_file_state(expected, current)
    )


def verify_exact_directory(
    directory: int,
    expected: dict[str, tuple[bytes, os.stat_result]],
) -> None:
    if set(os.listdir(directory)) != set(expected):
        fail("render directory does not contain the exact canonical file pair")
    for name, (content, identity) in expected.items():
        observed, current = read_bound_regular(directory, name)
        if not published_file_state_matches(identity, current) or observed != content:
            fail(f"rendered file changed after validation: {name}")


def verify_completion_state(
    directory: int,
    expected: dict[str, tuple[bytes, os.stat_result]],
    approved_identity: tuple[int, int],
    expected_directory_state: os.stat_result,
) -> None:
    """Recheck the complete publication state after the content walk."""
    expected_names = set(expected)
    if set(os.listdir(directory)) != expected_names:
        fail("render directory entries changed after content verification")
    for name, (_, identity) in expected.items():
        current = entry_state(directory, name)
        if current is None or not published_file_state_matches(identity, current):
            fail(f"rendered file metadata changed after content verification: {name}")
    current_directory_state = verify_approved_output(directory, approved_identity)
    if not same_directory_state(expected_directory_state, current_directory_state):
        fail("render directory metadata changed after content verification")
    if set(os.listdir(directory)) != expected_names:
        fail("render directory entries changed after content verification")


def render_sources(
    source_directory: int,
    values: dict[bytes, bytes],
    envsubst: BoundExecutable,
    child_boundary: Callable[[], None],
    *,
    deadline: float | None = None,
) -> tuple[dict[str, bytes], dict[str, bytes], dict[str, os.stat_result]]:
    rendered: dict[str, bytes] = {}
    sources: dict[str, bytes] = {}
    identities: dict[str, os.stat_result] = {}
    for name in CONFIG_NAMES:
        source, identity = read_bound_regular(source_directory, name)
        for placeholder, count in PLACEHOLDERS[name].items():
            if source.count(placeholder) != count:
                fail(
                    f"{name} must contain exactly {count} {placeholder.decode()} placeholder(s)"
                )
        content = source
        for placeholder, value in values.items():
            content = content.replace(placeholder, value)
        if b"${NOMAD_" in content:
            fail(f"unresolved Nomad placeholder remains in {name}")
        substitution = run_supervised(
            envsubst,
            ("${NOMAD_SERVER_IP} ${NOMAD_ADVERTISE_ADDR}",),
            source,
            child_boundary,
            deadline=deadline,
        )
        if substitution.returncode != 0 or substitution.stdout != content:
            fail(f"envsubst did not produce the exact expected bytes for {name}")
        rendered[name] = substitution.stdout
        sources[name] = source
        identities[name] = identity
    return rendered, sources, identities


def select_parser() -> BoundCommand:
    nomad = shutil.which("nomad")
    if nomad:
        return BoundCommand(
            bind_executable(
                "nomad",
                "Nomad HCL parser unavailable (requires nomad or hclfmt)",
            ),
            ("fmt", "-check"),
        )
    hclfmt = shutil.which("hclfmt")
    if hclfmt:
        return BoundCommand(
            bind_executable(
                "hclfmt",
                "Nomad HCL parser unavailable (requires nomad or hclfmt)",
            ),
            ("--check",),
        )
    fail("Nomad HCL parser unavailable (requires nomad or hclfmt)")


def validate_rendered(
    parser_command: BoundCommand,
    rendered: dict[str, bytes],
    child_boundary: Callable[[], None],
    *,
    deadline: float | None = None,
) -> None:
    """Parse the exact rendered bytes through stdin, not a mutable path."""
    is_nomad = parser_command.executable.name == "nomad"
    for name in CONFIG_NAMES:
        arguments = (
            (*parser_command.arguments, "-")
            if is_nomad
            else parser_command.arguments
        )
        result = run_supervised(
            parser_command.executable,
            arguments,
            rendered[name],
            child_boundary,
            deadline=deadline,
        )
        if result.returncode != 0:
            fail(f"Nomad HCL parser rejected the rendered configuration: {name}")


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--source-dir", required=True)
    parser.add_argument("--output-dir", required=True)
    return parser.parse_args()


def run() -> None:
    arguments = parse_arguments()
    server_ip = literal_ip("NOMAD_SERVER_IP")
    advertise_ip = literal_ip("NOMAD_ADVERTISE_ADDR")

    requested = os.path.abspath(arguments.output_dir)
    approval_value = os.environ.get("NOMAD_RENDER_APPROVED_DIR")
    if not approval_value:
        fail("set NOMAD_RENDER_APPROVED_DIR to the exact output directory")
    approved = os.path.abspath(approval_value)
    if requested != approved:
        fail("NOMAD_RENDER_APPROVED_DIR does not match the exact output directory")
    approval_identity_value = os.environ.get("NOMAD_RENDER_APPROVED_ID")
    if not approval_identity_value:
        fail("set NOMAD_RENDER_APPROVED_ID to the approved output device:inode receipt")
    approved_identity = parse_identity(
        approval_identity_value, "NOMAD_RENDER_APPROVED_ID"
    )
    if requested in {
        os.path.sep,
        os.path.realpath(os.getcwd()),
        os.path.realpath(Path.home()),
    }:
        fail("output directory must be an explicit, narrow destination")

    output_name = os.path.basename(requested)
    parent_path = os.path.dirname(requested)
    if not output_name or output_name in {".", ".."}:
        fail("output directory must have a safe final component")
    parent = open_bound_directory(parent_path, require_private_owner=True)
    source_path = os.path.abspath(arguments.source_dir)
    source_directory = -1
    output = -1
    output_identity: os.stat_result | None = None
    output_files: dict[str, os.stat_result] = {}
    envsubst: BoundExecutable | None = None
    parser_command: BoundCommand | None = None
    completed = False
    try:
        source_directory = open_bound_directory(
            source_path,
            require_private_owner=False,
        )
        if not directory_path_matches(parent, parent_path):
            fail("output parent changed while it was bound")
        try:
            output = os.open(
                output_name,
                os.O_RDONLY
                | getattr(os, "O_DIRECTORY", 0)
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent,
            )
        except (FileNotFoundError, NotADirectoryError):
            fail("approved output must be a pre-created direct directory")
        output_identity = verify_approved_output(output, approved_identity)
        direct_output = entry_state(parent, output_name)
        if direct_output is None or not same_object(direct_output, output_identity):
            fail("approved output path changed while it was bound")
        if os.listdir(output):
            fail("approved output directory must be empty before rendering")
        if not directory_path_matches(source_directory, source_path):
            fail("canonical Nomad source directory changed while it was bound")
        envsubst = bind_executable(
            "envsubst", "required render dependency unavailable: envsubst"
        )
        parser_command = select_parser()
        initial_parent_state = os.fstat(parent)
        initial_output_state = os.fstat(output)

        def verify_child_boundary() -> None:
            verify_bound_parent_and_output(
                parent,
                parent_path,
                initial_parent_state,
                output_name,
                output,
                approved_identity,
                initial_output_state,
                "child boundary",
            )

        verify_child_boundary()
        operation_deadline = time.monotonic() + COMMAND_TIMEOUT_SECONDS

        rendered, source_bytes, source_identities = render_sources(
            source_directory,
            {
                b"${NOMAD_SERVER_IP}": server_ip.encode(),
                b"${NOMAD_ADVERTISE_ADDR}": advertise_ip.encode(),
            },
            envsubst,
            verify_child_boundary,
            deadline=operation_deadline,
        )
        verify_approved_output(output, approved_identity)
        if os.listdir(output):
            fail("approved output directory changed during rendering")
        validate_rendered(
            parser_command,
            rendered,
            verify_child_boundary,
            deadline=operation_deadline,
        )
        if not directory_path_matches(source_directory, source_path):
            fail("canonical Nomad source directory changed during validation")
        for name, identity in source_identities.items():
            current_bytes, current = read_bound_regular(source_directory, name)
            if (
                not same_file_state(current, identity)
                or current_bytes != source_bytes[name]
            ):
                fail(f"canonical Nomad source changed during validation: {name}")
        if not directory_path_matches(parent, parent_path):
            fail("output parent changed during validation")
        verify_approved_output(output, approved_identity)
        if os.listdir(output):
            fail("approved output directory changed during validation")
        direct_output = entry_state(parent, output_name)
        if direct_output is None or not same_object(direct_output, output_identity):
            fail("approved output path does not name the owned publication")

        for name, content in rendered.items():
            verify_approved_output(output, approved_identity)
            output_files[name] = write_new_regular(output, name, content)
        os.fsync(output)
        final_directory_state = verify_approved_output(output, approved_identity)
        expected_output = {
            name: (rendered[name], output_files[name]) for name in CONFIG_NAMES
        }
        verify_exact_directory(
            output,
            expected_output,
        )
        if not directory_path_matches(parent, parent_path):
            fail("output parent changed before completion")
        direct_output = entry_state(parent, output_name)
        if direct_output is None or not same_object(direct_output, output_identity):
            fail("approved output path changed before completion")
        verify_completion_state(
            output,
            expected_output,
            approved_identity,
            final_directory_state,
        )
        verify_bound_parent_and_output(
            parent,
            parent_path,
            initial_parent_state,
            output_name,
            output,
            approved_identity,
            final_directory_state,
            "final-state verification",
        )
        for name, identity in source_identities.items():
            current_bytes, current = read_bound_regular(source_directory, name)
            if (
                not same_file_state(current, identity)
                or current_bytes != source_bytes[name]
            ):
                fail(f"canonical Nomad source changed during publication: {name}")
        completed = True
        for name in CONFIG_NAMES:
            print(f"rendered and HCL-validated {requested}/{name}")
    finally:
        actions: list[Callable[[], None]] = []
        if output >= 0:
            if not completed:

                def rollback_owned_publications() -> None:
                    removed = False
                    rollback_actions: list[Callable[[], None]] = []
                    for name, identity in output_files.items():

                        def remove_one(
                            item_name: str = name,
                            item_identity: os.stat_result = identity,
                        ) -> None:
                            nonlocal removed
                            removed = (
                                remove_exact_publication(
                                    output,
                                    item_name,
                                    item_identity,
                                )
                                or removed
                            )

                        rollback_actions.append(remove_one)
                    run_cleanup_actions(*rollback_actions)
                    if removed:
                        os.fsync(output)

                actions.append(rollback_owned_publications)

                def report_retained_entries() -> None:
                    if os.listdir(output):
                        print(
                            "ERROR: incomplete output contains entries not owned by this "
                            f"publication and they were retained: {requested}",
                            file=sys.stderr,
                        )

                actions.append(report_retained_entries)
            actions.append(lambda: os.close(output))
        if source_directory >= 0:
            actions.append(lambda: os.close(source_directory))
        actions.append(lambda: os.close(parent))
        if parser_command is not None:
            actions.append(parser_command.executable.close)
        if envsubst is not None:
            actions.append(envsubst.close)
        run_cleanup_actions(*actions)


def main() -> int:
    with deferred_termination():
        try:
            run()
        except (OSError, RuntimeError, ValueError) as error:
            print(f"ERROR: {error}", file=sys.stderr)
            return 2
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
