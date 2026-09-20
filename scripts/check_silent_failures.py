#!/usr/bin/env python3
"""Reject silent-failure controls in sealed staged executable commands."""

from __future__ import annotations

import hashlib
import fcntl
import importlib
import importlib.machinery
import importlib.util
import io
import json
import os
import re
import resource
import signal
import stat
import subprocess
import sys
import tempfile
from dataclasses import dataclass
from pathlib import Path, PurePosixPath
from types import ModuleType
from typing import BinaryIO, Iterable, Iterator, TextIO


SHELL_SUFFIXES = {".bash", ".sh"}
EXPECTED_PYYAML_VERSION = "6.0.3"
RESTRICTED_POLICY_ROOT = "/run/trusted-policy"
RESTRICTED_WORK_ROOT = "/run/candidate-policy"
MAX_YAML_DOCUMENTS = 32
MAX_YAML_NODES = 100_000
MAX_YAML_DEPTH = 64
MAX_YAML_ALIASES = 1_000
CPU_SECONDS = 10
WALL_SECONDS = 30
FILE_DESCRIPTORS = 64
PROCESSES = 4_000
ADDRESS_SPACE_BYTES = 512 * 1024 * 1024
MAX_YAML_CLOSURE_FILES = 512
MAX_YAML_CLOSURE_BYTES = 32 * 1024 * 1024
MAX_FINDINGS = 256
MAX_DIAGNOSTIC_BYTES = 60 * 1024
MAX_GIT_DIAGNOSTIC_BYTES = 4096
MAX_SHELL_SOURCE_BYTES = 64 * 1024 * 1024


class PolicyError(RuntimeError):
    """The checker cannot establish its required trust or resource boundary."""


class DiagnosticLimit(PolicyError):
    """The checker stopped because its global diagnostic budget was exhausted."""


class _SealedYamlLoader:
    """Execute one authenticated source snapshot without reopening its path."""

    def __init__(self, path: str, source: bytes, package: bool) -> None:
        self.path = path
        self.source = source
        self.package = package

    def create_module(self, _spec: object) -> None:
        return None

    def exec_module(self, module: ModuleType) -> None:
        module.__file__ = self.path
        if self.package:
            module.__path__ = [f"<sealed:{self.path}>"]
        code = compile(self.source, self.path, "exec", dont_inherit=True)
        exec(code, module.__dict__)


class _RejectedYamlLoader:
    """Prevent PathFinder from reaching an unauthenticated YAML module."""

    def create_module(self, _spec: object) -> None:
        return None

    def exec_module(self, module: ModuleType) -> None:
        raise ImportError(f"unsealed PyYAML module is unavailable: {module.__name__}")


class _SealedYamlFinder:
    """Resolve the entire yaml namespace from authenticated in-memory bytes."""

    def __init__(self, loaders: dict[str, _SealedYamlLoader]) -> None:
        self.loaders = loaders
        self.rejected = _RejectedYamlLoader()

    def find_spec(
        self,
        fullname: str,
        _path: object = None,
        _target: object = None,
    ) -> object:
        if fullname != "yaml" and not fullname.startswith("yaml."):
            return None
        loader = self.loaders.get(fullname, self.rejected)
        package = isinstance(loader, _SealedYamlLoader) and loader.package
        return importlib.util.spec_from_loader(
            fullname,
            loader,
            origin=(loader.path if isinstance(loader, _SealedYamlLoader) else None),
            is_package=package,
        )

    def close(self) -> None:
        while self in sys.meta_path:
            sys.meta_path.remove(self)


class Reporter:
    """Emit bounded diagnostics without converting truncation into success."""

    _TRUNCATED = "ERROR: diagnostic budget exceeded; results truncated\n"

    def __init__(self) -> None:
        self.findings = 0
        self.bytes_written = 0
        self.exhausted = False

    def _write(self, text: str) -> None:
        data = text.encode("utf-8", "backslashreplace")
        os.write(sys.stderr.fileno(), data)
        self.bytes_written += len(data)

    def emit(self, text: str) -> None:
        if self.exhausted:
            raise DiagnosticLimit("diagnostic budget already exhausted")
        line = text.rstrip("\n") + "\n"
        encoded = line.encode("utf-8", "backslashreplace")
        reserve = len(self._TRUNCATED.encode("utf-8"))
        if (
            self.findings >= MAX_FINDINGS
            or self.bytes_written + len(encoded) > MAX_DIAGNOSTIC_BYTES - reserve
        ):
            self.exhausted = True
            self._write(self._TRUNCATED)
            raise DiagnosticLimit("diagnostic budget exceeded")
        self._write(line)
        self.findings += 1


def _identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def _directory_identity(value: os.stat_result) -> tuple[int, ...]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_nlink,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


@dataclass
class BoundFile:
    """One direct regular file whose pathname and descriptor remain identical."""

    path: str
    descriptor: int
    token: tuple[int, ...]
    directory_fd: int | None = None
    name: str | None = None

    @classmethod
    def open(cls, path: str, *, executable: bool = False) -> "BoundFile":
        path = os.path.abspath(path)
        return cls._open(path, path, None, executable=executable)

    @classmethod
    def open_at(
        cls,
        directory_fd: int,
        name: str,
        display_path: str,
        *,
        executable: bool = False,
    ) -> "BoundFile":
        return cls._open(name, display_path, directory_fd, executable=executable)

    @classmethod
    def _open(
        cls,
        route: str,
        display_path: str,
        directory_fd: int | None,
        *,
        executable: bool,
    ) -> "BoundFile":
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NONBLOCK
        if not hasattr(os, "O_NOFOLLOW"):
            raise PolicyError("no-follow file binding is unavailable")
        flags |= os.O_NOFOLLOW
        descriptor = -1
        try:
            named = os.stat(route, dir_fd=directory_fd, follow_symlinks=False)
            descriptor = os.open(route, flags, dir_fd=directory_fd)
            opened = os.fstat(descriptor)
        except OSError as error:
            if descriptor >= 0:
                os.close(descriptor)
            raise PolicyError(f"cannot bind {display_path}: {error}") from error
        if (
            _identity(named) != _identity(opened)
            or not stat.S_ISREG(opened.st_mode)
            or opened.st_uid not in {0, os.geteuid()}
            or opened.st_nlink != 1
            or stat.S_IMODE(opened.st_mode) & 0o022
            or (executable and not opened.st_mode & 0o111)
        ):
            os.close(descriptor)
            raise PolicyError(f"unsafe direct file route: {display_path}")
        return cls(
            display_path,
            descriptor,
            _identity(opened),
            directory_fd,
            route if directory_fd is not None else None,
        )

    def verify(self) -> None:
        if self.descriptor < 0:
            raise PolicyError(f"file binding is closed: {self.path}")
        try:
            named = (
                os.stat(self.name, dir_fd=self.directory_fd, follow_symlinks=False)
                if self.directory_fd is not None
                else os.lstat(self.path)
            )
            opened = os.fstat(self.descriptor)
        except OSError as error:
            raise PolicyError(f"cannot revalidate {self.path}: {error}") from error
        if self.token != _identity(named) or self.token != _identity(opened):
            raise PolicyError(f"file identity changed: {self.path}")

    def digest(self) -> str:
        self.verify()
        digest = hashlib.sha256()
        offset = 0
        while True:
            chunk = os.pread(self.descriptor, 64 * 1024, offset)
            if not chunk:
                break
            digest.update(chunk)
            offset += len(chunk)
        self.verify()
        if offset != self.token[6]:
            raise PolicyError(f"file content changed: {self.path}")
        return digest.hexdigest()

    def text_stream(self) -> TextIO:
        self.verify()
        raw = os.fdopen(os.dup(self.descriptor), "rb")
        return io.TextIOWrapper(raw, encoding="utf-8", errors="strict", newline=None)

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


