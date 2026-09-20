"""Durable, single-host runtime primitives for the legacy myrmidon harnesses.

The module deliberately uses only the Python standard library.  Runtime state
is stored below Git's common directory so linked worktrees and both legacy
harness entrypoints observe the same database and lock namespace.  The state is
bound to one repository registry and one host; a conflicting binding fails
closed instead of guessing whether persisted work is safe to resume.

Untrusted candidate work is outside the runtime trust domain. The runtime
requires it to have a distinct, non-root OS UID; the service UID is the sole
owner of the 0700 state and lock namespaces. Metadata checks below detect
interference but are not presented as integrity against a hostile process that
shares the service UID. Deployments that cannot enforce the distinct-UID
boundary must keep this runtime disabled and use a separately owned broker.
"""

from __future__ import annotations

import asyncio
from collections.abc import Awaitable, Callable, Iterator, Mapping, Sequence
from contextlib import contextmanager
from contextvars import ContextVar
import ctypes
from dataclasses import dataclass
import errno
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import selectors
import select
import secrets
import signal
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
MAX_ITERATION = (1 << 63) - 1
_SERVICE_UID_ENV = "HOMERIC_LEGACY_SERVICE_UID"
_CANDIDATE_UID_ENV = "HOMERIC_LEGACY_CANDIDATE_UID"
_TERMINAL_FAILURE_STATES = frozenset({"failed", "human-blocked"})
_STAGE_TERMINAL_STATES = frozenset({"succeeded", "failed", "human-blocked"})
_ROOT_STAGE_REPO = "@odysseus-root"
_ROOT_STAGE_NAME = "ship-final"
_ROOT_STAGE_ITERATION = 0
_TRANSIENT_NAK_DELAY_SECONDS = 30.0
_MAX_TEXT_BYTES = 4096
_MAX_JSON_BYTES = 1024 * 1024
_MAX_JSON_DEPTH = 32
_MAX_JSON_NODES = 10_000
_MAX_TASK_ROUTES = 256
_MAX_OUTBOX_EVENTS = 256
_MAX_ACTIVE_TASKS = 256
_MAX_STORED_OUTBOX = 10_000
_MAX_QUERY_ROWS = 1000
_MAX_RECONCILE_ROWS = 1000
_MAX_TERMINAL_HISTORY = 256
_MAX_TRACKED_DESCENDANTS = 256
_MAX_EXTERNAL_EFFECTS_PER_DELIVERY = 8
_MAX_CGROUP_MEMORY_BYTES = 8 * 1024 * 1024 * 1024
_GIT_EXECUTABLE = Path("/usr/bin/git")
_GIT_TIMEOUT_SECONDS = 10.0
_MAX_GIT_OUTPUT_BYTES = 64 * 1024
_PROCESS_TERM_GRACE_SECONDS = 0.25
_DEFAULT_HANDLER_SHUTDOWN_TIMEOUT = 30.0
_MAX_CONTAINER_COMMAND_OUTPUT_BYTES = 256 * 1024
_SQLITE_LEASE_TIMEOUT_SECONDS = 5.0
_MAX_DURABLE_STATE_BYTES = 64 * 1024 * 1024
_SQLITE_SIDECAR_RESERVE_BYTES = 1024 * 1024
_SQLITE_DIRTY_CACHE_BYTES = 256 * 1024
_SQLITE_COMMIT_RESERVE_BYTES = 512 * 1024
# SQLite's documented maximum sector size. With dirty-page spilling disabled,
# one transaction needs one aligned rollback-journal header.
_SQLITE_MAX_SECTOR_BYTES = 64 * 1024
_SQLITE_JOURNAL_RECORD_OVERHEAD_BYTES = 8
_local_lock_guard = threading.Lock()
_local_lock_paths: set[tuple[int, int, str]] = set()
_sqlite_descriptor_guard = threading.RLock()
_OPEN_SUPPORTS_DIR_FD = os.open in getattr(os, "supports_dir_fd", set())
_MKDIR_SUPPORTS_DIR_FD = os.mkdir in getattr(os, "supports_dir_fd", set())
_STAT_SUPPORTS_DIR_FD = os.stat in getattr(os, "supports_dir_fd", set())
_DELIVERED_TERMINAL_PREDICATE = (
    "t.namespace = ? "
    "AND t.completion_json IS NOT NULL AND t.completed_at IS NOT NULL "
    "AND NOT EXISTS (SELECT 1 FROM outbox AS o WHERE "
    "o.namespace = t.namespace AND o.task_id = t.task_id AND "
    "((o.requires_consumer_checkpoint = 0 AND o.sent_at IS NULL) OR "
    "(o.requires_consumer_checkpoint = 1 AND "
    "o.consumer_checkpointed_at IS NULL))) "
    "AND NOT EXISTS (SELECT 1 FROM stage_runs AS s WHERE "
    "s.namespace = t.namespace AND s.task_id = t.task_id AND "
    "s.state = 'pending') "
    "AND NOT EXISTS (SELECT 1 FROM candidates AS c WHERE "
    "c.namespace = t.namespace AND c.task_id = t.task_id AND "
    "c.completed_at IS NULL) "
)


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


def _sqlite_deadline_remaining(deadline: float) -> float:
    remaining = deadline - time.monotonic()
    if not math.isfinite(remaining) or remaining <= 0:
        raise LeaseUnavailableError("SQLite state admission deadline expired")
    return remaining


@contextmanager
def _bounded_sqlite_descriptor_guard(deadline: float) -> Iterator[None]:
    """Acquire the process-wide descriptor-discovery guard within one deadline."""

    acquired = _sqlite_descriptor_guard.acquire(
        timeout=_sqlite_deadline_remaining(deadline)
    )
    if not acquired:
        raise LeaseUnavailableError("SQLite descriptor admission is unavailable")
    try:
        yield
    finally:
        _sqlite_descriptor_guard.release()


def _bound_sqlite_wait(
    connection: sqlite3.Connection,
    deadline: float,
) -> None:
    remaining_ms = max(1, int(_sqlite_deadline_remaining(deadline) * 1000))
    connection.execute(f"PRAGMA busy_timeout = {remaining_ms}")


class RejectMessage(PermanentMessageError):
    """A JetStream message is permanently invalid and must be terminated."""


class ConsumerHandlerError(LegacyRuntimeError):
    """A message handler failed after its message was NAKed for redelivery."""


class ConsumerHeartbeatError(LegacyRuntimeError):
    """A JetStream progress heartbeat failed or exceeded its RPC deadline."""


class ConsumerDispositionError(LegacyRuntimeError):
    """JetStream could not ACK, NAK, or terminate a handled message."""


class WorkerContainmentError(LegacyRuntimeError):
    """A worker could not prove extinction of its request-scoped effects."""


class WorkerContainmentFatalError(WorkerContainmentError):
    """Containment is uncertain, so redelivery is forbidden until extinction."""


class WorkerContainmentUnavailableError(WorkerContainmentFatalError):
    """The worker has no active kernel-owned extinction authority."""


class WorkerExtinctionError(WorkerContainmentFatalError):
    """The active authority could not prove complete worker extinction."""


@dataclass(frozen=True)
class ExternalEffectReceipt:
    """One durable pre-create or exact-bound external-effect receipt."""

    effect_token: str
    source_event_id: str
    effect_kind: str
    authority: Mapping[str, Any]
    binding: Mapping[str, Any] | None


@dataclass(frozen=True)
class ExternalEffectExtinctionProof:
    """Structured proof returned only after one exact effect is extinct."""

    effect_token: str
    engine_endpoint_identity: Mapping[str, Any]
    binding_digest: str | None


@dataclass(frozen=True)
class NonpersistentDispatchAuthority:
    """Explicit dry-run dispatch: dispositions work, external effects cannot arm."""


@dataclass(frozen=True)
class DurableDispatchAuthority:
    """Stable message identity plus trusted exact-effect reconciliation."""

    store: Any
    identify: Callable[[Any], str]
    reconcile: Callable[
        [ExternalEffectReceipt], Awaitable[ExternalEffectExtinctionProof]
    ]


class _WorkerRequestEffectScope:
    """Atomically close one dispatch to new effects before its disposition."""

    def __init__(self, supervisor: WorkerExtinctionSupervisor) -> None:
        self._supervisor = supervisor
        self._effects: set[object] = set()
        self._admission_open = True

    def _register_locked(self, effect: object) -> None:
        if not self._admission_open:
            raise WorkerContainmentFatalError(
                "request effect admission is closed"
            )
        self._effects.add(effect)

    def _unregister_locked(self, effect: object) -> None:
        self._effects.discard(effect)

    def seal_and_verify_quiescent(self) -> None:
        with self._supervisor._external_effects_lock:
            self._admission_open = False
            if self._effects:
                raise WorkerContainmentFatalError(
                    "request effects remained live after handler completion"
                )


class WorkerExtinctionSupervisor:
    """Registry for exact external effects owned by one live worker.

    Concrete supervisors must implement :meth:`extinguish_and_terminate` with
    an operating-system containment primitive. The shared registry guarantees
    that every exact external receipt is extinct before that primitive may
    terminate the worker.
    """

    def __init__(self) -> None:
        self._external_effects: set[object] = set()
        self._external_effect_scopes: dict[
            object, _WorkerRequestEffectScope | None
        ] = {}
        self._external_effects_lock = threading.RLock()
        self._extinction_started = False

    def _open_request_effect_scope(self) -> _WorkerRequestEffectScope:
        return _WorkerRequestEffectScope(self)

    def _register_external_effect(
        self,
        effect: object,
        request_scope: _WorkerRequestEffectScope | None = None,
    ) -> None:
        with self._external_effects_lock:
            if self._extinction_started:
                raise WorkerExtinctionError(
                    "worker extinction already started; new effects are forbidden"
                )
            if effect in self._external_effect_scopes:
                raise WorkerContainmentFatalError(
                    "external effect is already registered"
                )
            scope = (
                _CURRENT_WORKER_REQUEST_EFFECT_SCOPE.get()
                if request_scope is None
                else request_scope
            )
            if scope is not None:
                if scope._supervisor is not self:
                    raise WorkerContainmentFatalError(
                        "request effect scope belongs to another supervisor"
                    )
                scope._register_locked(effect)
            self._external_effects.add(effect)
            self._external_effect_scopes[effect] = scope

    def _unregister_external_effect(
        self, effect: object
    ) -> None:
        with self._external_effects_lock:
            self._external_effects.discard(effect)
            scope = self._external_effect_scopes.pop(effect, None)
            if scope is not None:
                scope._unregister_locked(effect)

    def _extinguish_registered_effects(self) -> None:
        with self._external_effects_lock:
            self._extinction_started = True
            effects = tuple(self._external_effects)
        failures: list[BaseException] = []
        for effect in effects:
            try:
                effect._extinguish()
            except BaseException as error:
                failures.append(error)
        if failures:
            failure = WorkerExtinctionError(
                "exact external-effect extinction could not be proven"
            )
            for error in failures:
                failure.add_note(f"external-effect cleanup failed: {error}")
            raise failure from failures[0]

    def _release_registered_effects(self) -> None:
        """Release receipts only after kernel process extinction is proven."""

        with self._external_effects_lock:
            effects = tuple(self._external_effects)
        failures: list[BaseException] = []
        for effect in effects:
            try:
                effect._close_proven()
            except BaseException as error:
                failures.append(error)
        with self._external_effects_lock:
            remaining = tuple(self._external_effects)
        if failures or remaining:
            failure = WorkerExtinctionError(
                "proven external-effect receipts could not be released"
            )
            for error in failures:
                failure.add_note(f"external-effect release failed: {error}")
            if remaining:
                failure.add_note(
                    f"{len(remaining)} external effect receipt(s) remain armed"
                )
            raise failure from (failures[0] if failures else None)

    async def extinguish_and_terminate(self, reason: str) -> None:
        raise NotImplementedError


_CURRENT_WORKER_EXTINCTION_SUPERVISOR: ContextVar[object | None] = ContextVar(
    "legacy_worker_extinction_supervisor",
    default=None,
)
_CURRENT_WORKER_REQUEST_EFFECT_SCOPE: ContextVar[
    _WorkerRequestEffectScope | None
] = ContextVar("legacy_worker_request_effect_scope", default=None)


@dataclass(frozen=True)
class _DurableDeliveryContext:
    store: Any
    source_event_id: str
    claim_token: str


_CURRENT_DURABLE_DELIVERY: ContextVar[_DurableDeliveryContext | None] = (
    ContextVar("legacy_durable_delivery", default=None)
)


def _validated_extinction_supervisor(supervisor: object) -> object:
    method = getattr(supervisor, "extinguish_and_terminate", None)
    if not callable(method):
        raise TypeError(
            "extinction_supervisor must provide extinguish_and_terminate()"
        )
    return supervisor


def current_worker_extinction_supervisor(
    *, required: bool = True
) -> object | None:
    """Return the request-bound authority without inventing a fallback.

    Direct deterministic helpers may query with ``required=False``. Live
    worker paths must use the default so missing containment fails before a
    fatal timeout can be converted into restart or broker redelivery.
    """

    supervisor = _CURRENT_WORKER_EXTINCTION_SUPERVISOR.get()
    if supervisor is None:
        if required:
            raise WorkerContainmentUnavailableError(
                "no worker extinction supervisor is bound to this invocation"
            )
        return None
    return _validated_extinction_supervisor(supervisor)


@contextmanager
def bind_worker_extinction_supervisor(
    supervisor: object,
) -> Iterator[object]:
    """Bind one explicit authority for synchronous or deterministic helpers."""

    supervisor = _validated_extinction_supervisor(supervisor)
    token = _CURRENT_WORKER_EXTINCTION_SUPERVISOR.set(supervisor)
    try:
        yield supervisor
    finally:
        _CURRENT_WORKER_EXTINCTION_SUPERVISOR.reset(token)


def _required_text(value: object, field: str) -> str:
    if (
        not isinstance(value, str)
        or not value.strip()
        or "\x00" in value
        or len(value.encode("utf-8")) > _MAX_TEXT_BYTES
    ):
        raise ValueError(f"{field} must be a non-empty string")
    return value


def _validated_issue_number(value: object) -> int:
    """Require one normalized issue integer that SQLite can store exactly."""
    if type(value) is not int or not 1 <= value <= MAX_ISSUE_NUMBER:
        raise ValueError(
            f"issue_number must be between 1 and {MAX_ISSUE_NUMBER}"
        )
    return value


def _validated_repo_slug(value: object, *, persisted: bool = False) -> str:
    """Reject the delimiter used by durable outbox and stage purpose keys."""

    error_type: type[Exception] = StateConflictError if persisted else ValueError
    try:
        slug = _required_text(value, "repo_slug")
    except ValueError as error:
        raise error_type("repo_slug is malformed") from error
    if ":" in slug:
        raise error_type("repo_slug cannot contain the purpose delimiter")
    return slug


def _validate_json_shape(
    value: object,
    field: str,
    *,
    persisted: bool = False,
) -> None:
    """Reject JSON values whose resource cost exceeds the runtime envelope."""

    error_type: type[Exception] = StateConflictError if persisted else ValueError
    nodes = 0
    text_bytes = 0
    stack: list[tuple[object, int]] = [(value, 0)]
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > _MAX_JSON_NODES:
            raise error_type(f"{field} exceeds the JSON node limit")
        if depth > _MAX_JSON_DEPTH:
            raise error_type(f"{field} exceeds the JSON depth limit")
        if current is None or type(current) in (bool, int):
            continue
        if type(current) is float:
            if not math.isfinite(current):
                raise error_type(f"{field} contains a non-finite number")
            continue
        if isinstance(current, str):
            text_bytes += len(current.encode("utf-8"))
        elif isinstance(current, list):
            stack.extend((item, depth + 1) for item in current)
        elif isinstance(current, dict):
            for key, item in current.items():
                if not isinstance(key, str):
                    raise error_type(f"{field} contains a non-string object key")
                text_bytes += len(key.encode("utf-8"))
                stack.append((item, depth + 1))
        else:
            raise error_type(f"{field} must be canonical JSON data")
        if text_bytes > _MAX_JSON_BYTES:
            raise error_type(f"{field} exceeds the JSON byte limit")


def _canonical_json(value: object, field: str) -> str:
    _validate_json_shape(value, field)
    try:
        encoded = json.dumps(
            value,
            allow_nan=False,
            ensure_ascii=False,
            separators=(",", ":"),
            sort_keys=True,
        )
    except (TypeError, ValueError) as error:
        raise ValueError(f"{field} must be canonical JSON data") from error
    if len(encoded.encode("utf-8")) > _MAX_JSON_BYTES:
        raise ValueError(f"{field} exceeds the JSON byte limit")
    return encoded


def _validated_engine_endpoint_identity(
    value: object,
    *,
    persisted: bool = False,
) -> dict[str, Any]:
    """Normalize one caller-verified, opaque engine/endpoint identity."""

    error_type: type[Exception] = (
        StateConflictError if persisted else WorkerContainmentUnavailableError
    )
    if not isinstance(value, Mapping) or not value:
        raise error_type("engine endpoint identity is missing")
    try:
        encoded = _canonical_json(dict(value), "engine endpoint identity")
        normalized = json.loads(encoded)
    except (TypeError, ValueError, json.JSONDecodeError) as error:
        raise error_type("engine endpoint identity is malformed") from error
    if not isinstance(normalized, dict) or not normalized:
        raise error_type("engine endpoint identity is malformed")
    return normalized


def _external_effect_binding_digest(
    receipt: ExternalEffectReceipt,
) -> str | None:
    if receipt.binding is None:
        return None
    if not isinstance(receipt.binding, Mapping):
        raise StateConflictError("external effect binding is malformed")
    try:
        return _digest(
            _canonical_json(dict(receipt.binding), "external effect binding")
        )
    except ValueError as error:
        raise StateConflictError(
            "external effect binding is malformed"
        ) from error


def _verify_external_effect_extinction_proof(
    receipt: ExternalEffectReceipt,
    proof: object,
) -> None:
    """Refuse retirement unless proof binds the same effect and engine epoch."""

    if not isinstance(proof, ExternalEffectExtinctionProof):
        raise WorkerExtinctionError(
            "external effect reconciler returned no structured proof"
        )
    if proof.effect_token != receipt.effect_token:
        raise WorkerExtinctionError(
            "external effect reconciliation proof changed effect identity"
        )
    expected = _validated_engine_endpoint_identity(
        receipt.authority.get("engine_endpoint_identity")
        if isinstance(receipt.authority, Mapping)
        else None,
        persisted=True,
    )
    try:
        observed = _validated_engine_endpoint_identity(
            proof.engine_endpoint_identity
        )
    except WorkerContainmentUnavailableError as error:
        raise WorkerExtinctionError(
            "external effect reconciliation engine identity is unproven"
        ) from error
    if _canonical_json(observed, "engine endpoint identity") != _canonical_json(
        expected, "engine endpoint identity"
    ):
        raise WorkerExtinctionError(
            "external effect reconciliation crossed engine endpoint identity"
        )
    expected_binding = _external_effect_binding_digest(receipt)
    if proof.binding_digest != expected_binding:
        raise WorkerExtinctionError(
            "external effect reconciliation proof changed its exact binding"
        )


def external_effect_extinction_proof(
    receipt: ExternalEffectReceipt,
    engine_endpoint_identity: Mapping[str, Any],
) -> ExternalEffectExtinctionProof:
    """Build the structured result of trusted exact-effect reconciliation.

    The trusted reconciler calls this only after proving the receipt's exact
    binding and every invocation-scoped inventory extinct through the same
    verified engine endpoint.
    """

    if not isinstance(receipt, ExternalEffectReceipt) or not _is_sha256(
        receipt.effect_token
    ):
        raise WorkerExtinctionError(
            "external effect reconciliation receipt is malformed"
        )
    identity = _validated_engine_endpoint_identity(engine_endpoint_identity)
    proof = ExternalEffectExtinctionProof(
        effect_token=receipt.effect_token,
        engine_endpoint_identity=identity,
        binding_digest=_external_effect_binding_digest(receipt),
    )
    _verify_external_effect_extinction_proof(receipt, proof)
    return proof


def _digest(value: str) -> str:
    return hashlib.sha256(value.encode("utf-8")).hexdigest()


def _aggregate_durable_allocation_bytes(
    *,
    page_size: int,
    page_count: int,
    database_size: int,
    sidecar_sizes: Sequence[int],
) -> int:
    """Count projected database pages and every live SQLite sidecar."""

    values = (page_size, page_count, database_size, *sidecar_sizes)
    if (
        type(page_size) is not int
        or page_size <= 0
        or any(type(value) is not int or value < 0 for value in values[1:])
    ):
        raise StateConflictError("SQLite durable allocation is invalid")
    projected_database_size = page_size * page_count
    return max(projected_database_size, database_size) + sum(sidecar_sizes)


def _plan_transition_binding_digest(
    task_id: str,
    team_id: str,
    issue_number: int,
    task_digest: str,
    source_event_id: str,
    subject: str,
    payload_json: str,
    routes: Mapping[str, str],
) -> str:
    """Hash one ingress binding without constructing an unbounded aggregate."""

    digest = hashlib.sha256()

    def update(value: str) -> None:
        encoded = value.encode("utf-8")
        digest.update(len(encoded).to_bytes(8, "big"))
        digest.update(encoded)

    for value in (
        task_id,
        team_id,
        str(issue_number),
        task_digest,
        source_event_id,
        subject,
        payload_json,
    ):
        update(value)
    for slug, route_json in sorted(routes.items()):
        update(slug)
        update(route_json)
    return digest.hexdigest()


def _is_sha256(value: object) -> bool:
    return (
        isinstance(value, str)
        and len(value) == 64
        and all(character in "0123456789abcdef" for character in value)
    )


def container_binding_digest(inspection: object) -> str:
    """Digest immutable identity/configuration from one exact OCI inspection."""

    if not isinstance(inspection, dict):
        raise ValueError("container inspection must be an object")
    container_id = inspection.get("Id")
    name = inspection.get("Name")
    image = inspection.get("Image")
    config = inspection.get("Config")
    host_config = inspection.get("HostConfig")
    mounts = inspection.get("Mounts")
    if (
        not _is_sha256(container_id)
        or not isinstance(name, str)
        or not name
        or "\x00" in name
        or not isinstance(image, str)
        or not image
        or not isinstance(config, dict)
        or not isinstance(host_config, dict)
        or not isinstance(mounts, list)
    ):
        raise ValueError("container inspection has no immutable binding")
    binding = {
        "Config": config,
        "HostConfig": host_config,
        "Id": container_id,
        "Image": image,
        "Mounts": mounts,
        "Name": name.removeprefix("/"),
    }
    return _digest(_canonical_json(binding, "container binding"))


def pod_binding_digest(inspection: object) -> str:
    """Digest one exact Podman pod/infra namespace binding."""

    if not isinstance(inspection, dict):
        raise ValueError("pod inspection must be an object")
    pod_id = inspection.get("Id")
    name = inspection.get("Name")
    labels = inspection.get("Labels")
    shared = inspection.get("SharedNamespaces")
    infra_id = inspection.get("InfraContainerID")
    if (
        not _is_sha256(pod_id)
        or not isinstance(name, str)
        or not name
        or "\x00" in name
        or not isinstance(labels, dict)
        or not isinstance(shared, list)
        or any(not isinstance(value, str) for value in shared)
        or "net" not in {value.casefold() for value in shared}
        or not _is_sha256(infra_id)
    ):
        raise ValueError("pod inspection has no immutable infra binding")
    binding = {
        "Id": pod_id,
        "InfraContainerID": infra_id,
        "Labels": labels,
        "Name": name.removeprefix("/"),
        "SharedNamespaces": sorted(value.casefold() for value in shared),
    }
    return _digest(_canonical_json(binding, "pod binding"))


def _decode_json(
    value: object,
    field: str,
    *,
    expected_digest: object | None = None,
) -> Any:
    if not isinstance(value, str):
        raise StateConflictError(f"persisted {field} is not text")
    if len(value.encode("utf-8")) > _MAX_JSON_BYTES:
        raise StateConflictError(f"persisted {field} exceeds the JSON byte limit")
    if expected_digest is not None and (
        not isinstance(expected_digest, str) or _digest(value) != expected_digest
    ):
        raise StateConflictError(f"persisted {field} failed its integrity check")
    try:
        decoded = json.loads(value)
    except (TypeError, ValueError, RecursionError) as error:
        raise StateConflictError(f"persisted {field} is invalid JSON") from error
    _validate_json_shape(decoded, f"persisted {field}", persisted=True)
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
    _validated_candidate_uid(configured_uid)
    return configured_uid


def _validated_candidate_uid(service_uid: int) -> int:
    """Require an OS ownership boundary between service and candidate code."""

    configured_text = os.environ.get(_CANDIDATE_UID_ENV)
    if (
        configured_text is None
        or not configured_text.isascii()
        or not configured_text.isdigit()
        or str(int(configured_text)) != configured_text
    ):
        raise HostBindingError(
            f"{_CANDIDATE_UID_ENV} must name one exact untrusted candidate UID"
        )
    candidate_uid = int(configured_text)
    if candidate_uid == 0 or candidate_uid >= (1 << 32) - 1:
        raise HostBindingError(
            f"{_CANDIDATE_UID_ENV} must name one non-root platform UID"
        )
    if candidate_uid == service_uid:
        raise HostBindingError(
            "untrusted candidate code cannot share the legacy runtime service UID"
        )
    return candidate_uid


def _validated_iteration(value: object) -> int:
    if type(value) is not int or not 0 <= value <= MAX_ITERATION:
        raise ValueError(
            f"iteration must be between 0 and {MAX_ITERATION}"
        )
    return value


def validate_message_iteration(value: object) -> int:
    """Validate an untrusted broker iteration or reject it permanently."""

    try:
        return _validated_iteration(value)
    except ValueError as error:
        raise RejectMessage(str(error)) from error


def _validated_limit(value: object, field: str = "limit") -> int:
    if (
        isinstance(value, bool)
        or not isinstance(value, int)
        or not 1 <= value <= _MAX_QUERY_ROWS
    ):
        raise ValueError(f"{field} must be between 1 and {_MAX_QUERY_ROWS}")
    return value


def _is_sqlite_full_error(error: BaseException) -> bool:
    code = getattr(error, "sqlite_errorcode", None)
    return isinstance(error, sqlite3.Error) and (
        (isinstance(code, int) and code & 0xFF == sqlite3.SQLITE_FULL)
        or "database or disk is full" in str(error).lower()
    )


