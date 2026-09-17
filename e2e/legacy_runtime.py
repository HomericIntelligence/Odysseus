"""Durable, single-host runtime primitives for the legacy myrmidon harnesses.

The module deliberately uses only the Python standard library.  Runtime state
is stored below Git's common directory so linked worktrees and both legacy
harness entrypoints observe the same database and lock namespace.  The state is
bound to one repository registry and one host; a conflicting binding fails
closed instead of guessing whether persisted work is safe to resume.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Iterator, Mapping, Sequence
from contextlib import contextmanager
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import secrets
import socket
import sqlite3
import stat
import subprocess
import sys
import threading
import time
from typing import Any
import weakref


_STATE_DIRECTORY = "homeric-legacy-runtime"
_DATABASE_NAME = "state.sqlite3"
_MAX_HEAVY_SLOTS = 3
# SQLite INTEGER is signed 64-bit. Issue identity must fit this durable domain.
MAX_ISSUE_NUMBER = (1 << 63) - 1
_SERVICE_UID_ENV = "HOMERIC_LEGACY_SERVICE_UID"
_TERMINAL_FAILURE_STATES = frozenset({"failed", "human-blocked"})
_STAGE_TERMINAL_STATES = frozenset({"succeeded", "failed", "human-blocked"})
_ROOT_STAGE_REPO = "@odysseus-root"
_ROOT_STAGE_NAME = "ship-final"
_ROOT_STAGE_ITERATION = 0
_TRANSIENT_NAK_DELAY_SECONDS = 30.0
_local_lock_guard = threading.Lock()
_local_lock_paths: set[tuple[int, int, str]] = set()
_sqlite_descriptor_guard = threading.RLock()
_OPEN_SUPPORTS_DIR_FD = os.open in getattr(os, "supports_dir_fd", set())
_MKDIR_SUPPORTS_DIR_FD = os.mkdir in getattr(os, "supports_dir_fd", set())
_STAT_SUPPORTS_DIR_FD = os.stat in getattr(os, "supports_dir_fd", set())


class LegacyRuntimeError(RuntimeError):
    """Base error for durable legacy runtime operations."""


class TransientMessageError(LegacyRuntimeError):
    """A message operation can succeed after a bounded redelivery."""


class PermanentMessageError(LegacyRuntimeError):
    """The message cannot become valid through redelivery."""


class StateLocationError(LegacyRuntimeError):
    """The Git common directory cannot be bound safely."""


class StateConflictError(LegacyRuntimeError):
    """Persisted state conflicts with an exact task or event binding."""


class HostBindingError(LegacyRuntimeError):
    """A runtime database belongs to a different host."""


class RetryMessage(TransientMessageError):
    """A transient condition requires NAK/redelivery without worker failure."""


class LeaseUnavailableError(RetryMessage):
    """A bounded file lease could not be acquired before its deadline."""


class RejectMessage(PermanentMessageError):
    """A JetStream message is permanently invalid and must be terminated."""


class ConsumerHandlerError(LegacyRuntimeError):
    """A message handler failed after its message was NAKed for redelivery."""


class ConsumerHeartbeatError(LegacyRuntimeError):
    """A JetStream progress heartbeat failed or exceeded its RPC deadline."""


class ConsumerDispositionError(LegacyRuntimeError):
    """JetStream could not ACK, NAK, or terminate a handled message."""


def _required_text(value: object, field: str) -> str:
    if not isinstance(value, str) or not value.strip() or "\x00" in value:
        raise ValueError(f"{field} must be a non-empty string")
    return value


def _validated_issue_number(value: object) -> int:
    """Require one normalized issue integer that SQLite can store exactly."""
    if type(value) is not int or not 1 <= value <= MAX_ISSUE_NUMBER:
        raise ValueError(
            f"issue_number must be between 1 and {MAX_ISSUE_NUMBER}"
        )
    return value


def _canonical_json(value: object, field: str) -> str:
    try:
        return json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise ValueError(f"{field} must be canonical JSON data") from error


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _decode_json(
    value: object,
    field: str,
    *,
    expected_digest: object | None = None,
) -> Any:
    if not isinstance(value, str):
        raise StateConflictError(f"persisted {field} is not text")
    if expected_digest is not None and (
        not isinstance(expected_digest, str) or _digest(value) != expected_digest
    ):
        raise StateConflictError(f"persisted {field} failed its integrity check")
    try:
        decoded = json.loads(value)
    except (TypeError, ValueError) as error:
        raise StateConflictError(f"persisted {field} is invalid JSON") from error
    if _canonical_json(decoded, field) != value:
        raise StateConflictError(f"persisted {field} is not canonical")
    return decoded


def _decode_mapping(
    value: object,
    field: str,
    *,
    expected_digest: object | None = None,
) -> dict[str, Any]:
    decoded = _decode_json(value, field, expected_digest=expected_digest)
    if not isinstance(decoded, dict):
        raise StateConflictError(f"persisted {field} is not an object")
    return decoded


def _lease_deadline(now: float, lease_seconds: float) -> float:
    deadline = now + float(lease_seconds)
    if not math.isfinite(deadline):
        raise ValueError("lease expiration must be finite")
    return deadline


def _validated_lease_seconds(value: object) -> float:
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(float(value))
        or value <= 0
    ):
        raise ValueError("lease_seconds must be a positive finite number")
    return float(value)


def _validated_retention_seconds(value: object) -> float:
    try:
        retention = _validated_lease_seconds(value)
    except ValueError as error:
        raise ValueError(
            "message_retention_seconds must be a positive finite number"
        ) from error
    return retention


def _validated_service_uid(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("service_uid must be a non-negative integer")
    configured_text = os.environ.get(_SERVICE_UID_ENV)
    if (
        configured_text is None
        or not configured_text.isascii()
        or not configured_text.isdigit()
        or str(int(configured_text)) != configured_text
    ):
        raise HostBindingError(
            f"{_SERVICE_UID_ENV} must name one exact service UID"
        )
    configured_uid = int(configured_text)
    if value != configured_uid:
        raise HostBindingError(
            f"legacy runtime was configured for service UID {configured_uid}, "
            f"not {value}"
        )
    effective_uid = os.geteuid()
    if configured_uid != effective_uid:
        raise HostBindingError(
            f"legacy runtime requires service UID {configured_uid}, effective UID is "
            f"{effective_uid}"
        )
    return configured_uid


def _validated_iteration(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise ValueError("iteration must be a non-negative integer")
    return value


def _validate_retention_bounded_lease(
    lease_seconds: float,
    message_retention_seconds: float,
) -> None:
    if lease_seconds >= message_retention_seconds:
        raise ValueError(
            "lease_seconds must be shorter than message retention so a failed "
            "claim remains recoverable"
        )


def stable_event_id(
    subject: str,
    *,
    stream: str,
    message_id: str | None = None,
    stream_sequence: int | None = None,
) -> str:
    """Return a stable identity for one JetStream event across redelivery.

    Durable producer IDs are preferred.  Headerless legacy events must use the
    immutable stream sequence exposed by JetStream metadata.  Content hashes
    are deliberately not accepted as identities because two intentional,
    byte-identical publications are still distinct events.  The durable stage
    record separately binds this identity to the exact subject and payload.
    """

    subject = _required_text(subject, "subject")
    stream = _required_text(stream, "stream")
    if (message_id is None) == (stream_sequence is None):
        raise ValueError(
            "exactly one of message_id or stream_sequence is required"
        )
    if message_id is not None:
        source = {
            "kind": "message-id",
            "message_id": _required_text(message_id, "message_id"),
            "stream": stream,
        }
    else:
        if (
            isinstance(stream_sequence, bool)
            or not isinstance(stream_sequence, int)
            or stream_sequence <= 0
        ):
            raise ValueError("stream_sequence must be a positive integer")
        source = {
            "kind": "stream-sequence",
            "sequence": stream_sequence,
            "stream": stream,
        }
    return _digest(_canonical_json(source, "event source"))


def _validate_claim_state(owner: object, expires_at: object, field: str) -> None:
    if owner is None and expires_at is None:
        return
    if owner is None or expires_at is None:
        raise StateConflictError(f"persisted {field} claim is incomplete")
    _required_text(owner, f"{field} claim owner")
    if (
        isinstance(expires_at, bool)
        or not isinstance(expires_at, (int, float))
        or not math.isfinite(float(expires_at))
    ):
        raise StateConflictError(f"persisted {field} claim expiry is invalid")


def _validate_fenced_claim_state(
    owner: object,
    expires_at: object,
    token: object,
    generation: object,
    field: str,
) -> None:
    if (
        isinstance(generation, bool)
        or not isinstance(generation, int)
        or generation < 0
    ):
        raise StateConflictError(
            f"persisted {field} claim generation is invalid"
        )
    if owner is None and expires_at is None and token is None:
        return
    if owner is None or expires_at is None or token is None:
        raise StateConflictError(f"persisted {field} claim is incomplete")
    _validate_claim_state(owner, expires_at, field)
    if not isinstance(token, str) or not token.strip() or "\x00" in token:
        raise StateConflictError(f"persisted {field} claim token is invalid")
    if generation == 0:
        raise StateConflictError(
            f"persisted {field} claim generation is invalid"
        )


def _validate_outbox_claim_state(
    owner: object,
    expires_at: object,
    token: object,
    generation: object,
) -> None:
    _validate_fenced_claim_state(
        owner, expires_at, token, generation, "outbox"
    )


def _validate_outbox_delivery_state(
    requires_checkpoint: object,
    consumer_checkpointed_at: object,
    sent_at: object,
    rearm_at: object,
    *,
    duplicate_window_seconds: float,
    message_retention_seconds: float,
) -> None:
    if requires_checkpoint not in (0, 1):
        raise StateConflictError(
            "persisted outbox checkpoint requirement is invalid"
        )
    for value, field in (
        (consumer_checkpointed_at, "consumer checkpoint"),
        (sent_at, "broker acknowledgement"),
        (rearm_at, "outbox rearm"),
    ):
        if value is not None and (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
        ):
            raise StateConflictError(f"persisted {field} time is invalid")
    if not requires_checkpoint and (
        consumer_checkpointed_at is not None or rearm_at is not None
    ):
        raise StateConflictError(
            "non-checkpoint outbox event contains consumer checkpoint state"
        )
    if rearm_at is not None and (
        sent_at is None or consumer_checkpointed_at is not None
    ):
        raise StateConflictError("persisted outbox rearm state is inconsistent")
    if rearm_at is not None:
        delay = float(rearm_at) - float(sent_at)
        if not duplicate_window_seconds < delay < message_retention_seconds:
            raise StateConflictError(
                "persisted outbox rearm delay must be after the duplicate window "
                "and before message retention"
            )


def _run_git(workdir: Path, *args: str) -> str:
    try:
        result = subprocess.run(
            ["git", "-C", str(workdir), *args],
            capture_output=True,
            check=False,
            stdin=subprocess.DEVNULL,
            text=True,
            timeout=10,
            env={
                key: value
                for key, value in os.environ.items()
                if not key.startswith("GIT_")
            },
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise StateLocationError(f"could not inspect Git state: {error}") from error
    if result.returncode != 0:
        detail = result.stderr.strip() or "git rev-parse failed"
        raise StateLocationError(f"could not resolve Git state: {detail}")
    output = result.stdout.strip()
    if not output or "\x00" in output or "\n" in output:
        raise StateLocationError("Git returned an invalid path")
    return output


def _bind_state_root(
    workdir: str | os.PathLike[str],
) -> _BoundLockDirectory:
    """Bind the private state directory through a root-anchored chain.

    A non-repository, missing common directory, or symlink in the chain is
    rejected. This never falls back to the checkout or a global temp path.
    """

    try:
        checkout = Path(workdir).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StateLocationError(f"working directory is unavailable: {error}") from error
    if not checkout.is_dir():
        raise StateLocationError("working directory is not a directory")

    raw_common = _run_git(checkout, "rev-parse", "--git-common-dir")
    common = Path(raw_common)
    if not common.is_absolute():
        common = checkout / common
    try:
        common = common.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StateLocationError(f"Git common directory is unavailable: {error}") from error
    if not common.is_dir():
        raise StateLocationError("Git common directory is not a directory")

    binding: _BoundLockDirectory | None = None
    try:
        binding = _open_existing_directory_chain(common)
        binding.append_private(_STATE_DIRECTORY)
        os.fsync(binding._descriptors[-2])
        binding.verify()
        return binding
    except BaseException as error:
        if binding is not None:
            try:
                binding.close()
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to close the state directory binding: {cleanup_error}"
                )
        raise


def state_root(workdir: str | os.PathLike[str]) -> Path:
    """Return a root-bound private directory below Git's common directory."""

    binding = _bind_state_root(workdir)
    try:
        return binding.path
    finally:
        binding.close()


def _default_host_id() -> str:
    return _required_text(socket.gethostname(), "host_id")


class _BoundConnection(sqlite3.Connection):
    """SQLite connection that revalidates its guarded path around operations."""

    _guard_directory: _BoundLockDirectory | None = None
    _guard_file_descriptor: int | None = None
    _guard_database_name: str | None = None
    _guard_database_identity: tuple[int, int] | None = None
    _guard_sidecar_identities: dict[str, tuple[int, int]] | None = None
    _sqlite_descriptor: int | None = None

    def _verify_paths(self) -> None:
        if self._guard_directory is None:
            return
        if (
            self._guard_file_descriptor is None
            or self._guard_database_name is None
            or self._guard_database_identity is None
            or self._guard_sidecar_identities is None
        ):
            raise StateLocationError("runtime database guard is incomplete")
        _verify_runtime_paths(
            self._guard_directory,
            self._guard_file_descriptor,
            self._guard_database_name,
            self._guard_database_identity,
            self._guard_sidecar_identities,
        )

    def _verify_binding(self) -> None:
        self._verify_paths()
        if self._guard_directory is None:
            return
        if self._sqlite_descriptor is None or self._guard_database_identity is None:
            raise StateLocationError("SQLite database descriptor is not bound")
        try:
            sqlite_info = os.fstat(self._sqlite_descriptor)
        except OSError as error:
            raise StateLocationError(
                f"SQLite database descriptor is unavailable: {error}"
            ) from error
        _verify_private_file(
            sqlite_info,
            "SQLite opened database",
            expected_identity=self._guard_database_identity,
        )

    def _guarded_call(self, operation: Callable[[], Any]) -> Any:
        self._verify_binding()
        try:
            return operation()
        finally:
            self._verify_binding()

    def execute(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        return self._guarded_call(lambda: super(_BoundConnection, self).execute(*args, **kwargs))

    def executemany(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        return self._guarded_call(
            lambda: super(_BoundConnection, self).executemany(*args, **kwargs)
        )

    def executescript(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        return self._guarded_call(
            lambda: super(_BoundConnection, self).executescript(*args, **kwargs)
        )

    def commit(self) -> None:
        self._guarded_call(lambda: super(_BoundConnection, self).commit())

    def rollback(self) -> None:
        self._guarded_call(lambda: super(_BoundConnection, self).rollback())

    def close(self) -> None:
        directory = self._guard_directory
        file_descriptor = self._guard_file_descriptor
        verification_error: BaseException | None = None
        try:
            if directory is not None:
                try:
                    self._verify_binding()
                except BaseException as error:
                    verification_error = error
            with _sqlite_descriptor_guard:
                try:
                    super().close()
                except BaseException as error:
                    if verification_error is None:
                        verification_error = error
            if directory is not None:
                try:
                    self._verify_paths()
                except BaseException as error:
                    if verification_error is None:
                        verification_error = error
        finally:
            self._guard_directory = None
            self._guard_file_descriptor = None
            self._guard_database_name = None
            self._guard_database_identity = None
            self._guard_sidecar_identities = None
            self._sqlite_descriptor = None
            cleanup_errors: list[BaseException] = []
            if file_descriptor is not None:
                try:
                    os.close(file_descriptor)
                except BaseException as error:
                    cleanup_errors.append(error)
            if directory is not None:
                try:
                    directory.close()
                except BaseException as error:
                    cleanup_errors.append(error)
            if verification_error is None and cleanup_errors:
                verification_error = cleanup_errors.pop(0)
            if verification_error is not None:
                for error in cleanup_errors:
                    verification_error.add_note(f"also failed during cleanup: {error}")
        if verification_error is not None:
            raise verification_error


def _verify_private_directory(info: os.stat_result) -> None:
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
    ):
        raise StateLocationError("runtime state directory is not private to this user")


def _verify_private_file(
    info: os.stat_result,
    field: str,
    *,
    expected_identity: tuple[int, int] | None = None,
) -> None:
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_nlink != 1
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
        or (
            expected_identity is not None
            and (info.st_dev, info.st_ino) != expected_identity
        )
    ):
        raise StateLocationError(f"{field} must be one private regular file")


def _descriptor_snapshot() -> dict[int, os.stat_result]:
    """Return stable open descriptors, omitting the listing's transient FD."""

    try:
        entries = os.listdir("/dev/fd")
    except OSError as error:
        raise StateLocationError(
            f"could not inspect process descriptors: {error}"
        ) from error
    descriptors: dict[int, os.stat_result] = {}
    for entry in entries:
        if not entry.isascii() or not entry.isdigit():
            continue
        descriptor = int(entry)
        try:
            descriptors[descriptor] = os.fstat(descriptor)
        except OSError as error:
            if error.errno == errno.EBADF:
                continue
            raise StateLocationError(
                f"could not inspect process descriptor {descriptor}: {error}"
            ) from error
    return descriptors


def _identify_sqlite_descriptor(
    before: Mapping[int, os.stat_result],
    after: Mapping[int, os.stat_result],
    database_identity: tuple[int, int],
    sidecar_identities: Mapping[str, tuple[int, int]],
) -> int:
    """Bind the one descriptor opened by sqlite3.connect to the guarded inode."""

    new_descriptors = sorted(set(after) - set(before))
    database_descriptors = [
        descriptor
        for descriptor in new_descriptors
        if (after[descriptor].st_dev, after[descriptor].st_ino)
        == database_identity
    ]
    allowed_identities = {database_identity, *sidecar_identities.values()}
    unexpected_descriptors = [
        descriptor
        for descriptor in new_descriptors
        if (after[descriptor].st_dev, after[descriptor].st_ino)
        not in allowed_identities
    ]
    if len(database_descriptors) != 1 or unexpected_descriptors:
        raise StateLocationError(
            "sqlite3.connect opened an unidentifiable database descriptor set"
        )
    descriptor = database_descriptors[0]
    _verify_private_file(
        after[descriptor],
        "SQLite opened database",
        expected_identity=database_identity,
    )
    return descriptor


def _verify_runtime_paths(
    directory: _BoundLockDirectory,
    file_descriptor: int,
    database_name: str,
    database_identity: tuple[int, int],
    sidecar_identities: dict[str, tuple[int, int]],
) -> None:
    """Fail closed if SQLite's path or a sidecar is redirected or replaced."""

    try:
        directory.verify()
        descriptor_directory = os.fstat(directory.descriptor)
        _verify_private_directory(descriptor_directory)

        descriptor_database = os.fstat(file_descriptor)
        path_database = os.stat(
            database_name,
            dir_fd=directory.descriptor,
            follow_symlinks=False,
        )
        _verify_private_file(
            descriptor_database,
            "runtime database",
            expected_identity=database_identity,
        )
        _verify_private_file(
            path_database,
            "runtime database entry",
            expected_identity=database_identity,
        )

        for suffix in ("-journal", "-wal", "-shm"):
            sidecar_name = f"{database_name}{suffix}"
            try:
                sidecar = os.stat(
                    sidecar_name,
                    dir_fd=directory.descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                continue
            _verify_private_file(sidecar, f"SQLite sidecar {sidecar_name}")
            identity = (sidecar.st_dev, sidecar.st_ino)
            expected_identity = sidecar_identities.get(sidecar_name)
            if expected_identity is None:
                sidecar_identities[sidecar_name] = identity
            elif identity != expected_identity:
                raise StateLocationError(
                    f"SQLite sidecar {sidecar_name} changed inode"
                )
    except StateLocationError:
        raise
    except OSError as error:
        raise StateLocationError(
            f"could not revalidate durable runtime state: {error}"
        ) from error


def _descriptor_sqlite_route_supported() -> bool:
    """Return whether Linux procfs exposes stable descriptor-relative paths."""

    if not sys.platform.startswith("linux"):
        return False
    try:
        info = os.stat("/proc/self/fd")
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode)


def _connect_sqlite_at(
    directory: _BoundLockDirectory,
    database_name: str,
    **kwargs: Any,
) -> _BoundConnection:
    """Open SQLite through the exact retained Linux directory descriptor."""

    if not _descriptor_sqlite_route_supported():
        raise StateLocationError(
            "descriptor-relative SQLite requires Linux /proc/self/fd"
        )
    if (
        not database_name
        or database_name in {".", ".."}
        or os.sep in database_name
        or "\x00" in database_name
    ):
        raise StateLocationError("runtime database name is malformed")
    connection: _BoundConnection | None = None
    try:
        directory.verify()
        descriptor_info = os.fstat(directory.descriptor)
        proc_info = os.stat(f"/proc/self/fd/{directory.descriptor}")
        if (descriptor_info.st_dev, descriptor_info.st_ino) != (
            proc_info.st_dev,
            proc_info.st_ino,
        ):
            raise StateLocationError("the procfs directory route changed")
        connection = sqlite3.connect(
            f"/proc/self/fd/{directory.descriptor}/{database_name}",
            **kwargs,
        )
        directory.verify()
        proc_after = os.stat(f"/proc/self/fd/{directory.descriptor}")
        if (descriptor_info.st_dev, descriptor_info.st_ino) != (
            proc_after.st_dev,
            proc_after.st_ino,
        ):
            raise StateLocationError("the procfs directory route changed")
        return connection
    except BaseException as error:
        if connection is not None:
            try:
                connection.close()
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to close the rejected SQLite handle: {cleanup_error}"
                )
        if isinstance(error, OSError) and not isinstance(error, sqlite3.Error):
            raise StateLocationError(
                f"could not use descriptor-relative SQLite: {error}"
            ) from error
        raise


