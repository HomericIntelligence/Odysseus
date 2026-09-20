"""Behavior tests for the legacy myrmidon single-host runtime state.

These tests use disposable Git repositories and local process/file primitives.
They do not require NATS, Tailscale, a container runtime, or network access.
"""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import ctypes
import errno
import fcntl
import hashlib
import json
import multiprocessing
import os
import signal
import socket
import subprocess
import sqlite3
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch


_E2E_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_E2E_ROOT) not in sys.path:
    sys.path.insert(0, str(_E2E_ROOT))

import legacy_runtime  # noqa: E402
import legacy_athena  # noqa: E402


_TEST_ENGINE_ENDPOINT_IDENTITY = {"authority_digest": "9" * 64}


class _ControlledEndpoint:
    """Replace only the broker transport for pure supervisor behavior tests."""

    def enter_command(self, runtime, arguments, *, input_text=None, timeout_seconds):
        if input_text is not None:
            raise AssertionError("cleanup does not accept stdin")
        code, output, errors = legacy_runtime._run_exact_container_command(
            runtime.descriptor, {"LC_ALL": "C"}, tuple(arguments), timeout_seconds,
        )
        return subprocess.CompletedProcess(arguments, code, output.decode(), errors.decode())

    def register_effect(self, effect, supervisor):
        self.effect = effect

    def durable_effect_identity(self):
        return dict(_TEST_ENGINE_ENDPOINT_IDENTITY)

    def release_effect(self, effect):
        if not effect._extinction_proven:
            raise AssertionError("effect released before extinction")


_TEST_CANDIDATE_UID = 65534 if os.geteuid() != 65534 else 65533


def _git(root: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", str(root), *args],
        check=True,
        capture_output=True,
        text=True,
        stdin=subprocess.DEVNULL,
    )
    return result.stdout.strip()


def _init_repo(root: Path) -> None:
    root.mkdir(parents=True, exist_ok=True)
    _git(root, "init", "--quiet")
    _git(root, "config", "user.email", "runtime-tests@example.invalid")
    _git(root, "config", "user.name", "Runtime Tests")
    (root / "README.md").write_text("fixture\n", encoding="utf-8")
    _git(root, "add", "README.md")
    _git(root, "-c", "commit.gpgsign=false", "commit", "--quiet", "-m", "base")


def _hold_heavy_slot(
    workdir: str,
    host_lock_root: str,
    service_uid: int,
    acquired: multiprocessing.synchronize.Event,
    release: multiprocessing.synchronize.Event,
) -> None:
    with legacy_runtime.heavy_slot(
        workdir,
        max_slots=3,
        timeout=5,
        host_lock_root=host_lock_root,
        service_uid=service_uid,
    ):
        acquired.set()
        release.wait(10)


def _hold_checkout_lane(
    workdir: str,
    checkout: str,
    host_lock_root: str,
    service_uid: int,
    acquired: multiprocessing.synchronize.Event,
) -> None:
    with legacy_runtime.checkout_lane(
        workdir,
        checkout,
        timeout=5,
        host_lock_root=host_lock_root,
        service_uid=service_uid,
    ):
        acquired.set()
        time.sleep(30)