def _validate_retention_bounded_lease(
    lease_seconds: float,
    message_retention_seconds: float,
) -> None:
    if lease_seconds >= message_retention_seconds:
        raise ValueError(
            "lease_seconds must be shorter than message retention so a failed "
            "claim remains recoverable"
        )


def _query_pages(
    connection: sqlite3.Connection,
    query: str,
    parameters: Sequence[Any],
    *,
    page_size: int,
) -> Iterator[list[sqlite3.Row]]:
    """Read a stable ordered query in bounded pages within one transaction."""

    if isinstance(page_size, bool) or not isinstance(page_size, int) or page_size < 1:
        raise ValueError("page_size must be a positive integer")
    offset = 0
    while True:
        rows = list(
            connection.execute(
                f"{query} LIMIT ? OFFSET ?",
                (*parameters, page_size, offset),
            )
        )
        if not rows:
            return
        yield rows
        if len(rows) < page_size:
            return
        offset += len(rows)


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


def _secure_descriptor_routes_supported() -> bool:
    if not sys.platform.startswith("linux"):
        return False
    try:
        info = os.stat("/proc/self/fd")
    except OSError:
        return False
    return stat.S_ISDIR(info.st_mode)


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def _extinguish_process_group(process: subprocess.Popen[bytes]) -> None:
    """Terminate and reap an owned process group within one fixed deadline."""

    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    deadline = time.monotonic() + _PROCESS_TERM_GRACE_SECONDS
    while _process_group_exists(process.pid) and time.monotonic() < deadline:
        time.sleep(0.01)
    if _process_group_exists(process.pid):
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    try:
        process.wait(timeout=_PROCESS_TERM_GRACE_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=_PROCESS_TERM_GRACE_SECONDS)
        except subprocess.TimeoutExpired:
            pass


def _run_bounded_process(
    argv: Sequence[str],
    *,
    env: Mapping[str, str],
    pass_fds: Sequence[int],
    timeout: float,
    output_limit: int,
) -> tuple[int, bytes, bytes]:
    """Run one noninteractive process with bounded output and tree lifetime."""

    process: subprocess.Popen[bytes] | None = None
    selector = selectors.DefaultSelector()
    stdout = bytearray()
    stderr = bytearray()
    primary: BaseException | None = None
    try:
        process = subprocess.Popen(
            list(argv),
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=dict(env),
            close_fds=True,
            pass_fds=tuple(pass_fds),
            start_new_session=True,
        )
        if process.stdout is None or process.stderr is None:
            raise StateLocationError("Git output pipes are unavailable")
        for stream, target in ((process.stdout, stdout), (process.stderr, stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, target)
        deadline = time.monotonic() + timeout
        while selector.get_map():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise StateLocationError("Git inspection exceeded its deadline")
            events = selector.select(min(remaining, 0.05))
            for key, _mask in events:
                try:
                    chunk = os.read(key.fileobj.fileno(), 8192)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                target = key.data
                target.extend(chunk)
                if len(target) > output_limit:
                    raise StateLocationError("Git inspection exceeded its output limit")
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise StateLocationError("Git inspection exceeded its deadline")
        try:
            returncode = process.wait(timeout=remaining)
        except subprocess.TimeoutExpired as error:
            raise StateLocationError("Git inspection exceeded its deadline") from error
        if _process_group_exists(process.pid):
            _extinguish_process_group(process)
            raise StateLocationError("Git left a descendant process running")
        return returncode, bytes(stdout), bytes(stderr)
    except BaseException as error:
        primary = error
        if process is not None:
            try:
                _extinguish_process_group(process)
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to extinguish the Git process group: "
                    f"{cleanup_error}"
                )
        raise
    finally:
        cleanup_errors: list[BaseException] = []
        try:
            selector.close()
        except BaseException as error:
            cleanup_errors.append(error)
        if process is not None:
            for stream in (process.stdout, process.stderr):
                if stream is not None:
                    try:
                        stream.close()
                    except BaseException as error:
                        cleanup_errors.append(error)
        if primary is not None:
            for error in cleanup_errors:
                primary.add_note(f"also failed during process cleanup: {error}")
        elif cleanup_errors:
            cleanup_error = cleanup_errors.pop(0)
            for error in cleanup_errors:
                cleanup_error.add_note(
                    f"also failed during process cleanup: {error}"
                )
            raise cleanup_error


def _duplicate_sealed_runtime_descriptor(runtime_fd: int) -> int:
    """Retain one immutable executable used for exact container operations."""

    if isinstance(runtime_fd, bool) or not isinstance(runtime_fd, int) or runtime_fd < 0:
        raise WorkerContainmentUnavailableError(
            "container runtime descriptor is malformed"
        )
    if not sys.platform.startswith("linux") or not _secure_descriptor_routes_supported():
        raise WorkerContainmentUnavailableError(
            "sealed container-runtime execution requires Linux /proc"
        )
    required_names = (
        "F_GET_SEALS",
        "F_SEAL_SEAL",
        "F_SEAL_SHRINK",
        "F_SEAL_GROW",
        "F_SEAL_WRITE",
    )
    if any(not hasattr(fcntl, name) for name in required_names):
        raise WorkerContainmentUnavailableError(
            "sealed container-runtime descriptors are unavailable"
        )
    duplicate = -1
    try:
        duplicate = os.dup(runtime_fd)
        os.set_inheritable(duplicate, False)
        info = os.fstat(duplicate)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid not in {0, os.geteuid()}
            or info.st_mode & 0o022
            or not info.st_mode & 0o111
        ):
            raise WorkerContainmentUnavailableError(
                "container runtime descriptor is not a protected executable"
            )
        required_seals = (
            fcntl.F_SEAL_SEAL
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_WRITE
        )
        if fcntl.fcntl(duplicate, fcntl.F_GET_SEALS) & required_seals != required_seals:
            raise WorkerContainmentUnavailableError(
                "container runtime descriptor is not immutably sealed"
            )
        return duplicate
    except BaseException:
        if duplicate >= 0:
            os.close(duplicate)
        raise




def _run_exact_container_command(*_arguments, **_options):
    """Reject the removed environment-backed direct-execution interface."""
    raise WorkerContainmentUnavailableError(
        "direct container execution is disabled; an endpoint broker is required"
    )








def _validated_container_name(value: object) -> str:
    if (
        not isinstance(value, str)
        or not 1 <= len(value) <= 128
        or not value[0].isalnum()
        or not value.isascii()
        or any(not (character.isalnum() or character in "_.-") for character in value)
    ):
        raise WorkerContainmentUnavailableError(
            "pre-create container name is malformed"
        )
    return value