class RuntimeStore:
    """Exact-bound SQLite task state with recoverable claims and an outbox."""

    def __init__(
        self,
        database: Path,
        repo: str,
        registry_digest: str,
        *,
        host_id: str,
        service_uid: int,
        message_retention_seconds: float,
        duplicate_window_seconds: float,
        clock: Callable[[], float],
        _state_directory: _BoundLockDirectory | None = None,
    ) -> None:
        self.database = database
        self.repo = _required_text(repo, "repo")
        self.registry_digest = _required_text(registry_digest, "registry_digest")
        self.host_id = _required_text(host_id, "host_id")
        self.service_uid = _validated_service_uid(service_uid)
        self.message_retention_seconds = _validated_retention_seconds(
            message_retention_seconds
        )
        self.duplicate_window_seconds = _validated_lease_seconds(
            duplicate_window_seconds
        )
        if self.duplicate_window_seconds >= self.message_retention_seconds:
            raise ValueError(
                "duplicate_window_seconds must be shorter than message retention"
            )
        self.outbox_rearm_seconds = (
            self.duplicate_window_seconds + self.message_retention_seconds
        ) / 2.0
        self._clock = clock
        self.namespace = _digest(f"{self.repo}\0{self.registry_digest}")
        if not _descriptor_sqlite_route_supported():
            raise StateLocationError(
                "durable runtime state requires Linux /proc/self/fd"
            )
        self._state_directory = (
            _state_directory
            if _state_directory is not None
            else _open_existing_directory_chain(self.database.parent)
        )
        self._state_directory.verify()
        _verify_private_directory(os.fstat(self._state_directory.descriptor))
        self._state_directory_finalizer = weakref.finalize(
            self,
            self._state_directory.close,
        )
        self._initialize()

    def _bind_database_inode(
        self,
    ) -> tuple[_BoundLockDirectory, int, os.stat_result]:
        directory: _BoundLockDirectory | None = None
        file_flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
        file_descriptor = -1
        bound = False
        try:
            self._state_directory.verify()
            directory = self._state_directory.clone()
            directory.verify()
            file_descriptor = os.open(
                self.database.name,
                file_flags,
                0o600,
                dir_fd=directory.descriptor,
            )
            info = os.fstat(file_descriptor)
            if (
                not stat.S_ISREG(info.st_mode)
                or info.st_nlink != 1
                or info.st_uid != os.geteuid()
            ):
                raise StateLocationError(
                    "runtime database must be one private regular file"
                )
            identity = (info.st_dev, info.st_ino)
            os.fchmod(file_descriptor, 0o600)
            info = os.fstat(file_descriptor)
            _verify_private_file(
                info,
                "runtime database",
                expected_identity=identity,
            )
            os.fsync(file_descriptor)
            os.fsync(directory.descriptor)
            directory.verify()
            bound = True
            return directory, file_descriptor, info
        except StateLocationError:
            raise
        except OSError as error:
            raise StateLocationError(
                f"could not bind durable runtime state: {error}"
            ) from error
        finally:
            if not bound:
                if file_descriptor >= 0:
                    os.close(file_descriptor)
                if directory is not None:
                    directory.close()

    def _connect(self) -> _BoundConnection:
        # Descriptor discovery is process-global. Keep database binding and
        # sqlite3 descriptor discovery in one critical section so a concurrent
        # opener cannot make another connection's descriptor set ambiguous.
        with _sqlite_descriptor_guard:
            return self._connect_locked()

    def _connect_locked(self) -> _BoundConnection:
        directory, file_descriptor, bound_info = self._bind_database_inode()
        connection: _BoundConnection | None = None
        try:
            identity = (bound_info.st_dev, bound_info.st_ino)
            sidecar_identities: dict[str, tuple[int, int]] = {}
            _verify_runtime_paths(
                directory,
                file_descriptor,
                self.database.name,
                identity,
                sidecar_identities,
            )
            with _sqlite_descriptor_guard:
                descriptors_before = _descriptor_snapshot()
                connection = _connect_sqlite_at(
                    directory,
                    self.database.name,
                    isolation_level=None,
                    timeout=5,
                    factory=_BoundConnection,
                )
                descriptors_after = _descriptor_snapshot()
                _verify_runtime_paths(
                    directory,
                    file_descriptor,
                    self.database.name,
                    identity,
                    sidecar_identities,
                )
                sqlite_descriptor = _identify_sqlite_descriptor(
                    descriptors_before,
                    descriptors_after,
                    identity,
                    sidecar_identities,
                )
            connection._guard_directory = directory
            connection._guard_file_descriptor = file_descriptor
            connection._guard_database_name = self.database.name
            connection._guard_database_identity = identity
            connection._guard_sidecar_identities = sidecar_identities
            connection._sqlite_descriptor = sqlite_descriptor
            directory = None
            file_descriptor = -1
            connection._verify_binding()
            connection.row_factory = sqlite3.Row
            connection.execute("PRAGMA busy_timeout = 5000")
            connection.execute("PRAGMA foreign_keys = ON")
            mode = connection.execute("PRAGMA journal_mode = WAL").fetchone()[0]
            if str(mode).lower() != "wal":
                connection.close()
                raise LegacyRuntimeError("SQLite WAL mode is unavailable")
            connection.execute("PRAGMA synchronous = FULL")
            return connection
        except StateLocationError:
            if connection is not None:
                connection.close()
            raise
        except sqlite3.Error as error:
            if connection is not None:
                connection.close()
            raise LegacyRuntimeError(f"could not open durable runtime state: {error}") from error
        except Exception:
            if connection is not None:
                connection.close()
            raise
        finally:
            if file_descriptor >= 0:
                os.close(file_descriptor)
            if directory is not None:
                directory.close()

    def _initialize(self) -> None:
        connection = self._connect()
        try:
            connection.execute("BEGIN EXCLUSIVE")
            schema = """
                CREATE TABLE IF NOT EXISTS runtimes (
                    namespace TEXT PRIMARY KEY,
                    repo TEXT NOT NULL,
                    registry_digest TEXT NOT NULL,
                    host_id TEXT NOT NULL,
                    service_uid INTEGER NOT NULL,
                    message_retention_seconds REAL NOT NULL,
                    duplicate_window_seconds REAL NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS tasks (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    team_id TEXT NOT NULL,
                    issue_number INTEGER NOT NULL,
                    task_digest TEXT NOT NULL,
                    plan_source_event_id TEXT,
                    plan_subject TEXT,
                    plan_payload_json TEXT,
                    plan_payload_digest TEXT,
                    completion_json TEXT,
                    completion_outbox_json TEXT,
                    terminal_status TEXT,
                    completed_at REAL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (namespace, task_id),
                    UNIQUE (namespace, plan_source_event_id),
                    FOREIGN KEY (namespace) REFERENCES runtimes(namespace)
                );
                CREATE TABLE IF NOT EXISTS routes (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    route_json TEXT NOT NULL,
                    PRIMARY KEY (namespace, task_id, repo_slug),
                    FOREIGN KEY (namespace, task_id)
                        REFERENCES tasks(namespace, task_id)
                );
                CREATE TABLE IF NOT EXISTS candidates (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    candidate_json TEXT NOT NULL,
                    candidate_digest TEXT NOT NULL,
                    source_message_id TEXT,
                    source_subject TEXT,
                    source_payload_json TEXT,
                    source_payload_digest TEXT,
                    claim_owner TEXT,
                    claim_expires_at REAL,
                    claim_token TEXT,
                    claim_generation INTEGER NOT NULL DEFAULT 0,
                    completed_at REAL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (namespace, task_id, repo_slug),
                    FOREIGN KEY (namespace, task_id, repo_slug)
                        REFERENCES routes(namespace, task_id, repo_slug)
                );
                CREATE TABLE IF NOT EXISTS receipts (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    receipt_json TEXT NOT NULL,
                    receipt_digest TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (namespace, task_id, repo_slug),
                    FOREIGN KEY (namespace, task_id, repo_slug)
                        REFERENCES routes(namespace, task_id, repo_slug)
                );
                CREATE TABLE IF NOT EXISTS outbox (
                    namespace TEXT NOT NULL,
                    outbox_id TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    purpose TEXT NOT NULL,
                    subject TEXT NOT NULL,
                    payload_json TEXT NOT NULL,
                    payload_digest TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    sent_at REAL,
                    sent_by TEXT,
                    sent_claim_token TEXT,
                    requires_consumer_checkpoint INTEGER NOT NULL DEFAULT 0,
                    consumer_checkpointed_at REAL,
                    rearm_at REAL,
                    attempts INTEGER NOT NULL DEFAULT 0,
                    claim_owner TEXT,
                    claim_expires_at REAL,
                    claim_token TEXT,
                    claim_generation INTEGER NOT NULL DEFAULT 0,
                    PRIMARY KEY (namespace, outbox_id),
                    UNIQUE (namespace, task_id, purpose),
                    FOREIGN KEY (namespace, task_id)
                        REFERENCES tasks(namespace, task_id)
                );
                CREATE TABLE IF NOT EXISTS stage_runs (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    stage TEXT NOT NULL,
                    iteration INTEGER NOT NULL,
                    source_event_id TEXT NOT NULL,
                    source_message_id TEXT,
                    subject TEXT NOT NULL,
                    input_json TEXT NOT NULL,
                    input_digest TEXT NOT NULL,
                    intent_json TEXT NOT NULL,
                    intent_digest TEXT NOT NULL,
                    state TEXT NOT NULL,
                    result_json TEXT,
                    result_digest TEXT,
                    output_outbox_id TEXT,
                    claim_owner TEXT,
                    claim_expires_at REAL,
                    claim_token TEXT,
                    claim_generation INTEGER NOT NULL DEFAULT 0,
                    created_at REAL NOT NULL,
                    completed_at REAL,
                    PRIMARY KEY (
                        namespace, task_id, repo_slug, stage, iteration
                    ),
                    UNIQUE (namespace, source_event_id),
                    FOREIGN KEY (namespace, task_id)
                        REFERENCES tasks(namespace, task_id),
                    FOREIGN KEY (namespace, output_outbox_id)
                        REFERENCES outbox(namespace, outbox_id)
                );
                """
            for statement in schema.split(";"):
                statement = statement.strip()
                if statement:
                    connection.execute(statement)
            runtime_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(runtimes)")
            }
            if "service_uid" not in runtime_columns:
                connection.execute(
                    "ALTER TABLE runtimes ADD COLUMN service_uid INTEGER"
                )
            connection.execute(
                "UPDATE runtimes SET service_uid = ? WHERE service_uid IS NULL",
                (self.service_uid,),
            )
            if "message_retention_seconds" not in runtime_columns:
                connection.execute(
                    "ALTER TABLE runtimes ADD COLUMN message_retention_seconds REAL"
                )
            connection.execute(
                "UPDATE runtimes SET message_retention_seconds = ? "
                "WHERE message_retention_seconds IS NULL",
                (self.message_retention_seconds,),
            )
            if "duplicate_window_seconds" not in runtime_columns:
                connection.execute(
                    "ALTER TABLE runtimes ADD COLUMN duplicate_window_seconds REAL"
                )
            connection.execute(
                "UPDATE runtimes SET duplicate_window_seconds = ? "
                "WHERE duplicate_window_seconds IS NULL",
                (self.duplicate_window_seconds,),
            )
            task_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(tasks)")
            }
            for column in (
                "plan_source_event_id",
                "plan_subject",
                "plan_payload_json",
                "plan_payload_digest",
            ):
                if column not in task_columns:
                    connection.execute(f"ALTER TABLE tasks ADD COLUMN {column} TEXT")
            connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS task_plan_source_event "
                "ON tasks(namespace, plan_source_event_id) "
                "WHERE plan_source_event_id IS NOT NULL"
            )
            if "completion_outbox_json" not in task_columns:
                connection.execute(
                    "ALTER TABLE tasks ADD COLUMN completion_outbox_json TEXT"
                )
            if "terminal_status" not in task_columns:
                connection.execute(
                    "ALTER TABLE tasks ADD COLUMN terminal_status TEXT"
                )
            connection.execute(
                "UPDATE tasks SET terminal_status = 'completed' "
                "WHERE completion_json IS NOT NULL AND terminal_status IS NULL"
            )
            candidate_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(candidates)")
            }
            for column in (
                "source_message_id",
                "source_subject",
                "source_payload_json",
                "source_payload_digest",
            ):
                if column not in candidate_columns:
                    connection.execute(
                        f"ALTER TABLE candidates ADD COLUMN {column} TEXT"
                    )
            connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS candidate_source_message "
                "ON candidates(namespace, source_message_id) "
                "WHERE source_message_id IS NOT NULL"
            )
            added_candidate_token = "claim_token" not in candidate_columns
            if added_candidate_token:
                connection.execute(
                    "ALTER TABLE candidates ADD COLUMN claim_token TEXT"
                )
            if "claim_generation" not in candidate_columns:
                connection.execute(
                    "ALTER TABLE candidates ADD COLUMN claim_generation INTEGER "
                    "NOT NULL DEFAULT 0"
                )
            if added_candidate_token:
                connection.execute(
                    "UPDATE candidates SET claim_owner = NULL, "
                    "claim_expires_at = NULL WHERE completed_at IS NULL"
                )
            connection.execute(
                "UPDATE candidates SET completed_at = COALESCE(completed_at, "
                "(SELECT t.completed_at FROM tasks AS t WHERE "
                "t.namespace = candidates.namespace AND "
                "t.task_id = candidates.task_id)), claim_owner = NULL, "
                "claim_expires_at = NULL, claim_token = NULL WHERE EXISTS "
                "(SELECT 1 FROM tasks AS t WHERE t.namespace = candidates.namespace "
                "AND t.task_id = candidates.task_id AND t.completion_json IS NOT NULL)"
            )
            outbox_columns = {
                row["name"]
                for row in connection.execute("PRAGMA table_info(outbox)")
            }
            if "claim_owner" not in outbox_columns:
                connection.execute("ALTER TABLE outbox ADD COLUMN claim_owner TEXT")
            if "claim_expires_at" not in outbox_columns:
                connection.execute(
                    "ALTER TABLE outbox ADD COLUMN claim_expires_at REAL"
                )
            if "sent_by" not in outbox_columns:
                connection.execute("ALTER TABLE outbox ADD COLUMN sent_by TEXT")
            if "sent_claim_token" not in outbox_columns:
                connection.execute(
                    "ALTER TABLE outbox ADD COLUMN sent_claim_token TEXT"
                )
            if "requires_consumer_checkpoint" not in outbox_columns:
                connection.execute(
                    "ALTER TABLE outbox ADD COLUMN requires_consumer_checkpoint "
                    "INTEGER NOT NULL DEFAULT 0"
                )
            if "consumer_checkpointed_at" not in outbox_columns:
                connection.execute(
                    "ALTER TABLE outbox ADD COLUMN consumer_checkpointed_at REAL"
                )
            if "rearm_at" not in outbox_columns:
                connection.execute("ALTER TABLE outbox ADD COLUMN rearm_at REAL")
            connection.execute(
                "UPDATE outbox SET requires_consumer_checkpoint = 1 WHERE "
                "purpose = 'fan-in-ready' OR purpose LIKE 'route:%' OR "
                "purpose LIKE 'candidate:%' OR purpose LIKE 'stage:%'"
            )
            connection.execute(
                "UPDATE outbox SET rearm_at = sent_at + ? WHERE "
                "requires_consumer_checkpoint = 1 AND sent_at IS NOT NULL "
                "AND consumer_checkpointed_at IS NULL AND rearm_at IS NULL",
                (self.outbox_rearm_seconds,),
            )
            added_claim_token = "claim_token" not in outbox_columns
            if added_claim_token:
                connection.execute("ALTER TABLE outbox ADD COLUMN claim_token TEXT")
            if "claim_generation" not in outbox_columns:
                connection.execute(
                    "ALTER TABLE outbox ADD COLUMN claim_generation INTEGER "
                    "NOT NULL DEFAULT 0"
                )
            if added_claim_token:
                connection.execute(
                    "UPDATE outbox SET claim_owner = NULL, claim_expires_at = NULL "
                    "WHERE sent_at IS NULL"
                )
            duplicate_stage_source = connection.execute(
                "SELECT namespace, source_message_id FROM stage_runs "
                "WHERE source_message_id IS NOT NULL "
                "GROUP BY namespace, source_message_id "
                "HAVING COUNT(*) > 1 LIMIT 1",
            ).fetchone()
            if duplicate_stage_source is not None:
                raise StateConflictError(
                    "persisted stages reuse one local source message"
                )
            connection.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS stage_source_message "
                "ON stage_runs(namespace, source_message_id) "
                "WHERE source_message_id IS NOT NULL"
            )
            conflicting_runtime = connection.execute(
                "SELECT r.registry_digest FROM runtimes AS r "
                "WHERE r.repo = ? AND r.namespace <> ? AND ("
                "EXISTS (SELECT 1 FROM tasks AS t WHERE t.namespace = r.namespace "
                "AND t.completion_json IS NULL) OR "
                "EXISTS (SELECT 1 FROM outbox AS o WHERE o.namespace = r.namespace "
                "AND o.consumer_checkpointed_at IS NULL AND (o.sent_at IS NULL "
                "OR o.requires_consumer_checkpoint = 1)) OR "
                "EXISTS (SELECT 1 FROM candidates AS c WHERE c.namespace = r.namespace "
                "AND c.completed_at IS NULL) OR "
                "EXISTS (SELECT 1 FROM stage_runs AS s WHERE s.namespace = r.namespace "
                "AND s.state = 'pending')) LIMIT 1",
                (self.repo, self.namespace),
            ).fetchone()
            if conflicting_runtime is not None:
                raise StateConflictError(
                    "another registry binding has unfinished durable state"
                )
            row = connection.execute(
                "SELECT repo, registry_digest, host_id, service_uid, "
                "message_retention_seconds, duplicate_window_seconds FROM runtimes "
                "WHERE namespace = ?",
                (self.namespace,),
            ).fetchone()
            is_new_runtime = row is None
            if is_new_runtime:
                connection.execute(
                    "INSERT INTO runtimes "
                    "(namespace, repo, registry_digest, host_id, service_uid, "
                    "message_retention_seconds, duplicate_window_seconds, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        self.repo,
                        self.registry_digest,
                        self.host_id,
                        self.service_uid,
                        self.message_retention_seconds,
                        self.duplicate_window_seconds,
                        self._now(),
                    ),
                )
            else:
                if row["repo"] != self.repo or row["registry_digest"] != self.registry_digest:
                    raise StateConflictError("runtime identity hash collision")
                if row["host_id"] != self.host_id:
                    raise HostBindingError(
                        "durable runtime state is bound to a different host"
                    )
                if row["service_uid"] != self.service_uid:
                    raise HostBindingError(
                        "durable runtime state is bound to a different service UID"
                    )
                persisted_retention = row["message_retention_seconds"]
                if (
                    isinstance(persisted_retention, bool)
                    or not isinstance(persisted_retention, (int, float))
                    or not math.isfinite(float(persisted_retention))
                    or float(persisted_retention)
                    != self.message_retention_seconds
                ):
                    raise StateConflictError(
                        "message retention conflicts with persisted runtime state"
                    )
                persisted_duplicate_window = row["duplicate_window_seconds"]
                if (
                    isinstance(persisted_duplicate_window, bool)
                    or not isinstance(persisted_duplicate_window, (int, float))
                    or not math.isfinite(float(persisted_duplicate_window))
                    or float(persisted_duplicate_window)
                    != self.duplicate_window_seconds
                ):
                    raise StateConflictError(
                        "duplicate window conflicts with persisted runtime state"
                    )
            connection.commit()
        except Exception:
            if connection.in_transaction:
                connection.rollback()
            raise
        finally:
            connection.close()

    def _now(self) -> float:
        value = self._clock()
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            raise ValueError("clock must return a finite number")
        value = float(value)
        if not math.isfinite(value):
            raise ValueError("clock must return a finite number")
        return value

    @contextmanager
    def _transaction(self) -> Iterator[sqlite3.Connection]:
        connection = self._connect()
        try:
            connection.execute("BEGIN IMMEDIATE")
            yield connection
            connection.commit()
        except Exception:
            if connection.in_transaction:
                connection.rollback()
            raise
        finally:
            connection.close()

    def record_plan(
        self,
        task_id: str,
        team_id: str,
        issue_number: int,
        route_map: Mapping[str, Mapping[str, Any]],
        task_digest: str,
    ) -> None:
        """Persist an exact plan binding, accepting only identical redelivery."""

        task_id = _required_text(task_id, "task_id")
        team_id = _required_text(team_id, "team_id")
        task_digest = _required_text(task_digest, "task_digest")
        issue_number = _validated_issue_number(issue_number)
        if not isinstance(route_map, Mapping) or not route_map:
            raise ValueError("route_map must be a non-empty mapping")
        routes: dict[str, str] = {}
        for slug, route in route_map.items():
            slug = _required_text(slug, "repo_slug")
            if not isinstance(route, Mapping):
                raise ValueError("each route must be a mapping")
            routes[slug] = _canonical_json(dict(route), f"route {slug}")

        now = self._now()
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT team_id, issue_number, task_digest FROM tasks "
                "WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            is_new_task = row is None
            if is_new_task:
                connection.execute(
                    "INSERT INTO tasks "
                    "(namespace, task_id, team_id, issue_number, task_digest, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        task_id,
                        team_id,
                        issue_number,
                        task_digest,
                        now,
                    ),
                )
            elif (
                row["team_id"] != team_id
                or row["issue_number"] != issue_number
                or row["task_digest"] != task_digest
            ):
                raise StateConflictError("task binding conflicts with persisted state")

            persisted = {
                item["repo_slug"]: item["route_json"]
                for item in connection.execute(
                    "SELECT repo_slug, route_json FROM routes "
                    "WHERE namespace = ? AND task_id = ?",
                    (self.namespace, task_id),
                )
            }
            if persisted and persisted != routes:
                raise StateConflictError("route set conflicts with persisted state")
            if not persisted and not is_new_task:
                raise StateConflictError("persisted task is missing its route set")
            if is_new_task:
                connection.executemany(
                    "INSERT INTO routes "
                    "(namespace, task_id, repo_slug, route_json) VALUES (?, ?, ?, ?)",
                    (
                        (self.namespace, task_id, slug, route_json)
                        for slug, route_json in sorted(routes.items())
                    ),
                )

    @staticmethod
    def _validate_plan_source_state(task: Mapping[str, Any]) -> None:
        values = (
            task["plan_source_event_id"],
            task["plan_subject"],
            task["plan_payload_json"],
            task["plan_payload_digest"],
        )
        if all(value is None for value in values):
            return
        if any(value is None for value in values):
            raise StateConflictError("persisted plan source binding is incomplete")
        try:
            _required_text(task["plan_source_event_id"], "plan source event")
            _required_text(task["plan_subject"], "plan source subject")
        except ValueError as error:
            raise StateConflictError("persisted plan source binding is invalid") from error
        _decode_json(
            task["plan_payload_json"],
            "plan source payload",
            expected_digest=task["plan_payload_digest"],
        )

    def bind_task(
        self,
        task_id: str,
        team_id: str,
        issue_number: int,
        route_map: Mapping[str, Mapping[str, Any]],
        task_digest: str,
    ) -> None:
        """Compatibility name for :meth:`record_plan`."""

        self.record_plan(task_id, team_id, issue_number, route_map, task_digest)

    def record_plan_transition(
        self,
        task_id: str,
        team_id: str,
        issue_number: int,
        route_map: Mapping[str, Mapping[str, Any]],
        task_digest: str,
        *,
        source_event_id: str,
        subject: str,
        payload: Any,
    ) -> None:
        """Atomically bind plan ingress and enqueue every route event."""

        task_id = _required_text(task_id, "task_id")
        team_id = _required_text(team_id, "team_id")
        task_digest = _required_text(task_digest, "task_digest")
        source_event_id = _required_text(source_event_id, "source_event_id")
        subject = _required_text(subject, "subject")
        issue_number = _validated_issue_number(issue_number)
        if not isinstance(route_map, Mapping) or not route_map:
            raise ValueError("route_map must be a non-empty mapping")
        routes: dict[str, str] = {}
        route_events: dict[str, Mapping[str, Any]] = {}
        for slug, route in route_map.items():
            slug = _required_text(slug, "repo_slug")
            if not isinstance(route, Mapping):
                raise ValueError("each route must be a mapping")
            dispatch_event = route.get("dispatch_event")
            if not isinstance(dispatch_event, Mapping):
                raise ValueError("each plan route requires a dispatch_event")
            self._normalize_outbox_message(dispatch_event, f"route:{slug}")
            routes[slug] = _canonical_json(dict(route), f"route {slug}")
            route_events[slug] = dispatch_event
        payload_json = _canonical_json(payload, "plan source payload")
        with self._transaction() as connection:
            now = self._now()
            source_owner = connection.execute(
                "SELECT task_id FROM tasks WHERE namespace = ? "
                "AND plan_source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if source_owner is not None and source_owner["task_id"] != task_id:
                raise StateConflictError(
                    "plan source event is already bound to another task"
                )
            row = connection.execute(
                "SELECT task_id, team_id, issue_number, task_digest, "
                "plan_source_event_id, plan_subject, plan_payload_json, "
                "plan_payload_digest, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            is_new_task = row is None
            source_binding_is_new = is_new_task
            if is_new_task:
                connection.execute(
                    "INSERT INTO tasks (namespace, task_id, team_id, issue_number, "
                    "task_digest, plan_source_event_id, plan_subject, "
                    "plan_payload_json, plan_payload_digest, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        task_id,
                        team_id,
                        issue_number,
                        task_digest,
                        source_event_id,
                        subject,
                        payload_json,
                        _digest(payload_json),
                        now,
                    ),
                )
            else:
                if (
                    row["team_id"] != team_id
                    or row["issue_number"] != issue_number
                    or row["task_digest"] != task_digest
                ):
                    raise StateConflictError(
                        "task binding conflicts with persisted state"
                    )
                persisted_source = (
                    row["plan_source_event_id"],
                    row["plan_subject"],
                    row["plan_payload_json"],
                    row["plan_payload_digest"],
                )
                if all(value is None for value in persisted_source):
                    if row["completion_json"] is not None:
                        raise StateConflictError(
                            "terminal task cannot backfill a plan transition"
                        )
                    connection.execute(
                        "UPDATE tasks SET plan_source_event_id = ?, "
                        "plan_subject = ?, plan_payload_json = ?, "
                        "plan_payload_digest = ? WHERE namespace = ? "
                        "AND task_id = ?",
                        (
                            source_event_id,
                            subject,
                            payload_json,
                            _digest(payload_json),
                            self.namespace,
                            task_id,
                        ),
                    )
                    source_binding_is_new = True
                else:
                    if any(value is None for value in persisted_source):
                        raise StateConflictError(
                            "persisted plan source binding is incomplete"
                        )
                    _decode_json(
                        row["plan_payload_json"],
                        "plan source payload",
                        expected_digest=row["plan_payload_digest"],
                    )
                    if (
                        row["plan_source_event_id"] != source_event_id
                        or row["plan_subject"] != subject
                        or row["plan_payload_json"] != payload_json
                    ):
                        raise StateConflictError(
                            "plan redelivery conflicts with its persisted source"
                        )
            persisted_routes = {
                item["repo_slug"]: item["route_json"]
                for item in connection.execute(
                    "SELECT repo_slug, route_json FROM routes WHERE namespace = ? "
                    "AND task_id = ?",
                    (self.namespace, task_id),
                )
            }
            if persisted_routes and persisted_routes != routes:
                raise StateConflictError("route set conflicts with persisted state")
            if not persisted_routes and not is_new_task:
                raise StateConflictError("persisted task is missing its route set")
            if is_new_task:
                connection.executemany(
                    "INSERT INTO routes (namespace, task_id, repo_slug, route_json) "
                    "VALUES (?, ?, ?, ?)",
                    (
                        (self.namespace, task_id, slug, route_json)
                        for slug, route_json in sorted(routes.items())
                    ),
                )
            if not source_binding_is_new:
                actual_route_purposes = {
                    item["purpose"]
                    for item in connection.execute(
                        "SELECT purpose FROM outbox WHERE namespace = ? "
                        "AND task_id = ? AND purpose LIKE 'route:%'",
                        (self.namespace, task_id),
                    )
                }
                expected_route_purposes = {
                    f"route:{slug}" for slug in route_events
                }
                if actual_route_purposes != expected_route_purposes:
                    raise StateConflictError(
                        "plan route outbox set conflicts with persisted state"
                    )
            for slug, event in sorted(route_events.items()):
                self._insert_outbox(
                    connection,
                    task_id,
                    event,
                    f"route:{slug}",
                    requires_consumer_checkpoint=True,
                )
            if row is not None and row["completion_json"] is not None:
                self._validate_task_terminal_graph(connection, row)

    def _save_candidate_in_transaction(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        repo_slug: str,
        candidate: Mapping[str, Any],
    ) -> None:
        candidate_json = _canonical_json(dict(candidate), "candidate")
        candidate_digest = _digest(candidate_json)
        task = connection.execute(
            "SELECT completion_json FROM tasks WHERE namespace = ? AND task_id = ?",
            (self.namespace, task_id),
        ).fetchone()
        if task is None:
            raise StateConflictError("candidate has no exact task binding")
        route = connection.execute(
            "SELECT 1 FROM routes WHERE namespace = ? AND task_id = ? "
            "AND repo_slug = ?",
            (self.namespace, task_id, repo_slug),
        ).fetchone()
        if route is None:
            raise StateConflictError("candidate has no exact planned route")
        row = connection.execute(
            "SELECT candidate_json, candidate_digest FROM candidates WHERE namespace = ? "
            "AND task_id = ? AND repo_slug = ?",
            (self.namespace, task_id, repo_slug),
        ).fetchone()
        receipt = connection.execute(
            "SELECT 1 FROM receipts WHERE namespace = ? AND task_id = ? "
            "AND repo_slug = ?",
            (self.namespace, task_id, repo_slug),
        ).fetchone()
        if task["completion_json"] is not None and row is None:
            raise StateConflictError("terminal task cannot accept a late candidate")
        if receipt is not None and row is None:
            raise StateConflictError("receipt cannot be backfilled with a candidate")
        if row is None:
            connection.execute(
                "INSERT INTO candidates "
                "(namespace, task_id, repo_slug, candidate_json, "
                "candidate_digest, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                (
                    self.namespace,
                    task_id,
                    repo_slug,
                    candidate_json,
                    candidate_digest,
                    self._now(),
                ),
            )
        else:
            _decode_mapping(
                row["candidate_json"],
                "candidate",
                expected_digest=row["candidate_digest"],
            )
            if row["candidate_json"] != candidate_json:
                raise StateConflictError(
                    "candidate conflicts with persisted evidence"
                )

    def save_candidate(
        self,
        task_id: str,
        repo_slug: str,
        candidate: Mapping[str, Any],
    ) -> None:
        """Persist a reviewed candidate without overwriting prior evidence."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        if not isinstance(candidate, Mapping):
            raise ValueError("candidate must be a mapping")
        with self._transaction() as connection:
            self._save_candidate_in_transaction(
                connection, task_id, repo_slug, candidate
            )

    @staticmethod
    def _validate_candidate_source_state(row: Mapping[str, Any]) -> None:
        values = (
            row["source_message_id"],
            row["source_subject"],
            row["source_payload_json"],
            row["source_payload_digest"],
        )
        if all(value is None for value in values):
            return
        if any(value is None for value in values):
            raise StateConflictError(
                "persisted candidate source binding is incomplete"
            )
        try:
            _required_text(row["source_message_id"], "candidate source message")
            _required_text(row["source_subject"], "candidate source subject")
        except ValueError as error:
            raise StateConflictError(
                "persisted candidate source binding is invalid"
            ) from error
        _decode_json(
            row["source_payload_json"],
            "candidate source payload",
            expected_digest=row["source_payload_digest"],
        )

    def _validate_candidate_source_event(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        repo_slug: str,
        source_message_id: str,
        subject: str,
        payload_json: str,
        *,
        expected_checkpointed: bool | None = None,
    ) -> sqlite3.Row:
        source = connection.execute(
            "SELECT task_id, purpose, subject, payload_json, payload_digest, "
            "requires_consumer_checkpoint, consumer_checkpointed_at FROM outbox "
            "WHERE namespace = ? "
            "AND outbox_id = ?",
            (self.namespace, source_message_id),
        ).fetchone()
        if source is not None:
            _decode_json(
                source["payload_json"],
                "outbox payload",
                expected_digest=source["payload_digest"],
            )
        purpose = source["purpose"] if source is not None else None
        allowed_purpose = purpose == f"candidate:{repo_slug}" or (
            isinstance(purpose, str)
            and purpose.startswith(f"stage:{repo_slug}:review:")
        )
        if (
            source is None
            or source["task_id"] != task_id
            or not allowed_purpose
            or source["subject"] != subject
            or source["payload_json"] != payload_json
            or not bool(source["requires_consumer_checkpoint"])
        ):
            raise StateConflictError(
                "candidate source conflicts with the durable outbox"
            )
        if expected_checkpointed is not None and (
            (source["consumer_checkpointed_at"] is not None)
            != expected_checkpointed
        ):
            expected = "checkpointed" if expected_checkpointed else "pending"
            raise StateConflictError(
                f"candidate source is not in the expected {expected} state"
            )
        self._validate_consumer_source_exclusive(
            connection, source_message_id, "candidate"
        )
        return source

    def _validate_consumer_source_exclusive(
        self,
        connection: sqlite3.Connection,
        source_message_id: str,
        consumer: str,
    ) -> None:
        """Bind one control outbox message to exactly one consumer role."""

        if consumer == "candidate":
            conflict = connection.execute(
                "SELECT 1 FROM stage_runs WHERE namespace = ? "
                "AND source_message_id = ? LIMIT 1",
                (self.namespace, source_message_id),
            ).fetchone()
        elif consumer == "stage":
            conflict = connection.execute(
                "SELECT 1 FROM candidates WHERE namespace = ? "
                "AND source_message_id = ? LIMIT 1",
                (self.namespace, source_message_id),
            ).fetchone()
        else:
            raise ValueError("consumer must be candidate or stage")
        if conflict is not None:
            raise StateConflictError(
                "local source message is already bound to another consumer"
            )

    def inspect_candidate(
        self,
        task_id: str,
        repo_slug: str,
        *,
        source_message_id: str,
        subject: str,
        payload: Any,
    ) -> dict[str, Any] | None:
        """Validate an exact ship input without claiming or mutating it."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        source_message_id = _required_text(
            source_message_id, "source_message_id"
        )
        subject = _required_text(subject, "subject")
        source_payload_json = _canonical_json(payload, "candidate source payload")
        connection = self._connect()
        try:
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("candidate has no exact task binding")
            route = connection.execute(
                "SELECT 1 FROM routes WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if route is None:
                raise StateConflictError("candidate has no exact planned route")
            source = self._validate_candidate_source_event(
                connection,
                task_id,
                repo_slug,
                source_message_id,
                subject,
                source_payload_json,
            )
            row = connection.execute(
                "SELECT * FROM candidates WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if row is None:
                raise StateConflictError("reviewed candidate is not persisted")
            candidate = _decode_mapping(
                row["candidate_json"],
                "candidate",
                expected_digest=row["candidate_digest"],
            )
            _validate_fenced_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
                "candidate",
            )
            self._validate_candidate_source_state(row)
            if row["source_message_id"] is None:
                if task["completion_json"] is not None:
                    if (
                        row["completed_at"] is None
                        or source["consumer_checkpointed_at"] is None
                    ):
                        raise StateConflictError(
                            "terminal candidate source is not checkpointed"
                        )
                    terminal, _terminal_outbox = (
                        self._validate_task_terminal_graph(connection, task)
                    )
                    return {
                        "state": "terminal",
                        "terminal_status": task["terminal_status"],
                        "result": terminal,
                        "candidate": candidate,
                    }
                if row["completed_at"] is not None:
                    raise StateConflictError(
                        "completed candidate has no durable source binding"
                    )
                return None
            if (
                row["source_message_id"] != source_message_id
                or row["source_subject"] != subject
                or row["source_payload_json"] != source_payload_json
            ):
                raise StateConflictError(
                    "candidate redelivery conflicts with its persisted source"
                )
            if row["completed_at"] is None:
                if task["completion_json"] is not None:
                    raise StateConflictError(
                        "terminal task contains an unfinished candidate"
                    )
                if source["consumer_checkpointed_at"] is not None:
                    raise StateConflictError(
                        "pending candidate source is already checkpointed"
                    )
                return None
            if source["consumer_checkpointed_at"] is None:
                raise StateConflictError(
                    "completed candidate source is not checkpointed"
                )
            if task["completion_json"] is not None:
                terminal, _terminal_outbox = self._validate_task_terminal_graph(
                    connection, task
                )
                return {
                    "state": "terminal",
                    "terminal_status": task["terminal_status"],
                    "result": terminal,
                    "candidate": candidate,
                }
            receipt = connection.execute(
                "SELECT receipt_json, receipt_digest FROM receipts "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if receipt is None:
                raise StateConflictError(
                    "completed candidate has no durable receipt"
                )
            return {
                "state": "completed",
                "receipt": _decode_mapping(
                    receipt["receipt_json"],
                    "receipt",
                    expected_digest=receipt["receipt_digest"],
                ),
                "candidate": candidate,
            }
        finally:
            connection.close()

    def claim_candidate(
        self,
        task_id: str,
        repo_slug: str,
        *,
        owner: str,
        lease_seconds: float,
        source_message_id: str | None = None,
        subject: str | None = None,
        payload: Any = None,
    ) -> dict[str, Any] | None:
        """Lease a candidate with a generation-fenced, renewable claim."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        owner = _required_text(owner, "owner")
        if source_message_id is None:
            raise StateConflictError(
                "candidate claim requires an exact local source message"
            )
        source_message_id = _required_text(
            source_message_id, "source_message_id"
        )
        subject = _required_text(subject, "subject")
        source_payload_json = _canonical_json(payload, "candidate source payload")
        lease_seconds = _validated_lease_seconds(lease_seconds)
        _validate_retention_bounded_lease(
            lease_seconds, self.message_retention_seconds
        )
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("candidate has no exact task binding")
            if task["completion_json"] is not None:
                raise StateConflictError("terminal task cannot claim a candidate")
            self._validate_candidate_source_event(
                connection,
                task_id,
                repo_slug,
                source_message_id,
                subject,
                source_payload_json,
                expected_checkpointed=False,
            )
            row = connection.execute(
                "SELECT candidate_json, candidate_digest, claim_owner, "
                "claim_expires_at, claim_token, claim_generation, completed_at, "
                "source_message_id, source_subject, source_payload_json, "
                "source_payload_digest "
                "FROM candidates WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if row is None:
                raise StateConflictError("reviewed candidate is not persisted")
            _validate_fenced_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
                "candidate",
            )
            self._validate_candidate_source_state(row)
            if row["source_message_id"] is not None and (
                row["source_message_id"] != source_message_id
                or row["source_subject"] != subject
                or row["source_payload_json"] != source_payload_json
            ):
                raise StateConflictError(
                    "candidate redelivery conflicts with its persisted source"
                )
            if row["completed_at"] is not None:
                return None
            self._validate_stage_mutual_exclusion(
                connection, task_id, repo_slug
            )
            if (
                row["claim_owner"] is not None
                and row["claim_expires_at"] is not None
                and row["claim_expires_at"] > now
            ):
                return None
            claim_token = secrets.token_urlsafe(32)
            generation = row["claim_generation"] + 1
            connection.execute(
                "UPDATE candidates SET claim_owner = ?, claim_expires_at = ?, "
                "claim_token = ?, claim_generation = ?, source_message_id = ?, "
                "source_subject = ?, source_payload_json = ?, "
                "source_payload_digest = ? "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                (
                    owner,
                    expires,
                    claim_token,
                    generation,
                    source_message_id,
                    subject,
                    source_payload_json,
                    _digest(source_payload_json),
                    self.namespace,
                    task_id,
                    repo_slug,
                ),
            )
            return {
                "candidate": _decode_mapping(
                    row["candidate_json"],
                    "candidate",
                    expected_digest=row["candidate_digest"],
                ),
                "claim_token": claim_token,
                "claim_generation": generation,
                "lease_expires_at": expires,
                "source_message_id": source_message_id,
                "source_subject": subject,
                "source_payload": _decode_json(
                    source_payload_json, "candidate source payload"
                ),
            }

    def renew_claim(
        self,
        task_id: str,
        repo_slug: str,
        *,
        owner: str,
        claim_token: str,
        lease_seconds: float,
    ) -> bool:
        """Extend one live claim owned by the caller."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        lease_seconds = _validated_lease_seconds(lease_seconds)
        _validate_retention_bounded_lease(
            lease_seconds, self.message_retention_seconds
        )
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            row = connection.execute(
                "SELECT * FROM candidates "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if row is None:
                raise StateConflictError("reviewed candidate is not persisted")
            _validate_fenced_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
                "candidate",
            )
            self._validate_candidate_source_state(row)
            self._validate_candidate_source_event(
                connection,
                task_id,
                repo_slug,
                row["source_message_id"],
                row["source_subject"],
                row["source_payload_json"],
                expected_checkpointed=False,
            )
            cursor = connection.execute(
                "UPDATE candidates SET claim_expires_at = ? WHERE namespace = ? "
                "AND task_id = ? AND repo_slug = ? AND claim_owner = ? "
                "AND claim_token = ? AND claim_expires_at > ? "
                "AND completed_at IS NULL",
                (
                    expires,
                    self.namespace,
                    task_id,
                    repo_slug,
                    owner,
                    claim_token,
                    now,
                ),
            )
            return cursor.rowcount == 1

    def release_claim(
        self,
        task_id: str,
        repo_slug: str,
        *,
        owner: str,
        claim_token: str,
    ) -> bool:
        """Release only the caller's claim while retaining the candidate."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        with self._transaction() as connection:
            cursor = connection.execute(
                "UPDATE candidates SET claim_owner = NULL, claim_expires_at = NULL, "
                "claim_token = NULL "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ? "
                "AND claim_owner = ? AND claim_token = ? AND completed_at IS NULL",
                (self.namespace, task_id, repo_slug, owner, claim_token),
            )
            return cursor.rowcount == 1

    def _insert_outbox(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        message: Mapping[str, Any],
        purpose: str,
        *,
        requires_consumer_checkpoint: bool = False,
    ) -> str:
        if not isinstance(requires_consumer_checkpoint, bool):
            raise ValueError("requires_consumer_checkpoint must be boolean")
        if (
            purpose == "fan-in-ready"
            or purpose.startswith("route:")
            or purpose.startswith("candidate:")
            or purpose.startswith("stage:")
        ):
            requires_consumer_checkpoint = True
        subject, payload_json = self._normalize_outbox_message(message, purpose)
        outbox_id = _digest(f"{self.namespace}\0{task_id}\0{purpose}")
        row = connection.execute(
            "SELECT subject, payload_json, requires_consumer_checkpoint "
            "FROM outbox WHERE namespace = ? "
            "AND task_id = ? AND purpose = ?",
            (self.namespace, task_id, purpose),
        ).fetchone()
        if row is not None:
            if (
                row["subject"] != subject
                or row["payload_json"] != payload_json
                or bool(row["requires_consumer_checkpoint"])
                != requires_consumer_checkpoint
            ):
                raise StateConflictError("outbox event conflicts with persisted state")
            return outbox_id
        connection.execute(
            "INSERT INTO outbox "
            "(namespace, outbox_id, task_id, purpose, subject, payload_json, "
            "payload_digest, requires_consumer_checkpoint, created_at) "
            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
            (
                self.namespace,
                outbox_id,
                task_id,
                purpose,
                subject,
                payload_json,
                _digest(payload_json),
                int(requires_consumer_checkpoint),
                self._now(),
            ),
        )
        return outbox_id

    @staticmethod
    def _normalize_outbox_message(
        message: Mapping[str, Any], purpose: str
    ) -> tuple[str, str]:
        if not isinstance(message, Mapping):
            raise ValueError("outbox message must be a mapping")
        purpose = _required_text(purpose, "outbox purpose")
        if "purpose" in message and message["purpose"] != purpose:
            raise StateConflictError(
                "outbox message cannot override its trusted purpose"
            )
        subject = _required_text(message.get("subject"), "outbox subject")
        if "payload" not in message:
            raise ValueError("outbox message requires payload")
        payload_json = _canonical_json(message["payload"], "outbox payload")
        return subject, payload_json

    def _validate_task_terminal_graph(
        self,
        connection: sqlite3.Connection,
        task: Mapping[str, Any],
    ) -> tuple[dict[str, Any] | None, list[dict[str, Any]] | None]:
        task_id = _required_text(task["task_id"], "persisted task task_id")
        completion_json = task["completion_json"]
        completion_outbox_json = task["completion_outbox_json"]
        terminal_status = task["terminal_status"]
        completed_at = task["completed_at"]
        if completion_json is None:
            if (
                completion_outbox_json is not None
                or terminal_status is not None
                or completed_at is not None
            ):
                raise StateConflictError(
                    "persisted unfinished task contains terminal state"
                )
            return None, None
        if (
            completion_outbox_json is None
            or terminal_status not in {"completed", *_TERMINAL_FAILURE_STATES}
            or completed_at is None
        ):
            raise StateConflictError("persisted terminal task state is incomplete")
        completion = _decode_mapping(completion_json, "completion")
        events = _decode_json(completion_outbox_json, "completion outbox")
        if not isinstance(events, list) or not events:
            raise StateConflictError(
                "persisted terminal task requires an outbox event list"
            )
        expected_events: dict[str, tuple[str, str]] = {}
        prefix = "completion" if terminal_status == "completed" else (
            f"terminal:{terminal_status}"
        )
        for index, event in enumerate(events):
            if not isinstance(event, dict) or set(event) != {
                "purpose",
                "subject",
                "payload",
            }:
                raise StateConflictError(
                    "persisted terminal outbox event has an invalid schema"
                )
            purpose = f"{prefix}:{index}"
            if event["purpose"] != purpose:
                raise StateConflictError(
                    "persisted terminal outbox purpose is not sequential"
                )
            subject = _required_text(
                event["subject"], "persisted terminal outbox subject"
            )
            expected_events[purpose] = (
                subject,
                _canonical_json(event["payload"], "terminal outbox payload"),
            )
        actual = list(
            connection.execute(
                "SELECT purpose, subject, payload_json, payload_digest, "
                "requires_consumer_checkpoint FROM outbox WHERE namespace = ? "
                "AND task_id = ? AND (purpose LIKE 'completion:%' OR "
                "purpose LIKE 'terminal:%') ORDER BY purpose",
                (self.namespace, task_id),
            )
        )
        if {row["purpose"] for row in actual} != set(expected_events):
            raise StateConflictError(
                "persisted terminal outbox event set is inconsistent"
            )
        for row in actual:
            _decode_json(
                row["payload_json"],
                "outbox payload",
                expected_digest=row["payload_digest"],
            )
            expected_subject, expected_payload = expected_events[row["purpose"]]
            if (
                row["subject"] != expected_subject
                or row["payload_json"] != expected_payload
                or bool(row["requires_consumer_checkpoint"])
            ):
                raise StateConflictError(
                    "persisted terminal outbox event is inconsistent"
                )
        pending_stage = connection.execute(
            "SELECT 1 FROM stage_runs WHERE namespace = ? AND task_id = ? "
            "AND state = 'pending' LIMIT 1",
            (self.namespace, task_id),
        ).fetchone()
        if pending_stage is not None:
            raise StateConflictError("terminal task contains an unfinished stage")
        return completion, events

    def _normalize_completion(
        self,
        completion: Mapping[str, Any],
        outbox: Sequence[Mapping[str, Any]],
    ) -> tuple[str, list[dict[str, Any]], str]:
        if not isinstance(completion, Mapping):
            raise ValueError("completion must be a mapping")
        if not isinstance(outbox, Sequence) or isinstance(outbox, (str, bytes)):
            raise ValueError("outbox must be a sequence")
        if not outbox:
            raise StateConflictError("completion requires an atomic outbox event")
        completion_json = _canonical_json(dict(completion), "completion")
        normalized_events: list[dict[str, Any]] = []
        for index, message in enumerate(outbox):
            purpose = f"completion:{index}"
            subject, payload_json = self._normalize_outbox_message(
                message, purpose
            )
            normalized_events.append(
                {
                    "purpose": purpose,
                    "subject": subject,
                    "payload": _decode_json(payload_json, "outbox payload"),
                }
            )
        return (
            completion_json,
            normalized_events,
            _canonical_json(normalized_events, "completion outbox"),
        )

    def _validate_exact_fan_in(
        self,
        connection: sqlite3.Connection,
        task_id: str,
    ) -> tuple[list[str], list[str]]:
        expected = sorted(
            row["repo_slug"]
            for row in connection.execute(
                "SELECT repo_slug FROM routes WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            )
        )
        receipt_rows = list(
            connection.execute(
                "SELECT repo_slug, receipt_json, receipt_digest FROM receipts "
                "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug",
                (self.namespace, task_id),
            )
        )
        for row in receipt_rows:
            _decode_mapping(
                row["receipt_json"],
                "receipt",
                expected_digest=row["receipt_digest"],
            )
        received = [row["repo_slug"] for row in receipt_rows]
        if not expected or received != expected:
            raise StateConflictError("completion requires exact route fan-in")
        return expected, received

    def _insert_completion_in_transaction(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        completion_json: str,
        normalized_events: Sequence[Mapping[str, Any]],
        completion_outbox_json: str,
        now: float,
    ) -> str:
        existing = connection.execute(
            "SELECT 1 FROM outbox WHERE namespace = ? AND task_id = ? "
            "AND (purpose LIKE 'completion:%' OR purpose LIKE 'terminal:%') LIMIT 1",
            (self.namespace, task_id),
        ).fetchone()
        if existing is not None:
            raise StateConflictError("terminal outbox exists before completion")
        self._checkpoint_task_control_outbox(connection, task_id, now)
        first_outbox_id = ""
        for event in normalized_events:
            outbox_id = self._insert_outbox(
                connection,
                task_id,
                {"subject": event["subject"], "payload": event["payload"]},
                event["purpose"],
            )
            if not first_outbox_id:
                first_outbox_id = outbox_id
        cursor = connection.execute(
            "UPDATE tasks SET completion_json = ?, completion_outbox_json = ?, "
            "terminal_status = 'completed', completed_at = ? WHERE namespace = ? "
            "AND task_id = ? AND completion_json IS NULL",
            (
                completion_json,
                completion_outbox_json,
                now,
                self.namespace,
                task_id,
            ),
        )
        if cursor.rowcount != 1:
            raise StateConflictError("task changed during completion")
        return first_outbox_id

    def _checkpoint_task_control_outbox(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        now: float,
    ) -> None:
        rows = list(
            connection.execute(
                "SELECT outbox_id, payload_json, payload_digest, claim_owner, "
                "claim_expires_at, claim_token, claim_generation, "
                "requires_consumer_checkpoint, consumer_checkpointed_at, "
                "sent_at, rearm_at FROM outbox WHERE namespace = ? "
                "AND task_id = ? AND requires_consumer_checkpoint = 1",
                (self.namespace, task_id),
            )
        )
        for row in rows:
            _decode_json(
                row["payload_json"],
                "outbox payload",
                expected_digest=row["payload_digest"],
            )
            _validate_outbox_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
            )
            _validate_outbox_delivery_state(
                row["requires_consumer_checkpoint"],
                row["consumer_checkpointed_at"],
                row["sent_at"],
                row["rearm_at"],
                duplicate_window_seconds=self.duplicate_window_seconds,
                message_retention_seconds=self.message_retention_seconds,
            )
            cursor = connection.execute(
                "UPDATE outbox SET consumer_checkpointed_at = "
                "COALESCE(consumer_checkpointed_at, ?), rearm_at = NULL, "
                "claim_owner = NULL, claim_expires_at = NULL, claim_token = NULL "
                "WHERE namespace = ? AND outbox_id = ? "
                "AND requires_consumer_checkpoint = 1",
                (now, self.namespace, row["outbox_id"]),
            )
            if cursor.rowcount != 1:
                raise StateConflictError(
                    "task control checkpoint changed during terminal transition"
                )

    def enqueue_outbox(
        self,
        task_id: str,
        message: Mapping[str, Any],
        *,
        purpose: str,
        requires_consumer_checkpoint: bool = False,
    ) -> str:
        """Persist one deterministic event for retryable external publication."""

        task_id = _required_text(task_id, "task_id")
        purpose = _required_text(purpose, "outbox purpose")
        if (
            purpose == "fan-in-ready"
            or purpose.startswith("completion:")
            or purpose.startswith("terminal:")
            or purpose.startswith("stage:")
        ):
            raise StateConflictError("outbox purpose is reserved for an atomic transition")
        with self._transaction() as connection:
            task = connection.execute(
                "SELECT completion_json FROM tasks WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("outbox event has no exact task binding")
            if task["completion_json"] is not None:
                raise StateConflictError("terminal task cannot accept a late outbox event")
            return self._insert_outbox(
                connection,
                task_id,
                message,
                purpose,
                requires_consumer_checkpoint=requires_consumer_checkpoint,
            )

    def _validate_stage_scope(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
    ) -> None:
        if repo_slug == _ROOT_STAGE_REPO:
            if stage != _ROOT_STAGE_NAME or iteration != _ROOT_STAGE_ITERATION:
                raise StateConflictError(
                    "reserved root stage scope is valid only for ship-final iteration 0"
                )
            return
        route = connection.execute(
            "SELECT 1 FROM routes WHERE namespace = ? AND task_id = ? "
            "AND repo_slug = ?",
            (self.namespace, task_id, repo_slug),
        ).fetchone()
        if route is None:
            raise StateConflictError("stage has no exact planned route")

    def _validate_stage_mutual_exclusion(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        repo_slug: str,
    ) -> None:
        """Keep root integration and repository work from overlapping."""

        if repo_slug == _ROOT_STAGE_REPO:
            conflict = connection.execute(
                "SELECT 1 FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND state = 'pending' AND NOT (repo_slug = ? AND stage = ? "
                "AND iteration = ?) LIMIT 1",
                (
                    self.namespace,
                    task_id,
                    _ROOT_STAGE_REPO,
                    _ROOT_STAGE_NAME,
                    _ROOT_STAGE_ITERATION,
                ),
            ).fetchone()
            if conflict is not None:
                raise StateConflictError(
                    "root integration cannot overlap pending repository work"
                )
            return
        conflict = connection.execute(
            "SELECT 1 FROM stage_runs WHERE namespace = ? AND task_id = ? "
            "AND repo_slug = ? AND stage = ? AND iteration = ? "
            "AND state = 'pending' LIMIT 1",
            (
                self.namespace,
                task_id,
                _ROOT_STAGE_REPO,
                _ROOT_STAGE_NAME,
                _ROOT_STAGE_ITERATION,
            ),
        ).fetchone()
        if conflict is not None:
            raise StateConflictError(
                "repository work cannot start during root integration"
            )

    def _validate_stage_source_event(
        self,
        connection: sqlite3.Connection,
        row: Mapping[str, Any],
    ) -> None:
        source_message_id = row["source_message_id"]
        if source_message_id is None:
            return
        source = connection.execute(
            "SELECT task_id, purpose, subject, payload_json, payload_digest, "
            "requires_consumer_checkpoint, consumer_checkpointed_at FROM outbox "
            "WHERE namespace = ? "
            "AND outbox_id = ?",
            (self.namespace, source_message_id),
        ).fetchone()
        if source is not None:
            _decode_json(
                source["payload_json"],
                "outbox payload",
                expected_digest=source["payload_digest"],
            )
        if (
            source is None
            or source["task_id"] != row["task_id"]
            or not self._stage_source_purpose_matches(
                row["repo_slug"],
                row["stage"],
                row["iteration"],
                source["purpose"],
            )
            or source["subject"] != row["subject"]
            or source["payload_json"] != row["input_json"]
            or not bool(source["requires_consumer_checkpoint"])
            or (
                row["state"] == "pending"
                and source["consumer_checkpointed_at"] is not None
            )
            or (
                row["state"] != "pending"
                and source["consumer_checkpointed_at"] is None
            )
        ):
            raise StateConflictError(
                "stage source checkpoint conflicts with its durable binding"
            )
        self._validate_consumer_source_exclusive(
            connection, source_message_id, "stage"
        )

    def _checkpoint_stage_source(
        self,
        connection: sqlite3.Connection,
        row: Mapping[str, Any],
        now: float,
    ) -> None:
        source_message_id = row["source_message_id"]
        if source_message_id is None:
            return
        self._validate_stage_source_event(connection, row)
        cursor = connection.execute(
            "UPDATE outbox SET consumer_checkpointed_at = "
            "COALESCE(consumer_checkpointed_at, ?), rearm_at = NULL, "
            "claim_owner = NULL, claim_expires_at = NULL, claim_token = NULL "
            "WHERE namespace = ? AND outbox_id = ? "
            "AND task_id = ? AND subject = ? AND payload_json = ? "
            "AND requires_consumer_checkpoint = 1",
            (
                now,
                self.namespace,
                source_message_id,
                row["task_id"],
                row["subject"],
                row["input_json"],
            ),
        )
        if cursor.rowcount != 1:
            raise StateConflictError("stage source checkpoint changed during completion")

    @staticmethod
    def _stage_source_purpose_matches(
        repo_slug: str,
        stage: str,
        iteration: int,
        purpose: object,
    ) -> bool:
        if not isinstance(purpose, str):
            return False
        if repo_slug == _ROOT_STAGE_REPO:
            return (
                stage == _ROOT_STAGE_NAME
                and iteration == _ROOT_STAGE_ITERATION
                and purpose == "fan-in-ready"
            )
        if stage == "test":
            if iteration == 1:
                return purpose == f"route:{repo_slug}"
            return purpose == f"stage:{repo_slug}:review:{iteration - 1}"
        if stage == "implement":
            return purpose == f"stage:{repo_slug}:test:{iteration}"
        if stage == "review":
            return purpose == f"stage:{repo_slug}:implement:{iteration}"
        return False

    @staticmethod
    def _validate_stage_row(row: Mapping[str, Any]) -> tuple[Any, Any, Any | None]:
        try:
            for field in (
                "task_id",
                "repo_slug",
                "stage",
                "source_event_id",
                "subject",
            ):
                _required_text(row[field], f"persisted stage {field}")
            if row["source_message_id"] is not None:
                _required_text(
                    row["source_message_id"],
                    "persisted stage source_message_id",
                )
        except ValueError as error:
            raise StateConflictError("persisted stage identity is invalid") from error
        state = row["state"]
        if state not in {"pending", *_STAGE_TERMINAL_STATES}:
            raise StateConflictError("persisted stage state is invalid")
        if (
            isinstance(row["iteration"], bool)
            or not isinstance(row["iteration"], int)
            or row["iteration"] < 0
        ):
            raise StateConflictError("persisted stage iteration is invalid")
        payload = _decode_json(
            row["input_json"],
            "stage input",
            expected_digest=row["input_digest"],
        )
        intent = _decode_json(
            row["intent_json"],
            "stage intent",
            expected_digest=row["intent_digest"],
        )
        _validate_fenced_claim_state(
            row["claim_owner"],
            row["claim_expires_at"],
            row["claim_token"],
            row["claim_generation"],
            "stage",
        )
        if state == "pending":
            if (
                row["result_json"] is not None
                or row["result_digest"] is not None
                or row["output_outbox_id"] is not None
                or row["completed_at"] is not None
            ):
                raise StateConflictError(
                    "pending stage contains terminal checkpoint state"
                )
            result = None
        else:
            if (
                row["result_json"] is None
                or row["result_digest"] is None
                or row["output_outbox_id"] is None
                or row["completed_at"] is None
                or row["claim_owner"] is not None
                or row["claim_expires_at"] is not None
                or row["claim_token"] is not None
            ):
                raise StateConflictError(
                    "terminal stage checkpoint is incomplete"
                )
            result = _decode_json(
                row["result_json"],
                "stage result",
                expected_digest=row["result_digest"],
            )
        return payload, intent, result

    def _validate_stage_outbox(
        self,
        connection: sqlite3.Connection,
        row: Mapping[str, Any],
    ) -> None:
        if row["state"] == "pending":
            return
        outbox = connection.execute(
            "SELECT task_id, purpose, requires_consumer_checkpoint FROM outbox "
            "WHERE namespace = ? AND outbox_id = ?",
            (self.namespace, row["output_outbox_id"]),
        ).fetchone()
        if row["state"] == "succeeded":
            if row["repo_slug"] == _ROOT_STAGE_REPO:
                purpose_matches = (
                    outbox is not None
                    and outbox["purpose"] == "completion:0"
                    and not bool(outbox["requires_consumer_checkpoint"])
                )
            else:
                expected_stage_purpose = (
                    f"stage:{row['repo_slug']}:{row['stage']}:{row['iteration']}"
                )
                purpose_matches = (
                    outbox is not None
                    and outbox["purpose"] == expected_stage_purpose
                    and bool(outbox["requires_consumer_checkpoint"])
                )
        else:
            purpose_matches = (
                outbox is not None
                and outbox["purpose"] == f"terminal:{row['state']}:0"
            )
        if (
            outbox is None
            or outbox["task_id"] != row["task_id"]
            or not purpose_matches
        ):
            raise StateConflictError(
                "stage checkpoint points to an inconsistent outbox event"
            )
        if row["repo_slug"] == _ROOT_STAGE_REPO or row["state"] in (
            _TERMINAL_FAILURE_STATES
        ):
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, row["task_id"]),
            ).fetchone()
            if task is None:
                raise StateConflictError(
                    "terminal stage has no exact task binding"
                )
            self._validate_task_terminal_graph(connection, task)
            expected_status = (
                "completed" if row["repo_slug"] == _ROOT_STAGE_REPO else row["state"]
            )
            if task["terminal_status"] != expected_status:
                raise StateConflictError(
                    "stage status conflicts with its terminal task"
                )

    @staticmethod
    def _stage_result(row: Mapping[str, Any], result: Any) -> dict[str, Any]:
        return {
            "state": row["state"],
            "result": result,
            "outbox_id": row["output_outbox_id"],
        }

    def inspect_stage(
        self,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
        *,
        source_event_id: str,
        subject: str,
        payload: Any,
        source_message_id: str | None,
    ) -> dict[str, Any] | None:
        """Inspect one exact inbound stage without claiming or mutating it."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        stage = _required_text(stage, "stage")
        iteration = _validated_iteration(iteration)
        source_event_id = _required_text(source_event_id, "source_event_id")
        subject = _required_text(subject, "subject")
        if source_message_id is not None:
            source_message_id = _required_text(
                source_message_id, "source_message_id"
            )
        input_json = _canonical_json(payload, "stage input")
        connection = self._connect()
        try:
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("stage has no exact task binding")
            self._validate_stage_scope(
                connection, task_id, repo_slug, stage, iteration
            )
            row = connection.execute(
                "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ? AND stage = ? AND iteration = ?",
                (self.namespace, task_id, repo_slug, stage, iteration),
            ).fetchone()
            if row is None and source_message_id is None:
                raise StateConflictError(
                    "new stage requires an exact local source message"
                )
            source_owner = connection.execute(
                "SELECT task_id, repo_slug, stage, iteration FROM stage_runs "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if source_owner is not None and (
                source_owner["task_id"] != task_id
                or source_owner["repo_slug"] != repo_slug
                or source_owner["stage"] != stage
                or source_owner["iteration"] != iteration
            ):
                raise StateConflictError(
                    "source event is already bound to another stage"
                )
            local_source = None
            if source_message_id is not None:
                local_source = connection.execute(
                    "SELECT task_id, purpose, subject, payload_json, payload_digest, "
                    "requires_consumer_checkpoint, consumer_checkpointed_at "
                    "FROM outbox WHERE namespace = ? AND outbox_id = ?",
                    (self.namespace, source_message_id),
                ).fetchone()
                if local_source is not None:
                    _decode_json(
                        local_source["payload_json"],
                        "outbox payload",
                        expected_digest=local_source["payload_digest"],
                    )
                if (
                    local_source is None
                    or local_source["task_id"] != task_id
                    or not self._stage_source_purpose_matches(
                        repo_slug,
                        stage,
                        iteration,
                        local_source["purpose"],
                    )
                    or local_source["subject"] != subject
                    or local_source["payload_json"] != input_json
                    or not bool(local_source["requires_consumer_checkpoint"])
                ):
                    raise StateConflictError(
                        "source message conflicts with the durable outbox"
                    )
                self._validate_consumer_source_exclusive(
                    connection, source_message_id, "stage"
                )
            if row is None:
                if task["completion_json"] is None:
                    if (
                        local_source is not None
                        and local_source["consumer_checkpointed_at"] is not None
                    ):
                        raise StateConflictError(
                            "new stage source is already checkpointed"
                        )
                    return None
                terminal, _terminal_outbox = self._validate_task_terminal_graph(
                    connection, task
                )
                if (
                    local_source is None
                    or local_source["consumer_checkpointed_at"] is None
                ):
                    raise StateConflictError(
                        "terminal task has an uncheckpointed late control event"
                    )
                return {
                    "state": "terminal",
                    "terminal_status": task["terminal_status"],
                    "result": terminal,
                    "intent": None,
                    "outbox_id": None,
                }
            _persisted_payload, intent, result = self._validate_stage_row(row)
            self._validate_stage_source_event(connection, row)
            self._validate_stage_outbox(connection, row)
            if (
                row["source_event_id"] != source_event_id
                or row["source_message_id"] != source_message_id
                or row["subject"] != subject
                or row["input_json"] != input_json
            ):
                raise StateConflictError(
                    "stage redelivery conflicts with its persisted binding"
                )
            if row["state"] == "pending" and task["completion_json"] is not None:
                raise StateConflictError(
                    "terminal task contains an unfinished stage checkpoint"
                )
            return {
                "state": row["state"],
                "result": result,
                "intent": intent,
                "outbox_id": row["output_outbox_id"],
            }
        finally:
            connection.close()

    def claim_stage(
        self,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
        *,
        source_event_id: str,
        subject: str,
        payload: Any,
        owner: str,
        lease_seconds: float,
        source_message_id: str | None = None,
        intent: Any = None,
    ) -> dict[str, Any] | None:
        """Bind and lease one logical stage execution across redelivery.

        The stage key and source identity are both unique.  An exact completed
        redelivery returns its durable checkpoint, an active execution returns
        ``None``, and an expired execution receives a new fencing token.
        """

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        stage = _required_text(stage, "stage")
        iteration = _validated_iteration(iteration)
        source_event_id = _required_text(source_event_id, "source_event_id")
        subject = _required_text(subject, "subject")
        owner = _required_text(owner, "owner")
        if source_message_id is not None:
            source_message_id = _required_text(
                source_message_id, "source_message_id"
            )
        lease_seconds = _validated_lease_seconds(lease_seconds)
        _validate_retention_bounded_lease(
            lease_seconds, self.message_retention_seconds
        )
        input_json = _canonical_json(payload, "stage input")
        intent_json = _canonical_json(intent, "stage intent")
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("stage has no exact task binding")
            self._validate_stage_scope(
                connection, task_id, repo_slug, stage, iteration
            )
            row = connection.execute(
                "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ? AND stage = ? AND iteration = ?",
                (self.namespace, task_id, repo_slug, stage, iteration),
            ).fetchone()
            if row is None and source_message_id is None:
                raise StateConflictError(
                    "new stage requires an exact local source message"
                )
            source_owner = connection.execute(
                "SELECT task_id, repo_slug, stage, iteration FROM stage_runs "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if source_owner is not None and (
                source_owner["task_id"] != task_id
                or source_owner["repo_slug"] != repo_slug
                or source_owner["stage"] != stage
                or source_owner["iteration"] != iteration
            ):
                raise StateConflictError(
                    "source event is already bound to another stage"
                )
            source_message_owner = None
            if source_message_id is not None:
                source_message_owner = connection.execute(
                    "SELECT task_id, repo_slug, stage, iteration FROM stage_runs "
                    "WHERE namespace = ? AND source_message_id = ?",
                    (self.namespace, source_message_id),
                ).fetchone()
            if source_message_owner is not None and (
                source_message_owner["task_id"] != task_id
                or source_message_owner["repo_slug"] != repo_slug
                or source_message_owner["stage"] != stage
                or source_message_owner["iteration"] != iteration
            ):
                raise StateConflictError(
                    "local source message is already bound to another stage"
                )
            if source_message_id is not None:
                local_source = connection.execute(
                    "SELECT task_id, purpose, subject, payload_json, payload_digest, "
                    "requires_consumer_checkpoint, consumer_checkpointed_at "
                    "FROM outbox "
                    "WHERE namespace = ? AND outbox_id = ?",
                    (self.namespace, source_message_id),
                ).fetchone()
                if local_source is not None:
                    _decode_json(
                        local_source["payload_json"],
                        "outbox payload",
                        expected_digest=local_source["payload_digest"],
                    )
                if (
                    local_source is None
                    or local_source["task_id"] != task_id
                    or not self._stage_source_purpose_matches(
                        repo_slug,
                        stage,
                        iteration,
                        local_source["purpose"],
                    )
                    or local_source["subject"] != subject
                    or local_source["payload_json"] != input_json
                    or not bool(local_source["requires_consumer_checkpoint"])
                ):
                    raise StateConflictError(
                        "source message conflicts with the durable outbox"
                    )
                self._validate_consumer_source_exclusive(
                    connection, source_message_id, "stage"
                )
            if row is None:
                if task["completion_json"] is not None:
                    terminal, _terminal_outbox = (
                        self._validate_task_terminal_graph(connection, task)
                    )
                    if (
                        local_source is None
                        or local_source["consumer_checkpointed_at"] is None
                    ):
                        raise StateConflictError(
                            "terminal task has an uncheckpointed late control event"
                        )
                    return {
                        "state": "terminal",
                        "terminal_status": task["terminal_status"],
                        "result": terminal,
                        "outbox_id": None,
                    }
                if (
                    local_source is not None
                    and local_source["consumer_checkpointed_at"] is not None
                ):
                    raise StateConflictError(
                        "new stage source is already checkpointed"
                    )
                self._validate_stage_mutual_exclusion(
                    connection, task_id, repo_slug
                )
                claim_token = secrets.token_urlsafe(32)
                connection.execute(
                    "INSERT INTO stage_runs (namespace, task_id, repo_slug, "
                    "stage, iteration, source_event_id, source_message_id, "
                    "subject, input_json, input_digest, intent_json, "
                    "intent_digest, state, claim_owner, claim_expires_at, "
                    "claim_token, claim_generation, created_at) VALUES "
                    "(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?, ?, 1, ?)",
                    (
                        self.namespace,
                        task_id,
                        repo_slug,
                        stage,
                        iteration,
                        source_event_id,
                        source_message_id,
                        subject,
                        input_json,
                        _digest(input_json),
                        intent_json,
                        _digest(intent_json),
                        owner,
                        expires,
                        claim_token,
                        now,
                    ),
                )
                return {
                    "state": "claimed",
                    "claim_token": claim_token,
                    "claim_generation": 1,
                    "lease_expires_at": expires,
                }

            _payload, _intent, result = self._validate_stage_row(row)
            self._validate_stage_source_event(connection, row)
            self._validate_stage_outbox(connection, row)
            if (
                row["source_event_id"] != source_event_id
                or row["source_message_id"] != source_message_id
                or row["subject"] != subject
                or row["input_json"] != input_json
                or row["intent_json"] != intent_json
            ):
                raise StateConflictError(
                    "stage redelivery conflicts with its persisted binding"
                )
            if row["state"] != "pending":
                return self._stage_result(row, result)
            if task["completion_json"] is not None:
                raise StateConflictError(
                    "terminal task contains an unfinished stage checkpoint"
                )
            self._validate_stage_mutual_exclusion(
                connection, task_id, repo_slug
            )
            if (
                row["claim_owner"] is not None
                and row["claim_expires_at"] is not None
                and row["claim_expires_at"] > now
            ):
                return None
            claim_token = secrets.token_urlsafe(32)
            generation = row["claim_generation"] + 1
            cursor = connection.execute(
                "UPDATE stage_runs SET claim_owner = ?, claim_expires_at = ?, "
                "claim_token = ?, claim_generation = ? WHERE namespace = ? "
                "AND task_id = ? AND repo_slug = ? AND stage = ? "
                "AND iteration = ? AND state = 'pending'",
                (
                    owner,
                    expires,
                    claim_token,
                    generation,
                    self.namespace,
                    task_id,
                    repo_slug,
                    stage,
                    iteration,
                ),
            )
            if cursor.rowcount != 1:
                raise StateConflictError("stage claim changed during transaction")
            return {
                "state": "claimed",
                "claim_token": claim_token,
                "claim_generation": generation,
                "lease_expires_at": expires,
            }

    def renew_stage_claim(
        self,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
        *,
        owner: str,
        claim_token: str,
        lease_seconds: float,
    ) -> bool:
        """Renew only the live stage generation held by the caller."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        stage = _required_text(stage, "stage")
        iteration = _validated_iteration(iteration)
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        lease_seconds = _validated_lease_seconds(lease_seconds)
        _validate_retention_bounded_lease(
            lease_seconds, self.message_retention_seconds
        )
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            row = connection.execute(
                "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ? AND stage = ? AND iteration = ?",
                (self.namespace, task_id, repo_slug, stage, iteration),
            ).fetchone()
            if row is None:
                return False
            self._validate_stage_scope(
                connection, task_id, repo_slug, stage, iteration
            )
            self._validate_stage_row(row)
            self._validate_stage_source_event(connection, row)
            task = connection.execute(
                "SELECT completion_json FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("stage has no exact task binding")
            if task["completion_json"] is not None:
                raise StateConflictError(
                    "terminal task contains an unfinished stage checkpoint"
                )
            cursor = connection.execute(
                "UPDATE stage_runs SET claim_expires_at = ? WHERE namespace = ? "
                "AND task_id = ? AND repo_slug = ? AND stage = ? "
                "AND iteration = ? AND state = 'pending' AND claim_owner = ? "
                "AND claim_token = ? AND claim_expires_at > ?",
                (
                    expires,
                    self.namespace,
                    task_id,
                    repo_slug,
                    stage,
                    iteration,
                    owner,
                    claim_token,
                    now,
                ),
            )
            return cursor.rowcount == 1

    def release_stage_claim(
        self,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
        *,
        owner: str,
        claim_token: str,
    ) -> bool:
        """Release one exact stage generation without losing its input."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        stage = _required_text(stage, "stage")
        iteration = _validated_iteration(iteration)
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        with self._transaction() as connection:
            cursor = connection.execute(
                "UPDATE stage_runs SET claim_owner = NULL, "
                "claim_expires_at = NULL, claim_token = NULL "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ? "
                "AND stage = ? AND iteration = ? AND state = 'pending' "
                "AND claim_owner = ? AND claim_token = ?",
                (
                    self.namespace,
                    task_id,
                    repo_slug,
                    stage,
                    iteration,
                    owner,
                    claim_token,
                ),
            )
            return cursor.rowcount == 1

    def complete_stage(
        self,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
        *,
        owner: str,
        claim_token: str,
        result: Any,
        output: Mapping[str, Any],
        candidate: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Atomically checkpoint a stage and enqueue its next control event."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        stage = _required_text(stage, "stage")
        iteration = _validated_iteration(iteration)
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        if not isinstance(output, Mapping):
            raise ValueError("output must be an outbox message mapping")
        if candidate is not None and not isinstance(candidate, Mapping):
            raise ValueError("candidate must be a mapping")
        if repo_slug == _ROOT_STAGE_REPO:
            raise StateConflictError(
                "reserved root stage must use complete_root_stage"
            )
        result_json = _canonical_json(result, "stage result")
        purpose = f"stage:{repo_slug}:{stage}:{iteration}"
        with self._transaction() as connection:
            now = self._now()
            row = connection.execute(
                "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ? AND stage = ? AND iteration = ?",
                (self.namespace, task_id, repo_slug, stage, iteration),
            ).fetchone()
            if row is None:
                raise StateConflictError("stage is not durably claimed")
            _payload, _intent, persisted_result = self._validate_stage_row(row)
            self._validate_stage_outbox(connection, row)
            if row["state"] != "pending":
                expected_subject, expected_payload = self._normalize_outbox_message(
                    output, purpose
                )
                persisted_outbox = connection.execute(
                    "SELECT subject, payload_json, payload_digest, "
                    "requires_consumer_checkpoint FROM outbox "
                    "WHERE namespace = ? AND outbox_id = ?",
                    (self.namespace, row["output_outbox_id"]),
                ).fetchone()
                if persisted_outbox is not None:
                    _decode_json(
                        persisted_outbox["payload_json"],
                        "outbox payload",
                        expected_digest=persisted_outbox["payload_digest"],
                    )
                if (
                    row["state"] != "succeeded"
                    or row["result_json"] != result_json
                    or persisted_outbox is None
                    or persisted_outbox["subject"] != expected_subject
                    or persisted_outbox["payload_json"] != expected_payload
                    or not bool(
                        persisted_outbox["requires_consumer_checkpoint"]
                    )
                ):
                    raise StateConflictError(
                        "stage completion conflicts with persisted checkpoint"
                    )
                if candidate is not None:
                    candidate_json = _canonical_json(
                        dict(candidate), "candidate"
                    )
                    persisted_candidate = connection.execute(
                        "SELECT candidate_json, candidate_digest FROM candidates "
                        "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                        (self.namespace, task_id, repo_slug),
                    ).fetchone()
                    if persisted_candidate is not None:
                        _decode_mapping(
                            persisted_candidate["candidate_json"],
                            "candidate",
                            expected_digest=persisted_candidate[
                                "candidate_digest"
                            ],
                        )
                    if (
                        persisted_candidate is None
                        or persisted_candidate["candidate_json"]
                        != candidate_json
                    ):
                        raise StateConflictError(
                            "completed review is missing its exact candidate"
                        )
                return self._stage_result(row, persisted_result)
            if (
                row["claim_owner"] != owner
                or row["claim_token"] != claim_token
                or row["claim_expires_at"] is None
                or row["claim_expires_at"] <= now
            ):
                raise StateConflictError(
                    "stage completion requires a live fenced claim"
                )
            task = connection.execute(
                "SELECT completion_json FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None or task["completion_json"] is not None:
                raise StateConflictError(
                    "terminal or missing task cannot complete another stage"
                )
            if candidate is not None:
                self._save_candidate_in_transaction(
                    connection, task_id, repo_slug, candidate
                )
            outbox_id = self._insert_outbox(
                connection,
                task_id,
                output,
                purpose,
                requires_consumer_checkpoint=True,
            )
            self._checkpoint_stage_source(connection, row, now)
            cursor = connection.execute(
                "UPDATE stage_runs SET state = 'succeeded', result_json = ?, "
                "result_digest = ?, output_outbox_id = ?, claim_owner = NULL, "
                "claim_expires_at = NULL, claim_token = NULL, completed_at = ? "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ? "
                "AND stage = ? AND iteration = ? AND state = 'pending' "
                "AND claim_owner = ? AND claim_token = ? AND claim_expires_at > ?",
                (
                    result_json,
                    _digest(result_json),
                    outbox_id,
                    now,
                    self.namespace,
                    task_id,
                    repo_slug,
                    stage,
                    iteration,
                    owner,
                    claim_token,
                    now,
                ),
            )
            if cursor.rowcount != 1:
                raise StateConflictError("stage claim changed during completion")
            return {
                "state": "succeeded",
                "result": _decode_json(result_json, "stage result"),
                "outbox_id": outbox_id,
            }

    def complete_root_stage(
        self,
        task_id: str,
        *,
        owner: str,
        claim_token: str,
        result: Any,
        completion: Mapping[str, Any],
        outbox: Sequence[Mapping[str, Any]],
    ) -> dict[str, Any]:
        """Atomically checkpoint root integration and complete its task."""

        task_id = _required_text(task_id, "task_id")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        result_json = _canonical_json(result, "stage result")
        (
            completion_json,
            normalized_events,
            completion_outbox_json,
        ) = self._normalize_completion(completion, outbox)
        with self._transaction() as connection:
            now = self._now()
            row = connection.execute(
                "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ? AND stage = ? AND iteration = ?",
                (
                    self.namespace,
                    task_id,
                    _ROOT_STAGE_REPO,
                    _ROOT_STAGE_NAME,
                    _ROOT_STAGE_ITERATION,
                ),
            ).fetchone()
            if row is None:
                raise StateConflictError("root stage is not durably claimed")
            self._validate_stage_scope(
                connection,
                task_id,
                _ROOT_STAGE_REPO,
                _ROOT_STAGE_NAME,
                _ROOT_STAGE_ITERATION,
            )
            _payload, _intent, persisted_result = self._validate_stage_row(row)
            self._validate_stage_outbox(connection, row)
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("root stage has no exact task binding")
            if row["state"] != "pending":
                if (
                    row["state"] != "succeeded"
                    or row["result_json"] != result_json
                    or task["completion_json"] != completion_json
                    or task["completion_outbox_json"] != completion_outbox_json
                    or task["terminal_status"] != "completed"
                ):
                    raise StateConflictError(
                        "root completion conflicts with persisted checkpoint"
                    )
                self._validate_task_terminal_graph(connection, task)
                return self._stage_result(row, persisted_result)
            if task["completion_json"] is not None:
                raise StateConflictError(
                    "task completed before its root stage checkpoint"
                )
            if (
                row["claim_owner"] != owner
                or row["claim_token"] != claim_token
                or row["claim_expires_at"] is None
                or row["claim_expires_at"] <= now
            ):
                raise StateConflictError(
                    "root completion requires a live fenced claim"
                )
            self._validate_stage_mutual_exclusion(
                connection, task_id, _ROOT_STAGE_REPO
            )
            self._validate_exact_fan_in(connection, task_id)
            self._checkpoint_stage_source(connection, row, now)
            outbox_id = self._insert_completion_in_transaction(
                connection,
                task_id,
                completion_json,
                normalized_events,
                completion_outbox_json,
                now,
            )
            cursor = connection.execute(
                "UPDATE stage_runs SET state = 'succeeded', result_json = ?, "
                "result_digest = ?, output_outbox_id = ?, claim_owner = NULL, "
                "claim_expires_at = NULL, claim_token = NULL, completed_at = ? "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ? "
                "AND stage = ? AND iteration = ? AND state = 'pending' "
                "AND claim_owner = ? AND claim_token = ? AND claim_expires_at > ?",
                (
                    result_json,
                    _digest(result_json),
                    outbox_id,
                    now,
                    self.namespace,
                    task_id,
                    _ROOT_STAGE_REPO,
                    _ROOT_STAGE_NAME,
                    _ROOT_STAGE_ITERATION,
                    owner,
                    claim_token,
                    now,
                ),
            )
            if cursor.rowcount != 1:
                raise StateConflictError("root stage changed during completion")
            return {
                "state": "succeeded",
                "result": _decode_json(result_json, "stage result"),
                "outbox_id": outbox_id,
            }

    def recoverable_stages(self, *, limit: int = 100) -> list[dict[str, Any]]:
        """Return expired/unclaimed stage inputs for broker-independent recovery."""

        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            raise ValueError("limit must be a positive integer")
        now = self._now()
        connection = self._connect()
        try:
            rows = list(
                connection.execute(
                    "SELECT * FROM stage_runs WHERE namespace = ? "
                    "ORDER BY created_at, task_id, repo_slug, stage, iteration",
                    (self.namespace,),
                )
            )
            decoded: list[tuple[sqlite3.Row, Any, Any]] = []
            for row in rows:
                self._validate_stage_scope(
                    connection,
                    row["task_id"],
                    row["repo_slug"],
                    row["stage"],
                    row["iteration"],
                )
                payload, intent, _result = self._validate_stage_row(row)
                self._validate_stage_source_event(connection, row)
                self._validate_stage_outbox(connection, row)
                if row["state"] == "pending" and (
                    row["claim_owner"] is None
                    or row["claim_expires_at"] is None
                    or row["claim_expires_at"] <= now
                ):
                    decoded.append((row, payload, intent))
            return [
                {
                    "task_id": row["task_id"],
                    "repo_slug": row["repo_slug"],
                    "stage": row["stage"],
                    "iteration": row["iteration"],
                    "source_event_id": row["source_event_id"],
                    "source_message_id": row["source_message_id"],
                    "subject": row["subject"],
                    "payload": payload,
                    "intent": intent,
                }
                for row, payload, intent in decoded[:limit]
            ]
        finally:
            connection.close()

    def _checkpoint_candidate_source(
        self,
        connection: sqlite3.Connection,
        task_id: str,
        repo_slug: str,
        source_message_id: str,
        source_subject: str,
        source_payload_json: str,
        now: float,
    ) -> None:
        candidate = connection.execute(
            "SELECT source_message_id, source_subject, source_payload_json, "
            "source_payload_digest FROM candidates WHERE namespace = ? "
            "AND task_id = ? AND repo_slug = ?",
            (self.namespace, task_id, repo_slug),
        ).fetchone()
        if candidate is None:
            raise StateConflictError("candidate source has no persisted candidate")
        self._validate_candidate_source_state(candidate)
        if (
            candidate["source_message_id"] != source_message_id
            or candidate["source_subject"] != source_subject
            or candidate["source_payload_json"] != source_payload_json
        ):
            raise StateConflictError(
                "receipt source conflicts with the claimed candidate event"
            )
        self._validate_candidate_source_event(
            connection,
            task_id,
            repo_slug,
            source_message_id,
            source_subject,
            source_payload_json,
        )
        cursor = connection.execute(
            "UPDATE outbox SET consumer_checkpointed_at = "
            "COALESCE(consumer_checkpointed_at, ?), rearm_at = NULL, "
            "claim_owner = NULL, claim_expires_at = NULL, claim_token = NULL "
            "WHERE namespace = ? AND outbox_id = ? AND task_id = ? "
            "AND subject = ? AND payload_json = ? "
            "AND requires_consumer_checkpoint = 1",
            (
                now,
                self.namespace,
                source_message_id,
                task_id,
                source_subject,
                source_payload_json,
            ),
        )
        if cursor.rowcount != 1:
            raise StateConflictError(
                "candidate source checkpoint changed during receipt"
            )

    def record_receipt(
        self,
        task_id: str,
        repo_slug: str,
        receipt: Mapping[str, Any],
        *,
        owner: str | None = None,
        claim_token: str | None = None,
        source_message_id: str | None = None,
        source_subject: str | None = None,
        source_payload: Any = None,
        ready_outbox: Mapping[str, Any] | None = None,
    ) -> dict[str, Any]:
        """Atomically record a receipt, derive fan-in, and queue its ready event."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        if not isinstance(receipt, Mapping):
            raise ValueError("receipt must be a mapping")
        if owner is not None:
            owner = _required_text(owner, "owner")
            claim_token = _required_text(claim_token, "claim_token")
            if source_message_id is None or source_subject is None:
                raise StateConflictError(
                    "owned receipt requires its exact candidate source"
                )
            source_message_id = _required_text(
                source_message_id, "source_message_id"
            )
            source_subject = _required_text(source_subject, "source_subject")
            source_payload_json = _canonical_json(
                source_payload, "candidate source payload"
            )
        elif claim_token is not None:
            raise ValueError("claim_token requires owner")
        elif source_message_id is not None or source_subject is not None:
            raise ValueError("candidate source requires an owned receipt")
        else:
            source_payload_json = None
        receipt_json = _canonical_json(dict(receipt), "receipt")
        with self._transaction() as connection:
            now = self._now()
            task = connection.execute(
                "SELECT completion_json FROM tasks WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("receipt has no exact task binding")
            route = connection.execute(
                "SELECT 1 FROM routes WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if route is None:
                raise StateConflictError("receipt has no exact planned route")
            persisted = connection.execute(
                "SELECT receipt_json, receipt_digest FROM receipts WHERE namespace = ? "
                "AND task_id = ? AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            # An identical durable receipt is a completed idempotency record.
            # It remains valid after the original claim is cleared, which lets
            # JetStream redelivery reconcile a crash after the transaction.
            if persisted is not None:
                _decode_mapping(
                    persisted["receipt_json"],
                    "receipt",
                    expected_digest=persisted["receipt_digest"],
                )
                if persisted["receipt_json"] != receipt_json:
                    raise StateConflictError(
                        "receipt conflicts with persisted evidence"
                    )
            if task["completion_json"] is not None and persisted is None:
                raise StateConflictError("terminal task cannot accept a late receipt")
            candidate_exists = connection.execute(
                "SELECT 1 FROM candidates WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if owner is None and candidate_exists is not None:
                raise StateConflictError(
                    "persisted candidate receipt requires its exact owned source"
                )
            if persisted is None and owner is not None:
                candidate = connection.execute(
                    "SELECT claim_owner, claim_expires_at, claim_token, "
                    "claim_generation, completed_at FROM candidates "
                    "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                    (self.namespace, task_id, repo_slug),
                ).fetchone()
                if candidate is not None:
                    _validate_fenced_claim_state(
                        candidate["claim_owner"],
                        candidate["claim_expires_at"],
                        candidate["claim_token"],
                        candidate["claim_generation"],
                        "candidate",
                    )
                if (
                    candidate is None
                    or candidate["completed_at"] is not None
                    or candidate["claim_owner"] != owner
                    or candidate["claim_token"] != claim_token
                    or candidate["claim_expires_at"] is None
                    or candidate["claim_expires_at"] <= now
                ):
                    raise StateConflictError("receipt is not backed by a live owned claim")
            if owner is not None:
                self._checkpoint_candidate_source(
                    connection,
                    task_id,
                    repo_slug,
                    source_message_id,
                    source_subject,
                    source_payload_json,
                    now,
                )
            if persisted is None:
                connection.execute(
                    "INSERT INTO receipts "
                    "(namespace, task_id, repo_slug, receipt_json, receipt_digest, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        task_id,
                        repo_slug,
                        receipt_json,
                        _digest(receipt_json),
                        now,
                    ),
                )
            if task["completion_json"] is None:
                connection.execute(
                    "UPDATE candidates SET completed_at = COALESCE(completed_at, ?), "
                    "claim_owner = NULL, claim_expires_at = NULL, "
                    "claim_token = NULL "
                    "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                    (now, self.namespace, task_id, repo_slug),
                )
            expected = sorted(
                row["repo_slug"]
                for row in connection.execute(
                    "SELECT repo_slug FROM routes WHERE namespace = ? AND task_id = ?",
                    (self.namespace, task_id),
                )
            )
            received = sorted(
                row["repo_slug"]
                for row in connection.execute(
                    "SELECT repo_slug FROM receipts WHERE namespace = ? AND task_id = ?",
                    (self.namespace, task_id),
                )
            )
            ready = expected == received
            outbox_id = None
            if ready:
                if ready_outbox is None:
                    existing = connection.execute(
                        "SELECT outbox_id FROM outbox WHERE namespace = ? "
                        "AND task_id = ? AND purpose = 'fan-in-ready'",
                        (self.namespace, task_id),
                    ).fetchone()
                    if existing is None:
                        raise StateConflictError(
                            "fan-in became ready without an atomic outbox event"
                        )
                    outbox_id = existing["outbox_id"]
                else:
                    outbox_id = self._insert_outbox(
                        connection, task_id, ready_outbox, "fan-in-ready"
                    )
            return {
                "ready": ready,
                "expected_repos": expected,
                "received_repos": received,
                "outbox_id": outbox_id,
            }

    def record_receipt_and_complete_task(
        self,
        task_id: str,
        repo_slug: str,
        receipt: Mapping[str, Any],
        *,
        owner: str,
        claim_token: str | None,
        source_message_id: str,
        source_subject: str,
        source_payload: Any,
        completion: Mapping[str, Any],
        outbox: Sequence[Mapping[str, Any]],
    ) -> None:
        """Atomically consume one ship event, store its receipt, and complete."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        owner = _required_text(owner, "owner")
        if claim_token is not None:
            claim_token = _required_text(claim_token, "claim_token")
        source_message_id = _required_text(
            source_message_id, "source_message_id"
        )
        source_subject = _required_text(source_subject, "source_subject")
        if not isinstance(receipt, Mapping):
            raise ValueError("receipt must be a mapping")
        receipt_json = _canonical_json(dict(receipt), "receipt")
        source_payload_json = _canonical_json(
            source_payload, "candidate source payload"
        )
        (
            completion_json,
            normalized_events,
            completion_outbox_json,
        ) = self._normalize_completion(completion, outbox)
        with self._transaction() as connection:
            now = self._now()
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("receipt has no exact task binding")
            route = connection.execute(
                "SELECT 1 FROM routes WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if route is None:
                raise StateConflictError("receipt has no exact planned route")
            persisted = connection.execute(
                "SELECT receipt_json, receipt_digest FROM receipts WHERE namespace = ? "
                "AND task_id = ? AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if persisted is not None:
                _decode_mapping(
                    persisted["receipt_json"],
                    "receipt",
                    expected_digest=persisted["receipt_digest"],
                )
                if persisted["receipt_json"] != receipt_json:
                    raise StateConflictError(
                        "receipt conflicts with persisted evidence"
                    )
            if task["completion_json"] is not None:
                if persisted is None or (
                    task["completion_json"] != completion_json
                    or task["completion_outbox_json"] != completion_outbox_json
                    or task["terminal_status"] != "completed"
                ):
                    raise StateConflictError(
                        "receipt completion conflicts with persisted task state"
                    )
                self._checkpoint_candidate_source(
                    connection,
                    task_id,
                    repo_slug,
                    source_message_id,
                    source_subject,
                    source_payload_json,
                    now,
                )
                self._validate_task_terminal_graph(connection, task)
                return
            candidate = connection.execute(
                "SELECT claim_owner, claim_expires_at, claim_token, "
                "claim_generation, completed_at FROM candidates "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                (self.namespace, task_id, repo_slug),
            ).fetchone()
            if candidate is not None:
                _validate_fenced_claim_state(
                    candidate["claim_owner"],
                    candidate["claim_expires_at"],
                    candidate["claim_token"],
                    candidate["claim_generation"],
                    "candidate",
                )
            if persisted is None and (
                candidate is None
                or candidate["completed_at"] is not None
                or candidate["claim_owner"] != owner
                or candidate["claim_token"] != claim_token
                or candidate["claim_expires_at"] is None
                or candidate["claim_expires_at"] <= now
            ):
                raise StateConflictError(
                    "receipt is not backed by a live owned claim"
                )
            self._checkpoint_candidate_source(
                connection,
                task_id,
                repo_slug,
                source_message_id,
                source_subject,
                source_payload_json,
                now,
            )
            if persisted is None:
                connection.execute(
                    "INSERT INTO receipts (namespace, task_id, repo_slug, "
                    "receipt_json, receipt_digest, created_at) VALUES (?, ?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        task_id,
                        repo_slug,
                        receipt_json,
                        _digest(receipt_json),
                        now,
                    ),
                )
            connection.execute(
                "UPDATE candidates SET completed_at = COALESCE(completed_at, ?), "
                "claim_owner = NULL, claim_expires_at = NULL, claim_token = NULL "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ?",
                (now, self.namespace, task_id, repo_slug),
            )
            self._validate_exact_fan_in(connection, task_id)
            pending_stage = connection.execute(
                "SELECT 1 FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND state = 'pending' LIMIT 1",
                (self.namespace, task_id),
            ).fetchone()
            if pending_stage is not None:
                raise StateConflictError(
                    "pending stage prevents atomic receipt completion"
                )
            self._insert_completion_in_transaction(
                connection,
                task_id,
                completion_json,
                normalized_events,
                completion_outbox_json,
                now,
            )

    def complete_task(
        self,
        task_id: str,
        completion: Mapping[str, Any],
        *,
        outbox: Sequence[Mapping[str, Any]],
    ) -> None:
        """Atomically persist terminal evidence and its publication events."""

        task_id = _required_text(task_id, "task_id")
        (
            completion_json,
            normalized_events,
            completion_outbox_json,
        ) = self._normalize_completion(completion, outbox)
        with self._transaction() as connection:
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at "
                "FROM tasks "
                "WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("completion has no exact task binding")
            self._validate_exact_fan_in(connection, task_id)
            if task["completion_json"] is not None:
                if (
                    task["completion_json"] != completion_json
                    or task["completion_outbox_json"] != completion_outbox_json
                    or task["terminal_status"] != "completed"
                ):
                    raise StateConflictError(
                        "completion conflicts with persisted terminal state"
                    )
                self._validate_task_terminal_graph(connection, task)
                return
            pending_stage = connection.execute(
                "SELECT 1 FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND state = 'pending' LIMIT 1",
                (self.namespace, task_id),
            ).fetchone()
            if pending_stage is not None:
                raise StateConflictError(
                    "pending stage must complete through its atomic stage transition"
                )
            self._insert_completion_in_transaction(
                connection,
                task_id,
                completion_json,
                normalized_events,
                completion_outbox_json,
                self._now(),
            )

    def _reject_owned_candidate_claims(
        self,
        connection: sqlite3.Connection,
        task_id: str,
    ) -> None:
        candidates = list(
            connection.execute(
                "SELECT * FROM candidates WHERE namespace = ? AND task_id = ? "
                "AND completed_at IS NULL",
                (self.namespace, task_id),
            )
        )
        for candidate in candidates:
            _decode_mapping(
                candidate["candidate_json"],
                "candidate",
                expected_digest=candidate["candidate_digest"],
            )
            _validate_fenced_claim_state(
                candidate["claim_owner"],
                candidate["claim_expires_at"],
                candidate["claim_token"],
                candidate["claim_generation"],
                "candidate",
            )
            self._validate_candidate_source_state(candidate)
            if candidate["source_message_id"] is not None:
                self._validate_candidate_source_event(
                    connection,
                    task_id,
                    candidate["repo_slug"],
                    candidate["source_message_id"],
                    candidate["source_subject"],
                    candidate["source_payload_json"],
                    expected_checkpointed=False,
                )
            if candidate["claim_owner"] is not None:
                raise StateConflictError(
                    "task-wide termination conflicts with an owned candidate claim"
                )

    def terminate_task(
        self,
        task_id: str,
        *,
        status: str,
        terminal: Mapping[str, Any],
        outbox: Sequence[Mapping[str, Any]],
    ) -> None:
        """Atomically persist an honest failure/block and its notification."""

        task_id = _required_text(task_id, "task_id")
        status = _required_text(status, "status")
        if status not in _TERMINAL_FAILURE_STATES:
            raise ValueError("status must be failed or human-blocked")
        if not isinstance(terminal, Mapping):
            raise ValueError("terminal must be a mapping")
        if not isinstance(outbox, Sequence) or isinstance(outbox, (str, bytes)):
            raise ValueError("outbox must be a sequence")
        if not outbox:
            raise StateConflictError("terminal state requires an atomic outbox event")
        terminal_json = _canonical_json(dict(terminal), "terminal state")
        normalized_events: list[dict[str, Any]] = []
        for index, message in enumerate(outbox):
            purpose = f"terminal:{status}:{index}"
            subject, payload_json = self._normalize_outbox_message(
                message, purpose
            )
            normalized_events.append(
                {
                    "purpose": purpose,
                    "subject": subject,
                    "payload": _decode_json(payload_json, "outbox payload"),
                }
            )
        terminal_outbox_json = _canonical_json(
            normalized_events, "terminal outbox"
        )
        with self._transaction() as connection:
            task = connection.execute(
                "SELECT task_id, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks WHERE namespace = ? "
                "AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("terminal state has no exact task binding")
            if task["completion_json"] is not None:
                if (
                    task["completion_json"] != terminal_json
                    or task["completion_outbox_json"] != terminal_outbox_json
                    or task["terminal_status"] != status
                ):
                    raise StateConflictError(
                        "terminal state conflicts with persisted task state"
                    )
                self._validate_task_terminal_graph(connection, task)
                return
            pending_stage = connection.execute(
                "SELECT 1 FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND state = 'pending' LIMIT 1",
                (self.namespace, task_id),
            ).fetchone()
            if pending_stage is not None:
                raise StateConflictError(
                    "pending stage must terminate through terminate_stage"
                )
            now = self._now()
            self._reject_owned_candidate_claims(connection, task_id)
            existing = connection.execute(
                "SELECT 1 FROM outbox WHERE namespace = ? AND task_id = ? "
                "AND (purpose LIKE 'terminal:%' OR purpose LIKE 'completion:%') "
                "LIMIT 1",
                (self.namespace, task_id),
            ).fetchone()
            if existing is not None:
                raise StateConflictError("terminal outbox exists before task state")
            for index, message in enumerate(outbox):
                self._insert_outbox(
                    connection,
                    task_id,
                    message,
                    f"terminal:{status}:{index}",
                )
            self._checkpoint_task_control_outbox(connection, task_id, now)
            connection.execute(
                "UPDATE tasks SET completion_json = ?, completion_outbox_json = ?, "
                "terminal_status = ?, completed_at = ? WHERE namespace = ? "
                "AND task_id = ?",
                (
                    terminal_json,
                    terminal_outbox_json,
                    status,
                    now,
                    self.namespace,
                    task_id,
                ),
            )
            connection.execute(
                "UPDATE candidates SET completed_at = COALESCE(completed_at, ?), "
                "claim_owner = NULL, claim_expires_at = NULL, claim_token = NULL "
                "WHERE namespace = ? AND task_id = ? AND completed_at IS NULL",
                (now, self.namespace, task_id),
            )

    def terminate_stage(
        self,
        task_id: str,
        repo_slug: str,
        stage: str,
        iteration: int,
        *,
        owner: str,
        claim_token: str,
        status: str,
        result: Any,
        terminal: Mapping[str, Any],
        outbox: Sequence[Mapping[str, Any]],
    ) -> dict[str, Any]:
        """Atomically checkpoint a failed stage and terminate its task."""

        task_id = _required_text(task_id, "task_id")
        repo_slug = _required_text(repo_slug, "repo_slug")
        stage = _required_text(stage, "stage")
        iteration = _validated_iteration(iteration)
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        status = _required_text(status, "status")
        if status not in _TERMINAL_FAILURE_STATES:
            raise ValueError("status must be failed or human-blocked")
        if not isinstance(terminal, Mapping):
            raise ValueError("terminal must be a mapping")
        if not isinstance(outbox, Sequence) or isinstance(outbox, (str, bytes)):
            raise ValueError("outbox must be a sequence")
        if not outbox:
            raise StateConflictError("terminal stage requires an atomic outbox event")
        result_json = _canonical_json(result, "stage result")
        terminal_json = _canonical_json(dict(terminal), "terminal state")
        normalized_events: list[dict[str, Any]] = []
        for index, message in enumerate(outbox):
            purpose = f"terminal:{status}:{index}"
            subject, payload_json = self._normalize_outbox_message(
                message, purpose
            )
            normalized_events.append(
                {
                    "purpose": purpose,
                    "subject": subject,
                    "payload": _decode_json(payload_json, "outbox payload"),
                }
            )
        terminal_outbox_json = _canonical_json(
            normalized_events, "terminal outbox"
        )
        with self._transaction() as connection:
            now = self._now()
            row = connection.execute(
                "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                "AND repo_slug = ? AND stage = ? AND iteration = ?",
                (self.namespace, task_id, repo_slug, stage, iteration),
            ).fetchone()
            if row is None:
                raise StateConflictError("stage is not durably claimed")
            _payload, _intent, persisted_result = self._validate_stage_row(row)
            self._validate_stage_outbox(connection, row)
            task = connection.execute(
                "SELECT completion_json, completion_outbox_json, terminal_status "
                "FROM tasks WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                raise StateConflictError("terminal stage has no exact task binding")
            if row["state"] != "pending":
                if (
                    row["state"] != status
                    or row["result_json"] != result_json
                    or task["completion_json"] != terminal_json
                    or task["completion_outbox_json"] != terminal_outbox_json
                    or task["terminal_status"] != status
                ):
                    raise StateConflictError(
                        "terminal stage conflicts with persisted checkpoint"
                    )
                for event in normalized_events:
                    persisted_event = connection.execute(
                        "SELECT subject, payload_json, payload_digest FROM outbox "
                        "WHERE namespace = ? AND task_id = ? AND purpose = ?",
                        (self.namespace, task_id, event["purpose"]),
                    ).fetchone()
                    expected_payload = _canonical_json(
                        event["payload"], "outbox payload"
                    )
                    if persisted_event is not None:
                        _decode_json(
                            persisted_event["payload_json"],
                            "outbox payload",
                            expected_digest=persisted_event["payload_digest"],
                        )
                    if (
                        persisted_event is None
                        or persisted_event["subject"] != event["subject"]
                        or persisted_event["payload_json"] != expected_payload
                    ):
                        raise StateConflictError(
                            "terminal stage outbox is missing or inconsistent"
                        )
                return self._stage_result(row, persisted_result)
            if task["completion_json"] is not None:
                raise StateConflictError("task terminated before its stage checkpoint")
            if (
                row["claim_owner"] != owner
                or row["claim_token"] != claim_token
                or row["claim_expires_at"] is None
                or row["claim_expires_at"] <= now
            ):
                raise StateConflictError(
                    "terminal stage requires a live fenced claim"
                )
            pending_rows = list(
                connection.execute(
                    "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
                    "AND state = 'pending'",
                    (self.namespace, task_id),
                )
            )
            for pending_row in pending_rows:
                self._validate_stage_scope(
                    connection,
                    pending_row["task_id"],
                    pending_row["repo_slug"],
                    pending_row["stage"],
                    pending_row["iteration"],
                )
                self._validate_stage_row(pending_row)
                is_terminating_stage = (
                    pending_row["repo_slug"] == repo_slug
                    and pending_row["stage"] == stage
                    and pending_row["iteration"] == iteration
                    and pending_row["claim_owner"] == owner
                    and pending_row["claim_token"] == claim_token
                )
                if (
                    not is_terminating_stage
                    and pending_row["claim_owner"] is not None
                ):
                    raise StateConflictError(
                        "task-wide termination conflicts with an owned peer stage claim"
                    )
            self._reject_owned_candidate_claims(connection, task_id)
            existing_terminal = connection.execute(
                "SELECT 1 FROM outbox WHERE namespace = ? AND task_id = ? "
                "AND (purpose LIKE 'terminal:%' OR purpose LIKE 'completion:%') "
                "LIMIT 1",
                (self.namespace, task_id),
            ).fetchone()
            if existing_terminal is not None:
                raise StateConflictError(
                    "terminal outbox exists before stage termination"
                )
            outbox_ids = [
                self._insert_outbox(
                    connection,
                    task_id,
                    message,
                    f"terminal:{status}:{index}",
                )
                for index, message in enumerate(outbox)
            ]
            connection.execute(
                "UPDATE tasks SET completion_json = ?, completion_outbox_json = ?, "
                "terminal_status = ?, completed_at = ? WHERE namespace = ? "
                "AND task_id = ?",
                (
                    terminal_json,
                    terminal_outbox_json,
                    status,
                    now,
                    self.namespace,
                    task_id,
                ),
            )
            for pending_row in pending_rows:
                self._checkpoint_stage_source(connection, pending_row, now)
            self._checkpoint_task_control_outbox(connection, task_id, now)
            cursor = connection.execute(
                "UPDATE stage_runs SET state = ?, result_json = ?, "
                "result_digest = ?, output_outbox_id = ?, claim_owner = NULL, "
                "claim_expires_at = NULL, claim_token = NULL, completed_at = ? "
                "WHERE namespace = ? AND task_id = ? AND repo_slug = ? "
                "AND stage = ? AND iteration = ? AND state = 'pending' "
                "AND claim_owner = ? AND claim_token = ? AND claim_expires_at > ?",
                (
                    status,
                    result_json,
                    _digest(result_json),
                    outbox_ids[0],
                    now,
                    self.namespace,
                    task_id,
                    repo_slug,
                    stage,
                    iteration,
                    owner,
                    claim_token,
                    now,
                ),
            )
            if cursor.rowcount != 1:
                raise StateConflictError("stage claim changed during termination")
            peer_result_json = _canonical_json(
                {
                    "reason": "task terminated by another stage",
                    "status": status,
                    "terminal_stage": {
                        "iteration": iteration,
                        "repo_slug": repo_slug,
                        "stage": stage,
                    },
                },
                "peer terminal stage result",
            )
            connection.execute(
                "UPDATE stage_runs SET state = ?, result_json = ?, "
                "result_digest = ?, output_outbox_id = ?, claim_owner = NULL, "
                "claim_expires_at = NULL, claim_token = NULL, completed_at = ? "
                "WHERE namespace = ? AND task_id = ? AND state = 'pending'",
                (
                    status,
                    peer_result_json,
                    _digest(peer_result_json),
                    outbox_ids[0],
                    now,
                    self.namespace,
                    task_id,
                ),
            )
            connection.execute(
                "UPDATE candidates SET completed_at = COALESCE(completed_at, ?), "
                "claim_owner = NULL, claim_expires_at = NULL, claim_token = NULL "
                "WHERE namespace = ? AND task_id = ? AND completed_at IS NULL",
                (now, self.namespace, task_id),
            )
            return {
                "state": status,
                "result": _decode_json(result_json, "stage result"),
                "outbox_id": outbox_ids[0],
            }

    def load_task(self, task_id: str) -> dict[str, Any] | None:
        """Load one task and all durable child state after a restart."""

        task_id = _required_text(task_id, "task_id")
        connection = self._connect()
        try:
            task = connection.execute(
                "SELECT task_id, team_id, issue_number, task_digest, "
                "plan_source_event_id, plan_subject, plan_payload_json, "
                "plan_payload_digest, completion_json, completion_outbox_json, "
                "terminal_status, completed_at FROM tasks "
                "WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            if task is None:
                return None
            self._validate_plan_source_state(task)
            completion, completion_outbox = self._validate_task_terminal_graph(
                connection, task
            )
            routes = {
                row["repo_slug"]: _decode_json(row["route_json"], "route")
                for row in connection.execute(
                    "SELECT repo_slug, route_json FROM routes WHERE namespace = ? "
                    "AND task_id = ? ORDER BY repo_slug",
                    (self.namespace, task_id),
                )
            }
            candidates = {
                row["repo_slug"]: _decode_mapping(
                    row["candidate_json"],
                    "candidate",
                    expected_digest=row["candidate_digest"],
                )
                for row in connection.execute(
                    "SELECT repo_slug, candidate_json, candidate_digest FROM candidates "
                    "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug",
                    (self.namespace, task_id),
                )
            }
            receipts = {
                row["repo_slug"]: _decode_mapping(
                    row["receipt_json"],
                    "receipt",
                    expected_digest=row["receipt_digest"],
                )
                for row in connection.execute(
                    "SELECT repo_slug, receipt_json, receipt_digest FROM receipts "
                    "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug",
                    (self.namespace, task_id),
                )
            }
            claim_rows = list(
                connection.execute(
                    "SELECT repo_slug, claim_owner, claim_expires_at, claim_token, "
                    "claim_generation, source_message_id, source_subject, "
                    "source_payload_json, source_payload_digest FROM candidates "
                    "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug",
                    (self.namespace, task_id),
                )
            )
            for claim_row in claim_rows:
                self._validate_candidate_source_state(claim_row)
                if claim_row["source_message_id"] is not None:
                    self._validate_candidate_source_event(
                        connection,
                        task_id,
                        claim_row["repo_slug"],
                        claim_row["source_message_id"],
                        claim_row["source_subject"],
                        claim_row["source_payload_json"],
                    )
                _validate_fenced_claim_state(
                    claim_row["claim_owner"],
                    claim_row["claim_expires_at"],
                    claim_row["claim_token"],
                    claim_row["claim_generation"],
                    "candidate",
                )
            claims = {
                row["repo_slug"]: {
                    "owner": row["claim_owner"],
                    "expires_at": row["claim_expires_at"],
                    "generation": row["claim_generation"],
                }
                for row in claim_rows
                if row["claim_owner"] is not None
            }
            return {
                "task_id": task_id,
                "team_id": task["team_id"],
                "issue_number": task["issue_number"],
                "task_digest": task["task_digest"],
                "routes": routes,
                "candidates": candidates,
                "claims": claims,
                "receipts": receipts,
                "completion": completion,
                "completion_outbox": completion_outbox,
                "terminal_status": task["terminal_status"],
                "completed_at": task["completed_at"],
            }
        finally:
            connection.close()

    def pending_outbox(self, *, limit: int = 100) -> list[dict[str, Any]]:
        """Return events due for first publish or checkpoint-safe rearming."""

        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            raise ValueError("limit must be a positive integer")
        now = self._now()
        connection = self._connect()
        try:
            rows = list(
                connection.execute(
                    "SELECT outbox_id, task_id, purpose, subject, payload_json, "
                    "payload_digest, attempts, created_at, sent_at, "
                    "requires_consumer_checkpoint, consumer_checkpointed_at, "
                    "rearm_at FROM outbox WHERE namespace = ? AND "
                    "consumer_checkpointed_at IS NULL AND (sent_at IS NULL OR "
                    "(requires_consumer_checkpoint = 1 AND rearm_at IS NOT NULL "
                    "AND rearm_at <= ?)) ORDER BY created_at, outbox_id LIMIT ?",
                    (self.namespace, now, limit),
                )
            )
            pending = []
            for row in rows:
                _validate_outbox_delivery_state(
                    row["requires_consumer_checkpoint"],
                    row["consumer_checkpointed_at"],
                    row["sent_at"],
                    row["rearm_at"],
                    duplicate_window_seconds=self.duplicate_window_seconds,
                    message_retention_seconds=self.message_retention_seconds,
                )
                pending.append(
                    {
                        "id": row["outbox_id"],
                        "task_id": row["task_id"],
                        "purpose": row["purpose"],
                        "subject": row["subject"],
                        "payload": _decode_json(
                            row["payload_json"],
                            "outbox payload",
                            expected_digest=row["payload_digest"],
                        ),
                        "attempts": row["attempts"],
                        "created_at": row["created_at"],
                        "broker_acked_at": row["sent_at"],
                        "requires_consumer_checkpoint": bool(
                            row["requires_consumer_checkpoint"]
                        ),
                    }
                )
            return pending
        finally:
            connection.close()

    def claim_outbox(
        self,
        *,
        owner: str,
        lease_seconds: float,
        limit: int = 1,
    ) -> list[dict[str, Any]]:
        """Atomically lease unsent events so only one publisher dispatches them."""

        owner = _required_text(owner, "owner")
        lease_seconds = _validated_lease_seconds(lease_seconds)
        _validate_retention_bounded_lease(
            lease_seconds, self.message_retention_seconds
        )
        if isinstance(limit, bool) or not isinstance(limit, int) or limit <= 0:
            raise ValueError("limit must be a positive integer")
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            for state in connection.execute(
                "SELECT claim_owner, claim_expires_at, claim_token, "
                "claim_generation, requires_consumer_checkpoint, "
                "consumer_checkpointed_at, sent_at, rearm_at FROM outbox "
                "WHERE namespace = ?",
                (self.namespace,),
            ):
                _validate_outbox_claim_state(
                    state["claim_owner"],
                    state["claim_expires_at"],
                    state["claim_token"],
                    state["claim_generation"],
                )
                _validate_outbox_delivery_state(
                    state["requires_consumer_checkpoint"],
                    state["consumer_checkpointed_at"],
                    state["sent_at"],
                    state["rearm_at"],
                    duplicate_window_seconds=self.duplicate_window_seconds,
                    message_retention_seconds=self.message_retention_seconds,
                )
            rows = list(
                connection.execute(
                    "SELECT outbox_id, task_id, purpose, subject, payload_json, "
                    "payload_digest, attempts, created_at, claim_generation "
                    "FROM outbox "
                    "WHERE namespace = ? AND consumer_checkpointed_at IS NULL "
                    "AND (sent_at IS NULL OR (requires_consumer_checkpoint = 1 "
                    "AND rearm_at IS NOT NULL AND rearm_at <= ?)) AND "
                    "((claim_owner IS NULL AND claim_expires_at IS NULL AND "
                    "claim_token IS NULL) OR claim_expires_at <= ?) "
                    "ORDER BY created_at, outbox_id LIMIT ?",
                    (self.namespace, now, now, limit),
                )
            )
            claimed = []
            for row in rows:
                payload = _decode_json(
                    row["payload_json"],
                    "outbox payload",
                    expected_digest=row["payload_digest"],
                )
                claim_token = secrets.token_urlsafe(32)
                generation = row["claim_generation"] + 1
                cursor = connection.execute(
                    "UPDATE outbox SET claim_owner = ?, claim_expires_at = ?, "
                    "claim_token = ?, claim_generation = ? WHERE namespace = ? "
                    "AND outbox_id = ? AND consumer_checkpointed_at IS NULL AND "
                    "(sent_at IS NULL OR (requires_consumer_checkpoint = 1 "
                    "AND rearm_at IS NOT NULL AND rearm_at <= ?)) AND "
                    "((claim_owner IS NULL AND claim_expires_at IS NULL AND "
                    "claim_token IS NULL) OR claim_expires_at <= ?)",
                    (
                        owner,
                        expires,
                        claim_token,
                        generation,
                        self.namespace,
                        row["outbox_id"],
                        now,
                        now,
                    ),
                )
                if cursor.rowcount != 1:
                    raise StateConflictError("outbox claim changed during transaction")
                claimed.append(
                    {
                        "id": row["outbox_id"],
                        "task_id": row["task_id"],
                        "purpose": row["purpose"],
                        "subject": row["subject"],
                        "payload": payload,
                        "attempts": row["attempts"],
                        "created_at": row["created_at"],
                        "lease_expires_at": expires,
                        "claim_token": claim_token,
                        "claim_generation": generation,
                    }
                )
            return claimed

    def renew_outbox_claim(
        self,
        outbox_id: str,
        *,
        owner: str,
        claim_token: str,
        lease_seconds: float,
    ) -> bool:
        """Extend a live outbox publication claim owned by the caller."""

        outbox_id = _required_text(outbox_id, "outbox_id")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        lease_seconds = _validated_lease_seconds(lease_seconds)
        _validate_retention_bounded_lease(
            lease_seconds, self.message_retention_seconds
        )
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            row = connection.execute(
                "SELECT claim_owner, claim_expires_at, claim_token, "
                "claim_generation FROM outbox "
                "WHERE namespace = ? AND outbox_id = ? "
                "AND consumer_checkpointed_at IS NULL",
                (self.namespace, outbox_id),
            ).fetchone()
            if row is None:
                return False
            _validate_outbox_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
            )
            cursor = connection.execute(
                "UPDATE outbox SET claim_expires_at = ? WHERE namespace = ? "
                "AND outbox_id = ? AND consumer_checkpointed_at IS NULL "
                "AND claim_owner = ? "
                "AND claim_token = ? AND claim_expires_at > ?",
                (
                    expires,
                    self.namespace,
                    outbox_id,
                    owner,
                    claim_token,
                    now,
                ),
            )
            return cursor.rowcount == 1

    def release_outbox_claim(
        self,
        outbox_id: str,
        *,
        owner: str,
        claim_token: str,
    ) -> bool:
        """Release one unsent event while retaining it for another publisher."""

        outbox_id = _required_text(outbox_id, "outbox_id")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT claim_owner, claim_expires_at, claim_token, "
                "claim_generation FROM outbox "
                "WHERE namespace = ? AND outbox_id = ? "
                "AND consumer_checkpointed_at IS NULL",
                (self.namespace, outbox_id),
            ).fetchone()
            if row is None:
                return False
            _validate_outbox_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
            )
            cursor = connection.execute(
                "UPDATE outbox SET claim_owner = NULL, claim_expires_at = NULL, "
                "claim_token = NULL "
                "WHERE namespace = ? AND outbox_id = ? "
                "AND consumer_checkpointed_at IS NULL "
                "AND claim_owner = ? AND claim_token = ?",
                (self.namespace, outbox_id, owner, claim_token),
            )
            return cursor.rowcount == 1

    def record_outbox_attempt(
        self,
        outbox_id: str,
        *,
        owner: str,
        claim_token: str,
    ) -> bool:
        """Record an attempted publish without losing an unsent event."""

        outbox_id = _required_text(outbox_id, "outbox_id")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        with self._transaction() as connection:
            now = self._now()
            row = connection.execute(
                "SELECT claim_owner, claim_expires_at, claim_token, "
                "claim_generation FROM outbox "
                "WHERE namespace = ? AND outbox_id = ? "
                "AND consumer_checkpointed_at IS NULL",
                (self.namespace, outbox_id),
            ).fetchone()
            if row is None:
                raise StateConflictError("outbox event is not pending")
            _validate_outbox_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
            )
            cursor = connection.execute(
                "UPDATE outbox SET attempts = attempts + 1 WHERE namespace = ? "
                "AND outbox_id = ? AND consumer_checkpointed_at IS NULL "
                "AND claim_owner = ? "
                "AND claim_token = ? AND claim_expires_at > ?",
                (self.namespace, outbox_id, owner, claim_token, now),
            )
            if cursor.rowcount != 1:
                raise StateConflictError("outbox attempt requires a live owned claim")
            return True

    def mark_outbox_sent(
        self,
        outbox_id: str,
        *,
        owner: str,
        claim_token: str,
    ) -> bool:
        """Mark one published event sent; repeated acknowledgement is harmless."""

        outbox_id = _required_text(outbox_id, "outbox_id")
        owner = _required_text(owner, "owner")
        claim_token = _required_text(claim_token, "claim_token")
        with self._transaction() as connection:
            now = self._now()
            row = connection.execute(
                "SELECT sent_at, sent_by, sent_claim_token, claim_owner, "
                "claim_expires_at, claim_token, claim_generation, "
                "requires_consumer_checkpoint, consumer_checkpointed_at, "
                "rearm_at FROM outbox "
                "WHERE namespace = ? AND outbox_id = ?",
                (self.namespace, outbox_id),
            ).fetchone()
            if row is None:
                raise StateConflictError("outbox event is not persisted")
            _validate_outbox_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
            )
            _validate_outbox_delivery_state(
                row["requires_consumer_checkpoint"],
                row["consumer_checkpointed_at"],
                row["sent_at"],
                row["rearm_at"],
                duplicate_window_seconds=self.duplicate_window_seconds,
                message_retention_seconds=self.message_retention_seconds,
            )
            if row["consumer_checkpointed_at"] is not None:
                return False
            if row["sent_at"] is not None and row["claim_owner"] is None:
                if (
                    row["sent_by"] != owner
                    or row["sent_claim_token"] != claim_token
                ):
                    raise StateConflictError(
                        "outbox event was completed by a different publisher"
                    )
                return False
            if (
                row["claim_owner"] != owner
                or row["claim_token"] != claim_token
                or row["claim_expires_at"] is None
                or row["claim_expires_at"] <= now
            ):
                raise StateConflictError("outbox completion requires a live owned claim")
            rearm_at = None
            if (
                bool(row["requires_consumer_checkpoint"])
                and row["consumer_checkpointed_at"] is None
            ):
                rearm_at = _lease_deadline(
                    now, self.outbox_rearm_seconds
                )
            cursor = connection.execute(
                "UPDATE outbox SET sent_at = ?, sent_by = ?, sent_claim_token = ?, "
                "rearm_at = ?, claim_owner = NULL, claim_expires_at = NULL, "
                "claim_token = NULL WHERE namespace = ? AND outbox_id = ? "
                "AND claim_owner = ? AND claim_token = ? AND claim_expires_at > ?",
                (
                    now,
                    owner,
                    claim_token,
                    rearm_at,
                    self.namespace,
                    outbox_id,
                    owner,
                    claim_token,
                    now,
                ),
            )
            return cursor.rowcount == 1

    def reconcile(self) -> dict[str, Any]:
        """Describe recoverable work without mutating or claiming it."""

        now = self._now()
        connection = self._connect()
        try:
            task_rows = list(
                connection.execute(
                    "SELECT task_id, plan_source_event_id, plan_subject, "
                    "plan_payload_json, plan_payload_digest, completion_json, "
                    "completion_outbox_json, terminal_status, completed_at FROM tasks "
                    "WHERE namespace = ? ORDER BY task_id",
                    (self.namespace,),
                )
            )
            unfinished_tasks = []
            for row in task_rows:
                self._validate_plan_source_state(row)
                self._validate_task_terminal_graph(connection, row)
                if row["completion_json"] is None:
                    unfinished_tasks.append(row["task_id"])
            unfinished_task_ids = set(unfinished_tasks)

            candidate_rows = list(
                connection.execute(
                    "SELECT task_id, repo_slug, candidate_json, candidate_digest, "
                    "claim_owner, claim_expires_at, claim_token, "
                    "claim_generation, completed_at, source_message_id, "
                    "source_subject, source_payload_json, source_payload_digest "
                    "FROM candidates "
                    "WHERE namespace = ? ORDER BY task_id, repo_slug",
                    (self.namespace,),
                )
            )
            claimable = []
            for row in candidate_rows:
                self._validate_candidate_source_state(row)
                if row["source_message_id"] is not None:
                    self._validate_candidate_source_event(
                        connection,
                        row["task_id"],
                        row["repo_slug"],
                        row["source_message_id"],
                        row["source_subject"],
                        row["source_payload_json"],
                    )
                _decode_mapping(
                    row["candidate_json"],
                    "candidate",
                    expected_digest=row["candidate_digest"],
                )
                _validate_fenced_claim_state(
                    row["claim_owner"],
                    row["claim_expires_at"],
                    row["claim_token"],
                    row["claim_generation"],
                    "candidate",
                )
                if (
                    row["task_id"] in unfinished_task_ids
                    and row["completed_at"] is None
                    and (
                    row["claim_owner"] is None
                    or row["claim_expires_at"] is None
                    or row["claim_expires_at"] <= now
                    )
                ):
                    claimable.append(
                        {
                            "task_id": row["task_id"],
                            "repo_slug": row["repo_slug"],
                        }
                    )

            awaiting_consumer_checkpoints = []
            for row in connection.execute(
                "SELECT outbox_id, task_id, purpose, payload_json, payload_digest, "
                "claim_owner, claim_expires_at, claim_token, claim_generation, "
                "requires_consumer_checkpoint, consumer_checkpointed_at, "
                "sent_at, rearm_at FROM outbox WHERE namespace = ? "
                "ORDER BY created_at, outbox_id",
                (self.namespace,),
            ):
                _decode_json(
                    row["payload_json"],
                    "outbox payload",
                    expected_digest=row["payload_digest"],
                )
                _validate_outbox_claim_state(
                    row["claim_owner"],
                    row["claim_expires_at"],
                    row["claim_token"],
                    row["claim_generation"],
                )
                _validate_outbox_delivery_state(
                    row["requires_consumer_checkpoint"],
                    row["consumer_checkpointed_at"],
                    row["sent_at"],
                    row["rearm_at"],
                    duplicate_window_seconds=self.duplicate_window_seconds,
                    message_retention_seconds=self.message_retention_seconds,
                )
                if (
                    bool(row["requires_consumer_checkpoint"])
                    and row["consumer_checkpointed_at"] is None
                    and row["sent_at"] is not None
                ):
                    awaiting_consumer_checkpoints.append(
                        {
                            "id": row["outbox_id"],
                            "task_id": row["task_id"],
                            "purpose": row["purpose"],
                            "rearm_at": row["rearm_at"],
                        }
                    )
        finally:
            connection.close()
        return {
            "unfinished_tasks": unfinished_tasks,
            "claimable_candidates": claimable,
            "recoverable_stages": self.recoverable_stages(),
            "pending_outbox": self.pending_outbox(),
            "awaiting_consumer_checkpoints": awaiting_consumer_checkpoints,
        }


def runtime_store(
    workdir: str | os.PathLike[str],
    repo: str,
    registry_digest: str,
    *,
    host_id: str | None = None,
    service_uid: int,
    message_retention_seconds: float,
    duplicate_window_seconds: float,
    clock: Callable[[], float] = time.time,
) -> RuntimeStore:
    """Open the exact-bound runtime database below Git's common directory."""

    state_directory = _bind_state_root(workdir)
    try:
        store = RuntimeStore(
            state_directory.path / _DATABASE_NAME,
            repo,
            registry_digest,
            host_id=host_id if host_id is not None else _default_host_id(),
            service_uid=service_uid,
            message_retention_seconds=message_retention_seconds,
            duplicate_window_seconds=duplicate_window_seconds,
            clock=clock,
            _state_directory=state_directory,
        )
        return store
    except BaseException as error:
        try:
            state_directory.close()
        except BaseException as cleanup_error:
            error.add_note(
                f"also failed to close the state directory binding: {cleanup_error}"
            )
        raise


def _lease_directory_flags() -> int:
    flags = os.O_RDONLY
    for capability in ("O_DIRECTORY", "O_NOFOLLOW", "O_CLOEXEC"):
        value = getattr(os, capability, None)
        if value is None:
            raise StateLocationError(f"{capability} is required for runtime leases")
        flags |= value
    if (
        not _OPEN_SUPPORTS_DIR_FD
        or not _MKDIR_SUPPORTS_DIR_FD
        or not _STAT_SUPPORTS_DIR_FD
    ):
        raise StateLocationError("descriptor-relative runtime leases are required")
    return flags


class _BoundLockDirectory:
    """Keep one no-follow directory chain open for a lease lifetime."""

    def __init__(
        self,
        path: Path,
        descriptors: list[int],
        names: list[str],
    ) -> None:
        self.path = path
        self._descriptors = descriptors
        self._names = names

    @property
    def descriptor(self) -> int:
        return self._descriptors[-1]

    @property
    def identity(self) -> tuple[int, int]:
        info = os.fstat(self.descriptor)
        return info.st_dev, info.st_ino

    def verify(self) -> None:
        for index, name in enumerate(self._names):
            try:
                entry = os.stat(
                    name,
                    dir_fd=self._descriptors[index],
                    follow_symlinks=False,
                )
                opened = os.fstat(self._descriptors[index + 1])
            except OSError as error:
                raise StateLocationError(
                    "runtime lock directory chain changed"
                ) from error
            if (
                not stat.S_ISDIR(entry.st_mode)
                or (entry.st_dev, entry.st_ino)
                != (opened.st_dev, opened.st_ino)
            ):
                raise StateLocationError("runtime lock directory chain changed")

    def append_private(self, name: str) -> None:
        if not name or name in {".", ".."} or os.sep in name:
            raise StateLocationError("runtime lock directory name is malformed")
        self.verify()
        try:
            os.mkdir(name, mode=0o700, dir_fd=self.descriptor)
        except FileExistsError:
            pass
        try:
            child = os.open(
                name,
                _lease_directory_flags(),
                dir_fd=self.descriptor,
            )
        except OSError as error:
            raise StateLocationError(
                "could not open runtime lock directory"
            ) from error
        self._names.append(name)
        self._descriptors.append(child)
        self.path /= name
        try:
            _verify_private_directory(os.fstat(child))
            self.verify()
        except BaseException as error:
            self._descriptors.pop()
            self._names.pop()
            try:
                os.close(child)
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to close the rejected directory: {cleanup_error}"
                )
            raise

    def clone(self) -> _BoundLockDirectory:
        """Duplicate the retained chain for one independent connection."""

        duplicates: list[int] = []
        try:
            self.verify()
            for descriptor in self._descriptors:
                duplicates.append(os.dup(descriptor))
            clone = _BoundLockDirectory(
                self.path,
                duplicates,
                list(self._names),
            )
            clone.verify()
            return clone
        except BaseException as error:
            for descriptor in reversed(duplicates):
                try:
                    os.close(descriptor)
                except BaseException as cleanup_error:
                    error.add_note(
                        f"also failed to close a cloned descriptor: {cleanup_error}"
                    )
            raise

    def close(self) -> None:
        errors: list[BaseException] = []
        while self._descriptors:
            descriptor = self._descriptors.pop()
            try:
                os.close(descriptor)
            except BaseException as error:
                errors.append(error)
        self._names.clear()
        if errors:
            for error in errors[1:]:
                errors[0].add_note(f"also failed to close a descriptor: {error}")
            raise errors[0]


def _open_existing_directory_chain(path: Path) -> _BoundLockDirectory:
    if not path.is_absolute() or any(part in {".", ".."} for part in path.parts):
        raise StateLocationError("runtime lock path must be canonical and absolute")
    descriptors: list[int] = []
    names: list[str] = []
    try:
        descriptors.append(os.open(os.sep, _lease_directory_flags()))
        for name in path.parts[1:]:
            descriptors.append(
                os.open(name, _lease_directory_flags(), dir_fd=descriptors[-1])
            )
            names.append(name)
        binding = _BoundLockDirectory(path, descriptors, names)
        binding.verify()
        return binding
    except BaseException as error:
        for descriptor in reversed(descriptors):
            try:
                os.close(descriptor)
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to close a directory-chain descriptor: {cleanup_error}"
                )
        if isinstance(error, StateLocationError):
            raise
        if not isinstance(error, Exception):
            raise
        raise StateLocationError(
            "could not walk runtime lock directory"
        ) from error


def _verify_lock_file(
    directory: _BoundLockDirectory, filename: str, descriptor: int
) -> None:
    """Require the opened lease file to remain the private directory entry."""
    directory.verify()
    info = os.fstat(descriptor)
    entry = os.stat(
        filename,
        dir_fd=directory.descriptor,
        follow_symlinks=False,
    )
    directory.verify()
    if (
        not stat.S_ISREG(info.st_mode)
        or (entry.st_dev, entry.st_ino) != (info.st_dev, info.st_ino)
        or info.st_nlink != 1
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o077
    ):
        raise StateLocationError("runtime lease path is not one private file")


def _open_lock(directory: _BoundLockDirectory, filename: str) -> int:
    if (
        not filename
        or filename in {".", ".."}
        or os.sep in filename
        or "\x00" in filename
    ):
        raise StateLocationError("runtime lease filename is malformed")
    flags = os.O_RDWR
    for capability in ("O_NOFOLLOW", "O_CLOEXEC"):
        value = getattr(os, capability, None)
        if value is None:
            raise StateLocationError(f"{capability} is required for runtime leases")
        flags |= value
    descriptor = None
    try:
        directory.verify()
        try:
            descriptor = os.open(
                filename,
                flags,
                dir_fd=directory.descriptor,
            )
        except FileNotFoundError:
            try:
                descriptor = os.open(
                    filename,
                    flags | os.O_CREAT | os.O_EXCL,
                    0o600,
                    dir_fd=directory.descriptor,
                )
            except FileExistsError:
                descriptor = os.open(
                    filename,
                    flags,
                    dir_fd=directory.descriptor,
                )
        _verify_lock_file(directory, filename, descriptor)
        return descriptor
    except Exception:
        if descriptor is not None:
            os.close(descriptor)
        raise


@contextmanager
def _file_lease(
    directory: _BoundLockDirectory,
    filenames: Sequence[str],
    timeout: float | None,
) -> Iterator[int]:
    if timeout is not None and (
        isinstance(timeout, bool)
        or not isinstance(timeout, (int, float))
        or not math.isfinite(float(timeout))
        or timeout < 0
    ):
        raise ValueError("timeout must be a non-negative finite number or None")
    deadline = None if timeout is None else time.monotonic() + float(timeout)
    if deadline is not None and not math.isfinite(deadline):
        raise ValueError("lease timeout deadline must be finite")
    descriptor: int | None = None
    held_path: tuple[int, int, str] | None = None
    slot = -1
    while descriptor is None:
        with _local_lock_guard:
            directory.verify()
            device, inode = directory.identity
            for index, filename in enumerate(filenames):
                identity = (device, inode, filename)
                if identity in _local_lock_paths:
                    continue
                candidate = _open_lock(directory, filename)
                try:
                    fcntl.flock(candidate, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except BlockingIOError:
                    os.close(candidate)
                    continue
                except Exception:
                    os.close(candidate)
                    raise
                try:
                    directory.verify()
                    _verify_lock_file(directory, filename, candidate)
                except Exception:
                    try:
                        fcntl.flock(candidate, fcntl.LOCK_UN)
                    finally:
                        os.close(candidate)
                    raise
                descriptor = candidate
                held_path = identity
                slot = index
                _local_lock_paths.add(identity)
                break
        if descriptor is not None:
            break
        if deadline is not None and time.monotonic() >= deadline:
            raise LeaseUnavailableError("runtime lease is unavailable")
        time.sleep(0.02)
    try:
        yield slot
    finally:
        with _local_lock_guard:
            if held_path is not None:
                _local_lock_paths.discard(held_path)
            if descriptor is not None:
                try:
                    fcntl.flock(descriptor, fcntl.LOCK_UN)
                finally:
                    os.close(descriptor)


@contextmanager
def _lock_directory(
    workdir: str | os.PathLike[str],
    name: str,
    *,
    host_lock_root: str | os.PathLike[str] | None,
    service_uid: int,
) -> Iterator[_BoundLockDirectory]:
    # Require an operator-configured service identity before selecting the one
    # host-local namespace shared by every clone and both harnesses.  Deriving
    # this value from each process would silently turn the cap into a per-UID
    # cap, so callers must pass the same configured exact UID at startup.
    service_uid = _validated_service_uid(service_uid)
    state_root(workdir)
    if host_lock_root is None:
        parent = Path(os.path.realpath("/tmp"))
        binding = _open_existing_directory_chain(parent)
        host_name = f"homeric-legacy-runtime-service-{service_uid}"
    else:
        requested_root = Path(host_lock_root)
        if not requested_root.is_absolute():
            raise StateLocationError("injected host lock root must be absolute")
        try:
            binding = _open_existing_directory_chain(requested_root.parent)
        except (OSError, RuntimeError, StateLocationError) as error:
            raise StateLocationError(
                f"injected host lock root parent is unavailable: {error}"
            ) from error
        try:
            _verify_private_directory(os.fstat(binding.descriptor))
            host_name = requested_root.name
        except Exception:
            binding.close()
            raise
    try:
        binding.append_private(host_name)
        binding.append_private("locks")
        binding.append_private(name)
        binding.verify()
        yield binding
    finally:
        binding.close()


@contextmanager
def heavy_slot(
    workdir: str | os.PathLike[str],
    max_slots: int = _MAX_HEAVY_SLOTS,
    timeout: float | None = None,
    *,
    host_lock_root: str | os.PathLike[str] | None = None,
    service_uid: int,
) -> Iterator[int]:
    """Acquire one host-wide heavy slot shared by both legacy harnesses."""

    if isinstance(max_slots, bool) or not isinstance(max_slots, int):
        raise ValueError("max_slots must be an integer")
    if not 1 <= max_slots <= _MAX_HEAVY_SLOTS:
        raise ValueError(f"max_slots must be between 1 and {_MAX_HEAVY_SLOTS}")
    with _lock_directory(
        workdir,
        "heavy",
        host_lock_root=host_lock_root,
        service_uid=service_uid,
    ) as directory:
        filenames = [f"slot-{index}.lock" for index in range(max_slots)]
        with _file_lease(directory, filenames, timeout) as slot:
            yield slot


@contextmanager
def checkout_lane(
    workdir: str | os.PathLike[str],
    checkout: str | os.PathLike[str],
    timeout: float | None = None,
    *,
    host_lock_root: str | os.PathLike[str] | None = None,
    service_uid: int,
) -> Iterator[None]:
    """Serialize mutating work for one canonical checkout path."""

    try:
        checkout_path = Path(checkout).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StateLocationError(f"checkout is unavailable: {error}") from error
    if not checkout_path.is_dir():
        raise StateLocationError("checkout is not a directory")
    checkout_root = Path(_run_git(checkout_path, "rev-parse", "--show-toplevel"))
    if not checkout_root.is_absolute():
        checkout_root = checkout_path / checkout_root
    try:
        checkout_root = checkout_root.resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StateLocationError(f"checkout root is unavailable: {error}") from error
    key = _digest(str(checkout_root))
    with _lock_directory(
        workdir,
        "checkouts",
        host_lock_root=host_lock_root,
        service_uid=service_uid,
    ) as directory:
        with _file_lease(directory, [f"{key}.lock"], timeout):
            yield None


async def _dispatch_with_heartbeat(
    message: Any,
    handler: Callable[[Any], Awaitable[Any]],
    heartbeat_seconds: float,
    heartbeat_rpc_timeout: float,
    disposition_timeout: float,
) -> None:
    handler_task = asyncio.create_task(handler(message))
    terminal_disposition_started: str | None = None

    async def settle_handler() -> None:
        """Wait until handler work actually stops before allowing redelivery.

        Cancelling an asyncio task that is awaiting ``asyncio.to_thread`` does
        not stop or join the underlying thread.  A NAK at that point can hand
        the same checkout to a redelivery while the original subprocess still
        mutates it.  Shield the handler and retain its lanes/claims until its
        real completion, even while this dispatcher is being cancelled.
        """

        while not handler_task.done():
            try:
                await asyncio.shield(handler_task)
            except asyncio.CancelledError:
                if handler_task.done():
                    break
                continue
            except Exception:
                break

    async def disposition(
        operation: str,
        *,
        delay: float | None = None,
    ) -> None:
        nonlocal terminal_disposition_started
        if terminal_disposition_started is not None:
            raise ConsumerDispositionError(
                "JetStream terminal disposition was already attempted"
            )
        terminal_disposition_started = operation
        try:
            call = getattr(message, operation)
            request = call() if delay is None else call(delay=delay)
            await asyncio.wait_for(request, timeout=disposition_timeout)
        except (asyncio.CancelledError, KeyboardInterrupt, SystemExit):
            raise
        except Exception as error:
            raise ConsumerDispositionError(
                f"JetStream {operation} failed"
            ) from error

    try:
        while True:
            done, _pending = await asyncio.wait(
                {handler_task}, timeout=heartbeat_seconds
            )
            if handler_task in done:
                try:
                    await handler_task
                except TransientMessageError:
                    await disposition(
                        "nak", delay=_TRANSIENT_NAK_DELAY_SECONDS
                    )
                    return
                except PermanentMessageError:
                    await disposition("term")
                    return
                except asyncio.CancelledError as error:
                    current_task = asyncio.current_task()
                    if current_task is not None and current_task.cancelling():
                        raise
                    try:
                        await disposition("nak")
                    except ConsumerDispositionError as disposition_error:
                        raise disposition_error from error
                    raise ConsumerHandlerError(
                        "message handler cancelled itself after NAK"
                    ) from error
                except Exception as error:
                    try:
                        await disposition("nak")
                    except ConsumerDispositionError as disposition_error:
                        raise disposition_error from error
                    raise ConsumerHandlerError(
                        "message handler failed after NAK"
                    ) from error
                await disposition("ack")
                return
            try:
                await asyncio.wait_for(
                    message.in_progress(), timeout=heartbeat_rpc_timeout
                )
            except (asyncio.CancelledError, KeyboardInterrupt, SystemExit):
                raise
            except Exception as error:
                await settle_handler()
                try:
                    await disposition("nak")
                except ConsumerDispositionError as disposition_error:
                    raise disposition_error from error
                raise ConsumerHeartbeatError(
                    "JetStream in_progress heartbeat failed"
                ) from error
    except asyncio.CancelledError:
        await settle_handler()
        if terminal_disposition_started is None:
            await disposition("nak")
        raise


async def run_consumer_workers(
    subscription: Any,
    handler: Callable[[Any], Awaitable[Any]],
    *,
    max_workers: int = _MAX_HEAVY_SLOTS,
    heartbeat_seconds: float = 30.0,
    heartbeat_rpc_timeout: float = 10.0,
    disposition_timeout: float = 10.0,
    fetch_timeout: float = 1.0,
    stop_event: asyncio.Event | None = None,
) -> None:
    """Run a bounded pull-consumer pool with JetStream progress heartbeats.

    A successful handler ACKs its message. :class:`TransientMessageError`
    NAKs for bounded redelivery and keeps the worker alive, while
    :class:`PermanentMessageError` terminates input that redelivery cannot
    repair. Any unclassified failure NAKs and then propagates. Fetch errors
    other than ordinary timeouts propagate instead of creating false success.
    """

    if isinstance(max_workers, bool) or not isinstance(max_workers, int):
        raise ValueError("max_workers must be an integer")
    if not 1 <= max_workers <= _MAX_HEAVY_SLOTS:
        raise ValueError(f"max_workers must be between 1 and {_MAX_HEAVY_SLOTS}")
    for value, name in (
        (heartbeat_seconds, "heartbeat_seconds"),
        (heartbeat_rpc_timeout, "heartbeat_rpc_timeout"),
        (disposition_timeout, "disposition_timeout"),
        (fetch_timeout, "fetch_timeout"),
    ):
        if (
            isinstance(value, bool)
            or not isinstance(value, (int, float))
            or not math.isfinite(float(value))
            or value <= 0
        ):
            raise ValueError(f"{name} must be a positive finite number")
    stop = stop_event if stop_event is not None else asyncio.Event()

    async def worker() -> None:
        while not stop.is_set():
            try:
                messages = await subscription.fetch(batch=1, timeout=fetch_timeout)
            except TimeoutError:
                continue
            for message in messages:
                await _dispatch_with_heartbeat(
                    message,
                    handler,
                    heartbeat_seconds,
                    heartbeat_rpc_timeout,
                    disposition_timeout,
                )

    workers = [asyncio.create_task(worker()) for _ in range(max_workers)]
    try:
        await asyncio.gather(*workers)
    finally:
        for worker_task in workers:
            if not worker_task.done():
                worker_task.cancel()
        await asyncio.gather(*workers, return_exceptions=True)


__all__ = [
    "ConsumerDispositionError",
    "ConsumerHandlerError",
    "ConsumerHeartbeatError",
    "HostBindingError",
    "LeaseUnavailableError",
    "LegacyRuntimeError",
    "MAX_ISSUE_NUMBER",
    "PermanentMessageError",
    "RejectMessage",
    "RetryMessage",
    "RuntimeStore",
    "StateConflictError",
    "StateLocationError",
    "TransientMessageError",
    "checkout_lane",
    "heavy_slot",
    "run_consumer_workers",
    "runtime_store",
    "stable_event_id",
    "state_root",
]