@dataclass
class _IndexSnapshot:
    """An anonymous exact copy of the selected index passed to Git by FD."""

    descriptor: int
    size: int
    digest: str
    seals: int = 0

    @classmethod
    def capture(cls, source: BoundFile, expected_digest: str) -> "_IndexSnapshot":
        source.verify()
        path: str | None = None
        descriptor = -1
        linux = sys.platform.startswith("linux")
        if linux:
            names = (
                "F_ADD_SEALS",
                "F_GET_SEALS",
                "F_SEAL_SEAL",
                "F_SEAL_SHRINK",
                "F_SEAL_GROW",
                "F_SEAL_WRITE",
            )
            if not hasattr(os, "memfd_create") or not all(
                hasattr(fcntl, name) for name in names
            ):
                raise PolicyError("immutable staged-index snapshots are unavailable")
            flags = getattr(os, "MFD_CLOEXEC", 0x0001) | getattr(
                os, "MFD_ALLOW_SEALING", 0x0002
            )
            descriptor = os.memfd_create("odysseus-staged-index", flags)
        else:
            descriptor, path = tempfile.mkstemp(prefix="odysseus-staged-index-")

        digest = hashlib.sha256()
        offset = 0
        try:
            while offset < source.token[6]:
                chunk = os.pread(
                    source.descriptor,
                    min(64 * 1024, source.token[6] - offset),
                    offset,
                )
                if not chunk:
                    break
                view = memoryview(chunk)
                while view:
                    written = os.write(descriptor, view)
                    if written <= 0:
                        raise PolicyError("staged-index snapshot write made no progress")
                    view = view[written:]
                digest.update(chunk)
                offset += len(chunk)
            source.verify()
            if offset != source.token[6] or digest.hexdigest() != expected_digest:
                raise PolicyError("Git index changed while it was snapshotted")
            os.fchmod(descriptor, 0o400)
            seals = 0
            if linux:
                seals = (
                    fcntl.F_SEAL_SHRINK
                    | fcntl.F_SEAL_GROW
                    | fcntl.F_SEAL_WRITE
                    | fcntl.F_SEAL_SEAL
                )
                fcntl.fcntl(descriptor, fcntl.F_ADD_SEALS, seals)
            else:
                assert path is not None
                readonly = os.open(path, os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW)
                os.close(descriptor)
                descriptor = readonly
                os.unlink(path)
                path = None
            snapshot = cls(descriptor, offset, expected_digest, seals)
            snapshot.verify()
            return snapshot
        except BaseException:
            if descriptor >= 0:
                os.close(descriptor)
            if path is not None:
                try:
                    os.unlink(path)
                except FileNotFoundError:
                    pass
            raise

    def verify(self) -> None:
        if self.descriptor < 0:
            raise PolicyError("staged-index snapshot is closed")
        opened = os.fstat(self.descriptor)
        if not stat.S_ISREG(opened.st_mode) or opened.st_size != self.size:
            raise PolicyError("staged-index snapshot identity changed")
        if self.seals and fcntl.fcntl(self.descriptor, fcntl.F_GET_SEALS) & self.seals != self.seals:
            raise PolicyError("staged-index snapshot lost its immutable seals")
        digest = hashlib.sha256()
        offset = 0
        while offset < self.size:
            chunk = os.pread(
                self.descriptor, min(64 * 1024, self.size - offset), offset
            )
            if not chunk:
                break
            digest.update(chunk)
            offset += len(chunk)
        if offset != self.size or digest.hexdigest() != self.digest:
            raise PolicyError("staged-index snapshot content changed")

    def close(self) -> None:
        if self.descriptor >= 0:
            os.close(self.descriptor)
            self.descriptor = -1


def _git_route() -> str:
    if os.environ.get("ODYSSEUS_TRUSTED_POLICY_ROOT") == RESTRICTED_POLICY_ROOT:
        return os.environ.get("ODYSSEUS_PRE_COMMIT_GIT", "/usr/bin/git")
    return _required_environment("ODYSSEUS_PRE_COMMIT_GIT")


def _git_environment() -> dict[str, str]:
    """Return a fixed Git environment without ambient repository selectors."""

    environment = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_OPTIONAL_LOCKS": "0",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
    }
    index = os.environ.get("GIT_INDEX_FILE")
    if index and os.path.isabs(index) and "\x00" not in index:
        environment["GIT_INDEX_FILE"] = os.path.abspath(index)
    return environment


def _run_git_capture(
    arguments: list[str], cwd: str, *, index_descriptor: int | None = None
) -> bytes:
    environment = _git_environment()
    pass_fds: tuple[int, ...] = ()
    if index_descriptor is not None:
        os.fstat(index_descriptor)
        route = (
            "/proc/self/fd/{}" if sys.platform.startswith("linux")
            else "/dev/fd/{}"
        ).format(index_descriptor)
        environment["GIT_INDEX_FILE"] = route
        pass_fds = (index_descriptor,)
    try:
        result = subprocess.run(
            [_git_route(), "-C", cwd, *arguments],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
            close_fds=True,
            pass_fds=pass_fds,
            start_new_session=True,
            env=environment,
            timeout=WALL_SECONDS,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise PolicyError(f"cannot acquire staged Git snapshot: {error}") from error
    if result.returncode != 0:
        diagnostic = result.stderr[:MAX_GIT_DIAGNOSTIC_BYTES].decode(
            "utf-8", "backslashreplace"
        ).strip()
        raise PolicyError(
            "cannot acquire staged Git snapshot"
            + (f": {diagnostic}" if diagnostic else "")
        )
    return result.stdout


@dataclass(frozen=True)
class StagedEntry:
    path: str
    object_id: str


class _GitBlobReader(io.RawIOBase):
    """Hash exactly one `git cat-file --batch` blob while it is streamed."""

    def __init__(self, source: BinaryIO, size: int, algorithm: str) -> None:
        super().__init__()
        self.source = source
        self.remaining = size
        self.digest = hashlib.new(algorithm)
        self.digest.update(f"blob {size}\0".encode("ascii"))

    def readable(self) -> bool:
        return True

    def readinto(self, target: object) -> int:
        if self.remaining == 0:
            return 0
        view = memoryview(target).cast("B")
        wanted = min(len(view), self.remaining)
        data = self.source.read(wanted)
        if not data:
            raise PolicyError("staged Git blob ended before its declared size")
        view[: len(data)] = data
        self.digest.update(data)
        self.remaining -= len(data)
        return len(data)


class StagedBlob:
    """One immutable content-addressed index blob and its bounded Git reader."""

    def __init__(self, entry: StagedEntry, cwd: str, algorithm: str) -> None:
        self.entry = entry
        self.process: subprocess.Popen[bytes] | None = None
        self.raw: _GitBlobReader | None = None
        self.buffer: io.BufferedReader | None = None
        self.stream: TextIO | None = None
        try:
            self.process = subprocess.Popen(
                [_git_route(), "-C", cwd, "cat-file", "--batch"],
                stdin=subprocess.PIPE,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                close_fds=True,
                start_new_session=True,
                env=_git_environment(),
            )
            assert self.process.stdin is not None
            assert self.process.stdout is not None
            self.process.stdin.write(entry.object_id.encode("ascii") + b"\n")
            self.process.stdin.close()
            header = self.process.stdout.readline()
            parts = header.rstrip(b"\n").split(b" ")
            if len(parts) != 3:
                raise PolicyError("Git returned a malformed staged-object header")
            returned, object_type, raw_size = parts
            if (
                returned.decode("ascii", "strict") != entry.object_id
                or object_type != b"blob"
                or not raw_size.isdigit()
            ):
                raise PolicyError("Git returned the wrong staged object")
            size = int(raw_size)
            self.raw = _GitBlobReader(self.process.stdout, size, algorithm)
            self.buffer = io.BufferedReader(self.raw, 64 * 1024)
            self.stream = io.TextIOWrapper(
                self.buffer, encoding="utf-8", errors="strict", newline=None
            )
        except BaseException:
            self.close()
            raise

    def verify(self) -> None:
        if self.process is None or self.raw is None or self.stream is None:
            raise PolicyError("staged Git blob binding is closed")
        self.stream.read()
        if self.raw.remaining != 0:
            raise PolicyError("staged Git blob was not completely consumed")
        assert self.process.stdout is not None
        if self.process.stdout.read(1) != b"\n":
            raise PolicyError("staged Git blob framing changed")
        status = self.process.wait(timeout=WALL_SECONDS)
        diagnostic = b""
        if self.process.stderr is not None:
            diagnostic = self.process.stderr.read(MAX_GIT_DIAGNOSTIC_BYTES + 1)
        if status != 0:
            detail = diagnostic[:MAX_GIT_DIAGNOSTIC_BYTES].decode(
                "utf-8", "backslashreplace"
            ).strip()
            raise PolicyError(
                "Git could not read the staged blob"
                + (f": {detail}" if detail else "")
            )
        if self.raw.digest.hexdigest() != self.entry.object_id:
            raise PolicyError("staged Git blob digest changed while streaming")

    def close(self) -> None:
        stream, self.stream = self.stream, None
        if stream is not None:
            try:
                stream.close()
            except OSError:
                pass
        process, self.process = self.process, None
        if process is not None:
            if process.stdin is not None and not process.stdin.closed:
                process.stdin.close()
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if process.stdout is not None:
                process.stdout.close()
            if process.stderr is not None:
                process.stderr.close()


class StagedSnapshot:
    """A digest-bound Git index selection whose blobs are addressed by object ID."""

    _ENTRY = re.compile(
        rb"(?P<mode>[0-7]{6}) (?P<object>[0-9a-f]+) (?P<stage>[0-3])\t(?P<path>.+)",
        re.DOTALL,
    )

    def __init__(self, cwd: str) -> None:
        self.cwd = os.path.abspath(cwd)
        self.index: BoundFile | None = None
        self.index_snapshot: _IndexSnapshot | None = None
        self.index_digest = ""
        try:
            top = _run_git_capture(["rev-parse", "--show-toplevel"], self.cwd)
            if os.path.realpath(top.decode("utf-8", "strict").strip()) != os.path.realpath(
                self.cwd
            ):
                raise PolicyError("silent-failure hook must run at the worktree root")
            index_path = _run_git_capture(
                ["rev-parse", "--path-format=absolute", "--git-path", "index"],
                self.cwd,
            ).decode("utf-8", "strict").strip()
            git_directory = _run_git_capture(
                ["rev-parse", "--absolute-git-dir"], self.cwd
            ).decode("utf-8", "strict").strip()
            common_raw = _run_git_capture(
                ["rev-parse", "--git-common-dir"], self.cwd
            ).decode("utf-8", "strict").strip()
            git_common = os.path.realpath(
                common_raw
                if os.path.isabs(common_raw)
                else os.path.join(self.cwd, common_raw)
            )
            normalized_index = os.path.realpath(index_path)
            if not any(
                os.path.commonpath((normalized_index, root)) == root
                for root in (
                    os.path.realpath(git_directory),
                    git_common,
                )
            ):
                raise PolicyError("Git index is outside bound repository metadata")
            object_format = _run_git_capture(
                ["rev-parse", "--show-object-format"], self.cwd
            ).decode("ascii", "strict").strip()
            if object_format not in {"sha1", "sha256"}:
                raise PolicyError("Git repository uses an unsupported object format")
            self.algorithm = object_format
            self.index = BoundFile.open(index_path)
            self.index_digest = self.index.digest()
            self.index_snapshot = _IndexSnapshot.capture(
                self.index, self.index_digest
            )
            listing = _run_git_capture(
                ["ls-files", "--stage", "-z"],
                self.cwd,
                index_descriptor=self.index_snapshot.descriptor,
            )
            self.entries = self._parse_listing(listing)
            self.verify()
        except BaseException:
            self.close()
            raise

    def _parse_listing(self, listing: bytes) -> list[StagedEntry]:
        selected: dict[str, StagedEntry] = {}
        for record in listing.split(b"\0"):
            if not record:
                continue
            match = self._ENTRY.fullmatch(record)
            if match is None:
                raise PolicyError("Git index returned a malformed staged entry")
            try:
                path = match.group("path").decode("utf-8", "strict")
                object_id = match.group("object").decode("ascii", "strict")
            except UnicodeError as error:
                raise PolicyError("Git index contains a non-UTF-8 policy path") from error
            if not (
                _is_shell_source(path)
                or _is_workflow(path)
                or _is_static_command_source(path)
            ):
                continue
            if (
                match.group("stage") != b"0"
                or match.group("mode") not in {b"100644", b"100755"}
                or len(object_id) != hashlib.new(self.algorithm).digest_size * 2
            ):
                raise PolicyError(f"unsupported staged policy entry: {path}")
            if path in selected:
                raise PolicyError(f"duplicate staged policy entry: {path}")
            selected[path] = StagedEntry(path, object_id)
        return [selected[path] for path in sorted(selected)]

    def open_blob(self, entry: StagedEntry) -> StagedBlob:
        self.verify()
        return StagedBlob(entry, self.cwd, self.algorithm)

    def verify(self) -> None:
        if self.index is None:
            raise PolicyError("staged Git snapshot is closed")
        if self.index_snapshot is None:
            raise PolicyError("staged-index snapshot is closed")
        self.index.verify()
        self.index_snapshot.verify()
        if self.index.digest() != self.index_digest:
            raise PolicyError("Git index changed after staged selection")

    def close(self) -> None:
        snapshot, self.index_snapshot = self.index_snapshot, None
        if snapshot is not None:
            snapshot.close()
        index, self.index = self.index, None
        if index is not None:
            index.close()


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "")
    if not value or any(character in value for character in "\x00\r\n"):
        raise PolicyError(f"missing or invalid managed policy metadata: {name}")
    return value