def _duplicate_private_directory_descriptor(descriptor: int) -> tuple[int, tuple[int, ...]]:
    if isinstance(descriptor, bool) or not isinstance(descriptor, int) or descriptor < 0:
        raise WorkerContainmentUnavailableError(
            "container receipt parent descriptor is malformed"
        )
    duplicate = -1
    try:
        duplicate = os.dup(descriptor)
        os.set_inheritable(duplicate, False)
        info = os.fstat(duplicate)
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise WorkerContainmentUnavailableError(
                "container receipt parent is not a protected directory"
            )
        return duplicate, (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
    except BaseException:
        if duplicate >= 0:
            os.close(duplicate)
        raise


class _ExternalEffectSupervisor:
    """One generic, request-scoped durable effect with trusted exact cleanup."""

    def __init__(
        self,
        supervisor: WorkerExtinctionSupervisor,
        effect_kind: str,
        authority: Mapping[str, Any],
        cleanup: Callable[
            [ExternalEffectReceipt], ExternalEffectExtinctionProof
        ],
    ) -> None:
        try:
            effect_kind = _required_text(effect_kind, "effect_kind")
        except ValueError as error:
            raise WorkerContainmentUnavailableError(
                "external effect kind is malformed"
            ) from error
        if (
            not effect_kind.isascii()
            or len(effect_kind) > 64
            or any(
                not (character.isalnum() or character in "_.-")
                for character in effect_kind
            )
        ):
            raise WorkerContainmentUnavailableError(
                "external effect kind is malformed"
            )
        if not isinstance(authority, Mapping) or not authority:
            raise WorkerContainmentUnavailableError(
                "external effect authority is malformed"
            )
        try:
            normalized_authority = json.loads(
                _canonical_json(dict(authority), "external effect authority")
            )
            normalized_authority["engine_endpoint_identity"] = (
                _validated_engine_endpoint_identity(
                    normalized_authority.get("engine_endpoint_identity")
                )
            )
        except (TypeError, ValueError) as error:
            raise WorkerContainmentUnavailableError(
                "external effect authority is malformed"
            ) from error
        if not callable(cleanup):
            raise TypeError("external effect cleanup must be callable")
        request_scope = _CURRENT_WORKER_REQUEST_EFFECT_SCOPE.get()
        durable_delivery = _CURRENT_DURABLE_DELIVERY.get()
        if (
            request_scope is None
            or request_scope._supervisor is not supervisor
            or durable_delivery is None
        ):
            raise WorkerContainmentUnavailableError(
                "generic external effects require request and durable authorities"
            )
        self._supervisor = supervisor
        self._request_effect_scope = request_scope
        self._durable_delivery = durable_delivery
        self._effect_kind = effect_kind
        self._authority = normalized_authority
        self._cleanup = cleanup
        self._effect_token: str | None = None
        self._binding: dict[str, Any] | None = None
        self._extinction_proven = False
        self._entered = False
        self._closed = False
        self._lock = threading.RLock()

    def _receipt(self) -> ExternalEffectReceipt:
        if self._effect_token is None:
            raise WorkerExtinctionError(
                "generic external effect has no durable token"
            )
        return ExternalEffectReceipt(
            effect_token=self._effect_token,
            source_event_id=self._durable_delivery.source_event_id,
            effect_kind=self._effect_kind,
            authority=dict(self._authority),
            binding=(None if self._binding is None else dict(self._binding)),
        )

    def __enter__(self) -> _ExternalEffectSupervisor:
        with self._lock:
            if self._entered or self._closed:
                raise WorkerExtinctionError(
                    "generic external effect supervisor cannot be reused"
                )
            armed = False
            registered = False
            try:
                with self._supervisor._external_effects_lock:
                    self._effect_token = (
                        self._durable_delivery.store.arm_external_effect(
                            self._durable_delivery.source_event_id,
                            self._durable_delivery.claim_token,
                            self._effect_kind,
                            self._authority,
                        )
                    )
                    if not _is_sha256(self._effect_token):
                        raise WorkerContainmentFatalError(
                            "durable effect store returned a malformed token"
                        )
                    armed = True
                    self._supervisor._register_external_effect(
                        self,
                        self._request_effect_scope,
                    )
                    registered = True
            except BaseException as error:
                if registered:
                    self._supervisor._unregister_external_effect(self)
                if armed and self._effect_token is not None:
                    try:
                        self._durable_delivery.store.retire_external_effect(
                            self._durable_delivery.source_event_id,
                            self._durable_delivery.claim_token,
                            self._effect_token,
                        )
                    except BaseException as cleanup_error:
                        error.add_note(
                            "also failed to retire rejected external effect: "
                            f"{cleanup_error}"
                        )
                self._effect_token = None
                self._closed = True
                raise
            self._entered = True
            return self

    def bind_exact(self, binding: Mapping[str, Any]) -> None:
        if not isinstance(binding, Mapping) or not binding:
            raise WorkerExtinctionError(
                "generic external effect binding is malformed"
            )
        try:
            normalized = json.loads(
                _canonical_json(dict(binding), "external effect binding")
            )
        except (TypeError, ValueError) as error:
            raise WorkerExtinctionError(
                "generic external effect binding is malformed"
            ) from error
        with self._lock:
            if (
                not self._entered
                or self._closed
                or self._binding is not None
                or self._effect_token is None
            ):
                raise WorkerExtinctionError(
                    "generic external effect cannot be rebound"
                )
            self._durable_delivery.store.bind_external_effect(
                self._durable_delivery.source_event_id,
                self._durable_delivery.claim_token,
                self._effect_token,
                normalized,
            )
            self._binding = normalized

    def _extinguish(self) -> None:
        with self._lock:
            if self._closed or self._extinction_proven:
                return
            receipt = self._receipt()
            try:
                proof = self._cleanup(receipt)
            except (KeyboardInterrupt, SystemExit):
                raise
            except BaseException as error:
                raise WorkerExtinctionError(
                    "generic external effect cleanup failed"
                ) from error
            _verify_external_effect_extinction_proof(receipt, proof)
            self._extinction_proven = True

    def _close_proven(self) -> None:
        with self._lock:
            if self._closed:
                return
            if not self._extinction_proven or self._effect_token is None:
                raise WorkerExtinctionError(
                    "generic external effect extinction is unproven"
                )
            self._durable_delivery.store.retire_external_effect(
                self._durable_delivery.source_event_id,
                self._durable_delivery.claim_token,
                self._effect_token,
            )
            self._supervisor._unregister_external_effect(self)
            self._effect_token = None
            self._closed = True

    def __exit__(self, *_exc: object) -> bool:
        self._extinguish()
        self._close_proven()
        return False


def external_effect_supervisor(
    effect_kind: str,
    authority: Mapping[str, Any],
    cleanup: Callable[[ExternalEffectReceipt], ExternalEffectExtinctionProof],
) -> _ExternalEffectSupervisor:
    """Arm a generalized exact effect before its caller admits side effects."""

    supervisor = current_worker_extinction_supervisor()
    if not isinstance(supervisor, WorkerExtinctionSupervisor):
        raise WorkerContainmentUnavailableError(
            "the active supervisor cannot retain generic external effects"
        )
    return _ExternalEffectSupervisor(
        supervisor,
        effect_kind,
        authority,
        cleanup,
    )


class _ExternalContainerSupervisor:
    """Retain an exact pre-create authority until extinction is proven."""

    def __init__(
        self,
        supervisor: WorkerExtinctionSupervisor,
        runtime_binding,
        endpoint_binding,
        timeout: float,
        *,
        container_name: str,
        invocation_token: str,
        cidfile_parent_fd: int,
        cidfile_name: str,
    ) -> None:
        if (
            isinstance(timeout, bool)
            or not isinstance(timeout, (int, float))
            or not math.isfinite(float(timeout))
            or timeout <= 0
        ):
            raise ValueError("container extinction timeout must be positive")
        self._supervisor = supervisor
        self._request_effect_scope = _CURRENT_WORKER_REQUEST_EFFECT_SCOPE.get()
        self._durable_delivery = _CURRENT_DURABLE_DELIVERY.get()
        self._durable_effect_token: str | None = None
        if (
            self._request_effect_scope is not None
            and self._request_effect_scope._supervisor is not supervisor
        ):
            raise WorkerContainmentFatalError(
                "request effect scope belongs to another supervisor"
            )
        self._endpoint_binding = endpoint_binding
        self._runtime_fd = -1
        self._cidfile_parent_fd = -1
        try:
            import legacy_athena
            self._runtime_fd = _duplicate_sealed_runtime_descriptor(runtime_binding.descriptor)
            self._runtime_binding = legacy_athena._BoundExecutable(
                self._runtime_fd, runtime_binding.sha256
            )
            if any(not callable(getattr(endpoint_binding, method, None)) for method in (
                "durable_effect_identity",
                "enter_command",
                "register_effect",
                "release_effect",
            )):
                raise WorkerContainmentUnavailableError("an explicit endpoint broker is required")
            self._engine_endpoint_identity = None
            self._verify_engine_endpoint_identity()
            self._container_name = _validated_container_name(container_name)
            if not _is_sha256(invocation_token):
                raise WorkerContainmentUnavailableError(
                    "pre-create invocation token is malformed"
                )
            self._invocation_token = invocation_token
            if (
                not isinstance(cidfile_name, str)
                or not cidfile_name
                or cidfile_name in {".", ".."}
                or os.sep in cidfile_name
                or "\x00" in cidfile_name
                or len(cidfile_name.encode("utf-8")) > 255
            ):
                raise WorkerContainmentUnavailableError(
                    "container receipt filename is malformed"
                )
            self._cidfile_name = cidfile_name
            (
                self._cidfile_parent_fd,
                self._cidfile_parent_identity,
            ) = _duplicate_private_directory_descriptor(cidfile_parent_fd)
        except BaseException as error:
            for descriptor in (self._cidfile_parent_fd, self._runtime_fd):
                if descriptor >= 0:
                    try:
                        os.close(descriptor)
                    except BaseException as cleanup_error:
                        error.add_note(
                            "also failed to close a rejected container authority: "
                            f"{cleanup_error}"
                        )
            self._cidfile_parent_fd = -1
            self._runtime_fd = -1
            raise
        self._timeout = float(timeout)
        self._container_id: str | None = None
        self._binding_digest: str | None = None
        self._extinction_proven = False
        self._entered = False
        self._closed = False
        self._lock = threading.RLock()

    def _durable_authority(self) -> Mapping[str, Any]:
        return {
            "container_name": self._container_name,
            "engine_endpoint_identity": self._engine_endpoint_identity,
            "invocation_token": self._invocation_token,
        }

    def _verify_engine_endpoint_identity(self) -> None:
        try:
            observed = _validated_engine_endpoint_identity(
                self._endpoint_binding.durable_effect_identity()
            )
        except WorkerContainmentUnavailableError:
            raise
        except BaseException as error:
            raise WorkerContainmentUnavailableError(
                "engine endpoint identity could not be verified"
            ) from error
        retained = getattr(self, "_engine_endpoint_identity", None)
        if retained is None:
            self._engine_endpoint_identity = observed
            return
        if _canonical_json(
            retained, "engine endpoint identity"
        ) != _canonical_json(observed, "engine endpoint identity"):
            raise WorkerContainmentUnavailableError(
                "engine endpoint identity changed before effect admission"
            )

    def _verify_cidfile_parent(self) -> None:
        try:
            info = os.fstat(self._cidfile_parent_fd)
        except OSError as error:
            raise WorkerExtinctionError(
                "container receipt parent is unavailable"
            ) from error
        if (
            (info.st_dev, info.st_ino, info.st_mode, info.st_uid)
            != self._cidfile_parent_identity
            or not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.geteuid()
            or info.st_mode & 0o077
        ):
            raise WorkerExtinctionError("container receipt parent changed")

    def _read_cidfile(self) -> str | None:
        self._verify_cidfile_parent()
        flags = os.O_RDONLY
        for capability in ("O_NOFOLLOW", "O_CLOEXEC"):
            value = getattr(os, capability, None)
            if value is None:
                raise WorkerExtinctionError(
                    f"{capability} is required for container receipts"
                )
            flags |= value
        descriptor = -1
        try:
            try:
                descriptor = os.open(
                    self._cidfile_name,
                    flags,
                    dir_fd=self._cidfile_parent_fd,
                )
            except FileNotFoundError:
                return None
            initial = os.fstat(descriptor)
            entry = os.stat(
                self._cidfile_name,
                dir_fd=self._cidfile_parent_fd,
                follow_symlinks=False,
            )
            identity = (
                initial.st_dev,
                initial.st_ino,
                initial.st_mode,
                initial.st_uid,
                initial.st_nlink,
                initial.st_size,
            )
            if (
                not stat.S_ISREG(initial.st_mode)
                or initial.st_uid != os.geteuid()
                or initial.st_nlink != 1
                or initial.st_mode & 0o022
                or initial.st_size > 128
                or identity
                != (
                    entry.st_dev,
                    entry.st_ino,
                    entry.st_mode,
                    entry.st_uid,
                    entry.st_nlink,
                    entry.st_size,
                )
            ):
                raise WorkerExtinctionError(
                    "container receipt is not one exact private file"
                )
            value = os.read(descriptor, 129)
            final = os.fstat(descriptor)
            if identity != (
                final.st_dev,
                final.st_ino,
                final.st_mode,
                final.st_uid,
                final.st_nlink,
                final.st_size,
            ):
                raise WorkerExtinctionError("container receipt changed while read")
            try:
                container_id = value.decode("ascii", errors="strict").strip()
            except UnicodeDecodeError as error:
                raise WorkerExtinctionError(
                    "container receipt is malformed"
                ) from error
            if not _is_sha256(container_id):
                raise WorkerExtinctionError("container receipt is malformed")
            self._verify_cidfile_parent()
            return container_id
        except WorkerExtinctionError:
            raise
        except OSError as error:
            raise WorkerExtinctionError(
                "container receipt could not be bound"
            ) from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def __enter__(self) -> _ExternalContainerSupervisor:
        with self._lock:
            if self._entered or self._closed:
                raise WorkerExtinctionError(
                    "external container supervisor cannot be reused"
                )
            endpoint_registered = False
            supervisor_registered = False
            durable_registered = False
            try:
                self._verify_engine_endpoint_identity()
                self._verify_cidfile_parent()
                # Hold the seal lock across request admission and helper
                # registration. A handler-return seal and a late child can
                # never both win this boundary.
                with self._supervisor._external_effects_lock:
                    if self._durable_delivery is not None:
                        self._durable_effect_token = (
                            self._durable_delivery.store.arm_external_effect(
                                self._durable_delivery.source_event_id,
                                self._durable_delivery.claim_token,
                                "container",
                                self._durable_authority(),
                            )
                        )
                        durable_registered = True
                    self._supervisor._register_external_effect(
                        self,
                        self._request_effect_scope,
                    )
                    supervisor_registered = True
                    self._endpoint_binding.register_effect(self, self._supervisor)
                    endpoint_registered = True
            except BaseException as error:
                if endpoint_registered:
                    try:
                        self._extinction_proven = True  # No create command was admitted.
                        self._endpoint_binding.release_effect(self)
                    except BaseException as cleanup_error:
                        error.add_note(
                            "also failed to close a rejected cleanup authority: "
                            f"{cleanup_error}"
                        )
                if supervisor_registered:
                    self._supervisor._unregister_external_effect(self)
                if durable_registered and self._durable_effect_token is not None:
                    try:
                        self._durable_delivery.store.retire_external_effect(
                            self._durable_delivery.source_event_id,
                            self._durable_delivery.claim_token,
                            self._durable_effect_token,
                        )
                        self._durable_effect_token = None
                    except BaseException as cleanup_error:
                        error.add_note(
                            "also failed to retire rejected durable effect: "
                            f"{cleanup_error}"
                        )
                for descriptor in (self._cidfile_parent_fd, self._runtime_fd):
                    if descriptor >= 0:
                        try:
                            os.close(descriptor)
                        except BaseException as cleanup_error:
                            error.add_note(
                                "also failed to close a rejected container authority: "
                                f"{cleanup_error}"
                            )
                self._cidfile_parent_fd = -1
                self._runtime_fd = -1
                self._closed = True
                raise
            self._entered = True
        return self

    def __exit__(self, *_exc: object) -> bool:
        with self._lock:
            closed = self._closed
        if not closed:
            self._extinguish()
            self._close_proven()
        return False

    @staticmethod
    def _remaining(deadline: float) -> float:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise WorkerExtinctionError(
                "exact container extinction exceeded its deadline"
            )
        return remaining

    def _run(
        self, arguments: tuple[str, ...], deadline: float
    ) -> tuple[int, bytes, bytes]:
        try:
            result = self._endpoint_binding.enter_command(
                self._runtime_binding, list(arguments),
                timeout_seconds=self._remaining(deadline),
            )
            if (not isinstance(result, subprocess.CompletedProcess)
                    or not isinstance(result.stdout, str) or not isinstance(result.stderr, str)):
                raise WorkerExtinctionError("endpoint broker result is malformed")
            return result.returncode, result.stdout.encode("utf-8"), result.stderr.encode("utf-8")
        except BaseException as error:
            raise WorkerExtinctionError("endpoint broker cleanup authority failed") from error

    def _inspect(
        self,
        candidate: str,
        deadline: float,
    ) -> tuple[str, str] | None:
        returncode, stdout, _stderr = self._run(
            (
                "inspect",
                "--type",
                "container",
                "--format",
                "{{json .}}",
                candidate,
            ),
            deadline,
        )
        if returncode != 0:
            return None
        if len(stdout) > _MAX_CONTAINER_COMMAND_OUTPUT_BYTES:
            raise WorkerExtinctionError(
                "exact container inspection exceeded its output bound"
            )
        try:
            inspection = json.loads(stdout.decode("utf-8"))
            _validate_json_shape(
                inspection,
                "container inspection",
                persisted=True,
            )
            binding_digest = container_binding_digest(inspection)
        except (UnicodeDecodeError, ValueError, StateConflictError) as error:
            raise WorkerExtinctionError(
                "exact container inspection is malformed"
            ) from error
        config = inspection.get("Config") if isinstance(inspection, dict) else None
        labels = config.get("Labels") if isinstance(config, dict) else None
        name = inspection.get("Name") if isinstance(inspection, dict) else None
        if isinstance(name, str):
            name = name.removeprefix("/")
        container_id = inspection.get("Id") if isinstance(inspection, dict) else None
        if (
            not _is_sha256(container_id)
            or name != self._container_name
            or not isinstance(labels, dict)
            or labels.get("homeric.invocation") != self._invocation_token
        ):
            raise WorkerExtinctionError(
                "container inspection conflicts with pre-create authority"
            )
        return container_id, binding_digest

    def _recover_precreated_container(self, deadline: float) -> str | None:
        receipt_id = self._read_cidfile()
        if receipt_id is not None:
            inspected = self._inspect(receipt_id, deadline)
            if inspected is not None:
                return inspected[0]
        returncode, stdout, _stderr = self._run(
            (
                "ps",
                "--all",
                "--quiet",
                "--no-trunc",
                "--filter",
                f"label=homeric.invocation={self._invocation_token}",
            ),
            deadline,
        )
        if returncode != 0 or len(stdout) > _MAX_CONTAINER_COMMAND_OUTPUT_BYTES:
            raise WorkerExtinctionError(
                "pre-create container inventory could not be verified"
            )
        try:
            candidates = stdout.decode("ascii", errors="strict").splitlines()
        except UnicodeDecodeError as error:
            raise WorkerExtinctionError(
                "pre-create container inventory is malformed"
            ) from error
        if not candidates:
            return None
        if len(candidates) != 1 or not _is_sha256(candidates[0]):
            raise WorkerExtinctionError(
                "pre-create container inventory is ambiguous"
            )
        inspected = self._inspect(candidates[0], deadline)
        if inspected is None:
            raise WorkerExtinctionError(
                "pre-create container disappeared before exact binding"
            )
        return inspected[0]

    def bind_exact_container(
        self,
        container_id: str,
        expected_binding_digest: str,
    ) -> None:
        if not _is_sha256(container_id) or not _is_sha256(expected_binding_digest):
            raise WorkerExtinctionError("exact container receipt is malformed")
        with self._lock:
            if not self._entered or self._closed or self._container_id is not None:
                raise WorkerExtinctionError(
                    "exact container receipt cannot be rebound"
                )
            deadline = time.monotonic() + self._timeout
            inspected = self._inspect(container_id, deadline)
            if inspected is None or inspected != (
                container_id,
                expected_binding_digest,
            ):
                raise WorkerExtinctionError(
                    "exact container inspection does not match its receipt"
                )
            receipt_id = self._read_cidfile()
            if receipt_id is not None and receipt_id != container_id:
                raise WorkerExtinctionError(
                    "retained container receipt conflicts with exact binding"
                )
            if self._durable_delivery is not None:
                if self._durable_effect_token is None:
                    raise WorkerExtinctionError(
                        "durable external effect was not armed"
                    )
                self._durable_delivery.store.bind_external_effect(
                    self._durable_delivery.source_event_id,
                    self._durable_delivery.claim_token,
                    self._durable_effect_token,
                    {
                        "binding_digest": expected_binding_digest,
                        "container_id": container_id,
                    },
                )
            self._container_id = container_id
            self._binding_digest = expected_binding_digest

    def _prove_absent(self, container_id: str | None, deadline: float) -> None:
        for _attempt in range(2):
            inventories: list[tuple[str, str]] = [
                (
                    f"label=homeric.invocation={self._invocation_token}",
                    "invocation-token",
                )
            ]
            if container_id is not None:
                inventories.insert(0, (f"id={container_id}", "exact container"))
            for filter_value, inventory in inventories:
                returncode, stdout, _stderr = self._run(
                    (
                        "ps",
                        "--all",
                        "--quiet",
                        "--no-trunc",
                        "--filter",
                        filter_value,
                    ),
                    deadline,
                )
                if returncode != 0 or stdout.strip():
                    raise WorkerExtinctionError(
                        f"{inventory} extinction inventory is not empty"
                    )

    def _close_proven(self) -> None:
        descriptors: tuple[int, int] = (-1, -1)
        with self._lock:
            if self._closed:
                return
            if not self._extinction_proven:
                raise WorkerExtinctionError(
                    "cannot release an unproven exact container receipt"
                )
            # Retirement proves broker descendants extinct before the worker
            # relinquishes this effect. The caller still owns binding.close().
            durable_delivery = getattr(self, "_durable_delivery", None)
            if durable_delivery is not None:
                if getattr(self, "_durable_effect_token", None) is None:
                    raise WorkerExtinctionError(
                        "durable external effect receipt disappeared"
                    )
                durable_delivery.store.retire_external_effect(
                    durable_delivery.source_event_id,
                    durable_delivery.claim_token,
                    self._durable_effect_token,
                )
                self._durable_effect_token = None
            self._endpoint_binding.release_effect(self)
            self._closed = True
            descriptors = (self._cidfile_parent_fd, self._runtime_fd)
            self._cidfile_parent_fd = -1
            self._runtime_fd = -1
            self._supervisor._unregister_external_effect(self)
        failures: list[BaseException] = []
        for descriptor in descriptors:
            if descriptor < 0:
                continue
            try:
                os.close(descriptor)
            except BaseException as error:
                failures.append(error)
        if failures:
            failure = WorkerExtinctionError(
                "exact container authority could not be closed"
            )
            for error in failures:
                failure.add_note(f"container authority close failed: {error}")
            raise failure from failures[0]

    def disarm(self) -> None:
        with self._lock:
            if self._closed:
                return
            deadline = time.monotonic() + self._timeout
            container_id = self._container_id
            if container_id is None:
                container_id = self._recover_precreated_container(deadline)
            if container_id is not None:
                self._prove_absent(container_id, deadline)
            else:
                self._prove_absent(None, deadline)
            self._extinction_proven = True
            self._close_proven()

    def _extinguish(self) -> None:
        with self._lock:
            if self._closed:
                return
            if self._extinction_proven:
                return
            deadline = time.monotonic() + self._timeout
            container_id = self._container_id
            if container_id is None:
                container_id = self._recover_precreated_container(deadline)
                if container_id is None:
                    self._prove_absent(None, deadline)
                    self._extinction_proven = True
                    return
                self._container_id = container_id
            for command in (
                ("stop", "--time", "1", container_id),
                ("kill", container_id),
                ("rm", "--force", container_id),
            ):
                self._run(command, deadline)
            self._prove_absent(container_id, deadline)
            self._extinction_proven = True


def external_container_supervisor(
    runtime_binding,
    endpoint_binding,
    timeout: float,
    *,
    container_name: str,
    invocation_token: str,
    cidfile_parent_fd: int,
    cidfile_name: str,
) -> _ExternalContainerSupervisor:
    """Create an armed exact pre-create authority under the active worker."""

    supervisor = current_worker_extinction_supervisor()
    if not isinstance(supervisor, WorkerExtinctionSupervisor):
        raise WorkerContainmentUnavailableError(
            "the active supervisor cannot retain exact container receipts"
        )
    return _ExternalContainerSupervisor(
        supervisor,
        runtime_binding,
        endpoint_binding,
        timeout,
        container_name=container_name,
        invocation_token=invocation_token,
        cidfile_parent_fd=cidfile_parent_fd,
        cidfile_name=cidfile_name,
    )


def reconcile_external_container_effect(
    receipt: ExternalEffectReceipt,
    runtime_binding: Any,
    endpoint_binding: Any,
    timeout: float,
) -> ExternalEffectExtinctionProof:
    """Extinguish one abandoned container receipt without rearming it.

    This synchronous operation is intended to run directly inside the trusted
    durable-dispatch reconciliation callback. Keeping it in that task, rather
    than detaching it into a cancellable executor future, ensures the kernel
    delivery lease cannot be released while cleanup is still executing.
    """

    if not isinstance(receipt, ExternalEffectReceipt):
        raise WorkerExtinctionError(
            "external container reconciliation receipt is malformed"
        )
    if receipt.effect_kind != "container" or not _is_sha256(
        receipt.effect_token
    ):
        raise WorkerExtinctionError(
            "external container reconciliation kind is unsupported"
        )
    if (
        isinstance(timeout, bool)
        or not isinstance(timeout, (int, float))
        or not math.isfinite(float(timeout))
        or timeout <= 0
    ):
        raise ValueError("container reconciliation timeout must be positive")
    if not isinstance(receipt.authority, Mapping):
        raise WorkerExtinctionError(
            "external container authority is malformed"
        )
    try:
        container_name = _validated_container_name(
            receipt.authority.get("container_name")
        )
    except WorkerContainmentUnavailableError as error:
        raise WorkerExtinctionError(
            "external container authority is malformed"
        ) from error
    invocation_token = receipt.authority.get("invocation_token")
    if not _is_sha256(invocation_token):
        raise WorkerExtinctionError(
            "external container invocation authority is malformed"
        )
    expected_engine_identity = _validated_engine_endpoint_identity(
        receipt.authority.get("engine_endpoint_identity"),
        persisted=True,
    )
    if any(
        not callable(getattr(endpoint_binding, method, None))
        for method in ("durable_effect_identity", "enter_command")
    ):
        raise WorkerExtinctionError(
            "external container reconciliation endpoint is incomplete"
        )

    def verified_engine_identity() -> dict[str, Any]:
        try:
            current = _validated_engine_endpoint_identity(
                endpoint_binding.durable_effect_identity()
            )
        except BaseException as error:
            if isinstance(error, (KeyboardInterrupt, SystemExit)):
                raise
            raise WorkerExtinctionError(
                "external container engine identity is unavailable"
            ) from error
        if _canonical_json(
            current, "engine endpoint identity"
        ) != _canonical_json(
            expected_engine_identity, "engine endpoint identity"
        ):
            raise WorkerExtinctionError(
                "external container engine identity changed before reconciliation"
            )
        return current

    container_id: str | None = None
    binding_digest: str | None = None
    if receipt.binding is not None:
        if not isinstance(receipt.binding, Mapping):
            raise WorkerExtinctionError(
                "external container exact binding is malformed"
            )
        container_id = receipt.binding.get("container_id")
        binding_digest = receipt.binding.get("binding_digest")
        if not _is_sha256(container_id) or not _is_sha256(binding_digest):
            raise WorkerExtinctionError(
                "external container exact binding is malformed"
            )

    current_engine_identity = verified_engine_identity()
    runtime_fd = -1
    primary: BaseException | None = None
    try:
        import legacy_athena

        runtime_fd = _duplicate_sealed_runtime_descriptor(
            runtime_binding.descriptor
        )
        guard = object.__new__(_ExternalContainerSupervisor)
        guard._endpoint_binding = endpoint_binding
        guard._runtime_fd = runtime_fd
        guard._runtime_binding = legacy_athena._BoundExecutable(
            runtime_fd, runtime_binding.sha256
        )
        guard._container_name = container_name
        guard._invocation_token = invocation_token
        guard._timeout = float(timeout)
        deadline = time.monotonic() + float(timeout)

        if container_id is not None:
            inspected = guard._inspect(container_id, deadline)
            if inspected is not None and inspected != (
                container_id,
                binding_digest,
            ):
                raise WorkerExtinctionError(
                    "abandoned container changed from its exact binding"
                )
            if inspected is None:
                guard._prove_absent(container_id, deadline)
                current_engine_identity = verified_engine_identity()
                return external_effect_extinction_proof(
                    receipt, current_engine_identity
                )
        else:
            returncode, stdout, _stderr = guard._run(
                (
                    "ps",
                    "--all",
                    "--quiet",
                    "--no-trunc",
                    "--filter",
                    f"label=homeric.invocation={invocation_token}",
                ),
                deadline,
            )
            if returncode != 0 or len(stdout) > _MAX_CONTAINER_COMMAND_OUTPUT_BYTES:
                raise WorkerExtinctionError(
                    "abandoned pre-create inventory could not be verified"
                )
            try:
                candidates = stdout.decode("ascii", errors="strict").splitlines()
            except UnicodeDecodeError as error:
                raise WorkerExtinctionError(
                    "abandoned pre-create inventory is malformed"
                ) from error
            if len(candidates) > 1 or any(
                not _is_sha256(candidate) for candidate in candidates
            ):
                raise WorkerExtinctionError(
                    "abandoned pre-create inventory is ambiguous"
                )
            if not candidates:
                guard._prove_absent(None, deadline)
                current_engine_identity = verified_engine_identity()
                return external_effect_extinction_proof(
                    receipt, current_engine_identity
                )
            container_id = candidates[0]
            if guard._inspect(container_id, deadline) is None:
                raise WorkerExtinctionError(
                    "abandoned pre-create container disappeared before binding"
                )

        for command in (
            ("stop", "--time", "1", container_id),
            ("kill", container_id),
            ("rm", "--force", container_id),
        ):
            guard._run(command, deadline)
        guard._prove_absent(container_id, deadline)
        current_engine_identity = verified_engine_identity()
        return external_effect_extinction_proof(
            receipt, current_engine_identity
        )
    except (WorkerExtinctionError, KeyboardInterrupt, SystemExit) as error:
        primary = error
        raise
    except BaseException as error:
        failure = WorkerExtinctionError(
            "external container reconciliation failed closed"
        )
        primary = failure
        raise failure from error
    finally:
        if runtime_fd >= 0:
            try:
                os.close(runtime_fd)
            except OSError as error:
                failure = WorkerExtinctionError(
                    "external container reconciliation authority did not close"
                )
                if primary is not None:
                    primary.add_note(f"{failure}: {error}")
                else:
                    raise failure from error


_linux_subreaper_lock = threading.Lock()
_linux_subreaper_users = 0
_linux_subreaper_original_state: int | None = None


class _LinuxSockFilter(ctypes.Structure):
    _fields_ = [
        ("code", ctypes.c_ushort),
        ("jt", ctypes.c_ubyte),
        ("jf", ctypes.c_ubyte),
        ("value", ctypes.c_uint),
    ]


class _LinuxSockFilterProgram(ctypes.Structure):
    _fields_ = [
        ("length", ctypes.c_ushort),
        ("filters", ctypes.POINTER(_LinuxSockFilter)),
    ]


def _linux_seccomp_contract() -> tuple[
    int,
    int,
    int | None,
    tuple[int, ...],
]:
    machine = os.uname().machine.casefold()
    if machine in {"x86_64", "amd64"}:
        return (
            317,
            0xC000003E,
            0x40000000,
            (56, 57, 58, 59, 62, 129, 200, 234, 297, 322, 435),
        )
    if machine in {"aarch64", "arm64"}:
        return (
            277,
            0xC00000B7,
            None,
            (129, 130, 131, 138, 220, 221, 240, 281, 435),
        )
    raise WorkerContainmentUnavailableError(
        f"no verified no-spawn syscall contract exists for {machine!r}"
    )


def _install_linux_no_spawn_filter() -> None:
    """Atomically deny fork/clone/exec across every current worker thread."""

    (
        seccomp_syscall,
        audit_architecture,
        rejected_abi_mask,
        denied_syscalls,
    ) = _linux_seccomp_contract()
    prctl = _linux_prctl()
    ctypes.set_errno(0)
    if prctl(38, 1, 0, 0, 0) != 0:
        error_number = ctypes.get_errno() or errno.ENOTSUP
        raise WorkerContainmentUnavailableError(
            "Linux no-new-privileges containment could not be enabled"
        ) from OSError(error_number, os.strerror(error_number))
    if prctl(39, 0, 0, 0, 0) != 1:
        raise WorkerContainmentUnavailableError(
            "Linux no-new-privileges containment is not active"
        )

    instructions: list[_LinuxSockFilter] = [
        _LinuxSockFilter(0x20, 0, 0, 4),
        _LinuxSockFilter(0x15, 1, 0, audit_architecture),
        _LinuxSockFilter(0x06, 0, 0, 0x80000000),
        _LinuxSockFilter(0x20, 0, 0, 0),
    ]
    if rejected_abi_mask is not None:
        instructions.extend(
            (
                _LinuxSockFilter(0x45, 0, 1, rejected_abi_mask),
                _LinuxSockFilter(0x06, 0, 0, 0x00050000 | errno.EPERM),
            )
        )
    for syscall_number in denied_syscalls:
        instructions.extend(
            (
                _LinuxSockFilter(0x15, 0, 1, syscall_number),
                _LinuxSockFilter(0x06, 0, 0, 0x00050000 | errno.EPERM),
            )
        )
    instructions.append(_LinuxSockFilter(0x06, 0, 0, 0x7FFF0000))
    filter_array_type = _LinuxSockFilter * len(instructions)
    filter_array = filter_array_type(*instructions)
    program = _LinuxSockFilterProgram(len(instructions), filter_array)
    library = ctypes.CDLL(None, use_errno=True)
    syscall = getattr(library, "syscall", None)
    if syscall is None:
        raise WorkerContainmentUnavailableError(
            "Linux seccomp syscall is unavailable"
        )
    syscall.restype = ctypes.c_long
    ctypes.set_errno(0)
    result = syscall(
        seccomp_syscall,
        1,
        1,
        ctypes.byref(program),
    )
    if result != 0:
        error_number = ctypes.get_errno() or errno.ENOTSUP
        raise WorkerContainmentUnavailableError(
            "Linux thread-synchronized no-spawn containment failed"
        ) from OSError(error_number, os.strerror(error_number))


def _linux_prctl() -> Any:
    if not sys.platform.startswith("linux"):
        raise WorkerContainmentUnavailableError(
            "worker process containment requires Linux"
        )
    library = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(library, "prctl", None)
    if prctl is None:
        raise WorkerContainmentUnavailableError(
            "Linux subreaper containment is unavailable"
        )
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    return prctl


def _linux_subreaper_state(prctl: Any) -> int:
    state = ctypes.c_int(0)
    ctypes.set_errno(0)
    if prctl(37, ctypes.addressof(state), 0, 0, 0) != 0:
        error_number = ctypes.get_errno() or errno.ENOTSUP
        raise WorkerContainmentUnavailableError(
            "Linux subreaper state could not be read"
        ) from OSError(error_number, os.strerror(error_number))
    if state.value not in (0, 1):
        raise WorkerContainmentUnavailableError(
            "Linux subreaper state is malformed"
        )
    return state.value


def _acquire_linux_subreaper() -> None:
    global _linux_subreaper_original_state, _linux_subreaper_users
    prctl = _linux_prctl()
    with _linux_subreaper_lock:
        state = _linux_subreaper_state(prctl)
        if _linux_subreaper_users != 0:
            raise WorkerContainmentUnavailableError(
                "a worker extinction supervisor is already active"
            )
        _linux_subreaper_original_state = state
        if state == 0:
            ctypes.set_errno(0)
            if prctl(36, 1, 0, 0, 0) != 0:
                error_number = ctypes.get_errno() or errno.ENOTSUP
                raise WorkerContainmentUnavailableError(
                    "Linux subreaper containment could not be enabled"
                ) from OSError(error_number, os.strerror(error_number))
        if _linux_subreaper_state(prctl) != 1:
            raise WorkerContainmentUnavailableError(
                "Linux subreaper containment is not active"
            )
        _linux_subreaper_users += 1


def _release_linux_subreaper() -> None:
    global _linux_subreaper_original_state, _linux_subreaper_users
    prctl = _linux_prctl()
    with _linux_subreaper_lock:
        if _linux_subreaper_users <= 0:
            raise WorkerExtinctionError(
                "Linux subreaper reference state is inconsistent"
            )
        _linux_subreaper_users -= 1
        if _linux_subreaper_users != 0:
            return
        original = _linux_subreaper_original_state
        _linux_subreaper_original_state = None
        if original == 0:
            ctypes.set_errno(0)
            if prctl(36, 0, 0, 0, 0) != 0:
                error_number = ctypes.get_errno() or errno.ENOTSUP
                raise WorkerExtinctionError(
                    "Linux subreaper containment could not be restored"
                ) from OSError(error_number, os.strerror(error_number))
            if _linux_subreaper_state(prctl) != 0:
                raise WorkerExtinctionError(
                    "Linux subreaper containment remained active"
                )


def _linux_process_record(process_id: int) -> tuple[int, str, int] | None:
    try:
        with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
            content = stream.read(65_537)
    except (FileNotFoundError, ProcessLookupError):
        return None
    if len(content) > 65_536:
        raise WorkerExtinctionError(
            "Linux process identity exceeded its byte bound"
        )
    closing = content.rfind(b")")
    if closing < 1:
        raise WorkerExtinctionError("Linux process identity is malformed")
    fields = content[closing + 2 :].split()
    if len(fields) <= 19 or len(fields[0]) != 1:
        raise WorkerExtinctionError("Linux process identity is incomplete")
    try:
        state = fields[0].decode("ascii")
        return process_id, state, int(fields[19])
    except (UnicodeDecodeError, ValueError) as error:
        raise WorkerExtinctionError(
            "Linux process identity is malformed"
        ) from error


def _linux_process_identity(process_id: int) -> tuple[int, int] | None:
    record = _linux_process_record(process_id)
    if record is None:
        return None
    return record[0], record[2]


def _linux_child_pids(process_id: int) -> set[int]:
    task_root = f"/proc/{process_id}/task"
    try:
        task_ids = tuple(
            entry for entry in os.listdir(task_root) if entry.isdecimal()
        )
    except (FileNotFoundError, ProcessLookupError):
        return set()
    children: set[int] = set()
    for task_id in task_ids:
        try:
            with open(
                f"{task_root}/{task_id}/children",
                "rb",
                buffering=0,
            ) as stream:
                content = stream.read(1_048_577)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if len(content) > 1_048_576:
            raise WorkerExtinctionError(
                "Linux child inventory exceeded its byte bound"
            )
        for value in content.split():
            if not value.isdigit():
                raise WorkerExtinctionError(
                    "Linux child inventory is malformed"
                )
            child = int(value)
            if child > 1:
                children.add(child)
                if len(children) > _MAX_TRACKED_DESCENDANTS:
                    raise WorkerExtinctionError(
                        "Linux child inventory exceeded its process bound"
                    )
    return children


@dataclass(frozen=True)
class LinuxWorkerLimits:
    """Finite aggregate limits for one parent-guarded cgroup-v2 worker."""

    pids_max: int
    memory_max_bytes: int
    memory_swap_max_bytes: int = 0
    pidfd_cap: int = 64
    extinction_timeout: float = 5.0

    def __post_init__(self) -> None:
        if (
            type(self.pids_max) is not int
            or type(self.pidfd_cap) is not int
            or not 1 <= self.pids_max <= self.pidfd_cap
            or self.pidfd_cap > _MAX_TRACKED_DESCENDANTS
        ):
            raise ValueError("cgroup pids/pidfd limits are invalid")
        if (
            type(self.memory_max_bytes) is not int
            or not 1 <= self.memory_max_bytes <= _MAX_CGROUP_MEMORY_BYTES
            or type(self.memory_swap_max_bytes) is not int
            or self.memory_swap_max_bytes != 0
        ):
            raise ValueError("cgroup memory limits are invalid")
        if (
            isinstance(self.extinction_timeout, bool)
            or not isinstance(self.extinction_timeout, (int, float))
            or not math.isfinite(float(self.extinction_timeout))
            or self.extinction_timeout <= 0
        ):
            raise ValueError("cgroup extinction timeout is invalid")


class _ParentCgroupGuardian:
    """Order parent-owned cgroup control through one exact operations object."""

    def __init__(self, operations: Any, limits: LinuxWorkerLimits) -> None:
        if not isinstance(limits, LinuxWorkerLimits):
            raise TypeError("limits must be LinuxWorkerLimits")
        required = (
            "write_control",
            "read_control",
            "verify_kill_control",
            "verify_stopped_worker",
            "attach_process",
            "read_processes",
            "release_process",
            "pidfd_exited",
            "read_events",
        )
        if any(not callable(getattr(operations, name, None)) for name in required):
            raise WorkerContainmentUnavailableError(
                "cgroup guardian operations are incomplete"
            )
        self._operations = operations
        self._limits = limits
        self._prepared = False
        self._worker: tuple[int, int] | None = None

    def prepare(self) -> None:
        if self._prepared:
            raise WorkerContainmentUnavailableError(
                "cgroup guardian cannot be prepared twice"
            )
        controls = (
            ("pids.max", str(self._limits.pids_max)),
            ("memory.max", str(self._limits.memory_max_bytes)),
            ("memory.swap.max", str(self._limits.memory_swap_max_bytes)),
            ("memory.oom.group", "1"),
            ("cgroup.freeze", "0"),
        )
        for name, value in controls:
            self._operations.write_control(name, value)
            if self._operations.read_control(name).strip() != value:
                raise WorkerContainmentUnavailableError(
                    f"cgroup control {name} did not retain its exact limit"
                )
        self._operations.verify_kill_control()
        if tuple(self._operations.read_processes()):
            raise WorkerContainmentUnavailableError(
                "worker cgroup was populated before admission"
            )
        populated, frozen = self._validated_events(
            self._operations.read_events()
        )
        if populated != 0 or frozen != 0:
            raise WorkerContainmentUnavailableError(
                "worker cgroup was not empty and thawed before admission"
            )
        self._prepared = True

    def admit(self, process_id: int, pidfd: int) -> None:
        if (
            not self._prepared
            or self._worker is not None
            or type(process_id) is not int
            or process_id <= 1
            or type(pidfd) is not int
            or pidfd < 0
        ):
            raise WorkerContainmentUnavailableError(
                "cgroup worker admission is not available"
            )
        self._operations.verify_stopped_worker(process_id, pidfd)
        self._operations.attach_process(process_id)
        processes = tuple(self._operations.read_processes())
        if processes != (process_id,):
            raise WorkerContainmentUnavailableError(
                "cgroup worker membership is not exact"
            )
        self._operations.verify_stopped_worker(process_id, pidfd)
        self._worker = (process_id, pidfd)
        self._operations.release_process(pidfd)

    @staticmethod
    def _validated_events(events: object) -> tuple[int, int]:
        if not isinstance(events, Mapping):
            raise WorkerExtinctionError("cgroup events are malformed")
        populated = events.get("populated")
        frozen = events.get("frozen")
        if populated not in (0, 1) or frozen not in (0, 1):
            raise WorkerExtinctionError("cgroup events are malformed")
        return populated, frozen

    def extinguish(self, pidfd: int) -> None:
        if self._worker is None or self._worker[1] != pidfd:
            raise WorkerExtinctionError("cgroup worker receipt changed")
        if not self._operations.pidfd_exited(pidfd):
            raise WorkerExtinctionError(
                "parent cannot extinguish a live worker prematurely"
            )
        deadline = time.monotonic() + float(self._limits.extinction_timeout)
        self._operations.write_control("cgroup.freeze", "1")
        while True:
            populated, frozen = self._validated_events(
                self._operations.read_events()
            )
            if populated == 0 or frozen == 1:
                break
            if time.monotonic() >= deadline:
                raise WorkerExtinctionError(
                    "cgroup did not freeze before its deadline"
                )
            time.sleep(0.005)
        self._operations.write_control("cgroup.kill", "1")
        while True:
            populated, _frozen = self._validated_events(
                self._operations.read_events()
            )
            if populated == 0:
                self._worker = None
                return
            if time.monotonic() >= deadline:
                raise WorkerExtinctionError(
                    "cgroup remained populated after aggregate kill"
                )
            time.sleep(0.005)


def _read_cgroup_control(descriptor: int, name: str) -> str:
    if (
        not isinstance(name, str)
        or not name
        or name in {".", ".."}
        or os.sep in name
    ):
        raise WorkerContainmentUnavailableError(
            "cgroup control name is malformed"
        )
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise WorkerContainmentUnavailableError(
            "O_NOFOLLOW is required for cgroup controls"
        )
    control = os.open(name, flags | nofollow, dir_fd=descriptor)
    try:
        value = os.read(control, 65_537)
        if len(value) > 65_536:
            raise WorkerContainmentUnavailableError(
                "cgroup control exceeded its byte bound"
            )
        return value.decode("ascii", errors="strict")
    except (OSError, UnicodeDecodeError) as error:
        raise WorkerContainmentUnavailableError(
            f"cgroup control {name} could not be read"
        ) from error
    finally:
        os.close(control)


def _write_cgroup_control(descriptor: int, name: str, value: str) -> None:
    _required_text(value, "cgroup control value")
    flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise WorkerContainmentUnavailableError(
            "O_NOFOLLOW is required for cgroup controls"
        )
    control = os.open(name, flags | nofollow, dir_fd=descriptor)
    try:
        payload = value.encode("ascii", errors="strict")
        written = os.write(control, payload)
        if written != len(payload):
            raise WorkerContainmentUnavailableError(
                f"cgroup control {name} accepted a partial write"
            )
    except (OSError, UnicodeEncodeError) as error:
        raise WorkerContainmentUnavailableError(
            f"cgroup control {name} could not be written"
        ) from error
    finally:
        os.close(control)


def inherited_cgroup_v2_parent_fd(
    env: str = "ODYSSEUS_CGROUP_PARENT_FD",
) -> int:
    """Consume a launcher FD and return a caller-owned validated duplicate."""

    if not sys.platform.startswith("linux"):
        raise WorkerContainmentUnavailableError(
            "parent-owned cgroup containment requires Linux"
        )
    raw = os.environ.get(env)
    if raw is None or not raw.isascii() or not raw.isdecimal():
        raise WorkerContainmentUnavailableError(
            "a delegated cgroup-v2 parent descriptor is required"
        )
    source = int(raw)
    if source < 3:
        raise WorkerContainmentUnavailableError(
            "delegated cgroup descriptor is malformed"
        )
    descriptor = -1
    try:
        descriptor = os.dup(source)
        try:
            os.close(source)
        except OSError as error:
            raise WorkerContainmentUnavailableError(
                "delegated cgroup source descriptor could not be consumed"
            ) from error
        os.set_inheritable(descriptor, False)
        info = os.fstat(descriptor)
        if not stat.S_ISDIR(info.st_mode):
            raise WorkerContainmentUnavailableError(
                "delegated cgroup descriptor is not a directory"
            )
        library = ctypes.CDLL(None, use_errno=True)
        fstatfs = getattr(library, "fstatfs", None)
        if fstatfs is None:
            raise WorkerContainmentUnavailableError(
                "cgroup-v2 filesystem verification is unavailable"
            )
        buffer = ctypes.create_string_buffer(256)
        ctypes.set_errno(0)
        if fstatfs(descriptor, ctypes.byref(buffer)) != 0:
            error_number = ctypes.get_errno() or errno.ENOTSUP
            raise WorkerContainmentUnavailableError(
                "delegated cgroup filesystem could not be verified"
            ) from OSError(error_number, os.strerror(error_number))
        if ctypes.c_long.from_buffer(buffer).value != 0x63677270:
            raise WorkerContainmentUnavailableError(
                "delegated containment root is not cgroup v2"
            )
        controllers = set(
            _read_cgroup_control(descriptor, "cgroup.subtree_control").split()
        )
        if not {"memory", "pids"}.issubset(controllers):
            raise WorkerContainmentUnavailableError(
                "delegated cgroup lacks memory/pids subtree control"
            )
        if _read_cgroup_control(descriptor, "cgroup.procs").split():
            raise WorkerContainmentUnavailableError(
                "delegated cgroup parent must be process-free"
            )
        return descriptor
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise


class _DescriptorCgroupOps:
    """Descriptor-relative controls for one randomly named child cgroup."""

    def __init__(self, parent_fd: int, *, process_limit: int) -> None:
        if type(process_limit) is not int or process_limit <= 0:
            raise ValueError("cgroup process limit is invalid")
        self._parent_fd = os.dup(parent_fd)
        os.set_inheritable(self._parent_fd, False)
        self._name = f"odysseus-worker-{secrets.token_hex(16)}"
        self._descriptor = -1
        try:
            os.mkdir(self._name, mode=0o700, dir_fd=self._parent_fd)
            self._descriptor = os.open(
                self._name,
                _lease_directory_flags(),
                dir_fd=self._parent_fd,
            )
            if _read_cgroup_control(self._descriptor, "cgroup.type").strip() != "domain":
                raise WorkerContainmentUnavailableError(
                    "worker cgroup is not a domain cgroup"
                )
        except BaseException:
            self.close(remove=True)
            raise
        self._process_limit = process_limit

    def write_control(self, name: str, value: str) -> None:
        _write_cgroup_control(self._descriptor, name, value)

    def read_control(self, name: str) -> str:
        return _read_cgroup_control(self._descriptor, name)

    def verify_kill_control(self) -> None:
        flags = os.O_WRONLY | getattr(os, "O_CLOEXEC", 0)
        nofollow = getattr(os, "O_NOFOLLOW", None)
        if nofollow is None:
            raise WorkerContainmentUnavailableError(
                "O_NOFOLLOW is required for cgroup controls"
            )
        descriptor = -1
        try:
            descriptor = os.open(
                "cgroup.kill",
                flags | nofollow,
                dir_fd=self._descriptor,
            )
        except OSError as error:
            raise WorkerContainmentUnavailableError(
                "aggregate cgroup kill authority is unavailable"
            ) from error
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def verify_stopped_worker(self, process_id: int, pidfd: int) -> None:
        record = _linux_process_record(process_id)
        if (
            record is None
            or record[1] not in {"T", "t"}
            or LinuxWorkerExtinctionSupervisor._pidfd_exited(pidfd)
        ):
            raise WorkerContainmentUnavailableError(
                "worker did not remain stopped during cgroup admission"
            )

    def attach_process(self, process_id: int) -> None:
        self.write_control("cgroup.procs", str(process_id))

    def read_processes(self) -> tuple[int, ...]:
        values = self.read_control("cgroup.procs").split()
        if len(values) > self._process_limit:
            raise WorkerExtinctionError(
                "cgroup process inventory exceeded its bound"
            )
        if any(not value.isdecimal() or int(value) <= 1 for value in values):
            raise WorkerExtinctionError("cgroup process inventory is malformed")
        return tuple(sorted(int(value) for value in values))

    def release_process(self, pidfd: int) -> None:
        signal.pidfd_send_signal(pidfd, signal.SIGCONT, None, 0)

    def pidfd_exited(self, pidfd: int) -> bool:
        return LinuxWorkerExtinctionSupervisor._pidfd_exited(pidfd)

    def read_events(self) -> dict[str, int]:
        events: dict[str, int] = {}
        for line in self.read_control("cgroup.events").splitlines():
            fields = line.split()
            if len(fields) != 2 or fields[0] in events or not fields[1].isdecimal():
                raise WorkerExtinctionError("cgroup events are malformed")
            events[fields[0]] = int(fields[1])
        return events

    def close(self, *, remove: bool) -> None:
        if self._descriptor >= 0:
            os.close(self._descriptor)
            self._descriptor = -1
        if remove and self._parent_fd >= 0:
            try:
                os.rmdir(self._name, dir_fd=self._parent_fd)
            except FileNotFoundError:
                pass
        if self._parent_fd >= 0:
            os.close(self._parent_fd)
            self._parent_fd = -1


def run_linux_cgroup_worker(
    worker_main: Callable[[LinuxWorkerExtinctionSupervisor], Awaitable[None]],
    *,
    cgroup_parent_fd: int,
    limits: LinuxWorkerLimits,
    _ops: Any | None = None,
) -> int:
    """Run a worker below a guardian; the caller retains ``cgroup_parent_fd``."""

    if not sys.platform.startswith("linux"):
        raise WorkerContainmentUnavailableError(
            "parent-owned cgroup containment requires Linux"
        )
    if not callable(worker_main):
        raise TypeError("worker_main must be callable")
    if threading.active_count() != 1:
        raise WorkerContainmentUnavailableError(
            "cgroup worker bootstrap must run before threads are started"
        )
    if not isinstance(limits, LinuxWorkerLimits):
        raise TypeError("limits must be LinuxWorkerLimits")
    if type(cgroup_parent_fd) is not int or cgroup_parent_fd < 3:
        raise WorkerContainmentUnavailableError(
            "cgroup parent descriptor is malformed"
        )
    operations = (
        _DescriptorCgroupOps(cgroup_parent_fd, process_limit=limits.pids_max)
        if _ops is None
        else _ops
    )
    guardian = _ParentCgroupGuardian(operations, limits)
    child_pid = -1
    child_pidfd = -1
    child_status: int | None = None
    admitted = False
    primary: BaseException | None = None
    try:
        guardian.prepare()
        child_pid = os.fork()
        if child_pid == 0:
            exit_code = 1
            try:
                if isinstance(operations, _DescriptorCgroupOps):
                    operations.close(remove=False)
                # The caller retains this handoff descriptor in the guardian
                # parent. The worker must not inherit a second controller FD.
                os.close(cgroup_parent_fd)
                os.kill(os.getpid(), signal.SIGSTOP)
                with LinuxWorkerExtinctionSupervisor(
                    timeout=float(limits.extinction_timeout),
                    _cgroup_managed=True,
                    _pidfd_cap=limits.pidfd_cap,
                ) as supervisor:
                    asyncio.run(worker_main(supervisor))
                exit_code = 0
            except SystemExit as error:
                exit_code = error.code if type(error.code) is int else 1
            except BaseException:
                exit_code = 1
            os._exit(exit_code)

        waited, stopped_status = os.waitpid(child_pid, os.WUNTRACED)
        if waited != child_pid or not os.WIFSTOPPED(stopped_status):
            raise WorkerContainmentUnavailableError(
                "cgroup worker did not stop at its admission gate"
            )
        identity = _linux_process_identity(child_pid)
        if identity is None:
            raise WorkerContainmentUnavailableError(
                "cgroup worker identity is unavailable"
            )
        child_pidfd = os.pidfd_open(child_pid, 0)
        if _linux_process_identity(child_pid) != identity:
            raise WorkerContainmentUnavailableError(
                "cgroup worker identity changed during admission"
            )
        guardian.admit(child_pid, child_pidfd)
        admitted = True
        while not LinuxWorkerExtinctionSupervisor._pidfd_exited(child_pidfd):
            select.select([child_pidfd], [], [], None)
        waited, child_status = os.waitpid(child_pid, 0)
        if waited != child_pid:
            raise WorkerExtinctionError("cgroup worker could not be reaped")
        guardian.extinguish(child_pidfd)
        admitted = False
        return os.waitstatus_to_exitcode(child_status)
    except BaseException as error:
        primary = error
        raise
    finally:
        cleanup_errors: list[BaseException] = []
        if child_pid > 1 and child_status is None:
            try:
                if child_pidfd >= 0:
                    LinuxWorkerExtinctionSupervisor._signal_pidfd(
                        child_pidfd, signal.SIGKILL
                    )
                else:
                    os.kill(child_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            try:
                waited, child_status = os.waitpid(child_pid, 0)
                if waited != child_pid:
                    raise WorkerExtinctionError(
                        "failed cgroup worker could not be reaped"
                    )
            except BaseException as cleanup_error:
                cleanup_errors.append(cleanup_error)
        if (
            (admitted or getattr(guardian, "_worker", None) is not None)
            and child_pidfd >= 0
        ):
            try:
                guardian.extinguish(child_pidfd)
            except BaseException as cleanup_error:
                cleanup_errors.append(cleanup_error)
        if child_pidfd >= 0:
            try:
                os.close(child_pidfd)
            except BaseException as cleanup_error:
                cleanup_errors.append(cleanup_error)
        close = getattr(operations, "close", None)
        if callable(close):
            try:
                close(remove=True)
            except BaseException as cleanup_error:
                cleanup_errors.append(cleanup_error)
        if primary is not None:
            for cleanup_error in cleanup_errors:
                primary.add_note(
                    f"also failed during cgroup guardian cleanup: {cleanup_error}"
                )
        elif cleanup_errors:
            failure = cleanup_errors.pop(0)
            for cleanup_error in cleanup_errors:
                failure.add_note(
                    f"also failed during cgroup guardian cleanup: {cleanup_error}"
                )
            raise failure


class LinuxWorkerExtinctionSupervisor(WorkerExtinctionSupervisor):
    """Contain post-activation descendants with subreaper state and pidfds."""

    def __init__(
        self,
        *,
        timeout: float = 5.0,
        _cgroup_managed: bool = False,
        _pidfd_cap: int = _MAX_TRACKED_DESCENDANTS,
    ) -> None:
        if (
            isinstance(timeout, bool)
            or not isinstance(timeout, (int, float))
            or not math.isfinite(float(timeout))
            or timeout <= 0
        ):
            raise ValueError("worker extinction timeout must be positive")
        if not callable(getattr(os, "pidfd_open", None)) or not callable(
            getattr(signal, "pidfd_send_signal", None)
        ):
            raise WorkerContainmentUnavailableError(
                "Linux pidfd containment is unavailable"
            )
        super().__init__()
        if type(_cgroup_managed) is not bool:
            raise TypeError("cgroup managed marker must be boolean")
        if (
            type(_pidfd_cap) is not int
            or not 1 <= _pidfd_cap <= _MAX_TRACKED_DESCENDANTS
        ):
            raise ValueError("worker pidfd cap is invalid")
        _linux_seccomp_contract()
        self._timeout = float(timeout)
        self._process_lock = threading.RLock()
        self._fatal_lock = threading.Lock()
        self._owned_processes: dict[int, tuple[int, int]] = {}
        self._max_tracked_descendants = _pidfd_cap
        self._cgroup_managed = _cgroup_managed
        self._cleanup_executors: dict[int, int] = {}
        self._self_pidfd = -1
        self._subreaper_acquired = False
        self._no_spawn_barrier_installed = False
        self._closed = False
        try:
            _acquire_linux_subreaper()
            self._subreaper_acquired = True
            existing = {
                identity
                for child in _linux_child_pids(os.getpid())
                if (identity := _linux_process_identity(child)) is not None
            }
            if existing:
                raise WorkerContainmentUnavailableError(
                    "worker containment must activate before child processes"
                )
            own_identity = _linux_process_identity(os.getpid())
            if own_identity is None:
                raise WorkerContainmentUnavailableError(
                    "worker process identity is unavailable"
                )
            self._self_pidfd = os.pidfd_open(os.getpid(), 0)
            if _linux_process_identity(os.getpid()) != own_identity:
                raise WorkerContainmentUnavailableError(
                    "worker process identity changed while binding its pidfd"
                )
        except BaseException:
            self._close_descriptors()
            if self._subreaper_acquired:
                self._subreaper_acquired = False
                _release_linux_subreaper()
            raise

    def __enter__(self) -> LinuxWorkerExtinctionSupervisor:
        return self

    def __exit__(self, *_exc: object) -> bool:
        self.close()
        return False

    @staticmethod
    def _pidfd_exited(descriptor: int) -> bool:
        ready, _writable, _exceptional = select.select(
            [descriptor], [], [], 0
        )
        return bool(ready)

    @staticmethod
    def _signal_pidfd(descriptor: int, signal_number: int) -> None:
        try:
            signal.pidfd_send_signal(descriptor, signal_number, None, 0)
        except ProcessLookupError:
            pass

    def _track_process(self, process_id: int) -> bool:
        identity = _linux_process_identity(process_id)
        if identity is None:
            return False
        previous = self._owned_processes.get(process_id)
        if previous is not None and previous[0] == identity[1]:
            return False
        if (
            previous is None
            and len(self._owned_processes) >= self._max_tracked_descendants
        ):
            raise WorkerExtinctionError(
                "Linux descendant pidfd inventory reached its bound"
            )
        if previous is not None:
            os.close(previous[1])
        try:
            descriptor = os.pidfd_open(process_id, 0)
        except ProcessLookupError:
            return False
        rebound = _linux_process_identity(process_id)
        if rebound != identity:
            os.close(descriptor)
            if rebound is None:
                return False
            raise WorkerExtinctionError(
                "Linux process identity changed while binding its pidfd"
            )
        self._owned_processes[process_id] = (identity[1], descriptor)
        return True

    def _register_cleanup_executor(self, identity: tuple[int, int]) -> None:
        process_id, start_time = identity
        with self._external_effects_lock:
            if self._extinction_started:
                raise WorkerExtinctionError(
                    "worker extinction already sealed cleanup authorities"
                )
            with self._process_lock:
                if (
                    process_id in self._cleanup_executors
                    or _linux_process_identity(process_id) != identity
                ):
                    raise WorkerContainmentUnavailableError(
                        "cleanup authority identity could not be registered"
                    )
                self._cleanup_executors[process_id] = start_time

    def _unregister_cleanup_executor(self, identity: tuple[int, int]) -> None:
        process_id, start_time = identity
        with self._process_lock:
            if self._cleanup_executors.get(process_id) != start_time:
                raise WorkerExtinctionError(
                    "cleanup authority registration changed"
                )
            if _linux_process_identity(process_id) == identity:
                raise WorkerExtinctionError(
                    "cannot release a live cleanup authority"
                )
            del self._cleanup_executors[process_id]

    def _discover_processes(self) -> None:
        with self._process_lock:
            while True:
                candidates = set(_linux_child_pids(os.getpid()))
                for process_id, start_time in self._cleanup_executors.items():
                    if _linux_process_identity(process_id) == (
                        process_id,
                        start_time,
                    ):
                        candidates.discard(process_id)
                for process_id, (start_time, descriptor) in tuple(
                    self._owned_processes.items()
                ):
                    if (
                        not self._pidfd_exited(descriptor)
                        and _linux_process_identity(process_id)
                        == (process_id, start_time)
                    ):
                        candidates.update(_linux_child_pids(process_id))
                changed = False
                for process_id in candidates:
                    changed = self._track_process(process_id) or changed
                if not changed:
                    return

    def _live_processes(self) -> tuple[tuple[int, int], ...]:
        self._discover_processes()
        with self._process_lock:
            return tuple(
                (process_id, descriptor)
                for process_id, (_start_time, descriptor) in (
                    self._owned_processes.items()
                )
                if not self._pidfd_exited(descriptor)
            )

    def _reap_owned_processes(self) -> None:
        with self._process_lock:
            entries = tuple(self._owned_processes.items())
        for process_id, (_start_time, descriptor) in entries:
            if not self._pidfd_exited(descriptor):
                continue
            try:
                os.waitpid(process_id, os.WNOHANG)
            except ChildProcessError:
                pass
            with self._process_lock:
                current = self._owned_processes.get(process_id)
                if current is None or current[1] != descriptor:
                    continue
                del self._owned_processes[process_id]
            os.close(descriptor)

    def _owned_process_identities_exist(self) -> bool:
        with self._process_lock:
            entries = tuple(self._owned_processes.items())
        return any(
            _linux_process_identity(process_id) == (process_id, start_time)
            for process_id, (start_time, _descriptor) in entries
        )

    def _install_no_spawn_barrier(self) -> None:
        if self._no_spawn_barrier_installed:
            return
        _install_linux_no_spawn_filter()
        self._no_spawn_barrier_installed = True

    def _all_live_processes_stopped(
        self,
        live: tuple[tuple[int, int], ...],
    ) -> bool:
        with self._process_lock:
            identities = {
                process_id: start_time
                for process_id, (start_time, _descriptor) in (
                    self._owned_processes.items()
                )
            }
        for process_id, descriptor in live:
            if self._pidfd_exited(descriptor):
                continue
            record = _linux_process_record(process_id)
            if (
                record is None
                or identities.get(process_id) != record[2]
                or record[1] not in {"T", "t"}
            ):
                return False
        return True

    def _freeze_descendant_membership(self, deadline: float) -> None:
        stable: frozenset[int] | None = None
        while True:
            live = self._live_processes()
            if not live:
                self._reap_owned_processes()
                if not self._owned_process_identities_exist():
                    return
            for _process_id, descriptor in live:
                self._signal_pidfd(descriptor, signal.SIGSTOP)
            time.sleep(0.005)
            current = self._live_processes()
            current_ids = frozenset(process_id for process_id, _fd in current)
            if self._all_live_processes_stopped(current):
                if stable == current_ids:
                    return
                stable = current_ids
            else:
                stable = None
            if time.monotonic() >= deadline:
                raise WorkerExtinctionError(
                    "descendant membership could not be frozen before extinction"
                )

    def _extinguish_descendants(self) -> None:
        deadline = time.monotonic() + self._timeout
        reserve = max(0.01, min(0.5, self._timeout / 3))
        freeze_deadline = max(time.monotonic(), deadline - reserve)
        self._freeze_descendant_membership(freeze_deadline)
        while True:
            live = self._live_processes()
            if not live:
                self._reap_owned_processes()
                if (
                    not self._live_processes()
                    and not self._owned_process_identities_exist()
                ):
                    return
            for _process_id, descriptor in live:
                self._signal_pidfd(descriptor, signal.SIGKILL)
            self._reap_owned_processes()
            if time.monotonic() >= deadline:
                break
            time.sleep(0.01)
        live = self._live_processes()
        self._reap_owned_processes()
        if (
            live
            or self._live_processes()
            or self._owned_process_identities_exist()
        ):
            raise WorkerExtinctionError(
                "owned descendant processes survived worker extinction"
            )

    def _extinguish_owned_effects(self) -> None:
        if self._closed:
            raise WorkerExtinctionError("worker extinction supervisor is closed")
        with self._external_effects_lock:
            self._extinction_started = True
        try:
            self._install_no_spawn_barrier()
        except BaseException as error:
            raise WorkerExtinctionError(
                "kernel no-spawn containment could not be established"
            ) from error
        try:
            self._extinguish_descendants()
        except BaseException as error:
            raise WorkerExtinctionError(
                "creator descendants could not be proven extinct"
            ) from error
        try:
            self._extinguish_registered_effects()
        except BaseException as error:
            raise WorkerExtinctionError(
                "external effects could not be proven extinct after containment"
            ) from error
        try:
            self._release_registered_effects()
        except BaseException as error:
            raise WorkerExtinctionError(
                "worker-owned effect receipts could not be released"
            ) from error

    def _extinguish_and_terminate_sync(self, reason: str) -> None:
        _required_text(reason, "worker extinction reason")
        with self._fatal_lock:
            self._extinguish_owned_effects()
            if self._self_pidfd < 0:
                raise WorkerExtinctionError(
                    "worker pidfd is unavailable after extinction proof"
                )
            signal.pidfd_send_signal(
                self._self_pidfd,
                signal.SIGKILL,
                None,
                0,
            )
            raise WorkerExtinctionError(
                "worker SIGKILL returned without terminating the process"
            )

    async def extinguish_and_terminate(self, reason: str) -> None:
        await asyncio.to_thread(self._extinguish_and_terminate_sync, reason)

    def _close_descriptors(self) -> None:
        with self._process_lock:
            descriptors = [
                descriptor
                for _start_time, descriptor in self._owned_processes.values()
            ]
            self._owned_processes.clear()
            if self._self_pidfd >= 0:
                descriptors.append(self._self_pidfd)
                self._self_pidfd = -1
        for descriptor in descriptors:
            os.close(descriptor)

    def close(self) -> None:
        if self._closed:
            return
        with self._external_effects_lock:
            if self._external_effects:
                raise WorkerExtinctionError(
                    "cannot close a supervisor with armed external receipts"
                )
        with self._process_lock:
            if self._cleanup_executors:
                raise WorkerExtinctionError(
                    "cannot close a supervisor with live cleanup authorities"
                )
        if self._live_processes():
            raise WorkerExtinctionError(
                "cannot close a supervisor with live owned descendants"
            )
        self._reap_owned_processes()
        if self._owned_process_identities_exist():
            raise WorkerExtinctionError(
                "cannot close a supervisor with unreaped owned descendants"
            )
        self._close_descriptors()
        if self._subreaper_acquired:
            self._subreaper_acquired = False
            _release_linux_subreaper()
        self._closed = True


def _verified_git_descriptor() -> tuple[int, tuple[int, int]]:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", None)
    if nofollow is None:
        raise StateLocationError("O_NOFOLLOW is required for Git inspection")
    descriptor = -1
    try:
        descriptor = os.open(_GIT_EXECUTABLE, flags | nofollow)
        info = os.fstat(descriptor)
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != 0
            or info.st_mode & 0o022
        ):
            raise StateLocationError(
                "the fixed Git executable is not a root-owned immutable file"
            )
        return descriptor, (info.st_dev, info.st_ino)
    except BaseException as error:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to close the rejected Git descriptor: "
                    f"{cleanup_error}"
                )
        raise