class DescriptorRouteCompatibilityTest(unittest.TestCase):
    def test_distinct_stores_bound_descriptor_guard_contention(self) -> None:
        class Lease:
            def __init__(self) -> None:
                self.closed = False

            def close(self) -> None:
                self.closed = True

        class Connection:
            def __init__(self) -> None:
                self._guard_state_lease = None

            def close(self) -> None:
                if self._guard_state_lease is not None:
                    self._guard_state_lease.close()

        stores = []
        for index in range(2):
            store = object.__new__(legacy_runtime.RuntimeStore)
            store.service_uid = os.geteuid()
            store._state_lease_key = f"store-{index}"
            store._connect_locked = lambda *_args: Connection()
            stores.append(store)

        admission = threading.Barrier(3)
        leases: list[Lease] = []

        def acquire_lease(*_args) -> tuple[Lease, int]:
            lease = Lease()
            leases.append(lease)
            admission.wait(timeout=1)
            return lease, 0

        observed: list[BaseException | None] = []
        futures = []
        pool = ThreadPoolExecutor(max_workers=2)
        legacy_runtime._sqlite_descriptor_guard.acquire()
        try:
            with (
                patch.object(
                    legacy_runtime,
                    "_SQLITE_LEASE_TIMEOUT_SECONDS",
                    0.05,
                ),
                patch.object(
                    legacy_runtime,
                    "_acquire_kernel_lease",
                    side_effect=acquire_lease,
                ),
            ):
                futures = [pool.submit(store._connect) for store in stores]
                admission.wait(timeout=1)
                for future in futures:
                    try:
                        future.result(timeout=0.5)
                    except BaseException as error:
                        observed.append(error)
                    else:
                        observed.append(None)
        finally:
            legacy_runtime._sqlite_descriptor_guard.release()
            for future in futures:
                try:
                    connection = future.result(timeout=1)
                except BaseException:
                    continue
                connection.close()
            pool.shutdown(wait=True, cancel_futures=True)

        self.assertTrue(
            all(
                isinstance(error, legacy_runtime.LeaseUnavailableError)
                for error in observed
            ),
            observed,
        )
        self.assertEqual(len(leases), 2)
        self.assertTrue(all(lease.closed for lease in leases))

    def test_legacy_route_migration_installs_physical_not_null_constraint(
        self,
    ) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "legacy.sqlite3"
            repo = "HomericIntelligence/Odysseus"
            registry_digest = "a" * 64
            namespace = hashlib.sha256(
                f"{repo}\0{registry_digest}".encode()
            ).hexdigest()
            route_json = legacy_runtime._canonical_json(
                {"github_repo": repo, "path": "."}, "route"
            )
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.executescript(
                    """
                    CREATE TABLE tasks (
                        namespace TEXT NOT NULL,
                        task_id TEXT NOT NULL,
                        team_id TEXT NOT NULL,
                        issue_number INTEGER NOT NULL,
                        task_digest TEXT NOT NULL,
                        completion_json TEXT,
                        completed_at REAL,
                        created_at REAL NOT NULL,
                        PRIMARY KEY (namespace, task_id)
                    );
                    CREATE TABLE routes (
                        namespace TEXT NOT NULL,
                        task_id TEXT NOT NULL,
                        repo_slug TEXT NOT NULL,
                        route_json TEXT NOT NULL,
                        PRIMARY KEY (namespace, task_id, repo_slug),
                        FOREIGN KEY (namespace, task_id)
                            REFERENCES tasks(namespace, task_id)
                    );
                    CREATE INDEX pure_legacy_route_index ON routes(route_json);
                    CREATE TABLE pure_route_audit (repo_slug TEXT NOT NULL);
                    CREATE TRIGGER pure_legacy_route_trigger
                        AFTER UPDATE ON routes
                        BEGIN
                            INSERT INTO pure_route_audit VALUES (NEW.repo_slug);
                        END;
                    CREATE TABLE pure_route_child (
                        namespace TEXT NOT NULL,
                        task_id TEXT NOT NULL,
                        repo_slug TEXT NOT NULL,
                        FOREIGN KEY (namespace, task_id, repo_slug)
                            REFERENCES routes(namespace, task_id, repo_slug)
                    );
                    """
                )
                connection.execute(
                    "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, NULL, NULL, ?)",
                    (namespace, "legacy-task", "team-1", 1, "b" * 64, 1.0),
                )
                connection.execute(
                    "INSERT INTO routes VALUES (?, ?, ?, ?)",
                    (namespace, "legacy-task", "odysseus", route_json),
                )
                connection.execute(
                    "INSERT INTO pure_route_child VALUES (?, ?, ?)",
                    (namespace, "legacy-task", "odysseus"),
                )

            store = object.__new__(legacy_runtime.RuntimeStore)
            with closing(
                sqlite3.connect(database, isolation_level=None)
            ) as connection:
                connection.row_factory = sqlite3.Row
                signature = store._route_column_signature(
                    list(connection.execute("PRAGMA table_info(routes)"))
                )
                connection.execute("BEGIN EXCLUSIVE")
                store._rebuild_routes_with_digest_constraint(
                    connection,
                    signature,
                )
                connection.commit()

            with closing(sqlite3.connect(database)) as connection:
                route_columns = {
                    row[1]: row
                    for row in connection.execute("PRAGMA table_info(routes)")
                }
                self.assertIn(
                    "pure_legacy_route_index",
                    {
                        row[1]
                        for row in connection.execute("PRAGMA index_list(routes)")
                    },
                )
                self.assertIsNotNone(
                    connection.execute(
                        "SELECT 1 FROM sqlite_schema WHERE type = 'trigger' "
                        "AND name = 'pure_legacy_route_trigger'"
                    ).fetchone()
                )
                self.assertEqual(
                    {
                        row[2]
                        for row in connection.execute(
                            "PRAGMA foreign_key_list(pure_route_child)"
                        )
                    },
                    {"routes"},
                )
                connection.execute(
                    "UPDATE routes SET route_json = route_json"
                )
                self.assertEqual(
                    connection.execute(
                        "SELECT COUNT(*) FROM pure_route_audit"
                    ).fetchone()[0],
                    1,
                )
            self.assertEqual(route_columns["route_digest"][3], 1)

            with closing(sqlite3.connect(database)) as connection, connection:
                connection.executescript(
                    """
                    CREATE TABLE routes_nullable_tamper (
                        namespace TEXT NOT NULL,
                        task_id TEXT NOT NULL,
                        repo_slug TEXT NOT NULL,
                        route_json TEXT NOT NULL,
                        route_digest TEXT,
                        PRIMARY KEY (namespace, task_id, repo_slug),
                        FOREIGN KEY (namespace, task_id)
                            REFERENCES tasks(namespace, task_id)
                    );
                    INSERT INTO routes_nullable_tamper
                        SELECT namespace, task_id, repo_slug, route_json, NULL
                        FROM routes;
                    DROP TABLE routes;
                    ALTER TABLE routes_nullable_tamper RENAME TO routes;
                    """
                )

            with closing(
                sqlite3.connect(database, isolation_level=None)
            ) as connection:
                connection.row_factory = sqlite3.Row
                signature = store._route_column_signature(
                    list(connection.execute("PRAGMA table_info(routes)"))
                )
                connection.execute("BEGIN EXCLUSIVE")
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store._rebuild_routes_with_digest_constraint(
                        connection,
                        signature,
                    )
                connection.rollback()
            with closing(sqlite3.connect(database)) as connection:
                self.assertIsNotNone(
                    connection.execute(
                        "SELECT 1 FROM routes WHERE route_digest IS NULL"
                    ).fetchone()
                )
                self.assertIsNone(
                    connection.execute(
                        "SELECT 1 FROM sqlite_schema WHERE "
                        "name = 'routes_homeric_not_null_rebuild'"
                    ).fetchone()
                )

    def test_ambient_path_cannot_select_the_git_executable(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            _init_repo(root)
            fake_bin = Path(temporary) / "bin"
            fake_bin.mkdir()
            marker = Path(temporary) / "ambient-git-ran"
            fake_git = fake_bin / "git"
            fake_git.write_text(
                "#!/bin/sh\n: > \"$MARKER_PATH\"\nprintf '.git\\n'\n",
                encoding="utf-8",
            )
            fake_git.chmod(0o755)

            failure: BaseException | None = None
            try:
                with patch.dict(
                    os.environ,
                    {
                        "PATH": f"{fake_bin}{os.pathsep}{os.environ.get('PATH', '')}",
                        "MARKER_PATH": str(marker),
                    },
                ):
                    legacy_runtime.state_root(root)
            except BaseException as error:
                failure = error

            if sys.platform.startswith("linux"):
                self.assertIsNone(failure)
            else:
                self.assertIsInstance(failure, legacy_runtime.StateLocationError)
            self.assertFalse(marker.exists())

    def test_darwin_fails_closed_for_linux_descriptor_and_kernel_authorities(
        self,
    ) -> None:
        if sys.platform.startswith("linux"):
            self.skipTest("Linux exercises the retained-descriptor proof")
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            _init_repo(root)
            with self.assertRaises(legacy_runtime.StateLocationError):
                legacy_runtime.state_root(root)
            with patch.dict(
                os.environ,
                {
                    "HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid()),
                    "HOMERIC_LEGACY_CANDIDATE_UID": str(_TEST_CANDIDATE_UID),
                },
            ), self.assertRaises(legacy_runtime.StateLocationError):
                with legacy_runtime.heavy_slot(
                    root,
                    max_slots=1,
                    timeout=0,
                    service_uid=os.geteuid(),
                ):
                    pass

    @unittest.skipUnless(
        sys.platform.startswith("linux"),
        "retained Git descriptors require Linux /proc/self/fd",
    )
    def test_state_mkdir_ancestor_replacement_cannot_write_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            _init_repo(root)
            common = root / ".git"
            held_common = root / ".git-held"
            real_mkdir = legacy_runtime.os.mkdir
            swapped = False

            def replace_common_then_mkdir(path, mode=0o777, *, dir_fd=None):
                nonlocal swapped
                if path == legacy_runtime._STATE_DIRECTORY and not swapped:
                    swapped = True
                    common.rename(held_common)
                    real_mkdir(common, 0o700)
                return real_mkdir(path, mode, dir_fd=dir_fd)

            with patch.object(
                legacy_runtime.os,
                "mkdir",
                side_effect=replace_common_then_mkdir,
            ), self.assertRaises(legacy_runtime.StateLocationError):
                legacy_runtime.state_root(root)

            self.assertTrue(swapped)
            self.assertEqual(list(common.iterdir()), [])

    def test_unsupported_host_fails_before_creating_the_database(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary) / "repo"
            _init_repo(root)
            if not sys.platform.startswith("linux"):
                with patch.dict(
                    os.environ,
                    {
                        "HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid()),
                        "HOMERIC_LEGACY_CANDIDATE_UID": str(
                            _TEST_CANDIDATE_UID
                        ),
                    },
                ), self.assertRaises(legacy_runtime.StateLocationError):
                    legacy_runtime.runtime_store(
                        root,
                        "HomericIntelligence/Odysseus",
                        "a" * 64,
                        host_id="host-a",
                        service_uid=os.geteuid(),
                        message_retention_seconds=3600,
                        duplicate_window_seconds=120,
                    )
                return
            state = legacy_runtime.state_root(root)
            database = state / "state.sqlite3"
            with patch.dict(
                os.environ,
                {
                    "HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid()),
                    "HOMERIC_LEGACY_CANDIDATE_UID": str(_TEST_CANDIDATE_UID),
                },
            ), patch.object(
                legacy_runtime,
                "_descriptor_sqlite_route_supported",
                return_value=False,
            ), self.assertRaises(legacy_runtime.StateLocationError):
                legacy_runtime.runtime_store(
                    root,
                    "HomericIntelligence/Odysseus",
                    "a" * 64,
                    host_id="host-a",
                    service_uid=os.geteuid(),
                    message_retention_seconds=3600,
                    duplicate_window_seconds=120,
                )
            self.assertFalse(database.exists())


@unittest.skipUnless(
    legacy_runtime._descriptor_sqlite_route_supported(),
    "durable SQLite runtime requires Linux /proc/self/fd",
)
class RuntimeStoreTest(unittest.TestCase):
    def setUp(self) -> None:
        self.service_uid_environment = patch.dict(
            os.environ,
            {
                "HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid()),
                "HOMERIC_LEGACY_CANDIDATE_UID": str(_TEST_CANDIDATE_UID),
            },
        )
        self.service_uid_environment.start()
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name) / "repo"
        _init_repo(self.root)
        self.repo = "HomericIntelligence/Odysseus"
        self.registry_digest = "a" * 64
        self.task_digest = "b" * 64
        self.routes = {
            "keystone": {
                "path": "provisioning/Keystone",
                "github_repo": "HomericIntelligence/Keystone",
            },
            "hephaestus": {
                "path": "shared/Hephaestus",
                "github_repo": "HomericIntelligence/Hephaestus",
            },
        }

    def tearDown(self) -> None:
        self.tempdir.cleanup()
        self.service_uid_environment.stop()

    def _store(
        self,
        *,
        host_id: str = "host-a",
        message_retention_seconds: float = 3600,
        duplicate_window_seconds: float = 120,
        clock=time.time,
    ) -> legacy_runtime.RuntimeStore:
        return legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id=host_id,
            service_uid=os.geteuid(),
            message_retention_seconds=message_retention_seconds,
            duplicate_window_seconds=duplicate_window_seconds,
            clock=clock,
        )

    def _record_plan(self, store: legacy_runtime.RuntimeStore) -> None:
        store.record_plan(
            "task-1",
            "team-1",
            22,
            self.routes,
            self.task_digest,
        )

    def test_issue_number_must_fit_the_persistent_integer_domain(self) -> None:
        maximum = (1 << 63) - 1
        accepted = self._store(host_id="host-maximum")
        accepted.record_plan(
            "task-maximum", "team-1", maximum, self.routes, self.task_digest
        )
        self.assertEqual(accepted.load_task("task-maximum")["issue_number"], maximum)

        for index, value in enumerate((True, 1.0, "1", 0, -1, maximum + 1)):
            with self.subTest(value=value):
                failure = None
                try:
                    accepted.record_plan(
                        f"task-invalid-{index}",
                        "team-1",
                        value,
                        self.routes,
                        self.task_digest,
                    )
                except Exception as error:  # Capture the public error contract.
                    failure = error
                self.assertIsInstance(failure, ValueError)

    def test_stage_iteration_and_route_slug_fit_unambiguous_sqlite_keys(
        self,
    ) -> None:
        maximum = (1 << 63) - 1
        self.assertEqual(legacy_runtime._validated_iteration(maximum), maximum)
        for value in (maximum + 1, "1", 1.0, True, -1):
            with self.subTest(iteration=value), self.assertRaises(ValueError):
                legacy_runtime._validated_iteration(value)

        store = self._store()
        with self.assertRaises(ValueError):
            store.record_plan(
                "task-colon-route",
                "team-1",
                22,
                {
                    "keystone:review": {
                        "path": "provisioning/Keystone",
                        "github_repo": "HomericIntelligence/Keystone",
                    }
                },
                self.task_digest,
            )
        self.assertIsNone(store.load_task("task-colon-route"))

    def test_public_stage_ingress_rejects_out_of_domain_iteration(self) -> None:
        store = self._store()
        invalid = legacy_runtime.MAX_ITERATION + 1
        common = {
            "source_event_id": "c" * 64,
            "source_message_id": "d" * 64,
            "subject": "hi.myrmidon.claude.test.task-1",
            "payload": {"task_id": "task-1", "iteration": invalid},
        }

        with self.assertRaises(legacy_runtime.RejectMessage):
            store.inspect_stage(
                "task-1",
                "keystone",
                "test",
                invalid,
                **common,
            )
        with self.assertRaises(legacy_runtime.RejectMessage):
            store.claim_stage(
                "task-1",
                "keystone",
                "test",
                invalid,
                owner="worker",
                lease_seconds=30,
                **common,
            )

    def test_sqlite_authority_acquisition_uses_one_finite_deadline(self) -> None:
        store = self._store()
        observed_timeouts: list[float | None] = []
        acquire = legacy_runtime._acquire_kernel_lease

        def capture_timeout(service_uid, namespace, keys, timeout):
            observed_timeouts.append(timeout)
            return acquire(service_uid, namespace, keys, timeout)

        with patch.object(
            legacy_runtime,
            "_acquire_kernel_lease",
            side_effect=capture_timeout,
        ):
            self.assertIsNone(store.load_task("not-persisted"))

        self.assertTrue(observed_timeouts)
        self.assertTrue(
            all(
                isinstance(timeout, (int, float))
                and not isinstance(timeout, bool)
                and 0 < timeout <= 30
                for timeout in observed_timeouts
            ),
            observed_timeouts,
        )

    def test_aggregate_sqlite_page_budget_rolls_back_oversized_state(self) -> None:
        store = self._store()
        with closing(sqlite3.connect(store.database)) as connection:
            page_size = connection.execute("PRAGMA page_size").fetchone()[0]
            baseline_pages = connection.execute("PRAGMA page_count").fetchone()[0]
        byte_budget = (
            legacy_runtime._SQLITE_DIRTY_CACHE_BYTES
            + legacy_runtime._SQLITE_COMMIT_RESERVE_BYTES
            + legacy_runtime._SQLITE_MAX_SECTOR_BYTES
            + (baseline_pages + 64) * (3 * page_size + 8)
        )

        def transition(task_id: str, payload_value: str) -> None:
            subject = f"hi.tasks.team-1.{task_id}.assigned"
            payload = {"task_id": task_id, "value": payload_value}
            route = {
                "keystone": {
                    **self.routes["keystone"],
                    "dispatch_event": {
                        "subject": f"hi.myrmidon.claude.test.{task_id}",
                        "payload": payload,
                    },
                }
            }
            store.record_plan_transition(
                task_id,
                "team-1",
                22,
                route,
                self.task_digest,
                source_event_id=legacy_runtime.stable_event_id(
                    subject,
                    stream="homeric-tasks",
                    message_id=f"source-{task_id}",
                ),
                subject=subject,
                payload=payload,
            )

        with patch.object(
            legacy_runtime,
            "_MAX_DURABLE_STATE_BYTES",
            byte_budget,
            create=True,
        ):
            transition("page-budget-small", "ok")
            with self.assertRaises(legacy_runtime.StateConflictError):
                transition("page-budget-oversized", "x" * (700 * 1024))

        self.assertIsNotNone(store.load_task("page-budget-small"))
        self.assertIsNone(store.load_task("page-budget-oversized"))
        allocated = sum(
            candidate.stat().st_size
            for candidate in (
                store.database,
                Path(f"{store.database}-journal"),
                Path(f"{store.database}-wal"),
                Path(f"{store.database}-shm"),
            )
            if candidate.exists()
        )
        self.assertLessEqual(allocated, byte_budget)

    def test_runtime_uses_bounded_rollback_journal_and_memory_temp_store(
        self,
    ) -> None:
        store = self._store()
        with closing(store._connect()) as connection:
            self.assertEqual(
                str(connection.execute("PRAGMA journal_mode").fetchone()[0]).lower(),
                "persist",
            )
            self.assertEqual(
                connection.execute("PRAGMA temp_store").fetchone()[0],
                2,
            )
            self.assertEqual(
                connection.execute("PRAGMA cache_spill").fetchone()[0],
                0,
            )

    def test_preexisting_wal_allocation_fails_closed_before_reopen(self) -> None:
        store = self._store()
        wal = Path(f"{store.database}-wal")
        shm = Path(f"{store.database}-shm")
        wal.write_bytes(b"untrusted legacy WAL allocation")
        shm.write_bytes(b"untrusted legacy SHM allocation")
        wal.chmod(0o600)
        shm.chmod(0o600)

        failure: BaseException | None = None
        try:
            store.load_task("missing-task")
        except BaseException as error:
            failure = error
        self.assertIsInstance(failure, legacy_runtime.StateConflictError)

    def test_hot_rollback_journal_recovers_within_hard_quota(self) -> None:
        store = self._store()
        child = subprocess.run(
            [
                sys.executable,
                "-c",
                "import os,sqlite3,sys; "
                "c=sqlite3.connect(sys.argv[1]); "
                "c.execute('PRAGMA journal_mode=PERSIST').fetchone(); "
                "c.execute('PRAGMA synchronous=FULL'); "
                "c.execute('BEGIN IMMEDIATE'); "
                "c.execute(\"UPDATE runtimes SET host_id='uncommitted'\"); "
                "os._exit(73)",
                str(store.database),
            ],
            check=False,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
        )
        self.assertEqual(child.returncode, 73, child.stderr)
        journal = Path(f"{store.database}-journal")
        self.assertTrue(journal.exists())

        reopened = self._store()
        self.assertIsNone(reopened.load_task("missing-task"))
        allocated = sum(
            candidate.stat().st_size
            for candidate in (reopened.database, journal)
            if candidate.exists()
        )
        self.assertLessEqual(allocated, legacy_runtime._MAX_DURABLE_STATE_BYTES)

    def test_oversized_startup_journal_is_rejected(self) -> None:
        store = self._store()
        journal = Path(f"{store.database}-journal")
        with journal.open("ab") as stream:
            stream.truncate(legacy_runtime._MAX_DURABLE_STATE_BYTES)
        journal.chmod(0o600)

        with self.assertRaises(legacy_runtime.StateConflictError):
            store.load_task("missing-task")

    def test_failed_transaction_rechecks_quota_after_rollback(self) -> None:
        store = self._store()
        observed_transaction_states: list[bool] = []
        verify = store._verify_durable_page_budget

        def record_verification(connection, deadline=None) -> None:
            observed_transaction_states.append(connection.in_transaction)
            verify(connection, deadline)

        with patch.object(
            store,
            "_verify_durable_page_budget",
            side_effect=record_verification,
        ), self.assertRaisesRegex(RuntimeError, "intentional transaction failure"):
            with store._transaction():
                raise RuntimeError("intentional transaction failure")

        self.assertGreaterEqual(len(observed_transaction_states), 2)
        self.assertFalse(observed_transaction_states[0])
        self.assertFalse(observed_transaction_states[-1])

    def _candidate_source(
        self,
        store: legacy_runtime.RuntimeStore,
        task_id: str,
        repo_slug: str,
    ) -> tuple[str, dict[str, object]]:
        event: dict[str, object] = {
            "subject": f"hi.myrmidon.claude.ship.{repo_slug}.{task_id}",
            "payload": {"task_id": task_id, "repo_slug": repo_slug},
        }
        source_id = store.enqueue_outbox(
            task_id, event, purpose=f"candidate:{repo_slug}"
        )
        return source_id, event

    def _stage_source(
        self,
        store: legacy_runtime.RuntimeStore,
        task_id: str,
        repo_slug: str,
        subject: str,
        payload: object,
        *,
        purpose: str | None = None,
    ) -> str:
        purpose = purpose or f"route:{repo_slug}"
        message = {"subject": subject, "payload": payload}
        if purpose.startswith("stage:"):
            with store._transaction() as connection:
                return store._insert_outbox(
                    connection,
                    task_id,
                    message,
                    purpose,
                    requires_consumer_checkpoint=True,
                )
        return store.enqueue_outbox(task_id, message, purpose=purpose)

    def _claim_candidate(
        self,
        store: legacy_runtime.RuntimeStore,
        task_id: str,
        repo_slug: str,
        *,
        owner: str,
        lease_seconds: float,
    ) -> dict[str, object] | None:
        source_id, event = self._candidate_source(store, task_id, repo_slug)
        return store.claim_candidate(
            task_id,
            repo_slug,
            owner=owner,
            lease_seconds=lease_seconds,
            source_message_id=source_id,
            subject=event["subject"],
            payload=event["payload"],
        )

    def _record_ready_receipts(self, store: legacy_runtime.RuntimeStore) -> None:
        ready = {
            "subject": "hi.myrmidon.claude.ship-final.task-1",
            "payload": {"task_id": "task-1", "team_id": "team-1"},
        }
        store.record_receipt(
            "task-1", "keystone", {"merge_oid": "1" * 40}, ready_outbox=ready
        )
        store.record_receipt(
            "task-1", "hephaestus", {"merge_oid": "2" * 40}, ready_outbox=ready
        )

    def test_state_is_below_the_verified_git_common_directory(self) -> None:
        expected_common = Path(_git(self.root, "rev-parse", "--git-common-dir"))
        if not expected_common.is_absolute():
            expected_common = self.root / expected_common
        state = legacy_runtime.state_root(self.root)
        self.assertEqual(state.parent.resolve(), expected_common.resolve())
        self.assertTrue(state.is_dir())

        outside = Path(self.tempdir.name) / "not-a-repository"
        outside.mkdir()
        with self.assertRaises(legacy_runtime.StateLocationError):
            legacy_runtime.state_root(outside)

    def test_new_state_directory_is_fsynced_through_git_common_parent(self) -> None:
        raw_common = Path(_git(self.root, "rev-parse", "--git-common-dir"))
        common = raw_common if raw_common.is_absolute() else self.root / raw_common
        common_identity = (common.stat().st_dev, common.stat().st_ino)
        real_fsync = os.fsync
        fsynced: list[tuple[int, int]] = []

        def record_fsync(descriptor: int) -> None:
            info = os.fstat(descriptor)
            fsynced.append((info.st_dev, info.st_ino))
            real_fsync(descriptor)

        with patch.object(legacy_runtime.os, "fsync", side_effect=record_fsync):
            legacy_runtime.state_root(self.root)
            legacy_runtime.state_root(self.root)

        self.assertEqual(fsynced.count(common_identity), 2)

    def test_database_inode_and_parent_are_fsynced_before_store_opens(self) -> None:
        state = legacy_runtime.state_root(self.root)
        state_identity = (state.stat().st_dev, state.stat().st_ino)
        real_fsync = os.fsync
        fsynced_modes_and_ids: list[tuple[int, tuple[int, int]]] = []

        def record_fsync(descriptor: int) -> None:
            info = os.fstat(descriptor)
            fsynced_modes_and_ids.append(
                (stat.S_IFMT(info.st_mode), (info.st_dev, info.st_ino))
            )
            real_fsync(descriptor)

        with patch.object(legacy_runtime.os, "fsync", side_effect=record_fsync):
            store = self._store()

        database_identity = (store.database.stat().st_dev, store.database.stat().st_ino)
        database_sync = (stat.S_IFREG, database_identity)
        state_sync = (stat.S_IFDIR, state_identity)
        self.assertIn(database_sync, fsynced_modes_and_ids)
        self.assertIn(state_sync, fsynced_modes_and_ids)
        self.assertLess(
            fsynced_modes_and_ids.index(database_sync),
            fsynced_modes_and_ids.index(state_sync),
        )

    def test_baseexception_during_connection_binding_closes_every_descriptor(
        self,
    ) -> None:
        store = self._store()
        baseline = set(legacy_runtime._descriptor_snapshot())
        for exception in (KeyboardInterrupt(), SystemExit(74)):
            with self.subTest(exception=type(exception).__name__):
                observed: BaseException | None = None
                with patch.object(
                    legacy_runtime,
                    "_identify_sqlite_descriptor",
                    side_effect=exception,
                ):
                    try:
                        store._connect()
                    except BaseException as error:
                        observed = error
                self.assertIsInstance(observed, type(exception))
                self.assertEqual(set(legacy_runtime._descriptor_snapshot()), baseline)
                self.assertIsNone(store.load_task("not-persisted"))

    def test_baseexception_during_store_directory_binding_closes_descriptors(
        self,
    ) -> None:
        state = legacy_runtime.state_root(self.root)
        baseline = set(legacy_runtime._descriptor_snapshot())
        real_verify = legacy_runtime._BoundLockDirectory.verify
        calls = 0

        def interrupt_second_verify(binding) -> None:
            nonlocal calls
            calls += 1
            real_verify(binding)
            if calls == 2:
                raise KeyboardInterrupt()

        observed: BaseException | None = None
        with patch.object(
            legacy_runtime._BoundLockDirectory,
            "verify",
            interrupt_second_verify,
        ):
            try:
                legacy_runtime.RuntimeStore(
                    state / "interrupted.sqlite3",
                    self.repo,
                    self.registry_digest,
                    host_id="host-a",
                    service_uid=os.geteuid(),
                    message_retention_seconds=3600,
                    duplicate_window_seconds=120,
                    clock=time.time,
                )
            except BaseException as error:
                observed = error
        self.assertIsInstance(observed, KeyboardInterrupt)
        self.assertEqual(set(legacy_runtime._descriptor_snapshot()), baseline)

    def test_baseexception_while_retaining_sqlite_proof_closes_descriptor(
        self,
    ) -> None:
        store = self._store()
        baseline = set(legacy_runtime._descriptor_snapshot())
        observed: BaseException | None = None
        interrupted_descriptors: list[int] = []

        def interrupt_retention(descriptor: int, inheritable: bool) -> None:
            del inheritable
            interrupted_descriptors.append(descriptor)
            raise SystemExit(76)

        with patch.object(
            legacy_runtime.os,
            "set_inheritable",
            side_effect=interrupt_retention,
        ):
            try:
                store._connect()
            except BaseException as error:
                observed = error
        self.assertIsInstance(observed, SystemExit)
        self.assertEqual(len(interrupted_descriptors), 1)
        with self.assertRaises(OSError):
            os.fstat(interrupted_descriptors[0])
        self.assertEqual(set(legacy_runtime._descriptor_snapshot()), baseline)
        self.assertIsNone(store.load_task("not-persisted"))

    def test_baseexception_rolls_back_and_allows_transaction_reacquisition(self) -> None:
        store = self._store()
        for exception in (KeyboardInterrupt(), SystemExit(75)):
            with self.subTest(exception=type(exception).__name__):
                observed: BaseException | None = None
                try:
                    with store._transaction() as connection:
                        connection.execute(
                            "INSERT INTO tasks (namespace, task_id, team_id, "
                            "issue_number, task_digest, created_at) "
                            "VALUES (?, ?, ?, ?, ?, ?)",
                            (
                                store.namespace,
                                f"interrupted-{type(exception).__name__}",
                                "team-1",
                                1,
                                self.task_digest,
                                1.0,
                            ),
                        )
                        raise exception
                except BaseException as error:
                    observed = error
                self.assertIsInstance(observed, type(exception))
                self.assertIsNone(
                    store.load_task(f"interrupted-{type(exception).__name__}")
                )

    def test_database_symlink_is_rejected_instead_of_followed(self) -> None:
        state = legacy_runtime.state_root(self.root)
        outside = Path(self.tempdir.name) / "outside.sqlite3"
        outside.write_text("do not overwrite\n", encoding="utf-8")
        (state / "state.sqlite3").symlink_to(outside)
        with self.assertRaises(legacy_runtime.StateLocationError):
            self._store()
        self.assertEqual(outside.read_text(encoding="utf-8"), "do not overwrite\n")

    def test_hardlinked_database_is_rejected_without_chmodding_target(self) -> None:
        state = legacy_runtime.state_root(self.root)
        outside = Path(self.tempdir.name) / "unrelated.sqlite3"
        outside.write_text("do not chmod\n", encoding="utf-8")
        outside.chmod(0o644)
        os.link(outside, state / "state.sqlite3")

        with self.assertRaises(legacy_runtime.StateLocationError):
            self._store()

        self.assertEqual(outside.stat().st_mode & 0o777, 0o644)

    def test_open_connection_revalidates_database_entry_before_each_operation(self) -> None:
        store = self._store()
        connection = store._connect()
        database = store.database
        held_database = database.with_name("held.sqlite3")
        outside = Path(self.tempdir.name) / "outside.sqlite3"
        sqlite3.connect(outside).close()
        database.rename(held_database)
        database.symlink_to(outside)
        try:
            with self.assertRaises(legacy_runtime.StateLocationError):
                connection.execute("SELECT 1")
        finally:
            database.unlink()
            held_database.rename(database)
            connection.close()

    def test_sqlite_sidecar_symlink_is_rejected_before_open(self) -> None:
        store = self._store()
        outside = Path(self.tempdir.name) / "outside-sidecar"
        outside.write_text("do not overwrite\n", encoding="utf-8")
        sidecar = store.database.with_name(f"{store.database.name}-wal")
        if sidecar.exists() or sidecar.is_symlink():
            sidecar.unlink()
        sidecar.symlink_to(outside)

        with self.assertRaises(legacy_runtime.StateLocationError):
            store.load_task("missing-task")

        self.assertEqual(outside.read_text(encoding="utf-8"), "do not overwrite\n")

    def test_git_control_environment_cannot_redirect_the_state_root(self) -> None:
        other = Path(self.tempdir.name) / "other"
        _init_repo(other)
        expected = legacy_runtime.state_root(self.root)
        with patch.dict(
            os.environ,
            {
                "GIT_DIR": str(other / ".git"),
                "GIT_WORK_TREE": str(other),
                "GIT_COMMON_DIR": str(other / ".git"),
                "GIT_INDEX_FILE": str(other / ".git/index"),
            },
        ):
            self.assertEqual(legacy_runtime.state_root(self.root), expected)

    def test_database_inode_swap_during_connect_fails_closed(self) -> None:
        state = legacy_runtime.state_root(self.root)
        database = state / "state.sqlite3"
        outside = Path(self.tempdir.name) / "outside.sqlite3"
        sqlite3.connect(outside).close()
        real_connect = legacy_runtime.sqlite3.connect
        swapped = False

        def swap_then_connect(path, *args, **kwargs):
            nonlocal swapped
            if Path(path).name == database.name and not swapped:
                swapped = True
                if database.exists() or database.is_symlink():
                    database.unlink()
                database.symlink_to(outside)
            return real_connect(path, *args, **kwargs)

        with patch.object(
            legacy_runtime.sqlite3,
            "connect",
            side_effect=swap_then_connect,
        ), self.assertRaises(legacy_runtime.StateLocationError):
            self._store()

    def test_git_common_ancestor_replacement_cannot_receive_database_writes(
        self,
    ) -> None:
        state = legacy_runtime.state_root(self.root)
        common = state.parent
        held_common = common.with_name(f"{common.name}-held")
        replacement_state = common / state.name
        real_connect = legacy_runtime.sqlite3.connect
        swapped = False

        def replace_common_then_connect(path, *args, **kwargs):
            nonlocal swapped
            if not swapped:
                swapped = True
                common.rename(held_common)
                common.mkdir(mode=0o700)
                replacement_state.mkdir(mode=0o700)
            return real_connect(path, *args, **kwargs)

        with patch.object(
            legacy_runtime.sqlite3,
            "connect",
            side_effect=replace_common_then_connect,
        ), self.assertRaises(legacy_runtime.StateLocationError):
            self._store()

        self.assertTrue(swapped)
        self.assertEqual(list(replacement_state.iterdir()), [])

    def test_transient_database_swap_and_restore_during_connect_fails_closed(
        self,
    ) -> None:
        state = legacy_runtime.state_root(self.root)
        database = state / "state.sqlite3"
        held_database = state / "held.sqlite3"
        outside = Path(self.tempdir.name) / "outside.sqlite3"
        sqlite3.connect(outside).close()
        outside.chmod(0o600)
        real_connect = legacy_runtime.sqlite3.connect
        swapped = False

        def connect_swapped_inode(path, *args, **kwargs):
            nonlocal swapped
            if Path(path).name != database.name or swapped:
                return real_connect(path, *args, **kwargs)
            swapped = True
            database.rename(held_database)
            outside.rename(database)
            try:
                return real_connect(path, *args, **kwargs)
            finally:
                database.rename(outside)
                held_database.rename(database)

        with patch.object(
            legacy_runtime.sqlite3,
            "connect",
            side_effect=connect_swapped_inode,
        ), self.assertRaises(legacy_runtime.StateLocationError):
            self._store()

    def test_preexisting_sidecar_regular_inode_replacement_fails_closed(self) -> None:
        store = self._store()
        journal = store.database.with_name(f"{store.database.name}-journal")
        journal.touch(mode=0o600)
        # Retain the old inode until the replacement identity has been checked.
        self.addCleanup(os.close, os.open(journal, os.O_RDONLY))
        original_identity = (journal.stat().st_dev, journal.stat().st_ino)
        real_connect = legacy_runtime.sqlite3.connect
        replaced = False

        def replace_sidecar_then_connect(path, *args, **kwargs):
            nonlocal replaced
            if Path(path).name == store.database.name and not replaced:
                replaced = True
                journal.unlink()
                journal.touch(mode=0o600)
            return real_connect(path, *args, **kwargs)

        with patch.object(
            legacy_runtime.sqlite3,
            "connect",
            side_effect=replace_sidecar_then_connect,
        ), self.assertRaises(legacy_runtime.StateLocationError):
            store.load_task("missing-task")

        self.assertNotEqual(
            (journal.stat().st_dev, journal.stat().st_ino),
            original_identity,
        )

    def test_same_inode_sidecar_mutation_and_restore_fails_closed(self) -> None:
        store = self._store()
        connection = store._connect()
        sidecars = [
            store.database.with_name(f"{store.database.name}{suffix}")
            for suffix in ("-journal", "-wal", "-shm")
        ]
        sidecar = next(path for path in sidecars if path.exists())
        before = sidecar.stat()
        original = sidecar.read_bytes()
        sidecar.write_bytes(original + b"untrusted transient write")
        sidecar.write_bytes(original)
        os.utime(sidecar, ns=(before.st_atime_ns, before.st_mtime_ns))

        try:
            with self.assertRaises(legacy_runtime.StateLocationError):
                connection.execute("SELECT 1")
        finally:
            try:
                connection.close()
            except legacy_runtime.StateLocationError:
                pass

    def test_sidecar_mutation_between_execute_and_fetch_fails_closed(self) -> None:
        store = self._store()
        connection = store._connect()
        sidecar = next(
            store.database.with_name(f"{store.database.name}{suffix}")
            for suffix in ("-journal", "-wal", "-shm")
            if store.database.with_name(f"{store.database.name}{suffix}").exists()
        )
        cursor = connection.execute("SELECT 1")
        before = sidecar.stat()
        original = sidecar.read_bytes()
        sidecar.write_bytes(original + b"untrusted between cursor calls")
        sidecar.write_bytes(original)
        os.utime(sidecar, ns=(before.st_atime_ns, before.st_mtime_ns))
        try:
            with self.assertRaises(legacy_runtime.StateLocationError):
                cursor.fetchone()
        finally:
            try:
                connection.close()
            except legacy_runtime.StateLocationError:
                pass

    def test_new_sidecar_between_connection_operations_fails_closed(self) -> None:
        store = self._store()
        connection = store._connect()
        wal = store.database.with_name(f"{store.database.name}-wal")
        self.assertFalse(wal.exists())
        wal.touch(mode=0o600)
        try:
            with self.assertRaises(legacy_runtime.StateLocationError):
                connection.execute("SELECT 1")
        finally:
            try:
                connection.close()
            except legacy_runtime.StateLocationError:
                pass

    def test_route_json_requires_its_persisted_digest(self) -> None:
        store = self._store()
        self._record_plan(store)
        replacement = legacy_runtime._canonical_json(
            {"path": "elsewhere", "github_repo": "attacker/rebound"},
            "route",
        )
        raw = sqlite3.connect(store.database)
        try:
            raw.execute(
                "UPDATE routes SET route_json = ? WHERE namespace = ? "
                "AND task_id = ? AND repo_slug = ?",
                (replacement, store.namespace, "task-1", "keystone"),
            )
            raw.commit()
        finally:
            raw.close()

        with self.assertRaises(legacy_runtime.StateConflictError):
            store.load_task("task-1")

    def test_query_limits_and_active_task_admission_are_enforced(self) -> None:
        store = self._store()
        with self.assertRaises(ValueError):
            store.pending_outbox(limit=legacy_runtime._MAX_QUERY_ROWS + 1)
        with patch.object(legacy_runtime, "_MAX_ACTIVE_TASKS", 2, create=True):
            for index in range(2):
                store.record_plan(
                    f"task-cap-{index}",
                    "team-1",
                    index + 1,
                    self.routes,
                    self.task_digest,
                )
            with self.assertRaises(legacy_runtime.StateConflictError):
                store.record_plan(
                    "task-cap-2",
                    "team-1",
                    3,
                    self.routes,
                    self.task_digest,
                )

    def test_outbox_validation_paginates_without_stranding_valid_events(self) -> None:
        store = self._store()
        self._record_plan(store)
        with patch.object(legacy_runtime, "_MAX_QUERY_ROWS", 2):
            with store._transaction() as connection:
                for index in range(5):
                    store._insert_outbox(
                        connection,
                        "task-1",
                        {
                            "subject": f"test.page.{index}",
                            "payload": {"index": index},
                        },
                        f"page:{index}",
                    )

            claimed = store.claim_outbox(
                owner="publisher", lease_seconds=30, limit=1
            )

        self.assertEqual(len(claimed), 1)
        self.assertEqual(claimed[0]["purpose"], "page:0")

    def test_outbox_validation_checks_integrity_on_every_page(self) -> None:
        store = self._store()
        self._record_plan(store)
        with patch.object(legacy_runtime, "_MAX_QUERY_ROWS", 2):
            with store._transaction() as connection:
                for index in range(5):
                    store._insert_outbox(
                        connection,
                        "task-1",
                        {
                            "subject": f"test.integrity.{index}",
                            "payload": {"index": index},
                        },
                        f"integrity:{index}",
                    )
            with closing(sqlite3.connect(store.database)) as connection, connection:
                connection.execute(
                    "UPDATE outbox SET payload_digest = ? WHERE namespace = ? "
                    "AND task_id = ? AND purpose = ?",
                    ("0" * 64, store.namespace, "task-1", "integrity:4"),
                )

            with self.assertRaises(legacy_runtime.StateConflictError):
                store.claim_outbox(
                    owner="publisher", lease_seconds=30, limit=1
                )

    def test_outbox_admission_has_one_explicit_durable_bound(self) -> None:
        store = self._store()
        self._record_plan(store)
        with patch.object(legacy_runtime, "_MAX_STORED_OUTBOX", 2):
            for index in range(2):
                store.enqueue_outbox(
                    "task-1",
                    {
                        "subject": f"test.admission.{index}",
                        "payload": {"index": index},
                    },
                    purpose=f"admission:{index}",
                )
            with self.assertRaises(legacy_runtime.StateConflictError):
                store.enqueue_outbox(
                    "task-1",
                    {
                        "subject": "test.admission.2",
                        "payload": {"index": 2},
                    },
                    purpose="admission:2",
                )

        self.assertEqual(
            [event["purpose"] for event in store.pending_outbox()],
            ["admission:0", "admission:1"],
        )

    def test_outbox_admission_prunes_only_delivered_terminal_graphs(self) -> None:
        store = self._store()
        with patch.object(legacy_runtime, "_MAX_STORED_OUTBOX", 2), patch.object(
            legacy_runtime, "_MAX_TERMINAL_HISTORY", 10
        ):
            for index in range(2):
                task_id = f"budget-terminal-{index}"
                store.record_plan(
                    task_id,
                    "team-1",
                    index + 1,
                    {"keystone": self.routes["keystone"]},
                    self.task_digest,
                )
                store.terminate_task(
                    task_id,
                    status="failed",
                    terminal={"reason": task_id},
                    outbox=[
                        {
                            "subject": f"terminal.{task_id}",
                            "payload": {"task_id": task_id},
                        }
                    ],
                )
                claim = store.claim_outbox(
                    owner="publisher", lease_seconds=60, limit=1
                )[0]
                store.mark_outbox_sent(
                    claim["id"],
                    owner="publisher",
                    claim_token=claim["claim_token"],
                )

            store.record_plan(
                "budget-terminal-2",
                "team-1",
                3,
                {"keystone": self.routes["keystone"]},
                self.task_digest,
            )
            store.terminate_task(
                "budget-terminal-2",
                status="failed",
                terminal={"reason": "budget-terminal-2"},
                outbox=[
                    {
                        "subject": "terminal.budget-terminal-2",
                        "payload": {"task_id": "budget-terminal-2"},
                    }
                ],
            )

            self.assertIsNone(store.load_task("budget-terminal-0"))
            self.assertIsNotNone(store.load_task("budget-terminal-1"))
            self.assertIsNotNone(store.load_task("budget-terminal-2"))

    def test_outbox_admission_never_prunes_a_corrupt_terminal_graph(self) -> None:
        store = self._store()
        store.record_plan(
            "corrupt-terminal",
            "team-1",
            1,
            {"keystone": self.routes["keystone"]},
            self.task_digest,
        )
        store.terminate_task(
            "corrupt-terminal",
            status="failed",
            terminal={"reason": "corrupt-terminal"},
            outbox=[
                {
                    "subject": "terminal.corrupt-terminal",
                    "payload": {"task_id": "corrupt-terminal"},
                }
            ],
        )
        claim = store.claim_outbox(
            owner="publisher", lease_seconds=60, limit=1
        )[0]
        store.mark_outbox_sent(
            claim["id"],
            owner="publisher",
            claim_token=claim["claim_token"],
        )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "UPDATE outbox SET payload_digest = ? WHERE namespace = ? "
                "AND task_id = ?",
                ("0" * 64, store.namespace, "corrupt-terminal"),
            )
        store.record_plan(
            "new-active",
            "team-1",
            2,
            {"keystone": self.routes["keystone"]},
            self.task_digest,
        )

        with patch.object(legacy_runtime, "_MAX_STORED_OUTBOX", 1):
            with self.assertRaises(legacy_runtime.StateConflictError):
                store.enqueue_outbox(
                    "new-active",
                    {
                        "subject": "new-active.event",
                        "payload": {"task_id": "new-active"},
                    },
                    purpose="new-active:event",
                )

        with closing(sqlite3.connect(store.database)) as connection:
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM tasks WHERE namespace = ? "
                    "AND task_id = ?",
                    (store.namespace, "corrupt-terminal"),
                ).fetchone()[0],
                1,
            )

    def test_load_task_rejects_child_cardinality_above_route_bound(self) -> None:
        store = self._store()
        store.record_plan(
            "task-one-route",
            "team-1",
            22,
            {"keystone": self.routes["keystone"]},
            self.task_digest,
        )
        store.save_candidate(
            "task-one-route", "keystone", {"head_oid": "1" * 40}
        )
        candidate_json = legacy_runtime._canonical_json(
            {"head_oid": "2" * 40}, "candidate"
        )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "INSERT INTO candidates (namespace, task_id, repo_slug, "
                "candidate_json, candidate_digest, created_at) "
                "VALUES (?, ?, ?, ?, ?, ?)",
                (
                    store.namespace,
                    "task-one-route",
                    "unplanned",
                    candidate_json,
                    hashlib.sha256(candidate_json.encode()).hexdigest(),
                    1.0,
                ),
            )

        with patch.object(legacy_runtime, "_MAX_TASK_ROUTES", 1):
            with self.assertRaises(legacy_runtime.StateConflictError):
                store.load_task("task-one-route")

    def test_terminal_pruning_never_discards_unsent_outbox_state(self) -> None:
        store = self._store()
        with patch.object(legacy_runtime, "_MAX_TERMINAL_HISTORY", 1, create=True):
            for index in range(3):
                task_id = f"terminal-{index}"
                store.record_plan(
                    task_id,
                    "team-1",
                    index + 1,
                    self.routes,
                    self.task_digest,
                )
                store.terminate_task(
                    task_id,
                    status="failed",
                    terminal={"reason": task_id},
                    outbox=[
                        {
                            "subject": f"terminal.{task_id}",
                            "payload": {"task_id": task_id},
                        }
                    ],
                )
            claimed = store.claim_outbox(
                owner="publisher", lease_seconds=60, limit=2
            )
            for event in claimed:
                store.mark_outbox_sent(
                    event["id"],
                    owner="publisher",
                    claim_token=event["claim_token"],
                )

            reopened = self._store()
            self.assertIsNone(reopened.load_task("terminal-0"))
            self.assertIsNotNone(reopened.load_task("terminal-1"))
            self.assertIsNotNone(reopened.load_task("terminal-2"))
            self.assertEqual(
                [event["task_id"] for event in reopened.pending_outbox()],
                ["terminal-2"],
            )

    def test_terminal_history_is_pruned_after_delivery_without_reopen(self) -> None:
        store = self._store()
        with patch.object(legacy_runtime, "_MAX_TERMINAL_HISTORY", 1):
            for index in range(3):
                task_id = f"steady-terminal-{index}"
                store.record_plan(
                    task_id,
                    "team-1",
                    index + 1,
                    {"keystone": self.routes["keystone"]},
                    self.task_digest,
                )
                store.terminate_task(
                    task_id,
                    status="failed",
                    terminal={"reason": task_id},
                    outbox=[
                        {
                            "subject": f"terminal.{task_id}",
                            "payload": {"task_id": task_id},
                        }
                    ],
                )
                claim = store.claim_outbox(
                    owner="publisher", lease_seconds=60, limit=1
                )[0]
                store.mark_outbox_sent(
                    claim["id"],
                    owner="publisher",
                    claim_token=claim["claim_token"],
                )

            self.assertIsNone(store.load_task("steady-terminal-0"))
            self.assertIsNone(store.load_task("steady-terminal-1"))
            self.assertIsNotNone(store.load_task("steady-terminal-2"))

    def test_restart_restores_exact_plan_candidate_receipt_completion_and_outbox(self) -> None:
        first = self._store()
        self._record_plan(first)
        candidate = {
            "task_id": "task-1",
            "repo_slug": "keystone",
            "head_oid": "1" * 40,
        }
        first.save_candidate("task-1", "keystone", candidate)
        claimed = self._claim_candidate(
            first,
            "task-1", "keystone", owner="worker-1", lease_seconds=60
        )
        self.assertEqual(claimed["candidate"], candidate)
        first.record_receipt(
            "task-1",
            "keystone",
            {"url": "https://example.invalid/pr/1", "merge_oid": "2" * 40},
            owner="worker-1",
            claim_token=claimed["claim_token"],
            source_message_id=claimed["source_message_id"],
            source_subject=claimed["source_subject"],
            source_payload=claimed["source_payload"],
        )
        repeated_receipt = first.record_receipt(
            "task-1",
            "keystone",
            {"url": "https://example.invalid/pr/1", "merge_oid": "2" * 40},
            owner="worker-1",
            claim_token=claimed["claim_token"],
            source_message_id=claimed["source_message_id"],
            source_subject=claimed["source_subject"],
            source_payload=claimed["source_payload"],
        )
        self.assertFalse(repeated_receipt["ready"])
        first.record_receipt(
            "task-1",
            "hephaestus",
            {"url": "https://example.invalid/pr/2", "merge_oid": "3" * 40},
            ready_outbox={
                "subject": "hi.myrmidon.claude.ship-final.task-1",
                "payload": {"task_id": "task-1", "team_id": "team-1"},
            },
        )
        first.complete_task(
            "task-1",
            {"status": "completed", "result": "https://example.invalid/pr/3"},
            outbox=(
                {
                    "subject": "hi.tasks.team-1.task-1.completed",
                    "payload": {
                        "event": "task.completed",
                        "data": {"task_id": "task-1", "team_id": "team-1"},
                    },
                },
            ),
        )

        restarted = self._store()
        task = restarted.load_task("task-1")
        self.assertEqual(task["team_id"], "team-1")
        self.assertEqual(task["issue_number"], 22)
        self.assertEqual(task["task_digest"], self.task_digest)
        self.assertEqual(task["routes"], self.routes)
        self.assertEqual(task["candidates"]["keystone"], candidate)
        self.assertEqual(set(task["receipts"]), {"keystone", "hephaestus"})
        self.assertEqual(task["completion"]["status"], "completed")
        self.assertEqual(
            [event["purpose"] for event in restarted.pending_outbox()],
            ["completion:0"],
        )
        self.assertEqual(restarted.reconcile()["pending_outbox"], restarted.pending_outbox())

    def test_exact_bindings_are_idempotent_but_conflicting_redelivery_fails_closed(self) -> None:
        store = self._store()
        self._record_plan(store)
        self._record_plan(store)

        changed_routes = dict(self.routes)
        changed_routes["keystone"] = {
            **changed_routes["keystone"],
            "github_repo": "attacker/redirected",
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan(
                "task-1", "team-1", 22, changed_routes, self.task_digest
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan(
                "task-1", "other-team", 22, self.routes, self.task_digest
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan(
                "task-1", "team-1", 23, self.routes, self.task_digest
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan(
                "task-1", "team-1", 22, self.routes, "c" * 64
            )

        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.save_candidate("task-1", "keystone", {"head_oid": "2" * 40})

    def test_partial_or_tampered_sqlite_state_fails_closed(self) -> None:
        store = self._store()
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        with closing(sqlite3.connect(store.database)) as connection:
            connection.execute(
                "UPDATE candidates SET candidate_json = ? WHERE task_id = ?",
                ('{"head_oid":"tampered"}', "task-1"),
            )
            connection.commit()
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.load_task("task-1")

        with closing(sqlite3.connect(store.database)) as connection:
            connection.execute("DELETE FROM candidates")
            connection.execute("DELETE FROM routes")
            connection.commit()
        with self.assertRaises(legacy_runtime.StateConflictError):
            self._record_plan(store)

    def test_claim_verifies_candidate_digest_and_mapping_schema(self) -> None:
        store = self._store()
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        with closing(sqlite3.connect(store.database)) as connection:
            connection.execute(
                "UPDATE candidates SET candidate_json = ? WHERE task_id = ?",
                ('{"head_oid":"tampered"}', "task-1"),
            )
            connection.commit()
        with self.assertRaises(legacy_runtime.StateConflictError):
            self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker-1", lease_seconds=30
            )

        invalid = "[]"
        with closing(sqlite3.connect(store.database)) as connection:
            connection.execute(
                "UPDATE candidates SET candidate_json = ?, candidate_digest = ? "
                "WHERE task_id = ?",
                (invalid, hashlib.sha256(invalid.encode()).hexdigest(), "task-1"),
            )
            connection.commit()
        with self.assertRaises(legacy_runtime.StateConflictError):
            self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker-1", lease_seconds=30
            )

    def test_outbox_cannot_override_the_trusted_purpose(self) -> None:
        store = self._store()
        self._record_plan(store)
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.enqueue_outbox(
                "task-1",
                {
                    "purpose": "attacker-selected-key",
                    "subject": "hi.tasks.team-1.task-1.progress",
                    "payload": {"task_id": "task-1"},
                },
                purpose="trusted-progress",
            )

    def test_claim_is_non_destructive_and_recovers_after_expiry(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        candidate = {"head_oid": "1" * 40}
        store.save_candidate("task-1", "keystone", candidate)

        first_claim = self._claim_candidate(
            store,
            "task-1", "keystone", owner="worker-1", lease_seconds=10
        )
        self.assertEqual(first_claim["candidate"], candidate)
        self.assertIsNone(
            self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker-2", lease_seconds=10
            )
        )
        self.assertEqual(store.load_task("task-1")["candidates"]["keystone"], candidate)

        now[0] = 1011.0
        second_claim = self._claim_candidate(
            store,
            "task-1", "keystone", owner="worker-2", lease_seconds=10
        )
        self.assertEqual(second_claim["candidate"], candidate)
        self.assertNotEqual(first_claim["claim_token"], second_claim["claim_token"])
        self.assertTrue(
            store.renew_claim(
                "task-1",
                "keystone",
                owner="worker-2",
                claim_token=second_claim["claim_token"],
                lease_seconds=20,
            )
        )
        now[0] = 1025.0
        self.assertIsNone(
            self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker-3", lease_seconds=10
            )
        )
        now[0] = 1032.0
        third_claim = self._claim_candidate(
            store,
            "task-1", "keystone", owner="worker-3", lease_seconds=10
        )
        self.assertEqual(third_claim["candidate"], candidate)
        self.assertFalse(
            store.release_claim(
                "task-1",
                "keystone",
                owner="worker-1",
                claim_token=first_claim["claim_token"],
            )
        )
        self.assertFalse(
            store.release_claim(
                "task-1",
                "keystone",
                owner="worker-2",
                claim_token=second_claim["claim_token"],
            )
        )
        self.assertTrue(
            store.release_claim(
                "task-1",
                "keystone",
                owner="worker-3",
                claim_token=third_claim["claim_token"],
            )
        )

    def test_reopened_store_respects_live_candidate_and_stage_leases(self) -> None:
        now = [1000.0]

        def open_store() -> legacy_runtime.RuntimeStore:
            return legacy_runtime.runtime_store(
                self.root,
                self.repo,
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
                clock=lambda: now[0],
            )

        first_store = open_store()
        first_store.record_plan(
            "task-restart-claim",
            "team-1",
            22,
            {"keystone": self.routes["keystone"]},
            "f" * 64,
        )
        first_store.save_candidate(
            "task-restart-claim", "keystone", {"head_oid": "1" * 40}
        )
        candidate_source, candidate_event = self._candidate_source(
            first_store, "task-restart-claim", "keystone"
        )
        candidate_claim = first_store.claim_candidate(
            "task-restart-claim",
            "keystone",
            owner="first-candidate-worker",
            lease_seconds=300,
            source_message_id=candidate_source,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        stage_subject = "hi.myrmidon.claude.test.task-restart-claim"
        stage_payload = {"task_id": "task-restart-claim", "iteration": 1}
        stage_source = self._stage_source(
            first_store,
            "task-restart-claim",
            "keystone",
            stage_subject,
            stage_payload,
        )
        stage_event_id = legacy_runtime.stable_event_id(
            stage_subject,
            stream="homeric-myrmidon",
            message_id=stage_source,
        )
        stage_claim = first_store.claim_stage(
            "task-restart-claim",
            "keystone",
            "test",
            1,
            source_event_id=stage_event_id,
            source_message_id=stage_source,
            subject=stage_subject,
            payload=stage_payload,
            owner="first-stage-worker",
            lease_seconds=300,
        )

        restarted = open_store()
        self.assertIsNone(
            restarted.claim_candidate(
                "task-restart-claim",
                "keystone",
                owner="second-candidate-worker",
                lease_seconds=300,
                source_message_id=candidate_source,
                subject=candidate_event["subject"],
                payload=candidate_event["payload"],
            )
        )
        self.assertIsNone(
            restarted.claim_stage(
                "task-restart-claim",
                "keystone",
                "test",
                1,
                source_event_id=stage_event_id,
                source_message_id=stage_source,
                subject=stage_subject,
                payload=stage_payload,
                owner="second-stage-worker",
                lease_seconds=300,
            )
        )
        now[0] = 1301.0
        replacement_candidate = restarted.claim_candidate(
            "task-restart-claim",
            "keystone",
            owner="second-candidate-worker",
            lease_seconds=300,
            source_message_id=candidate_source,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        replacement_stage = restarted.claim_stage(
            "task-restart-claim",
            "keystone",
            "test",
            1,
            source_event_id=stage_event_id,
            source_message_id=stage_source,
            subject=stage_subject,
            payload=stage_payload,
            owner="second-stage-worker",
            lease_seconds=300,
        )
        self.assertNotEqual(
            candidate_claim["claim_token"], replacement_candidate["claim_token"]
        )
        self.assertNotEqual(
            stage_claim["claim_token"], replacement_stage["claim_token"]
        )

    def test_candidate_renewal_fails_closed_when_its_source_is_lost(self) -> None:
        store = self._store()
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        claim = self._claim_candidate(
            store,
            "task-1",
            "keystone",
            owner="worker-1",
            lease_seconds=30,
        )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "DELETE FROM outbox WHERE namespace = ? AND outbox_id = ?",
                (store.namespace, claim["source_message_id"]),
            )

        with self.assertRaises(legacy_runtime.StateConflictError):
            store.renew_claim(
                "task-1",
                "keystone",
                owner="worker-1",
                claim_token=claim["claim_token"],
                lease_seconds=30,
            )

    def test_non_finite_candidate_lease_expiration_is_rejected(self) -> None:
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: 1e308,
        )
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        with self.assertRaises(ValueError):
            self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker-1", lease_seconds=1e308
            )

    def test_lease_clock_is_read_after_waiting_for_the_sqlite_write_lock(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        candidate = {"head_oid": "1" * 40}
        store.save_candidate("task-1", "keystone", candidate)

        def run_while_locked(operation, advanced_time):
            entered_clock = threading.Event()
            release_clock = threading.Event()

            def controlled_clock():
                captured = now[0]
                entered_clock.set()
                release_clock.wait(3)
                return captured

            store._clock = controlled_clock
            blocker = sqlite3.connect(store.database, timeout=3)
            blocker.execute("BEGIN IMMEDIATE")
            with ThreadPoolExecutor(max_workers=1) as executor:
                future = executor.submit(operation)
                entered_clock.wait(0.2)
                now[0] = advanced_time
                blocker.rollback()
                blocker.close()
                release_clock.set()
                return future

        future = run_while_locked(
            lambda: self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker-1", lease_seconds=10
            ),
            1010.0,
        )
        first_claim = future.result(timeout=3)
        self.assertEqual(first_claim["candidate"], candidate)
        store._clock = lambda: now[0]
        self.assertEqual(
            store.load_task("task-1")["claims"]["keystone"]["expires_at"],
            1020.0,
        )

        future = run_while_locked(
            lambda: store.renew_claim(
                "task-1",
                "keystone",
                owner="worker-1",
                claim_token=first_claim["claim_token"],
                lease_seconds=20,
            ),
            1015.0,
        )
        self.assertTrue(future.result(timeout=3))
        store._clock = lambda: now[0]
        self.assertEqual(
            store.load_task("task-1")["claims"]["keystone"]["expires_at"],
            1035.0,
        )

        future = run_while_locked(
            lambda: store.record_receipt(
                "task-1",
                "keystone",
                {"merge_oid": "2" * 40},
                owner="worker-1",
                claim_token=first_claim["claim_token"],
                source_message_id=first_claim["source_message_id"],
                source_subject=first_claim["source_subject"],
                source_payload=first_claim["source_payload"],
            ),
            1036.0,
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            future.result(timeout=3)

    def test_runtime_cannot_be_rebound_or_claimed_from_another_host(self) -> None:
        store = self._store(host_id="host-a")
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        with self.assertRaises(legacy_runtime.HostBindingError):
            self._store(host_id="host-b")

    def test_registry_change_cannot_hide_unfinished_state(self) -> None:
        store = self._store()
        self._record_plan(store)
        with self.assertRaises(legacy_runtime.StateConflictError):
            legacy_runtime.runtime_store(
                self.root,
                self.repo,
                "d" * 64,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )

    def test_candidate_uid_boundary_is_durable_and_denies_state_access(self) -> None:
        store = self._store()
        alternate_candidate_uid = (
            65532 if _TEST_CANDIDATE_UID != 65532 else 65531
        )
        with patch.dict(
            os.environ,
            {"HOMERIC_LEGACY_CANDIDATE_UID": str(alternate_candidate_uid)},
        ), self.assertRaises(legacy_runtime.HostBindingError):
            legacy_runtime.runtime_store(
                self.root,
                self.repo,
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )

        if os.geteuid() != 0:
            self.fail(
                "the Linux candidate DAC proof requires a root-owned CI fixture"
            )
        # Make unrelated fixture ancestors traversable so the denial is
        # specifically provided by the runtime's 0700 state authority.
        for path in (Path(self.tempdir.name), self.root, self.root / ".git"):
            path.chmod(0o755)
        state_directory = store.database.parent
        result = subprocess.run(
            [
                sys.executable,
                "-c",
                (
                    "import os,sys\n"
                    "state, database = sys.argv[1:]\n"
                    "paths = [database, database + '-journal', "
                    "database + '-wal', database + '-shm']\n"
                    "for path in paths:\n"
                    "    try:\n"
                    "        fd = os.open(path, os.O_RDONLY)\n"
                    "    except PermissionError:\n"
                    "        pass\n"
                    "    else:\n"
                    "        os.close(fd)\n"
                    "        raise SystemExit(10)\n"
                    "try:\n"
                    "    os.listdir(state)\n"
                    "except PermissionError:\n"
                    "    pass\n"
                    "else:\n"
                    "    raise SystemExit(11)\n"
                    "try:\n"
                    "    os.rename(state, state + '-candidate')\n"
                    "except PermissionError:\n"
                    "    pass\n"
                    "else:\n"
                    "    raise SystemExit(12)\n"
                ),
                str(state_directory),
                str(store.database),
            ],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            close_fds=True,
            user=_TEST_CANDIDATE_UID,
            group=_TEST_CANDIDATE_UID,
            extra_groups=(),
        )
        self.assertEqual(
            result.returncode,
            0,
            result.stderr.decode("utf-8", errors="replace"),
        )

    def test_candidate_writable_state_parent_is_rejected_before_database_open(
        self,
    ) -> None:
        root = Path(self.tempdir.name) / "candidate-writable-parent"
        _init_repo(root)
        git_directory = root / ".git"
        git_directory.chmod(0o777)

        with self.assertRaises(legacy_runtime.StateLocationError):
            legacy_runtime.runtime_store(
                root,
                f"{self.repo}:candidate-writable-parent",
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )

        self.assertFalse(
            (git_directory / legacy_runtime._STATE_DIRECTORY).exists()
        )

    def test_direct_store_rejects_candidate_writable_namespace_parent(self) -> None:
        unsafe_parent = Path(self.tempdir.name) / "unsafe-direct-parent"
        unsafe_parent.mkdir(mode=0o700)
        state = unsafe_parent / "state"
        state.mkdir(mode=0o700)
        unsafe_parent.chmod(0o777)

        with self.assertRaises(legacy_runtime.StateLocationError):
            legacy_runtime.RuntimeStore(
                state / "direct.sqlite3",
                f"{self.repo}:unsafe-direct-parent",
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
                clock=time.time,
            )

        self.assertFalse((state / "direct.sqlite3").exists())

    def test_open_store_rechecks_the_candidate_dac_parent(self) -> None:
        store = self._store()
        parent = store.database.parent.parent
        original_mode = parent.stat().st_mode & 0o777
        parent.chmod(0o777)
        try:
            with self.assertRaises(legacy_runtime.StateLocationError):
                store.load_task("missing-task")
        finally:
            parent.chmod(original_mode)

    def test_invalid_candidate_identity_creates_no_state_namespace(self) -> None:
        root = Path(self.tempdir.name) / "invalid-candidate-identity"
        _init_repo(root)
        state = root / ".git" / legacy_runtime._STATE_DIRECTORY

        with patch.dict(
            os.environ,
            {"HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid())},
            clear=True,
        ), self.assertRaises(legacy_runtime.HostBindingError):
            legacy_runtime.runtime_store(
                root,
                f"{self.repo}:invalid-candidate-identity",
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )

        self.assertFalse(state.exists())

    def test_receipt_fan_in_and_outbox_are_atomic_and_idempotent(self) -> None:
        store = self._store()
        self._record_plan(store)
        ready = {
            "subject": "hi.myrmidon.claude.ship-final.task-1",
            "payload": {"task_id": "task-1", "team_id": "team-1"},
        }
        first = store.record_receipt(
            "task-1", "keystone", {"merge_oid": "1" * 40}, ready_outbox=ready
        )
        self.assertFalse(first["ready"])
        self.assertEqual(store.pending_outbox(), [])

        complete = store.record_receipt(
            "task-1", "hephaestus", {"merge_oid": "2" * 40}, ready_outbox=ready
        )
        self.assertTrue(complete["ready"])
        self.assertEqual(complete["expected_repos"], ["hephaestus", "keystone"])
        self.assertEqual(complete["received_repos"], ["hephaestus", "keystone"])
        pending = store.pending_outbox()
        self.assertEqual(len(pending), 1)
        outbox_id = pending[0]["id"]

        repeated = store.record_receipt(
            "task-1", "hephaestus", {"merge_oid": "2" * 40}, ready_outbox=ready
        )
        self.assertTrue(repeated["ready"])
        self.assertEqual(store.pending_outbox()[0]["id"], outbox_id)
        self.assertEqual(len(store.pending_outbox()), 1)

        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_receipt(
                "task-1", "hephaestus", {"merge_oid": "9" * 40}, ready_outbox=ready
            )

        claimed = store.claim_outbox(owner="publisher-1", lease_seconds=30)
        self.assertEqual([item["id"] for item in claimed], [outbox_id])
        claim_token = claimed[0]["claim_token"]
        self.assertTrue(
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-1",
                claim_token=claim_token,
            )
        )
        self.assertFalse(
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-1",
                claim_token=claim_token,
            )
        )
        self.assertEqual(store.pending_outbox(), [])

    def test_completion_requires_fan_in_and_freezes_late_state(self) -> None:
        store = self._store()
        self._record_plan(store)
        completion_event = {
            "subject": "hi.tasks.team-1.task-1.completed",
            "payload": {"task_id": "task-1", "status": "completed"},
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.complete_task(
                "task-1",
                {"status": "completed"},
                outbox=(completion_event,),
            )

        self._record_ready_receipts(store)
        store.complete_task(
            "task-1", {"status": "completed"}, outbox=(completion_event,)
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.save_candidate(
                "task-1", "hephaestus", {"head_oid": "3" * 40}
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.enqueue_outbox(
                "task-1",
                {
                    "subject": "hi.tasks.team-1.task-1.late",
                    "payload": {"task_id": "task-1"},
                },
                purpose="late-event",
            )

    def test_completion_redelivery_binds_the_exact_outbox_event_set(self) -> None:
        store = self._store()
        self._record_plan(store)
        self._record_ready_receipts(store)
        completion = {"status": "completed", "head_revision": "4" * 40}
        event = {
            "subject": "hi.tasks.team-1.task-1.completed",
            "payload": {"task_id": "task-1", "status": "completed"},
        }
        store.complete_task("task-1", completion, outbox=(event,))
        store.complete_task("task-1", completion, outbox=(event,))
        before = store.pending_outbox()
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.complete_task(
                "task-1",
                completion,
                outbox=(
                    event,
                    {
                        "subject": "hi.tasks.team-1.task-1.extra",
                        "payload": {"task_id": "task-1", "unexpected": True},
                    },
                ),
            )
        self.assertEqual(store.pending_outbox(), before)

    def test_outbox_claim_renews_expires_and_recovers_without_deletion(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        outbox_id = store.enqueue_outbox(
            "task-1",
            {
                "subject": "hi.tasks.team-1.task-1.progress",
                "payload": {"task_id": "task-1"},
            },
            purpose="progress",
        )
        claimed = store.claim_outbox(
            owner="publisher-1", lease_seconds=10, limit=1
        )
        self.assertEqual([item["id"] for item in claimed], [outbox_id])
        first_token = claimed[0]["claim_token"]
        self.assertEqual(claimed[0]["claim_generation"], 1)
        self.assertEqual(
            store.claim_outbox(owner="publisher-1", lease_seconds=10, limit=1), []
        )
        self.assertEqual(
            store.claim_outbox(owner="publisher-2", lease_seconds=10, limit=1), []
        )
        self.assertTrue(
            store.renew_outbox_claim(
                outbox_id,
                owner="publisher-1",
                claim_token=first_token,
                lease_seconds=20,
            )
        )
        now[0] = 1015.0
        self.assertEqual(
            store.claim_outbox(owner="publisher-2", lease_seconds=10, limit=1), []
        )
        self.assertTrue(
            store.release_outbox_claim(
                outbox_id,
                owner="publisher-1",
                claim_token=first_token,
            )
        )
        second_claim = store.claim_outbox(
            owner="publisher-2", lease_seconds=10, limit=1
        )
        self.assertEqual([item["id"] for item in second_claim], [outbox_id])
        second_token = second_claim[0]["claim_token"]
        self.assertNotEqual(second_token, first_token)
        self.assertEqual(second_claim[0]["claim_generation"], 2)
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-1",
                claim_token=first_token,
            )
        now[0] = 1026.0
        third_claim = store.claim_outbox(
            owner="publisher-3", lease_seconds=10, limit=1
        )
        self.assertEqual([item["id"] for item in third_claim], [outbox_id])
        third_token = third_claim[0]["claim_token"]
        self.assertNotIn(third_token, {first_token, second_token})
        self.assertEqual(third_claim[0]["claim_generation"], 3)
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-2",
                claim_token=second_token,
            )
        self.assertTrue(
            store.record_outbox_attempt(
                outbox_id,
                owner="publisher-3",
                claim_token=third_token,
            )
        )
        self.assertTrue(
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-3",
                claim_token=third_token,
            )
        )
        self.assertFalse(
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-3",
                claim_token=third_token,
            )
        )

    def test_two_publishers_cannot_claim_the_same_outbox_event(self) -> None:
        first = self._store()
        self._record_plan(first)
        outbox_id = first.enqueue_outbox(
            "task-1",
            {
                "subject": "hi.tasks.team-1.task-1.progress",
                "payload": {"task_id": "task-1"},
            },
            purpose="progress",
        )
        second = self._store()
        barrier = threading.Barrier(2)

        def claim(store, owner):
            barrier.wait(timeout=3)
            return store.claim_outbox(owner=owner, lease_seconds=30, limit=1)

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(
                executor.map(
                    lambda pair: claim(*pair),
                    ((first, "publisher-1"), (second, "publisher-2")),
                )
            )
        claimed_ids = [item["id"] for result in results for item in result]
        self.assertEqual(claimed_ids, [outbox_id])

    def test_same_owner_publishers_receive_only_one_fenced_claim(self) -> None:
        first = self._store()
        self._record_plan(first)
        outbox_id = first.enqueue_outbox(
            "task-1",
            {
                "subject": "hi.tasks.team-1.task-1.progress",
                "payload": {"task_id": "task-1"},
            },
            purpose="progress",
        )
        second = self._store()
        barrier = threading.Barrier(2)

        def claim(store):
            barrier.wait(timeout=3)
            return store.claim_outbox(
                owner="stable-publisher", lease_seconds=30, limit=1
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            results = list(executor.map(claim, (first, second)))

        claimed = [item for result in results for item in result]
        self.assertEqual([item["id"] for item in claimed], [outbox_id])
        self.assertEqual(len({item["claim_token"] for item in claimed}), 1)

    def test_stable_event_ids_require_durable_broker_identity(self) -> None:
        by_message_id = legacy_runtime.stable_event_id(
            "hi.myrmidon.claude.test.task-1",
            stream="homeric-myrmidon",
            message_id="durable-outbox-id",
        )
        self.assertEqual(
            by_message_id,
            legacy_runtime.stable_event_id(
                "hi.myrmidon.claude.test.task-1",
                stream="homeric-myrmidon",
                message_id="durable-outbox-id",
            ),
        )
        self.assertNotEqual(
            by_message_id,
            legacy_runtime.stable_event_id(
                "hi.myrmidon.claude.test.task-1",
                stream="homeric-myrmidon",
                message_id="other-outbox-id",
            ),
        )
        self.assertEqual(
            by_message_id,
            legacy_runtime.stable_event_id(
                "hi.myrmidon.claude.review.task-1",
                stream="homeric-myrmidon",
                message_id="durable-outbox-id",
            ),
            "one producer ID must not become two events by changing the subject",
        )
        by_sequence = legacy_runtime.stable_event_id(
            "hi.myrmidon.claude.plan.task-1",
            stream="homeric-myrmidon",
            stream_sequence=41,
        )
        self.assertEqual(
            by_sequence,
            legacy_runtime.stable_event_id(
                "hi.myrmidon.claude.plan.task-1",
                stream="homeric-myrmidon",
                stream_sequence=41,
            ),
        )
        with self.assertRaises(ValueError):
            legacy_runtime.stable_event_id(
                "hi.myrmidon.claude.plan.task-1",
                stream="homeric-myrmidon",
            )
        with self.assertRaises(ValueError):
            legacy_runtime.stable_event_id(
                "hi.myrmidon.claude.plan.task-1",
                stream="homeric-myrmidon",
                message_id="one",
                stream_sequence=1,
            )

    def test_stage_checkpoint_and_outbox_are_atomic_and_deduplicate_redelivery(
        self,
    ) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        subject = "hi.myrmidon.claude.test.task-1"
        payload = {"task_id": "task-1", "iteration": 1, "plan": "trusted? no"}
        source_message_id = store.enqueue_outbox(
            "task-1",
            {"subject": subject, "payload": payload},
            purpose="route:keystone",
            requires_consumer_checkpoint=True,
        )
        event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-myrmidon",
            message_id=source_message_id,
        )
        claim = store.claim_stage(
            "task-1",
            "keystone",
            "test",
            1,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="worker-1",
            lease_seconds=30,
            source_message_id=source_message_id,
        )
        self.assertEqual(claim["state"], "claimed")
        self.assertEqual(claim["claim_generation"], 1)
        self.assertIsNone(
            store.claim_stage(
                "task-1",
                "keystone",
                "test",
                1,
                source_event_id=event_id,
                subject=subject,
                payload=payload,
                owner="worker-2",
                lease_seconds=30,
                source_message_id=source_message_id,
            )
        )

        output = {
            "subject": "hi.myrmidon.claude.implement.task-1",
            "payload": {**payload, "test_script": "#!/bin/sh\nexit 0\n"},
        }
        checkpoint = {"test_script": "#!/bin/sh\nexit 0\n"}
        completed = store.complete_stage(
            "task-1",
            "keystone",
            "test",
            1,
            owner="worker-1",
            claim_token=claim["claim_token"],
            result=checkpoint,
            output=output,
        )
        self.assertEqual(completed["state"], "succeeded")
        self.assertEqual(completed["result"], checkpoint)
        self.assertEqual(store.pending_outbox()[0]["id"], completed["outbox_id"])

        restarted = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        redelivery = restarted.claim_stage(
            "task-1",
            "keystone",
            "test",
            1,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="worker-2",
            lease_seconds=30,
            source_message_id=source_message_id,
        )
        self.assertEqual(redelivery, completed)
        self.assertEqual(len(restarted.pending_outbox()), 1)

        with self.assertRaises(legacy_runtime.StateConflictError):
            restarted.claim_stage(
                "task-1",
                "keystone",
                "test",
                1,
                source_event_id=event_id,
                subject=subject,
                payload={**payload, "iteration": 2},
                owner="worker-2",
                lease_seconds=30,
                source_message_id=source_message_id,
            )

    def test_consumer_checkpoint_survives_producer_crash_after_broker_ack(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        output = {
            "subject": "hi.myrmidon.claude.implement.task-1",
            "payload": {"task_id": "task-1", "iteration": 1},
        }
        producer_id = self._stage_source(
            store,
            "task-1",
            "keystone",
            output["subject"],
            output["payload"],
            purpose="stage:keystone:test:1",
        )
        producer_claim = store.claim_outbox(
            owner="publisher-1", lease_seconds=10
        )[0]
        store.record_outbox_attempt(
            producer_id,
            owner="publisher-1",
            claim_token=producer_claim["claim_token"],
        )

        # The broker ACK occurred, but the producer crashed before mark_outbox_sent.
        # The consumer's durable checkpoint, not the broker duplicate window, is
        # the correctness boundary for a later replay.
        event_id = legacy_runtime.stable_event_id(
            output["subject"],
            stream="homeric-myrmidon",
            message_id=producer_id,
        )
        consumer_claim = store.claim_stage(
            "task-1",
            "keystone",
            "implement",
            1,
            source_event_id=event_id,
            subject=output["subject"],
            payload=output["payload"],
            owner="worker-1",
            lease_seconds=30,
            source_message_id=producer_id,
        )
        store.complete_stage(
            "task-1",
            "keystone",
            "implement",
            1,
            owner="worker-1",
            claim_token=consumer_claim["claim_token"],
            result={"implementation_summary": "done"},
            output={
                "subject": "hi.myrmidon.claude.review.task-1",
                "payload": {"task_id": "task-1", "iteration": 1},
            },
        )

        self.assertNotIn(producer_id, {item["id"] for item in store.pending_outbox()})
        self.assertFalse(
            store.mark_outbox_sent(
                producer_id,
                owner="publisher-1",
                claim_token=producer_claim["claim_token"],
            )
        )
        self.assertFalse(
            store.release_outbox_claim(
                producer_id,
                owner="publisher-1",
                claim_token=producer_claim["claim_token"],
            )
        )
        duplicate = store.claim_stage(
            "task-1",
            "keystone",
            "implement",
            1,
            source_event_id=event_id,
            subject=output["subject"],
            payload=output["payload"],
            owner="worker-2",
            lease_seconds=30,
            source_message_id=producer_id,
        )
        self.assertEqual(duplicate["state"], "succeeded")
        self.assertEqual(duplicate["result"], {"implementation_summary": "done"})

    def test_stage_preflight_returns_persisted_intent_for_exact_redelivery(
        self,
    ) -> None:
        store = self._store()
        self._record_plan(store)
        subject = "hi.myrmidon.claude.review.task-1"
        payload = {"task_id": "task-1", "iteration": 1}
        intent = {
            "base_oid": "1" * 40,
            "expected_tree_oid": "2" * 40,
        }
        source_id = self._stage_source(
            store,
            "task-1",
            "keystone",
            subject,
            payload,
            purpose="stage:keystone:implement:1",
        )
        event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-myrmidon",
            message_id=source_id,
        )
        claim = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            1,
            source_event_id=event_id,
            source_message_id=source_id,
            subject=subject,
            payload=payload,
            intent=intent,
            owner="reviewer",
            lease_seconds=30,
        )
        completed = store.complete_stage(
            "task-1",
            "keystone",
            "review",
            1,
            owner="reviewer",
            claim_token=claim["claim_token"],
            result={"verdict": "NOGO"},
            output={
                "subject": "hi.myrmidon.claude.test.task-1",
                "payload": {"task_id": "task-1", "iteration": 2},
            },
        )

        inspected = store.inspect_stage(
            "task-1",
            "keystone",
            "review",
            1,
            source_event_id=event_id,
            source_message_id=source_id,
            subject=subject,
            payload=payload,
        )
        self.assertEqual(inspected["state"], "succeeded")
        self.assertEqual(inspected["intent"], intent)
        self.assertEqual(inspected["result"], completed["result"])
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.inspect_stage(
                "task-1",
                "keystone",
                "review",
                1,
                source_event_id=event_id,
                source_message_id=source_id,
                subject=subject,
                payload={**payload, "iteration": 2},
            )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "UPDATE outbox SET consumer_checkpointed_at = NULL "
                "WHERE namespace = ? AND outbox_id = ?",
                (store.namespace, source_id),
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.inspect_stage(
                "task-1",
                "keystone",
                "review",
                1,
                source_event_id=event_id,
                source_message_id=source_id,
                subject=subject,
                payload=payload,
            )

    def test_stage_claims_are_fenced_renewable_and_recoverable_after_retention(
        self,
    ) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        subject = "hi.myrmidon.claude.review.task-1"
        payload = {"task_id": "task-1", "iteration": 1}
        source_id = self._stage_source(
            store,
            "task-1",
            "keystone",
            subject,
            payload,
            purpose="stage:keystone:implement:1",
        )
        event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-myrmidon",
            message_id=source_id,
        )
        first = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            1,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="stable-worker",
            lease_seconds=30,
            source_message_id=source_id,
        )
        self.assertTrue(
            store.renew_stage_claim(
                "task-1",
                "keystone",
                "review",
                1,
                owner="stable-worker",
                claim_token=first["claim_token"],
                lease_seconds=40,
            )
        )
        now[0] = 1041.0
        second = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            1,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="stable-worker",
            lease_seconds=30,
            source_message_id=source_id,
        )
        self.assertEqual(second["claim_generation"], 2)
        self.assertNotEqual(first["claim_token"], second["claim_token"])
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.complete_stage(
                "task-1",
                "keystone",
                "review",
                1,
                owner="stable-worker",
                claim_token=first["claim_token"],
                result={"verdict": "NOGO"},
                output={
                    "subject": "hi.myrmidon.claude.test.task-1",
                    "payload": {"task_id": "task-1", "iteration": 2},
                },
            )
        self.assertTrue(
            store.release_stage_claim(
                "task-1",
                "keystone",
                "review",
                1,
                owner="stable-worker",
                claim_token=second["claim_token"],
            )
        )
        now[0] = 5000.0
        recoverable = store.recoverable_stages()
        self.assertEqual(len(recoverable), 1)
        self.assertEqual(recoverable[0]["source_event_id"], event_id)
        self.assertEqual(recoverable[0]["payload"], payload)

    def test_stage_renewal_fails_closed_when_its_source_is_lost(self) -> None:
        store = self._store()
        self._record_plan(store)
        subject = "hi.myrmidon.claude.review.task-1"
        payload = {"task_id": "task-1", "iteration": 1}
        source_id = self._stage_source(
            store,
            "task-1",
            "keystone",
            subject,
            payload,
            purpose="stage:keystone:implement:1",
        )
        claim = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            1,
            source_event_id=legacy_runtime.stable_event_id(
                subject,
                stream="homeric-myrmidon",
                message_id=source_id,
            ),
            source_message_id=source_id,
            subject=subject,
            payload=payload,
            owner="worker-1",
            lease_seconds=30,
        )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "DELETE FROM outbox WHERE namespace = ? AND outbox_id = ?",
                (store.namespace, source_id),
            )

        with self.assertRaises(legacy_runtime.StateConflictError):
            store.renew_stage_claim(
                "task-1",
                "keystone",
                "review",
                1,
                owner="worker-1",
                claim_token=claim["claim_token"],
                lease_seconds=30,
            )

    def test_checkpoint_aware_outbox_rearms_after_duplicate_window_before_retention(
        self,
    ) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        outbox_id = store.enqueue_outbox(
            "task-1",
            {
                "subject": "hi.myrmidon.claude.test.task-1",
                "payload": {"task_id": "task-1", "iteration": 1},
            },
            purpose="route:keystone",
            requires_consumer_checkpoint=True,
        )
        first = store.claim_outbox(owner="publisher-1", lease_seconds=30)[0]
        store.record_outbox_attempt(
            outbox_id,
            owner="publisher-1",
            claim_token=first["claim_token"],
        )
        self.assertTrue(
            store.mark_outbox_sent(
                outbox_id,
                owner="publisher-1",
                claim_token=first["claim_token"],
            )
        )
        self.assertGreater(store.outbox_rearm_seconds, store.duplicate_window_seconds)
        self.assertLess(store.outbox_rearm_seconds, store.message_retention_seconds)
        now[0] = 1000.0 + store.outbox_rearm_seconds - 0.1
        self.assertEqual(store.pending_outbox(), [])
        now[0] = 1000.0 + store.outbox_rearm_seconds
        rearmed = store.claim_outbox(owner="publisher-2", lease_seconds=30)
        self.assertEqual([item["id"] for item in rearmed], [outbox_id])
        self.assertEqual(rearmed[0]["claim_generation"], 2)

    def test_review_go_checkpoints_candidate_and_ship_event_in_one_transaction(
        self,
    ) -> None:
        store = self._store()
        self._record_plan(store)
        subject = "hi.myrmidon.claude.review.keystone.task-1"
        payload = {"task_id": "task-1", "repo_slug": "keystone", "iteration": 1}
        source_id = self._stage_source(
            store,
            "task-1",
            "keystone",
            subject,
            payload,
            purpose="stage:keystone:implement:1",
        )
        event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-myrmidon",
            message_id=source_id,
        )
        claim = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            1,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="reviewer",
            lease_seconds=30,
            source_message_id=source_id,
            intent={"expected_tree_oid": "1" * 40},
        )
        candidate = {"task_id": "task-1", "repo_slug": "keystone", "tree": "1" * 40}
        with self.assertRaises(ValueError):
            store.complete_stage(
                "task-1",
                "keystone",
                "review",
                1,
                owner="reviewer",
                claim_token=claim["claim_token"],
                result={"verdict": "GO"},
                output={"subject": "hi.myrmidon.claude.ship.keystone.task-1"},
                candidate=candidate,
            )
        self.assertNotIn("keystone", store.load_task("task-1")["candidates"])
        self.assertEqual(len(store.recoverable_stages()), 0)

        completed = store.complete_stage(
            "task-1",
            "keystone",
            "review",
            1,
            owner="reviewer",
            claim_token=claim["claim_token"],
            result={"verdict": "GO"},
            output={
                "subject": "hi.myrmidon.claude.ship.keystone.task-1",
                "payload": {"task_id": "task-1", "repo_slug": "keystone"},
            },
            candidate=candidate,
        )
        self.assertEqual(completed["state"], "succeeded")
        self.assertEqual(
            store.load_task("task-1")["candidates"]["keystone"], candidate
        )

    def test_same_owner_candidate_reacquisition_fences_the_expired_worker(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"tree": "1" * 40})
        first = self._claim_candidate(
            store,
            "task-1", "keystone", owner="stable-shipper", lease_seconds=10
        )
        now[0] = 1011.0
        second = self._claim_candidate(
            store,
            "task-1", "keystone", owner="stable-shipper", lease_seconds=10
        )
        self.assertEqual(second["claim_generation"], 2)
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_receipt(
                "task-1",
                "keystone",
                {"merge_oid": "2" * 40},
                owner="stable-shipper",
                claim_token=first["claim_token"],
                source_message_id=first["source_message_id"],
                source_subject=first["source_subject"],
                source_payload=first["source_payload"],
            )
        stored = store.record_receipt(
            "task-1",
            "keystone",
            {"merge_oid": "2" * 40},
            owner="stable-shipper",
            claim_token=second["claim_token"],
            source_message_id=second["source_message_id"],
            source_subject=second["source_subject"],
            source_payload=second["source_payload"],
        )
        self.assertFalse(stored["ready"])

    def test_terminal_stage_checkpoint_is_atomic_idempotent_and_complete(self) -> None:
        store = self._store()
        self._record_plan(store)
        subject = "hi.myrmidon.claude.review.keystone.task-1"
        payload = {"task_id": "task-1", "repo_slug": "keystone", "iteration": 4}
        source_id = self._stage_source(
            store,
            "task-1",
            "keystone",
            subject,
            payload,
            purpose="stage:keystone:implement:4",
        )
        event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-myrmidon",
            message_id=source_id,
        )
        claim = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            4,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="reviewer",
            lease_seconds=30,
            source_message_id=source_id,
        )
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": "task-1", "status": "human-blocked"},
        }
        outbox = (
            {
                "subject": "hi.tasks.team-1.task-1.human-blocked",
                "payload": terminal,
            },
            {
                "subject": "hi.logs.myrmidon.task-1",
                "payload": {"task_id": "task-1", "reason": "max-iterations"},
            },
        )
        result = {"verdict": "NOGO", "reason": "max-iterations"}
        completed = store.terminate_stage(
            "task-1",
            "keystone",
            "review",
            4,
            owner="reviewer",
            claim_token=claim["claim_token"],
            status="human-blocked",
            result=result,
            terminal=terminal,
            outbox=outbox,
        )
        self.assertEqual(completed["state"], "human-blocked")
        redelivery = store.claim_stage(
            "task-1",
            "keystone",
            "review",
            4,
            source_event_id=event_id,
            subject=subject,
            payload=payload,
            owner="reviewer-2",
            lease_seconds=30,
            source_message_id=source_id,
        )
        self.assertEqual(redelivery, completed)
        self.assertEqual(len(store.pending_outbox()), 2)

        with store._transaction() as connection:
            connection.execute(
                "DELETE FROM outbox WHERE namespace = ? AND task_id = ? "
                "AND purpose = 'terminal:human-blocked:1'",
                (store.namespace, "task-1"),
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.terminate_stage(
                "task-1",
                "keystone",
                "review",
                4,
                owner="reviewer",
                claim_token=claim["claim_token"],
                status="human-blocked",
                result=result,
                terminal=terminal,
                outbox=outbox,
            )

    def test_claim_leases_cannot_span_the_configured_message_retention(self) -> None:
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
        )
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        with self.assertRaises(ValueError):
            self._claim_candidate(
                store,
                "task-1", "keystone", owner="worker", lease_seconds=7200
            )
        with self.assertRaises(ValueError):
            store.claim_stage(
                "task-1",
                "keystone",
                "test",
                1,
                source_event_id="e" * 64,
                subject="hi.myrmidon.claude.test.task-1",
                payload={"task_id": "task-1"},
                owner="worker",
                lease_seconds=3600,
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            legacy_runtime.runtime_store(
                self.root,
                self.repo,
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=7200,
                duplicate_window_seconds=120,
            )
        with self.assertRaises(ValueError):
            legacy_runtime.runtime_store(
                self.root,
                self.repo,
                "c" * 64,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=3600,
            )

    def test_failed_and_human_blocked_terminal_states_are_durable_and_atomic(
        self,
    ) -> None:
        for status in ("failed", "human-blocked"):
            with self.subTest(status=status):
                task_id = f"task-{status}"
                store = self._store()
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    self.routes,
                    hashlib.sha256(task_id.encode()).hexdigest(),
                )
                terminal = {
                    "event": f"task.{status}",
                    "data": {"task_id": task_id, "status": status},
                }
                event = {
                    "subject": f"hi.tasks.team-1.{task_id}.{status}",
                    "payload": terminal,
                }
                store.terminate_task(
                    task_id,
                    status=status,
                    terminal=terminal,
                    outbox=(event,),
                )
                store.terminate_task(
                    task_id,
                    status=status,
                    terminal=terminal,
                    outbox=(event,),
                )
                loaded = self._store().load_task(task_id)
                self.assertEqual(loaded["terminal_status"], status)
                self.assertEqual(loaded["completion"], terminal)
                pending = [
                    item
                    for item in store.pending_outbox()
                    if item["task_id"] == task_id
                ]
                self.assertEqual(len(pending), 1)
                self.assertEqual(pending[0]["purpose"], f"terminal:{status}:0")
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store.terminate_task(
                        task_id,
                        status="failed" if status == "human-blocked" else "human-blocked",
                        terminal=terminal,
                        outbox=(event,),
                    )

    def test_bound_source_must_still_exist_when_a_stage_finishes(self) -> None:
        for operation in ("complete", "terminate"):
            with self.subTest(operation=operation):
                task_id = f"task-source-{operation}"
                store = self._store()
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    {"keystone": self.routes["keystone"]},
                    hashlib.sha256(task_id.encode()).hexdigest(),
                )
                subject = f"hi.myrmidon.claude.test.{task_id}"
                payload = {"task_id": task_id, "iteration": 1}
                source_id = store.enqueue_outbox(
                    task_id,
                    {"subject": subject, "payload": payload},
                    purpose="route:keystone",
                    requires_consumer_checkpoint=True,
                )
                claim = store.claim_stage(
                    task_id,
                    "keystone",
                    "test",
                    1,
                    source_event_id=legacy_runtime.stable_event_id(
                        subject,
                        stream="homeric-myrmidon",
                        message_id=source_id,
                    ),
                    source_message_id=source_id,
                    subject=subject,
                    payload=payload,
                    owner="worker",
                    lease_seconds=30,
                )
                with store._transaction() as connection:
                    connection.execute(
                        "DELETE FROM outbox WHERE namespace = ? AND outbox_id = ?",
                        (store.namespace, source_id),
                    )

                with self.assertRaises(legacy_runtime.StateConflictError):
                    if operation == "complete":
                        store.complete_stage(
                            task_id,
                            "keystone",
                            "test",
                            1,
                            owner="worker",
                            claim_token=claim["claim_token"],
                            result={"test_script": "ok"},
                            output={
                                "subject": (
                                    f"hi.myrmidon.claude.implement.{task_id}"
                                ),
                                "payload": payload,
                            },
                        )
                    else:
                        terminal = {
                            "event": "task.failed",
                            "data": {"task_id": task_id, "status": "failed"},
                        }
                        store.terminate_stage(
                            task_id,
                            "keystone",
                            "test",
                            1,
                            owner="worker",
                            claim_token=claim["claim_token"],
                            status="failed",
                            result={"reason": "model failure"},
                            terminal=terminal,
                            outbox=(
                                {
                                    "subject": f"hi.tasks.team-1.{task_id}.failed",
                                    "payload": terminal,
                                },
                            ),
                        )

                with store._transaction() as connection:
                    stage = connection.execute(
                        "SELECT state FROM stage_runs WHERE namespace = ? "
                        "AND task_id = ? AND repo_slug = 'keystone' "
                        "AND stage = 'test' AND iteration = 1",
                        (store.namespace, task_id),
                    ).fetchone()
                    task = connection.execute(
                        "SELECT completion_json FROM tasks WHERE namespace = ? "
                        "AND task_id = ?",
                        (store.namespace, task_id),
                    ).fetchone()
                    later_events = connection.execute(
                        "SELECT COUNT(*) FROM outbox WHERE namespace = ? "
                        "AND task_id = ?",
                        (store.namespace, task_id),
                    ).fetchone()[0]
                self.assertEqual(stage["state"], "pending")
                self.assertIsNone(task["completion_json"])
                self.assertEqual(later_events, 0)

    def test_reserved_root_stage_completes_task_and_checkpoints_fan_in_atomically(
        self,
    ) -> None:
        store = self._store()
        self._record_plan(store)
        self._record_ready_receipts(store)
        fan_in = next(
            item for item in store.pending_outbox() if item["purpose"] == "fan-in-ready"
        )
        event_id = legacy_runtime.stable_event_id(
            fan_in["subject"],
            stream="homeric-myrmidon",
            message_id=fan_in["id"],
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_stage(
                "task-1",
                "@odysseus-root",
                "review",
                0,
                source_event_id=event_id,
                source_message_id=fan_in["id"],
                subject=fan_in["subject"],
                payload=fan_in["payload"],
                owner="root-shipper",
                lease_seconds=30,
            )
        try:
            claim = store.claim_stage(
                "task-1",
                "@odysseus-root",
                "ship-final",
                0,
                source_event_id=event_id,
                source_message_id=fan_in["id"],
                subject=fan_in["subject"],
                payload=fan_in["payload"],
                intent={
                    "base_oid": "1" * 40,
                    "expected_tree_oid": "2" * 40,
                    "gitlinks": {
                        "provisioning/Keystone": {
                            "mode": "160000",
                            "oid": "3" * 40,
                        }
                    },
                },
                owner="root-shipper",
                lease_seconds=30,
            )
        except legacy_runtime.StateConflictError as error:
            self.fail(f"reserved root stage was rejected: {error}")
        completion = {
            "event": "task.completed",
            "data": {"task_id": "task-1", "status": "completed"},
        }
        completion_outbox = (
            {
                "subject": "hi.tasks.team-1.task-1.completed",
                "payload": completion,
            },
        )
        completed = store.complete_root_stage(
            "task-1",
            owner="root-shipper",
            claim_token=claim["claim_token"],
            result={"merge_oid": "4" * 40},
            completion=completion,
            outbox=completion_outbox,
        )
        self.assertEqual(completed["state"], "succeeded")
        self.assertEqual(store.load_task("task-1")["terminal_status"], "completed")
        self.assertNotIn(fan_in["id"], {item["id"] for item in store.pending_outbox()})
        self.assertEqual(
            store.claim_stage(
                "task-1",
                "@odysseus-root",
                "ship-final",
                0,
                source_event_id=event_id,
                source_message_id=fan_in["id"],
                subject=fan_in["subject"],
                payload=fan_in["payload"],
                intent={
                    "base_oid": "1" * 40,
                    "expected_tree_oid": "2" * 40,
                    "gitlinks": {
                        "provisioning/Keystone": {
                            "mode": "160000",
                            "oid": "3" * 40,
                        }
                    },
                },
                owner="other-root-shipper",
                lease_seconds=30,
            ),
            completed,
        )
        self.assertEqual(
            store.complete_root_stage(
                "task-1",
                owner="root-shipper",
                claim_token=claim["claim_token"],
                result={"merge_oid": "4" * 40},
                completion=completion,
                outbox=completion_outbox,
            ),
            completed,
        )

    def test_root_stage_and_repository_stages_are_mutually_exclusive(self) -> None:
        store = self._store()
        self._record_plan(store)
        peer_subject = "hi.myrmidon.claude.test.task-1"
        peer_payload = {"task_id": "task-1", "iteration": 1}
        peer_source = self._stage_source(
            store,
            "task-1",
            "keystone",
            peer_subject,
            peer_payload,
        )
        peer_claim = store.claim_stage(
            "task-1",
            "keystone",
            "test",
            1,
            source_event_id=legacy_runtime.stable_event_id(
                peer_subject,
                stream="homeric-myrmidon",
                message_id=peer_source,
            ),
            source_message_id=peer_source,
            subject=peer_subject,
            payload=peer_payload,
            owner="peer-worker",
            lease_seconds=30,
        )
        self._record_ready_receipts(store)
        fan_in = next(
            item for item in store.pending_outbox() if item["purpose"] == "fan-in-ready"
        )
        root_arguments = {
            "source_event_id": legacy_runtime.stable_event_id(
                fan_in["subject"],
                stream="homeric-myrmidon",
                message_id=fan_in["id"],
            ),
            "source_message_id": fan_in["id"],
            "subject": fan_in["subject"],
            "payload": fan_in["payload"],
            "intent": {"expected_tree_oid": "2" * 40},
            "owner": "root-worker",
            "lease_seconds": 30,
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_stage(
                "task-1", "@odysseus-root", "ship-final", 0, **root_arguments
            )

        store.complete_stage(
            "task-1",
            "keystone",
            "test",
            1,
            owner="peer-worker",
            claim_token=peer_claim["claim_token"],
            result={"test_script": "ok"},
            output={
                "subject": "hi.myrmidon.claude.implement.task-1",
                "payload": peer_payload,
            },
        )
        root_claim = store.claim_stage(
            "task-1", "@odysseus-root", "ship-final", 0, **root_arguments
        )
        late_subject = "hi.myrmidon.claude.test.hephaestus.task-1"
        late_payload = {"task_id": "task-1", "iteration": 1}
        late_source = self._stage_source(
            store,
            "task-1",
            "hephaestus",
            late_subject,
            late_payload,
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_stage(
                "task-1",
                "hephaestus",
                "test",
                1,
                source_event_id=legacy_runtime.stable_event_id(
                    late_subject,
                    stream="homeric-myrmidon",
                    message_id=late_source,
                ),
                source_message_id=late_source,
                subject=late_subject,
                payload=late_payload,
                owner="late-peer",
                lease_seconds=30,
            )
        self.assertTrue(
            store.renew_stage_claim(
                "task-1",
                "@odysseus-root",
                "ship-final",
                0,
                owner="root-worker",
                claim_token=root_claim["claim_token"],
                lease_seconds=30,
            )
        )

    def test_root_completion_rejects_a_corrupt_pending_peer_stage(self) -> None:
        store = self._store()
        self._record_plan(store)
        self._record_ready_receipts(store)
        fan_in = next(
            item for item in store.pending_outbox() if item["purpose"] == "fan-in-ready"
        )
        root_claim = store.claim_stage(
            "task-1",
            "@odysseus-root",
            "ship-final",
            0,
            source_event_id=legacy_runtime.stable_event_id(
                fan_in["subject"],
                stream="homeric-myrmidon",
                message_id=fan_in["id"],
            ),
            source_message_id=fan_in["id"],
            subject=fan_in["subject"],
            payload=fan_in["payload"],
            intent={"expected_tree_oid": "2" * 40},
            owner="root-worker",
            lease_seconds=30,
        )
        peer_subject = "hi.myrmidon.claude.test.task-1"
        peer_payload = {"task_id": "task-1", "iteration": 1}
        peer_source = self._stage_source(
            store,
            "task-1",
            "keystone",
            peer_subject,
            peer_payload,
        )
        peer_input = legacy_runtime._canonical_json(peer_payload, "peer payload")
        peer_intent = legacy_runtime._canonical_json(None, "peer intent")
        with store._transaction() as connection:
            connection.execute(
                "INSERT INTO stage_runs (namespace, task_id, repo_slug, stage, "
                "iteration, source_event_id, source_message_id, subject, input_json, "
                "input_digest, intent_json, intent_digest, state, claim_generation, "
                "created_at) VALUES (?, ?, ?, 'test', 1, ?, ?, ?, ?, ?, ?, ?, "
                "'pending', 0, ?)",
                (
                    store.namespace,
                    "task-1",
                    "keystone",
                    legacy_runtime.stable_event_id(
                        peer_subject,
                        stream="homeric-myrmidon",
                        message_id=peer_source,
                    ),
                    peer_source,
                    peer_subject,
                    peer_input,
                    hashlib.sha256(peer_input.encode()).hexdigest(),
                    peer_intent,
                    hashlib.sha256(peer_intent.encode()).hexdigest(),
                    1.0,
                ),
            )
        completion = {
            "event": "task.completed",
            "data": {"task_id": "task-1", "status": "completed"},
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.complete_root_stage(
                "task-1",
                owner="root-worker",
                claim_token=root_claim["claim_token"],
                result={"merge_oid": "4" * 40},
                completion=completion,
                outbox=(
                    {
                        "subject": "hi.tasks.team-1.task-1.completed",
                        "payload": completion,
                    },
                ),
            )
        self.assertIsNone(store.load_task("task-1")["terminal_status"])
        self.assertTrue(
            store.renew_stage_claim(
                "task-1",
                "@odysseus-root",
                "ship-final",
                0,
                owner="root-worker",
                claim_token=root_claim["claim_token"],
                lease_seconds=30,
            )
        )

    def test_single_receipt_can_complete_task_in_the_same_transaction(self) -> None:
        store = self._store()
        route = {"odysseus": {"path": ".", "github_repo": self.repo}}
        store.record_plan("task-single", "team-1", 22, route, "d" * 64)
        candidate = {"head_oid": "1" * 40}
        store.save_candidate("task-single", "odysseus", candidate)
        candidate_event = {
            "subject": "hi.myrmidon.claude.ship.task-single",
            "payload": {"task_id": "task-single"},
        }
        source_id = store.enqueue_outbox(
            "task-single", candidate_event, purpose="candidate:odysseus"
        )
        claim = store.claim_candidate(
            "task-single",
            "odysseus",
            owner="shipper",
            lease_seconds=30,
            source_message_id=source_id,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        completion = {
            "event": "task.completed",
            "data": {"task_id": "task-single", "status": "completed"},
        }
        completion_outbox = (
            {
                "subject": "hi.tasks.team-1.task-single.completed",
                "payload": completion,
            },
        )
        self.assertTrue(
            hasattr(store, "record_receipt_and_complete_task"),
            "runtime store must expose one atomic receipt/completion operation",
        )
        store.record_receipt_and_complete_task(
            "task-single",
            "odysseus",
            {"merge_oid": "2" * 40},
            owner="shipper",
            claim_token=claim["claim_token"],
            source_message_id=source_id,
            source_subject=candidate_event["subject"],
            source_payload=candidate_event["payload"],
            completion=completion,
            outbox=completion_outbox,
        )
        loaded = store.load_task("task-single")
        self.assertEqual(loaded["terminal_status"], "completed")
        self.assertEqual(loaded["receipts"]["odysseus"], {"merge_oid": "2" * 40})
        self.assertNotIn(source_id, {item["id"] for item in store.pending_outbox()})
        self.assertEqual(
            [item["purpose"] for item in store.pending_outbox()], ["completion:0"]
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_candidate(
                "task-single",
                "odysseus",
                owner="late-shipper",
                lease_seconds=30,
                source_message_id=source_id,
                subject=candidate_event["subject"],
                payload=candidate_event["payload"],
            )
        store.record_receipt_and_complete_task(
            "task-single",
            "odysseus",
            {"merge_oid": "2" * 40},
            owner="shipper",
            claim_token=claim["claim_token"],
            source_message_id=source_id,
            source_subject=candidate_event["subject"],
            source_payload=candidate_event["payload"],
            completion=completion,
            outbox=completion_outbox,
        )

    def test_persisted_single_receipt_can_resume_completion_without_claim_token(
        self,
    ) -> None:
        store = self._store()
        task_id = "task-single-receipt-crash"
        store.record_plan(
            task_id,
            "team-1",
            22,
            {"odysseus": {"path": ".", "github_repo": self.repo}},
            hashlib.sha256(task_id.encode()).hexdigest(),
        )
        store.save_candidate(task_id, "odysseus", {"head_oid": "1" * 40})
        candidate_event = {
            "subject": f"hi.myrmidon.claude.ship.{task_id}",
            "payload": {"task_id": task_id},
        }
        source_id = store.enqueue_outbox(
            task_id, candidate_event, purpose="candidate:odysseus"
        )
        claim = store.claim_candidate(
            task_id,
            "odysseus",
            owner="shipper",
            lease_seconds=30,
            source_message_id=source_id,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        receipt = {"merge_oid": "2" * 40}
        store.record_receipt(
            task_id,
            "odysseus",
            receipt,
            owner="shipper",
            claim_token=claim["claim_token"],
            source_message_id=source_id,
            source_subject=candidate_event["subject"],
            source_payload=candidate_event["payload"],
            ready_outbox={
                "subject": f"hi.myrmidon.claude.ship-final.{task_id}",
                "payload": {"task_id": task_id},
            },
        )
        inspected = store.inspect_candidate(
            task_id,
            "odysseus",
            source_message_id=source_id,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        self.assertEqual(inspected["state"], "completed")
        self.assertEqual(inspected["receipt"], receipt)
        completion = {
            "event": "task.completed",
            "data": {"task_id": task_id, "status": "completed"},
        }
        store.record_receipt_and_complete_task(
            task_id,
            "odysseus",
            receipt,
            owner="recovery-worker",
            claim_token=None,
            source_message_id=source_id,
            source_subject=candidate_event["subject"],
            source_payload=candidate_event["payload"],
            completion=completion,
            outbox=(
                {
                    "subject": f"hi.tasks.team-1.{task_id}.completed",
                    "payload": completion,
                },
            ),
        )
        self.assertEqual(store.load_task(task_id)["terminal_status"], "completed")

    def test_receipt_cannot_bypass_an_existing_candidate_claim(self) -> None:
        store = self._store()
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        self._claim_candidate(
            store,
            "task-1",
            "keystone",
            owner="shipper",
            lease_seconds=30,
        )

        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_receipt(
                "task-1",
                "keystone",
                {"merge_oid": "2" * 40},
            )

    def test_terminal_tasks_fence_candidates_and_pending_stages(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        for status, expired in (("failed", True), ("human-blocked", True)):
            with self.subTest(status=status, expired=expired):
                task_id = f"task-{status}-candidate"
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    {"keystone": self.routes["keystone"]},
                    hashlib.sha256(task_id.encode()).hexdigest(),
                )
                store.save_candidate(task_id, "keystone", {"tree": "1" * 40})
                source_id, source_event = self._candidate_source(
                    store, task_id, "keystone"
                )
                first_claim = store.claim_candidate(
                    task_id,
                    "keystone",
                    owner="shipper",
                    lease_seconds=10,
                    source_message_id=source_id,
                    subject=source_event["subject"],
                    payload=source_event["payload"],
                )
                if expired:
                    now[0] += 11
                terminal = {
                    "event": f"task.{status}",
                    "data": {"task_id": task_id, "status": status},
                }
                terminal_arguments = {
                    "status": status,
                    "terminal": terminal,
                    "outbox": (
                        {
                            "subject": f"hi.tasks.team-1.{task_id}.{status}",
                            "payload": terminal,
                        },
                    ),
                }
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store.terminate_task(task_id, **terminal_arguments)
                self.assertIsNone(store.load_task(task_id)["terminal_status"])
                replacement = store.claim_candidate(
                    task_id,
                    "keystone",
                    owner="recovery-shipper",
                    lease_seconds=10,
                    source_message_id=source_id,
                    subject=source_event["subject"],
                    payload=source_event["payload"],
                )
                self.assertNotEqual(
                    first_claim["claim_token"], replacement["claim_token"]
                )
                self.assertTrue(
                    store.release_claim(
                        task_id,
                        "keystone",
                        owner="recovery-shipper",
                        claim_token=replacement["claim_token"],
                    )
                )
                store.terminate_task(
                    task_id,
                    **terminal_arguments,
                )
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store.claim_candidate(
                        task_id,
                        "keystone",
                        owner="late-shipper",
                        lease_seconds=10,
                        source_message_id=source_id,
                        subject=source_event["subject"],
                        payload=source_event["payload"],
                    )
                self.assertNotIn(
                    {"task_id": task_id, "repo_slug": "keystone"},
                    store.reconcile()["claimable_candidates"],
                )
                self.assertEqual(
                    [
                        event["purpose"]
                        for event in store.pending_outbox()
                        if event["task_id"] == task_id
                    ],
                    [f"terminal:{status}:0"],
                )

        task_id = "task-pending-stage"
        store.record_plan(
            task_id,
            "team-1",
            22,
            {"keystone": self.routes["keystone"]},
            hashlib.sha256(task_id.encode()).hexdigest(),
        )
        pending_subject = f"hi.myrmidon.claude.review.{task_id}"
        pending_payload = {"task_id": task_id}
        source_id = self._stage_source(
            store,
            task_id,
            "keystone",
            pending_subject,
            pending_payload,
            purpose="stage:keystone:implement:1",
        )
        store.claim_stage(
            task_id,
            "keystone",
            "review",
            1,
            source_event_id=legacy_runtime.stable_event_id(
                pending_subject,
                stream="homeric-myrmidon",
                message_id=source_id,
            ),
            source_message_id=source_id,
            subject=pending_subject,
            payload=pending_payload,
            owner="reviewer",
            lease_seconds=30,
        )
        terminal = {
            "event": "task.failed",
            "data": {"task_id": task_id, "status": "failed"},
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.terminate_task(
                task_id,
                status="failed",
                terminal=terminal,
                outbox=(
                    {
                        "subject": f"hi.tasks.team-1.{task_id}.failed",
                        "payload": terminal,
                    },
                ),
            )

    def test_late_unstarted_control_event_is_drained_after_peer_termination(
        self,
    ) -> None:
        store = self._store()
        task_id = "task-late-control"
        routes = {
            slug: {
                **route,
                "dispatch_event": {
                    "subject": f"hi.myrmidon.claude.test.{slug}.{task_id}",
                    "payload": {
                        "task_id": task_id,
                        "repo_slug": slug,
                        "iteration": 1,
                    },
                },
            }
            for slug, route in self.routes.items()
        }
        plan_subject = f"hi.tasks.team-1.{task_id}.assigned"
        store.record_plan_transition(
            task_id,
            "team-1",
            22,
            routes,
            hashlib.sha256(task_id.encode()).hexdigest(),
            source_event_id=legacy_runtime.stable_event_id(
                plan_subject,
                stream="homeric-tasks",
                message_id="late-control-plan",
            ),
            subject=plan_subject,
            payload={"task_id": task_id},
        )
        route_events = {
            event["purpose"]: event for event in store.pending_outbox()
        }
        first_source = route_events["route:keystone"]
        first_claim = store.claim_stage(
            task_id,
            "keystone",
            "test",
            1,
            source_event_id=legacy_runtime.stable_event_id(
                first_source["subject"],
                stream="homeric-myrmidon",
                message_id=first_source["id"],
            ),
            source_message_id=first_source["id"],
            subject=first_source["subject"],
            payload=first_source["payload"],
            owner="failing-worker",
            lease_seconds=30,
        )
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": task_id},
        }
        store.terminate_stage(
            task_id,
            "keystone",
            "test",
            1,
            owner="failing-worker",
            claim_token=first_claim["claim_token"],
            status="human-blocked",
            result={"reason": "iteration limit"},
            terminal=terminal,
            outbox=(
                {
                    "subject": f"hi.tasks.team-1.{task_id}.human-blocked",
                    "payload": terminal,
                },
            ),
        )
        late_source = route_events["route:hephaestus"]
        late = store.claim_stage(
            task_id,
            "hephaestus",
            "test",
            1,
            source_event_id=legacy_runtime.stable_event_id(
                late_source["subject"],
                stream="homeric-myrmidon",
                message_id=late_source["id"],
            ),
            source_message_id=late_source["id"],
            subject=late_source["subject"],
            payload=late_source["payload"],
            owner="late-worker",
            lease_seconds=30,
        )
        self.assertEqual(late["state"], "terminal")
        self.assertEqual(late["terminal_status"], "human-blocked")
        with closing(sqlite3.connect(store.database)) as connection, connection:
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM stage_runs WHERE namespace = ? "
                    "AND task_id = ? AND repo_slug = ?",
                    (store.namespace, task_id, "hephaestus"),
                ).fetchone()[0],
                0,
            )

    def test_stage_termination_refuses_live_peer_claims(self) -> None:
        for peer_kind in ("candidate", "stage"):
            with self.subTest(peer_kind=peer_kind):
                store = self._store()
                task_id = f"task-live-peer-{peer_kind}"
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    self.routes,
                    hashlib.sha256(task_id.encode()).hexdigest(),
                )
                failing_subject = f"hi.myrmidon.claude.test.keystone.{task_id}"
                failing_payload = {
                    "task_id": task_id,
                    "repo_slug": "keystone",
                    "iteration": 1,
                }
                failing_source = self._stage_source(
                    store,
                    task_id,
                    "keystone",
                    failing_subject,
                    failing_payload,
                )
                failing_claim = store.claim_stage(
                    task_id,
                    "keystone",
                    "test",
                    1,
                    source_event_id=legacy_runtime.stable_event_id(
                        failing_subject,
                        stream="homeric-myrmidon",
                        message_id=failing_source,
                    ),
                    source_message_id=failing_source,
                    subject=failing_subject,
                    payload=failing_payload,
                    owner="failing-worker",
                    lease_seconds=30,
                )
                if peer_kind == "candidate":
                    store.save_candidate(
                        task_id, "hephaestus", {"head_oid": "1" * 40}
                    )
                    peer_source, peer_event = self._candidate_source(
                        store, task_id, "hephaestus"
                    )
                    peer_claim = store.claim_candidate(
                        task_id,
                        "hephaestus",
                        owner="peer-worker",
                        lease_seconds=30,
                        source_message_id=peer_source,
                        subject=peer_event["subject"],
                        payload=peer_event["payload"],
                    )
                else:
                    peer_subject = (
                        f"hi.myrmidon.claude.test.hephaestus.{task_id}"
                    )
                    peer_payload = {
                        "task_id": task_id,
                        "repo_slug": "hephaestus",
                        "iteration": 1,
                    }
                    peer_source = self._stage_source(
                        store,
                        task_id,
                        "hephaestus",
                        peer_subject,
                        peer_payload,
                    )
                    peer_claim = store.claim_stage(
                        task_id,
                        "hephaestus",
                        "test",
                        1,
                        source_event_id=legacy_runtime.stable_event_id(
                            peer_subject,
                            stream="homeric-myrmidon",
                            message_id=peer_source,
                        ),
                        source_message_id=peer_source,
                        subject=peer_subject,
                        payload=peer_payload,
                        owner="peer-worker",
                        lease_seconds=30,
                    )
                terminal = {
                    "event": "task.human-blocked",
                    "data": {"task_id": task_id},
                }
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store.terminate_stage(
                        task_id,
                        "keystone",
                        "test",
                        1,
                        owner="failing-worker",
                        claim_token=failing_claim["claim_token"],
                        status="human-blocked",
                        result={"reason": "iteration limit"},
                        terminal=terminal,
                        outbox=(
                            {
                                "subject": (
                                    f"hi.tasks.team-1.{task_id}.human-blocked"
                                ),
                                "payload": terminal,
                            },
                        ),
                    )
                self.assertIsNone(store.load_task(task_id)["terminal_status"])
                if peer_kind == "candidate":
                    self.assertTrue(
                        store.renew_claim(
                            task_id,
                            "hephaestus",
                            owner="peer-worker",
                            claim_token=peer_claim["claim_token"],
                            lease_seconds=30,
                        )
                    )
                else:
                    self.assertTrue(
                        store.renew_stage_claim(
                            task_id,
                            "hephaestus",
                            "test",
                            1,
                            owner="peer-worker",
                            claim_token=peer_claim["claim_token"],
                            lease_seconds=30,
                        )
                    )

    def test_stage_termination_refuses_an_expired_but_owned_peer_claim(
        self,
    ) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        claims: dict[str, tuple[str, dict[str, object]]] = {}
        for repo_slug, lease_seconds in (("keystone", 30), ("hephaestus", 10)):
            subject = f"hi.myrmidon.claude.test.{repo_slug}.task-1"
            payload: dict[str, object] = {
                "task_id": "task-1",
                "repo_slug": repo_slug,
                "iteration": 1,
            }
            source_id = self._stage_source(
                store, "task-1", repo_slug, subject, payload
            )
            claim = store.claim_stage(
                "task-1",
                repo_slug,
                "test",
                1,
                source_event_id=legacy_runtime.stable_event_id(
                    subject,
                    stream="homeric-myrmidon",
                    message_id=source_id,
                ),
                source_message_id=source_id,
                subject=subject,
                payload=payload,
                owner=f"{repo_slug}-worker",
                lease_seconds=lease_seconds,
            )
            claims[repo_slug] = (source_id, claim)
        now[0] = 1011.0
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": "task-1"},
        }
        terminal_arguments = {
            "owner": "keystone-worker",
            "claim_token": claims["keystone"][1]["claim_token"],
            "status": "human-blocked",
            "result": {"reason": "iteration limit"},
            "terminal": terminal,
            "outbox": (
                {
                    "subject": "hi.tasks.team-1.task-1.human-blocked",
                    "payload": terminal,
                },
            ),
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.terminate_stage(
                "task-1", "keystone", "test", 1, **terminal_arguments
            )
        self.assertIsNone(store.load_task("task-1")["terminal_status"])
        peer_source, peer_claim = claims["hephaestus"]
        peer_subject = "hi.myrmidon.claude.test.hephaestus.task-1"
        peer_payload = {
            "task_id": "task-1",
            "repo_slug": "hephaestus",
            "iteration": 1,
        }
        replacement = store.claim_stage(
            "task-1",
            "hephaestus",
            "test",
            1,
            source_event_id=legacy_runtime.stable_event_id(
                peer_subject,
                stream="homeric-myrmidon",
                message_id=peer_source,
            ),
            source_message_id=peer_source,
            subject=peer_subject,
            payload=peer_payload,
            owner="recovery-worker",
            lease_seconds=10,
        )
        self.assertNotEqual(
            peer_claim["claim_token"], replacement["claim_token"]
        )
        self.assertTrue(
            store.release_stage_claim(
                "task-1",
                "hephaestus",
                "test",
                1,
                owner="recovery-worker",
                claim_token=replacement["claim_token"],
            )
        )
        completed = store.terminate_stage(
            "task-1", "keystone", "test", 1, **terminal_arguments
        )
        self.assertEqual(completed["state"], "human-blocked")

    def test_direct_task_termination_refuses_a_live_candidate_claim(self) -> None:
        store = self._store()
        task_id = "task-direct-terminal-live-candidate"
        store.record_plan(
            task_id,
            "team-1",
            22,
            {"keystone": self.routes["keystone"]},
            hashlib.sha256(task_id.encode()).hexdigest(),
        )
        store.save_candidate(task_id, "keystone", {"head_oid": "1" * 40})
        source_id, source_event = self._candidate_source(
            store, task_id, "keystone"
        )
        claim = store.claim_candidate(
            task_id,
            "keystone",
            owner="shipper",
            lease_seconds=30,
            source_message_id=source_id,
            subject=source_event["subject"],
            payload=source_event["payload"],
        )
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": task_id},
        }
        arguments = {
            "status": "human-blocked",
            "terminal": terminal,
            "outbox": (
                {
                    "subject": f"hi.tasks.team-1.{task_id}.human-blocked",
                    "payload": terminal,
                },
            ),
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.terminate_task(task_id, **arguments)
        self.assertIsNone(store.load_task(task_id)["terminal_status"])
        self.assertTrue(
            store.renew_claim(
                task_id,
                "keystone",
                owner="shipper",
                claim_token=claim["claim_token"],
                lease_seconds=30,
            )
        )
        self.assertEqual(
            [
                event["purpose"]
                for event in store.pending_outbox()
                if event["task_id"] == task_id
            ],
            ["candidate:keystone"],
        )
        self.assertTrue(
            store.release_claim(
                task_id,
                "keystone",
                owner="shipper",
                claim_token=claim["claim_token"],
            )
        )
        store.terminate_task(task_id, **arguments)
        self.assertEqual(store.load_task(task_id)["terminal_status"], "human-blocked")

    def test_terminal_graph_corruption_fails_on_reload_and_reconcile(self) -> None:
        store = self._store()
        self._record_plan(store)
        terminal = {
            "event": "task.failed",
            "data": {"task_id": "task-1", "status": "failed"},
        }
        store.terminate_task(
            "task-1",
            status="failed",
            terminal=terminal,
            outbox=(
                {
                    "subject": "hi.tasks.team-1.task-1.failed",
                    "payload": terminal,
                },
            ),
        )
        with store._transaction() as connection:
            connection.execute(
                "DELETE FROM outbox WHERE namespace = ? AND task_id = ? "
                "AND purpose = 'terminal:failed:0'",
                (store.namespace, "task-1"),
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.load_task("task-1")
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.reconcile()

    def test_rearm_time_must_be_between_duplicate_window_and_retention(self) -> None:
        for offset in (120.0, 3600.0):
            with self.subTest(offset=offset):
                now = [1000.0]
                root = Path(self.tempdir.name) / f"repo-rearm-{int(offset)}"
                _init_repo(root)
                store = legacy_runtime.runtime_store(
                    root,
                    f"{self.repo}:{offset}",
                    self.registry_digest,
                    host_id="host-a",
                    service_uid=os.geteuid(),
                    message_retention_seconds=3600,
                    duplicate_window_seconds=120,
                    clock=lambda: now[0],
                )
                store.record_plan(
                    "task-1",
                    "team-1",
                    22,
                    {"keystone": self.routes["keystone"]},
                    self.task_digest,
                )
                outbox_id = store.enqueue_outbox(
                    "task-1",
                    {
                        "subject": "hi.myrmidon.claude.test.task-1",
                        "payload": {"task_id": "task-1"},
                    },
                    purpose="route:keystone",
                    requires_consumer_checkpoint=True,
                )
                claim = store.claim_outbox(owner="publisher", lease_seconds=30)[0]
                store.mark_outbox_sent(
                    outbox_id,
                    owner="publisher",
                    claim_token=claim["claim_token"],
                )
                with store._transaction() as connection:
                    connection.execute(
                        "UPDATE outbox SET rearm_at = sent_at + ? "
                        "WHERE namespace = ? AND outbox_id = ?",
                        (offset, store.namespace, outbox_id),
                    )
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store.reconcile()

    def test_control_outbox_policy_is_checkpoint_aware_by_default(self) -> None:
        now = [1000.0]
        store = legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id="host-a",
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
            clock=lambda: now[0],
        )
        self._record_plan(store)
        outbox_id = store.enqueue_outbox(
            "task-1",
            {
                "subject": "hi.myrmidon.claude.test.task-1",
                "payload": {"task_id": "task-1"},
            },
            purpose="route:keystone",
        )
        claim = store.claim_outbox(owner="publisher", lease_seconds=30)[0]
        store.mark_outbox_sent(
            outbox_id,
            owner="publisher",
            claim_token=claim["claim_token"],
        )
        awaiting = store.reconcile()["awaiting_consumer_checkpoints"]
        self.assertEqual([event["id"] for event in awaiting], [outbox_id])
        now[0] += store.outbox_rearm_seconds
        self.assertEqual([event["id"] for event in store.pending_outbox()], [outbox_id])

    def test_interrupted_column_migration_is_repaired_transactionally(self) -> None:
        database = legacy_runtime.state_root(self.root) / "state.sqlite3"
        namespace = hashlib.sha256(
            f"{self.repo}\0{self.registry_digest}".encode()
        ).hexdigest()
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.execute(
                "CREATE TABLE runtimes (namespace TEXT PRIMARY KEY, repo TEXT NOT NULL, "
                "registry_digest TEXT NOT NULL, host_id TEXT NOT NULL, "
                "service_uid INTEGER, message_retention_seconds REAL, "
                "duplicate_window_seconds REAL, created_at REAL NOT NULL)"
            )
            connection.execute(
                "INSERT INTO runtimes VALUES (?, ?, ?, ?, NULL, NULL, NULL, ?)",
                (namespace, self.repo, self.registry_digest, "host-a", 1.0),
            )

        try:
            repaired = self._store()
        except legacy_runtime.HostBindingError as error:
            self.fail(f"interrupted migration was not repaired: {error}")
        self.assertEqual(repaired.service_uid, os.geteuid())
        with closing(repaired._connect()) as connection:
            row = connection.execute(
                "SELECT service_uid, message_retention_seconds, "
                "duplicate_window_seconds FROM runtimes WHERE namespace = ?",
                (namespace,),
            ).fetchone()
        self.assertEqual(row["service_uid"], os.geteuid())
        self.assertEqual(row["message_retention_seconds"], 3600)
        self.assertEqual(row["duplicate_window_seconds"], 120)

    def test_legacy_route_digest_is_backfilled_and_null_is_constrained(self) -> None:
        database = legacy_runtime.state_root(self.root) / "state.sqlite3"
        namespace = hashlib.sha256(
            f"{self.repo}\0{self.registry_digest}".encode()
        ).hexdigest()
        route_json = legacy_runtime._canonical_json(
            self.routes["keystone"], "route"
        )
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.executescript(
                """
                CREATE TABLE runtimes (
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
                CREATE TABLE tasks (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    team_id TEXT NOT NULL,
                    issue_number INTEGER NOT NULL,
                    task_digest TEXT NOT NULL,
                    completion_json TEXT,
                    completed_at REAL,
                    created_at REAL NOT NULL,
                    PRIMARY KEY (namespace, task_id)
                );
                CREATE TABLE routes (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    route_json TEXT NOT NULL,
                    PRIMARY KEY (namespace, task_id, repo_slug),
                    FOREIGN KEY (namespace, task_id)
                        REFERENCES tasks(namespace, task_id)
                );
                CREATE INDEX legacy_route_json_index ON routes(route_json);
                CREATE TABLE route_audit (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL
                );
                CREATE TRIGGER legacy_route_audit
                    AFTER UPDATE ON routes
                    BEGIN
                        INSERT INTO route_audit VALUES (
                            NEW.namespace, NEW.task_id, NEW.repo_slug
                        );
                    END;
                CREATE TABLE route_children (
                    namespace TEXT NOT NULL,
                    task_id TEXT NOT NULL,
                    repo_slug TEXT NOT NULL,
                    FOREIGN KEY (namespace, task_id, repo_slug)
                        REFERENCES routes(namespace, task_id, repo_slug)
                );
                """
            )
            connection.execute(
                "INSERT INTO runtimes VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
                (
                    namespace,
                    self.repo,
                    self.registry_digest,
                    "host-a",
                    os.geteuid(),
                    _TEST_CANDIDATE_UID,
                    3600,
                    120,
                    1.0,
                ),
            )
            connection.execute(
                "INSERT INTO tasks VALUES (?, ?, ?, ?, ?, NULL, NULL, ?)",
                (
                    namespace,
                    "legacy-task",
                    "team-1",
                    22,
                    self.task_digest,
                    1.0,
                ),
            )
            connection.execute(
                "INSERT INTO routes VALUES (?, ?, ?, ?)",
                (namespace, "legacy-task", "keystone", route_json),
            )
            connection.execute(
                "INSERT INTO route_children VALUES (?, ?, ?)",
                (namespace, "legacy-task", "keystone"),
            )
        database.chmod(0o600)

        migrated = self._store()
        self.assertEqual(
            migrated.load_task("legacy-task")["routes"]["keystone"],
            self.routes["keystone"],
        )
        with closing(sqlite3.connect(database)) as connection, connection:
            route_columns = {
                row[1]: row for row in connection.execute("PRAGMA table_info(routes)")
            }
            self.assertEqual(route_columns["route_digest"][3], 1)
            self.assertIn(
                "legacy_route_json_index",
                {
                    row[1]
                    for row in connection.execute("PRAGMA index_list(routes)")
                },
            )
            self.assertIsNotNone(
                connection.execute(
                    "SELECT 1 FROM sqlite_schema WHERE type = 'trigger' "
                    "AND name = 'legacy_route_audit'"
                ).fetchone()
            )
            child_foreign_keys = list(
                connection.execute("PRAGMA foreign_key_list(route_children)")
            )
            self.assertTrue(child_foreign_keys)
            self.assertEqual({row[2] for row in child_foreign_keys}, {"routes"})
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM route_children").fetchone()[0],
                1,
            )
            connection.execute(
                "UPDATE routes SET route_json = route_json WHERE namespace = ? "
                "AND task_id = ?",
                (namespace, "legacy-task"),
            )
            self.assertEqual(
                connection.execute("SELECT COUNT(*) FROM route_audit").fetchone()[0],
                1,
            )
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "UPDATE routes SET route_digest = NULL "
                    "WHERE namespace = ? AND task_id = ?",
                    (namespace, "legacy-task"),
                )
            connection.execute("DROP TRIGGER route_digest_required_insert")
            connection.execute("DROP TRIGGER route_digest_required_update")
            with self.assertRaises(sqlite3.IntegrityError):
                connection.execute(
                    "UPDATE routes SET route_digest = NULL "
                    "WHERE namespace = ? AND task_id = ?",
                    (namespace, "legacy-task"),
                )

    def test_concurrent_runtime_initialization_uses_one_atomic_migration(self) -> None:
        root = Path(self.tempdir.name) / "concurrent-initialization"
        _init_repo(root)
        barrier = threading.Barrier(2)

        def initialize() -> legacy_runtime.RuntimeStore:
            barrier.wait(timeout=3)
            return legacy_runtime.runtime_store(
                root,
                f"{self.repo}:concurrent",
                self.registry_digest,
                host_id="host-a",
                service_uid=os.geteuid(),
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )

        with ThreadPoolExecutor(max_workers=2) as executor:
            stores = list(executor.map(lambda _index: initialize(), range(2)))
        self.assertEqual(stores[0].namespace, stores[1].namespace)
        with closing(stores[0]._connect()) as connection:
            self.assertEqual(
                connection.execute("PRAGMA integrity_check").fetchone()[0], "ok"
            )

    def test_plan_transition_binds_source_and_route_outbox_atomically(self) -> None:
        store = self._store()
        payload = {"task_id": "task-plan", "team_id": "team-1"}
        subject = "hi.tasks.team-1.task-plan.assigned"
        source_event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-tasks",
            message_id="plan-message-1",
        )
        routes = {
            slug: {
                **route,
                "dispatch_event": {
                    "subject": f"hi.myrmidon.claude.test.{slug}.task-plan",
                    "payload": {"task_id": "task-plan", "repo_slug": slug},
                },
            }
            for slug, route in self.routes.items()
        }
        self.assertTrue(
            hasattr(store, "record_plan_transition"),
            "runtime store must expose one atomic plan transition",
        )
        store.record_plan_transition(
            "task-plan",
            "team-1",
            22,
            routes,
            "f" * 64,
            source_event_id=source_event_id,
            subject=subject,
            payload=payload,
        )
        store.record_plan_transition(
            "task-plan",
            "team-1",
            22,
            routes,
            "f" * 64,
            source_event_id=source_event_id,
            subject=subject,
            payload=payload,
        )
        self.assertEqual(
            {event["purpose"] for event in store.pending_outbox()},
            {"route:keystone", "route:hephaestus"},
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan_transition(
                "task-plan-copy",
                "team-1",
                22,
                routes,
                "0" * 64,
                source_event_id=source_event_id,
                subject=subject,
                payload={**payload, "task_id": "task-plan-copy"},
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan_transition(
                "task-plan",
                "team-1",
                22,
                routes,
                "f" * 64,
                source_event_id=source_event_id,
                subject=f"{subject}.changed",
                payload=payload,
            )

    def test_exact_plan_transition_redelivery_is_harmless_after_terminal(self) -> None:
        store = self._store()
        payload = {"task_id": "task-plan-terminal", "team_id": "team-1"}
        subject = "hi.tasks.team-1.task-plan-terminal.assigned"
        source_event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-tasks",
            message_id="plan-message-terminal",
        )
        routes = {
            slug: {
                **route,
                "dispatch_event": {
                    "subject": (
                        f"hi.myrmidon.claude.test.{slug}.task-plan-terminal"
                    ),
                    "payload": {
                        "task_id": "task-plan-terminal",
                        "repo_slug": slug,
                    },
                },
            }
            for slug, route in self.routes.items()
        }
        store.record_plan_transition(
            "task-plan-terminal",
            "team-1",
            22,
            routes,
            "e" * 64,
            source_event_id=source_event_id,
            subject=subject,
            payload=payload,
        )
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": "task-plan-terminal"},
        }
        store.terminate_task(
            "task-plan-terminal",
            status="human-blocked",
            terminal=terminal,
            outbox=(
                {
                    "subject": (
                        "hi.tasks.team-1.task-plan-terminal.human-blocked"
                    ),
                    "payload": terminal,
                },
            ),
        )

        store.record_plan_transition(
            "task-plan-terminal",
            "team-1",
            22,
            routes,
            "e" * 64,
            source_event_id=source_event_id,
            subject=subject,
            payload=payload,
        )
        conflicting_source_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-tasks",
            message_id="plan-message-terminal-copy",
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan_transition(
                "task-plan-terminal",
                "team-1",
                22,
                routes,
                "e" * 64,
                source_event_id=conflicting_source_id,
                subject=subject,
                payload=payload,
            )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "UPDATE tasks SET completion_json = '[]' WHERE namespace = ? "
                "AND task_id = ?",
                (store.namespace, "task-plan-terminal"),
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.record_plan_transition(
                "task-plan-terminal",
                "team-1",
                22,
                routes,
                "e" * 64,
                source_event_id=source_event_id,
                subject=subject,
                payload=payload,
            )

    def test_pruned_plan_retains_exact_ingress_redelivery_tombstone(self) -> None:
        store = self._store()
        task_id = "task-plan-pruned"
        payload = {"task_id": task_id, "team_id": "team-1"}
        subject = f"hi.tasks.team-1.{task_id}.assigned"
        source_event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-tasks",
            message_id="plan-message-pruned",
        )
        routes = {
            "keystone": {
                **self.routes["keystone"],
                "dispatch_event": {
                    "subject": f"hi.myrmidon.claude.test.keystone.{task_id}",
                    "payload": {"task_id": task_id, "repo_slug": "keystone"},
                },
            }
        }

        with patch.object(legacy_runtime, "_MAX_TERMINAL_HISTORY", 0):
            store.record_plan_transition(
                task_id,
                "team-1",
                22,
                routes,
                self.task_digest,
                source_event_id=source_event_id,
                subject=subject,
                payload=payload,
            )
            terminal = {"event": "task.failed", "data": {"task_id": task_id}}
            store.terminate_task(
                task_id,
                status="failed",
                terminal=terminal,
                outbox=(
                    {
                        "subject": f"hi.tasks.team-1.{task_id}.failed",
                        "payload": terminal,
                    },
                ),
            )
            claims = store.claim_outbox(
                owner="publisher", lease_seconds=60, limit=2
            )
            self.assertEqual(
                [claim["purpose"] for claim in claims], ["terminal:failed:0"]
            )
            for claim in claims:
                store.mark_outbox_sent(
                    claim["id"],
                    owner="publisher",
                    claim_token=claim["claim_token"],
                )
            self.assertIsNone(store.load_task(task_id))
            self.assertEqual(store.pending_outbox(), [])

            store.record_plan_transition(
                task_id,
                "team-1",
                22,
                routes,
                self.task_digest,
                source_event_id=source_event_id,
                subject=subject,
                payload=payload,
            )
            self.assertIsNone(store.load_task(task_id))
            self.assertEqual(store.pending_outbox(), [])

            with self.assertRaises(legacy_runtime.StateConflictError):
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    routes,
                    self.task_digest,
                )

            with self.assertRaises(legacy_runtime.StateConflictError):
                store.record_plan_transition(
                    task_id,
                    "team-1",
                    22,
                    routes,
                    self.task_digest,
                    source_event_id="9" * 64,
                    subject=subject,
                    payload=payload,
                )

    def test_plan_tombstone_expires_only_after_broker_retention(self) -> None:
        now = [100.0]

        def clock() -> float:
            return now[0]

        def open_store() -> legacy_runtime.RuntimeStore:
            return self._store(
                message_retention_seconds=10,
                duplicate_window_seconds=1,
                clock=clock,
            )

        task_id = "task-plan-retention-expiry"
        payload = {"task_id": task_id, "team_id": "team-1"}
        subject = f"hi.tasks.team-1.{task_id}.assigned"
        source_event_id = legacy_runtime.stable_event_id(
            subject,
            stream="homeric-tasks",
            message_id="plan-message-retention-expiry",
        )
        routes = {
            "keystone": {
                **self.routes["keystone"],
                "dispatch_event": {
                    "subject": f"hi.myrmidon.claude.test.keystone.{task_id}",
                    "payload": {"task_id": task_id, "repo_slug": "keystone"},
                },
            }
        }

        with patch.object(legacy_runtime, "_MAX_TERMINAL_HISTORY", 0):
            store = open_store()
            store.record_plan_transition(
                task_id,
                "team-1",
                22,
                routes,
                self.task_digest,
                source_event_id=source_event_id,
                subject=subject,
                payload=payload,
            )
            terminal = {"event": "task.failed", "data": {"task_id": task_id}}
            store.terminate_task(
                task_id,
                status="failed",
                terminal=terminal,
                outbox=(
                    {
                        "subject": f"hi.tasks.team-1.{task_id}.failed",
                        "payload": terminal,
                    },
                ),
            )
            claims = store.claim_outbox(
                owner="publisher",
                lease_seconds=1,
                limit=2,
            )
            self.assertEqual(
                [claim["purpose"] for claim in claims], ["terminal:failed:0"]
            )
            for claim in claims:
                store.mark_outbox_sent(
                    claim["id"],
                    owner="publisher",
                    claim_token=claim["claim_token"],
                )
            self.assertIsNone(store.load_task(task_id))

            for observed_time in (110.0, 90.0):
                now[0] = observed_time
                reopened = open_store()
                reopened.record_plan_transition(
                    task_id,
                    "team-1",
                    22,
                    routes,
                    self.task_digest,
                    source_event_id=source_event_id,
                    subject=subject,
                    payload=payload,
                )
                self.assertIsNone(reopened.load_task(task_id))

            now[0] = 110.001
            reopened = open_store()
            reopened.record_plan_transition(
                task_id,
                "team-1",
                22,
                routes,
                self.task_digest,
                source_event_id=source_event_id,
                subject=subject,
                payload=payload,
            )
            self.assertIsNotNone(reopened.load_task(task_id))
            self.assertEqual(len(reopened.pending_outbox()), 1)

    def test_message_delivery_guard_survives_restart_and_exact_retirement(
        self,
    ) -> None:
        source_event_id = "e" * 64
        first = self._store()
        claim_token = first.claim_message_delivery(source_event_id)
        self.assertIsNotNone(claim_token)

        restarted = self._store()
        self.assertIsNone(
            restarted.claim_message_delivery(source_event_id)
        )
        with self.assertRaises(
            legacy_runtime.WorkerContainmentFatalError
        ):
            restarted.release_message_delivery(
                source_event_id, "f" * 64
            )
        self.assertIsNone(
            restarted.claim_message_delivery(source_event_id)
        )

        restarted.release_message_delivery(source_event_id, claim_token)
        replacement = restarted.claim_message_delivery(source_event_id)
        self.assertIsNotNone(replacement)
        self.assertNotEqual(replacement, claim_token)
        restarted.release_message_delivery(source_event_id, replacement)

    def test_external_effect_receipt_survives_restart_and_fences_takeover(
        self,
    ) -> None:
        source_event_id = "e" * 64
        store = self._store()
        claim_token = store.claim_message_delivery(source_event_id)
        effect_token = store.arm_external_effect(
            source_event_id,
            claim_token,
            "pod-infra-relay",
            {
                "agent_name": "agent-one",
                "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                "invocation_token": "a" * 64,
                "pod_name": "pod-one",
            },
        )
        store.bind_external_effect(
            source_event_id,
            claim_token,
            effect_token,
            {
                "agent_id": "b" * 64,
                "infra_id": "c" * 64,
                "infra_pid": 4242,
                "infra_start_time": 100,
                "netns_dev": 11,
                "netns_ino": 12,
                "pod_id": "d" * 64,
                "relay_pid": 4343,
                "relay_start_time": 101,
            },
        )

        restarted = self._store()
        receipts = restarted.active_external_effects(source_event_id)
        self.assertEqual(len(receipts), 1)
        self.assertEqual(receipts[0].effect_token, effect_token)
        self.assertEqual(receipts[0].binding["pod_id"], "d" * 64)
        with self.assertRaises(
            legacy_runtime.WorkerContainmentFatalError
        ):
            restarted.take_over_message_delivery(
                source_event_id, claim_token
            )
        with self.assertRaises(
            legacy_runtime.WorkerContainmentFatalError
        ):
            restarted.retire_external_effect(
                source_event_id, "f" * 64, effect_token
            )

        restarted.retire_external_effect(
            source_event_id, claim_token, effect_token
        )
        replacement = restarted.take_over_message_delivery(
            source_event_id, claim_token
        )
        self.assertNotEqual(replacement, claim_token)
        restarted.release_message_delivery(source_event_id, replacement)

    def test_new_stage_claim_requires_an_exact_local_source_event(self) -> None:
        store = self._store()
        self._record_plan(store)
        stage_subject = "hi.myrmidon.claude.test.task-1"
        stage_payload = {"task_id": "task-1", "iteration": 1}
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_stage(
                "task-1",
                "keystone",
                "test",
                1,
                source_event_id="1" * 64,
                subject=stage_subject,
                payload=stage_payload,
                owner="worker",
                lease_seconds=30,
            )

    def test_new_stage_claim_rejects_an_already_checkpointed_source(self) -> None:
        store = self._store()
        self._record_plan(store)
        subject = "hi.myrmidon.claude.test.task-1"
        payload = {"task_id": "task-1", "iteration": 1}
        source_id = self._stage_source(
            store, "task-1", "keystone", subject, payload
        )
        with store._transaction() as connection:
            connection.execute(
                "UPDATE outbox SET consumer_checkpointed_at = ? "
                "WHERE namespace = ? AND outbox_id = ?",
                (1.0, store.namespace, source_id),
            )
        arguments = {
            "source_event_id": legacy_runtime.stable_event_id(
                subject,
                stream="homeric-myrmidon",
                message_id=source_id,
            ),
            "source_message_id": source_id,
            "subject": subject,
            "payload": payload,
        }
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.inspect_stage(
                "task-1", "keystone", "test", 1, **arguments
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_stage(
                "task-1",
                "keystone",
                "test",
                1,
                owner="worker",
                lease_seconds=30,
                **arguments,
            )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            self.assertEqual(
                connection.execute(
                    "SELECT COUNT(*) FROM stage_runs WHERE namespace = ?",
                    (store.namespace,),
                ).fetchone()[0],
                0,
            )

    def test_one_local_source_message_cannot_bind_two_stage_event_ids(self) -> None:
        store = self._store()
        self._record_plan(store)
        subject = "hi.myrmidon.claude.test.task-1"
        payload = {"task_id": "task-1", "iteration": 1}
        source_id = self._stage_source(
            store, "task-1", "keystone", subject, payload
        )
        first = store.claim_stage(
            "task-1",
            "keystone",
            "test",
            1,
            source_event_id="1" * 64,
            source_message_id=source_id,
            subject=subject,
            payload=payload,
            owner="worker-1",
            lease_seconds=30,
        )
        self.assertEqual(first["state"], "claimed")
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_stage(
                "task-1",
                "keystone",
                "test",
                1,
                source_event_id="2" * 64,
                source_message_id=source_id,
                subject=subject,
                payload=payload,
                owner="worker-2",
                lease_seconds=30,
            )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            indexes = {
                row[1]
                for row in connection.execute("PRAGMA index_list(stage_runs)")
            }
        self.assertIn("stage_source_message", indexes)

    def test_one_review_message_cannot_bind_stage_and_candidate_consumers(
        self,
    ) -> None:
        store = self._store()
        for order in ("stage-first", "candidate-first"):
            with self.subTest(order=order):
                task_id = f"task-cross-consumer-{order}"
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    {"keystone": self.routes["keystone"]},
                    hashlib.sha256(task_id.encode()).hexdigest(),
                )
                store.save_candidate(
                    task_id, "keystone", {"head_oid": "1" * 40}
                )
                subject = f"hi.myrmidon.claude.review-result.{task_id}"
                payload = {"task_id": task_id, "iteration": 1}
                with store._transaction() as connection:
                    source_id = store._insert_outbox(
                        connection,
                        task_id,
                        {"subject": subject, "payload": payload},
                        "stage:keystone:review:1",
                        requires_consumer_checkpoint=True,
                    )
                stage_arguments = {
                    "source_event_id": legacy_runtime.stable_event_id(
                        subject,
                        stream="homeric-myrmidon",
                        message_id=source_id,
                    ),
                    "source_message_id": source_id,
                    "subject": subject,
                    "payload": payload,
                    "owner": "stage-worker",
                    "lease_seconds": 30,
                }
                candidate_arguments = {
                    "owner": "candidate-worker",
                    "lease_seconds": 30,
                    "source_message_id": source_id,
                    "subject": subject,
                    "payload": payload,
                }
                if order == "stage-first":
                    store.claim_stage(
                        task_id,
                        "keystone",
                        "test",
                        2,
                        **stage_arguments,
                    )
                    with self.assertRaises(legacy_runtime.StateConflictError):
                        store.claim_candidate(
                            task_id, "keystone", **candidate_arguments
                        )
                    with self.assertRaises(legacy_runtime.StateConflictError):
                        store.inspect_candidate(
                            task_id,
                            "keystone",
                            source_message_id=source_id,
                            subject=subject,
                            payload=payload,
                        )
                else:
                    store.claim_candidate(
                        task_id, "keystone", **candidate_arguments
                    )
                    with self.assertRaises(legacy_runtime.StateConflictError):
                        store.claim_stage(
                            task_id,
                            "keystone",
                            "test",
                            2,
                            **stage_arguments,
                        )
                    with self.assertRaises(legacy_runtime.StateConflictError):
                        store.inspect_stage(
                            task_id,
                            "keystone",
                            "test",
                            2,
                            source_event_id=stage_arguments["source_event_id"],
                            source_message_id=source_id,
                            subject=subject,
                            payload=payload,
                        )

    def test_reconcile_rejects_cross_consumer_source_corruption(self) -> None:
        store = self._store()
        self._record_plan(store)
        store.save_candidate("task-1", "keystone", {"head_oid": "1" * 40})
        subject = "hi.myrmidon.claude.review-result.task-1"
        payload = {"task_id": "task-1", "iteration": 1}
        with store._transaction() as connection:
            source_id = store._insert_outbox(
                connection,
                "task-1",
                {"subject": subject, "payload": payload},
                "stage:keystone:review:1",
                requires_consumer_checkpoint=True,
            )
        store.claim_stage(
            "task-1",
            "keystone",
            "test",
            2,
            source_event_id="3" * 64,
            source_message_id=source_id,
            subject=subject,
            payload=payload,
            owner="stage-worker",
            lease_seconds=30,
        )
        payload_json = legacy_runtime._canonical_json(payload, "source payload")
        with store._transaction() as connection:
            connection.execute(
                "UPDATE candidates SET source_message_id = ?, source_subject = ?, "
                "source_payload_json = ?, source_payload_digest = ? "
                "WHERE namespace = ? AND task_id = 'task-1' "
                "AND repo_slug = 'keystone'",
                (
                    source_id,
                    subject,
                    payload_json,
                    hashlib.sha256(payload_json.encode()).hexdigest(),
                    store.namespace,
                ),
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.reconcile()

    def test_local_source_purpose_must_authorize_the_requested_stage(self) -> None:
        store = self._store()
        for stage, iteration, repo_slug in (
            ("implement", 1, "keystone"),
            ("review", 1, "keystone"),
            ("test", 2, "keystone"),
            ("ship-final", 0, "@odysseus-root"),
        ):
            with self.subTest(stage=stage, iteration=iteration):
                task_id = f"task-wrong-source-{stage}-{iteration}"
                store.record_plan(
                    task_id,
                    "team-1",
                    22,
                    {"keystone": self.routes["keystone"]},
                    hashlib.sha256(task_id.encode()).hexdigest(),
                )
                subject = f"hi.myrmidon.claude.{stage}.{task_id}"
                payload = {"task_id": task_id, "iteration": iteration}
                source_id = store.enqueue_outbox(
                    task_id,
                    {"subject": subject, "payload": payload},
                    purpose="route:keystone",
                )
                with self.assertRaises(legacy_runtime.StateConflictError):
                    store.claim_stage(
                        task_id,
                        repo_slug,
                        stage,
                        iteration,
                        source_event_id=legacy_runtime.stable_event_id(
                            subject,
                            stream="homeric-myrmidon",
                            message_id=source_id,
                        ),
                        source_message_id=source_id,
                        subject=subject,
                        payload=payload,
                        owner="worker",
                        lease_seconds=30,
                    )

    def test_candidate_claim_requires_an_exact_local_source_event(self) -> None:
        store = self._store()
        self._record_plan(store)
        candidate = {"tree": "2" * 40}
        store.save_candidate("task-1", "keystone", candidate)
        candidate_event = {
            "subject": "hi.myrmidon.claude.ship.keystone.task-1",
            "payload": {"task_id": "task-1", "repo_slug": "keystone"},
        }
        source_id = store.enqueue_outbox(
            "task-1", candidate_event, purpose="candidate:keystone"
        )
        for changes in (
            {"source_message_id": None},
            {"source_message_id": "not-local"},
            {"subject": f"{candidate_event['subject']}.forged"},
            {"payload": {**candidate_event["payload"], "repo_slug": "hephaestus"}},
        ):
            with self.subTest(changes=changes):
                arguments = {
                    "source_message_id": source_id,
                    "subject": candidate_event["subject"],
                    "payload": candidate_event["payload"],
                }
                arguments.update(changes)
                try:
                    with self.assertRaises(legacy_runtime.StateConflictError):
                        store.claim_candidate(
                            "task-1",
                            "keystone",
                            owner="shipper",
                            lease_seconds=30,
                            **arguments,
                        )
                except TypeError as error:
                    self.fail(f"candidate claim has no source-binding API: {error}")
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "UPDATE outbox SET consumer_checkpointed_at = 1.0 "
                "WHERE namespace = ? AND outbox_id = ?",
                (store.namespace, source_id),
            )
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.claim_candidate(
                "task-1",
                "keystone",
                owner="shipper",
                lease_seconds=30,
                source_message_id=source_id,
                subject=candidate_event["subject"],
                payload=candidate_event["payload"],
            )
        with closing(sqlite3.connect(store.database)) as connection, connection:
            connection.execute(
                "UPDATE outbox SET consumer_checkpointed_at = NULL "
                "WHERE namespace = ? AND outbox_id = ?",
                (store.namespace, source_id),
            )
        try:
            claim = store.claim_candidate(
                "task-1",
                "keystone",
                owner="shipper",
                lease_seconds=30,
                source_message_id=source_id,
                subject=candidate_event["subject"],
                payload=candidate_event["payload"],
            )
        except TypeError as error:
            self.fail(f"candidate claim has no source-binding API: {error}")
        self.assertEqual(claim["candidate"], candidate)

    def test_candidate_preflight_validates_terminal_ship_redelivery(self) -> None:
        store = self._store()
        self._record_plan(store)
        candidate = {"tree": "2" * 40}
        store.save_candidate("task-1", "keystone", candidate)
        candidate_event = {
            "subject": "hi.myrmidon.claude.ship.keystone.task-1",
            "payload": {"task_id": "task-1", "repo_slug": "keystone"},
        }
        source_id = store.enqueue_outbox(
            "task-1", candidate_event, purpose="candidate:keystone"
        )
        self.assertIsNone(
            store.inspect_candidate(
                "task-1",
                "keystone",
                source_message_id=source_id,
                subject=candidate_event["subject"],
                payload=candidate_event["payload"],
            )
        )
        claim = store.claim_candidate(
            "task-1",
            "keystone",
            owner="shipper",
            lease_seconds=30,
            source_message_id=source_id,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        self.assertTrue(
            store.release_claim(
                "task-1",
                "keystone",
                owner="shipper",
                claim_token=claim["claim_token"],
            )
        )
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": "task-1"},
        }
        store.terminate_task(
            "task-1",
            status="human-blocked",
            terminal=terminal,
            outbox=(
                {
                    "subject": "hi.tasks.team-1.task-1.human-blocked",
                    "payload": terminal,
                },
            ),
        )
        inspected = store.inspect_candidate(
            "task-1",
            "keystone",
            source_message_id=source_id,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        self.assertEqual(inspected["state"], "terminal")
        self.assertEqual(inspected["terminal_status"], "human-blocked")
        self.assertEqual(inspected["candidate"], candidate)

        for changes in (
            {"source_message_id": "not-local"},
            {"subject": f"{candidate_event['subject']}.changed"},
            {"payload": {**candidate_event["payload"], "repo_slug": "hephaestus"}},
        ):
            with self.subTest(changes=changes), self.assertRaises(
                legacy_runtime.StateConflictError
            ):
                arguments = {
                    "source_message_id": source_id,
                    "subject": candidate_event["subject"],
                    "payload": candidate_event["payload"],
                }
                arguments.update(changes)
                store.inspect_candidate(
                    "task-1",
                    "keystone",
                    **arguments,
                )

    def test_candidate_preflight_drains_unclaimed_ship_after_terminal(self) -> None:
        store = self._store()
        self._record_plan(store)
        candidate = {"tree": "3" * 40}
        store.save_candidate("task-1", "keystone", candidate)
        source_id, candidate_event = self._candidate_source(
            store, "task-1", "keystone"
        )
        terminal = {
            "event": "task.human-blocked",
            "data": {"task_id": "task-1"},
        }
        store.terminate_task(
            "task-1",
            status="human-blocked",
            terminal=terminal,
            outbox=(
                {
                    "subject": "hi.tasks.team-1.task-1.human-blocked",
                    "payload": terminal,
                },
            ),
        )

        inspected = store.inspect_candidate(
            "task-1",
            "keystone",
            source_message_id=source_id,
            subject=candidate_event["subject"],
            payload=candidate_event["payload"],
        )
        self.assertEqual(inspected["state"], "terminal")
        self.assertEqual(inspected["candidate"], candidate)
        with self.assertRaises(legacy_runtime.StateConflictError):
            store.inspect_candidate(
                "task-1",
                "keystone",
                source_message_id="not-local",
                subject=candidate_event["subject"],
                payload=candidate_event["payload"],
            )


@unittest.skipUnless(
    sys.platform.startswith("linux"),
    "canonical host leases require Linux abstract Unix sockets",
)
class FileLeaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.service_uid_environment = patch.dict(
            os.environ,
            {
                "HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid()),
                "HOMERIC_LEGACY_CANDIDATE_UID": str(_TEST_CANDIDATE_UID),
            },
        )
        self.service_uid_environment.start()
        self.tempdir = tempfile.TemporaryDirectory()
        self.root = Path(self.tempdir.name) / "repo"
        self.host_lock_root = (
            Path(self.tempdir.name).resolve(strict=True) / "host-locks"
        )
        _init_repo(self.root)

    def tearDown(self) -> None:
        self.tempdir.cleanup()
        self.service_uid_environment.stop()

    def test_host_wide_heavy_limit_is_three_across_processes(self) -> None:
        context = multiprocessing.get_context("spawn")
        other = Path(self.tempdir.name) / "other-repo"
        _init_repo(other)
        release = context.Event()
        acquired = [context.Event() for _ in range(3)]
        workdirs = (self.root, self.root, other)
        processes = [
            context.Process(
                target=_hold_heavy_slot,
                args=(
                    str(workdirs[index]),
                    str(self.host_lock_root),
                    os.geteuid(),
                    acquired[index],
                    release,
                ),
            )
            for index in range(3)
        ]
        try:
            for process in processes:
                process.start()
            for event in acquired:
                self.assertTrue(event.wait(10), "a heavy slot holder did not start")
            with self.assertRaises(legacy_runtime.LeaseUnavailableError):
                with legacy_runtime.heavy_slot(
                    other,
                    max_slots=3,
                    timeout=0.2,
                    host_lock_root=self.host_lock_root,
                    service_uid=os.geteuid(),
                ):
                    self.fail("a fourth host-wide heavy slot must not be granted")
        finally:
            release.set()
            for process in processes:
                process.join(10)
                if process.is_alive():
                    process.terminate()
                    process.join(5)
        self.assertTrue(all(process.exitcode == 0 for process in processes))

        with legacy_runtime.heavy_slot(
            self.root,
            max_slots=3,
            timeout=1,
            host_lock_root=self.host_lock_root,
            service_uid=os.geteuid(),
        ) as slot:
            self.assertIn(slot, (0, 1, 2))
        with self.assertRaises(ValueError):
            with legacy_runtime.heavy_slot(
                self.root,
                max_slots=4,
                timeout=0,
                host_lock_root=self.host_lock_root,
                service_uid=os.geteuid(),
            ):
                pass

    def test_lock_creation_recovers_when_another_process_wins(self) -> None:
        """Concurrent first-use creates one shared descriptor-bound lock file."""
        with legacy_runtime._lock_directory(
            self.root,
            "heavy",
            host_lock_root=self.host_lock_root,
            service_uid=os.geteuid(),
        ) as directory:
            real_open = os.open
            attempts: list[int] = []

            def concurrent_create(path, flags, mode=0o777, *, dir_fd=None):
                if path != "slot-0.lock":
                    return real_open(path, flags, mode, dir_fd=dir_fd)
                attempts.append(flags)
                if len(attempts) == 1:
                    raise FileNotFoundError(2, "not found", path)
                if len(attempts) == 2:
                    competitor = real_open(
                        path,
                        flags,
                        mode,
                        dir_fd=dir_fd,
                    )
                    os.close(competitor)
                    raise FileExistsError(17, "already exists", path)
                return real_open(path, flags, mode, dir_fd=dir_fd)

            with patch.object(
                legacy_runtime.os, "open", side_effect=concurrent_create
            ):
                descriptor = None
                open_error = None
                try:
                    descriptor = legacy_runtime._open_lock(
                        directory, "slot-0.lock"
                    )
                except OSError as error:
                    open_error = error
            if descriptor is not None:
                os.close(descriptor)

        self.assertIsNone(open_error)
        self.assertIsNotNone(descriptor)
        self.assertEqual(len(attempts), 3)
        self.assertFalse(attempts[0] & os.O_CREAT)
        self.assertTrue(attempts[1] & os.O_CREAT)
        self.assertTrue(attempts[1] & os.O_EXCL)
        self.assertFalse(attempts[2] & os.O_CREAT)

    def test_lease_fails_closed_when_namespace_changes_after_flock(self) -> None:
        """A lock acquired from a replaced namespace cannot enter the lease body."""
        real_flock = legacy_runtime.fcntl.flock
        held_root = self.host_lock_root.with_name("host-locks-held")
        swapped = False
        entered = False

        def swap_after_acquire(descriptor, operation):
            nonlocal swapped
            result = real_flock(descriptor, operation)
            if (
                not swapped
                and operation & legacy_runtime.fcntl.LOCK_EX
                and not operation & legacy_runtime.fcntl.LOCK_UN
            ):
                swapped = True
                self.host_lock_root.rename(held_root)
                replacement = self.host_lock_root / "locks" / "heavy"
                replacement.mkdir(parents=True, mode=0o700)
                self.host_lock_root.chmod(0o700)
                (self.host_lock_root / "locks").chmod(0o700)
                replacement.chmod(0o700)
            return result

        with patch.object(
            legacy_runtime.fcntl, "flock", side_effect=swap_after_acquire
        ), self.assertRaises(legacy_runtime.StateLocationError):
            with legacy_runtime.heavy_slot(
                self.root,
                max_slots=1,
                timeout=0,
                host_lock_root=self.host_lock_root,
                service_uid=os.geteuid(),
            ):
                entered = True

        self.assertTrue(swapped)
        self.assertFalse(entered)
        descriptor = os.open(
            held_root / "locks" / "heavy" / "slot-0.lock", os.O_RDWR
        )
        try:
            real_flock(
                descriptor,
                legacy_runtime.fcntl.LOCK_EX | legacy_runtime.fcntl.LOCK_NB,
            )
        finally:
            os.close(descriptor)

    def test_lease_fails_closed_when_lock_leaf_changes_after_flock(self) -> None:
        """A replaced lock file cannot enter the lease body after acquisition."""
        real_flock = legacy_runtime.fcntl.flock
        lock_directory = self.host_lock_root / "locks" / "heavy"
        held_lock = lock_directory / "slot-0-held.lock"
        replacement_lock = lock_directory / "slot-0.lock"
        swapped = False
        entered = False

        def swap_after_acquire(descriptor, operation):
            nonlocal swapped
            result = real_flock(descriptor, operation)
            if (
                not swapped
                and operation & legacy_runtime.fcntl.LOCK_EX
                and not operation & legacy_runtime.fcntl.LOCK_UN
            ):
                swapped = True
                replacement_lock.rename(held_lock)
                replacement_lock.touch(mode=0o600)
                replacement_lock.chmod(0o600)
            return result

        with patch.object(
            legacy_runtime.fcntl, "flock", side_effect=swap_after_acquire
        ), self.assertRaises(legacy_runtime.StateLocationError):
            with legacy_runtime.heavy_slot(
                self.root,
                max_slots=1,
                timeout=0,
                host_lock_root=self.host_lock_root,
                service_uid=os.geteuid(),
            ):
                entered = True

        self.assertTrue(swapped)
        self.assertFalse(entered)
        for lock_path in (held_lock, replacement_lock):
            descriptor = os.open(lock_path, os.O_RDWR)
            try:
                real_flock(
                    descriptor,
                    legacy_runtime.fcntl.LOCK_EX | legacy_runtime.fcntl.LOCK_NB,
                )
            finally:
                os.close(descriptor)

    def test_post_entry_namespace_swap_cannot_create_a_second_authority(self) -> None:
        held_root = self.host_lock_root.with_name("host-locks-held-after-entry")
        with legacy_runtime.heavy_slot(
            self.root,
            max_slots=1,
            timeout=0,
            host_lock_root=self.host_lock_root,
            service_uid=os.geteuid(),
        ):
            self.host_lock_root.rename(held_root)
            replacement = self.host_lock_root / "locks" / "heavy"
            replacement.mkdir(parents=True, mode=0o700)
            self.host_lock_root.chmod(0o700)
            (self.host_lock_root / "locks").chmod(0o700)
            replacement.chmod(0o700)
            with self.assertRaises(legacy_runtime.LeaseUnavailableError):
                with legacy_runtime.heavy_slot(
                    self.root,
                    max_slots=1,
                    timeout=0.05,
                    host_lock_root=self.host_lock_root,
                    service_uid=os.geteuid(),
                ):
                    pass

    def test_baseexception_during_acquisition_releases_descriptor_and_flock(
        self,
    ) -> None:
        for index, exception in enumerate((KeyboardInterrupt(), SystemExit(73))):
            with self.subTest(exception=type(exception).__name__):
                lock_root = (
                    Path(self.tempdir.name).resolve(strict=True)
                    / f"interrupt-locks-{index}"
                )
                real_verify = legacy_runtime._verify_lock_file
                calls = 0

                def interrupt_after_flock(directory, filename, descriptor):
                    nonlocal calls
                    calls += 1
                    real_verify(directory, filename, descriptor)
                    if calls == 2:
                        raise exception

                observed: BaseException | None = None
                try:
                    with patch.object(
                        legacy_runtime,
                        "_verify_lock_file",
                        side_effect=interrupt_after_flock,
                    ):
                        with legacy_runtime.heavy_slot(
                            self.root,
                            max_slots=1,
                            timeout=0,
                            host_lock_root=lock_root,
                            service_uid=os.geteuid(),
                        ):
                            pass
                except BaseException as error:
                    observed = error
                self.assertIsInstance(observed, type(exception))

                reacquire_error: BaseException | None = None
                try:
                    with legacy_runtime.heavy_slot(
                        self.root,
                        max_slots=1,
                        timeout=0.05,
                        host_lock_root=lock_root,
                        service_uid=os.geteuid(),
                    ):
                        pass
                except BaseException as error:
                    reacquire_error = error
                self.assertIsNone(reacquire_error)

    def test_service_uid_is_explicit_and_one_namespace_is_shared_by_all_clones(
        self,
    ) -> None:
        service_uid = os.geteuid()
        other = Path(self.tempdir.name) / "other-service-repo"
        _init_repo(other)
        with legacy_runtime._lock_directory(
            self.root,
            "heavy",
            host_lock_root=self.host_lock_root,
            service_uid=service_uid,
        ) as first, legacy_runtime._lock_directory(
            other,
            "heavy",
            host_lock_root=self.host_lock_root,
            service_uid=service_uid,
        ) as second:
            self.assertEqual(first.path, second.path)
            self.assertEqual(first.identity, second.identity)
            self.assertEqual(
                first.path, self.host_lock_root / "locks" / "heavy"
            )

        with patch.object(legacy_runtime.os, "geteuid", return_value=service_uid + 1):
            with self.assertRaises(legacy_runtime.HostBindingError):
                with legacy_runtime.heavy_slot(
                    self.root,
                    max_slots=3,
                    timeout=0,
                    host_lock_root=self.host_lock_root,
                    service_uid=service_uid,
                ):
                    pass

        boundary_cases = (
            {"HOMERIC_LEGACY_SERVICE_UID": str(service_uid)},
            {
                "HOMERIC_LEGACY_SERVICE_UID": str(service_uid),
                "HOMERIC_LEGACY_CANDIDATE_UID": str(service_uid),
            },
        )
        for environment in boundary_cases:
            with self.subTest(environment=environment), patch.dict(
                os.environ, environment, clear=True
            ), self.assertRaises(legacy_runtime.HostBindingError):
                with legacy_runtime.heavy_slot(
                    self.root,
                    max_slots=1,
                    timeout=0,
                    host_lock_root=self.host_lock_root,
                    service_uid=service_uid,
                ):
                    pass

        with self.assertRaises(TypeError):
            legacy_runtime.runtime_store(
                self.root,
                "HomericIntelligence/Odysseus",
                "a" * 64,
                host_id="host-a",
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )
        with self.assertRaises(legacy_runtime.HostBindingError):
            legacy_runtime.runtime_store(
                self.root,
                "HomericIntelligence/Odysseus",
                "a" * 64,
                host_id="host-a",
                service_uid=service_uid + 1,
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
            )
        if not legacy_runtime._descriptor_sqlite_route_supported():
            with self.assertRaises(legacy_runtime.StateLocationError):
                legacy_runtime.runtime_store(
                    self.root,
                    "HomericIntelligence/Odysseus",
                    "a" * 64,
                    host_id="host-a",
                    service_uid=service_uid,
                    message_retention_seconds=3600,
                    duplicate_window_seconds=120,
                )
            return
        bound = legacy_runtime.runtime_store(
            self.root,
            "HomericIntelligence/Odysseus",
            "a" * 64,
            host_id="host-a",
            service_uid=service_uid,
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
        )
        with patch.dict(os.environ, {}, clear=True), self.assertRaises(
            legacy_runtime.HostBindingError
        ):
            legacy_runtime.RuntimeStore(
                bound.database,
                "HomericIntelligence/Odysseus",
                "a" * 64,
                host_id="host-a",
                service_uid=service_uid,
                message_retention_seconds=3600,
                duplicate_window_seconds=120,
                clock=time.time,
            )

    def test_checkout_lane_is_serial_and_os_releases_it_after_worker_crash(self) -> None:
        context = multiprocessing.get_context("spawn")
        acquired = context.Event()
        holder = context.Process(
            target=_hold_checkout_lane,
            args=(
                str(self.root),
                str(self.root),
                str(self.host_lock_root),
                os.geteuid(),
                acquired,
            ),
        )
        holder.start()
        try:
            self.assertTrue(acquired.wait(10), "checkout lane holder did not start")
            with self.assertRaises(legacy_runtime.LeaseUnavailableError):
                with legacy_runtime.checkout_lane(
                    self.root,
                    self.root,
                    timeout=0.2,
                    host_lock_root=self.host_lock_root,
                    service_uid=os.geteuid(),
                ):
                    self.fail("the checkout lane must serialize writers")
        finally:
            holder.terminate()
            holder.join(5)
        self.assertFalse(holder.is_alive())

        with legacy_runtime.checkout_lane(
            self.root,
            self.root,
            timeout=1,
            host_lock_root=self.host_lock_root,
            service_uid=os.geteuid(),
        ):
            pass

    def test_checkout_replacement_keeps_one_lane_and_retained_operator_path(
        self,
    ) -> None:
        requested = self.root.resolve(strict=True)
        held = requested.with_name(f"{requested.name}-held")

        with legacy_runtime.checkout_lane(
            self.root,
            requested,
            timeout=1,
            host_lock_root=self.host_lock_root,
            service_uid=os.geteuid(),
        ) as retained:
            self.assertIsInstance(retained, str)
            self.assertTrue(Path(retained).is_absolute())
            self.assertTrue(retained.startswith(f"/proc/{os.getpid()}/fd/"))
            requested.rename(held)
            _init_repo(requested)

            self.assertEqual(
                (Path(retained) / "README.md").read_text(encoding="utf-8"),
                "fixture\n",
            )

            def acquire_replacement() -> bool:
                with legacy_runtime.checkout_lane(
                    requested,
                    requested,
                    timeout=0.1,
                    host_lock_root=self.host_lock_root,
                    service_uid=os.geteuid(),
                ):
                    return True

            with ThreadPoolExecutor(max_workers=1) as executor:
                contender = executor.submit(acquire_replacement)
                with self.assertRaises(legacy_runtime.LeaseUnavailableError):
                    contender.result(timeout=2)

            self.assertEqual(
                (Path(retained) / "README.md").read_text(encoding="utf-8"),
                "fixture\n",
            )

    def test_lock_namespace_fails_closed_when_an_ancestor_is_replaced(self) -> None:
        checkout_key = hashlib.sha256(
            f"path\0{self.root.resolve(strict=True)}".encode()
        ).hexdigest()
        cases = (
            (
                "heavy",
                lambda: legacy_runtime.heavy_slot(
                    self.root,
                    max_slots=1,
                    timeout=0,
                    host_lock_root=self.host_lock_root,
                    service_uid=os.geteuid(),
                ),
                "slot-0.lock",
            ),
            (
                "checkouts",
                lambda: legacy_runtime.checkout_lane(
                    self.root,
                    self.root,
                    timeout=0,
                    host_lock_root=self.host_lock_root,
                    service_uid=os.geteuid(),
                ),
                f"{checkout_key}.lock",
            ),
        )
        for namespace, manager, lock_name in cases:
            with self.subTest(namespace=namespace):
                if self.host_lock_root.exists():
                    for path in sorted(
                        self.host_lock_root.rglob("*"), reverse=True
                    ):
                        if path.is_file() or path.is_symlink():
                            path.unlink()
                        else:
                            path.rmdir()
                    self.host_lock_root.rmdir()
                real_open = os.open
                held_root = self.host_lock_root.with_name(
                    f"{self.host_lock_root.name}-{namespace}-held"
                )
                swapped = False

                def swap_before_lock(path, flags, mode=0o777, *, dir_fd=None):
                    nonlocal swapped
                    if not swapped and str(path).endswith(".lock"):
                        swapped = True
                        self.host_lock_root.rename(held_root)
                        replacement = self.host_lock_root / "locks" / namespace
                        replacement.mkdir(parents=True, mode=0o700)
                        self.host_lock_root.chmod(0o700)
                        (self.host_lock_root / "locks").chmod(0o700)
                        replacement.chmod(0o700)
                    return real_open(path, flags, mode, dir_fd=dir_fd)

                with patch.object(legacy_runtime.os, "open", side_effect=swap_before_lock):
                    with self.assertRaises(legacy_runtime.StateLocationError):
                        with manager():
                            pass
                self.assertTrue(swapped)
                self.assertFalse(
                    (self.host_lock_root / "locks" / namespace / lock_name).exists()
                )
                self.assertTrue(
                    (held_root / "locks" / namespace / lock_name).exists()
                )


class _Message:
    def __init__(
        self,
        value: int,
        *,
        failures: set[str] | None = None,
        hangs: set[str] | None = None,
    ) -> None:
        self.value = value
        self.failures = failures or set()
        self.hangs = hangs or set()
        self.heartbeats = 0
        self.acks = 0
        self.naks = 0
        self.nak_delays: list[float | None] = []
        self.terms = 0

    async def _outcome(self, operation: str) -> None:
        if operation in self.hangs:
            await asyncio.Event().wait()
        if operation in self.failures:
            raise RuntimeError(f"{operation} failed")

    async def in_progress(self) -> None:
        self.heartbeats += 1
        await self._outcome("heartbeat")

    async def ack(self) -> None:
        self.acks += 1
        await self._outcome("ack")

    async def nak(self, *, delay: float | None = None) -> None:
        self.naks += 1
        self.nak_delays.append(delay)
        await self._outcome("nak")

    async def term(self) -> None:
        self.terms += 1
        await self._outcome("term")


class _Subscription:
    def __init__(self, messages: list[_Message]) -> None:
        self._queue = asyncio.Queue()
        for message in messages:
            self._queue.put_nowait(message)

    async def fetch(self, *, batch: int, timeout: float) -> list[_Message]:
        self.asserted_batch = batch
        try:
            message = await asyncio.wait_for(self._queue.get(), timeout=timeout)
        except TimeoutError:
            return []
        return [message]


class _RecordingExtinctionSupervisor:
    def __init__(self) -> None:
        self.reasons: list[str] = []

    async def extinguish_and_terminate(self, reason: str) -> None:
        self.reasons.append(reason)
        raise SystemExit(70)


class ConsumerWorkerTest(unittest.IsolatedAsyncioTestCase):
    async def test_nonpersistent_cancellation_waits_for_handler_cleanup_before_nak(self):
        entered, cleanup_done, release = asyncio.Event(), asyncio.Event(), asyncio.Event()
        message = _Message(1)
        async def handler(_message):
            entered.set()
            await release.wait()
            cleanup_done.set()
        dispatch = asyncio.create_task(legacy_runtime._dispatch_with_heartbeat(
            message, handler, 0.01, 0.1, 0.1,
            delivery_authority=legacy_runtime.NonpersistentDispatchAuthority(),
        ))
        await asyncio.wait_for(entered.wait(), 1)
        dispatch.cancel()
        self.assertEqual((message.acks, message.naks), (0, 0))
        self.assertFalse(dispatch.done())
        release.set()
        with self.assertRaises(asyncio.CancelledError):
            await dispatch
        self.assertEqual((message.acks, message.naks), (0, 1))
        self.assertTrue(cleanup_done.is_set())

    async def test_nonpersistent_dispatch_preserves_dispositions_and_rejects_effects(self):
        authority_type = getattr(legacy_runtime, "NonpersistentDispatchAuthority", None)
        self.assertTrue(callable(authority_type), "dry-run needs explicit nonpersistent authority")
        for failure, expected in ((None, (1, 0, 0)),
                                  (legacy_runtime.RejectMessage("poison"), (0, 0, 1)),
                                  (legacy_runtime.RetryMessage("retry"), (0, 1, 0))):
            message = _Message(1)
            async def handler(_message):
                if failure is not None:
                    raise failure
            await legacy_runtime._dispatch_with_heartbeat(
                message, handler, 0.01, 0.1, 0.1,
                delivery_authority=authority_type(),
            )
            self.assertEqual((message.acks, message.naks, message.terms), expected)

        supervisor = legacy_runtime.WorkerExtinctionSupervisor()
        observed = []
        async def attempted_effect(_message):
            with self.assertRaises(legacy_runtime.WorkerContainmentFatalError):
                supervisor._register_external_effect(object())
            observed.append("refused")
        message = _Message(1)
        await legacy_runtime._dispatch_with_heartbeat(
            message, attempted_effect, 0.01, 0.1, 0.1,
            extinction_supervisor=supervisor, delivery_authority=authority_type(),
        )
        self.assertEqual(observed, ["refused"])
        self.assertFalse(supervisor._external_effects)

    async def test_workers_dispatch_concurrently_with_in_progress_heartbeats(self) -> None:
        messages = [_Message(index) for index in range(6)]
        subscription = _Subscription(messages)
        stop = asyncio.Event()
        active = 0
        maximum_active = 0
        completed = 0
        lock = asyncio.Lock()

        async def handler(message: _Message) -> None:
            nonlocal active, maximum_active, completed
            async with lock:
                active += 1
                maximum_active = max(maximum_active, active)
            await asyncio.sleep(0.04)
            async with lock:
                active -= 1
                completed += 1
                if completed == len(messages):
                    stop.set()

        await asyncio.wait_for(
            legacy_runtime.run_consumer_workers(
                subscription,
                handler,
                max_workers=3,
                heartbeat_seconds=0.01,
                fetch_timeout=0.01,
                stop_event=stop,
            ),
            timeout=3,
        )
        self.assertEqual(maximum_active, 3)
        self.assertTrue(all(message.acks == 1 for message in messages))
        self.assertTrue(all(message.naks == 0 for message in messages))
        self.assertTrue(all(message.heartbeats >= 2 for message in messages))

    async def test_failure_naks_for_redelivery_and_rejection_terminates(self) -> None:
        retry = _Message(1)
        stop_retry = asyncio.Event()

        async def fail(_message: _Message) -> None:
            stop_retry.set()
            raise RuntimeError("crash")

        with self.assertRaises(legacy_runtime.ConsumerHandlerError):
            await legacy_runtime.run_consumer_workers(
                _Subscription([retry]),
                fail,
                max_workers=1,
                heartbeat_seconds=0.01,
                fetch_timeout=0.01,
                stop_event=stop_retry,
            )
        self.assertEqual(retry.naks, 1)
        self.assertEqual(retry.acks, 0)

        rejected = _Message(2)
        stop_reject = asyncio.Event()

        async def reject(_message: _Message) -> None:
            stop_reject.set()
            raise legacy_runtime.RejectMessage("malformed")

        await legacy_runtime.run_consumer_workers(
            _Subscription([rejected]),
            reject,
            max_workers=1,
            heartbeat_seconds=0.01,
            fetch_timeout=0.01,
            stop_event=stop_reject,
        )
        self.assertEqual(rejected.terms, 1)
        self.assertEqual(rejected.naks, 0)

    async def test_message_error_taxonomy_controls_broker_disposition(self) -> None:
        for error, expected_terms, expected_nak_delays in (
            (legacy_runtime.PermanentMessageError("invalid route"), 1, []),
            (
                legacy_runtime.TransientMessageError("temporary contention"),
                0,
                [30.0],
            ),
        ):
            message = _Message(1)
            stop = asyncio.Event()

            async def handler(_message: _Message, failure=error) -> None:
                stop.set()
                raise failure

            with self.subTest(error=type(error).__name__):
                await legacy_runtime.run_consumer_workers(
                    _Subscription([message]),
                    handler,
                    max_workers=1,
                    heartbeat_seconds=0.01,
                    fetch_timeout=0.01,
                    stop_event=stop,
                )
            self.assertEqual(message.terms, expected_terms)
            self.assertEqual(message.nak_delays, expected_nak_delays)
            self.assertEqual(message.acks, 0)

    async def test_out_of_domain_iteration_terminates_and_peer_progresses(self) -> None:
        poison = _Message(legacy_runtime.MAX_ITERATION + 1)
        valid = _Message(1)
        stop = asyncio.Event()

        async def handler(message: _Message) -> None:
            legacy_runtime.validate_message_iteration(message.value)
            stop.set()

        await asyncio.wait_for(
            legacy_runtime.run_consumer_workers(
                _Subscription([poison, valid]),
                handler,
                max_workers=1,
                heartbeat_seconds=0.01,
                fetch_timeout=0.01,
                stop_event=stop,
            ),
            timeout=3,
        )

        self.assertEqual(poison.terms, 1)
        self.assertEqual(poison.naks, 0)
        self.assertEqual(poison.acks, 0)
        self.assertEqual(valid.acks, 1)
        self.assertEqual(valid.naks, 0)
        self.assertEqual(valid.terms, 0)

    async def test_success_with_live_request_effect_enters_extinction_not_ack(self) -> None:
        class TerminalExtinction(BaseException):
            pass

        class Supervisor(legacy_runtime.WorkerExtinctionSupervisor):
            def __init__(self) -> None:
                super().__init__()
                self.reasons: list[str] = []

            async def extinguish_and_terminate(self, reason: str) -> None:
                self.reasons.append(reason)
                raise TerminalExtinction

        message = _Message(1)
        supervisor = Supervisor()
        effect = object()

        async def leak_effect(_message: _Message) -> None:
            supervisor._register_external_effect(effect)

        with self.assertRaises(TerminalExtinction):
            await legacy_runtime._dispatch_with_heartbeat(
                message,
                leak_effect,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )

        self.assertEqual(len(supervisor.reasons), 1)
        self.assertIn("request effects remained live", supervisor.reasons[0])
        self.assertEqual(message.acks, 0)
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.terms, 0)

    async def test_inherited_child_cannot_register_effect_after_handler_return(self) -> None:
        class Supervisor(legacy_runtime.WorkerExtinctionSupervisor):
            async def extinguish_and_terminate(self, reason: str) -> None:
                raise AssertionError(reason)

        ack_started = asyncio.Event()

        class BlockingAckMessage(_Message):
            async def ack(self) -> None:
                self.acks += 1
                ack_started.set()
                await asyncio.sleep(0)

        message = BlockingAckMessage(1)
        supervisor = Supervisor()
        effect = object()
        late_result: list[BaseException | None] = []
        child: asyncio.Task[None] | None = None

        async def late_registration() -> None:
            await ack_started.wait()
            try:
                supervisor._register_external_effect(effect)
            except BaseException as error:
                late_result.append(error)
            else:
                late_result.append(None)

        async def spawn_late_child(_message: _Message) -> None:
            nonlocal child
            child = asyncio.create_task(late_registration())

        await legacy_runtime._dispatch_with_heartbeat(
            message,
            spawn_late_child,
            heartbeat_seconds=0.01,
            heartbeat_rpc_timeout=0.01,
            disposition_timeout=0.01,
            extinction_supervisor=supervisor,
        )
        self.assertIsNotNone(child)
        await child

        self.assertEqual(message.acks, 1)
        self.assertEqual(len(late_result), 1)
        self.assertIsInstance(
            late_result[0], legacy_runtime.WorkerContainmentFatalError
        )
        self.assertNotIn(effect, supervisor._external_effects)

    async def test_request_quiescence_ignores_another_concurrent_effect(
        self,
    ) -> None:
        class Supervisor(legacy_runtime.WorkerExtinctionSupervisor):
            async def extinguish_and_terminate(self, reason: str) -> None:
                raise AssertionError(reason)

        supervisor = Supervisor()
        registered = asyncio.Event()
        release = asyncio.Event()
        holder_message = _Message(1)
        clean_message = _Message(2)
        effect = object()

        async def hold_effect(_message: _Message) -> None:
            supervisor._register_external_effect(effect)
            registered.set()
            try:
                await release.wait()
            finally:
                supervisor._unregister_external_effect(effect)

        async def clean(_message: _Message) -> None:
            return None

        holder = asyncio.create_task(
            legacy_runtime._dispatch_with_heartbeat(
                holder_message,
                hold_effect,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        )
        try:
            await asyncio.wait_for(registered.wait(), timeout=1)
            await legacy_runtime._dispatch_with_heartbeat(
                clean_message,
                clean,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
            self.assertEqual(
                (clean_message.acks, clean_message.naks, clean_message.terms),
                (1, 0, 0),
            )
            self.assertEqual(holder_message.acks, 0)
            self.assertIn(effect, supervisor._external_effects)
        finally:
            release.set()
            await asyncio.wait_for(holder, timeout=1)
        self.assertEqual(holder_message.acks, 1)

    async def test_abrupt_owner_guard_blocks_then_allows_exact_redelivery(
        self,
    ) -> None:
        class DurableExclusion:
            def __init__(self) -> None:
                self.claims: dict[str, str] = {}
                self.counter = 0
                self.releases: list[tuple[str, int]] = []

            def claim_message_delivery(self, source_event_id: str) -> str | None:
                if source_event_id in self.claims:
                    return None
                self.counter += 1
                token = f"{self.counter:064x}"
                self.claims[source_event_id] = token
                return token

            def release_message_delivery(
                self, source_event_id: str, claim_token: str
            ) -> None:
                if self.claims.get(source_event_id) != claim_token:
                    raise AssertionError("delivery guard changed")
                self.releases.append((claim_token, duplicate.acks))
                del self.claims[source_event_id]

        source_event_id = "e" * 64
        exclusion = DurableExclusion()
        # Model an earlier process dying abruptly while its external effect is
        # still live: the durable claim survives, but its Python task does not.
        abandoned_token = exclusion.claim_message_delivery(source_event_id)
        self.assertIsNotNone(abandoned_token)
        duplicate = _Message(1)
        handler_calls = 0

        async def handler(_message: _Message) -> None:
            nonlocal handler_calls
            handler_calls += 1

        dispatch = asyncio.create_task(
            legacy_runtime._dispatch_with_heartbeat(
                duplicate,
                handler,
                heartbeat_seconds=0.005,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                redelivery_exclusion=exclusion,
                message_identity=lambda _message: source_event_id,
            )
        )
        for _attempt in range(100):
            if duplicate.heartbeats >= 2:
                break
            await asyncio.sleep(0.005)
        self.assertGreaterEqual(duplicate.heartbeats, 2)
        self.assertEqual(handler_calls, 0)
        self.assertEqual(duplicate.acks, 0)
        self.assertEqual(duplicate.naks, 0)
        self.assertEqual(duplicate.terms, 0)

        exclusion.release_message_delivery(source_event_id, abandoned_token)
        await asyncio.wait_for(dispatch, timeout=1)
        self.assertEqual(handler_calls, 1)
        self.assertEqual(duplicate.acks, 1)
        self.assertEqual(duplicate.naks, 0)
        self.assertEqual(duplicate.terms, 0)
        self.assertEqual(exclusion.claims, {})
        self.assertEqual(
            exclusion.releases,
            [(abandoned_token, 0), (f"{2:064x}", 1)],
        )

    async def test_dead_owner_effect_is_reconciled_before_takeover_and_ack(
        self,
    ) -> None:
        source_event_id = "e" * 64
        prior_token = "1" * 64
        replacement_token = "2" * 64
        receipt = legacy_runtime.ExternalEffectReceipt(
            effect_token="3" * 64,
            source_event_id=source_event_id,
            effect_kind="pod-infra-relay",
            authority={
                "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                "invocation_token": "4" * 64,
            },
            binding={
                "infra_pid": 4242,
                "netns_dev": 7,
                "netns_ino": 8,
                "pod_id": "5" * 64,
                "relay_pid": 4343,
            },
        )
        events: list[str] = []

        class Lease:
            closed = False

            def close(self) -> None:
                self.closed = True
                events.append("lease-close")

        lease = Lease()

        class Store:
            def __init__(self) -> None:
                self.effects = [receipt]
                self.claim = prior_token

            def acquire_message_delivery_lease(self, event, *, timeout):
                self.assert_event(event)
                events.append("lease")
                return lease

            def inspect_message_delivery(self, event):
                self.assert_event(event)
                return self.claim

            def active_external_effects(self, event):
                self.assert_event(event)
                return tuple(self.effects)

            def retire_external_effect(self, event, claim, effect):
                self.assert_event(event)
                self_outer.assertEqual(claim, prior_token)
                self_outer.assertEqual(effect, receipt.effect_token)
                events.append("effect-retire")
                self.effects.clear()

            def take_over_message_delivery(self, event, claim):
                self.assert_event(event)
                self_outer.assertEqual(claim, prior_token)
                self_outer.assertEqual(self.effects, [])
                events.append("takeover")
                self.claim = replacement_token
                return replacement_token

            def claim_message_delivery(self, event):
                raise AssertionError("stale guard must use takeover")

            def release_message_delivery(self, event, claim):
                self.assert_event(event)
                self_outer.assertEqual(claim, replacement_token)
                self_outer.assertEqual(message.acks, 1)
                events.append("guard-retire")
                self.claim = None

            def assert_event(self, event):
                self_outer.assertEqual(event, source_event_id)

        self_outer = self
        store = Store()
        message = _Message(1)

        async def reconcile(observed):
            self.assertEqual(observed, receipt)
            events.append("effect-proof")
            return legacy_runtime.external_effect_extinction_proof(
                receipt,
                _TEST_ENGINE_ENDPOINT_IDENTITY,
            )

        async def handler(_message):
            context = legacy_runtime._CURRENT_DURABLE_DELIVERY.get()
            self.assertIsNotNone(context)
            self.assertEqual(context.claim_token, replacement_token)
            events.append("handler")

        await legacy_runtime._dispatch_with_heartbeat(
            message,
            handler,
            heartbeat_seconds=0.01,
            heartbeat_rpc_timeout=0.01,
            disposition_timeout=0.01,
            delivery_authority=legacy_runtime.DurableDispatchAuthority(
                store=store,
                identify=lambda _message: source_event_id,
                reconcile=reconcile,
            ),
        )

        self.assertEqual((message.acks, message.naks, message.terms), (1, 0, 0))
        self.assertEqual(
            events,
            [
                "lease",
                "effect-proof",
                "effect-retire",
                "takeover",
                "handler",
                "guard-retire",
                "lease-close",
            ],
        )

    async def test_dead_owner_reconcile_refuses_changed_engine_identity(
        self,
    ) -> None:
        source_event_id = "e" * 64
        prior_token = "1" * 64
        receipt = legacy_runtime.ExternalEffectReceipt(
            effect_token="3" * 64,
            source_event_id=source_event_id,
            effect_kind="container",
            authority={
                "container_name": "agent",
                "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                "invocation_token": "4" * 64,
            },
            binding={"container_id": "5" * 64},
        )
        reconcile_calls = 0
        retired = False
        takeover = False
        handler_called = False

        class Lease:
            closed = False

            def close(self) -> None:
                self.closed = True

        lease = Lease()

        class Store:
            def acquire_message_delivery_lease(self, event, *, timeout):
                self_outer.assertEqual(event, source_event_id)
                return lease

            def inspect_message_delivery(self, event):
                self_outer.assertEqual(event, source_event_id)
                return prior_token

            def active_external_effects(self, event):
                self_outer.assertEqual(event, source_event_id)
                return (receipt,)

            def retire_external_effect(self, event, claim, effect):
                nonlocal retired
                retired = True

            def take_over_message_delivery(self, event, claim):
                nonlocal takeover
                takeover = True
                return "2" * 64

            def claim_message_delivery(self, event):
                raise AssertionError("stale guard must use takeover")

            def release_message_delivery(self, event, claim):
                raise AssertionError("changed engine identity cannot retire guard")

        self_outer = self

        async def reconcile(_observed):
            nonlocal reconcile_calls
            reconcile_calls += 1
            return legacy_runtime.ExternalEffectExtinctionProof(
                effect_token=receipt.effect_token,
                engine_endpoint_identity={"authority_digest": "8" * 64},
                binding_digest=legacy_runtime._external_effect_binding_digest(
                    receipt
                ),
            )

        async def handler(_message):
            nonlocal handler_called
            handler_called = True

        message = _Message(1)
        dispatch = asyncio.create_task(
            legacy_runtime._dispatch_with_heartbeat(
                message,
                handler,
                heartbeat_seconds=0.001,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                delivery_authority=legacy_runtime.DurableDispatchAuthority(
                    store=Store(),
                    identify=lambda _message: source_event_id,
                    reconcile=reconcile,
                ),
            )
        )
        for _attempt in range(100):
            if reconcile_calls >= 2:
                break
            await asyncio.sleep(0.002)
        dispatch.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await dispatch

        self.assertGreaterEqual(reconcile_calls, 2)
        self.assertFalse(retired)
        self.assertFalse(takeover)
        self.assertFalse(handler_called)
        self.assertEqual((message.acks, message.naks, message.terms), (0, 0, 0))
        self.assertTrue(lease.closed)

    async def test_transient_lease_contention_naks_and_keeps_worker_alive(self) -> None:
        contended = _Message(1)
        following = _Message(2)
        stop = asyncio.Event()

        async def handler(message: _Message) -> None:
            if message is contended:
                raise legacy_runtime.RetryMessage("claim is held by another worker")
            stop.set()

        await asyncio.wait_for(
            legacy_runtime.run_consumer_workers(
                _Subscription([contended, following]),
                handler,
                max_workers=1,
                heartbeat_seconds=0.01,
                fetch_timeout=0.01,
                stop_event=stop,
            ),
            timeout=3,
        )
        self.assertEqual(contended.naks, 1)
        self.assertEqual(contended.acks, 0)
        self.assertEqual(contended.nak_delays, [30.0])
        self.assertEqual(following.acks, 1)
        self.assertEqual(following.naks, 0)

    async def test_heartbeat_rpc_timeout_naks_and_surfaces_failure(self) -> None:
        message = _Message(1, hangs={"heartbeat"})

        async def slow(_message: _Message) -> None:
            await asyncio.sleep(0.05)

        with self.assertRaises(legacy_runtime.ConsumerHeartbeatError):
            await legacy_runtime.run_consumer_workers(
                _Subscription([message]),
                slow,
                max_workers=1,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.02,
                disposition_timeout=0.02,
                fetch_timeout=0.01,
            )
        self.assertEqual(message.naks, 1)
        self.assertEqual(message.acks, 0)

    async def test_heartbeat_failure_waits_for_blocking_handler_before_nak(self) -> None:
        message = _Message(1, hangs={"heartbeat"})
        worker_started = threading.Event()
        release_worker = threading.Event()

        async def blocking(_message: _Message) -> None:
            def work() -> None:
                worker_started.set()
                release_worker.wait(2)

            await asyncio.to_thread(work)

        runner = asyncio.create_task(
            legacy_runtime.run_consumer_workers(
                _Subscription([message]),
                blocking,
                max_workers=1,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.02,
                disposition_timeout=0.02,
                fetch_timeout=0.01,
            )
        )
        self.assertTrue(
            await asyncio.to_thread(worker_started.wait, 1),
            "blocking worker did not start",
        )
        await asyncio.sleep(0.06)
        self.assertEqual(
            message.naks,
            0,
            "message was redelivered while its original worker was still running",
        )
        release_worker.set()
        with self.assertRaises(legacy_runtime.ConsumerHeartbeatError):
            await asyncio.wait_for(runner, timeout=1)
        self.assertEqual(message.naks, 1)

    async def test_heartbeat_race_preserves_handler_containment_failure(self) -> None:
        heartbeat_started = asyncio.Event()

        class FailingHeartbeatMessage(_Message):
            async def in_progress(self) -> None:
                self.heartbeats += 1
                heartbeat_started.set()
                raise RuntimeError("broker heartbeat failed")

        message = FailingHeartbeatMessage(1)
        supervisor = _RecordingExtinctionSupervisor()

        async def containment_failed(_message: _Message) -> None:
            await heartbeat_started.wait()
            raise legacy_runtime.WorkerExtinctionError(
                "container creation may still be publishing"
            )

        observed: BaseException | None = None
        try:
            await legacy_runtime._dispatch_with_heartbeat(
                message,
                containment_failed,
                heartbeat_seconds=0.001,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        except BaseException as error:
            observed = error

        self.assertIsInstance(observed, SystemExit)
        self.assertEqual(len(supervisor.reasons), 1)
        self.assertIn("containment-fatal", supervisor.reasons[0])
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.acks, 0)
        self.assertEqual(message.terms, 0)

    async def test_cancellation_race_preserves_handler_containment_failure(
        self,
    ) -> None:
        message = _Message(1, hangs={"heartbeat"})
        handler_started = asyncio.Event()
        release_handler = asyncio.Event()

        class TerminalExtinction(BaseException):
            pass

        class TerminalSupervisor:
            def __init__(self) -> None:
                self.reasons: list[str] = []

            async def extinguish_and_terminate(self, reason: str) -> None:
                self.reasons.append(reason)
                raise TerminalExtinction

        supervisor = TerminalSupervisor()

        async def containment_failed(_message: _Message) -> None:
            handler_started.set()
            await release_handler.wait()
            raise legacy_runtime.WorkerExtinctionError(
                "container creation may still be publishing"
            )

        runner = asyncio.create_task(
            legacy_runtime._dispatch_with_heartbeat(
                message,
                containment_failed,
                heartbeat_seconds=1,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        )
        await asyncio.wait_for(handler_started.wait(), timeout=1)
        runner.cancel()
        release_handler.set()
        observed: BaseException | None = None
        try:
            await runner
        except BaseException as error:
            observed = error

        self.assertIsInstance(observed, TerminalExtinction)
        self.assertEqual(len(supervisor.reasons), 1)
        self.assertIn("containment-fatal", supervisor.reasons[0])
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.acks, 0)
        self.assertEqual(message.terms, 0)

    async def test_fatal_heartbeat_settles_handler_before_propagation(self) -> None:
        for fatal in (KeyboardInterrupt(), SystemExit(74)):
            with self.subTest(fatal=type(fatal).__name__):
                handler_started = asyncio.Event()
                release_handler = asyncio.Event()
                handler_finished = asyncio.Event()

                class FatalHeartbeatMessage(_Message):
                    async def in_progress(self) -> None:
                        self.heartbeats += 1
                        raise fatal

                message = FatalHeartbeatMessage(1)

                async def blocking(_message: _Message) -> None:
                    handler_started.set()
                    await release_handler.wait()
                    handler_finished.set()

                async def release_after_heartbeat() -> None:
                    await handler_started.wait()
                    while message.heartbeats == 0:
                        await asyncio.sleep(0)
                    await asyncio.sleep(0.02)
                    release_handler.set()

                releaser = asyncio.create_task(release_after_heartbeat())
                observed: BaseException | None = None
                propagated_after_handler = False
                try:
                    await legacy_runtime._dispatch_with_heartbeat(
                        message,
                        blocking,
                        heartbeat_seconds=0.001,
                        heartbeat_rpc_timeout=0.01,
                        disposition_timeout=0.01,
                        handler_shutdown_timeout=1,
                    )
                except BaseException as error:
                    observed = error
                    propagated_after_handler = handler_finished.is_set()
                finally:
                    release_handler.set()
                    await releaser
                    await asyncio.sleep(0)

                self.assertIsInstance(observed, type(fatal))
                self.assertTrue(propagated_after_handler)
                self.assertTrue(handler_finished.is_set())
                self.assertEqual(message.naks, 0)
                self.assertEqual(message.acks, 0)
                self.assertEqual(message.terms, 0)

    async def test_supervisor_cancellation_waits_for_blocking_handler_before_nak(self) -> None:
        message = _Message(1)
        worker_started = threading.Event()
        release_worker = threading.Event()

        async def blocking(_message: _Message) -> None:
            def work() -> None:
                worker_started.set()
                release_worker.wait(2)

            await asyncio.to_thread(work)

        runner = asyncio.create_task(
            legacy_runtime.run_consumer_workers(
                _Subscription([message]),
                blocking,
                max_workers=1,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.02,
                disposition_timeout=0.02,
                fetch_timeout=0.01,
            )
        )
        self.assertTrue(
            await asyncio.to_thread(worker_started.wait, 1),
            "blocking worker did not start",
        )
        runner.cancel()
        await asyncio.sleep(0.05)
        self.assertFalse(runner.done())
        self.assertEqual(
            message.naks,
            0,
            "message was redelivered before the cancelled worker actually stopped",
        )
        release_worker.set()
        with self.assertRaises(asyncio.CancelledError):
            await asyncio.wait_for(runner, timeout=1)
        self.assertEqual(message.naks, 1)

    async def test_nonterminating_handler_hits_worker_extinction_without_nak(
        self,
    ) -> None:
        message = _Message(1, hangs={"heartbeat"})
        supervisor = _RecordingExtinctionSupervisor()
        started = asyncio.Event()
        release = asyncio.Event()

        async def never_finishes(_message: _Message) -> None:
            started.set()
            await release.wait()

        observed: BaseException | None = None
        with patch.object(
            legacy_runtime.os,
            "_exit",
            side_effect=AssertionError("raw os._exit bypassed extinction proof"),
        ):
            try:
                await legacy_runtime._dispatch_with_heartbeat(
                    message,
                    never_finishes,
                    heartbeat_seconds=0.01,
                    heartbeat_rpc_timeout=0.01,
                    disposition_timeout=0.01,
                    handler_shutdown_timeout=0.03,
                    extinction_supervisor=supervisor,
                )
            except BaseException as error:
                observed = error
            finally:
                release.set()
                await asyncio.sleep(0)
        self.assertTrue(started.is_set())
        self.assertEqual(
            type(observed).__name__,
            "SystemExit",
        )
        self.assertEqual(len(supervisor.reasons), 1)
        self.assertEqual(message.naks, 0)

    async def test_fatal_timeout_delegates_once_to_bound_extinction_supervisor(
        self,
    ) -> None:
        message = _Message(1, hangs={"heartbeat"})
        supervisor = _RecordingExtinctionSupervisor()
        started = asyncio.Event()
        release = asyncio.Event()

        async def never_finishes(_message: _Message) -> None:
            self.assertIs(
                legacy_runtime.current_worker_extinction_supervisor(),
                supervisor,
            )
            started.set()
            await release.wait()

        observed: BaseException | None = None
        try:
            await legacy_runtime._dispatch_with_heartbeat(
                message,
                never_finishes,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                handler_shutdown_timeout=0.03,
                extinction_supervisor=supervisor,
            )
        except BaseException as error:
            observed = error
        finally:
            release.set()
            await asyncio.sleep(0)

        self.assertTrue(started.is_set())
        self.assertIsInstance(observed, SystemExit)
        self.assertEqual(supervisor.reasons, [
            "message handler did not stop before its extinction deadline"
        ])
        self.assertEqual(message.naks, 0)

    async def test_containment_failure_extinguishes_before_any_nak(self) -> None:
        message = _Message(1)
        supervisor = _RecordingExtinctionSupervisor()

        async def containment_failed(_message: _Message) -> None:
            raise legacy_runtime.WorkerExtinctionError(
                "container creation may have left an unreceipted object"
            )

        observed: BaseException | None = None
        try:
            await legacy_runtime._dispatch_with_heartbeat(
                message,
                containment_failed,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        except BaseException as error:
            observed = error

        self.assertIsInstance(observed, SystemExit)
        self.assertEqual(supervisor.reasons, [
            "containment-fatal: container creation may have left an unreceipted object"
        ])
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.acks, 0)
        self.assertEqual(message.terms, 0)

    async def test_failed_extinction_quarantines_redelivery_until_retry_exits(
        self,
    ) -> None:
        message = _Message(1)

        class RetryExtinctionSupervisor:
            def __init__(self) -> None:
                self.reasons: list[str] = []

            async def extinguish_and_terminate(self, reason: str) -> None:
                self.reasons.append(reason)
                if len(self.reasons) == 1:
                    raise legacy_runtime.WorkerExtinctionError(
                        "exact external effect is still live"
                    )
                raise SystemExit(70)

        supervisor = RetryExtinctionSupervisor()

        async def containment_failed(_message: _Message) -> None:
            raise legacy_runtime.WorkerExtinctionError(
                "container creation may have left an unreceipted object"
            )

        observed: BaseException | None = None
        try:
            await legacy_runtime._dispatch_with_heartbeat(
                message,
                containment_failed,
                heartbeat_seconds=0.001,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        except BaseException as error:
            observed = error

        self.assertIsInstance(observed, SystemExit)
        self.assertEqual(len(supervisor.reasons), 2)
        self.assertGreaterEqual(message.heartbeats, 1)
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.acks, 0)
        self.assertEqual(message.terms, 0)

    async def test_handler_shutdown_timeout_retries_extinction_while_handler_lives(
        self,
    ) -> None:
        """A timeout must use quarantine, not return a live handler to NAK."""

        message = _Message(1, hangs={"heartbeat"})
        handler_started = asyncio.Event()
        release_handler = asyncio.Event()
        permit_terminal_exit = asyncio.Event()

        class TerminalExtinction(BaseException):
            pass

        class RepeatedlyFailingExtinctionSupervisor:
            def __init__(self) -> None:
                self.reasons: list[str] = []

            async def extinguish_and_terminate(self, reason: str) -> None:
                self.reasons.append(reason)
                if permit_terminal_exit.is_set():
                    raise TerminalExtinction
                raise legacy_runtime.WorkerExtinctionError(
                    "exact worker extinction is still unproven"
                )

        supervisor = RepeatedlyFailingExtinctionSupervisor()

        async def never_finishes(_message: _Message) -> None:
            handler_started.set()
            await release_handler.wait()

        runner = asyncio.create_task(
            legacy_runtime._dispatch_with_heartbeat(
                message,
                never_finishes,
                heartbeat_seconds=0.001,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                handler_shutdown_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        )
        try:
            await asyncio.wait_for(handler_started.wait(), timeout=1)
            deadline = time.monotonic() + 1
            while len(supervisor.reasons) < 2 and time.monotonic() < deadline:
                await asyncio.sleep(0.005)
            self.assertGreaterEqual(len(supervisor.reasons), 2)
            self.assertFalse(runner.done())
            self.assertFalse(release_handler.is_set())
            self.assertGreaterEqual(message.heartbeats, 1)
            self.assertEqual(message.acks, 0)
            self.assertEqual(message.naks, 0)
            self.assertEqual(message.terms, 0)
            self.assertTrue(
                all(
                    reason
                    == "message handler did not stop before its extinction deadline"
                    for reason in supervisor.reasons
                )
            )
            permit_terminal_exit.set()
            with self.assertRaises(TerminalExtinction):
                await asyncio.wait_for(runner, timeout=1)
        finally:
            release_handler.set()
            permit_terminal_exit.set()
            if not runner.done():
                runner.cancel()
            await asyncio.gather(runner, return_exceptions=True)

    async def test_slow_extinction_keeps_heartbeat_quarantine_under_cancellation(
        self,
    ) -> None:
        heartbeat_calls: asyncio.Queue[int] = asyncio.Queue()

        class TerminalExtinction(BaseException):
            pass

        class FailingHeartbeatMessage(_Message):
            async def in_progress(self) -> None:
                self.heartbeats += 1
                heartbeat_calls.put_nowait(self.heartbeats)
                raise SystemExit(74)

        message = FailingHeartbeatMessage(1)
        first_attempt_started = asyncio.Event()
        release_first_attempt = asyncio.Event()

        class SlowRetryExtinctionSupervisor:
            def __init__(self) -> None:
                self.reasons: list[str] = []

            async def extinguish_and_terminate(self, reason: str) -> None:
                self.reasons.append(reason)
                if len(self.reasons) == 1:
                    first_attempt_started.set()
                    await release_first_attempt.wait()
                    raise legacy_runtime.WorkerExtinctionError(
                        "exact external effect is still live"
                    )
                raise TerminalExtinction

        supervisor = SlowRetryExtinctionSupervisor()

        async def containment_failed(_message: _Message) -> None:
            raise legacy_runtime.WorkerExtinctionError(
                "container creation may have left an unreceipted object"
            )

        runner = asyncio.create_task(
            legacy_runtime._dispatch_with_heartbeat(
                message,
                containment_failed,
                heartbeat_seconds=0.001,
                heartbeat_rpc_timeout=0.01,
                disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        )

        async def next_heartbeat() -> int:
            getter = asyncio.create_task(heartbeat_calls.get())
            try:
                done, _pending = await asyncio.wait({getter}, timeout=1)
                if getter not in done:
                    self.fail("extinction quarantine stopped broker heartbeats")
                return getter.result()
            finally:
                if not getter.done():
                    getter.cancel()
                await asyncio.gather(getter, return_exceptions=True)

        observed: BaseException | None = None
        try:
            await asyncio.wait_for(first_attempt_started.wait(), timeout=1)
            self.assertEqual(await next_heartbeat(), 1)
            runner.cancel()
            self.assertEqual(await next_heartbeat(), 2)
            self.assertFalse(runner.done())
            release_first_attempt.set()
            try:
                await runner
            except BaseException as error:
                observed = error
        finally:
            release_first_attempt.set()
            if not runner.done():
                runner.cancel()
            await asyncio.gather(runner, return_exceptions=True)

        self.assertIsInstance(observed, TerminalExtinction)
        self.assertEqual(len(supervisor.reasons), 2)
        self.assertGreaterEqual(message.heartbeats, 2)
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.acks, 0)
        self.assertEqual(message.terms, 0)


    async def test_ack_nak_and_term_failures_reach_the_supervisor(self) -> None:
        async def succeed(_message: _Message) -> None:
            return None

        async def fail(_message: _Message) -> None:
            raise RuntimeError("handler failed")

        async def reject(_message: _Message) -> None:
            raise legacy_runtime.RejectMessage("malformed")

        cases = (
            (_Message(1, failures={"ack"}), succeed),
            (_Message(2, failures={"nak"}), fail),
            (_Message(3, failures={"term"}), reject),
            (_Message(4, hangs={"ack"}), succeed),
        )
        for message, handler in cases:
            with self.subTest(message=message.value), self.assertRaises(
                legacy_runtime.ConsumerDispositionError
            ):
                await legacy_runtime.run_consumer_workers(
                    _Subscription([message]),
                    handler,
                    max_workers=1,
                    heartbeat_seconds=0.01,
                    heartbeat_rpc_timeout=0.02,
                    disposition_timeout=0.02,
                    fetch_timeout=0.01,
                )

    async def test_cancellation_naks_inflight_message_and_propagates(self) -> None:
        message = _Message(1)
        started = asyncio.Event()
        release = asyncio.Event()

        async def wait_forever(_message: _Message) -> None:
            started.set()
            await release.wait()

        runner = asyncio.create_task(
            legacy_runtime.run_consumer_workers(
                _Subscription([message]),
                wait_forever,
                max_workers=1,
                heartbeat_seconds=1,
                heartbeat_rpc_timeout=0.02,
                disposition_timeout=0.02,
                fetch_timeout=0.01,
            )
        )
        await asyncio.wait_for(started.wait(), timeout=1)
        runner.cancel()
        await asyncio.sleep(0)
        self.assertEqual(message.naks, 0)
        release.set()
        with self.assertRaises(asyncio.CancelledError):
            await runner
        self.assertEqual(message.naks, 1)
        self.assertEqual(message.acks, 0)

    async def test_handler_self_cancellation_is_naked_once_and_surfaces(self) -> None:
        message = _Message(1)

        async def self_cancel(_message: _Message) -> None:
            raise asyncio.CancelledError

        with self.assertRaises(legacy_runtime.ConsumerHandlerError):
            await legacy_runtime.run_consumer_workers(
                _Subscription([message]),
                self_cancel,
                max_workers=1,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.02,
                disposition_timeout=0.02,
                fetch_timeout=0.01,
            )

        self.assertEqual(message.naks, 1)
        self.assertEqual(message.acks, 0)

    async def test_cancellation_during_ack_does_not_send_a_second_disposition(self) -> None:
        ack_started = asyncio.Event()

        class HangingAckMessage(_Message):
            async def ack(self) -> None:
                self.acks += 1
                ack_started.set()
                await asyncio.Event().wait()

        message = HangingAckMessage(1)

        async def succeed(_message: _Message) -> None:
            return None

        runner = asyncio.create_task(
            legacy_runtime.run_consumer_workers(
                _Subscription([message]),
                succeed,
                max_workers=1,
                heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.02,
                disposition_timeout=30,
                fetch_timeout=0.01,
            )
        )
        await asyncio.wait_for(ack_started.wait(), timeout=1)
        runner.cancel()
        with self.assertRaises(asyncio.CancelledError):
            await runner

        self.assertEqual(message.acks, 1)
        self.assertEqual(message.naks, 0)
        self.assertEqual(message.terms, 0)

    async def test_worker_limit_above_host_cap_is_rejected(self) -> None:
        with self.assertRaises(ValueError):
            await legacy_runtime.run_consumer_workers(
                _Subscription([]),
                lambda message: None,
                max_workers=4,
                heartbeat_seconds=1,
                fetch_timeout=0.01,
                stop_event=asyncio.Event(),
            )


class GenericExternalEffectSupervisorTest(unittest.TestCase):
    def test_pod_infra_relay_receipt_arms_binds_cleans_and_retires_exactly(
        self,
    ) -> None:
        source_event_id = "a" * 64
        claim_token = "b" * 64
        effect_token = "c" * 64
        events: list[str] = []

        class Store:
            def arm_external_effect(self, source, claim, kind, authority):
                self_outer.assertEqual((source, claim), (source_event_id, claim_token))
                self_outer.assertEqual(kind, "pod-infra-relay")
                self_outer.assertEqual(
                    authority["engine_endpoint_identity"],
                    _TEST_ENGINE_ENDPOINT_IDENTITY,
                )
                events.append("arm")
                return effect_token

            def bind_external_effect(self, source, claim, token, binding):
                self_outer.assertEqual(
                    (source, claim, token),
                    (source_event_id, claim_token, effect_token),
                )
                self_outer.assertEqual(binding["pod_id"], "d" * 64)
                events.append("bind")

            def retire_external_effect(self, source, claim, token):
                self_outer.assertEqual(
                    (source, claim, token),
                    (source_event_id, claim_token, effect_token),
                )
                events.append("retire")

        self_outer = self
        supervisor = legacy_runtime.WorkerExtinctionSupervisor()
        scope = supervisor._open_request_effect_scope()
        delivery = legacy_runtime._DurableDeliveryContext(
            Store(), source_event_id, claim_token
        )

        def cleanup(receipt):
            self.assertEqual(receipt.effect_token, effect_token)
            self.assertEqual(receipt.binding["pod_id"], "d" * 64)
            events.append("cleanup")
            return legacy_runtime.external_effect_extinction_proof(
                receipt,
                _TEST_ENGINE_ENDPOINT_IDENTITY,
            )

        scope_token = legacy_runtime._CURRENT_WORKER_REQUEST_EFFECT_SCOPE.set(scope)
        delivery_token = legacy_runtime._CURRENT_DURABLE_DELIVERY.set(delivery)
        supervisor_token = (
            legacy_runtime._CURRENT_WORKER_EXTINCTION_SUPERVISOR.set(supervisor)
        )
        try:
            with legacy_runtime.external_effect_supervisor(
                "pod-infra-relay",
                {
                    "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                    "invocation_token": "e" * 64,
                    "pod_name": "pod-one",
                },
                cleanup,
            ) as effect:
                effect.bind_exact(
                    {
                        "infra_id": "f" * 64,
                        "pod_id": "d" * 64,
                        "relay_pid": 4242,
                    }
                )
        finally:
            legacy_runtime._CURRENT_WORKER_EXTINCTION_SUPERVISOR.reset(
                supervisor_token
            )
            legacy_runtime._CURRENT_DURABLE_DELIVERY.reset(delivery_token)
            legacy_runtime._CURRENT_WORKER_REQUEST_EFFECT_SCOPE.reset(scope_token)

        scope.seal_and_verify_quiescent()
        self.assertEqual(events, ["arm", "bind", "cleanup", "retire"])

    def test_wrong_cleanup_identity_keeps_generic_receipt_armed(self) -> None:
        events: list[str] = []

        class Store:
            def arm_external_effect(self, *_args):
                events.append("arm")
                return "c" * 64

            def bind_external_effect(self, *_args):
                raise AssertionError("this effect remains pre-create")

            def retire_external_effect(self, *_args):
                events.append("retire")

        supervisor = legacy_runtime.WorkerExtinctionSupervisor()
        scope = supervisor._open_request_effect_scope()
        delivery = legacy_runtime._DurableDeliveryContext(
            Store(), "a" * 64, "b" * 64
        )

        def wrong_cleanup(receipt):
            events.append("wrong-cleanup")
            return legacy_runtime.ExternalEffectExtinctionProof(
                effect_token=receipt.effect_token,
                engine_endpoint_identity={"authority_digest": "8" * 64},
                binding_digest=None,
            )

        scope_token = legacy_runtime._CURRENT_WORKER_REQUEST_EFFECT_SCOPE.set(scope)
        delivery_token = legacy_runtime._CURRENT_DURABLE_DELIVERY.set(delivery)
        supervisor_token = (
            legacy_runtime._CURRENT_WORKER_EXTINCTION_SUPERVISOR.set(supervisor)
        )
        effect = None
        try:
            effect = legacy_runtime.external_effect_supervisor(
                "pod-infra-relay",
                {
                    "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                    "invocation_token": "e" * 64,
                },
                wrong_cleanup,
            )
            effect.__enter__()
            with self.assertRaises(legacy_runtime.WorkerExtinctionError):
                effect.__exit__(None, None, None)
            self.assertIn(effect, supervisor._external_effects)
            with self.assertRaises(legacy_runtime.WorkerContainmentFatalError):
                scope.seal_and_verify_quiescent()
            self.assertNotIn("retire", events)

            effect._cleanup = lambda receipt: (
                legacy_runtime.external_effect_extinction_proof(
                    receipt,
                    _TEST_ENGINE_ENDPOINT_IDENTITY,
                )
            )
            effect._extinguish()
            effect._close_proven()
        finally:
            legacy_runtime._CURRENT_WORKER_EXTINCTION_SUPERVISOR.reset(
                supervisor_token
            )
            legacy_runtime._CURRENT_DURABLE_DELIVERY.reset(delivery_token)
            legacy_runtime._CURRENT_WORKER_REQUEST_EFFECT_SCOPE.reset(scope_token)

        self.assertEqual(events, ["arm", "wrong-cleanup", "retire"])


class ExternalContainerSupervisorTest(unittest.IsolatedAsyncioTestCase):
    def setUp(self):
        descriptor_path = patch.object(
            legacy_athena, "_descriptor_execution_path",
            side_effect=lambda descriptor: f"/proc/self/fd/{descriptor}",
        )
        descriptor_path.start()
        self.addCleanup(descriptor_path.stop)

    def test_durable_effect_is_armed_before_endpoint_admission_and_retired_last(
        self,
    ) -> None:
        events: list[str] = []

        class Store:
            def arm_external_effect(self, event, claim, kind, authority):
                self_outer.assertEqual((event, claim), ("a" * 64, "b" * 64))
                self_outer.assertEqual(kind, "container")
                self_outer.assertEqual(authority["container_name"], "agent")
                self_outer.assertEqual(
                    authority["engine_endpoint_identity"],
                    _TEST_ENGINE_ENDPOINT_IDENTITY,
                )
                events.append("durable-arm")
                return "c" * 64

            def retire_external_effect(self, event, claim, token):
                self_outer.assertEqual(
                    (event, claim, token),
                    ("a" * 64, "b" * 64, "c" * 64),
                )
                events.append("durable-retire")

        class Endpoint:
            def durable_effect_identity(self):
                return dict(_TEST_ENGINE_ENDPOINT_IDENTITY)

            def register_effect(self, effect, supervisor):
                events.append("endpoint-admit")

            def release_effect(self, effect):
                self_outer.assertTrue(effect._extinction_proven)
                events.append("endpoint-release")

        self_outer = self
        supervisor = legacy_runtime.WorkerExtinctionSupervisor()
        guard = object.__new__(legacy_runtime._ExternalContainerSupervisor)
        guard._supervisor = supervisor
        guard._request_effect_scope = None
        guard._durable_delivery = legacy_runtime._DurableDeliveryContext(
            Store(), "a" * 64, "b" * 64
        )
        guard._durable_effect_token = None
        guard._endpoint_binding = Endpoint()
        guard._runtime_fd = -1
        guard._cidfile_parent_fd = -1
        guard._container_name = "agent"
        guard._invocation_token = "d" * 64
        guard._timeout = 1.0
        guard._container_id = None
        guard._binding_digest = None
        guard._extinction_proven = False
        guard._entered = False
        guard._closed = False
        guard._lock = threading.RLock()
        guard._verify_cidfile_parent = lambda: None

        guard.__enter__()
        self.assertEqual(events, ["durable-arm", "endpoint-admit"])
        guard._extinction_proven = True
        guard._close_proven()
        self.assertEqual(
            events,
            [
                "durable-arm",
                "endpoint-admit",
                "durable-retire",
                "endpoint-release",
            ],
        )

    def test_restart_reconciler_uses_exact_id_and_returns_structured_proof(
        self,
    ) -> None:
        container_id = "a" * 64
        invocation_token = "b" * 64
        inspection = {
            "Id": container_id,
            "Name": "/agent",
            "Image": "c" * 64,
            "Config": {
                "Image": "c" * 64,
                "Labels": {"homeric.invocation": invocation_token},
            },
            "HostConfig": {},
            "Mounts": [],
        }
        binding_digest = legacy_runtime.container_binding_digest(inspection)
        receipt = legacy_runtime.ExternalEffectReceipt(
            effect_token="d" * 64,
            source_event_id="e" * 64,
            effect_kind="container",
            authority={
                "container_name": "agent",
                "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                "invocation_token": invocation_token,
            },
            binding={
                "binding_digest": binding_digest,
                "container_id": container_id,
            },
        )
        commands: list[tuple[str, ...]] = []

        def run_exact(
            _runtime_fd: int,
            _environment: dict[str, str],
            arguments: tuple[str, ...],
            _timeout: float,
        ) -> tuple[int, bytes, bytes]:
            commands.append(arguments)
            if arguments[0] == "inspect":
                return 0, json.dumps(inspection).encode(), b""
            if arguments[0] == "ps":
                return 0, b"", b""
            return 0, b"", b""

        descriptor = os.open(__file__, os.O_RDONLY)
        try:
            with (
                patch.object(
                    legacy_runtime,
                    "_duplicate_sealed_runtime_descriptor",
                    side_effect=os.dup,
                ),
                patch.object(
                    legacy_runtime,
                    "_run_exact_container_command",
                    side_effect=run_exact,
                ),
            ):
                proof = legacy_runtime.reconcile_external_container_effect(
                    receipt,
                    SimpleNamespace(descriptor=descriptor, sha256="f" * 64),
                    _ControlledEndpoint(),
                    timeout=1,
                )
        finally:
            os.close(descriptor)

        self.assertEqual(proof.effect_token, receipt.effect_token)
        self.assertEqual(
            proof.engine_endpoint_identity,
            _TEST_ENGINE_ENDPOINT_IDENTITY,
        )
        self.assertEqual(
            [command[0] for command in commands],
            ["inspect", "stop", "kill", "rm", "ps", "ps", "ps", "ps"],
        )
        for command in commands:
            rendered = "\0".join(command)
            if command[0] in {"stop", "kill", "rm"}:
                self.assertEqual(command[-1], container_id)
                self.assertNotIn("agent", rendered)

    def test_restart_reconciler_rejects_changed_engine_before_commands(
        self,
    ) -> None:
        receipt = legacy_runtime.ExternalEffectReceipt(
            effect_token="a" * 64,
            source_event_id="b" * 64,
            effect_kind="container",
            authority={
                "container_name": "agent",
                "engine_endpoint_identity": _TEST_ENGINE_ENDPOINT_IDENTITY,
                "invocation_token": "c" * 64,
            },
            binding=None,
        )

        class ChangedEndpoint(_ControlledEndpoint):
            def durable_effect_identity(self):
                return {"authority_digest": "8" * 64}

            def enter_command(self, *args, **kwargs):
                raise AssertionError("changed endpoint must not receive commands")

        descriptor = os.open(__file__, os.O_RDONLY)
        try:
            with patch.object(
                legacy_runtime,
                "_duplicate_sealed_runtime_descriptor",
                side_effect=os.dup,
            ):
                with self.assertRaises(legacy_runtime.WorkerExtinctionError):
                    legacy_runtime.reconcile_external_container_effect(
                        receipt,
                        SimpleNamespace(descriptor=descriptor, sha256="d" * 64),
                        ChangedEndpoint(),
                        timeout=1,
                    )
        finally:
            os.close(descriptor)

    async def test_endpoint_loss_keeps_effect_armed_and_forbids_all_dispositions(self) -> None:
        supervisor = _RecordingExtinctionSupervisor()
        message = _Message(1)
        guard = object.__new__(legacy_runtime._ExternalContainerSupervisor)
        guard._lock = threading.RLock()
        guard._closed = False
        guard._extinction_proven = False
        guard._container_id = "a" * 64
        guard._timeout = 1
        guard._runtime_binding = SimpleNamespace(descriptor=42)
        guard._endpoint_binding = SimpleNamespace(
            enter_command=lambda *_args, **_kwargs: (_ for _ in ()).throw(
                legacy_athena.AthenaEvidenceError("exact endpoint broker is gone")
            ),
            release_effect=lambda _effect: self.fail("unproven receipt released"),
        )
        authority = legacy_runtime.WorkerExtinctionSupervisor()
        authority._register_external_effect(guard)

        async def handler(_message):
            guard._extinguish()

        with self.assertRaises(SystemExit):
            await legacy_runtime._dispatch_with_heartbeat(
                message, handler, heartbeat_seconds=0.01,
                heartbeat_rpc_timeout=0.01, disposition_timeout=0.01,
                extinction_supervisor=supervisor,
            )
        self.assertEqual((message.acks, message.naks, message.terms), (0, 0, 0))
        self.assertFalse(guard._closed)
        self.assertFalse(guard._extinction_proven)
        self.assertIn(guard, authority._external_effects)
        self.assertIn("containment-fatal", supervisor.reasons[0])

    def test_rejected_cleanup_executor_closes_parent_channel_and_pidfd(self) -> None:
        """Every post-pidfd initialization rejection releases parent resources."""

        class Channel:
            def __init__(self, descriptor: int) -> None:
                self.descriptor = descriptor
                self.close_count = 0

            def fileno(self) -> int:
                return self.descriptor

            def close(self) -> None:
                self.close_count += 1

        class Process:
            pid = 4321

            def __init__(self) -> None:
                self.dead = False

            def poll(self) -> int | None:
                return 0 if self.dead else None

            def wait(self, *, timeout: float) -> int:
                self.dead = True
                return 0

        parent = Channel(31)
        child = Channel(32)
        process = Process()
        closed_descriptors: list[int] = []

        with (
            patch.object(
                legacy_runtime.socket,
                "socketpair",
                return_value=(parent, child),
            ),
            patch.object(
                legacy_athena,
                "_trusted_python_executable",
                return_value=SimpleNamespace(
                    descriptor=42, execution_path="/proc/self/fd/42", close=lambda: None,
                ),
            ),
            patch.object(
                legacy_runtime.subprocess,
                "Popen",
                return_value=process,
            ),
            patch.object(
                legacy_runtime.os, "pidfd_open", return_value=97, create=True
            ),
            patch.object(
                legacy_runtime,
                "_linux_process_identity",
                side_effect=[(4321, 1), (4321, 2)],
            ),
            patch.object(
                legacy_runtime.signal,
                "pidfd_send_signal",
                side_effect=lambda *_args: setattr(process, "dead", True),
                create=True,
            ),
            patch.object(
                legacy_runtime.os,
                "close",
                side_effect=closed_descriptors.append,
            ),
        ):
            with self.assertRaises(legacy_athena.AthenaEvidenceError):
                legacy_athena._ContainerEndpointBinding(42)

        self.assertEqual(parent.close_count, 1)
        self.assertEqual(child.close_count, 1)
        self.assertEqual(closed_descriptors, [97])

    def test_post_barrier_container_commands_use_prearmed_executor(self) -> None:
        expected = (0, b"", b"")

        class Executor:
            def __init__(self) -> None:
                self.calls: list[tuple[tuple[str, ...], float]] = []

            def enter_command(self, runtime, arguments, *, timeout_seconds):
                self.calls.append((tuple(arguments), timeout_seconds))
                return subprocess.CompletedProcess(arguments, 0, "", "")

        executor = Executor()
        guard = object.__new__(legacy_runtime._ExternalContainerSupervisor)
        guard._endpoint_binding = executor
        guard._runtime_binding = SimpleNamespace(descriptor=10)
        guard._runtime_fd = 10
        guard._timeout = 1.0

        with patch.object(
            legacy_runtime,
            "_run_exact_container_command",
            side_effect=AssertionError("post-barrier direct spawn is forbidden"),
        ):
            result = guard._run(("ps", "--all"), time.monotonic() + 1)

        self.assertEqual(result, expected)
        self.assertEqual(executor.calls[0][0], ("ps", "--all"))

    def test_endpoint_binding_executes_every_cleanup_command_without_direct_spawn(
        self,
    ) -> None:
        """A sealed broker, rather than mutable endpoint environment, owns cleanup."""

        expected = subprocess.CompletedProcess([], 0, "", "")

        class EndpointBinding:
            def __init__(self) -> None:
                self.calls: list[tuple[object, list[str], float]] = []

            def enter_command(
                self,
                runtime: object,
                arguments: list[str],
                *,
                input_text: str | None = None,
                timeout_seconds: float,
            ) -> subprocess.CompletedProcess:
                if input_text is not None:
                    raise AssertionError("cleanup commands must not have stdin")
                self.calls.append((runtime, arguments, timeout_seconds))
                return expected

        binding = EndpointBinding()
        guard = object.__new__(legacy_runtime._ExternalContainerSupervisor)
        guard._endpoint_binding = binding
        guard._runtime_fd = 10
        guard._runtime_binding = SimpleNamespace(descriptor=10)
        guard._environment = {"CONTAINER_HOST": "unix:///attacker/socket"}
        guard._timeout = 1.0

        with patch.object(
            legacy_runtime,
            "_run_exact_container_command",
            side_effect=AssertionError("endpoint-bound cleanup must not spawn directly"),
        ):
            result = guard._run(("ps", "--all"), time.monotonic() + 1)

        self.assertEqual(result, (0, b"", b""))
        self.assertEqual(len(binding.calls), 1)
        runtime, arguments, timeout_seconds = binding.calls[0]
        self.assertIs(runtime, guard._runtime_binding)
        self.assertEqual(arguments, ["ps", "--all"])
        self.assertGreater(timeout_seconds, 0)

    def test_endpoint_binding_is_not_closed_before_extinction_and_receipt_release(
        self,
    ) -> None:
        """The broker remains armed through final cleanup and receipt release."""

        class EndpointBinding:
            def __init__(self) -> None:
                self.close_calls = 0
                self.release_calls = []

            def release_effect(self, effect) -> None:
                if not effect._extinction_proven:
                    raise AssertionError("effect released without extinction")
                self.release_calls.append(effect)

            def close(self) -> None:
                self.close_calls += 1

        binding = EndpointBinding()
        supervisor = legacy_runtime.WorkerExtinctionSupervisor()
        guard = object.__new__(legacy_runtime._ExternalContainerSupervisor)
        guard._lock = threading.RLock()
        guard._closed = False
        guard._extinction_proven = False
        guard._endpoint_binding = binding
        guard._cidfile_parent_fd = -1
        guard._runtime_fd = -1
        guard._supervisor = supervisor

        with self.assertRaises(legacy_runtime.WorkerExtinctionError):
            guard._close_proven()
        self.assertEqual(binding.close_calls, 0)

        guard._extinction_proven = True
        guard._close_proven()

        self.assertTrue(guard._closed)
        self.assertEqual(binding.close_calls, 0)
        self.assertEqual(binding.release_calls, [guard])

    def test_final_inventory_rejects_delayed_duplicate_invocation_token(self) -> None:
        """The exact ID and token inventories must both be empty twice."""

        container_id = "a" * 64
        duplicate_id = "b" * 64
        calls: list[tuple[str, ...]] = []
        token_inventory_checks = 0
        guard = object.__new__(legacy_runtime._ExternalContainerSupervisor)
        guard._invocation_token = "c" * 64

        def run(arguments: tuple[str, ...], _deadline: float):
            nonlocal token_inventory_checks
            calls.append(arguments)
            if arguments[-1].startswith("id="):
                return 0, b"", b""
            token_inventory_checks += 1
            return (
                0,
                b"" if token_inventory_checks == 1 else f"{duplicate_id}\n".encode(),
                b"",
            )

        guard._run = run
        with self.assertRaises(legacy_runtime.WorkerExtinctionError):
            guard._prove_absent(container_id, time.monotonic() + 1)

        self.assertEqual(
            calls,
            [
                ("ps", "--all", "--quiet", "--no-trunc", "--filter", f"id={container_id}"),
                (
                    "ps",
                    "--all",
                    "--quiet",
                    "--no-trunc",
                    "--filter",
                    f"label=homeric.invocation={'c' * 64}",
                ),
                ("ps", "--all", "--quiet", "--no-trunc", "--filter", f"id={container_id}"),
                (
                    "ps",
                    "--all",
                    "--quiet",
                    "--no-trunc",
                    "--filter",
                    f"label=homeric.invocation={'c' * 64}",
                ),
            ],
        )

    def _authority(self, name: str, token: str) -> dict[str, object]:
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        descriptor = os.open(directory.name, os.O_RDONLY)
        self.addCleanup(os.close, descriptor)
        return {
            "container_name": name,
            "invocation_token": token,
            "cidfile_parent_fd": descriptor,
            "cidfile_name": "container.cid",
        }

    def test_precreate_receipt_parent_must_be_owner_private(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            os.chmod(temporary, 0o755)
            descriptor = os.open(temporary, os.O_RDONLY)
            duplicate = -1
            failure: BaseException | None = None
            try:
                try:
                    duplicate, _identity = (
                        legacy_runtime._duplicate_private_directory_descriptor(
                            descriptor
                        )
                    )
                except BaseException as error:
                    failure = error
            finally:
                if duplicate >= 0:
                    os.close(duplicate)
                os.close(descriptor)

        self.assertIsInstance(
            failure,
            legacy_runtime.WorkerContainmentUnavailableError,
        )

    async def test_precreate_cid_authority_survives_parent_path_retarget(
        self,
    ) -> None:
        container_id = "1" * 64
        unrelated_id = "2" * 64
        invocation_token = "3" * 64
        container_name = "homeric-precreate-authority"
        inspection = {
            "Id": container_id,
            "Name": f"/{container_name}",
            "Image": "4" * 64,
            "Config": {
                "Image": "4" * 64,
                "Cmd": ["agent"],
                "Labels": {"homeric.invocation": invocation_token},
            },
            "HostConfig": {},
            "Mounts": [],
            "State": {"Status": "created", "Running": False},
        }
        commands: list[tuple[str, ...]] = []

        def run_exact(
            _runtime_fd: int,
            _environment: dict[str, str],
            arguments: tuple[str, ...],
            _timeout: float,
        ) -> tuple[int, bytes, bytes]:
            commands.append(arguments)
            if arguments[0] == "inspect":
                if arguments[-1] == container_id:
                    return 0, json.dumps(inspection).encode(), b""
                return 1, b"", b"not found"
            if arguments[0] == "ps":
                return 0, b"", b""
            return 0, b"", b""

        class RecordingSupervisor(legacy_runtime.WorkerExtinctionSupervisor):
            async def extinguish_and_terminate(self, _reason: str) -> None:
                self._extinguish_registered_effects()
                self._release_registered_effects()
                raise SystemExit(70)

        with tempfile.TemporaryDirectory() as temporary:
            authority = Path(temporary) / "authority"
            authority.mkdir(mode=0o700)
            retained_parent = os.open(authority, os.O_RDONLY)
            runtime_descriptor = os.open(__file__, os.O_RDONLY)
            supervisor = RecordingSupervisor()
            observed: BaseException | None = None
            try:
                try:
                    with (
                        patch.object(
                            legacy_runtime,
                            "_duplicate_sealed_runtime_descriptor",
                            side_effect=os.dup,
                        ),
                        patch.object(
                            legacy_runtime,
                            "_run_exact_container_command",
                            side_effect=run_exact,
                        ),
                        legacy_runtime.bind_worker_extinction_supervisor(supervisor),
                    ):
                        guard = legacy_runtime.external_container_supervisor(
                            SimpleNamespace(descriptor=runtime_descriptor, sha256="a" * 64),
                            _ControlledEndpoint(),
                            timeout=1,
                            container_name=container_name,
                            invocation_token=invocation_token,
                            cidfile_parent_fd=retained_parent,
                            cidfile_name="container.cid",
                        )
                        guard.__enter__()

                        held_authority = Path(temporary) / "held-authority"
                        authority.rename(held_authority)
                        authority.mkdir(mode=0o700)
                        (authority / "container.cid").write_text(
                            f"{unrelated_id}\n", encoding="ascii"
                        )
                        receipt_fd = os.open(
                            "container.cid",
                            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                            0o600,
                            dir_fd=retained_parent,
                        )
                        try:
                            os.write(
                                receipt_fd,
                                f"{container_id}\n".encode("ascii"),
                            )
                        finally:
                            os.close(receipt_fd)

                        await supervisor.extinguish_and_terminate(
                            "creation failed before caller receipt binding"
                        )
                except BaseException as error:
                    observed = error
            finally:
                os.close(runtime_descriptor)
                os.close(retained_parent)

        self.assertIsInstance(observed, SystemExit)
        self.assertEqual(
            [command[0] for command in commands],
            ["inspect", "stop", "kill", "rm", "ps", "ps", "ps", "ps"],
        )
        self.assertEqual(
            [command[-1] for command in commands if command[0] in {"stop", "kill", "rm"}],
            [container_id, container_id, container_id],
        )
        self.assertNotIn(unrelated_id, "\0".join("\0".join(item) for item in commands))

    async def test_fatal_extinction_uses_only_bound_container_id_before_exit(
        self,
    ) -> None:
        container_id = "a" * 64
        inspection = {
            "Id": container_id,
            "Name": "/bound-agent",
            "Image": "b" * 64,
            "Config": {
                "Image": "b" * 64,
                "Cmd": ["agent", "--once"],
                "Labels": {"homeric.invocation": "c" * 64},
            },
            "HostConfig": {"ReadonlyRootfs": True},
            "Mounts": [],
            "State": {"Status": "created", "Running": False},
        }
        binding_digest = legacy_runtime.container_binding_digest(inspection)
        commands: list[tuple[str, ...]] = []
        environments: list[dict[str, str]] = []

        def run_exact(
            _runtime_fd: int,
            environment: dict[str, str],
            arguments: tuple[str, ...],
            _timeout: float,
        ) -> tuple[int, bytes, bytes]:
            commands.append(arguments)
            environments.append(dict(environment))
            if arguments[0] == "inspect":
                return 0, json.dumps(inspection).encode(), b""
            if arguments[0] == "ps":
                return 0, b"", b""
            return 0, b"", b""

        class RecordingSupervisor(legacy_runtime.WorkerExtinctionSupervisor):
            def __init__(self) -> None:
                super().__init__()
                self.events: list[str] = []

            async def extinguish_and_terminate(self, reason: str) -> None:
                self.events.append(reason)
                self._extinguish_registered_effects()
                self._release_registered_effects()
                self.events.append("terminate")
                raise SystemExit(70)

        environment = {"PATH": "/usr/bin:/bin", "LC_ALL": "C"}
        supervisor = RecordingSupervisor()
        descriptor = os.open(__file__, os.O_RDONLY)
        try:
            with (
                patch.object(
                    legacy_runtime,
                    "_duplicate_sealed_runtime_descriptor",
                    side_effect=os.dup,
                    create=True,
                ),
                patch.object(
                    legacy_runtime,
                    "_run_exact_container_command",
                    side_effect=run_exact,
                    create=True,
                ),
                legacy_runtime.bind_worker_extinction_supervisor(supervisor),
                legacy_runtime.external_container_supervisor(
                    SimpleNamespace(descriptor=descriptor, sha256="a" * 64),
                    _ControlledEndpoint(),
                    timeout=1,
                    **self._authority("bound-agent", "c" * 64),
                ) as guard,
            ):
                os.close(descriptor)
                descriptor = -1
                environment["LC_ALL"] = "hostile-mutation"
                guard.bind_exact_container(container_id, binding_digest)
                with self.assertRaises(SystemExit):
                    await supervisor.extinguish_and_terminate("fatal deadline")
        finally:
            if descriptor >= 0:
                os.close(descriptor)

        self.assertEqual(
            [command[0] for command in commands],
            ["inspect", "stop", "kill", "rm", "ps", "ps", "ps", "ps"],
        )
        for command in commands:
            rendered = "\0".join(command)
            self.assertNotIn("bound-agent", rendered)
            if command[0] != "ps":
                self.assertEqual(command[-1], container_id)
            else:
                self.assertIn(
                    command[-1],
                    {
                        f"id={container_id}",
                        f"label=homeric.invocation={'c' * 64}",
                    },
                )
        self.assertTrue(all(item["LC_ALL"] == "C" for item in environments))
        self.assertEqual(supervisor.events, ["fatal deadline", "terminate"])

    async def test_nonempty_exact_inventory_blocks_worker_termination(
        self,
    ) -> None:
        container_id = "d" * 64
        inspection = {
            "Id": container_id,
            "Name": "/still-live",
            "Image": "e" * 64,
            "Config": {
                "Image": "e" * 64,
                "Cmd": ["agent"],
                "Labels": {"homeric.invocation": "6" * 64},
            },
            "HostConfig": {},
            "Mounts": [],
        }
        inventory_empty = False

        def run_exact(
            _runtime_fd: int,
            _environment: dict[str, str],
            arguments: tuple[str, ...],
            _timeout: float,
        ) -> tuple[int, bytes, bytes]:
            if arguments[0] == "inspect":
                return 0, json.dumps(inspection).encode(), b""
            if arguments[0] == "ps":
                return (
                    0,
                    b"" if inventory_empty else f"{container_id}\n".encode(),
                    b"",
                )
            return 0, b"", b""

        class RefusingSupervisor(legacy_runtime.WorkerExtinctionSupervisor):
            def __init__(self) -> None:
                super().__init__()
                self.terminated = False

            async def extinguish_and_terminate(self, _reason: str) -> None:
                self._extinguish_registered_effects()
                self.terminated = True
                raise SystemExit(70)

        supervisor = RefusingSupervisor()
        descriptor = os.open(__file__, os.O_RDONLY)
        guard = None
        try:
            with (
                patch.object(
                    legacy_runtime,
                    "_duplicate_sealed_runtime_descriptor",
                    side_effect=os.dup,
                ),
                patch.object(
                    legacy_runtime,
                    "_run_exact_container_command",
                    side_effect=run_exact,
                ),
                legacy_runtime.bind_worker_extinction_supervisor(supervisor),
            ):
                guard = legacy_runtime.external_container_supervisor(
                    SimpleNamespace(descriptor=descriptor, sha256="a" * 64),
                    _ControlledEndpoint(),
                    timeout=1,
                    **self._authority("still-live", "6" * 64),
                )
                guard.__enter__()
                guard.bind_exact_container(
                    container_id,
                    legacy_runtime.container_binding_digest(inspection),
                )
                with self.assertRaises(legacy_runtime.WorkerExtinctionError):
                    await supervisor.extinguish_and_terminate("fatal deadline")
                self.assertFalse(supervisor.terminated)
                inventory_empty = True
                guard._extinguish()
                guard._close_proven()
        finally:
            if guard is not None and not guard._closed:
                inventory_empty = True
                guard._extinguish()
                guard._close_proven()
            os.close(descriptor)

    async def test_container_receipt_remains_armed_when_process_proof_fails(
        self,
    ) -> None:
        container_id = "f" * 64
        inspection = {
            "Id": container_id,
            "Name": "/retained-receipt",
            "Image": "a" * 64,
            "Config": {
                "Image": "a" * 64,
                "Cmd": ["agent"],
                "Labels": {"homeric.invocation": "7" * 64},
            },
            "HostConfig": {},
            "Mounts": [],
        }

        def run_exact(
            _runtime_fd: int,
            _environment: dict[str, str],
            arguments: tuple[str, ...],
            _timeout: float,
        ) -> tuple[int, bytes, bytes]:
            if arguments[0] == "inspect":
                return 0, json.dumps(inspection).encode(), b""
            return 0, b"", b""

        class FailingProcessProof(legacy_runtime.WorkerExtinctionSupervisor):
            async def extinguish_and_terminate(self, _reason: str) -> None:
                self._extinguish_registered_effects()
                raise legacy_runtime.WorkerExtinctionError(
                    "descendant proof failed"
                )

        supervisor = FailingProcessProof()
        descriptor = os.open(__file__, os.O_RDONLY)
        guard = None
        try:
            with (
                patch.object(
                    legacy_runtime,
                    "_duplicate_sealed_runtime_descriptor",
                    side_effect=os.dup,
                ),
                patch.object(
                    legacy_runtime,
                    "_run_exact_container_command",
                    side_effect=run_exact,
                ),
                legacy_runtime.bind_worker_extinction_supervisor(supervisor),
            ):
                guard = legacy_runtime.external_container_supervisor(
                    SimpleNamespace(descriptor=descriptor, sha256="a" * 64),
                    _ControlledEndpoint(),
                    timeout=1,
                    **self._authority("retained-receipt", "7" * 64),
                )
                guard.__enter__()
                guard.bind_exact_container(
                    container_id,
                    legacy_runtime.container_binding_digest(inspection),
                )
                with self.assertRaises(legacy_runtime.WorkerExtinctionError):
                    await supervisor.extinguish_and_terminate("fatal deadline")
                self.assertFalse(
                    guard._closed,
                    "container receipt was discarded before process proof",
                )
                self.assertIn(guard, supervisor._external_effects)
        finally:
            if guard is not None and not guard._closed:
                guard._close_proven()
            os.close(descriptor)

    def test_linux_extinction_orders_barrier_and_receipt_release(self) -> None:
        supervisor = object.__new__(
            legacy_runtime.LinuxWorkerExtinctionSupervisor
        )
        legacy_runtime.WorkerExtinctionSupervisor.__init__(supervisor)
        supervisor._closed = False
        events: list[str] = []
        supervisor._extinguish_registered_effects = lambda: events.append(
            "external-proof"
        )
        supervisor._install_no_spawn_barrier = lambda: events.append(
            "kernel-barrier"
        )
        supervisor._extinguish_descendants = lambda: events.append(
            "descendant-proof"
        )
        supervisor._release_registered_effects = lambda: events.append(
            "receipt-release"
        )

        supervisor._extinguish_owned_effects()

        self.assertEqual(
            events,
            [
                "kernel-barrier",
                "descendant-proof",
                "external-proof",
                "receipt-release",
            ],
        )

    def test_delayed_container_publication_is_checked_after_creator_extinction(
        self,
    ) -> None:
        supervisor = object.__new__(
            legacy_runtime.LinuxWorkerExtinctionSupervisor
        )
        legacy_runtime.WorkerExtinctionSupervisor.__init__(supervisor)
        supervisor._closed = False
        events: list[str] = []
        creator_live = True
        container_published = False

        class DelayedContainerEffect:
            def _extinguish(self) -> None:
                nonlocal container_published
                events.append("container-inventory")
                if not creator_live:
                    container_published = False

            def _close_proven(self) -> None:
                if container_published:
                    raise legacy_runtime.WorkerExtinctionError(
                        "container appeared after the terminal inventory"
                    )
                supervisor._unregister_external_effect(self)

        effect = DelayedContainerEffect()
        supervisor._register_external_effect(effect)
        supervisor._install_no_spawn_barrier = lambda: events.append(
            "kernel-barrier"
        )

        def extinguish_creator() -> None:
            nonlocal creator_live, container_published
            events.append("creator-extinction")
            creator_live = False
            container_published = True

        supervisor._extinguish_descendants = extinguish_creator

        supervisor._extinguish_owned_effects()

        self.assertFalse(container_published)
        self.assertEqual(
            events,
            ["kernel-barrier", "creator-extinction", "container-inventory"],
        )

    def test_container_binding_digest_ignores_state_but_binds_configuration(
        self,
    ) -> None:
        inspection = {
            "Id": "a" * 64,
            "Name": "/bound-agent",
            "Image": "b" * 64,
            "Config": {"Image": "b" * 64, "Cmd": ["agent"]},
            "HostConfig": {"ReadonlyRootfs": True},
            "Mounts": [],
            "State": {"Status": "created", "Running": False},
        }
        running = json.loads(json.dumps(inspection))
        running["State"] = {"Status": "running", "Running": True}
        changed = json.loads(json.dumps(inspection))
        changed["Config"]["Cmd"] = ["other"]

        self.assertEqual(
            legacy_runtime.container_binding_digest(inspection),
            legacy_runtime.container_binding_digest(running),
        )
        self.assertNotEqual(
            legacy_runtime.container_binding_digest(inspection),
            legacy_runtime.container_binding_digest(changed),
        )

    def test_pod_binding_digest_ignores_phase_but_binds_infra_and_netns(
        self,
    ) -> None:
        inspection = {
            "Id": "a" * 64,
            "Name": "/bound-pod",
            "Labels": {"homeric.invocation": "b" * 64},
            "InfraContainerID": "c" * 64,
            "SharedNamespaces": ["net"],
            "NumContainers": 1,
            "State": "Created",
        }
        running = json.loads(json.dumps(inspection))
        running["NumContainers"] = 2
        running["State"] = "Running"
        changed = json.loads(json.dumps(inspection))
        changed["InfraContainerID"] = "d" * 64
        no_network = json.loads(json.dumps(inspection))
        no_network["SharedNamespaces"] = ["ipc"]

        self.assertEqual(
            legacy_runtime.pod_binding_digest(inspection),
            legacy_runtime.pod_binding_digest(running),
        )
        self.assertNotEqual(
            legacy_runtime.pod_binding_digest(inspection),
            legacy_runtime.pod_binding_digest(changed),
        )
        with self.assertRaises(ValueError):
            legacy_runtime.pod_binding_digest(no_network)


class InputBoundTest(unittest.TestCase):
    def test_preopen_quota_rejects_wal_and_aggregate_boundary_overflow(
        self,
    ) -> None:
        database = [(1, 1, 1)]
        with self.assertRaises(legacy_runtime.StateConflictError):
            legacy_runtime.RuntimeStore._verify_preopen_durable_budget(
                database,
                {"state.sqlite3-wal": (0, 1, 1)},
            )

        admission = (
            legacy_runtime._MAX_DURABLE_STATE_BYTES
            - legacy_runtime._SQLITE_COMMIT_RESERVE_BYTES
        )
        legacy_runtime.RuntimeStore._verify_preopen_durable_budget(
            [(admission, 1, 1)],
            {},
        )
        with self.assertRaises(legacy_runtime.StateConflictError):
            legacy_runtime.RuntimeStore._verify_preopen_durable_budget(
                [(admission + 1, 1, 1)],
                {},
            )

    def test_page_admission_reserves_worst_case_rollback_journal(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary) / "quota.sqlite3"
            with closing(sqlite3.connect(database)) as connection:
                legacy_runtime.RuntimeStore._configure_durable_page_budget(
                    connection
                )
                page_size = connection.execute("PRAGMA page_size").fetchone()[0]
                max_pages = connection.execute(
                    "PRAGMA max_page_count"
                ).fetchone()[0]

        worst_case_main = max_pages * page_size
        worst_case_journal = max_pages * (page_size + 8) + 64 * 1024
        worst_case_dirty_cache = worst_case_main
        self.assertLessEqual(
            worst_case_main
            + worst_case_journal
            + worst_case_dirty_cache
            + legacy_runtime._SQLITE_DIRTY_CACHE_BYTES
            + legacy_runtime._SQLITE_COMMIT_RESERVE_BYTES,
            legacy_runtime._MAX_DURABLE_STATE_BYTES,
        )

    def test_aggregate_durable_allocation_counts_pages_and_sidecars(self) -> None:
        self.assertEqual(
            legacy_runtime._aggregate_durable_allocation_bytes(
                page_size=4096,
                page_count=10,
                database_size=4096,
                sidecar_sizes=(8192, 32768),
            ),
            10 * 4096 + 8192 + 32768,
        )

    def test_iteration_must_fit_sqlite_signed_integer_domain(self) -> None:
        maximum = (1 << 63) - 1
        self.assertEqual(legacy_runtime._validated_iteration(maximum), maximum)
        with self.assertRaises(ValueError):
            legacy_runtime._validated_iteration(maximum + 1)

    def test_json_byte_depth_and_node_limits_fail_closed(self) -> None:
        oversized = "x" * (1024 * 1024 + 1)
        canonical_error: BaseException | None = None
        try:
            legacy_runtime._canonical_json({"value": oversized}, "payload")
        except BaseException as error:
            canonical_error = error
        self.assertIsInstance(canonical_error, ValueError)

        too_deep: object = None
        for _index in range(80):
            too_deep = [too_deep]
        deep_text = "[" * 80 + "null" + "]" * 80
        depth_error: BaseException | None = None
        try:
            legacy_runtime._decode_json(deep_text, "payload")
        except BaseException as error:
            depth_error = error
        self.assertIsInstance(depth_error, legacy_runtime.StateConflictError)

        too_many_nodes = [None] * 20_000
        node_error: BaseException | None = None
        try:
            legacy_runtime._canonical_json(too_many_nodes, "payload")
        except BaseException as error:
            node_error = error
        self.assertIsInstance(node_error, ValueError)


class LinuxSeccompFilterContractTest(unittest.TestCase):
    @staticmethod
    def _capture_x86_64_filter() -> tuple[tuple[int, int, int, int], ...]:
        captured: list[tuple[tuple[int, int, int, int], ...]] = []

        class X86Uname:
            machine = "x86_64"

        class CaptureSyscall:
            restype = ctypes.c_long

            def __call__(
                self,
                _syscall_number: int,
                _operation: int,
                _flags: int,
                program_pointer: object,
            ) -> int:
                program = ctypes.cast(
                    program_pointer,
                    ctypes.POINTER(legacy_runtime._LinuxSockFilterProgram),
                ).contents
                captured.append(
                    tuple(
                        (
                            int(program.filters[index].code),
                            int(program.filters[index].jt),
                            int(program.filters[index].jf),
                            int(program.filters[index].value),
                        )
                        for index in range(program.length)
                    )
                )
                return 0

        class CaptureLibrary:
            syscall = CaptureSyscall()

        def fake_prctl(operation: int, *_arguments: int) -> int:
            if operation == 38:
                return 0
            if operation == 39:
                return 1
            raise AssertionError(f"unexpected prctl operation: {operation}")

        with (
            patch.object(legacy_runtime.os, "uname", return_value=X86Uname()),
            patch.object(
                legacy_runtime,
                "_linux_prctl",
                return_value=fake_prctl,
            ),
            patch.object(
                legacy_runtime.ctypes,
                "CDLL",
                return_value=CaptureLibrary(),
            ),
        ):
            legacy_runtime._install_linux_no_spawn_filter()

        if len(captured) != 1:
            raise AssertionError("seccomp filter was not installed exactly once")
        return captured[0]

    @staticmethod
    def _evaluate_filter(
        instructions: tuple[tuple[int, int, int, int], ...],
        *,
        architecture: int,
        syscall_number: int,
    ) -> int:
        accumulator = 0
        program_counter = 0
        while program_counter < len(instructions):
            code, jump_true, jump_false, value = instructions[program_counter]
            if code == 0x20:
                if value == 0:
                    accumulator = syscall_number
                elif value == 4:
                    accumulator = architecture
                else:
                    raise AssertionError(
                        f"unexpected seccomp_data offset: {value}"
                    )
                program_counter += 1
                continue
            if code == 0x15:
                program_counter += (
                    jump_true if accumulator == value else jump_false
                ) + 1
                continue
            if code == 0x45:
                program_counter += (
                    jump_true if accumulator & value else jump_false
                ) + 1
                continue
            if code == 0x06:
                return value
            raise AssertionError(f"unexpected BPF instruction: {code:#x}")
        raise AssertionError("seccomp filter terminated without a verdict")

    def test_filter_fails_closed_for_architecture_and_x32_syscalls(
        self,
    ) -> None:
        instructions = self._capture_x86_64_filter()
        cases = {
            "native-allowed": (0xC000003E, 39, 0x7FFF0000),
            "native-clone-denied": (
                0xC000003E,
                56,
                0x00050000 | errno.EPERM,
            ),
            "aarch64-confusion-kills": (0xC00000B7, 39, 0x80000000),
            "x32-clone-denied": (
                0xC000003E,
                0x40000000 | 56,
                0x00050000 | errno.EPERM,
            ),
            "x32-exec-denied": (
                0xC000003E,
                0x40000000 | 520,
                0x00050000 | errno.EPERM,
            ),
        }
        for name, (architecture, syscall_number, expected) in cases.items():
            with self.subTest(name=name):
                self.assertEqual(
                    self._evaluate_filter(
                        instructions,
                        architecture=architecture,
                        syscall_number=syscall_number,
                    ),
                    expected,
                )


@unittest.skipUnless(
    sys.platform.startswith("linux"),
    "raw seccomp syscall proof requires Linux",
)
class LinuxSeccompAbiProofTest(unittest.TestCase):
    def test_raw_alternate_abi_spawn_syscalls_are_denied(self) -> None:
        read_fd, write_fd = os.pipe()
        child_pid = os.fork()
        if child_pid == 0:
            os.close(read_fd)
            exit_code = 1
            result: dict[str, object]
            try:
                machine = os.uname().machine.casefold()
                legacy_runtime._install_linux_no_spawn_filter()
                library = ctypes.CDLL(None, use_errno=True)
                syscall = library.syscall
                syscall.restype = ctypes.c_long
                if machine in {"x86_64", "amd64"}:
                    probes = (
                        (0x40000000 | 56, 0xFFFFFFFFFFFFFFFF),
                        (0x40000000 | 520, 0),
                    )
                elif machine in {"aarch64", "arm64"}:
                    probes = ((435, 0),)
                else:
                    raise AssertionError(
                        f"no raw seccomp proof exists for {machine!r}"
                    )
                outcomes: list[dict[str, int]] = []
                for syscall_number, first_argument in probes:
                    ctypes.set_errno(0)
                    syscall_result = syscall(
                        ctypes.c_long(syscall_number),
                        ctypes.c_ulong(first_argument),
                        ctypes.c_ulong(0),
                        ctypes.c_ulong(0),
                        ctypes.c_ulong(0),
                        ctypes.c_ulong(0),
                        ctypes.c_ulong(0),
                    )
                    outcomes.append(
                        {
                            "syscall": syscall_number,
                            "result": int(syscall_result),
                            "errno": ctypes.get_errno(),
                        }
                    )
                result = {
                    "machine": machine,
                    "outcomes": outcomes,
                }
                if all(
                    outcome["result"] == -1
                    and outcome["errno"] == errno.EPERM
                    for outcome in outcomes
                ):
                    exit_code = 0
            except BaseException as error:
                result = {
                    "error": f"{type(error).__name__}: {error}",
                }
            payload = json.dumps(result, sort_keys=True).encode("utf-8")
            os.write(write_fd, payload[:4096])
            os.close(write_fd)
            os._exit(exit_code)

        os.close(write_fd)
        deadline = time.monotonic() + 10
        status = None
        while time.monotonic() < deadline:
            waited, candidate_status = os.waitpid(child_pid, os.WNOHANG)
            if waited == child_pid:
                status = candidate_status
                break
            time.sleep(0.01)
        if status is None:
            os.kill(child_pid, signal.SIGKILL)
            _waited, status = os.waitpid(child_pid, 0)
        payload = os.read(read_fd, 4097)
        os.close(read_fd)
        self.assertLessEqual(len(payload), 4096)
        decoded = json.loads(payload.decode("utf-8")) if payload else {}
        self.assertEqual(
            os.waitstatus_to_exitcode(status),
            0,
            f"alternate-ABI raw syscall bypassed containment: {decoded!r}",
        )
        outcomes = decoded.get("outcomes")
        self.assertIsInstance(outcomes, list)
        self.assertTrue(outcomes)
        self.assertTrue(
            all(
                outcome.get("result") == -1
                and outcome.get("errno") == errno.EPERM
                for outcome in outcomes
            ),
            outcomes,
        )


@unittest.skipUnless(
    sys.platform.startswith("linux"),
    "process-group extinction proof requires Linux /proc",
)
class ProcessBoundaryTest(unittest.TestCase):
    def test_bounded_process_caps_output_and_extinguishes_descendants(self) -> None:
        output_error: BaseException | None = None
        try:
            legacy_runtime._run_bounded_process(
                [
                    sys.executable,
                    "-c",
                    "import os; os.write(1, b'x' * 4096)",
                ],
                env={"PATH": "/usr/bin:/bin"},
                pass_fds=(),
                timeout=1,
                output_limit=64,
            )
        except BaseException as error:
            output_error = error
        self.assertIsInstance(output_error, legacy_runtime.StateLocationError)

        with tempfile.TemporaryDirectory() as temporary:
            pid_path = Path(temporary) / "descendant.pid"
            script = (
                "import pathlib, subprocess, sys, time; "
                "child = subprocess.Popen([sys.executable, '-c', "
                "'import time; time.sleep(30)']); "
                "pathlib.Path(sys.argv[1]).write_text(str(child.pid)); "
                "time.sleep(30)"
            )
            timeout_error: BaseException | None = None
            try:
                legacy_runtime._run_bounded_process(
                    [sys.executable, "-c", script, str(pid_path)],
                    env={"PATH": "/usr/bin:/bin"},
                    pass_fds=(),
                    timeout=0.2,
                    output_limit=1024,
                )
            except BaseException as error:
                timeout_error = error
            self.assertIsInstance(timeout_error, legacy_runtime.StateLocationError)
            descendant_pid = int(pid_path.read_text(encoding="utf-8"))
            proc_stat = Path(f"/proc/{descendant_pid}/stat")
            if proc_stat.exists():
                state = proc_stat.read_text(encoding="utf-8").split()[2]
                self.assertEqual(state, "Z", "descendant remained executable")


class LinuxWorkerExtinctionControlTest(unittest.TestCase):
    def test_inherited_cgroup_authority_consumes_launcher_source_fd(
        self,
    ) -> None:
        closed: list[int] = []

        class Library:
            @staticmethod
            def fstatfs(descriptor, target):
                self.assertEqual(descriptor, 51)
                ctypes.cast(target, ctypes.POINTER(ctypes.c_long))[0] = 0x63677270
                return 0

        with (
            patch.object(legacy_runtime.sys, "platform", "linux"),
            patch.dict(
                legacy_runtime.os.environ,
                {"ODYSSEUS_CGROUP_PARENT_FD": "50"},
                clear=False,
            ),
            patch.object(legacy_runtime.os, "dup", return_value=51),
            patch.object(legacy_runtime.os, "set_inheritable"),
            patch.object(
                legacy_runtime.os,
                "fstat",
                return_value=SimpleNamespace(st_mode=stat.S_IFDIR | 0o700),
            ),
            patch.object(legacy_runtime.ctypes, "CDLL", return_value=Library()),
            patch.object(
                legacy_runtime,
                "_read_cgroup_control",
                side_effect=("memory pids\n", "\n"),
            ),
            patch.object(legacy_runtime.os, "close", side_effect=closed.append),
        ):
            descriptor = legacy_runtime.inherited_cgroup_v2_parent_fd()

        self.assertEqual(descriptor, 51)
        self.assertEqual(closed, [50])

    def test_cgroup_guardian_requires_kill_authority_before_prepare(self) -> None:
        incomplete = SimpleNamespace(
            write_control=lambda _name, _value: None,
            read_control=lambda _name: "0",
            verify_stopped_worker=lambda _process, _pidfd: None,
            attach_process=lambda _process: None,
            read_processes=lambda: (),
            release_process=lambda _pidfd: None,
            pidfd_exited=lambda _pidfd: True,
            read_events=lambda: {"populated": 0, "frozen": 0},
        )
        with self.assertRaises(
            legacy_runtime.WorkerContainmentUnavailableError
        ):
            legacy_runtime._ParentCgroupGuardian(
                incomplete,
                legacy_runtime.LinuxWorkerLimits(
                    pids_max=1,
                    memory_max_bytes=1024,
                    pidfd_cap=1,
                ),
            )

    def test_cgroup_limits_attach_and_extinction_are_strictly_ordered(
        self,
    ) -> None:
        class Ops:
            def __init__(self) -> None:
                self.controls: dict[str, str] = {}
                self.events: list[str] = []
                self.attached = False
                self.event_states = iter(
                    (
                        {"populated": 0, "frozen": 0},
                        {"populated": 1, "frozen": 0},
                        {"populated": 1, "frozen": 1},
                        {"populated": 0, "frozen": 1},
                    )
                )

            def write_control(self, name, value):
                self.events.append(f"write:{name}={value}")
                self.controls[name] = value

            def read_control(self, name):
                self.events.append(f"read:{name}")
                return self.controls[name]

            def verify_kill_control(self):
                self.events.append("verify:cgroup.kill")

            def verify_stopped_worker(self, process_id, pidfd):
                self.events.append(f"stopped:{process_id}:{pidfd}")

            def attach_process(self, process_id):
                self.events.append(f"attach:{process_id}")
                self.attached = True

            def read_processes(self):
                self.events.append("read:cgroup.procs")
                return (4242,) if self.attached else ()

            def release_process(self, pidfd):
                self.events.append(f"go:{pidfd}")

            def pidfd_exited(self, pidfd):
                self.events.append(f"pidfd-exited:{pidfd}")
                return True

            def read_events(self):
                self.events.append("read:cgroup.events")
                return next(self.event_states)

        ops = Ops()
        guardian = legacy_runtime._ParentCgroupGuardian(
            ops,
            legacy_runtime.LinuxWorkerLimits(
                pids_max=8,
                memory_max_bytes=256 * 1024 * 1024,
                pidfd_cap=8,
                extinction_timeout=1,
            ),
        )
        guardian.prepare()
        guardian.admit(4242, 77)
        guardian.extinguish(77)

        go_index = ops.events.index("go:77")
        for expected in (
            "write:pids.max=8",
            "read:pids.max",
            f"write:memory.max={256 * 1024 * 1024}",
            "read:memory.max",
            "write:memory.swap.max=0",
            "read:memory.swap.max",
            "write:memory.oom.group=1",
            "read:memory.oom.group",
            "write:cgroup.freeze=0",
            "read:cgroup.freeze",
            "verify:cgroup.kill",
            "attach:4242",
            "read:cgroup.procs",
        ):
            self.assertLess(ops.events.index(expected), go_index)
        freeze = ops.events.index("write:cgroup.freeze=1")
        kill = ops.events.index("write:cgroup.kill=1")
        self.assertLess(freeze, kill)
        self.assertEqual(ops.events[-1], "read:cgroup.events")

    def test_pidfd_cap_rejects_cap_plus_one_and_reclaims_reaped_slot(
        self,
    ) -> None:
        supervisor = object.__new__(
            legacy_runtime.LinuxWorkerExtinctionSupervisor
        )
        legacy_runtime.WorkerExtinctionSupervisor.__init__(supervisor)
        supervisor._process_lock = threading.RLock()
        supervisor._owned_processes = {
            101: (1, 11),
            102: (2, 12),
        }
        supervisor._cleanup_executors = {}
        supervisor._max_tracked_descendants = 2

        with patch.object(
            legacy_runtime, "_linux_process_identity", return_value=(103, 3)
        ), patch.object(
            legacy_runtime.os, "pidfd_open", return_value=13, create=True
        ) as pidfd_open:
            with self.assertRaises(legacy_runtime.WorkerExtinctionError):
                supervisor._track_process(103)
            pidfd_open.assert_not_called()

        closed: list[int] = []
        with patch.object(
            supervisor, "_pidfd_exited", side_effect=lambda fd: fd == 11
        ), patch.object(
            legacy_runtime.os, "waitpid", return_value=(101, 0)
        ), patch.object(
            legacy_runtime.os, "close", side_effect=closed.append
        ):
            supervisor._reap_owned_processes()
        self.assertNotIn(101, supervisor._owned_processes)
        self.assertEqual(closed, [11])

        with patch.object(
            legacy_runtime,
            "_linux_process_identity",
            side_effect=[(103, 3), (103, 3)],
        ), patch.object(
            legacy_runtime.os, "pidfd_open", return_value=13, create=True
        ) as pidfd_open:
            self.assertTrue(supervisor._track_process(103))
            pidfd_open.assert_called_once_with(103, 0)


@unittest.skipUnless(
    sys.platform.startswith("linux")
    and os.environ.get("HOMERIC_RUN_CGROUP_KERNEL_TESTS") == "1",
    "NON_PROOF_SKIP: authoritative cgroup proof requires Linux and HOMERIC_RUN_CGROUP_KERNEL_TESTS=1",
)
class LinuxCgroupAggregateProofTest(unittest.TestCase):
    @staticmethod
    def _parent_fd():
        # Preserve the operator's launcher authority across independent tests;
        # each invocation consumes only its explicitly handed-off duplicate.
        source = int(os.environ["ODYSSEUS_CGROUP_PARENT_FD"])
        handoff = os.dup(source)
        with patch.dict(os.environ, {"ODYSSEUS_CGROUP_PARENT_FD": str(handoff)}):
            return legacy_runtime.inherited_cgroup_v2_parent_fd()

    def test_real_harness_handoff_precedes_asyncio_and_hides_all_controller_fds(self):
        source = self._parent_fd()
        try:
            before = set(os.listdir(source))
            for name in ("claude-myrmidon.py", "claude-myrmidon-multi.py"):
                with self.subTest(harness=name):
                    program = r'''
import asyncio, importlib.util, json, os, pathlib, sys
source_path = os.readlink('/proc/self/fd/' + os.environ['ODYSSEUS_CGROUP_PARENT_FD'])
spec = importlib.util.spec_from_file_location('handoff_probe', sys.argv[1])
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
original_run = asyncio.run
admitted = False
def checked_run(coro, *args, **kwargs):
    global admitted
    entry = next(line[3:] for line in pathlib.Path('/proc/self/cgroup').read_text().splitlines() if line.startswith('0::'))
    group = pathlib.Path('/sys/fs/cgroup') / entry.lstrip('/')
    assert os.getpid() in {int(v) for v in (group / 'cgroup.procs').read_text().split()}
    for key, value in {'pids.max': '256', 'memory.max': str(4 * 1024**3), 'memory.swap.max': '0'}.items():
        assert (group / key).read_text().strip() == value, key
    for fd in os.listdir('/proc/self/fd'):
        try: target = os.readlink('/proc/self/fd/' + fd)
        except FileNotFoundError: continue
        assert target != source_path and not target.startswith(source_path + '/'), (fd, target)
    admitted = True
    return original_run(coro, *args, **kwargs)
async def probe(supervisor):
    assert admitted, 'main ran before cgroup/FD checks'
    assert supervisor._cgroup_managed and supervisor._pidfd_cap == 256
    os.write(1, b'{"admitted":true,"limits":true,"no_controller_fds":true}\n')
asyncio.run = checked_run
module._main = probe
sys.exit(module.main())
'''
                    environment = dict(os.environ, ODYSSEUS_CGROUP_PARENT_FD=str(source), DRY_RUN="1", NO_GITHUB="1")
                    result = subprocess.run(
                        [sys.executable, "-c", program, str(Path(legacy_runtime.__file__).with_name(name))],
                        env=environment, pass_fds=(source,), capture_output=True, text=True, timeout=30,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout),
                                     {"admitted": True, "limits": True, "no_controller_fds": True})
                    self.assertEqual(set(os.listdir(source)), before, "child cgroup survived parent cleanup")
        finally:
            os.close(source)

    def test_abrupt_worker_fanout_is_killed_before_parent_returns(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            inventory = Path(temporary) / "fanout.json"

            async def worker_main(
                _supervisor: legacy_runtime.LinuxWorkerExtinctionSupervisor,
            ) -> None:
                read_fd, write_fd = os.pipe()
                intermediates: list[int] = []
                for _index in range(8):
                    process_id = os.fork()
                    if process_id == 0:
                        os.close(read_fd)
                        os.setsid()
                        descendant = os.fork()
                        if descendant == 0:
                            os.close(write_fd)
                            while True:
                                signal.pause()
                        os.write(write_fd, f"{descendant}\n".encode("ascii"))
                        os.close(write_fd)
                        os._exit(0)
                    intermediates.append(process_id)
                os.close(write_fd)
                payload = bytearray()
                while True:
                    chunk = os.read(read_fd, 4096)
                    if not chunk:
                        break
                    payload.extend(chunk)
                os.close(read_fd)
                for process_id in intermediates:
                    os.waitpid(process_id, 0)
                descendants = sorted(
                    int(value) for value in payload.decode("ascii").splitlines()
                )
                if len(descendants) != 8:
                    os._exit(71)
                inventory.write_text(
                    json.dumps(descendants), encoding="utf-8"
                )
                os._exit(0)

            parent_fd = self._parent_fd()
            try:
                exit_code = legacy_runtime.run_linux_cgroup_worker(
                    worker_main,
                    cgroup_parent_fd=parent_fd,
                    limits=legacy_runtime.LinuxWorkerLimits(
                        pids_max=32,
                        memory_max_bytes=256 * 1024 * 1024,
                        pidfd_cap=32,
                        extinction_timeout=5,
                    ),
                )
            finally:
                os.close(parent_fd)
            self.assertEqual(exit_code, 0)
            descendants = json.loads(inventory.read_text(encoding="utf-8"))
            self.assertEqual(len(descendants), 8)
            for process_id in descendants:
                record = legacy_runtime._linux_process_record(process_id)
                self.assertTrue(
                    record is None or record[1] == "Z",
                    f"cgroup descendant {process_id} remained executable",
                )


@unittest.skipUnless(
    sys.platform.startswith("linux"),
    "worker subreaper/pidfd extinction proof requires Linux",
)
class LinuxWorkerExtinctionProofTest(unittest.TestCase):
    def test_setsid_double_forks_from_worker_and_cleanup_executor_are_extinct(
        self,
    ) -> None:
        container_id = "a" * 64
        inspection = {
            "Id": container_id,
            "Name": "/proof-agent",
            "Image": "b" * 64,
            "Config": {
                "Image": "b" * 64,
                "Cmd": ["proof-agent"],
                "Labels": {"homeric.invocation": "c" * 64},
            },
            "HostConfig": {"ReadonlyRootfs": True},
            "Mounts": [],
            "State": {"Status": "created", "Running": False},
        }
        inspection_text = json.dumps(inspection, separators=(",", ":"))
        script = f"""#!/bin/sh
set -eu
container_id={container_id}
last=
for argument in "$@"; do last=$argument; done
case "${{1:-}}" in
  inspect)
    [ "$last" = "$container_id" ] || exit 64
    printf '%s\\n' '{inspection_text}'
    ;;
  stop)
    [ "$last" = "$container_id" ] || exit 65
    /usr/bin/python3 -c 'import os, pathlib, sys, time; r,w=os.pipe(); first=os.fork(); os.close(w) if first else os.close(r); os.read(r,1) if first else None; os.waitpid(first,0) if first else None; os._exit(0) if first else None; os.setsid(); second=os.fork(); os._exit(0) if second else None; os.close(1); os.close(2); pathlib.Path(sys.argv[1]).write_text(str(os.getpid())); os.write(w,b"R"); os.close(w); time.sleep(60)' "${{FAKE_CLEANUP_DESCENDANT_PID:?}}"
    printf '0\\n' > "${{FAKE_CONTAINER_STATE:?}}"
    ;;
  kill|rm)
    [ "$last" = "$container_id" ] || exit 65
    printf '0\\n' > "${{FAKE_CONTAINER_STATE:?}}"
    ;;
  ps)
    [ "$last" = "id=$container_id" ] || [ "$last" = "label=homeric.invocation=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc" ] || exit 66
    state=
    IFS= read -r state < "${{FAKE_CONTAINER_STATE:?}}"
    if [ "$state" = 1 ]; then printf '%s\\n' "$container_id"; fi
    ;;
  *) exit 67 ;;
esac
""".encode()
        read_fd, write_fd = os.pipe()
        with tempfile.TemporaryDirectory(dir="/var/tmp") as temporary:
            receipt_parent_fd = os.open(temporary, os.O_RDONLY)
            state_path = Path(temporary) / "container.state"
            state_path.write_text("1\n", encoding="ascii")
            pid_path = Path(temporary) / "descendant.pid"
            cleanup_pid_path = Path(temporary) / "cleanup-descendant.pid"
            script = script.replace(b"${FAKE_CONTAINER_STATE:?}", os.fsencode(state_path))
            script = script.replace(b"${FAKE_CLEANUP_DESCENDANT_PID:?}", os.fsencode(cleanup_pid_path))
            runtime_fd = os.memfd_create(
                "legacy-runtime-proof",
                os.MFD_ALLOW_SEALING,
            )
            view = memoryview(script)
            while view:
                written = os.write(runtime_fd, view)
                self.assertGreater(written, 0)
                view = view[written:]
            os.fchmod(runtime_fd, 0o500)
            required_seals = (
                fcntl.F_SEAL_SEAL
                | fcntl.F_SEAL_SHRINK
                | fcntl.F_SEAL_GROW
                | fcntl.F_SEAL_WRITE
            )
            fcntl.fcntl(runtime_fd, fcntl.F_ADD_SEALS, required_seals)
            self.assertEqual(
                fcntl.fcntl(runtime_fd, fcntl.F_GET_SEALS) & required_seals,
                required_seals,
            )

            endpoint_path = Path(temporary) / "podman.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            self.addCleanup(listener.close)
            listener.bind(str(endpoint_path))
            child_pid = os.fork()
            if child_pid == 0:
                os.close(read_fd)
                exit_code = 0
                result: dict[str, object]
                try:
                    with legacy_runtime.LinuxWorkerExtinctionSupervisor(
                        timeout=5
                    ) as supervisor:
                        late_fork = threading.Event()
                        late_result: list[int | None] = []

                        def attempt_late_fork() -> None:
                            late_fork.wait(10)
                            try:
                                forked = os.fork()
                            except OSError as error:
                                late_result.append(error.errno)
                                return
                            if forked == 0:
                                os._exit(90)
                            os.waitpid(forked, 0)
                            late_result.append(None)

                        late_thread = threading.Thread(target=attempt_late_fork)
                        late_thread.start()
                        with (
                            patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{endpoint_path}"}),
                            legacy_athena.trusted_container_endpoint("podman") as endpoint_binding,
                            legacy_runtime.bind_worker_extinction_supervisor(
                                supervisor
                            ),
                            legacy_runtime.external_container_supervisor(
                                legacy_athena._BoundExecutable(runtime_fd, "d" * 64),
                                endpoint_binding,
                                timeout=2,
                                container_name="proof-agent",
                                invocation_token="c" * 64,
                                cidfile_parent_fd=receipt_parent_fd,
                                cidfile_name="container.cid",
                            ) as guard,
                        ):
                            guard.bind_exact_container(
                                container_id,
                                legacy_runtime.container_binding_digest(
                                    inspection
                                ),
                            )
                            double_fork = (
                                "import os, pathlib, sys, time; "
                                "first = os.fork(); "
                                "os._exit(0) if first else None; "
                                "os.setsid(); "
                                "second = os.fork(); "
                                "os._exit(0) if second else None; "
                                "state = pathlib.Path('/proc/self/stat').read_text(); "
                                "start = state[state.rfind(')') + 2:].split()[19]; "
                                "pathlib.Path(sys.argv[1]).write_text("
                                "f'{os.getpid()}:{start}'); "
                                "time.sleep(60)"
                            )
                            leader = subprocess.Popen(
                                [
                                    sys.executable,
                                    "-c",
                                    double_fork,
                                    str(pid_path),
                                ],
                                close_fds=True,
                            )
                            leader.wait(timeout=5)
                            deadline = time.monotonic() + 5
                            while (
                                not pid_path.exists()
                                and time.monotonic() < deadline
                            ):
                                time.sleep(0.01)
                            if not pid_path.exists():
                                raise AssertionError(
                                    "double-fork descendant did not publish its PID"
                                )
                            published_pid, published_start = pid_path.read_text(
                                encoding="ascii"
                            ).split(":", 1)
                            descendant_pid = int(published_pid)
                            descendant_start = int(published_start)
                            if legacy_runtime._linux_process_identity(
                                descendant_pid
                            ) != (descendant_pid, descendant_start):
                                raise AssertionError(
                                    "double-fork descendant identity drifted"
                                )
                            if not Path(f"/proc/{descendant_pid}").exists():
                                raise AssertionError(
                                    "double-fork descendant exited before proof"
                                )

                            supervisor._extinguish_owned_effects()

                            late_fork.set()
                            late_thread.join(timeout=5)
                            if late_thread.is_alive():
                                raise AssertionError(
                                    "late-fork probe did not finish"
                                )
                            if late_result != [errno.EPERM]:
                                raise AssertionError(
                                    f"late fork was not denied: {late_result!r}"
                                )
                            if state_path.read_text(encoding="ascii") != "0\n":
                                raise AssertionError(
                                    "exact container receipt remained live"
                                )
                            if Path(f"/proc/{descendant_pid}").exists():
                                raise AssertionError(
                                    "double-fork descendant survived extinction"
                                )
                            if not cleanup_pid_path.exists():
                                raise AssertionError(
                                    "cleanup executor descendant did not publish its PID"
                                )
                            cleanup_descendant_pid = int(
                                cleanup_pid_path.read_text(encoding="ascii")
                            )
                            if Path(
                                f"/proc/{cleanup_descendant_pid}"
                            ).exists():
                                raise AssertionError(
                                    "cleanup executor double-fork descendant survived final sweep"
                                )
                            if not guard._closed:
                                raise AssertionError(
                                    "container receipt was not released last"
                                )
                    result = {"ok": True}
                except BaseException as error:
                    exit_code = 1
                    result = {
                        "ok": False,
                        "error": f"{type(error).__name__}: {error}",
                    }
                payload = json.dumps(result, sort_keys=True).encode("utf-8")
                os.write(write_fd, payload[:16_384])
                os.close(write_fd)
                os._exit(exit_code)

            os.close(write_fd)
            deadline = time.monotonic() + 20
            status = None
            escaped_pidfd = -1
            while time.monotonic() < deadline:
                if escaped_pidfd < 0 and pid_path.exists():
                    published_pid, published_start = pid_path.read_text(
                        encoding="ascii"
                    ).split(":", 1)
                    escaped_identity = (int(published_pid), int(published_start))
                    if (
                        legacy_runtime._linux_process_identity(
                            escaped_identity[0]
                        )
                        == escaped_identity
                    ):
                        candidate_pidfd = os.pidfd_open(escaped_identity[0], 0)
                        if (
                            legacy_runtime._linux_process_identity(
                                escaped_identity[0]
                            )
                            == escaped_identity
                        ):
                            escaped_pidfd = candidate_pidfd
                        else:
                            os.close(candidate_pidfd)
                waited, candidate_status = os.waitpid(child_pid, os.WNOHANG)
                if waited == child_pid:
                    status = candidate_status
                    break
                time.sleep(0.02)
            if status is None:
                os.kill(child_pid, signal.SIGKILL)
                _waited, status = os.waitpid(child_pid, 0)
            payload = os.read(read_fd, 16_385)
            os.close(read_fd)
            if escaped_pidfd >= 0:
                try:
                    signal.pidfd_send_signal(
                        escaped_pidfd,
                        signal.SIGKILL,
                        None,
                        0,
                    )
                except ProcessLookupError:
                    pass
                os.close(escaped_pidfd)
            os.close(runtime_fd)
            os.close(receipt_parent_fd)

        self.assertLessEqual(len(payload), 16_384)
        decoded = json.loads(payload.decode("utf-8")) if payload else {}
        self.assertEqual(
            os.waitstatus_to_exitcode(status),
            0,
            decoded.get("error", "Linux containment child failed silently"),
        )
        self.assertEqual(decoded, {"ok": True})


if __name__ == "__main__":
    unittest.main()