def _expected_digest(name: str) -> str:
    value = _required_environment(name)
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise PolicyError(f"invalid managed policy digest: {name}")
    return value


def _same_file(left: str, right: str) -> bool:
    try:
        return os.path.samefile(left, right)
    except OSError:
        return False


def _verify_managed_runtime() -> list[BoundFile]:
    if os.environ.get("ODYSSEUS_MANAGED_PRE_COMMIT") != "1":
        raise PolicyError("silent-failure policy requires the managed hook runtime")
    if os.environ.get("ODYSSEUS_TRUSTED_POLICY_ROOT"):
        raise PolicyError("managed hooks cannot select an alternate policy root")

    provider_path = _required_environment("ODYSSEUS_PRE_COMMIT_PROVIDER")
    provider_digest = _expected_digest("ODYSSEUS_PRE_COMMIT_PROVIDER_SHA256")
    interpreter_path = _required_environment("ODYSSEUS_PRE_COMMIT_INTERPRETER")
    interpreter_digest = _expected_digest("ODYSSEUS_PRE_COMMIT_INTERPRETER_SHA256")
    git_path = _required_environment("ODYSSEUS_PRE_COMMIT_GIT")
    git_digest = _expected_digest("ODYSSEUS_PRE_COMMIT_GIT_SHA256")
    policy_digest = _expected_digest("ODYSSEUS_PRE_COMMIT_POLICY_SHA256")
    policy_hex = _required_environment("ODYSSEUS_PRE_COMMIT_POLICY_HEX")
    try:
        policy_bytes = bytes.fromhex(policy_hex)
    except ValueError as error:
        raise PolicyError("managed policy payload is not hexadecimal") from error
    if hashlib.sha256(policy_bytes).hexdigest() != policy_digest:
        raise PolicyError("managed policy payload provenance changed")
    if not all(
        os.path.isabs(path) for path in (provider_path, interpreter_path, git_path)
    ):
        raise PolicyError("managed policy providers must use absolute paths")
    if not sys.flags.isolated:
        raise PolicyError("silent-failure policy requires isolated Python")

    provider = BoundFile.open(provider_path, executable=True)
    interpreter = BoundFile.open(interpreter_path, executable=True)
    git = BoundFile.open(git_path, executable=True)
    script: BoundFile | None = None
    if os.path.abspath(__file__) != os.path.abspath("<odysseus-trusted-policy>"):
        script = BoundFile.open(
            os.path.join(os.getcwd(), "scripts", "check_silent_failures.py")
        )
    bindings = [provider, interpreter, git]
    if script is not None:
        bindings.append(script)
    try:
        if provider.digest() != provider_digest:
            raise PolicyError("pre-commit provider provenance changed")
        if interpreter.digest() != interpreter_digest:
            raise PolicyError("pre-commit interpreter provenance changed")
        if git.digest() != git_digest:
            raise PolicyError("Git provider provenance changed")
        if not _same_file(sys.executable, interpreter.path):
            raise PolicyError("the running interpreter is not the bound provider")
        if script is not None:
            if not _same_file(os.path.abspath(__file__), script.path):
                raise PolicyError("the running policy script is not the bound script")
            if script.digest() != policy_digest:
                raise PolicyError("the running policy script is not the trusted payload")
        elif __file__ != "<odysseus-trusted-policy>":
            raise PolicyError("the embedded policy filename is not trusted")
        return bindings
    except BaseException:
        for binding in bindings:
            binding.close()
        raise


def _verify_restricted_runtime() -> list[BoundFile]:
    if not sys.platform.startswith("linux"):
        raise PolicyError("restricted policy mode requires Linux containment")
    if os.getcwd() != RESTRICTED_WORK_ROOT:
        raise PolicyError("restricted policy mode requires the fixed candidate root")
    if (
        os.environ.get("ODYSSEUS_PRE_COMMIT_CONFIG") != "1"
        or os.environ.get("GIT_WORK_TREE") != RESTRICTED_WORK_ROOT
        or not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+",
            os.environ.get("ODYSSEUS_PRE_COMMIT_VERSION", ""),
        )
    ):
        raise PolicyError("restricted policy mode is not authenticated")
    try:
        filesystem = os.statvfs(RESTRICTED_POLICY_ROOT)
    except OSError as error:
        raise PolicyError("restricted policy mount is unavailable") from error
    if not filesystem.f_flag & getattr(os, "ST_RDONLY", 1):
        raise PolicyError("restricted policy mount is not read-only")
    if not sys.flags.isolated:
        raise PolicyError("restricted policy requires isolated Python")

    interpreter_route = "/usr/local/bin/python3"
    if not _same_file(sys.executable, interpreter_route):
        raise PolicyError("restricted policy used an unexpected interpreter")
    interpreter = BoundFile.open(os.path.realpath(interpreter_route), executable=True)
    provider = BoundFile.open("/usr/local/bin/pre-commit", executable=True)
    git_route = os.environ.get("ODYSSEUS_PRE_COMMIT_GIT", "/usr/bin/git")
    if git_route not in {"/usr/bin/git", "/usr/local/bin/git"}:
        raise PolicyError("restricted policy used an unexpected Git provider")
    git = BoundFile.open(os.path.realpath(git_route), executable=True)
    script = BoundFile.open(
        os.path.join(RESTRICTED_POLICY_ROOT, "scripts", "check_silent_failures.py")
    )
    bindings = [provider, interpreter, git, script]
    try:
        if not _same_file(os.path.abspath(__file__), script.path):
            raise PolicyError("restricted policy script route changed")
        for binding in bindings:
            binding.digest()
        return bindings
    except BaseException:
        for binding in bindings:
            binding.close()
        raise


def _bind_runtime() -> list[BoundFile]:
    policy_root = os.environ.get("ODYSSEUS_TRUSTED_POLICY_ROOT", "")
    if not policy_root:
        return _verify_managed_runtime()
    if policy_root == RESTRICTED_POLICY_ROOT:
        return _verify_restricted_runtime()
    raise PolicyError("untrusted policy root")


def _within(path: str, root: str) -> bool:
    try:
        return os.path.commonpath((os.path.realpath(path), os.path.realpath(root))) == (
            os.path.realpath(root)
        )
    except ValueError:
        return False