def _run_git(workdir: Path, *args: str) -> str:
    if not _secure_descriptor_routes_supported():
        raise StateLocationError(
            "secure Git inspection requires Linux /proc/self/fd"
        )
    checkout: _BoundLockDirectory | None = None
    git_descriptor = -1
    primary: BaseException | None = None
    try:
        checkout = _open_existing_directory_chain(workdir)
        git_descriptor, git_identity = _verified_git_descriptor()
        checkout.verify()
        executable = f"/proc/self/fd/{git_descriptor}"
        retained_checkout = f"/proc/self/fd/{checkout.descriptor}"
        returncode, stdout_bytes, stderr_bytes = _run_bounded_process(
            [
                executable,
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "core.fsmonitor=false",
                "-C",
                retained_checkout,
                *args,
            ],
            env={
                "GIT_CONFIG_GLOBAL": "/dev/null",
                "GIT_CONFIG_NOSYSTEM": "1",
                "GIT_CONFIG_SYSTEM": "/dev/null",
                "GIT_OPTIONAL_LOCKS": "0",
                "GIT_TERMINAL_PROMPT": "0",
                "HOME": "/nonexistent",
                "LANG": "C",
                "LC_ALL": "C",
                "PATH": "/usr/bin:/bin",
            },
            pass_fds=(git_descriptor, checkout.descriptor),
            timeout=_GIT_TIMEOUT_SECONDS,
            output_limit=_MAX_GIT_OUTPUT_BYTES,
        )
        checkout.verify()
        after = os.fstat(git_descriptor)
        if (after.st_dev, after.st_ino) != git_identity:
            raise StateLocationError("the fixed Git executable changed")
        try:
            stdout_text = stdout_bytes.decode("utf-8")
            stderr_text = stderr_bytes.decode("utf-8")
        except UnicodeDecodeError as error:
            raise StateLocationError("Git returned non-UTF-8 output") from error
    except StateLocationError as error:
        primary = error
        raise
    except (OSError, subprocess.SubprocessError) as error:
        mapped = StateLocationError(f"could not inspect Git state: {error}")
        primary = mapped
        raise mapped from error
    except BaseException as error:
        primary = error
        raise
    finally:
        cleanup_errors: list[BaseException] = []
        if git_descriptor >= 0:
            try:
                os.close(git_descriptor)
            except BaseException as error:
                cleanup_errors.append(error)
        if checkout is not None:
            try:
                checkout.close()
            except BaseException as error:
                cleanup_errors.append(error)
        if primary is not None:
            for error in cleanup_errors:
                primary.add_note(f"also failed during Git cleanup: {error}")
        elif cleanup_errors:
            cleanup_error = cleanup_errors.pop(0)
            for error in cleanup_errors:
                cleanup_error.add_note(f"also failed during Git cleanup: {error}")
            raise cleanup_error
    if returncode != 0:
        detail = stderr_text.strip() or "git rev-parse failed"
        raise StateLocationError(f"could not resolve Git state: {detail}")
    output = stdout_text.strip()
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
        _verify_state_parent_directory(os.fstat(binding.descriptor))
        repeated_common = Path(
            _run_git(checkout, "rev-parse", "--git-common-dir")
        )
        if not repeated_common.is_absolute():
            repeated_common = checkout / repeated_common
        if repeated_common.resolve(strict=True) != common:
            raise StateLocationError("Git common directory changed while binding")
        binding.verify()
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

    binding: _BoundLockDirectory | None = None
    try:
        binding = _bind_state_root(workdir)
        return binding.path
    finally:
        if binding is not None:
            binding.close()


