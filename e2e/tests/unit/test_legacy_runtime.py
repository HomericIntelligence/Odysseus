"""Behavior tests for the legacy myrmidon single-host runtime state.

These tests use disposable Git repositories and local process/file primitives.
They do not require NATS, Tailscale, a container runtime, or network access.
"""

from __future__ import annotations

import asyncio
from concurrent.futures import ThreadPoolExecutor
from contextlib import closing
import hashlib
import multiprocessing
import os
import subprocess
import sqlite3
import stat
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from unittest.mock import patch


_E2E_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_E2E_ROOT) not in sys.path:
    sys.path.insert(0, str(_E2E_ROOT))

import legacy_runtime  # noqa: E402


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
            state = legacy_runtime.state_root(root)
            database = state / "state.sqlite3"
            with patch.dict(
                os.environ,
                {"HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid())},
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
            {"HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid())},
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

    def _store(self, *, host_id: str = "host-a") -> legacy_runtime.RuntimeStore:
        return legacy_runtime.runtime_store(
            self.root,
            self.repo,
            self.registry_digest,
            host_id=host_id,
            service_uid=os.geteuid(),
            message_retention_seconds=3600,
            duplicate_window_seconds=120,
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


class FileLeaseTest(unittest.TestCase):
    def setUp(self) -> None:
        self.service_uid_environment = patch.dict(
            os.environ,
            {"HOMERIC_LEGACY_SERVICE_UID": str(os.geteuid())},
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

    def test_lock_namespace_fails_closed_when_an_ancestor_is_replaced(self) -> None:
        checkout_key = hashlib.sha256(str(self.root.resolve()).encode()).hexdigest()
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


class ConsumerWorkerTest(unittest.IsolatedAsyncioTestCase):
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


if __name__ == "__main__":
    unittest.main()