def _yaml_code_paths(package_root: str) -> list[str]:
    suffixes = (".py", *importlib.machinery.EXTENSION_SUFFIXES)
    paths: list[str] = []
    entries = 0
    total = 0
    pending = [package_root]
    while pending:
        current = pending.pop()
        try:
            iterator = os.scandir(current)
        except OSError as error:
            raise PolicyError(f"cannot inventory PyYAML closure: {error}") from error
        with iterator:
            for entry in iterator:
                entries += 1
                if entries > MAX_YAML_CLOSURE_FILES * 4:
                    raise PolicyError("PyYAML closure entry budget exceeded")
                try:
                    if entry.is_symlink():
                        raise PolicyError(
                            f"PyYAML closure contains a symbolic route: {entry.path}"
                        )
                    if entry.is_dir(follow_symlinks=False):
                        pending.append(entry.path)
                        continue
                    if not entry.is_file(follow_symlinks=False):
                        continue
                    path = os.path.abspath(entry.path)
                    if not path.endswith(suffixes):
                        continue
                    opened = entry.stat(follow_symlinks=False)
                except OSError as error:
                    raise PolicyError(
                        f"cannot bind PyYAML closure entry: {error}"
                    ) from error
                paths.append(path)
                total += opened.st_size
                if len(paths) > MAX_YAML_CLOSURE_FILES:
                    raise PolicyError("PyYAML closure file budget exceeded")
                if total > MAX_YAML_CLOSURE_BYTES:
                    raise PolicyError("PyYAML closure byte budget exceeded")
    return sorted(paths)


def _expected_yaml_manifest() -> dict[str, str] | None:
    raw = os.environ.get("ODYSSEUS_PYYAML_MANIFEST")
    if raw is None:
        return None
    if not raw or "\x00" in raw:
        raise PolicyError("managed PyYAML manifest is empty or malformed")
    result: dict[str, str] = {}
    for line in raw.splitlines():
        try:
            path, digest = line.rsplit("=", 1)
        except ValueError as error:
            raise PolicyError("managed PyYAML manifest is malformed") from error
        if (
            not os.path.isabs(path)
            or os.path.realpath(path) != path
            or not re.fullmatch(r"[0-9a-f]{64}", digest)
            or path in result
        ):
            raise PolicyError("managed PyYAML manifest is malformed")
        result[path] = digest
        if len(result) > MAX_YAML_CLOSURE_FILES:
            raise PolicyError("managed PyYAML manifest file budget exceeded")
    return result


def _root_immutable_route(path: str) -> bool:
    current = path
    while True:
        try:
            item = os.lstat(current)
        except OSError:
            return False
        if item.st_uid != 0 or stat.S_IMODE(item.st_mode) & 0o022:
            return False
        parent = os.path.dirname(current)
        if parent == current:
            return True
        current = parent


def _restricted_yaml_origin() -> str:
    """Locate PyYAML at a fixed prefix without enabling Python site startup."""

    version = "python{}.{}".format(sys.version_info.major, sys.version_info.minor)
    candidates: list[str] = []
    for prefix in dict.fromkeys((sys.prefix, sys.base_prefix)):
        for category in ("site-packages", "dist-packages"):
            candidate = os.path.realpath(
                os.path.join(prefix, "lib", version, category, "yaml", "__init__.py")
            )
            if not os.path.isfile(candidate) or not _root_immutable_route(candidate):
                continue
            if candidate not in candidates:
                candidates.append(candidate)
    if len(candidates) != 1:
        raise PolicyError(
            "restricted PyYAML dependency must have one immutable fixed origin"
        )
    return candidates[0]


def _yaml_module_name(package_root: str, path: str) -> tuple[str, bool] | None:
    relative = os.path.relpath(path, package_root)
    if relative == "__init__.py":
        return "yaml", True
    if not relative.endswith(".py"):
        return None
    parts = relative.split(os.sep)
    if parts[-1] == "__init__.py":
        return "yaml." + ".".join(parts[:-1]), True
    parts[-1] = parts[-1][:-3]
    return "yaml." + ".".join(parts), False


def _load_yaml() -> tuple[ModuleType, list[BoundFile], _SealedYamlFinder]:
    expected = _expected_yaml_manifest()
    if expected is not None:
        origins = [
            path for path in expected if os.path.basename(path) == "__init__.py"
            and os.path.basename(os.path.dirname(path)) == "yaml"
        ]
        if len(origins) != 1:
            raise PolicyError("managed PyYAML manifest has no unique package origin")
        package_origin = origins[0]
    elif os.environ.get("ODYSSEUS_TRUSTED_POLICY_ROOT") == RESTRICTED_POLICY_ROOT:
        package_origin = _restricted_yaml_origin()
    else:
        specification = importlib.util.find_spec("yaml")
        if specification is None or not specification.origin:
            raise PolicyError("the bound Python provider cannot locate PyYAML")
        package_origin = os.path.abspath(specification.origin)
    if expected is None and not _within(package_origin, sys.prefix):
        raise PolicyError("PyYAML is outside the bound interpreter environment")
    package_root = os.path.dirname(package_origin)
    paths = _yaml_code_paths(package_root)
    if package_origin not in paths:
        raise PolicyError("PyYAML package origin is outside its code closure")
    if expected is None:
        if os.environ.get("ODYSSEUS_TRUSTED_POLICY_ROOT") != RESTRICTED_POLICY_ROOT:
            raise PolicyError("managed PyYAML closure attestation is missing")
        if not all(_root_immutable_route(path) for path in paths):
            raise PolicyError("restricted PyYAML closure is not immutable")
    elif set(expected) != set(paths):
        raise PolicyError("PyYAML closure differs from its trusted manifest")

    bindings: list[BoundFile] = []
    finder: _SealedYamlFinder | None = None
    try:
        loaders: dict[str, _SealedYamlLoader] = {}
        for path in paths:
            binding = BoundFile.open(path)
            bindings.append(binding)
            if expected is not None and binding.digest() != expected[path]:
                raise PolicyError("PyYAML closure provenance changed before import")
            module = _yaml_module_name(package_root, path)
            if module is not None:
                name, package = module
                if name in loaders:
                    raise PolicyError("PyYAML closure has duplicate module routes")
                data = bytearray()
                offset = 0
                while offset < binding.token[6]:
                    chunk = os.pread(
                        binding.descriptor,
                        min(64 * 1024, binding.token[6] - offset),
                        offset,
                    )
                    if not chunk:
                        break
                    data.extend(chunk)
                    offset += len(chunk)
                if offset != binding.token[6]:
                    raise PolicyError("PyYAML source changed while snapshotting")
                loaders[name] = _SealedYamlLoader(path, bytes(data), package)
        if "yaml" not in loaders:
            raise PolicyError("PyYAML closure has no sealed package module")
        for binding in bindings:
            binding.verify()

        for name in tuple(sys.modules):
            if name == "yaml" or name.startswith("yaml."):
                raise PolicyError("PyYAML was imported before closure authentication")
        finder = _SealedYamlFinder(loaders)
        sys.meta_path.insert(0, finder)
        yaml = importlib.import_module("yaml")
        importlib.import_module("yaml.events")
        importlib.import_module("yaml.nodes")
        if getattr(yaml, "__version__", None) != EXPECTED_PYYAML_VERSION:
            raise PolicyError("the PyYAML version does not match the repository lock")

        for name, module in tuple(sys.modules.items()):
            if name != "yaml" and not name.startswith("yaml."):
                continue
            loader = getattr(getattr(module, "__spec__", None), "loader", None)
            if loader is not loaders.get(name):
                raise PolicyError("PyYAML loaded code outside its bound closure")
        for binding in bindings:
            binding.verify()
            if expected is not None and binding.digest() != expected[binding.path]:
                raise PolicyError("PyYAML closure changed while it was imported")
        return yaml, bindings, finder
    except BaseException:
        if finder is not None:
            finder.close()
        for name in tuple(sys.modules):
            if name == "yaml" or name.startswith("yaml."):
                sys.modules.pop(name, None)
        for binding in bindings:
            binding.close()
        raise


def _set_soft_limit(key: int, wanted: int, label: str) -> None:
    try:
        soft, hard = resource.getrlimit(key)
        candidates = [wanted]
        if soft != resource.RLIM_INFINITY:
            candidates.append(soft)
        if hard != resource.RLIM_INFINITY:
            candidates.append(hard)
        target = min(candidates)
        if target <= 0:
            raise PolicyError(f"{label} resource limit is unavailable")
        resource.setrlimit(key, (target, hard))
        actual, _ = resource.getrlimit(key)
    except (OSError, ValueError) as error:
        raise PolicyError(f"cannot establish {label} resource limit") from error
    if actual == resource.RLIM_INFINITY or actual > wanted:
        raise PolicyError(f"cannot verify {label} resource limit")


def _wall_timeout(_signum: int, _frame: object) -> None:
    raise TimeoutError("silent-failure policy exceeded its wall deadline")


def _establish_resource_limits() -> None:
    _set_soft_limit(resource.RLIMIT_CPU, CPU_SECONDS, "CPU")
    _set_soft_limit(resource.RLIMIT_NOFILE, FILE_DESCRIPTORS, "file-descriptor")
    if not hasattr(resource, "RLIMIT_NPROC"):
        raise PolicyError("process-count containment is unavailable")
    _set_soft_limit(resource.RLIMIT_NPROC, PROCESSES, "process-count")
    if sys.platform.startswith("linux"):
        if not hasattr(resource, "RLIMIT_AS"):
            raise PolicyError("Linux memory containment is unavailable")
        _set_soft_limit(resource.RLIMIT_AS, ADDRESS_SPACE_BYTES, "address-space")
    if not hasattr(signal, "SIGALRM"):
        raise PolicyError("wall-clock containment is unavailable")
    signal.signal(signal.SIGALRM, _wall_timeout)
    signal.alarm(WALL_SECONDS)