def _default_host_id() -> str:
    return _required_text(socket.gethostname(), "host_id")


class _BoundCursor(sqlite3.Cursor):
    """Revalidate a bound connection around lazy SQLite cursor work."""

    def _connection(self) -> _BoundConnection:
        connection = self.connection
        if not isinstance(connection, _BoundConnection):
            raise StateLocationError("SQLite cursor lost its bound connection")
        return connection

    def execute(self, *args: Any, **kwargs: Any) -> _BoundCursor:
        connection = self._connection()
        return connection._guarded_call(
            lambda: super(_BoundCursor, self).execute(*args, **kwargs)
        )

    def executemany(self, *args: Any, **kwargs: Any) -> _BoundCursor:
        connection = self._connection()
        return connection._guarded_call(
            lambda: super(_BoundCursor, self).executemany(*args, **kwargs)
        )

    def executescript(self, *args: Any, **kwargs: Any) -> _BoundCursor:
        connection = self._connection()
        return connection._guarded_call(
            lambda: super(_BoundCursor, self).executescript(*args, **kwargs)
        )

    def _finish_pending(self, operation: Callable[[], Any]) -> Any:
        connection = self._connection()
        # Fetching can finish lazy SQLite work, but no mutation between the
        # preceding execute and this continuation belongs to this call. Keep
        # the strict pre-check, then refresh only after the owned continuation.
        return connection._guarded_call(operation)

    def fetchone(self) -> Any:
        return self._finish_pending(
            lambda: super(_BoundCursor, self).fetchone()
        )

    def fetchmany(self, size: int | None = None) -> list[Any]:
        if size is None:
            return self._finish_pending(
                lambda: super(_BoundCursor, self).fetchmany()
            )
        return self._finish_pending(
            lambda: super(_BoundCursor, self).fetchmany(size)
        )

    def fetchall(self) -> list[Any]:
        return self._finish_pending(
            lambda: super(_BoundCursor, self).fetchall()
        )

    def __next__(self) -> Any:
        return self._finish_pending(
            lambda: super(_BoundCursor, self).__next__()
        )