def _is_workflow(path: str) -> bool:
    parts = PurePosixPath(path.replace("\\", "/")).parts
    return (
        len(parts) >= 3
        and parts[-3:-1] == (".github", "workflows")
        and PurePosixPath(parts[-1]).suffix in {".yaml", ".yml"}
    )


def _is_shell_source(path: str) -> bool:
    pure_path = PurePosixPath(path.replace("\\", "/"))
    return pure_path.suffix in SHELL_SUFFIXES


def _is_static_command_source(path: str) -> bool:
    pure_path = PurePosixPath(path.replace("\\", "/"))
    name = pure_path.name
    return (
        pure_path.suffix == ".hcl"
        or name.lower() == "justfile"
        or name.startswith("Dockerfile")
    )


@dataclass(frozen=True)
class _ShellToken:
    value: str
    line: int
    quoted: bool = False


class _ShellLexer:
    """A bounded, stateful lexer for executable shell command contexts.

    The policy does not need a shell AST, but it does need shell lexical state:
    quotes can cross physical lines, command substitutions execute inside double
    quotes, and only unquoted heredocs expand substitutions.  Keeping that state
    here avoids both shlex's line-at-a-time false positives and flat-token false
    negatives.
    """

    _OPERATORS = (
        ";;&",
        "<<<",
        "<<-",
        "&&",
        "||",
        ";;",
        ";&",
        "|&",
        ">>",
        "<<",
        "<&",
        ">&",
        "<>",
    )
    _SINGLE_OPERATORS = "|&;()<>{}"

    def __init__(self, source: str, first_line: int = 1) -> None:
        self.source = source
        self.index = 0
        self.line = first_line
        self.contexts: list[list[_ShellToken]] = []
        self.pending_heredocs: list[tuple[str, bool, bool]] = []

    def _advance(self, count: int = 1) -> str:
        value = self.source[self.index : self.index + count]
        self.index += count
        self.line += value.count("\n")
        return value

    def _at(self, value: str) -> bool:
        return self.source.startswith(value, self.index)

    def _add_substitution(self, source: str, first_line: int) -> None:
        nested = _ShellLexer(source, first_line)
        tokens = nested.lex()
        self.contexts.append(tokens)
        self.contexts.extend(nested.contexts)

    def _consume_single_quote(self, word: list[str]) -> None:
        self._advance()
        while self.index < len(self.source) and not self._at("'"):
            word.append(self._advance())
        if self.index >= len(self.source):
            raise PolicyError("invalid shell syntax: no closing single quote")
        self._advance()

    def _consume_backtick(self, word: list[str]) -> None:
        self._advance()
        first_line = self.line
        body: list[str] = []
        while self.index < len(self.source):
            if self._at("\\"):
                body.append(self._advance())
                if self.index < len(self.source):
                    body.append(self._advance())
                continue
            if self._at("`"):
                self._advance()
                self._add_substitution("".join(body), first_line)
                word.append("__command_substitution__")
                return
            body.append(self._advance())
        raise PolicyError("invalid shell syntax: no closing backtick")

    def _consume_command_substitution(self, word: list[str]) -> None:
        self._advance(2)
        first_line = self.line
        body_start = self.index
        context_boundary = len(self.contexts)
        group_depth = 0
        quote = ""
        word_start = True
        pending_heredocs: list[tuple[str, bool]] = []
        while self.index < len(self.source):
            if quote == "'":
                if self._at("'"):
                    quote = ""
                self._advance()
                continue
            if quote == '"':
                if self._at("\\"):
                    self._advance()
                    if self.index < len(self.source):
                        self._advance()
                    continue
                if self._at('"'):
                    quote = ""
                    self._advance()
                    continue
                if self._at("$(("):
                    self._consume_arithmetic([])
                    continue
                if self._at("$("):
                    self._consume_command_substitution([])
                    continue
                if self._at("`"):
                    self._consume_backtick([])
                    continue
                self._advance()
                continue
            if self._at("\\"):
                self._advance()
                if self.index < len(self.source):
                    escaped = self._advance()
                    if escaped != "\n":
                        word_start = False
                continue
            if self._at("'") or self._at('"'):
                quote = self._advance()
                word_start = False
                continue
            if self._at("$(("):
                self._consume_arithmetic([])
                word_start = False
                continue
            if self._at("$("):
                self._consume_command_substitution([])
                word_start = False
                continue
            if self._at("`"):
                self._consume_backtick([])
                word_start = False
                continue
            if self._at("#") and word_start:
                newline = self.source.find("\n", self.index)
                if newline < 0:
                    self._advance(len(self.source) - self.index)
                else:
                    self._advance(newline - self.index + 1)
                    word_start = True
                continue
            if self._at("<<") and not self._at("<<<"):
                strip_tabs = self._at("<<-")
                self._advance(3 if strip_tabs else 2)
                while self.index < len(self.source) and self.source[self.index] in " \t\r":
                    self._advance()
                delimiter, _quoted = self._consume_heredoc_word()
                pending_heredocs.append((delimiter, strip_tabs))
                word_start = False
                continue
            if self._at("\n"):
                self._advance()
                word_start = True
                for delimiter, strip_tabs in pending_heredocs:
                    while self.index < len(self.source):
                        newline = self.source.find("\n", self.index)
                        end = len(self.source) if newline < 0 else newline
                        following = end if newline < 0 else newline + 1
                        raw_line = self.source[self.index : end].rstrip("\r")
                        comparison = raw_line.lstrip("\t") if strip_tabs else raw_line
                        self._advance(following - self.index)
                        if comparison == delimiter:
                            break
                    else:
                        raise PolicyError("unterminated shell heredoc")
                pending_heredocs.clear()
                continue
            if self._at("("):
                group_depth += 1
                self._advance()
                word_start = True
                continue
            if self._at(")"):
                if group_depth:
                    group_depth -= 1
                    self._advance()
                    word_start = False
                    continue
                body = self.source[body_start : self.index]
                self._advance()
                # The boundary walk may have traversed nested substitutions.
                # Lexing the captured body below discovers them exactly once.
                del self.contexts[context_boundary:]
                self._add_substitution(body, first_line)
                word.append("__command_substitution__")
                return
            character = self._advance()
            word_start = character.isspace() or character in "|&;<>{}"
        raise PolicyError("invalid shell syntax: unterminated command substitution")

    def _consume_arithmetic(self, word: list[str], command: bool = False) -> None:
        opening = 2 if command else 3
        self._advance(opening)
        depth = 0
        while self.index < len(self.source):
            if self._at("\\"):
                self._advance()
                if self.index < len(self.source):
                    self._advance()
                continue
            if self._at("$(") and not self._at("$(("):
                self._consume_command_substitution([])
                continue
            if self._at("`"):
                self._consume_backtick([])
                continue
            if self._at("("):
                depth += 1
                self._advance()
                continue
            if self._at("))") and depth == 0:
                self._advance(2)
                word.append("__arithmetic__")
                return
            if self._at(")") and depth:
                depth -= 1
            self._advance()
        raise PolicyError("invalid shell syntax: unterminated arithmetic expression")

    def _consume_double_quote(self, word: list[str]) -> None:
        self._advance()
        while self.index < len(self.source):
            if self._at("\\"):
                self._advance()
                if self.index < len(self.source):
                    word.append(self._advance())
                continue
            if self._at('"'):
                self._advance()
                return
            if self._at("$(("):
                self._consume_arithmetic(word)
                continue
            if self._at("$("):
                self._consume_command_substitution(word)
                continue
            if self._at("`"):
                self._consume_backtick(word)
                continue
            word.append(self._advance())
        raise PolicyError("invalid shell syntax: no closing double quote")

    def _consume_word(self) -> _ShellToken:
        line = self.line
        word: list[str] = []
        consumed = False
        quoted = False
        while self.index < len(self.source):
            character = self.source[self.index]
            if character.isspace() or character in self._SINGLE_OPERATORS:
                break
            if any(self._at(operator) for operator in self._OPERATORS):
                break
            if self._at("\\"):
                consumed = True
                self._advance()
                if self.index >= len(self.source):
                    raise PolicyError("invalid shell syntax: trailing escape")
                if self._at("\n"):
                    self._advance()
                else:
                    quoted = True
                    word.append(self._advance())
                continue
            if self._at("'"):
                consumed = True
                quoted = True
                self._consume_single_quote(word)
                continue
            if self._at('"'):
                consumed = True
                quoted = True
                self._consume_double_quote(word)
                continue
            if self._at("$(("):
                consumed = True
                self._consume_arithmetic(word)
                continue
            if self._at("$("):
                consumed = True
                self._consume_command_substitution(word)
                continue
            if self._at("`"):
                consumed = True
                self._consume_backtick(word)
                continue
            consumed = True
            word.append(self._advance())
        if not consumed:
            raise PolicyError("invalid shell syntax: shell word made no progress")
        return _ShellToken("".join(word), line, quoted=quoted)

    def _consume_heredoc_word(self) -> tuple[str, bool]:
        word: list[str] = []
        quoted = False
        while self.index < len(self.source):
            character = self.source[self.index]
            if character.isspace() or character in self._SINGLE_OPERATORS:
                break
            if self._at("\\"):
                quoted = True
                self._advance()
                if self.index >= len(self.source):
                    raise PolicyError("invalid shell syntax: trailing heredoc escape")
                word.append(self._advance())
                continue
            if self._at("'"):
                quoted = True
                self._consume_single_quote(word)
                continue
            if self._at('"'):
                quoted = True
                self._advance()
                while self.index < len(self.source) and not self._at('"'):
                    if self._at("\\"):
                        self._advance()
                        if self.index >= len(self.source):
                            raise PolicyError(
                                "invalid shell syntax: trailing heredoc escape"
                            )
                    word.append(self._advance())
                if self.index >= len(self.source):
                    raise PolicyError(
                        "invalid shell syntax: no closing heredoc delimiter quote"
                    )
                self._advance()
                continue
            word.append(self._advance())
        if not word:
            raise PolicyError("shell heredoc has no delimiter")
        return "".join(word), quoted

    def _consume_heredoc_bodies(self) -> None:
        for delimiter, strip_tabs, quoted in self.pending_heredocs:
            body_start = self.index
            body_line = self.line
            chunks: list[str] = []
            while self.index < len(self.source):
                newline = self.source.find("\n", self.index)
                if newline < 0:
                    end = len(self.source)
                    following = end
                else:
                    end = newline
                    following = newline + 1
                raw_line = self.source[self.index : end]
                comparison = raw_line.rstrip("\r")
                if strip_tabs:
                    comparison = comparison.lstrip("\t")
                if comparison == delimiter:
                    self._advance(following - self.index)
                    break
                chunks.append(self.source[self.index : following])
                self._advance(following - self.index)
            else:
                raise PolicyError("unterminated shell heredoc")
            if not quoted:
                expansion_source = "".join(chunks)
                expansion_lexer = _ShellExpansionLexer(expansion_source, body_line)
                expansion_lexer.scan()
                self.contexts.extend(expansion_lexer.contexts)
            if self.index == body_start:
                raise PolicyError("unterminated shell heredoc")
        self.pending_heredocs.clear()

    def lex(self) -> list[_ShellToken]:
        tokens: list[_ShellToken] = []
        expect_heredoc: bool | None = None
        while self.index < len(self.source):
            if expect_heredoc is not None:
                if self.source[self.index] in " \t\r":
                    self._advance()
                    continue
                if self._at("\n"):
                    raise PolicyError("shell heredoc has no delimiter")
                delimiter, quoted = self._consume_heredoc_word()
                self.pending_heredocs.append((delimiter, expect_heredoc, quoted))
                tokens.append(_ShellToken(delimiter, self.line, quoted=True))
                expect_heredoc = None
                continue

            character = self.source[self.index]
            if character in " \t\r":
                self._advance()
                continue
            if self._at("\\\n"):
                self._advance(2)
                continue
            if self._at("\n"):
                tokens.append(_ShellToken("\n", self.line))
                self._advance()
                if self.pending_heredocs:
                    self._consume_heredoc_bodies()
                continue
            if self._at("#"):
                newline = self.source.find("\n", self.index)
                self._advance(
                    len(self.source) - self.index if newline < 0 else newline - self.index
                )
                continue
            if self._at("(("):
                line = self.line
                word: list[str] = []
                self._consume_arithmetic(word, command=True)
                tokens.append(_ShellToken("".join(word), line))
                continue
            if self._at("<<<"):
                tokens.append(_ShellToken("<<<", self.line))
                self._advance(3)
                continue
            if self._at("<<-"):
                tokens.append(_ShellToken("<<", self.line))
                self._advance(3)
                expect_heredoc = True
                continue
            if self._at("<<"):
                tokens.append(_ShellToken("<<", self.line))
                self._advance(2)
                expect_heredoc = False
                continue
            operator = next(
                (value for value in self._OPERATORS if self._at(value)), None
            )
            if operator is not None:
                tokens.append(_ShellToken(operator, self.line))
                self._advance(len(operator))
                continue
            if character in self._SINGLE_OPERATORS:
                tokens.append(_ShellToken(character, self.line))
                self._advance()
                continue
            tokens.append(self._consume_word())
        if expect_heredoc is not None:
            raise PolicyError("shell heredoc has no delimiter")
        if self.pending_heredocs:
            raise PolicyError("unterminated shell heredoc")
        return tokens


class _ShellExpansionLexer:
    """Find only command substitutions executed by an unquoted heredoc."""

    def __init__(self, source: str, first_line: int) -> None:
        self.lexer = _ShellLexer(source, first_line)
        self.contexts: list[list[_ShellToken]] = []

    def scan(self) -> None:
        word: list[str] = []
        while self.lexer.index < len(self.lexer.source):
            if self.lexer._at("\\"):
                self.lexer._advance()
                if self.lexer.index < len(self.lexer.source):
                    self.lexer._advance()
                continue
            if self.lexer._at("$(") and not self.lexer._at("$(("):
                self.lexer._consume_command_substitution(word)
                continue
            if self.lexer._at("`"):
                self.lexer._consume_backtick(word)
                continue
            self.lexer._advance()
        self.contexts.extend(self.lexer.contexts)


def _shell_token_contexts(stream: TextIO) -> list[list[_ShellToken]]:
    source = stream.read(MAX_SHELL_SOURCE_BYTES + 1)
    if len(source.encode("utf-8")) > MAX_SHELL_SOURCE_BYTES:
        raise PolicyError("shell source exceeds the policy byte budget")
    lexer = _ShellLexer(source)
    tokens = lexer.lex()
    return [tokens, *lexer.contexts]


def _is_redirection(token: str) -> bool:
    return bool(token) and all(character in "<>&" for character in token)


def _trim_group(tokens: list[_ShellToken], start: int) -> tuple[list[_ShellToken], int]:
    opener = tokens[start].value
    closer = ")" if opener == "(" else "}"
    stack = [closer]
    case_levels: list[int] = []
    index = start + 1
    while index < len(tokens):
        value = tokens[index].value
        if value == "case":
            case_levels.append(len(stack))
        elif value == "esac" and case_levels:
            case_levels.pop()
        elif value in {"(", "{"}:
            stack.append(")" if value == "(" else "}")
        elif value == stack[-1]:
            if value == ")" and case_levels and case_levels[-1] == len(stack):
                index += 1
                continue
            stack.pop()
            if not stack:
                return tokens[start + 1 : index], index + 1
        index += 1
    raise PolicyError("invalid shell syntax: unterminated command group")


def _final_sequence_command(tokens: list[_ShellToken]) -> list[_ShellToken]:
    end = len(tokens)
    while end and tokens[end - 1].value in {";", "\n"}:
        end -= 1
    tokens = tokens[:end]
    stack: list[str] = []
    boundary = 0
    for index, token in enumerate(tokens):
        if token.value in {"(", "{"}:
            stack.append(")" if token.value == "(" else "}")
        elif stack and token.value == stack[-1]:
            stack.pop()
        elif not stack and token.value in {";", "\n"}:
            boundary = index + 1
    final = tokens[boundary:]
    stack.clear()
    for token in final:
        if token.value in {"(", "{"}:
            stack.append(")" if token.value == "(" else "}")
        elif stack and token.value == stack[-1]:
            stack.pop()
        elif not stack and token.value in {"&&", "||", "|", "&"}:
            return []
    return final


def _noop_command(
    tokens: list[_ShellToken], start: int
) -> tuple[bool, bool, bool, bool, int, int]:
    """Return match and diagnostic details for one right-hand command."""

    while start < len(tokens) and tokens[start].value == "\n":
        start += 1
    if start >= len(tokens):
        return False, False, False, False, start, 0
    if tokens[start].value in {"(", "{"}:
        group, end = _trim_group(tokens, start)
        final = _final_sequence_command(group)
        if not final:
            return False, False, False, False, end, tokens[start].line
        matched, redirected, prefixed, colon_args, _unused, line = _noop_command(
            final, 0
        )
        return matched, redirected, prefixed, colon_args, end, line

    redirected = False
    prefixed = False
    index = start
    assignments_allowed = True
    while index < len(tokens):
        value = tokens[index].value
        if value == "command" and not prefixed:
            prefixed = True
            assignments_allowed = False
            index += 1
            continue
        if assignments_allowed and re.fullmatch(
            r"[A-Za-z_][A-Za-z0-9_]*=.*", value, re.DOTALL
        ):
            index += 1
            continue
        if value.isdigit() and index + 1 < len(tokens) and _is_redirection(
            tokens[index + 1].value
        ):
            redirected = True
            index += 3
            continue
        if _is_redirection(value):
            redirected = True
            index += 2
            continue
        break
    if index >= len(tokens):
        return False, redirected, prefixed, False, index, 0
    command = tokens[index]
    index += 1
    matched = command.value in {"true", ":"}
    if command.value == "exit" and index < len(tokens) and tokens[index].value == "0":
        matched = True
        index += 1
    if not matched:
        return False, redirected, prefixed, False, index, command.line

    has_arguments = False
    while index < len(tokens):
        value = tokens[index].value
        if value in {";", "\n", "|", "&", "&&", "||", ")", "}"}:
            break
        if value.isdigit() and index + 1 < len(tokens) and _is_redirection(
            tokens[index + 1].value
        ):
            redirected = True
            index += 3
            continue
        if _is_redirection(value):
            redirected = True
            index += 2
            continue
        has_arguments = True
        index += 1
    if command.value == "exit" and has_arguments:
        matched = False
    return (
        matched,
        redirected,
        prefixed,
        command.value == ":" and has_arguments,
        index,
        command.line,
    )