class _BoundConnection(sqlite3.Connection):
    """SQLite connection that revalidates its guarded path around operations."""

    _guard_directory: _BoundLockDirectory | None = None
    _guard_file_descriptor: int | None = None
    _guard_database_name: str | None = None
    _guard_database_identity: tuple[int, int] | None = None
    _guard_database_metadata: list[tuple[int, int, int]] | None = None
    _guard_sidecar_identities: dict[str, tuple[int, int]] | None = None
    _guard_sidecar_metadata: dict[str, tuple[int, int, int]] | None = None
    _sqlite_descriptor: int | None = None
    _guard_state_lease: Any = None
    _guard_failed = False

    def _verify_paths(self, *, refresh_metadata: bool = False) -> None:
        if self._guard_directory is None:
            return
        if (
            self._guard_file_descriptor is None
            or self._guard_database_name is None
            or self._guard_database_identity is None
            or self._guard_database_metadata is None
            or self._guard_sidecar_identities is None
            or self._guard_sidecar_metadata is None
        ):
            raise StateLocationError("runtime database guard is incomplete")
        try:
            _verify_runtime_paths(
                self._guard_directory,
                self._guard_file_descriptor,
                self._guard_database_name,
                self._guard_database_identity,
                self._guard_database_metadata,
                self._guard_sidecar_identities,
                self._guard_sidecar_metadata,
                refresh_metadata=refresh_metadata,
            )
        except BaseException:
            self._guard_failed = True
            raise

    def _verify_binding(self, *, refresh_metadata: bool = False) -> None:
        self._verify_paths(refresh_metadata=refresh_metadata)
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
        primary: BaseException | None = None
        try:
            return operation()
        except BaseException as error:
            primary = error
            raise
        finally:
            try:
                self._verify_binding(refresh_metadata=True)
            except BaseException as verification_error:
                if primary is not None:
                    primary.add_note(
                        f"also failed the post-operation state check: "
                        f"{verification_error}"
                    )
                else:
                    raise

    def execute(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        cursor = super().cursor(factory=_BoundCursor)
        return cursor.execute(*args, **kwargs)

    def executemany(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        cursor = super().cursor(factory=_BoundCursor)
        return cursor.executemany(*args, **kwargs)

    def executescript(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        cursor = super().cursor(factory=_BoundCursor)
        return cursor.executescript(*args, **kwargs)

    def cursor(self, *args: Any, **kwargs: Any) -> sqlite3.Cursor:
        kwargs.setdefault("factory", _BoundCursor)
        return self._guarded_call(
            lambda: super(_BoundConnection, self).cursor(*args, **kwargs)
        )

    def commit(self) -> None:
        self._guarded_call(lambda: super(_BoundConnection, self).commit())

    def rollback(self) -> None:
        self._guarded_call(lambda: super(_BoundConnection, self).rollback())

    def close(self) -> None:
        directory = self._guard_directory
        file_descriptor = self._guard_file_descriptor
        sqlite_descriptor = self._sqlite_descriptor
        state_lease = self._guard_state_lease
        verification_error: BaseException | None = None
        sqlite_closed = False
        try:
            if directory is not None and not self._guard_failed:
                try:
                    self._verify_binding()
                except BaseException as error:
                    verification_error = error
            close_deadline = time.monotonic() + _SQLITE_LEASE_TIMEOUT_SECONDS
            with _bounded_sqlite_descriptor_guard(close_deadline):
                try:
                    super().close()
                    sqlite_closed = True
                except BaseException as error:
                    if verification_error is None:
                        verification_error = error
            if directory is not None and not self._guard_failed:
                try:
                    self._verify_paths(refresh_metadata=True)
                except BaseException as error:
                    if verification_error is None:
                        verification_error = error
        except BaseException as error:
            if verification_error is not None:
                error.add_note(
                    "also failed the pre-close state verification: "
                    f"{verification_error}"
                )
            verification_error = error
        finally:
            cleanup_errors: list[BaseException] = []
            if sqlite_closed:
                self._guard_directory = None
                self._guard_file_descriptor = None
                self._guard_database_name = None
                self._guard_database_identity = None
                self._guard_database_metadata = None
                self._guard_sidecar_identities = None
                self._guard_sidecar_metadata = None
                self._sqlite_descriptor = None
                self._guard_state_lease = None
                self._guard_failed = False
                if file_descriptor is not None:
                    try:
                        os.close(file_descriptor)
                    except BaseException as error:
                        cleanup_errors.append(error)
                if sqlite_descriptor is not None:
                    try:
                        os.close(sqlite_descriptor)
                    except BaseException as error:
                        cleanup_errors.append(error)
                if directory is not None:
                    try:
                        directory.close()
                    except BaseException as error:
                        cleanup_errors.append(error)
                if state_lease is not None:
                    try:
                        state_lease.close()
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


def _verify_state_parent_directory(info: os.stat_result) -> None:
    """Require the service to own the namespace entry's protected parent."""

    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.geteuid()
        or info.st_mode & 0o022
    ):
        raise StateLocationError(
            "runtime state parent must be service-owned and not writable by "
            "other UIDs"
        )


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

    before_database_count = sum(
        (info.st_dev, info.st_ino) == database_identity
        for info in before.values()
    )
    database_descriptors = sorted(
        descriptor
        for descriptor, info in after.items()
        if (info.st_dev, info.st_ino) == database_identity
    )
    # Descriptor numbers can be reused if an unrelated object is finalized
    # during sqlite3.connect. Bind by the inode-count increase, not set
    # subtraction on descriptor integers. A transient route to another inode
    # cannot produce the required +1 database count.
    if len(database_descriptors) != before_database_count + 1:
        raise StateLocationError(
            "sqlite3.connect opened an unidentifiable database descriptor set"
        )
    descriptor = -1
    try:
        descriptor = os.dup(database_descriptors[-1])
        os.set_inheritable(descriptor, False)
        _verify_private_file(
            os.fstat(descriptor),
            "SQLite opened database",
            expected_identity=database_identity,
        )
        return descriptor
    except BaseException as error:
        if descriptor >= 0:
            try:
                os.close(descriptor)
            except BaseException as cleanup_error:
                error.add_note(
                    "also failed to close the rejected SQLite proof descriptor: "
                    f"{cleanup_error}"
                )
        raise


def _verify_runtime_paths(
    directory: _BoundLockDirectory,
    file_descriptor: int,
    database_name: str,
    database_identity: tuple[int, int],
    database_metadata: list[tuple[int, int, int]],
    sidecar_identities: dict[str, tuple[int, int]],
    sidecar_metadata: dict[str, tuple[int, int, int]],
    *,
    refresh_metadata: bool = False,
    allow_new_sidecars: bool = False,
) -> None:
    """Fail closed if SQLite's path or a sidecar is redirected or replaced."""

    try:
        directory.verify()
        _verify_state_parent_directory(os.fstat(directory.parent_descriptor))
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
        current_database_metadata = (
            path_database.st_size,
            path_database.st_mtime_ns,
            path_database.st_ctime_ns,
        )
        if database_metadata and (
            not refresh_metadata
            and database_metadata[0] != current_database_metadata
        ):
            raise StateLocationError("runtime database changed outside its connection")
        database_metadata[:] = [current_database_metadata]

        for suffix in ("-journal", "-wal", "-shm"):
            sidecar_name = f"{database_name}{suffix}"
            try:
                sidecar = os.stat(
                    sidecar_name,
                    dir_fd=directory.descriptor,
                    follow_symlinks=False,
                )
            except FileNotFoundError:
                if sidecar_name in sidecar_identities and not (
                    refresh_metadata or allow_new_sidecars
                ):
                    raise StateLocationError(
                        f"SQLite sidecar {sidecar_name} disappeared"
                    )
                if refresh_metadata or allow_new_sidecars:
                    sidecar_identities.pop(sidecar_name, None)
                    sidecar_metadata.pop(sidecar_name, None)
                continue
            _verify_private_file(sidecar, f"SQLite sidecar {sidecar_name}")
            identity = (sidecar.st_dev, sidecar.st_ino)
            expected_identity = sidecar_identities.get(sidecar_name)
            if expected_identity is None:
                if not (allow_new_sidecars or refresh_metadata):
                    raise StateLocationError(
                        f"SQLite sidecar {sidecar_name} appeared outside its "
                        "connection"
                    )
                sidecar_identities[sidecar_name] = identity
            elif identity != expected_identity:
                raise StateLocationError(
                    f"SQLite sidecar {sidecar_name} changed inode"
                )
            current_metadata = (
                sidecar.st_size,
                sidecar.st_mtime_ns,
                sidecar.st_ctime_ns,
            )
            expected_metadata = sidecar_metadata.get(sidecar_name)
            if (
                expected_metadata is not None
                and not refresh_metadata
                and expected_metadata != current_metadata
            ):
                raise StateLocationError(
                    f"SQLite sidecar {sidecar_name} changed outside its connection"
                )
            sidecar_metadata[sidecar_name] = current_metadata
    except StateLocationError:
        raise
    except OSError as error:
        raise StateLocationError(
            f"could not revalidate durable runtime state: {error}"
        ) from error


def _descriptor_sqlite_route_supported() -> bool:
    """Return whether Linux procfs exposes stable descriptor-relative paths."""
    return _secure_descriptor_routes_supported()


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
        self.candidate_uid = _validated_candidate_uid(self.service_uid)
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
        state_directory: _BoundLockDirectory | None = None
        state_directory_finalizer: weakref.finalize | None = None
        try:
            state_directory = (
                _state_directory
                if _state_directory is not None
                else _open_existing_directory_chain(self.database.parent)
            )
            state_directory.verify()
            _verify_private_directory(os.fstat(state_directory.descriptor))
            _verify_state_parent_directory(
                os.fstat(state_directory.parent_descriptor)
            )
            state_device, state_inode = state_directory.identity
            self._state_directory = state_directory
            self._state_lease_key = _digest(
                f"{state_device}:{state_inode}:{self.database.name}"
            )
            state_directory_finalizer = weakref.finalize(
                self,
                state_directory.close,
            )
            self._state_directory_finalizer = state_directory_finalizer
            self._initialize()
        except BaseException as error:
            try:
                if state_directory_finalizer is not None:
                    state_directory_finalizer()
                elif state_directory is not None:
                    state_directory.close()
            except BaseException as cleanup_error:
                error.add_note(
                    "also failed to close the runtime state binding: "
                    f"{cleanup_error}"
                )
            raise

    def _bind_database_inode(
        self,
    ) -> tuple[_BoundLockDirectory, int, os.stat_result]:
        directory: _BoundLockDirectory | None = None
        file_flags = os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC
        file_descriptor = -1
        bound = False
        primary: BaseException | None = None
        try:
            self._state_directory.verify()
            _verify_state_parent_directory(
                os.fstat(self._state_directory.parent_descriptor)
            )
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
        except StateLocationError as error:
            primary = error
            raise
        except OSError as error:
            primary = error
            raise StateLocationError(
                f"could not bind durable runtime state: {error}"
            ) from error
        except BaseException as error:
            primary = error
            raise
        finally:
            if not bound:
                if file_descriptor >= 0:
                    try:
                        os.close(file_descriptor)
                    except BaseException as cleanup_error:
                        if primary is not None:
                            primary.add_note(
                                f"also failed to close the database descriptor: "
                                f"{cleanup_error}"
                            )
                        else:
                            raise
                if directory is not None:
                    try:
                        directory.close()
                    except BaseException as cleanup_error:
                        if primary is not None:
                            primary.add_note(
                                f"also failed to close the database directory: "
                                f"{cleanup_error}"
                            )
                        else:
                            raise

    def _connect(self) -> _BoundConnection:
        # One kernel-owned authority serializes the complete SQLite connection
        # lifetime across runtime processes. This prevents a cooperating peer
        # from changing main/journal state between verification and commit.
        state_lease: socket.socket | None = None
        connection: _BoundConnection | None = None
        deadline = time.monotonic() + _SQLITE_LEASE_TIMEOUT_SECONDS
        try:
            state_lease, _slot = _acquire_kernel_lease(
                self.service_uid,
                "sqlite",
                [self._state_lease_key],
                _sqlite_deadline_remaining(deadline),
            )
            # Descriptor discovery is process-global. Keep database binding and
            # sqlite3 descriptor discovery in one critical section so an
            # unrelated local opener cannot make the descriptor set ambiguous.
            with _bounded_sqlite_descriptor_guard(deadline):
                connection = self._connect_locked(deadline)
            connection._guard_state_lease = state_lease
            return connection
        except BaseException as error:
            lease_was_attached = (
                connection is not None
                and connection._guard_state_lease is state_lease
            )
            if connection is not None:
                try:
                    connection.close()
                except BaseException as cleanup_error:
                    error.add_note(
                        "also failed to close the unattached SQLite connection: "
                        f"{cleanup_error}"
                    )
            if not lease_was_attached and state_lease is not None:
                try:
                    state_lease.close()
                except BaseException as cleanup_error:
                    error.add_note(
                        f"also failed to release the SQLite authority: "
                        f"{cleanup_error}"
                    )
            raise

    @staticmethod
    def _configure_durable_page_budget(
        connection: sqlite3.Connection,
        deadline: float | None = None,
    ) -> None:
        """Install a hard page ceiling that reserves live journal expansion."""

        def execute(statement: str) -> sqlite3.Cursor:
            if deadline is not None:
                _bound_sqlite_wait(connection, deadline)
            return connection.execute(statement)

        byte_limit = _MAX_DURABLE_STATE_BYTES
        fixed_reserve = (
            _SQLITE_DIRTY_CACHE_BYTES
            + _SQLITE_COMMIT_RESERVE_BYTES
            + _SQLITE_MAX_SECTOR_BYTES
        )
        if type(byte_limit) is not int or byte_limit <= fixed_reserve:
            raise StateConflictError("durable state byte limit is invalid")
        page_size = execute("PRAGMA page_size").fetchone()[0]
        page_count = execute("PRAGMA page_count").fetchone()[0]
        if type(page_size) is not int or page_size <= 0:
            raise StateConflictError("SQLite page size is invalid")
        if type(page_count) is not int or page_count < 0:
            raise StateConflictError("SQLite page count is invalid")
        # Spill is disabled below, so one transaction can allocate one main-db
        # page, one rollback record, and one in-memory dirty copy per admitted
        # page, plus the fixed aligned journal header above. This preserves a
        # useful database envelope without relying on post-allocation checks.
        per_page_allocation = (
            3 * page_size
            + _SQLITE_JOURNAL_RECORD_OVERHEAD_BYTES
        )
        max_pages = (byte_limit - fixed_reserve) // per_page_allocation
        if max_pages <= 0 or page_count > max_pages:
            raise StateConflictError(
                "runtime has reached its aggregate durable page limit"
            )
        configured = execute(
            f"PRAGMA max_page_count = {max_pages}"
        ).fetchone()[0]
        if configured != max_pages:
            raise StateConflictError(
                "SQLite could not install the durable page limit"
            )
        cache_kibibytes = _SQLITE_DIRTY_CACHE_BYTES // 1024
        execute(f"PRAGMA cache_size = -{cache_kibibytes}")
        configured_cache = execute("PRAGMA cache_size").fetchone()[0]
        if configured_cache != -cache_kibibytes:
            raise StateConflictError(
                "SQLite could not install the dirty-page cache limit"
            )
        execute("PRAGMA cache_spill = OFF")
        configured_spill = execute("PRAGMA cache_spill").fetchone()[0]
        if configured_spill != 0:
            raise StateConflictError("SQLite dirty-page spill could not be disabled")
        journal_limit = _SQLITE_SIDECAR_RESERVE_BYTES // 2
        configured_journal = execute(
            f"PRAGMA journal_size_limit = {journal_limit}"
        ).fetchone()[0]
        if configured_journal != journal_limit:
            raise StateConflictError(
                "SQLite could not install the journal size limit"
            )
        execute("PRAGMA temp_store = MEMORY")
        if execute("PRAGMA temp_store").fetchone()[0] != 2:
            raise StateConflictError(
                "SQLite could not keep temporary state out of durable storage"
            )

    @staticmethod
    def _verify_preopen_durable_budget(
        database_metadata: Sequence[tuple[int, int, int]],
        sidecar_metadata: Mapping[str, tuple[int, int, int]],
    ) -> None:
        """Reject unbounded legacy modes before SQLite can recover their files."""

        if len(database_metadata) != 1:
            raise StateConflictError("SQLite durable allocation is not bound")
        if any(
            name.endswith(("-wal", "-shm"))
            for name in sidecar_metadata
        ):
            raise StateConflictError(
                "unbounded SQLite WAL state requires offline recovery"
            )
        sizes = (database_metadata[0][0],) + tuple(
            metadata[0] for metadata in sidecar_metadata.values()
        )
        if any(type(size) is not int or size < 0 for size in sizes):
            raise StateConflictError("SQLite durable allocation is invalid")
        if sum(sizes) > _MAX_DURABLE_STATE_BYTES - _SQLITE_COMMIT_RESERVE_BYTES:
            raise StateConflictError(
                "runtime has reached its aggregate durable byte limit"
            )

    @staticmethod
    def _verify_durable_page_budget(
        connection: sqlite3.Connection,
        deadline: float | None = None,
    ) -> None:
        def execute(statement: str) -> sqlite3.Cursor:
            if deadline is not None:
                _bound_sqlite_wait(connection, deadline)
            return connection.execute(statement)

        byte_limit = _MAX_DURABLE_STATE_BYTES
        page_size = execute("PRAGMA page_size").fetchone()[0]
        page_count = execute("PRAGMA page_count").fetchone()[0]
        if (
            type(byte_limit) is not int
            or type(page_size) is not int
            or type(page_count) is not int
            or page_size <= 0
            or page_count < 0
        ):
            raise StateConflictError(
                "runtime has reached its aggregate durable page limit"
            )
        if not isinstance(connection, _BoundConnection):
            raise StateConflictError("SQLite durable allocation is not bound")
        connection._verify_binding(refresh_metadata=True)
        database_metadata = connection._guard_database_metadata
        sidecar_metadata = connection._guard_sidecar_metadata
        if (
            database_metadata is None
            or len(database_metadata) != 1
            or sidecar_metadata is None
        ):
            raise StateConflictError("SQLite durable allocation is not bound")
        RuntimeStore._verify_preopen_durable_budget(
            database_metadata,
            sidecar_metadata,
        )
        aggregate_bytes = _aggregate_durable_allocation_bytes(
            page_size=page_size,
            page_count=page_count,
            database_size=database_metadata[0][0],
            sidecar_sizes=tuple(
                metadata[0] for metadata in sidecar_metadata.values()
            ),
        )
        if aggregate_bytes > byte_limit - _SQLITE_COMMIT_RESERVE_BYTES:
            raise StateConflictError(
                "runtime has reached its aggregate durable byte limit"
            )

    def _connect_locked(self, deadline: float) -> _BoundConnection:
        directory: _BoundLockDirectory | None = None
        file_descriptor = -1
        bound_info: os.stat_result | None = None
        connection: _BoundConnection | None = None
        sqlite_proof_descriptor = -1
        primary: BaseException | None = None
        try:
            directory, file_descriptor, bound_info = self._bind_database_inode()
            identity = (bound_info.st_dev, bound_info.st_ino)
            database_metadata = [
                (
                    bound_info.st_size,
                    bound_info.st_mtime_ns,
                    bound_info.st_ctime_ns,
                )
            ]
            sidecar_identities: dict[str, tuple[int, int]] = {}
            sidecar_metadata: dict[str, tuple[int, int, int]] = {}
            _verify_runtime_paths(
                directory,
                file_descriptor,
                self.database.name,
                identity,
                database_metadata,
                sidecar_identities,
                sidecar_metadata,
                allow_new_sidecars=True,
            )
            self._verify_preopen_durable_budget(
                database_metadata,
                sidecar_metadata,
            )
            with _bounded_sqlite_descriptor_guard(deadline):
                descriptors_before = _descriptor_snapshot()
                connection = _connect_sqlite_at(
                    directory,
                    self.database.name,
                    isolation_level=None,
                    timeout=_sqlite_deadline_remaining(deadline),
                    factory=_BoundConnection,
                )
                descriptors_after = _descriptor_snapshot()
                _verify_runtime_paths(
                    directory,
                    file_descriptor,
                    self.database.name,
                    identity,
                    database_metadata,
                    sidecar_identities,
                    sidecar_metadata,
                    allow_new_sidecars=True,
                )
                sqlite_proof_descriptor = _identify_sqlite_descriptor(
                    descriptors_before,
                    descriptors_after,
                    identity,
                    sidecar_identities,
                )
            connection._guard_directory = directory
            connection._guard_file_descriptor = file_descriptor
            connection._guard_database_name = self.database.name
            connection._guard_database_identity = identity
            connection._guard_database_metadata = database_metadata
            connection._guard_sidecar_identities = sidecar_identities
            connection._guard_sidecar_metadata = sidecar_metadata
            connection._sqlite_descriptor = sqlite_proof_descriptor
            sqlite_proof_descriptor = -1
            directory = None
            file_descriptor = -1
            connection._verify_binding()
            self._verify_preopen_durable_budget(
                database_metadata,
                sidecar_metadata,
            )
            connection.row_factory = sqlite3.Row
            _bound_sqlite_wait(connection, deadline)
            connection.execute("PRAGMA foreign_keys = ON")
            self._configure_durable_page_budget(connection, deadline)
            _bound_sqlite_wait(connection, deadline)
            mode = connection.execute("PRAGMA journal_mode = PERSIST").fetchone()[0]
            if str(mode).lower() != "persist":
                raise LegacyRuntimeError("bounded SQLite journal mode is unavailable")
            _bound_sqlite_wait(connection, deadline)
            connection.execute("PRAGMA synchronous = FULL")
            self._verify_durable_page_budget(connection, deadline)
            return connection
        except BaseException as error:
            primary = error
            if connection is not None:
                try:
                    # Acquisition cleanup cannot start a fresh wait budget.
                    sqlite3.Connection.execute(
                        connection,
                        "PRAGMA busy_timeout = 0",
                    )
                    connection.close()
                except BaseException as cleanup_error:
                    error.add_note(
                        f"also failed to close the rejected SQLite connection: "
                        f"{cleanup_error}"
                    )
            if isinstance(error, sqlite3.Error):
                raise LegacyRuntimeError(
                    f"could not open durable runtime state: {error}"
                ) from error
            raise
        finally:
            cleanup_errors: list[BaseException] = []
            if sqlite_proof_descriptor >= 0:
                try:
                    os.close(sqlite_proof_descriptor)
                except BaseException as cleanup_error:
                    cleanup_error.add_note(
                        "while closing the SQLite proof descriptor"
                    )
                    cleanup_errors.append(cleanup_error)
            if file_descriptor >= 0:
                try:
                    os.close(file_descriptor)
                except BaseException as cleanup_error:
                    cleanup_error.add_note(
                        "while closing the bound database descriptor"
                    )
                    cleanup_errors.append(cleanup_error)
            if directory is not None:
                try:
                    directory.close()
                except BaseException as cleanup_error:
                    cleanup_error.add_note(
                        "while closing the bound database directory"
                    )
                    cleanup_errors.append(cleanup_error)
            if primary is not None:
                for error in cleanup_errors:
                    primary.add_note(
                        f"also failed during SQLite connection cleanup: {error}"
                    )
            elif cleanup_errors:
                cleanup_error = cleanup_errors.pop(0)
                for error in cleanup_errors:
                    cleanup_error.add_note(
                        f"also failed during SQLite connection cleanup: {error}"
                    )
                raise cleanup_error

    @staticmethod
    def _route_column_signature(
        rows: Sequence[Mapping[str, Any]],
    ) -> tuple[tuple[Any, ...], ...]:
        """Bind the exact legacy route-table shape across lock acquisition."""

        return tuple(
            (
                row["cid"],
                row["name"],
                row["type"],
                row["notnull"],
                row["dflt_value"],
                row["pk"],
            )
            for row in rows
        )

    @staticmethod
    def _route_table_requires_rebuild(
        rows: Sequence[Mapping[str, Any]],
    ) -> bool:
        if not rows:
            return False
        digest = next(
            (row for row in rows if row["name"] == "route_digest"),
            None,
        )
        return digest is None or digest["notnull"] != 1

    def _rebuild_routes_with_digest_constraint(
        self,
        connection: sqlite3.Connection,
        expected_signature: tuple[tuple[Any, ...], ...],
    ) -> None:
        """Transactionally migrate legacy routes to a physical NOT NULL schema."""

        route_info = list(connection.execute("PRAGMA table_info(routes)"))
        if self._route_column_signature(route_info) != expected_signature:
            raise StateConflictError(
                "route schema changed while acquiring the migration lock"
            )
        column_names = [row["name"] for row in route_info]
        legacy_columns = ["namespace", "task_id", "repo_slug", "route_json"]
        digest_columns = [*legacy_columns, "route_digest"]
        if column_names not in (legacy_columns, digest_columns):
            raise StateConflictError("persisted route schema is not migratable")
        digest_was_absent = column_names == legacy_columns

        schema_rows = list(
            connection.execute(
                "SELECT type, name, sql FROM sqlite_schema WHERE "
                "tbl_name = 'routes' AND type IN ('index', 'trigger') "
                "AND sql IS NOT NULL ORDER BY type, name LIMIT ?",
                (_MAX_QUERY_ROWS + 1,),
            )
        )
        if len(schema_rows) > _MAX_QUERY_ROWS:
            raise StateConflictError(
                "persisted route schema exceeds the migration object limit"
            )
        schema_objects: list[tuple[str, str, str]] = []
        seen_schema_names: set[str] = set()
        canonical_digest_triggers = {
            "route_digest_required_insert",
            "route_digest_required_update",
        }
        for row in schema_rows:
            object_type = row["type"]
            object_name = row["name"]
            object_sql = row["sql"]
            if (
                object_type not in {"index", "trigger"}
                or not isinstance(object_name, str)
                or not object_name
                or object_name in seen_schema_names
                or not isinstance(object_sql, str)
                or not object_sql.strip()
                or "\x00" in object_sql
                or len(object_sql.encode("utf-8")) > _MAX_JSON_BYTES
            ):
                raise StateConflictError(
                    "persisted route schema contains an invalid object"
                )
            seen_schema_names.add(object_name)
            if object_name not in canonical_digest_triggers:
                schema_objects.append((object_type, object_name, object_sql))

        rebuild_name = "routes_homeric_not_null_rebuild"
        if connection.execute(
            "SELECT 1 FROM sqlite_schema WHERE name = ? LIMIT 1",
            (rebuild_name,),
        ).fetchone() is not None:
            raise StateConflictError("route migration workspace already exists")
        connection.execute(
            f"CREATE TABLE {rebuild_name} ("
            "namespace TEXT NOT NULL, task_id TEXT NOT NULL, "
            "repo_slug TEXT NOT NULL, route_json TEXT NOT NULL, "
            "route_digest TEXT NOT NULL, "
            "PRIMARY KEY (namespace, task_id, repo_slug), "
            "FOREIGN KEY (namespace, task_id) "
            "REFERENCES tasks(namespace, task_id))"
        )

        copied = 0
        for route_rows in _query_pages(
            connection,
            "SELECT namespace, task_id, repo_slug, route_json"
            + ("" if digest_was_absent else ", route_digest")
            + " FROM routes ORDER BY namespace, task_id, repo_slug",
            (),
            page_size=_MAX_QUERY_ROWS,
        ):
            for route in route_rows:
                route_json = route["route_json"]
                if digest_was_absent:
                    _decode_mapping(route_json, "route")
                    route_digest = _digest(route_json)
                else:
                    route_digest = route["route_digest"]
                    if route_digest is None:
                        raise StateConflictError(
                            "persisted route is missing its integrity digest"
                        )
                    _decode_mapping(
                        route_json,
                        "route",
                        expected_digest=route_digest,
                    )
                try:
                    connection.execute(
                        f"INSERT INTO {rebuild_name} "
                        "(namespace, task_id, repo_slug, route_json, route_digest) "
                        "VALUES (?, ?, ?, ?, ?)",
                        (
                            route["namespace"],
                            route["task_id"],
                            route["repo_slug"],
                            route_json,
                            route_digest,
                        ),
                    )
                except sqlite3.IntegrityError as error:
                    raise StateConflictError(
                        "persisted route cannot satisfy the constrained schema"
                    ) from error
                copied += 1
        expected_rows = connection.execute(
            "SELECT COUNT(*) FROM routes"
        ).fetchone()[0]
        if copied != expected_rows:
            raise StateConflictError("route migration did not copy every row")

        connection.execute("DROP TABLE routes")
        connection.execute(f"ALTER TABLE {rebuild_name} RENAME TO routes")
        for _object_type, object_name, object_sql in schema_objects:
            try:
                connection.execute(object_sql)
            except sqlite3.Error as error:
                raise StateConflictError(
                    f"could not restore route schema object {object_name}"
                ) from error

        rebuilt_columns = {
            row["name"]: row
            for row in connection.execute("PRAGMA table_info(routes)")
        }
        if (
            set(rebuilt_columns) != set(digest_columns)
            or rebuilt_columns["route_digest"]["notnull"] != 1
        ):
            raise StateConflictError(
                "route migration did not install the NOT NULL constraint"
            )

    def _initialize(self) -> None:
        connection: _BoundConnection | None = None
        primary: BaseException | None = None
        foreign_keys_disabled = False
        route_schema_signature: tuple[tuple[Any, ...], ...] = ()
        rebuild_routes = False
        try:
            connection = self._connect()
            self._verify_durable_page_budget(connection)
            route_info = list(connection.execute("PRAGMA table_info(routes)"))
            route_schema_signature = self._route_column_signature(route_info)
            rebuild_routes = self._route_table_requires_rebuild(route_info)
            if rebuild_routes:
                # SQLite cannot replace a referenced parent table while FK
                # enforcement is active. The store's kernel lease excludes
                # cooperating peers; suspend enforcement before BEGIN, check
                # the rebuilt graph inside the transaction, then restore it.
                connection.execute("PRAGMA foreign_keys = OFF")
                foreign_keys_disabled = True
                if connection.execute("PRAGMA foreign_keys").fetchone()[0] != 0:
                    raise StateConflictError(
                        "could not suspend foreign keys for route migration"
                    )
            connection.execute("BEGIN EXCLUSIVE")
            schema = """
                CREATE TABLE IF NOT EXISTS runtimes (
                    namespace TEXT PRIMARY KEY,
                    repo TEXT NOT NULL,
                    registry_digest TEXT NOT NULL,
                    host_id TEXT NOT NULL,
                    service_uid INTEGER NOT NULL,
                    candidate_uid INTEGER NOT NULL,
                    message_retention_seconds REAL NOT NULL,
                    duplicate_window_seconds REAL NOT NULL,
                    created_at REAL NOT NULL
                );
                CREATE TABLE IF NOT EXISTS message_delivery_guards (
                    namespace TEXT NOT NULL,
                    source_event_id TEXT NOT NULL,
                    claim_token TEXT NOT NULL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (namespace, source_event_id),
                    UNIQUE (namespace, claim_token),
                    FOREIGN KEY (namespace) REFERENCES runtimes(namespace)
                );
                CREATE TABLE IF NOT EXISTS external_effect_receipts (
                    namespace TEXT NOT NULL,
                    source_event_id TEXT NOT NULL,
                    effect_token TEXT NOT NULL,
                    effect_kind TEXT NOT NULL,
                    authority_json TEXT NOT NULL,
                    authority_digest TEXT NOT NULL,
                    binding_json TEXT,
                    binding_digest TEXT,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (namespace, source_event_id, effect_token),
                    FOREIGN KEY (namespace, source_event_id)
                        REFERENCES message_delivery_guards(
                            namespace, source_event_id
                        ) ON DELETE RESTRICT
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
                CREATE TABLE IF NOT EXISTS plan_ingress_tombstones (
                    namespace TEXT NOT NULL,
                    source_event_id TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    binding_digest TEXT NOT NULL,
                    pruned_at REAL NOT NULL,
                    PRIMARY KEY (namespace, source_event_id),
                    UNIQUE (namespace, task_id),
                    FOREIGN KEY (namespace) REFERENCES runtimes(namespace)
                );
                CREATE TABLE IF NOT EXISTS routes (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    route_json TEXT NOT NULL,
                    route_digest TEXT NOT NULL,
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
            if "candidate_uid" not in runtime_columns:
                connection.execute(
                    "ALTER TABLE runtimes ADD COLUMN candidate_uid INTEGER"
                )
            unbound_runtime = connection.execute(
                "SELECT 1 FROM runtimes AS r WHERE r.candidate_uid IS NULL AND ("
                "EXISTS (SELECT 1 FROM tasks AS t WHERE t.namespace = r.namespace) "
                "OR EXISTS (SELECT 1 FROM outbox AS o "
                "WHERE o.namespace = r.namespace) "
                "OR EXISTS (SELECT 1 FROM candidates AS c "
                "WHERE c.namespace = r.namespace) "
                "OR EXISTS (SELECT 1 FROM stage_runs AS s "
                "WHERE s.namespace = r.namespace)) LIMIT 1"
            ).fetchone()
            if unbound_runtime is not None:
                raise HostBindingError(
                    "durable runtime state predates the candidate UID boundary"
                )
            connection.execute(
                "UPDATE runtimes SET candidate_uid = ? "
                "WHERE candidate_uid IS NULL",
                (self.candidate_uid,),
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
            if rebuild_routes:
                self._rebuild_routes_with_digest_constraint(
                    connection,
                    route_schema_signature,
                )
            elif connection.execute(
                "SELECT 1 FROM routes WHERE route_digest IS NULL LIMIT 1"
            ).fetchone() is not None:
                raise StateConflictError(
                    "persisted route is missing its integrity digest"
                )
            if connection.execute(
                "SELECT 1 FROM routes WHERE instr(repo_slug, ':') > 0 LIMIT 1"
            ).fetchone() is not None:
                raise StateConflictError(
                    "persisted route contains an ambiguous purpose delimiter"
                )
            connection.execute("DROP TRIGGER IF EXISTS route_digest_required_insert")
            connection.execute("DROP TRIGGER IF EXISTS route_digest_required_update")
            connection.execute(
                "CREATE TRIGGER route_digest_required_insert "
                "BEFORE INSERT ON routes WHEN NEW.route_digest IS NULL "
                "BEGIN SELECT RAISE(ABORT, 'route_digest is required'); END"
            )
            connection.execute(
                "CREATE TRIGGER route_digest_required_update "
                "BEFORE UPDATE OF route_digest ON routes "
                "WHEN NEW.route_digest IS NULL "
                "BEGIN SELECT RAISE(ABORT, 'route_digest is required'); END"
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
                "AND s.state = 'pending') OR "
                "EXISTS (SELECT 1 FROM message_delivery_guards AS g "
                "WHERE g.namespace = r.namespace)) LIMIT 1",
                (self.repo, self.namespace),
            ).fetchone()
            if conflicting_runtime is not None:
                raise StateConflictError(
                    "another registry binding has unfinished durable state"
                )
            row = connection.execute(
                "SELECT repo, registry_digest, host_id, service_uid, candidate_uid, "
                "message_retention_seconds, duplicate_window_seconds FROM runtimes "
                "WHERE namespace = ?",
                (self.namespace,),
            ).fetchone()
            is_new_runtime = row is None
            if is_new_runtime:
                connection.execute(
                    "INSERT INTO runtimes "
                    "(namespace, repo, registry_digest, host_id, service_uid, "
                    "candidate_uid, message_retention_seconds, "
                    "duplicate_window_seconds, created_at) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        self.repo,
                        self.registry_digest,
                        self.host_id,
                        self.service_uid,
                        self.candidate_uid,
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
                if row["candidate_uid"] != self.candidate_uid:
                    raise HostBindingError(
                        "durable runtime state is bound to a different candidate UID"
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
            maintenance_now = self._now()
            self._expire_plan_ingress_tombstones(
                connection, maintenance_now
            )
            connection.execute(
                "CREATE INDEX IF NOT EXISTS plan_ingress_tombstone_expiry "
                "ON plan_ingress_tombstones("
                "pruned_at, namespace, source_event_id)"
            )
            self._prune_terminal_history(connection)
            if rebuild_routes:
                violation = connection.execute(
                    "PRAGMA foreign_key_check"
                ).fetchone()
                if violation is not None:
                    raise StateConflictError(
                        "route migration would violate a persisted foreign key"
                    )
            self._verify_durable_page_budget(connection)
            connection.commit()
            self._verify_durable_page_budget(connection)
        except BaseException as error:
            primary = error
            if connection is not None and connection.in_transaction:
                try:
                    connection.rollback()
                except BaseException as cleanup_error:
                    error.add_note(
                        f"also failed to roll back runtime initialization: "
                        f"{cleanup_error}"
                    )
            if connection is not None:
                try:
                    self._verify_durable_page_budget(connection)
                except BaseException as cleanup_error:
                    error.add_note(
                        "also failed the post-rollback durable quota check: "
                        f"{cleanup_error}"
                    )
            raise
        finally:
            if connection is not None:
                cleanup_errors: list[BaseException] = []
                if foreign_keys_disabled:
                    try:
                        connection.execute("PRAGMA foreign_keys = ON")
                        if (
                            connection.execute("PRAGMA foreign_keys").fetchone()[0]
                            != 1
                        ):
                            raise StateConflictError(
                                "could not restore foreign-key enforcement"
                            )
                    except BaseException as cleanup_error:
                        cleanup_errors.append(cleanup_error)
                try:
                    connection.close()
                except BaseException as cleanup_error:
                    cleanup_errors.append(cleanup_error)
                if primary is not None:
                    for cleanup_error in cleanup_errors:
                        primary.add_note(
                            "also failed to clean up runtime initialization: "
                            f"{cleanup_error}"
                        )
                elif cleanup_errors:
                    cleanup_error = cleanup_errors.pop(0)
                    for additional_error in cleanup_errors:
                        cleanup_error.add_note(
                            "also failed during runtime initialization cleanup: "
                            f"{additional_error}"
                        )
                    raise cleanup_error

    def _expire_plan_ingress_tombstones(
        self,
        connection: sqlite3.Connection,
        maintenance_now: float,
    ) -> None:
        """Reclaim ingress keys only after each broker retention contract.

        ``maintenance_now`` is sampled after acquiring the SQLite write lock.
        A strict boundary and the explicit clock-regression check preserve an
        exact redelivery for the complete broker-retention interval.
        """

        if not math.isfinite(maintenance_now):
            raise ValueError("maintenance clock must be finite")
        for row in connection.execute(
            "SELECT p.pruned_at, r.message_retention_seconds "
            "FROM plan_ingress_tombstones AS p JOIN runtimes AS r "
            "ON r.namespace = p.namespace"
        ):
            pruned_at = row["pruned_at"]
            retention = row["message_retention_seconds"]
            if (
                isinstance(pruned_at, bool)
                or not isinstance(pruned_at, (int, float))
                or not math.isfinite(float(pruned_at))
                or isinstance(retention, bool)
                or not isinstance(retention, (int, float))
                or not math.isfinite(float(retention))
                or float(retention) <= 0
            ):
                raise StateConflictError(
                    "persisted plan tombstone retention metadata is invalid"
                )
        while True:
            cursor = connection.execute(
                "DELETE FROM plan_ingress_tombstones WHERE rowid IN ("
                "SELECT p.rowid FROM plan_ingress_tombstones AS p "
                "JOIN runtimes AS r ON r.namespace = p.namespace "
                "WHERE ? > p.pruned_at "
                "AND (? - p.pruned_at) > r.message_retention_seconds "
                "ORDER BY p.pruned_at, p.namespace, p.source_event_id LIMIT ?)",
                (maintenance_now, maintenance_now, _MAX_QUERY_ROWS),
            )
            if cursor.rowcount < _MAX_QUERY_ROWS:
                return

    def _prune_terminal_history(self, connection: sqlite3.Connection) -> None:
        """Bound fully delivered terminal history without deleting recovery state."""

        while True:
            rows = list(
                connection.execute(
                    "SELECT t.task_id FROM tasks AS t WHERE "
                    + _DELIVERED_TERMINAL_PREDICATE
                    + "ORDER BY t.completed_at DESC, t.task_id DESC "
                    "LIMIT ? OFFSET ?",
                    (
                        self.namespace,
                        _MAX_QUERY_ROWS,
                        _MAX_TERMINAL_HISTORY,
                    ),
                )
            )
            if not rows:
                return
            for row in rows:
                self._delete_terminal_graph(connection, row["task_id"])

    def _delete_terminal_graph(
        self,
        connection: sqlite3.Connection,
        task_id: str,
    ) -> None:
        """Delete one graph selected by the fully-delivered eligibility query."""

        self._validate_prunable_terminal_graph(connection, task_id)
        task = connection.execute(
            "SELECT task_id, team_id, issue_number, task_digest, "
            "plan_source_event_id, plan_subject, plan_payload_json "
            "FROM tasks WHERE namespace = ? AND task_id = ?",
            (self.namespace, task_id),
        ).fetchone()
        if task is None:
            raise StateConflictError("prunable terminal task disappeared")
        if task["plan_source_event_id"] is not None:
            routes = self._load_persisted_routes(connection, task_id)
            binding_digest = _plan_transition_binding_digest(
                task["task_id"],
                task["team_id"],
                task["issue_number"],
                task["task_digest"],
                task["plan_source_event_id"],
                task["plan_subject"],
                task["plan_payload_json"],
                routes,
            )
            tombstones = list(
                connection.execute(
                    "SELECT source_event_id, task_id, binding_digest FROM "
                    "plan_ingress_tombstones WHERE namespace = ? AND "
                    "(source_event_id = ? OR task_id = ?) LIMIT 2",
                    (
                        self.namespace,
                        task["plan_source_event_id"],
                        task_id,
                    ),
                )
            )
            if tombstones:
                if len(tombstones) != 1 or (
                    tombstones[0]["source_event_id"]
                    != task["plan_source_event_id"]
                    or tombstones[0]["task_id"] != task_id
                    or tombstones[0]["binding_digest"] != binding_digest
                ):
                    raise StateConflictError(
                        "pruned plan ingress conflicts with its tombstone"
                    )
            else:
                connection.execute(
                    "INSERT INTO plan_ingress_tombstones "
                    "(namespace, source_event_id, task_id, binding_digest, "
                    "pruned_at) VALUES (?, ?, ?, ?, ?)",
                    (
                        self.namespace,
                        task["plan_source_event_id"],
                        task_id,
                        binding_digest,
                        self._now(),
                    ),
                )
        for table in (
            "stage_runs",
            "candidates",
            "receipts",
            "routes",
            "outbox",
        ):
            connection.execute(
                f"DELETE FROM {table} WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            )
        connection.execute(
            "DELETE FROM tasks WHERE namespace = ? AND task_id = ?",
            (self.namespace, task_id),
        )

    def _validate_prunable_terminal_graph(
        self,
        connection: sqlite3.Connection,
        task_id: str,
    ) -> None:
        """Validate every durable child before irreversible graph deletion."""

        task = connection.execute(
            "SELECT task_id, plan_source_event_id, plan_subject, "
            "plan_payload_json, plan_payload_digest, completion_json, "
            "completion_outbox_json, terminal_status, completed_at FROM tasks "
            "WHERE namespace = ? AND task_id = ?",
            (self.namespace, task_id),
        ).fetchone()
        if task is None:
            raise StateConflictError("prunable terminal task disappeared")
        self._validate_plan_source_state(task)
        routes = self._load_persisted_routes(connection, task_id)
        self._validate_task_terminal_graph(connection, task)

        for outbox_rows in _query_pages(
            connection,
            "SELECT payload_json, payload_digest, claim_owner, "
            "claim_expires_at, claim_token, claim_generation, "
            "requires_consumer_checkpoint, consumer_checkpointed_at, "
            "sent_at, rearm_at FROM outbox WHERE namespace = ? "
            "AND task_id = ? ORDER BY outbox_id",
            (self.namespace, task_id),
            page_size=_MAX_QUERY_ROWS,
        ):
            for row in outbox_rows:
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

        candidate_rows = list(
            connection.execute(
                "SELECT repo_slug, candidate_json, candidate_digest, "
                "claim_owner, claim_expires_at, claim_token, claim_generation, "
                "source_message_id, source_subject, source_payload_json, "
                "source_payload_digest FROM candidates WHERE namespace = ? "
                "AND task_id = ? ORDER BY repo_slug LIMIT ?",
                (self.namespace, task_id, _MAX_TASK_ROUTES + 1),
            )
        )
        if len(candidate_rows) > _MAX_TASK_ROUTES:
            raise StateConflictError("terminal graph exceeds the candidate limit")
        for row in candidate_rows:
            if row["repo_slug"] not in routes:
                raise StateConflictError("terminal candidate has no planned route")
            _decode_mapping(
                row["candidate_json"],
                "candidate",
                expected_digest=row["candidate_digest"],
            )
            self._validate_candidate_source_state(row)
            if row["source_message_id"] is not None:
                self._validate_candidate_source_event(
                    connection,
                    task_id,
                    row["repo_slug"],
                    row["source_message_id"],
                    row["source_subject"],
                    row["source_payload_json"],
                )
            _validate_fenced_claim_state(
                row["claim_owner"],
                row["claim_expires_at"],
                row["claim_token"],
                row["claim_generation"],
                "candidate",
            )

        receipt_rows = list(
            connection.execute(
                "SELECT repo_slug, receipt_json, receipt_digest FROM receipts "
                "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug LIMIT ?",
                (self.namespace, task_id, _MAX_TASK_ROUTES + 1),
            )
        )
        if len(receipt_rows) > _MAX_TASK_ROUTES:
            raise StateConflictError("terminal graph exceeds the receipt limit")
        for row in receipt_rows:
            if row["repo_slug"] not in routes:
                raise StateConflictError("terminal receipt has no planned route")
            _decode_mapping(
                row["receipt_json"],
                "receipt",
                expected_digest=row["receipt_digest"],
            )

        for stage_rows in _query_pages(
            connection,
            "SELECT * FROM stage_runs WHERE namespace = ? AND task_id = ? "
            "ORDER BY repo_slug, stage, iteration",
            (self.namespace, task_id),
            page_size=_MAX_QUERY_ROWS,
        ):
            for row in stage_rows:
                self._validate_stage_scope(
                    connection,
                    task_id,
                    row["repo_slug"],
                    row["stage"],
                    row["iteration"],
                )
                self._validate_stage_row(row)
                self._validate_stage_source_event(connection, row)
                self._validate_stage_outbox(connection, row)

    def _prune_for_outbox_admission(
        self,
        connection: sqlite3.Connection,
    ) -> None:
        """Free outbox capacity only by deleting complete delivered graphs."""

        while connection.execute(
            "SELECT COUNT(*) FROM outbox WHERE namespace = ?",
            (self.namespace,),
        ).fetchone()[0] >= _MAX_STORED_OUTBOX:
            row = connection.execute(
                "SELECT t.task_id FROM tasks AS t WHERE "
                + _DELIVERED_TERMINAL_PREDICATE
                + "ORDER BY t.completed_at, t.task_id LIMIT 1",
                (self.namespace,),
            ).fetchone()
            if row is None:
                return
            self._delete_terminal_graph(connection, row["task_id"])

    def _admit_new_task(self, connection: sqlite3.Connection) -> None:
        """Keep unfinished task admission inside one explicit durable bound."""

        self._prune_terminal_history(connection)
        active = connection.execute(
            "SELECT COUNT(*) FROM tasks WHERE namespace = ? "
            "AND completion_json IS NULL",
            (self.namespace,),
        ).fetchone()[0]
        if active >= _MAX_ACTIVE_TASKS:
            raise StateConflictError(
                "runtime has reached its unfinished task admission limit"
            )

    def _admit_outbox_event(self, connection: sqlite3.Connection) -> None:
        """Keep durable publication state within one bounded row budget."""

        self._prune_terminal_history(connection)
        self._prune_for_outbox_admission(connection)
        count = connection.execute(
            "SELECT COUNT(*) FROM outbox WHERE namespace = ?",
            (self.namespace,),
        ).fetchone()[0]
        if count >= _MAX_STORED_OUTBOX:
            raise StateConflictError(
                "runtime has reached its durable outbox admission limit"
            )

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
        connection: _BoundConnection | None = None
        primary: BaseException | None = None
        try:
            connection = self._connect()
            self._verify_durable_page_budget(connection)
            connection.execute("BEGIN IMMEDIATE")
            maintenance_now = self._now()
            self._expire_plan_ingress_tombstones(
                connection, maintenance_now
            )
            self._prune_terminal_history(connection)
            yield connection
            self._prune_terminal_history(connection)
            self._verify_durable_page_budget(connection)
            connection.commit()
            self._verify_durable_page_budget(connection)
        except BaseException as error:
            failure: BaseException = error
            if _is_sqlite_full_error(error):
                failure = StateConflictError(
                    "runtime has reached its aggregate durable page limit"
                )
            primary = failure
            if connection is not None and connection.in_transaction:
                try:
                    connection.rollback()
                except BaseException as cleanup_error:
                    failure.add_note(
                        f"also failed to roll back the runtime transaction: "
                        f"{cleanup_error}"
                    )
            if connection is not None:
                try:
                    self._verify_durable_page_budget(connection)
                except BaseException as cleanup_error:
                    failure.add_note(
                        "also failed the post-rollback durable quota check: "
                        f"{cleanup_error}"
                    )
            if failure is not error:
                raise failure from error
            raise
        finally:
            if connection is not None:
                try:
                    connection.close()
                except BaseException as cleanup_error:
                    if primary is not None:
                        primary.add_note(
                            "also failed to close the runtime transaction: "
                            f"{cleanup_error}"
                        )
                    else:
                        raise

    def claim_message_delivery(self, source_event_id: str) -> str | None:
        """Durably exclude another worker from one broker delivery identity.

        A row has deliberately no time-based lease. If its owner dies before a
        broker disposition, later workers retain ownership heartbeats but do
        not enter the handler. Human or startup reconciliation must first
        prove the old external effects extinct; guessing from AckWait time
        would reintroduce overlapping effects.
        """

        source_event_id = _required_text(source_event_id, "source_event_id")
        if not _is_sha256(source_event_id):
            raise RejectMessage("source_event_id must be a stable event digest")
        claim_token = secrets.token_hex(32)
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT claim_token, created_at FROM message_delivery_guards "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if row is not None:
                if (
                    not _is_sha256(row["claim_token"])
                    or isinstance(row["created_at"], bool)
                    or not isinstance(row["created_at"], (int, float))
                    or not math.isfinite(float(row["created_at"]))
                ):
                    raise StateConflictError(
                        "persisted message delivery guard is malformed"
                    )
                return None
            connection.execute(
                "INSERT INTO message_delivery_guards "
                "(namespace, source_event_id, claim_token, created_at) "
                "VALUES (?, ?, ?, ?)",
                (
                    self.namespace,
                    source_event_id,
                    claim_token,
                    self._now(),
                ),
            )
        return claim_token

    def release_message_delivery(
        self,
        source_event_id: str,
        claim_token: str,
    ) -> None:
        """Retire exactly the claim held through a successful disposition."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        claim_token = _required_text(claim_token, "claim_token")
        if not _is_sha256(source_event_id) or not _is_sha256(claim_token):
            raise WorkerContainmentFatalError(
                "message delivery guard receipt is malformed"
            )
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT claim_token FROM message_delivery_guards "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if row is None or row["claim_token"] != claim_token:
                raise WorkerContainmentFatalError(
                    "message delivery guard changed before retirement"
                )
            deleted = connection.execute(
                "DELETE FROM message_delivery_guards WHERE namespace = ? "
                "AND source_event_id = ? AND claim_token = ?",
                (self.namespace, source_event_id, claim_token),
            ).rowcount
            if deleted != 1:
                raise WorkerContainmentFatalError(
                    "message delivery guard could not be retired exactly"
                )

    def acquire_message_delivery_lease(
        self,
        source_event_id: str,
        *,
        timeout: float,
    ) -> socket.socket:
        """Acquire the kernel lifetime fence for one stable broker event."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        if not _is_sha256(source_event_id):
            raise RejectMessage("source_event_id must be a stable event digest")
        timeout = _validated_lease_seconds(timeout)
        lease, _slot = _acquire_kernel_lease(
            self.service_uid,
            "message-delivery",
            [_digest(f"{self.namespace}\0{source_event_id}")],
            timeout,
        )
        return lease

    def inspect_message_delivery(self, source_event_id: str) -> str | None:
        source_event_id = _required_text(source_event_id, "source_event_id")
        if not _is_sha256(source_event_id):
            raise RejectMessage("source_event_id must be a stable event digest")
        with self._transaction() as connection:
            row = connection.execute(
                "SELECT claim_token FROM message_delivery_guards "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if row is None:
                return None
            if not _is_sha256(row["claim_token"]):
                raise StateConflictError(
                    "persisted message delivery guard is malformed"
                )
            return row["claim_token"]

    def take_over_message_delivery(
        self,
        source_event_id: str,
        prior_claim_token: str,
    ) -> str:
        """CAS a dead owner's guard after all durable effects are extinct."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        prior_claim_token = _required_text(
            prior_claim_token, "prior_claim_token"
        )
        if not _is_sha256(source_event_id) or not _is_sha256(prior_claim_token):
            raise WorkerContainmentFatalError(
                "message delivery takeover receipt is malformed"
            )
        replacement = secrets.token_hex(32)
        with self._transaction() as connection:
            if connection.execute(
                "SELECT 1 FROM external_effect_receipts WHERE namespace = ? "
                "AND source_event_id = ? LIMIT 1",
                (self.namespace, source_event_id),
            ).fetchone() is not None:
                raise WorkerContainmentFatalError(
                    "message delivery still has durable external effects"
                )
            changed = connection.execute(
                "UPDATE message_delivery_guards SET claim_token = ?, "
                "created_at = ? WHERE namespace = ? AND source_event_id = ? "
                "AND claim_token = ?",
                (
                    replacement,
                    self._now(),
                    self.namespace,
                    source_event_id,
                    prior_claim_token,
                ),
            ).rowcount
            if changed != 1:
                raise WorkerContainmentFatalError(
                    "message delivery guard changed during takeover"
                )
        return replacement

    def arm_external_effect(
        self,
        source_event_id: str,
        claim_token: str,
        effect_kind: str,
        authority: Mapping[str, Any],
    ) -> str:
        """Persist pre-create cleanup authority before local admission."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        claim_token = _required_text(claim_token, "claim_token")
        effect_kind = _required_text(effect_kind, "effect_kind")
        if not _is_sha256(source_event_id) or not _is_sha256(claim_token):
            raise WorkerContainmentFatalError(
                "external effect delivery receipt is malformed"
            )
        if not isinstance(authority, Mapping):
            raise ValueError("external effect authority must be an object")
        authority_value = dict(authority)
        try:
            authority_value["engine_endpoint_identity"] = (
                _validated_engine_endpoint_identity(
                    authority_value.get("engine_endpoint_identity")
                )
            )
        except WorkerContainmentUnavailableError as error:
            raise WorkerContainmentFatalError(
                "external effect engine endpoint identity is unproven"
            ) from error
        authority_json = _canonical_json(
            authority_value, "external effect authority"
        )
        authority_digest = _digest(authority_json)
        effect_token = secrets.token_hex(32)
        with self._transaction() as connection:
            guard = connection.execute(
                "SELECT claim_token FROM message_delivery_guards "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if guard is None or guard["claim_token"] != claim_token:
                raise WorkerContainmentFatalError(
                    "message delivery guard changed before effect admission"
                )
            count = connection.execute(
                "SELECT COUNT(*) FROM external_effect_receipts "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()[0]
            if count >= _MAX_EXTERNAL_EFFECTS_PER_DELIVERY:
                raise WorkerContainmentFatalError(
                    "message delivery external-effect bound is exhausted"
                )
            connection.execute(
                "INSERT INTO external_effect_receipts "
                "(namespace, source_event_id, effect_token, effect_kind, "
                "authority_json, authority_digest, binding_json, "
                "binding_digest, created_at) VALUES (?, ?, ?, ?, ?, ?, NULL, "
                "NULL, ?)",
                (
                    self.namespace,
                    source_event_id,
                    effect_token,
                    effect_kind,
                    authority_json,
                    authority_digest,
                    self._now(),
                ),
            )
        return effect_token

    def bind_external_effect(
        self,
        source_event_id: str,
        claim_token: str,
        effect_token: str,
        binding: Mapping[str, Any],
    ) -> None:
        """Persist an immutable exact receipt before candidate start."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        claim_token = _required_text(claim_token, "claim_token")
        effect_token = _required_text(effect_token, "effect_token")
        if not all(
            _is_sha256(value)
            for value in (source_event_id, claim_token, effect_token)
        ):
            raise WorkerContainmentFatalError(
                "external effect binding receipt is malformed"
            )
        if not isinstance(binding, Mapping):
            raise ValueError("external effect binding must be an object")
        binding_json = _canonical_json(
            dict(binding), "external effect binding"
        )
        binding_digest = _digest(binding_json)
        with self._transaction() as connection:
            guard = connection.execute(
                "SELECT claim_token FROM message_delivery_guards "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if guard is None or guard["claim_token"] != claim_token:
                raise WorkerContainmentFatalError(
                    "message delivery guard changed before exact effect binding"
                )
            changed = connection.execute(
                "UPDATE external_effect_receipts SET binding_json = ?, "
                "binding_digest = ? WHERE namespace = ? AND "
                "source_event_id = ? AND effect_token = ? AND "
                "binding_json IS NULL AND binding_digest IS NULL",
                (
                    binding_json,
                    binding_digest,
                    self.namespace,
                    source_event_id,
                    effect_token,
                ),
            ).rowcount
            if changed != 1:
                raise WorkerContainmentFatalError(
                    "durable external effect cannot be rebound"
                )

    def active_external_effects(
        self,
        source_event_id: str,
    ) -> tuple[ExternalEffectReceipt, ...]:
        """Load a bounded exact inventory for dead-owner reconciliation."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        if not _is_sha256(source_event_id):
            raise WorkerContainmentFatalError(
                "external effect inventory receipt is malformed"
            )
        with self._transaction() as connection:
            rows = list(
                connection.execute(
                    "SELECT effect_token, effect_kind, authority_json, "
                    "authority_digest, binding_json, binding_digest FROM "
                    "external_effect_receipts WHERE namespace = ? AND "
                    "source_event_id = ? ORDER BY effect_token LIMIT ?",
                    (
                        self.namespace,
                        source_event_id,
                        _MAX_EXTERNAL_EFFECTS_PER_DELIVERY + 1,
                    ),
                )
            )
        if len(rows) > _MAX_EXTERNAL_EFFECTS_PER_DELIVERY:
            raise StateConflictError(
                "persisted external-effect inventory exceeds its bound"
            )
        receipts: list[ExternalEffectReceipt] = []
        for row in rows:
            authority = _decode_mapping(
                row["authority_json"],
                "external effect authority",
                expected_digest=row["authority_digest"],
            )
            _validated_engine_endpoint_identity(
                authority.get("engine_endpoint_identity"),
                persisted=True,
            )
            binding = None
            if (row["binding_json"] is None) != (row["binding_digest"] is None):
                raise StateConflictError(
                    "persisted external effect binding is incomplete"
                )
            if row["binding_json"] is not None:
                binding = _decode_mapping(
                    row["binding_json"],
                    "external effect binding",
                    expected_digest=row["binding_digest"],
                )
            if not _is_sha256(row["effect_token"]):
                raise StateConflictError(
                    "persisted external effect token is malformed"
                )
            try:
                effect_kind = _required_text(
                    row["effect_kind"], "persisted effect_kind"
                )
            except ValueError as error:
                raise StateConflictError(
                    "persisted external effect kind is malformed"
                ) from error
            receipts.append(
                ExternalEffectReceipt(
                    effect_token=row["effect_token"],
                    source_event_id=source_event_id,
                    effect_kind=effect_kind,
                    authority=authority,
                    binding=binding,
                )
            )
        return tuple(receipts)

    def retire_external_effect(
        self,
        source_event_id: str,
        claim_token: str,
        effect_token: str,
    ) -> None:
        """Delete one receipt only after trusted exact extinction proof."""

        source_event_id = _required_text(source_event_id, "source_event_id")
        claim_token = _required_text(claim_token, "claim_token")
        effect_token = _required_text(effect_token, "effect_token")
        if not all(
            _is_sha256(value)
            for value in (source_event_id, claim_token, effect_token)
        ):
            raise WorkerContainmentFatalError(
                "external effect retirement receipt is malformed"
            )
        with self._transaction() as connection:
            guard = connection.execute(
                "SELECT claim_token FROM message_delivery_guards "
                "WHERE namespace = ? AND source_event_id = ?",
                (self.namespace, source_event_id),
            ).fetchone()
            if guard is None or guard["claim_token"] != claim_token:
                raise WorkerContainmentFatalError(
                    "message delivery guard changed before effect retirement"
                )
            changed = connection.execute(
                "DELETE FROM external_effect_receipts WHERE namespace = ? "
                "AND source_event_id = ? AND effect_token = ?",
                (self.namespace, source_event_id, effect_token),
            ).rowcount
            if changed != 1:
                raise WorkerContainmentFatalError(
                    "durable external effect changed before retirement"
                )

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
        if len(route_map) > _MAX_TASK_ROUTES:
            raise ValueError(
                f"route_map cannot contain more than {_MAX_TASK_ROUTES} routes"
            )
        routes: dict[str, str] = {}
        for slug, route in route_map.items():
            slug = _validated_repo_slug(slug)
            if not isinstance(route, Mapping):
                raise ValueError("each route must be a mapping")
            routes[slug] = _canonical_json(dict(route), f"route {slug}")

        now = self._now()
        with self._transaction() as connection:
            tombstone = connection.execute(
                "SELECT 1 FROM plan_ingress_tombstones "
                "WHERE namespace = ? AND task_id = ? LIMIT 1",
                (self.namespace, task_id),
            ).fetchone()
            if tombstone is not None:
                raise StateConflictError(
                    "task id belongs to a pruned plan ingress"
                )
            row = connection.execute(
                "SELECT team_id, issue_number, task_digest FROM tasks "
                "WHERE namespace = ? AND task_id = ?",
                (self.namespace, task_id),
            ).fetchone()
            is_new_task = row is None
            if is_new_task:
                self._admit_new_task(connection)
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

            persisted = self._load_persisted_routes(connection, task_id)
            if persisted and persisted != routes:
                raise StateConflictError("route set conflicts with persisted state")
            if not persisted and not is_new_task:
                raise StateConflictError("persisted task is missing its route set")
            if is_new_task:
                connection.executemany(
                    "INSERT INTO routes "
                    "(namespace, task_id, repo_slug, route_json, route_digest) "
                    "VALUES (?, ?, ?, ?, ?)",
                    (
                        (
                            self.namespace,
                            task_id,
                            slug,
                            route_json,
                            _digest(route_json),
                        )
                        for slug, route_json in sorted(routes.items())
                    ),
                )

    def _load_persisted_routes(
        self,
        connection: sqlite3.Connection,
        task_id: str,
    ) -> dict[str, str]:
        rows = list(
            connection.execute(
                "SELECT repo_slug, route_json, route_digest FROM routes "
                "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug LIMIT ?",
                (self.namespace, task_id, _MAX_TASK_ROUTES + 1),
            )
        )
        if len(rows) > _MAX_TASK_ROUTES:
            raise StateConflictError("persisted task exceeds the route limit")
        persisted: dict[str, str] = {}
        for row in rows:
            slug = _validated_repo_slug(row["repo_slug"], persisted=True)
            if row["route_digest"] is None:
                raise StateConflictError(
                    "persisted route is missing its integrity digest"
                )
            _decode_mapping(
                row["route_json"],
                "route",
                expected_digest=row["route_digest"],
            )
            persisted[slug] = row["route_json"]
        return persisted

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
        if len(route_map) > _MAX_TASK_ROUTES:
            raise ValueError(
                f"route_map cannot contain more than {_MAX_TASK_ROUTES} routes"
            )
        routes: dict[str, str] = {}
        route_events: dict[str, Mapping[str, Any]] = {}
        for slug, route in route_map.items():
            slug = _validated_repo_slug(slug)
            if not isinstance(route, Mapping):
                raise ValueError("each route must be a mapping")
            dispatch_event = route.get("dispatch_event")
            if not isinstance(dispatch_event, Mapping):
                raise ValueError("each plan route requires a dispatch_event")
            self._normalize_outbox_message(dispatch_event, f"route:{slug}")
            routes[slug] = _canonical_json(dict(route), f"route {slug}")
            route_events[slug] = dispatch_event
        payload_json = _canonical_json(payload, "plan source payload")
        binding_digest = _plan_transition_binding_digest(
            task_id,
            team_id,
            issue_number,
            task_digest,
            source_event_id,
            subject,
            payload_json,
            routes,
        )
        with self._transaction() as connection:
            now = self._now()
            tombstones = list(
                connection.execute(
                    "SELECT source_event_id, task_id, binding_digest FROM "
                    "plan_ingress_tombstones WHERE namespace = ? AND "
                    "(source_event_id = ? OR task_id = ?) LIMIT 2",
                    (self.namespace, source_event_id, task_id),
                )
            )
            if tombstones:
                live_binding = connection.execute(
                    "SELECT 1 FROM tasks WHERE namespace = ? AND "
                    "(task_id = ? OR plan_source_event_id = ?) LIMIT 1",
                    (self.namespace, task_id, source_event_id),
                ).fetchone()
                if live_binding is not None:
                    raise StateConflictError(
                        "pruned plan ingress conflicts with live task state"
                    )
                tombstone = tombstones[0]
                if (
                    len(tombstones) != 1
                    or not _is_sha256(tombstone["binding_digest"])
                    or tombstone["source_event_id"] != source_event_id
                    or tombstone["task_id"] != task_id
                    or tombstone["binding_digest"] != binding_digest
                ):
                    raise StateConflictError(
                        "plan redelivery conflicts with pruned ingress state"
                    )
                return
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
                self._admit_new_task(connection)
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
            persisted_routes = self._load_persisted_routes(connection, task_id)
            if persisted_routes and persisted_routes != routes:
                raise StateConflictError("route set conflicts with persisted state")
            if not persisted_routes and not is_new_task:
                raise StateConflictError("persisted task is missing its route set")
            if is_new_task:
                connection.executemany(
                    "INSERT INTO routes (namespace, task_id, repo_slug, route_json, "
                    "route_digest) VALUES (?, ?, ?, ?, ?)",
                    (
                        (
                            self.namespace,
                            task_id,
                            slug,
                            route_json,
                            _digest(route_json),
                        )
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        repo_slug = _validated_repo_slug(repo_slug)
        source_message_id = _required_text(
            source_message_id, "source_message_id"
        )
        subject = _required_text(subject, "subject")
        source_payload_json = _canonical_json(payload, "candidate source payload")
        connection: _BoundConnection | None = None
        try:
            connection = self._connect()
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
            if connection is not None:
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        self._admit_outbox_event(connection)
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
        if len(events) > _MAX_OUTBOX_EVENTS:
            raise StateConflictError(
                "persisted terminal task exceeds the outbox event limit"
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
                "purpose LIKE 'terminal:%') ORDER BY purpose LIMIT ?",
                (self.namespace, task_id, _MAX_OUTBOX_EVENTS + 1),
            )
        )
        if len(actual) > _MAX_OUTBOX_EVENTS:
            raise StateConflictError(
                "persisted terminal task exceeds the outbox event limit"
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
        if len(outbox) > _MAX_OUTBOX_EVENTS:
            raise ValueError(
                f"outbox cannot contain more than {_MAX_OUTBOX_EVENTS} events"
            )
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
        expected_routes = self._load_persisted_routes(connection, task_id)
        expected = sorted(expected_routes)
        receipt_rows = list(
            connection.execute(
                "SELECT repo_slug, receipt_json, receipt_digest FROM receipts "
                "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug LIMIT ?",
                (self.namespace, task_id, _MAX_TASK_ROUTES + 1),
            )
        )
        if len(receipt_rows) > _MAX_TASK_ROUTES:
            raise StateConflictError("persisted task exceeds the receipt limit")
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
                "stage",
                "source_event_id",
                "subject",
            ):
                _required_text(row[field], f"persisted stage {field}")
            _validated_repo_slug(row["repo_slug"], persisted=True)
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
        try:
            _validated_iteration(row["iteration"])
        except ValueError:
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
        repo_slug = _validated_repo_slug(repo_slug)
        stage = _required_text(stage, "stage")
        iteration = validate_message_iteration(iteration)
        source_event_id = _required_text(source_event_id, "source_event_id")
        subject = _required_text(subject, "subject")
        if source_message_id is not None:
            source_message_id = _required_text(
                source_message_id, "source_message_id"
            )
        input_json = _canonical_json(payload, "stage input")
        connection: _BoundConnection | None = None
        try:
            connection = self._connect()
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
            if connection is not None:
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
        repo_slug = _validated_repo_slug(repo_slug)
        stage = _required_text(stage, "stage")
        iteration = validate_message_iteration(iteration)
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        repo_slug = _validated_repo_slug(repo_slug)
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

        limit = _validated_limit(limit)
        now = self._now()
        connection: _BoundConnection | None = None
        try:
            connection = self._connect()
            rows = list(
                connection.execute(
                    "SELECT * FROM stage_runs WHERE namespace = ? AND state = 'pending' "
                    "AND ((claim_owner IS NULL AND claim_expires_at IS NULL AND "
                    "claim_token IS NULL) OR claim_expires_at <= ?) "
                    "ORDER BY created_at, task_id, repo_slug, stage, iteration LIMIT ?",
                    (self.namespace, now, limit),
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
                for row, payload, intent in decoded
            ]
        finally:
            if connection is not None:
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        if len(outbox) > _MAX_OUTBOX_EVENTS:
            raise ValueError(
                f"outbox cannot contain more than {_MAX_OUTBOX_EVENTS} events"
            )
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
        repo_slug = _validated_repo_slug(repo_slug)
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
        connection: _BoundConnection | None = None
        try:
            connection = self._connect()
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
            persisted_routes = self._load_persisted_routes(connection, task_id)
            routes = {
                slug: _decode_mapping(route_json, "route")
                for slug, route_json in persisted_routes.items()
            }
            candidate_rows = list(
                connection.execute(
                    "SELECT repo_slug, candidate_json, candidate_digest, "
                    "claim_owner, claim_expires_at, claim_token, "
                    "claim_generation, source_message_id, source_subject, "
                    "source_payload_json, source_payload_digest FROM candidates "
                    "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug LIMIT ?",
                    (self.namespace, task_id, _MAX_TASK_ROUTES + 1),
                )
            )
            if len(candidate_rows) > _MAX_TASK_ROUTES:
                raise StateConflictError("persisted task exceeds the candidate limit")
            if any(row["repo_slug"] not in routes for row in candidate_rows):
                raise StateConflictError("persisted candidate has no planned route")
            candidates = {
                row["repo_slug"]: _decode_mapping(
                    row["candidate_json"],
                    "candidate",
                    expected_digest=row["candidate_digest"],
                )
                for row in candidate_rows
            }
            receipt_rows = list(
                connection.execute(
                    "SELECT repo_slug, receipt_json, receipt_digest FROM receipts "
                    "WHERE namespace = ? AND task_id = ? ORDER BY repo_slug LIMIT ?",
                    (self.namespace, task_id, _MAX_TASK_ROUTES + 1),
                )
            )
            if len(receipt_rows) > _MAX_TASK_ROUTES:
                raise StateConflictError("persisted task exceeds the receipt limit")
            if any(row["repo_slug"] not in routes for row in receipt_rows):
                raise StateConflictError("persisted receipt has no planned route")
            receipts = {
                row["repo_slug"]: _decode_mapping(
                    row["receipt_json"],
                    "receipt",
                    expected_digest=row["receipt_digest"],
                )
                for row in receipt_rows
            }
            for claim_row in candidate_rows:
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
                for row in candidate_rows
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
            if connection is not None:
                connection.close()

    def pending_outbox(self, *, limit: int = 100) -> list[dict[str, Any]]:
        """Return events due for first publish or checkpoint-safe rearming."""

        limit = _validated_limit(limit)
        now = self._now()
        connection: _BoundConnection | None = None
        try:
            connection = self._connect()
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
            if connection is not None:
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
        limit = _validated_limit(limit)
        with self._transaction() as connection:
            now = self._now()
            expires = _lease_deadline(now, lease_seconds)
            for outbox_states in _query_pages(
                connection,
                "SELECT claim_owner, claim_expires_at, claim_token, "
                "claim_generation, requires_consumer_checkpoint, "
                "consumer_checkpointed_at, sent_at, rearm_at FROM outbox "
                "WHERE namespace = ? ORDER BY outbox_id",
                (self.namespace,),
                page_size=_MAX_QUERY_ROWS,
            ):
                for state in outbox_states:
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
        connection: _BoundConnection | None = None
        try:
            connection = self._connect()
            unfinished_tasks = []
            for task_rows in _query_pages(
                connection,
                "SELECT task_id, plan_source_event_id, plan_subject, "
                "plan_payload_json, plan_payload_digest, completion_json, "
                "completion_outbox_json, terminal_status, completed_at FROM tasks "
                "WHERE namespace = ? ORDER BY task_id",
                (self.namespace,),
                page_size=_MAX_RECONCILE_ROWS,
            ):
                for row in task_rows:
                    self._load_persisted_routes(connection, row["task_id"])
                    self._validate_plan_source_state(row)
                    self._validate_task_terminal_graph(connection, row)
                    if row["completion_json"] is None:
                        unfinished_tasks.append(row["task_id"])
            unfinished_task_ids = set(unfinished_tasks)

            claimable = []
            for candidate_rows in _query_pages(
                connection,
                "SELECT task_id, repo_slug, candidate_json, candidate_digest, "
                "claim_owner, claim_expires_at, claim_token, "
                "claim_generation, completed_at, source_message_id, "
                "source_subject, source_payload_json, source_payload_digest "
                "FROM candidates WHERE namespace = ? "
                "ORDER BY task_id, repo_slug",
                (self.namespace,),
                page_size=_MAX_RECONCILE_ROWS,
            ):
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
            for outbox_rows in _query_pages(
                connection,
                "SELECT outbox_id, task_id, purpose, payload_json, "
                "payload_digest, claim_owner, claim_expires_at, claim_token, "
                "claim_generation, requires_consumer_checkpoint, "
                "consumer_checkpointed_at, sent_at, rearm_at FROM outbox "
                "WHERE namespace = ? ORDER BY created_at, outbox_id",
                (self.namespace,),
                page_size=_MAX_RECONCILE_ROWS,
            ):
                for row in outbox_rows:
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
            if connection is not None:
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

    service_uid = _validated_service_uid(service_uid)
    state_directory: _BoundLockDirectory | None = None
    try:
        state_directory = _bind_state_root(workdir)
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
        if state_directory is not None:
            try:
                state_directory.close()
            except BaseException as cleanup_error:
                error.add_note(
                    "also failed to close the state directory binding: "
                    f"{cleanup_error}"
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
    def parent_descriptor(self) -> int:
        if len(self._descriptors) < 2:
            raise StateLocationError(
                "runtime state directory has no protected parent"
            )
        return self._descriptors[-2]

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
        child = -1
        original_descriptor_count = len(self._descriptors)
        original_name_count = len(self._names)
        original_path = self.path
        try:
            self.verify()
            try:
                os.mkdir(name, mode=0o700, dir_fd=self.descriptor)
            except FileExistsError:
                pass
            child = os.open(
                name,
                _lease_directory_flags(),
                dir_fd=self.descriptor,
            )
            _verify_private_directory(os.fstat(child))
            self._names.append(name)
            self._descriptors.append(child)
            self.path = original_path / name
            self.verify()
        except OSError as error:
            while len(self._descriptors) > original_descriptor_count:
                self._descriptors.pop()
            while len(self._names) > original_name_count:
                self._names.pop()
            self.path = original_path
            if child >= 0:
                try:
                    os.close(child)
                except BaseException as cleanup_error:
                    error.add_note(
                        f"also failed to close the rejected directory: "
                        f"{cleanup_error}"
                    )
            raise StateLocationError(
                "could not open runtime lock directory"
            ) from error
        except BaseException as error:
            while len(self._descriptors) > original_descriptor_count:
                self._descriptors.pop()
            while len(self._names) > original_name_count:
                self._names.pop()
            self.path = original_path
            if child >= 0:
                try:
                    os.close(child)
                except BaseException as cleanup_error:
                    error.add_note(
                        f"also failed to close the rejected directory: "
                        f"{cleanup_error}"
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
    except BaseException as error:
        if descriptor is not None:
            try:
                os.close(descriptor)
            except BaseException as cleanup_error:
                error.add_note(
                    f"also failed to close the rejected lock descriptor: {cleanup_error}"
                )
        raise


def _kernel_lease_address(service_uid: int, namespace: str, key: str) -> bytes:
    material = f"{service_uid}\0{namespace}\0{key}"
    return b"\0homeric-legacy-runtime-v1-" + _digest(material).encode("ascii")


def _acquire_kernel_lease(
    service_uid: int,
    namespace: str,
    keys: Sequence[str],
    timeout: float | None,
) -> tuple[socket.socket, int]:
    """Acquire one canonical kernel lease and return its owned socket."""

    if not _secure_descriptor_routes_supported():
        raise StateLocationError(
            "canonical runtime leases require Linux abstract Unix sockets"
        )
    if not keys:
        raise ValueError("at least one canonical lease key is required")
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
    while True:
        for index, key in enumerate(keys):
            candidate: socket.socket | None = None
            try:
                socket_type = socket.SOCK_DGRAM | getattr(socket, "SOCK_CLOEXEC", 0)
                candidate = socket.socket(socket.AF_UNIX, socket_type)
                candidate.set_inheritable(False)
                candidate.bind(_kernel_lease_address(service_uid, namespace, key))
                return candidate, index
            except OSError as error:
                if candidate is not None:
                    try:
                        candidate.close()
                    except BaseException as cleanup_error:
                        error.add_note(
                            "also failed to close a rejected canonical lease: "
                            f"{cleanup_error}"
                        )
                if error.errno == errno.EADDRINUSE:
                    continue
                raise StateLocationError(
                    "could not acquire the canonical kernel lease"
                ) from error
            except BaseException as error:
                if candidate is not None:
                    try:
                        candidate.close()
                    except BaseException as cleanup_error:
                        error.add_note(
                            "also failed to close an interrupted canonical lease: "
                            f"{cleanup_error}"
                        )
                raise
        if deadline is not None and time.monotonic() >= deadline:
            raise LeaseUnavailableError("runtime lease is unavailable")
        time.sleep(0.02)


@contextmanager
def _kernel_lease(
    service_uid: int,
    namespace: str,
    keys: Sequence[str],
    timeout: float | None,
) -> Iterator[int]:
    """Hold one canonical Linux-kernel lease that a path rename cannot split."""

    held_socket, slot = _acquire_kernel_lease(
        service_uid,
        namespace,
        keys,
        timeout,
    )
    primary: BaseException | None = None
    try:
        yield slot
    except BaseException as error:
        primary = error
        raise
    finally:
        try:
            held_socket.close()
        except BaseException as cleanup_error:
            if primary is not None:
                primary.add_note(
                    f"also failed to close the canonical kernel lease: {cleanup_error}"
                )
            else:
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
    if not filenames:
        raise ValueError("at least one runtime lease filename is required")
    descriptor: int | None = None
    held_path: tuple[int, int, str] | None = None
    slot = -1
    primary: BaseException | None = None
    try:
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
                    except BaseException as error:
                        try:
                            os.close(candidate)
                        except BaseException as cleanup_error:
                            error.add_note(
                                "also failed to close a contended lease: "
                                f"{cleanup_error}"
                            )
                        raise
                    try:
                        directory.verify()
                        _verify_lock_file(directory, filename, candidate)
                    except BaseException as error:
                        try:
                            fcntl.flock(candidate, fcntl.LOCK_UN)
                        except BaseException as cleanup_error:
                            error.add_note(
                                "also failed to unlock a rejected lease: "
                                f"{cleanup_error}"
                            )
                        try:
                            os.close(candidate)
                        except BaseException as cleanup_error:
                            error.add_note(
                                "also failed to close a rejected lease: "
                                f"{cleanup_error}"
                            )
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
        yield slot
    except BaseException as error:
        primary = error
        raise
    finally:
        cleanup_errors: list[BaseException] = []
        if descriptor is not None:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_UN)
            except BaseException as cleanup_error:
                cleanup_errors.append(cleanup_error)
            try:
                os.close(descriptor)
            except BaseException as cleanup_error:
                cleanup_errors.append(cleanup_error)
        if held_path is not None:
            try:
                with _local_lock_guard:
                    _local_lock_paths.discard(held_path)
            except BaseException as cleanup_error:
                # CPython set mutation is atomic under the GIL. This fallback
                # prevents an interrupted bookkeeping lock from stranding the
                # in-process lease after the kernel resources were released.
                _local_lock_paths.discard(held_path)
                cleanup_errors.append(cleanup_error)
        if primary is not None:
            for error in cleanup_errors:
                primary.add_note(f"also failed during lease cleanup: {error}")
        elif cleanup_errors:
            cleanup_error = cleanup_errors.pop(0)
            for error in cleanup_errors:
                cleanup_error.add_note(f"also failed during lease cleanup: {error}")
            raise cleanup_error


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
    binding: _BoundLockDirectory | None = None
    primary: BaseException | None = None
    try:
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
            _verify_private_directory(os.fstat(binding.descriptor))
            host_name = requested_root.name
        binding.append_private(host_name)
        binding.append_private("locks")
        binding.append_private(name)
        binding.verify()
        yield binding
    except BaseException as error:
        primary = error
        raise
    finally:
        if binding is not None:
            try:
                binding.close()
            except BaseException as cleanup_error:
                if primary is not None:
                    primary.add_note(
                        f"also failed to close the lock namespace: {cleanup_error}"
                    )
                else:
                    raise


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
    service_uid = _validated_service_uid(service_uid)
    state_root(workdir)
    filenames = [f"slot-{index}.lock" for index in range(max_slots)]
    with _kernel_lease(service_uid, "heavy", filenames, timeout) as slot:
        # Keep the legacy file lock as a secondary compatibility signal. The
        # abstract socket above is the canonical host authority and remains
        # held if a same-UID process renames this optional filesystem mirror.
        with _lock_directory(
            workdir,
            "heavy",
            host_lock_root=host_lock_root,
            service_uid=service_uid,
        ) as directory:
            with _file_lease(directory, [filenames[slot]], timeout):
                yield slot


@contextmanager
def checkout_lane(
    workdir: str | os.PathLike[str],
    checkout: str | os.PathLike[str],
    timeout: float | None = None,
    *,
    host_lock_root: str | os.PathLike[str] | None = None,
    service_uid: int,
) -> Iterator[str]:
    """Serialize one logical checkout and yield its retained operator path."""

    try:
        checkout_path = Path(checkout).resolve(strict=True)
    except (OSError, RuntimeError) as error:
        raise StateLocationError(f"checkout is unavailable: {error}") from error
    if not checkout_path.is_dir():
        raise StateLocationError("checkout is not a directory")
    checkout_binding: _BoundLockDirectory | None = None
    root_binding: _BoundLockDirectory | None = None
    primary: BaseException | None = None
    try:
        checkout_binding = _open_existing_directory_chain(checkout_path)
        checkout_root = Path(
            _run_git(checkout_path, "rev-parse", "--show-toplevel")
        )
        if not checkout_root.is_absolute():
            checkout_root = checkout_path / checkout_root
        try:
            checkout_root = checkout_root.resolve(strict=True)
        except (OSError, RuntimeError) as error:
            raise StateLocationError(
                f"checkout root is unavailable: {error}"
            ) from error
        root_binding = _open_existing_directory_chain(checkout_root)
        repeated_root = Path(
            _run_git(checkout_path, "rev-parse", "--show-toplevel")
        )
        if not repeated_root.is_absolute():
            repeated_root = checkout_path / repeated_root
        if repeated_root.resolve(strict=True) != checkout_root:
            raise StateLocationError("checkout root changed while binding")
        checkout_binding.verify()
        root_binding.verify()
        device, inode = root_binding.identity
        # Keep the legacy inode authority address during the transition. The
        # path authority adds replacement safety without splitting callers
        # that still hold the prior exact-inode lease.
        inode_key = _digest(f"{device}:{inode}")
        path_key = _digest(f"path\0{checkout_path}")
        service_uid = _validated_service_uid(service_uid)
        retained_checkout = (
            f"/proc/{os.getpid()}/fd/{checkout_binding.descriptor}"
        )
        if not os.path.isabs(retained_checkout):
            raise StateLocationError("retained checkout path is not absolute")
        with _kernel_lease(service_uid, "checkout-path", [path_key], timeout):
            with _kernel_lease(
                service_uid, "checkout", [inode_key], timeout
            ):
                with _lock_directory(
                    workdir,
                    "checkouts",
                    host_lock_root=host_lock_root,
                    service_uid=service_uid,
                ) as directory:
                    with _file_lease(directory, [f"{path_key}.lock"], timeout):
                        checkout_binding.verify()
                        root_binding.verify()
                        yield retained_checkout
                        for binding in (checkout_binding, root_binding):
                            info = os.fstat(binding.descriptor)
                            if not stat.S_ISDIR(info.st_mode):
                                raise StateLocationError(
                                    "retained checkout authority is not a directory"
                                )
    except BaseException as error:
        primary = error
        raise
    finally:
        cleanup_errors: list[BaseException] = []
        for binding, field in (
            (root_binding, "checkout root"),
            (checkout_binding, "checkout"),
        ):
            if binding is None:
                continue
            try:
                binding.close()
            except BaseException as cleanup_error:
                cleanup_error.add_note(f"while closing the {field} binding")
                cleanup_errors.append(cleanup_error)
        if primary is not None:
            for error in cleanup_errors:
                primary.add_note(f"also failed during checkout cleanup: {error}")
        elif cleanup_errors:
            cleanup_error = cleanup_errors.pop(0)
            for error in cleanup_errors:
                cleanup_error.add_note(
                    f"also failed during checkout cleanup: {error}"
                )
            raise cleanup_error


async def _terminate_worker(
    reason: str,
    supervisor: object | None = None,
) -> None:
    """Delegate fatal shutdown to one request-bound extinction authority."""

    authority = (
        current_worker_extinction_supervisor()
        if supervisor is None
        else _validated_extinction_supervisor(supervisor)
    )
    await authority.extinguish_and_terminate(reason)
    raise WorkerExtinctionError(
        "worker extinction authority returned without terminating the worker"
    )


def _validated_redelivery_exclusion(authority: object) -> object:
    for method in ("claim_message_delivery", "release_message_delivery"):
        if not callable(getattr(authority, method, None)):
            raise TypeError(
                "redelivery_exclusion must provide durable claim/release methods"
            )
    return authority


async def _dispatch_with_heartbeat(
    message: Any,
    handler: Callable[[Any], Awaitable[Any]],
    heartbeat_seconds: float,
    heartbeat_rpc_timeout: float,
    disposition_timeout: float,
    handler_shutdown_timeout: float = _DEFAULT_HANDLER_SHUTDOWN_TIMEOUT,
    extinction_supervisor: object | None = None,
    redelivery_exclusion: object | None = None,
    message_identity: Callable[[Any], str] | None = None,
    delivery_authority: DurableDispatchAuthority | NonpersistentDispatchAuthority | None = None,
) -> None:
    context_token = None
    request_scope: _WorkerRequestEffectScope | None = None
    request_scope_token = None
    if extinction_supervisor is not None:
        extinction_supervisor = _validated_extinction_supervisor(
            extinction_supervisor
        )
    if delivery_authority is not None and (
        redelivery_exclusion is not None or message_identity is not None
    ):
        raise TypeError(
            "delivery_authority cannot be combined with legacy exclusion args"
        )
    if (redelivery_exclusion is None) != (message_identity is None):
        raise TypeError(
            "redelivery_exclusion and message_identity must be provided together"
        )
    delivery_source_event_id: str | None = None
    delivery_claim_token: str | None = None
    delivery_lease: socket.socket | None = None
    delivery_store: object | None = None
    durable_delivery_token = None
    nonpersistent = isinstance(delivery_authority, NonpersistentDispatchAuthority)
    if delivery_authority is not None and not nonpersistent:
        if not isinstance(delivery_authority, DurableDispatchAuthority):
            raise TypeError("delivery_authority must be DurableDispatchAuthority")
        store = _validated_redelivery_exclusion(delivery_authority.store)
        delivery_store = store
        for method in (
            "acquire_message_delivery_lease",
            "inspect_message_delivery",
            "active_external_effects",
            "retire_external_effect",
            "take_over_message_delivery",
        ):
            if not callable(getattr(store, method, None)):
                raise TypeError(
                    f"delivery authority store must provide {method}()"
                )
        if not callable(delivery_authority.identify) or not callable(
            delivery_authority.reconcile
        ):
            raise TypeError(
                "delivery authority requires identify and reconcile callables"
            )
        delivery_source_event_id = delivery_authority.identify(message)
        if not _is_sha256(delivery_source_event_id):
            raise RejectMessage(
                "delivery authority identify() must return a stable digest"
            )
        while delivery_lease is None:
            try:
                delivery_lease = await asyncio.to_thread(
                    store.acquire_message_delivery_lease,
                    delivery_source_event_id,
                    timeout=heartbeat_rpc_timeout,
                )
            except LeaseUnavailableError:
                try:
                    await asyncio.wait_for(
                        message.in_progress(), timeout=heartbeat_rpc_timeout
                    )
                except asyncio.CancelledError:
                    raise
                except BaseException:
                    pass
                await asyncio.sleep(min(heartbeat_seconds, 0.1))
        try:
            prior_claim_token = await asyncio.to_thread(
                store.inspect_message_delivery, delivery_source_event_id
            )
            if prior_claim_token is None:
                delivery_claim_token = await asyncio.to_thread(
                    store.claim_message_delivery, delivery_source_event_id
                )
                if delivery_claim_token is None:
                    raise WorkerContainmentFatalError(
                        "delivery guard appeared while its kernel lease was held"
                    )
            else:
                while True:
                    receipts = await asyncio.to_thread(
                        store.active_external_effects, delivery_source_event_id
                    )
                    try:
                        for receipt in receipts:
                            proof = await delivery_authority.reconcile(receipt)
                            _verify_external_effect_extinction_proof(
                                receipt, proof
                            )
                            await asyncio.to_thread(
                                store.retire_external_effect,
                                delivery_source_event_id,
                                prior_claim_token,
                                receipt.effect_token,
                            )
                    except asyncio.CancelledError:
                        raise
                    except BaseException:
                        try:
                            await asyncio.wait_for(
                                message.in_progress(),
                                timeout=heartbeat_rpc_timeout,
                            )
                        except asyncio.CancelledError:
                            raise
                        except BaseException:
                            pass
                        await asyncio.sleep(min(heartbeat_seconds, 0.1))
                        continue
                    delivery_claim_token = await asyncio.to_thread(
                        store.take_over_message_delivery,
                        delivery_source_event_id,
                        prior_claim_token,
                    )
                    break
        except BaseException:
            delivery_lease.close()
            delivery_lease = None
            raise
    if redelivery_exclusion is not None:
        redelivery_exclusion = _validated_redelivery_exclusion(
            redelivery_exclusion
        )
        if not callable(message_identity):
            raise TypeError("message_identity must be callable")
        delivery_source_event_id = message_identity(message)
        if not _is_sha256(delivery_source_event_id):
            raise RejectMessage(
                "message_identity must return a stable event digest"
            )
        while delivery_claim_token is None:
            delivery_claim_token = await asyncio.to_thread(
                redelivery_exclusion.claim_message_delivery,
                delivery_source_event_id,
            )
            if delivery_claim_token is not None:
                if not _is_sha256(delivery_claim_token):
                    raise WorkerContainmentFatalError(
                        "redelivery exclusion returned a malformed claim token"
                    )
                break
            try:
                await asyncio.wait_for(
                    message.in_progress(),
                    timeout=heartbeat_rpc_timeout,
                )
            except asyncio.CancelledError:
                raise
            except BaseException:
                # The durable row, rather than broker timing, is the overlap
                # fence. Keep retrying while this delivery remains scheduled.
                pass
            await asyncio.sleep(min(heartbeat_seconds, 0.1))

    try:
        if extinction_supervisor is not None:
            context_token = _CURRENT_WORKER_EXTINCTION_SUPERVISOR.set(
                extinction_supervisor
            )
            if isinstance(extinction_supervisor, WorkerExtinctionSupervisor):
                request_scope = extinction_supervisor._open_request_effect_scope()
                if nonpersistent:
                    request_scope._admission_open = False
                request_scope_token = _CURRENT_WORKER_REQUEST_EFFECT_SCOPE.set(
                    request_scope
                )
        if nonpersistent:
            durable_delivery_token = _CURRENT_DURABLE_DELIVERY.set(None)
        elif delivery_store is not None:
            durable_delivery_token = _CURRENT_DURABLE_DELIVERY.set(
                _DurableDeliveryContext(
                    delivery_store,
                    delivery_source_event_id,
                    delivery_claim_token,
                )
            )
        handler_task = asyncio.create_task(handler(message))
    except BaseException:
        if durable_delivery_token is not None:
            _CURRENT_DURABLE_DELIVERY.reset(durable_delivery_token)
        if request_scope_token is not None:
            _CURRENT_WORKER_REQUEST_EFFECT_SCOPE.reset(request_scope_token)
        if context_token is not None:
            _CURRENT_WORKER_EXTINCTION_SUPERVISOR.reset(context_token)
        if delivery_lease is not None:
            delivery_lease.close()
        raise
    terminal_disposition_started: str | None = None
    extinction_started = False

    async def bounded_message_rpc(
        request: Awaitable[Any], timeout: float
    ) -> None:
        """Keep fatal RPC outcomes in the dispatch task, not a child task."""

        async def capture() -> BaseException | None:
            try:
                await request
            except asyncio.CancelledError:
                raise
            except BaseException as error:
                return error
            return None

        outcome = await asyncio.wait_for(capture(), timeout=timeout)
        if outcome is not None:
            raise outcome

    async def settle_handler() -> None:
        """Wait until handler work actually stops before allowing redelivery.

        Cancelling an asyncio task that is awaiting ``asyncio.to_thread`` does
        not stop or join the underlying thread.  A NAK at that point can hand
        the same checkout to a redelivery while the original subprocess still
        mutates it.  Shield the handler and retain its lanes/claims until its
        real completion, even while this dispatcher is being cancelled.
        """

        nonlocal extinction_started
        deadline = time.monotonic() + handler_shutdown_timeout
        while not handler_task.done():
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                extinction_started = True
                await terminate_with_redelivery_quarantine(
                    "message handler did not stop before its extinction deadline",
                )
            try:
                done, _pending = await asyncio.wait(
                    {handler_task}, timeout=min(remaining, 0.05)
                )
                if handler_task in done:
                    break
            except asyncio.CancelledError:
                if handler_task.done():
                    break
                continue
        if handler_task.done():
            try:
                await asyncio.shield(handler_task)
            except WorkerContainmentFatalError as error:
                extinction_started = True
                await terminate_with_redelivery_quarantine(
                    f"containment-fatal: {error}",
                )
            except BaseException:
                pass

    async def disposition(
        operation: str,
        *,
        delay: float | None = None,
    ) -> None:
        nonlocal terminal_disposition_started, extinction_started
        if terminal_disposition_started is not None:
            raise ConsumerDispositionError(
                "JetStream terminal disposition was already attempted"
            )
        if request_scope is not None:
            try:
                request_scope.seal_and_verify_quiescent()
            except WorkerContainmentFatalError as error:
                extinction_started = True
                await terminate_with_redelivery_quarantine(
                    f"containment-fatal: {error}",
                )
        terminal_disposition_started = operation
        try:
            call = getattr(message, operation)
            request = call() if delay is None else call(delay=delay)
            await bounded_message_rpc(request, disposition_timeout)
        except (asyncio.CancelledError, KeyboardInterrupt, SystemExit):
            raise
        except Exception as error:
            raise ConsumerDispositionError(
                f"JetStream {operation} failed"
            ) from error
        if (
            (redelivery_exclusion is not None or delivery_store is not None)
            and delivery_source_event_id is not None
            and delivery_claim_token is not None
        ):
            try:
                await asyncio.to_thread(
                    (
                        delivery_store
                        if delivery_store is not None
                        else redelivery_exclusion
                    ).release_message_delivery,
                    delivery_source_event_id,
                    delivery_claim_token,
                )
            except BaseException as error:
                extinction_started = True
                await terminate_with_redelivery_quarantine(
                    f"delivery-guard retirement failed after {operation}: {error}",
                )

    async def terminate_with_redelivery_quarantine(reason: str) -> None:
        """Keep extending broker ownership until extinction terminates us.

        A failed extinction attempt is not a message-processing failure: NAK or
        return would allow the same external effect to overlap a redelivery.
        Retain the message without a terminal disposition and retry the exact
        authority. Cancellation is likewise deferred until extinction wins.
        """

        if request_scope is not None:
            try:
                request_scope.seal_and_verify_quiescent()
            except WorkerContainmentFatalError:
                pass
        if isinstance(extinction_supervisor, WorkerExtinctionSupervisor):
            with extinction_supervisor._external_effects_lock:
                extinction_supervisor._extinction_started = True

        async def extinction_attempt() -> BaseException:
            try:
                await _terminate_worker(reason, extinction_supervisor)
            except BaseException as error:
                return error
            return WorkerExtinctionError(
                "worker extinction returned without a terminal outcome"
            )

        async def retain_broker_ownership() -> None:
            try:
                await bounded_message_rpc(
                    message.in_progress(), heartbeat_rpc_timeout
                )
            except BaseException:
                # Once containment is uncertain, no broker-side failure or
                # cancellation is allowed to outrank exact extinction.
                pass

        while True:
            attempt = asyncio.create_task(extinction_attempt())
            while not attempt.done():
                try:
                    done, _pending = await asyncio.wait(
                        {attempt}, timeout=heartbeat_seconds
                    )
                except asyncio.CancelledError:
                    continue
                if attempt not in done:
                    await retain_broker_ownership()
            outcome = attempt.result()
            if not isinstance(outcome, (Exception, asyncio.CancelledError)):
                raise outcome
            await retain_broker_ownership()
            try:
                await asyncio.sleep(min(max(heartbeat_seconds, 0.001), 0.1))
            except asyncio.CancelledError:
                continue

    try:
        while True:
            done, _pending = await asyncio.wait(
                {handler_task}, timeout=heartbeat_seconds
            )
            if handler_task in done:
                try:
                    await handler_task
                except WorkerContainmentFatalError as error:
                    extinction_started = True
                    await terminate_with_redelivery_quarantine(
                        f"containment-fatal: {error}",
                    )
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
                await bounded_message_rpc(
                    message.in_progress(), heartbeat_rpc_timeout
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
    except BaseException:
        if not extinction_started:
            await settle_handler()
        raise
    finally:
        if durable_delivery_token is not None:
            _CURRENT_DURABLE_DELIVERY.reset(durable_delivery_token)
        if delivery_lease is not None:
            delivery_lease.close()
        if request_scope_token is not None:
            _CURRENT_WORKER_REQUEST_EFFECT_SCOPE.reset(request_scope_token)
        if context_token is not None:
            _CURRENT_WORKER_EXTINCTION_SUPERVISOR.reset(context_token)


async def run_consumer_workers(
    subscription: Any,
    handler: Callable[[Any], Awaitable[Any]],
    *,
    max_workers: int = _MAX_HEAVY_SLOTS,
    heartbeat_seconds: float = 30.0,
    heartbeat_rpc_timeout: float = 10.0,
    disposition_timeout: float = 10.0,
    handler_shutdown_timeout: float = _DEFAULT_HANDLER_SHUTDOWN_TIMEOUT,
    fetch_timeout: float = 1.0,
    stop_event: asyncio.Event | None = None,
    extinction_supervisor: object | None = None,
    redelivery_exclusion: object | None = None,
    message_identity: Callable[[Any], str] | None = None,
    delivery_authority: DurableDispatchAuthority | NonpersistentDispatchAuthority | None = None,
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
        (handler_shutdown_timeout, "handler_shutdown_timeout"),
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
    if extinction_supervisor is not None:
        extinction_supervisor = _validated_extinction_supervisor(
            extinction_supervisor
        )
    if delivery_authority is not None and (
        redelivery_exclusion is not None or message_identity is not None
    ):
        raise TypeError(
            "delivery_authority cannot be combined with legacy exclusion args"
        )
    if (redelivery_exclusion is None) != (message_identity is None):
        raise TypeError(
            "redelivery_exclusion and message_identity must be provided together"
        )
    if redelivery_exclusion is not None:
        redelivery_exclusion = _validated_redelivery_exclusion(
            redelivery_exclusion
        )
        if not callable(message_identity):
            raise TypeError("message_identity must be callable")
    if (
        isinstance(extinction_supervisor, LinuxWorkerExtinctionSupervisor)
        and (
            not getattr(extinction_supervisor, "_cgroup_managed", False)
            or not isinstance(delivery_authority, (DurableDispatchAuthority, NonpersistentDispatchAuthority))
        )
    ):
        raise WorkerContainmentUnavailableError(
            "operational Linux workers require parent cgroup containment and "
            "durable delivery reconciliation"
        )

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
                    handler_shutdown_timeout,
                    extinction_supervisor,
                    redelivery_exclusion,
                    message_identity,
                    delivery_authority,
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
    "DurableDispatchAuthority",
    "NonpersistentDispatchAuthority",
    "ExternalEffectExtinctionProof",
    "ExternalEffectReceipt",
    "HostBindingError",
    "LeaseUnavailableError",
    "LegacyRuntimeError",
    "LinuxWorkerExtinctionSupervisor",
    "LinuxWorkerLimits",
    "MAX_ISSUE_NUMBER",
    "MAX_ITERATION",
    "PermanentMessageError",
    "RejectMessage",
    "RetryMessage",
    "RuntimeStore",
    "StateConflictError",
    "StateLocationError",
    "TransientMessageError",
    "WorkerContainmentError",
    "WorkerContainmentFatalError",
    "WorkerContainmentUnavailableError",
    "WorkerExtinctionError",
    "WorkerExtinctionSupervisor",
    "bind_worker_extinction_supervisor",
    "checkout_lane",
    "container_binding_digest",
    "current_worker_extinction_supervisor",
    "external_container_supervisor",
    "external_effect_extinction_proof",
    "external_effect_supervisor",
    "heavy_slot",
    "inherited_cgroup_v2_parent_fd",
    "pod_binding_digest",
    "reconcile_external_container_effect",
    "run_linux_cgroup_worker",
    "run_consumer_workers",
    "runtime_store",
    "stable_event_id",
    "state_root",
    "validate_message_iteration",
]