def _emits_warning_annotation(tokens: list[_ShellToken], index: int) -> bool:
    """Return whether a literal annotation is an argument to an output command."""

    boundaries = {";", "\n", "&&", "||", "|", "&", "(", "{", ")", "}"}
    for prior in reversed(tokens[:index]):
        if prior.value in boundaries:
            break
        if prior.value.rsplit("/", 1)[-1] in {"echo", "printf"}:
            return True
    return False


def _shell_findings(stream: TextIO) -> Iterator[tuple[int, str]]:
    """Inspect every executable shell context with continuous lexical state."""

    for tokens in _shell_token_contexts(stream):
        for index, token in enumerate(tokens):
            if token.value.startswith("::warning::") and _emits_warning_annotation(
                tokens, index
            ):
                yield token.line, "forbidden advisory warning annotation"
        conditional_depth = 0
        command_start = True
        time_option = False
        for index, token in enumerate(tokens):
            if time_option and not token.quoted and token.value == "-p":
                time_option = False
                continue
            time_option = command_start and not token.quoted and token.value == "time"
            if token.value == "[[" and not token.quoted and command_start:
                conditional_depth += 1
                command_start = False
                continue
            if token.value == "]]" and not token.quoted and conditional_depth:
                conditional_depth -= 1
                continue
            # Inside [[ ... ]], || joins conditional expressions; its right-hand
            # side is not a command and parentheses are conditional grouping.
            if conditional_depth:
                continue
            if not token.quoted and token.value in {
                ";", "\n", "&&", "||", "|", "&", "(", "{", ")", "}",
            }:
                command_start = True
            elif not (
                command_start and not token.quoted and token.value in {
                    "if", "then", "elif", "else", "while", "until", "do", "!", "time",
                }
            ):
                command_start = False
            if token.value != "||" or token.quoted:
                continue
            (
                matched,
                redirected,
                prefixed,
                colon_arguments,
                _end,
                command_line,
            ) = _noop_command(tokens, index + 1)
            if not matched:
                continue
            if command_line > token.line:
                message = "forbidden silent-failure workaround: newline-split true no-op"
            elif colon_arguments:
                message = (
                    "forbidden silent-failure workaround: colon no-op with arguments"
                )
            elif redirected or prefixed:
                message = "forbidden silent-failure workaround: redirected true no-op"
            else:
                message = "forbidden silent-failure workaround"
            yield token.line, message


def _mapping_values(
    yaml: ModuleType, node: object, name: str
) -> Iterator[tuple[object, object]]:
    if not isinstance(node, yaml.nodes.MappingNode):
        return
    for key_node, value_node in node.value:
        if isinstance(key_node, yaml.nodes.ScalarNode) and key_node.value == name:
            yield key_node, value_node


def _validate_mapping_keys(yaml: ModuleType, document: object) -> None:
    stack = [document]
    visited: set[int] = set()
    while stack:
        node = stack.pop()
        if id(node) in visited:
            continue
        visited.add(id(node))
        if isinstance(node, yaml.nodes.MappingNode):
            keys: set[str] = set()
            for key, value in node.value:
                if isinstance(key, yaml.nodes.ScalarNode):
                    if key.value in keys:
                        raise PolicyError(
                            f"duplicate workflow key at line {key.start_mark.line + 1}"
                        )
                    keys.add(key.value)
                stack.extend((key, value))
        elif isinstance(node, yaml.nodes.SequenceNode):
            stack.extend(node.value)


def _provably_false(yaml: ModuleType, node: object) -> bool:
    return (
        isinstance(node, yaml.nodes.ScalarNode)
        and node.style is None
        and node.tag == "tag:yaml.org,2002:bool"
        and node.value == "false"
        and getattr(node, "_policy_implicit", (False, False))[0]
        and not getattr(node, "_policy_alias_used", False)
    )


def _workflow_findings(yaml: ModuleType, document: object) -> Iterator[tuple[int, str]]:
    for _jobs_key, jobs_node in _mapping_values(yaml, document, "jobs"):
        if not isinstance(jobs_node, yaml.nodes.MappingNode):
            continue
        for _job_key, job_node in jobs_node.value:
            if not isinstance(job_node, yaml.nodes.MappingNode):
                continue
            for key, value in _mapping_values(yaml, job_node, "continue-on-error"):
                if not _provably_false(yaml, value):
                    yield (
                        key.start_mark.line + 1,
                        "forbidden continue-on-error true/value: "
                        "continue-on-error must be the literal false",
                    )
            for _steps_key, steps_node in _mapping_values(yaml, job_node, "steps"):
                if not isinstance(steps_node, yaml.nodes.SequenceNode):
                    continue
                for step_node in steps_node.value:
                    if not isinstance(step_node, yaml.nodes.MappingNode):
                        continue
                    for key, value in _mapping_values(
                        yaml, step_node, "continue-on-error"
                    ):
                        if not _provably_false(yaml, value):
                            yield (
                                key.start_mark.line + 1,
                                "forbidden continue-on-error true/value: "
                                "continue-on-error must be the literal false",
                            )
                    shell_values = list(_mapping_values(yaml, step_node, "shell"))
                    shell_enabled = True
                    if shell_values:
                        _shell_key, shell_node = shell_values[0]
                        if not isinstance(shell_node, yaml.nodes.ScalarNode):
                            raise PolicyError("workflow shell must be one scalar value")
                        selector = " ".join(shell_node.value.strip().split())
                        non_shell_selectors = {
                            "node {0}",
                            "perl {0}",
                            "python {0}",
                            "python2 {0}",
                            "python3 {0}",
                            "ruby {0}",
                        }
                        shell_enabled = selector not in non_shell_selectors
                    for run_key, run_node in _mapping_values(yaml, step_node, "run"):
                        if not isinstance(run_node, yaml.nodes.ScalarNode):
                            raise PolicyError(
                                "workflow run command must be one scalar value"
                        )
                        line = run_key.start_mark.line + 1
                        if shell_enabled:
                            for _relative_line, message in _shell_findings(
                                io.StringIO(run_node.value)
                            ):
                                if "warning annotation" in message:
                                    yield (
                                        line,
                                        "forbidden advisory warning annotation in "
                                        "workflow run command",
                                    )
                                else:
                                    yield (
                                        line,
                                        "forbidden silent-failure workaround in "
                                        "workflow run command",
                                    )


def _bounded_loader(yaml: ModuleType) -> type:
    class BoundedLoader(yaml.SafeLoader):
        def __init__(self, stream: TextIO) -> None:
            super().__init__(stream)
            self._policy_nodes = 0
            self._policy_depth = 0
            self._policy_aliases = 0

        def compose_node(self, parent: object, index: object) -> object:
            self._policy_nodes += 1
            if self._policy_nodes > MAX_YAML_NODES:
                raise yaml.YAMLError("workflow YAML node budget exceeded")
            event = self.peek_event()
            if isinstance(event, yaml.events.AliasEvent):
                self._policy_aliases += 1
                if self._policy_aliases > MAX_YAML_ALIASES:
                    raise yaml.YAMLError("workflow YAML alias budget exceeded")
            self._policy_depth += 1
            if self._policy_depth > MAX_YAML_DEPTH:
                raise yaml.YAMLError("workflow YAML depth budget exceeded")
            try:
                node = super().compose_node(parent, index)
                if isinstance(event, yaml.events.ScalarEvent):
                    node._policy_implicit = event.implicit
                elif isinstance(event, yaml.events.AliasEvent):
                    node._policy_alias_used = True
                return node
            finally:
                self._policy_depth -= 1

    return BoundedLoader


def _check_shell_source(path: Path, stream: TextIO, reporter: Reporter) -> int:
    failures = 0
    for line_number, message in _shell_findings(stream):
        reporter.emit(f"{path}:{line_number}: {message}")
        failures += 1
    return failures


def _docker_shell_contexts(source: str) -> Iterator[tuple[int, str]]:
    """Yield shell-form RUN instructions, preserving physical line numbers."""

    current: list[str] = []
    start_line = 1
    escape = "\\"
    directives = True
    for line_number, line in enumerate(source.splitlines(keepends=True), 1):
        if directives:
            directive = re.fullmatch(r"\s*#\s*escape\s*=\s*([\\`])\s*", line)
            if directive:
                escape = directive.group(1)
                continue
            if not re.match(r"\s*#\s*(?:syntax|check)\s*=", line):
                directives = False
        if line.lstrip().startswith("#"):
            # Docker comments do not continue, even when they end in escape.
            # Preserve physical diagnostic lines within a continued instruction.
            if current:
                current.append("\n")
            continue
        if not current:
            start_line = line_number
        content = line.rstrip("\r\n")
        trailing = len(content) - len(content.rstrip(escape))
        if trailing % 2:
            # Docker removes its escape before the shell sees the command.
            # A shell continuation preserves the physical diagnostic line.
            current.append(content[:-1] + "\\\n")
            continue
        current.append(line)
        instruction = "".join(current)
        current.clear()
        match = re.match(r"\s*([A-Za-z]+)\s+(.*)\Z", instruction, re.DOTALL)
        if match is None or match.group(1).lower() != "run":
            continue
        command = match.group(2)
        if command.lstrip().startswith("["):
            try:
                arguments = json.loads(command)
            except ValueError:
                arguments = None
            if isinstance(arguments, list) and all(isinstance(item, str) for item in arguments):
                continue
        yield start_line, command
    if current:
        raise PolicyError("unterminated Dockerfile continuation")


def _just_shell_contexts(source: str) -> Iterator[tuple[int, str]]:
    """Yield recipe bodies and exclude assignments, comments, and attributes."""

    header = re.compile(
        r"^(?:\[[^]\r\n]+\]\s*)*[A-Za-z_][A-Za-z0-9_-]*"
        r"(?:\s+[^:\r\n]+)*:(?!=)[^\r\n]*$"
    )
    body: list[str] = []
    body_line = 1
    in_recipe = False

    def emit() -> tuple[int, str] | None:
        if not body:
            return None
        return body_line, "".join(body)

    for line_number, line in enumerate(source.splitlines(keepends=True), 1):
        if line[:1] in {" ", "\t"} and in_recipe:
            command = line.lstrip(" \t")
            if command.startswith("@"):
                command = command[1:]
            if not body:
                body_line = line_number
            body.append(command)
            continue
        if not line.strip() and in_recipe:
            if body:
                body.append("\n")
            continue
        result = emit()
        if result is not None:
            yield result
        body.clear()
        in_recipe = bool(header.fullmatch(line.rstrip("\r\n")))
    result = emit()
    if result is not None:
        yield result


@dataclass(frozen=True)
class _HclToken:
    kind: str
    value: str
    line: int


def _hcl_tokens(source: str) -> list[_HclToken]:
    """Tokenize enough HCL to bind literal `args = ["-c", ...]` commands."""

    tokens: list[_HclToken] = []
    index = 0
    line = 1
    while index < len(source):
        character = source[index]
        if character.isspace():
            line += character == "\n"
            index += 1
            continue
        if source.startswith("//", index) or character == "#":
            newline = source.find("\n", index)
            index = len(source) if newline < 0 else newline
            continue
        if source.startswith("/*", index):
            end = source.find("*/", index + 2)
            if end < 0:
                raise PolicyError("unterminated HCL block comment")
            chunk = source[index : end + 2]
            line += chunk.count("\n")
            index = end + 2
            continue
        if character == '"':
            start = index
            start_line = line
            index += 1
            escaped = False
            while index < len(source):
                value = source[index]
                if not escaped and value == '"':
                    index += 1
                    break
                if not escaped and value == "\\":
                    escaped = True
                else:
                    escaped = False
                line += value == "\n"
                index += 1
            else:
                raise PolicyError("unterminated HCL string")
            raw = source[start:index]
            try:
                decoded = json.loads(raw)
            except (TypeError, ValueError) as error:
                raise PolicyError("unsupported HCL string escape") from error
            tokens.append(_HclToken("string", decoded, start_line))
            continue
        heredoc = re.match(r"<<(-?)([^\W\d][\w-]*)[ \t]*\r?\n", source[index:])
        if heredoc is not None:
            start_line = line
            strip_tabs = bool(heredoc.group(1))
            delimiter = heredoc.group(2)
            index += heredoc.end()
            line += 1
            chunks: list[str] = []
            while index < len(source):
                newline = source.find("\n", index)
                end = len(source) if newline < 0 else newline
                following = end if newline < 0 else newline + 1
                raw_line = source[index:end].rstrip("\r")
                comparison = raw_line.lstrip(" \t") if strip_tabs else raw_line
                chunk = source[index:following]
                index = following
                line += 1
                if comparison == delimiter:
                    break
                chunks.append(chunk)
            else:
                raise PolicyError("unterminated HCL heredoc")
            tokens.append(_HclToken("string", "".join(chunks), start_line))
            continue
        if source.startswith("<<", index):
            raise PolicyError("unsupported HCL heredoc delimiter")
        identifier = re.match(r"[A-Za-z_][A-Za-z0-9_-]*", source[index:])
        if identifier is not None:
            tokens.append(_HclToken("identifier", identifier.group(0), line))
            index += identifier.end()
            continue
        if character in "=[]{}(),":
            tokens.append(_HclToken("symbol", character, line))
        index += 1
    return tokens


def _hcl_shell_contexts(source: str) -> Iterator[tuple[int, str]]:
    tokens = _hcl_tokens(source)
    index = 0
    while index + 2 < len(tokens):
        if not (
            tokens[index].kind == "identifier"
            and tokens[index].value == "args"
            and tokens[index + 1].value == "="
            and tokens[index + 2].value == "["
        ):
            index += 1
            continue
        end = index + 3
        values: list[_HclToken] = []
        while end < len(tokens) and tokens[end].value != "]":
            if tokens[end].kind == "string":
                values.append(tokens[end])
            end += 1
        if end >= len(tokens):
            raise PolicyError("unterminated HCL args list")
        for value_index, value in enumerate(values[:-1]):
            if value.value == "-c":
                command = values[value_index + 1]
                yield command.line, command.value
        index = end + 1


def _static_shell_contexts(path: Path, source: str) -> Iterator[tuple[int, str]]:
    name = path.name
    if name.startswith("Dockerfile"):
        yield from _docker_shell_contexts(source)
    elif name.lower() == "justfile":
        yield from _just_shell_contexts(source)
    elif path.suffix == ".hcl":
        yield from _hcl_shell_contexts(source)


def _check_static_source(path: Path, stream: TextIO, reporter: Reporter) -> int:
    source = stream.read(MAX_SHELL_SOURCE_BYTES + 1)
    if len(source.encode("utf-8")) > MAX_SHELL_SOURCE_BYTES:
        raise PolicyError("static command source exceeds the policy byte budget")
    failures = 0
    for first_line, command in _static_shell_contexts(path, source):
        for relative_line, _message in _shell_findings(io.StringIO(command)):
            line_number = first_line + relative_line - 1
            reporter.emit(
                f"{path}:{line_number}: forbidden silent-failure workaround"
            )
            failures += 1
    return failures


def _check_workflow(
    yaml: ModuleType, path: Path, stream: TextIO, reporter: Reporter
) -> int:
    loader = _bounded_loader(yaml)(stream)
    failures = 0
    documents = 0
    try:
        while loader.check_node():
            documents += 1
            if documents > MAX_YAML_DOCUMENTS:
                raise yaml.YAMLError("workflow YAML document budget exceeded")
            document = loader.get_node()
            _validate_mapping_keys(yaml, document)
            for line, message in _workflow_findings(yaml, document):
                reporter.emit(f"{path}:{line}: {message}")
                failures += 1
    except (yaml.YAMLError, PolicyError) as error:
        if isinstance(error, DiagnosticLimit):
            raise
        reporter.emit(f"{path}: invalid GitHub Actions workflow YAML: {error}")
        return failures + 1
    finally:
        loader.dispose()
    return failures


def check_stream(
    yaml: ModuleType, path_text: str, stream: TextIO, reporter: Reporter
) -> int:
    if not (
        _is_shell_source(path_text)
        or _is_workflow(path_text)
        or _is_static_command_source(path_text)
    ):
        return 0
    path = Path(path_text)
    try:
        if _is_workflow(path_text):
            return _check_workflow(yaml, path, stream, reporter)
        if _is_static_command_source(path_text):
            return _check_static_source(path, stream, reporter)
        return _check_shell_source(path, stream, reporter)
    except (OSError, UnicodeError, PolicyError) as error:
        if isinstance(error, DiagnosticLimit):
            raise
        reporter.emit(f"{path}: cannot validate text source: {error}")
        return 1


def main(arguments: list[str]) -> int:
    bindings: list[BoundFile] = []
    yaml_finder: _SealedYamlFinder | None = None
    reporter = Reporter()
    snapshot: StagedSnapshot | None = None
    try:
        if arguments:
            raise PolicyError(
                "silent-failure policy owns staged selection and accepts no paths"
            )
        _establish_resource_limits()
        bindings.extend(_bind_runtime())
        yaml, yaml_bindings, yaml_finder = _load_yaml()
        bindings.extend(yaml_bindings)
        snapshot = StagedSnapshot(os.getcwd())
        failures = 0
        for entry in snapshot.entries:
            blob: StagedBlob | None = None
            try:
                blob = snapshot.open_blob(entry)
                assert blob.stream is not None
                failures += check_stream(yaml, entry.path, blob.stream, reporter)
                blob.verify()
            finally:
                if blob is not None:
                    blob.close()
        snapshot.verify()
        for binding in bindings:
            binding.verify()
        return 1 if failures else 0
    except DiagnosticLimit:
        return 2
    except Exception as error:
        try:
            reporter.emit(f"ERROR: silent-failure policy unavailable: {error}")
        except DiagnosticLimit:
            pass
        return 2
    finally:
        signal.alarm(0)
        if yaml_finder is not None:
            yaml_finder.close()
        if snapshot is not None:
            snapshot.close()
        for binding in reversed(bindings):
            binding.close()


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
