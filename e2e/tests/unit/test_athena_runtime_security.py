"""Security regressions for the dependency-locked Athena runtime boundary."""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import ctypes
import errno
import json
import os
from pathlib import Path
import signal
import socket
import stat
import struct
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch


_E2E_ROOT = Path(__file__).resolve().parent.parent.parent
if str(_E2E_ROOT) not in sys.path:
    sys.path.insert(0, str(_E2E_ROOT))

import athena_readonly_chain  # noqa: E402
import legacy_athena  # noqa: E402


class AthenaRuntimeSecurityTest(unittest.TestCase):
    @unittest.skipUnless(sys.platform == "linux", "NON_PROOF_SKIP: real durable store/lease recovery requires Linux descriptor SQLite")
    def test_persisted_receipt_reconciles_under_fresh_store_session_before_takeover(self):
        self._exercise_persisted_recovery(fail_first=False)

    @unittest.skipUnless(sys.platform == "linux", "NON_PROOF_SKIP: real durable store/lease recovery requires Linux descriptor SQLite")
    def test_persisted_receipt_failure_and_cancellation_preserve_lease_and_guard(self):
        self._exercise_persisted_recovery(fail_first=True)

    @unittest.skipUnless(sys.platform == "linux", "NON_PROOF_SKIP: cleanup cancellation needs real Linux durable lease")
    def test_persisted_receipt_cancellation_cannot_release_lease_during_sync_cleanup(self):
        self._exercise_persisted_recovery(fail_first=False, cancel_cleanup=True)

    def _exercise_persisted_recovery(self, *, fail_first, cancel_cleanup=False):
        import legacy_runtime
        import test_legacy_runtime as runtime_tests
        with self._storage_binding() as (first, info, _):
            root = Path(info["store"]["graphRoot"]).parent / "repo"
            runtime_tests._init_repo(root)
            first.bind_storage_authority(object(), "podman")
            identity = first.durable_effect_identity()
            inspection = {"Id": "a" * 64, "Name": "/recovery-agent", "Image": "c" * 64,
                          "Config": {"Image": "c" * 64, "Labels": {"homeric.invocation": "b" * 64}},
                          "HostConfig": {}, "Mounts": []}
            digest = legacy_runtime.container_binding_digest(inspection)
            environment = dict(os.environ, HOMERIC_LEGACY_SERVICE_UID=str(os.geteuid()),
                               HOMERIC_LEGACY_CANDIDATE_UID=str(65534 if os.geteuid() != 65534 else 65533))
            # Process one drives the real durable dispatch/effect admission,
            # then dies without Python cleanup, leaving a persisted receipt.
            writer = r'''
import asyncio, json, os, pathlib, sys
sys.path.insert(0, sys.argv[2])
import legacy_runtime as r
data = json.load(sys.stdin)
store = r.runtime_store(pathlib.Path(sys.argv[1]), 'HomericIntelligence/Odysseus', 'f'*64,
                        host_id='recovery-host', service_uid=os.geteuid(),
                        message_retention_seconds=3600, duplicate_window_seconds=120)
class Message:
    async def in_progress(self): pass
    async def ack(self): raise AssertionError('abandoned effect cannot ACK')
async def reconcile(receipt): raise AssertionError('no previous delivery')
async def handler(message):
    with r.external_effect_supervisor('container', {
        'container_name': 'recovery-agent', 'invocation_token': 'b'*64,
        'engine_endpoint_identity': data['identity'],
    }, lambda receipt: (_ for _ in ()).throw(AssertionError('crash skips cleanup'))) as effect:
        effect.bind_exact({'container_id':'a'*64, 'binding_digest':data['digest']})
        os._exit(0)
asyncio.run(r._dispatch_with_heartbeat(Message(), handler, .01, 1, 1,
    extinction_supervisor=r.WorkerExtinctionSupervisor(),
    delivery_authority=r.DurableDispatchAuthority(store, lambda message:'e'*64, reconcile)))
'''
            result = subprocess.run([sys.executable, "-c", writer, str(root), str(_E2E_ROOT)],
                                    input=json.dumps({"identity": identity, "digest": digest}),
                                    env=environment, capture_output=True, text=True, timeout=15)
            self.assertEqual(result.returncode, 0, result.stderr)
            with patch.dict(os.environ, environment):
                reopened = legacy_runtime.runtime_store(root, "HomericIntelligence/Odysseus", "f" * 64,
                                                        host_id="recovery-host", service_uid=os.geteuid(),
                                                        message_retention_seconds=3600, duplicate_window_seconds=120)
                prior_claim = reopened.inspect_message_delivery("e" * 64)
                self.assertEqual(len(reopened.active_external_effects("e" * 64)), 1)

                # Process two has a new authenticated socket and volatile runRoot.
                first._storage_authority.close()
                first._storage_authority = None
                second = object.__new__(legacy_athena._ContainerEndpointBinding)
                second._lock = threading.RLock()
                second._closed = second._retired = second._poisoned = False
                second._storage_authority = None
                second._endpoint_path = first._endpoint_path + "-restarted"
                second._socket_identity = {**first._socket_identity, "ino": 999}
                info["host"]["remoteSocket"]["path"] = second._endpoint_path
                old_run = Path(info["store"]["runRoot"])
                old_run.rename(old_run.with_name("retired-run"))
                old_run.mkdir()
                commands, live = [], [True]
                unavailable = [False]
                cancellation = {}
                def command(runtime, argv, **kwargs):
                    if argv == ["info", "--format=json"]:
                        if unavailable[0]:
                            raise legacy_athena.AthenaEvidenceError("controlled disconnected session")
                        return subprocess.CompletedProcess(argv, 0, json.dumps(info), "")
                    commands.append(list(argv))
                    output, code = "", 0
                    if argv[0] == "inspect":
                        output, code = (json.dumps(inspection), 0) if live[0] else ("", 1)
                    elif argv[0] in {"stop", "kill", "rm"}:
                        self.assertEqual(argv[-1], inspection["Id"])
                        if argv[0] == "rm":
                            if cancellation:
                                observations = []
                                def contend():
                                    try:
                                        lease = reopened.acquire_message_delivery_lease("e" * 64, timeout=.05)
                                    except legacy_runtime.LeaseUnavailableError:
                                        observations.append("lease-held-during-cleanup")
                                    else:
                                        lease.close()
                                        observations.append("unsafe-early-release")
                                    cancellation["loop"].call_soon_threadsafe(cancellation["task"].cancel)
                                contender = threading.Thread(target=contend)
                                contender.start()
                                contender.join(timeout=2)
                                self.assertFalse(contender.is_alive())
                                self.assertTrue(live[0])
                                self.assertEqual(observations, ["lease-held-during-cleanup"])
                                cancellation.clear()
                            live[0] = False
                    elif argv[0] == "ps":
                        output = inspection["Id"] + "\n" if live[0] else ""
                    else:
                        raise AssertionError(argv)
                    return subprocess.CompletedProcess(argv, code, output, "")
                second.enter_command = command
                second.bind_storage_authority(object(), "podman")
                self.assertEqual(second.durable_effect_identity(), identity)
                bound = self._sealed_python_runtime()
                async def scenario():
                    nonlocal second
                    heartbeat = asyncio.Event()
                    class Message(runtime_tests._Message):
                        async def in_progress(self):
                            await super().in_progress()
                            heartbeat.set()
                    message = Message(1)
                    calls = []
                    async def handler(_message):
                        self.assertFalse(live[0])
                        self.assertEqual(reopened.active_external_effects("e" * 64), ())
                        self.assertNotEqual(reopened.inspect_message_delivery("e" * 64), prior_claim)
                        calls.append("takeover")
                    async def reconcile(receipt):
                        return legacy_runtime.reconcile_external_container_effect(receipt, bound, second, 5)
                    authority = legacy_runtime.DurableDispatchAuthority(reopened, lambda message: "e" * 64, reconcile)
                    if cancel_cleanup:
                        task = asyncio.create_task(legacy_runtime._dispatch_with_heartbeat(
                            message, handler, .01, 1, 1, delivery_authority=authority))
                        cancellation.update(loop=asyncio.get_running_loop(), task=task)
                        with self.assertRaises(asyncio.CancelledError):
                            await task
                        self.assertFalse(live[0], "cancelled dispatcher returned before exact cleanup")
                        self.assertEqual(calls, [])
                        self.assertEqual((message.acks, message.naks, message.terms), (0, 0, 0))
                        self.assertEqual(reopened.inspect_message_delivery("e" * 64), prior_claim)
                    if fail_first:
                        unavailable[0] = True
                        task = asyncio.create_task(legacy_runtime._dispatch_with_heartbeat(
                            message, handler, .01, 1, 1, delivery_authority=authority))
                        try:
                            await asyncio.wait_for(heartbeat.wait(), 2)
                            with self.assertRaises(legacy_runtime.LeaseUnavailableError):
                                await asyncio.to_thread(reopened.acquire_message_delivery_lease, "e" * 64, timeout=.05)
                            self.assertEqual(commands, [])
                            self.assertTrue(live[0])
                            self.assertEqual(calls, [])
                        finally:
                            task.cancel()
                            with self.assertRaises(asyncio.CancelledError):
                                await task
                        self.assertEqual((message.acks, message.naks, message.terms), (0, 0, 0))
                        self.assertEqual(reopened.inspect_message_delivery("e" * 64), prior_claim)
                        self.assertEqual(len(reopened.active_external_effects("e" * 64)), 1)
                        unavailable[0] = False
                        second._storage_authority.close()
                        replacement = object.__new__(legacy_athena._ContainerEndpointBinding)
                        replacement._lock = threading.RLock()
                        replacement._closed = replacement._retired = replacement._poisoned = False
                        replacement._storage_authority = None
                        replacement._endpoint_path = second._endpoint_path + "-retry"
                        replacement._socket_identity = {**second._socket_identity, "ino": 1000}
                        replacement.enter_command = command
                        second = replacement
                        info["host"]["remoteSocket"]["path"] = second._endpoint_path
                        second.bind_storage_authority(object(), "podman")
                    await asyncio.wait_for(legacy_runtime._dispatch_with_heartbeat(
                        message, handler, .01, 1, 1, delivery_authority=authority), 5)
                    self.assertEqual(calls, ["takeover"])
                    self.assertEqual((message.acks, message.naks), (1, 0))
                    self.assertIsNone(reopened.inspect_message_delivery("e" * 64))
                    inventories = sum(argv[0] == "ps" for argv in commands)
                    self.assertIn(inventories, (4, 8) if cancel_cleanup else (4,))
                try:
                    asyncio.run(scenario())
                finally:
                    bound.close()
                    second._storage_authority.close()

    @contextlib.contextmanager
    def _storage_binding(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary).resolve()
            graph, run = root / "graph", root / "run"
            graph.mkdir()
            run.mkdir()
            endpoint = object.__new__(legacy_athena._ContainerEndpointBinding)
            endpoint._lock = threading.RLock()
            endpoint._closed = endpoint._retired = endpoint._poisoned = False
            endpoint._endpoint_path = str(root / "podman.sock")
            endpoint._socket_identity = {"dev": 1, "ino": 2, "uid": os.geteuid(),
                                         "gid": os.getegid(), "mode": 0o140600}
            endpoint._storage_authority = None
            info = {"host": {"serviceIsRemote": True,
                              "remoteSocket": {"path": endpoint._endpoint_path},
                              "security": {"rootless": True},
                              "idMappings": {"uidmap": [{"container_id": 0, "host_id": os.geteuid(), "size": 1},
                                                        {"container_id": 1, "host_id": 100000, "size": 65536}],
                                             "gidmap": [{"container_id": 0, "host_id": os.getegid(), "size": 1},
                                                        {"container_id": 1, "host_id": 100000, "size": 65536}]}},
                    "store": {"graphRoot": str(graph), "runRoot": str(run),
                              "graphDriverName": "overlay", "transientStore": False}}
            commands = []
            def command(runtime, argv, **kwargs):
                commands.append(argv)
                self.assertEqual(argv, ["info", "--format=json"])
                return subprocess.CompletedProcess(argv, 0, json.dumps(info), "")
            endpoint.enter_command = command
            try:
                yield endpoint, info, commands
            finally:
                if endpoint._storage_authority is not None:
                    endpoint._storage_authority.close()

    def test_storage_identity_accepts_service_restart_same_store_and_socket_spellings(self):
        with self._storage_binding() as (endpoint, info, _commands):
            endpoint.bind_storage_authority(object(), "podman")
            first = endpoint.durable_effect_identity()
            info["host"].update(pid=918, uptime="restarted")
            info["host"]["remoteSocket"].update(path="unix://" + endpoint._endpoint_path, exists=True)
            self.assertEqual(endpoint.durable_effect_identity(), first)
            first["store"]["graphDriverName"] = "mutated returned object"
            self.assertEqual(endpoint.durable_effect_identity()["store"]["graphDriverName"], "overlay")
            expected = endpoint.durable_effect_identity()
            endpoint._storage_authority.close()
            endpoint._storage_authority = None
            endpoint.bind_storage_authority(object(), "podman")
            self.assertEqual(endpoint.durable_effect_identity(), expected)

    def test_storage_identity_rejects_changed_store_and_replaced_directory(self):
        for replacement in ("store", "directory"):
            with self.subTest(replacement=replacement), self._storage_binding() as (endpoint, info, _):
                endpoint.bind_storage_authority(object(), "podman")
                graph = Path(info["store"]["graphRoot"])
                if replacement == "directory":
                    graph.rename(graph.with_name("old"))
                    graph.mkdir()
                else:
                    other = graph.with_name("other")
                    other.mkdir()
                    info["store"]["graphRoot"] = str(other)
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    endpoint.durable_effect_identity()

    def test_storage_identity_accepts_local_service_is_remote_false(self):
        with self._storage_binding() as (endpoint, info, _):
            info["host"]["serviceIsRemote"] = False
            endpoint.bind_storage_authority(object(), "podman")
            self.assertIs(endpoint._storage_authority.expected["serviceIsRemote"], False)

    def test_storage_initial_admission_rejects_unsafe_rootless_authority(self):
        mutations = {
            "rootful": lambda i: i["host"]["security"].update(rootless=False),
            "transient": lambda i: i["store"].update(transientStore=True),
            "wrong-service": lambda i: i["host"]["idMappings"]["uidmap"][0].update(host_id=31337),
            "wrong-group": lambda i: i["host"]["idMappings"]["gidmap"][0].update(host_id=31337),
            "container-overlap": lambda i: i["host"]["idMappings"]["uidmap"][1].update(container_id=0),
            "host-overlap": lambda i: i["host"]["idMappings"]["uidmap"][1].update(host_id=os.geteuid()),
            "container-gap": lambda i: i["host"]["idMappings"]["uidmap"][1].update(container_id=2),
            "overflow": lambda i: i["host"]["idMappings"]["uidmap"][1].update(host_id=2**32-2),
            "host-root": lambda i: i["host"]["idMappings"]["uidmap"][1].update(host_id=0),
        }
        for name, mutate in mutations.items():
            with self.subTest(name=name), self._storage_binding() as (endpoint, info, _):
                mutate(info)
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    endpoint.bind_storage_authority(object(), "podman")

    def test_storage_initial_admission_requires_service_owned_socket(self):
        for key, value in (("uid", 31337), ("gid", 31337), ("mode", 0o140666)):
            with self.subTest(key=key), self._storage_binding() as (endpoint, _info, _):
                endpoint._socket_identity[key] = value
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    endpoint.bind_storage_authority(object(), "podman")

    def test_durable_store_identity_survives_authenticated_new_session(self):
        with self._storage_binding() as (endpoint, info, _):
            endpoint.bind_storage_authority(object(), "podman")
            durable = endpoint.durable_effect_identity()
            endpoint._storage_authority.close()
            endpoint._storage_authority = None
            endpoint._endpoint_path += "-new"
            endpoint._socket_identity["ino"] += 1
            info["host"]["remoteSocket"]["path"] = endpoint._endpoint_path
            run = Path(info["store"]["runRoot"])
            run.rename(run.with_name("old-run"))
            run.mkdir()
            endpoint.bind_storage_authority(object(), "podman")
            self.assertEqual(endpoint.durable_effect_identity(), durable)

    def test_storage_identity_mismatch_executes_no_container_reconciliation_commands(self):
        import legacy_runtime
        for replacement in ("new-store", "replaced-path"):
            with self.subTest(replacement=replacement), self._storage_binding() as (endpoint, info, commands):
                endpoint.bind_storage_authority(object(), "podman")
                identity = endpoint.durable_effect_identity()
                receipt = legacy_runtime.ExternalEffectReceipt(
                    "a" * 64, "event", "container",
                    {"container_name": "controlled-container", "invocation_token": "b" * 64,
                     "engine_endpoint_identity": identity}, None,
                )
                original = Path(info["store"]["graphRoot"])
                original.rename(original.with_name("retained-old"))
                original.mkdir()
                # Model a fresh worker: it honestly binds the replacement store,
                # then must refuse the older persisted effect before any inventory.
                endpoint._storage_authority.close()
                endpoint._storage_authority = None
                endpoint.bind_storage_authority(object(), "podman")
                commands.clear()
                with self.assertRaises(legacy_runtime.WorkerExtinctionError):
                    legacy_runtime.reconcile_external_container_effect(
                        receipt, object(), endpoint, 5,
                    )
                self.assertEqual(commands, [["info", "--format=json"]])

    def test_storage_identity_rejects_unproven_or_changed_routing_and_modes(self):
        mutations = (
            lambda i: i["host"]["remoteSocket"].update(path="ssh://remote/run/podman.sock"),
            lambda i: i["host"]["remoteSocket"].update(exists=False),
            lambda i: i["host"].update(serviceIsRemote=False),
            lambda i: i["host"]["security"].update(rootless=False),
            lambda i: i["host"]["idMappings"]["uidmap"][0].update(host_id=12345),
            lambda i: i["store"].update(graphDriverName="vfs"),
            lambda i: i["store"].update(transientStore=True),
            lambda i: i["store"].update(runRoot="/unstatable/nonexistent/store"),
        )
        for mutate in mutations:
            with self.subTest(mutation=mutate), self._storage_binding() as (endpoint, info, _):
                endpoint.bind_storage_authority(object(), "podman")
                mutate(info)
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    endpoint.durable_effect_identity()

    def test_spawn_preserves_descriptor_paths_in_git_environment_and_cwd(self) -> None:
        captured = {}
        def observe(_executable, command, environment, **options):
            captured.update(command=command, environment=environment, options=options)
            raise OSError("controlled pre-spawn boundary")
        with tempfile.TemporaryFile() as retained, tempfile.TemporaryFile() as status:
            source = retained.fileno()
            path = f"/proc/self/fd/{source}/index"
            binding = SimpleNamespace(descriptor=source, execution_path=f"/proc/self/fd/{source}")
            with patch.object(legacy_athena.os, "posix_spawn", side_effect=observe):
                with self.assertRaisesRegex(OSError, "controlled pre-spawn"):
                    legacy_athena._spawn_owned_process(
                        ["git", "-C", f"/proc/self/fd/{source}/worktree"],
                        executable=None, stdin=subprocess.DEVNULL, status_descriptor=status.fileno(),
                        cwd=f"/proc/self/fd/{source}/worktree",
                        environment={"GIT_INDEX_FILE": path}, owner={"process": None, "streams": []},
                        pass_fds=(source,), supervisor_binding=binding,
                    )
            destinations = [action[2] for action in captured["options"]["file_actions"]
                            if action[0] == os.POSIX_SPAWN_DUP2 and action[1] == source]
            destination = destinations[-1]
            self.assertEqual(captured["environment"]["GIT_INDEX_FILE"],
                             f"/proc/self/fd/{destination}/index")
            self.assertEqual(captured["command"].count(f"/proc/self/fd/{destination}/worktree"), 2)

    @staticmethod
    def _sealed_python_runtime():
        source = legacy_athena._trusted_python_executable()
        try:
            return legacy_athena._sealed_executable_snapshot(
                source.descriptor, os.fstat(source.descriptor)
            )
        finally:
            source.close()

    @unittest.skipUnless(sys.platform == "darwin", "Darwin libproc lifecycle regression")
    def test_darwin_extinction_distinguishes_live_unreaped_and_reaped_children(self) -> None:
        probe = getattr(legacy_athena, "_darwin_process_is_extinct", None)
        self.assertTrue(callable(probe), "Darwin extinction requires a kernel zombie-state proof")
        child = subprocess.Popen([sys.executable, "-c", "import sys; sys.stdin.read()"], stdin=subprocess.PIPE)
        try:
            self.assertFalse(probe(child.pid), "an executable process is not extinct")
            child.stdin.close()
            os.waitid(os.P_PID, child.pid, os.WEXITED | os.WNOWAIT)
            os.kill(child.pid, 0)  # The unreaped PID exists but cannot execute.
            self.assertTrue(probe(child.pid))
            child.wait(timeout=2)
            self.assertTrue(probe(child.pid))
        finally:
            if child.returncode is None:
                child.kill()
                child.wait(timeout=2)

    @unittest.skipUnless(sys.platform == "darwin", "Darwin libproc lifecycle regression")
    def test_exited_leader_eperm_still_kills_ready_term_ignoring_descendant(self) -> None:
        program = (
            "import os,signal\n"
            "r,w=os.pipe()\n"
            "child=os.fork()\n"
            "if child==0:\n"
            " os.close(r); os.close(1); os.close(2)\n"
            " signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
            " os.write(w,b'R'); os.close(w)\n"
            " while True: signal.pause()\n"
            "os.close(w); assert os.read(r,1)==b'R'; os.close(r)\n"
            "print(child,flush=True); os._exit(0)\n"
        )
        process = subprocess.Popen(
            [sys.executable, "-I", "-S", "-c", program],
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        child = int(process.stdout.readline())
        os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOWAIT)
        try:
            with patch.object(legacy_athena.os, "killpg", side_effect=PermissionError("ordered EPERM")), patch.object(
                legacy_athena, "PROCESS_TERMINATE_SECONDS", 0
            ):
                legacy_athena._stop_process_group(process)
            info = legacy_athena._DarwinProcessInfo()
            libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
            size = libproc.proc_pidinfo(child, 3, 0, ctypes.byref(info), ctypes.sizeof(info))
            self.assertTrue(
                (size == 0 and ctypes.get_errno() == errno.ESRCH)
                or (size == ctypes.sizeof(info) and info.status == 5),
                "descendant remained executable or its state was unproven",
            )
        finally:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=2)
            process.stdout.close()

    def test_endpoint_broker_program_compiles(self) -> None:
        compile(legacy_athena._ENDPOINT_BROKER, "<endpoint-broker>", "exec")

    def test_endpoint_broker_interrupt_cannot_bypass_spawn_ownership(self) -> None:
        events = []
        process = SimpleNamespace(
            kill=lambda: events.append("kill"),
            wait=lambda **kwargs: events.append("reaped"),
        )
        executable = SimpleNamespace(descriptor=42, execution_path="/proc/self/fd/42", close=lambda: None)

        def interrupted_spawn(*_args, **_kwargs):
            signal.raise_signal(signal.SIGINT)
            return process

        with patch.object(legacy_athena, "_trusted_python_executable", return_value=executable), patch.object(
            legacy_athena.subprocess, "Popen", side_effect=interrupted_spawn,
        ), self.assertRaises(KeyboardInterrupt):
            legacy_athena._ContainerEndpointBinding(42)
        self.assertEqual(events, ["kill", "reaped"])

    def test_broker_transfers_only_client_local_receipt_not_daemon_mount_authority(self) -> None:
        binding = object.__new__(legacy_athena._ContainerEndpointBinding)
        binding._lock = threading.RLock()
        runtime = object.__new__(legacy_athena._BoundExecutable)
        runtime.descriptor = 42
        runtime.execution_path = "/proc/self/fd/42"
        requests = []
        binding._request = lambda request, deadline, descriptors: (
            requests.append((request, descriptors)) or struct.pack("!iII", 0, 0, 0)
        )
        with tempfile.TemporaryDirectory() as temporary:
            receipt = os.open(temporary, os.O_RDONLY)
            mount = os.open(temporary, os.O_RDONLY)
            try:
                arguments = ["create", "--cidfile", f"/proc/{os.getpid()}/fd/{receipt}/container.cid",
                             "--volume", f"/proc/{os.getpid()}/fd/{mount}:/workspace:ro"]
                binding.enter_command(runtime, arguments)
                self.assertEqual(requests[0][0]["references"], [receipt])
                self.assertEqual(requests[0][0]["arguments"], arguments)
                self.assertEqual(len(requests[0][1]), 2)
            finally:
                os.close(receipt)
                os.close(mount)

    def test_broker_preserves_existing_claude_input_and_stderr_bounds(self) -> None:
        binding = object.__new__(legacy_athena._ContainerEndpointBinding)
        binding._lock = threading.RLock()
        runtime = object.__new__(legacy_athena._BoundExecutable)
        runtime.descriptor = 42
        runtime.execution_path = "/proc/self/fd/42"
        stderr = b"e" * (1024 * 1024)
        binding._request = lambda *args: struct.pack("!iII", 0, 0, len(stderr)) + stderr
        result = binding.enter_command(runtime, ["start", "--attach", "c" * 64], input_text="i" * (16 * 1024 * 1024))
        self.assertEqual(len(result.stderr), len(stderr))

    def test_endpoint_close_refuses_registered_external_effects(self) -> None:
        binding = object.__new__(legacy_athena._ContainerEndpointBinding)
        binding._lock = threading.RLock()
        binding._closed = False
        binding._effects = {object(): object()}
        with self.assertRaisesRegex(legacy_athena.AthenaEvidenceError, "registered external effects"):
            binding.close()
        self.assertFalse(binding._closed)

    def test_endpoint_close_is_idempotent_after_exact_retirement(self) -> None:
        binding = object.__new__(legacy_athena._ContainerEndpointBinding)
        binding._lock = threading.RLock()
        binding._closed = False
        binding._effects = {}
        binding._pidfd = 97
        binding._storage_authority = None
        events = []
        binding._retire = lambda: events.append("retired")
        binding._channel = SimpleNamespace(close=lambda: events.append("channel-closed"))
        with patch.object(legacy_athena.os, "close", side_effect=lambda fd: events.append(fd)):
            binding.close()
            binding.close()
        self.assertEqual(events, ["retired", "channel-closed", 97])
        self.assertTrue(binding._closed)

    def test_endpoint_rejects_unbound_runtime_and_invalid_command_bounds_before_rpc(self) -> None:
        binding = object.__new__(legacy_athena._ContainerEndpointBinding)
        runtime = object.__new__(legacy_athena._BoundExecutable)
        runtime.descriptor = 42
        cases = [
            (SimpleNamespace(descriptor=42), ["ps"], None, 1),
            (runtime, [], None, 1),
            (runtime, ["ps"] * 4097, None, 1),
            (runtime, ["x" * 131073], None, 1),
            (runtime, ["ps\0"], None, 1),
            (runtime, ["ps"], None, float("nan")),
            (runtime, ["ps"], None, True),
            (runtime, ["ps"], None, 0),
            (runtime, ["ps"], None, 86401),
            (runtime, ["ps"], "x" * (16 * 1024 * 1024 + 1), 1),
        ]
        for index, (executable, argv, stdin, timeout) in enumerate(cases):
            with self.subTest(index=index), self.assertRaises(legacy_athena.AthenaEvidenceError):
                binding.enter_command(executable, argv, input_text=stdin, timeout_seconds=timeout)

    def test_endpoint_environment_only_direct_spawn_seam_is_rejected(self) -> None:
        with self.assertRaisesRegex(legacy_athena.AthenaEvidenceError, "binding.enter_command"):
            legacy_athena.container_runtime_environment()

    @unittest.skipUnless(sys.platform == "linux", "Linux namespace broker framing proof")
    def test_endpoint_broker_rejects_duplicate_rpc_keys(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "podman.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                with patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{path}"}, clear=True):
                    binding = legacy_athena.trusted_container_endpoint("podman")
                try:
                    invalid = b'{"operation":"close","operation":"close"}'
                    binding._channel.sendall(struct.pack("!I", len(invalid)) + invalid)
                    binding._process.wait(timeout=5)
                    self.assertNotEqual(binding._process.returncode, 0)
                    with self.assertRaises(legacy_athena.AthenaEvidenceError):
                        binding.close()
                    self.assertFalse(binding._closed)
                finally:
                    binding._channel.close()
                    os.close(binding._pidfd)

    def test_endpoint_release_retry_retains_receipt_until_descendant_sweep(self) -> None:
        class Effect:
            _extinction_proven = True

        events = []
        effect = Effect()
        binding = object.__new__(legacy_athena._ContainerEndpointBinding)
        binding._lock = threading.RLock()
        binding._effects = {effect: object()}
        binding._identity = (42, 123)
        binding._executor_registered = True
        binding._retire = lambda: events.append("retire")
        binding._supervisor = SimpleNamespace(
            _unregister_cleanup_executor=lambda identity: events.append("unregister"),
            _extinguish_descendants=lambda: (_ for _ in ()).throw(RuntimeError("sweep interrupted")),
        )
        with self.assertRaisesRegex(RuntimeError, "sweep interrupted"):
            binding.release_effect(effect)
        self.assertIn(effect, binding._effects)
        binding._supervisor._extinguish_descendants = lambda: events.append("swept")
        binding.release_effect(effect)
        self.assertNotIn(effect, binding._effects)
        self.assertEqual(events.count("unregister"), 1)
        self.assertEqual(events[-1], "swept")

    @unittest.skipUnless(sys.platform == "linux", "Linux descriptor transfer and namespace proof")
    def test_endpoint_transfers_retained_directory_without_reopening_parent_path(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            original = root / "authority"
            original.mkdir(mode=0o700)
            directory = os.open(original, os.O_RDONLY | os.O_DIRECTORY)
            path = root / "podman.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                with patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{path}"}, clear=True):
                    binding = legacy_athena.trusted_container_endpoint("podman")
                runtime = self._sealed_python_runtime()
                try:
                    held = root / "held"
                    original.rename(held)
                    original.mkdir(mode=0o700)
                    target = f"/proc/{os.getpid()}/fd/{directory}/container.cid"
                    program = "import sys; open(sys.argv[2],'x').write('bound')"
                    result = binding.enter_command(runtime, ["-I", "-S", "-c", program, "--cidfile", target], timeout_seconds=5)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual((held / "container.cid").read_text(), "bound")
                    self.assertFalse((original / "container.cid").exists())
                finally:
                    os.close(directory)
                    runtime.close()
                    binding.close()

    def test_image_resolution_has_no_direct_spawn_or_environment_fallback(self) -> None:
        calls = []
        reference = "example.invalid/agent@sha256:" + "a" * 64
        runtime = SimpleNamespace(descriptor=42, execution_path="/proc/self/fd/42")

        class Endpoint:
            def enter_command(self, bound, arguments, **options):
                calls.append((bound, arguments, options))
                return subprocess.CompletedProcess(arguments, 0, json.dumps({
                    "Id": "sha256:" + "b" * 64, "RepoDigests": [reference],
                }), "")

        with patch.object(legacy_athena, "_run_bounded_process", side_effect=AssertionError("direct spawn")), patch.object(
            legacy_athena, "container_runtime_environment", side_effect=AssertionError("ambient endpoint")
        ):
            result = legacy_athena.resolve_local_oci_image(
                "podman", reference, runtime_binding=runtime, endpoint_binding=Endpoint(),
            )
        self.assertEqual(result, "sha256:" + "b" * 64)
        self.assertIs(calls[0][0], runtime)
        self.assertEqual(calls[0][1], ["image", "inspect", "--format", "{{json .}}", reference])

    @unittest.skipUnless(sys.platform == "linux", "Linux user/mount namespaces and O_PATH required")
    def test_replaced_rootless_socket_still_reaches_acquired_inode(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "podman.sock"
            original = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            replacement = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            original.bind(str(path))
            original.listen(1)
            original.settimeout(10)
            errors = []

            def serve():
                try:
                    connection, _ = original.accept()
                    with connection:
                        connection.sendall(b"original-inode")
                except BaseException as exc:
                    errors.append(exc)

            with patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{path}"}, clear=True):
                binding = legacy_athena.trusted_container_endpoint("podman")
            runtime = self._sealed_python_runtime()
            server = threading.Thread(target=serve)
            server.start()
            try:
                path.unlink()
                replacement.bind(str(path))
                replacement.listen(1)
                replacement.setblocking(False)
                program = (
                    "import os,socket,stat\n"
                    "for name in os.listdir('/proc/self/fd'):\n"
                    " try: metadata=os.fstat(int(name))\n"
                    " except OSError: continue\n"
                    " assert not stat.S_ISSOCK(metadata.st_mode), 'inherited broker channel'\n"
                    "s=socket.socket(socket.AF_UNIX); "
                    "s.connect(os.environ['CONTAINER_HOST'][7:]); "
                    "print(s.recv(128).decode()); s.close()"
                )
                with patch.object(
                    legacy_athena.subprocess, "Popen",
                    side_effect=AssertionError("parent attempted direct runtime spawn"),
                ):
                    result = binding.enter_command(runtime, ["-I", "-S", "-c", program], timeout_seconds=5)
                self.assertEqual(result.stdout.strip(), "original-inode")
                with self.assertRaises(BlockingIOError):
                    replacement.accept()
                self.assertFalse(errors)
            finally:
                runtime.close()
                binding.close()
                original.close()
                replacement.close()
                server.join(10)

    @unittest.skipUnless(sys.platform == "linux", "Linux broker and pidfds required")
    def test_broker_extinguishes_double_forked_runtime_descendants(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "podman.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                with patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{path}"}, clear=True):
                    binding = legacy_athena.trusted_container_endpoint("podman")
                runtime = self._sealed_python_runtime()
                try:
                    program = (
                        "import os,signal,time\n"
                        "r,w=os.pipe()\n"
                        "if os.fork()==0:\n"
                        " os.close(r); os.setsid()\n"
                        " if os.fork(): os._exit(0)\n"
                        " signal.signal(signal.SIGTERM,signal.SIG_IGN)\n"
                        " os.write(w,str(os.getpid()).encode()); os.close(w)\n"
                        " os.close(1); os.close(2); time.sleep(60); os._exit(0)\n"
                        "os.close(w); print(os.read(r,32).decode(),flush=True); os.close(r)\n"
                    )
                    result = binding.enter_command(runtime, ["-I", "-S", "-c", program], timeout_seconds=5)
                    pid = int(result.stdout.strip())
                    with self.assertRaises(ProcessLookupError):
                        os.kill(pid, 0)
                finally:
                    runtime.close()
                    binding.close()

    @unittest.skipUnless(sys.platform == "linux", "Linux broker and pidfds required")
    def test_broker_loss_poisoning_never_falls_back_to_direct_execution(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "podman.sock"
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
                listener.bind(str(path))
                with patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{path}"}, clear=True):
                    binding = legacy_athena.trusted_container_endpoint("podman")
                runtime = self._sealed_python_runtime()
                try:
                    signal.pidfd_send_signal(binding._pidfd, signal.SIGKILL, None, 0)
                    binding._process.wait(timeout=2)
                    with patch.object(legacy_athena.subprocess, "Popen", side_effect=AssertionError("direct spawn")):
                        with self.assertRaises(legacy_athena.AthenaEvidenceError):
                            binding.enter_command(runtime, ["-c", "print('wrong')"])
                    with self.assertRaises(legacy_athena.AthenaEvidenceError):
                        binding.close()
                    self.assertFalse(binding._closed)
                finally:
                    runtime.close()
                    binding._channel.close()
                    os.close(binding._pidfd)

    def test_endpoint_defaults_ignore_ambient_client_configuration(self) -> None:
        resolve = getattr(legacy_athena, "_container_endpoint_path", None)
        self.assertTrue(callable(resolve), "endpoint defaults need explicit resolution")
        with patch.dict(os.environ, {"HOME": "/hostile", "CONTAINER_HOST": "unix:///bad"}, clear=True):
            self.assertEqual(resolve("podman"), f"/run/user/{os.geteuid()}/podman/podman.sock")
            self.assertEqual(resolve("docker"), "/var/run/docker.sock")
            with self.assertRaises(legacy_athena.AthenaEvidenceError):
                resolve("unknown")
        with patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": "unix:///explicit/socket"}, clear=True):
            self.assertEqual(resolve("/usr/bin/podman"), "/explicit/socket")
        for endpoint in ("tcp://host:1234", "unix://relative", "unix:///tmp/../socket", ""):
            with self.subTest(endpoint=endpoint), patch.dict(os.environ, {"ODYSSEUS_CONTAINER_ENDPOINT": endpoint}, clear=True):
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    resolve("podman")

    def test_endpoint_authority_fails_closed_without_linux_namespaces(self) -> None:
        acquire = getattr(legacy_athena, "trusted_container_endpoint", None)
        self.assertTrue(callable(acquire), "endpoint authority must be prearmed")
        with patch.object(legacy_athena.sys, "platform", "darwin"), patch.object(
            legacy_athena.subprocess, "Popen", side_effect=AssertionError("unsupported host must not spawn")
        ), self.assertRaises(legacy_athena.AthenaEvidenceError):
            acquire("podman")

    def test_darwin_eperm_requires_descendant_extinction_not_only_leader_exit(self) -> None:
        process = SimpleNamespace(pid=12345, returncode=0, wait=lambda **_kwargs: 0)
        with patch.object(legacy_athena.sys, "platform", "darwin"), patch.object(
            legacy_athena.os, "killpg", side_effect=[None, PermissionError("group still has a live child")]
        ), patch.object(legacy_athena, "_child_has_exited", return_value=True), patch.object(
            legacy_athena, "PROCESS_TERMINATE_SECONDS", 0
        ), patch.object(
            legacy_athena, "_darwin_extinguish_group",
            side_effect=legacy_athena.AthenaEvidenceError("live descendant remains"),
        ), self.assertRaises(legacy_athena.AthenaEvidenceError):
            legacy_athena._stop_process_group(process)

    def test_supervisor_uses_kernel_pid_namespace_authority(self) -> None:
        compile(
            legacy_athena._PROCESS_SUPERVISOR,
            "<athena-process-supervisor>",
            "exec",
        )
        self.assertIn("clone_newpid", legacy_athena._PROCESS_SUPERVISOR)
        self.assertIn("clone_newuser", legacy_athena._PROCESS_SUPERVISOR)
        self.assertIn("pidfd_open", legacy_athena._PROCESS_SUPERVISOR)
        self.assertIn("mount_private_proc", legacy_athena._PROCESS_SUPERVISOR)
        self.assertIn(
            "outer_uid = os.geteuid()",
            legacy_athena._PROCESS_SUPERVISOR,
        )
        self.assertIn("if outer_uid == 0", legacy_athena._PROCESS_SUPERVISOR)
        self.assertIn(
            'write_mapping("/proc/self/uid_map", f"1 {outer_uid} 1',
            legacy_athena._PROCESS_SUPERVISOR,
        )
        self.assertIn("st_uid == os.geteuid()", legacy_athena._PROCESS_SUPERVISOR)
        self.assertIn("pr_set_no_new_privs", legacy_athena._PROCESS_SUPERVISOR)
        child_branch = legacy_athena._PROCESS_SUPERVISOR.index(
            "if namespace_process_id == 0:"
        )
        child_launch = legacy_athena._PROCESS_SUPERVISOR.index(
            "namespace_init(ready_write, result_write)", child_branch
        )
        self.assertIn(
            "os.close(acquisition_descriptor)",
            legacy_athena._PROCESS_SUPERVISOR[child_branch:child_launch],
        )
        self.assertIn(
            "os.close(status_descriptor)",
            legacy_athena._PROCESS_SUPERVISOR[child_branch:child_launch],
        )

    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux containment")
    def test_pid_namespace_extinguishes_a_setsid_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            marker = Path(temporary) / "escaped"
            program = (
                "import os,signal,time\n"
                "try:\n os.kill(os.getppid(), signal.SIGKILL)\n"
                "except (PermissionError, ProcessLookupError):\n pass\n"
                "if os.fork() == 0:\n"
                " os.setsid()\n time.sleep(0.5)\n"
                f" open({str(marker)!r}, 'w').write('escaped')\n"
                " os._exit(0)\n"
                "os._exit(0)\n"
            )
            binding = legacy_athena._trusted_python_executable()
            try:
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    legacy_athena._run_bounded_process(
                        [binding.execution_path, "-I", "-S", "-c", program],
                        executable=binding.execution_path,
                        input_text=None,
                        cwd=None,
                        environment={"LANG": "C", "LC_ALL": "C"},
                        timeout_seconds=2.0,
                        pass_fds=(binding.descriptor,),
                    )
            finally:
                binding.close()
            time.sleep(0.6)
            self.assertFalse(marker.exists())

    def test_same_user_executable_is_not_an_independent_trust_anchor(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            executable = Path(temporary) / "gh"
            executable.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
            executable.chmod(0o500)
            with patch.dict(
                os.environ,
                {"ODYSSEUS_GH_EXECUTABLE": str(executable.resolve())},
                clear=True,
            ), patch.object(
                legacy_athena.sys, "platform", "linux"
            ), patch.object(
                legacy_athena,
                "_sealed_executable_snapshot",
                return_value=SimpleNamespace(close=lambda: None),
            ):
                with self.assertRaisesRegex(
                    legacy_athena.AthenaEvidenceError,
                    "independent trust",
                ):
                    legacy_athena._trusted_gh_executable()

    def test_python_dependency_closure_rejects_a_mutable_loaded_module(self) -> None:
        mutable_module = SimpleNamespace(
            __file__="/trusted/module.py",
            __cached__=None,
        )
        mutable_metadata = SimpleNamespace(
            st_mode=stat.S_IFREG | 0o666,
            st_uid=os.geteuid(),
        )
        with patch.dict(
            sys.modules,
            {"odysseus_mutable_dependency": mutable_module},
            clear=False,
        ), patch.object(
            legacy_athena.sysconfig,
            "get_paths",
            return_value={"stdlib": "/trusted", "platstdlib": "/trusted"},
        ), patch.object(
            legacy_athena,
            "_require_independent_directory_trust",
        ), patch.object(
            legacy_athena.os,
            "stat",
            return_value=mutable_metadata,
        ), patch.object(
            legacy_athena.sys,
            "platform",
            "darwin",
        ):
            with self.assertRaisesRegex(
                legacy_athena.AthenaEvidenceError,
                "dependency closure",
            ):
                legacy_athena._python_dependency_closure()

    def test_verified_helper_cannot_reach_ambient_subprocess_commands(self) -> None:
        source = (
            b"import subprocess\n"
            b"subprocess.run(['gh', 'api', 'user'], check=False)\n"
        )
        arguments = argparse.Namespace(
            plugin_root="/verified-athena",
            relative="skills/pr-review/scripts/collect_evidence.py",
            helper_argv=[],
        )
        with patch.object(
            athena_readonly_chain,
            "_verified_plugin_payloads",
            return_value={arguments.relative: source},
        ), patch.object(
            athena_readonly_chain,
            "_synthetic_helper_path",
            return_value="/verified/collect_evidence.py",
        ), patch.object(
            athena_readonly_chain,
            "_verified_import_environment",
            return_value=contextlib.nullcontext(),
        ), patch.object(
            subprocess,
            "run",
            return_value=subprocess.CompletedProcess(["gh"], 0, "", ""),
        ) as ambient:
            with self.assertRaises(athena_readonly_chain.VerificationError):
                athena_readonly_chain._run_verified_helper(arguments)
        ambient.assert_not_called()

    def test_broker_normalizes_nonempty_mutable_input_rejection(self) -> None:
        with patch.object(
            athena_readonly_chain,
            "_admit_broker_command",
            return_value=(("/proc/self/fd/9", "api", "user"), 9),
        ):
            with self.assertRaisesRegex(
                athena_readonly_chain.VerificationError,
                "unsupported subprocess option",
            ):
                athena_readonly_chain._broker_run(
                    ["gh", "api", "user"],
                    input=bytearray(b"untrusted"),
                )

    def test_broker_rejects_encoded_mutations_before_tool_binding(self) -> None:
        unsafe_commands = (
            (["gh", "api", "--method=POST", "repos/o/r/issues"], "mutation"),
            (["gh", "api", "repos/o/r/issues", "-f", "title=pwn"], "mutation"),
            (["gh", "pr", "view", "9", "--web"], "ambient helper"),
            (["gh", "issue", "view", "9", "-w"], "ambient helper"),
            (["git", "config", "--local", "--add", "core.fsmonitor", "evil"], "write"),
            (["git", "fetch", "ext::sh -c evil", "refs/heads/main"], "unsafe"),
            (["git", "fetch", "evil", "https://github.com/o/r.git"], "unsafe"),
            (["git", "fetch", "--exec=evil", "https://github.com/o/r.git"], "unsafe"),
            (["git", "fetch", "https://github.com/o/r.git", "--upload-pack=evil"], "unsafe"),
        )
        for command, diagnostic in unsafe_commands:
            with self.subTest(command=command):
                with self.assertRaisesRegex(
                    athena_readonly_chain.VerificationError,
                    diagnostic,
                ):
                    athena_readonly_chain._admit_broker_command(command)

    def test_broker_admits_only_the_pinned_fetch_grammar(self) -> None:
        command = ["git", "fetch", "--quiet", "--no-tags",
                   "--no-write-fetch-head", "--no-recurse-submodules", "--refmap=",
                   "https://github.com/o/r.git",
                   "+refs/heads/main:refs/athena/base",
                   "+refs/pull/9/head:refs/athena/pr/9/head"]
        with patch.object(athena_readonly_chain, "_inherited_tool_binding",
                          return_value=(9, "/proc/self/fd/9")):
            admitted, descriptor = athena_readonly_chain._admit_broker_command(command)
        self.assertEqual(descriptor, 9)
        self.assertEqual(admitted[1:], tuple(command[1:]))

    def test_container_endpoint_rejects_a_world_writable_parent(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            endpoint_parent = Path(temporary).resolve() / "mutable"
            endpoint_parent.mkdir(mode=0o700)
            endpoint_parent.chmod(0o777)
            endpoint = endpoint_parent / "podman.sock"
            listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            try:
                listener.bind(str(endpoint))
                with patch.dict(
                    os.environ,
                    {"ODYSSEUS_CONTAINER_ENDPOINT": f"unix://{endpoint}"},
                    clear=True,
                ):
                    with self.assertRaisesRegex(
                        legacy_athena.AthenaEvidenceError,
                        "endpoint is unsafe",
                    ):
                        legacy_athena._trusted_container_endpoint()
            finally:
                listener.close()

    def test_linux_cleanup_never_queries_a_reaped_process_group(self) -> None:
        process = object.__new__(legacy_athena._OwnedProcess)
        process.pid = 999_999_999
        process.returncode = 0
        process.supervisor_pidfd = None
        process.containment_pidfd = None
        state = {
            "process": process,
            "readers": [],
            "streams": [],
            "input_stream": None,
            "status_read_descriptor": -1,
            "status_write_descriptor": -1,
        }
        with patch.object(
            legacy_athena.sys,
            "platform",
            "linux",
        ), patch.object(
            legacy_athena,
            "_stop_process_group",
            side_effect=legacy_athena.AthenaEvidenceError("cleanup failed"),
        ), patch.object(
            legacy_athena,
            "_process_group_exists",
        ) as group_exists:
            with self.assertRaisesRegex(
                legacy_athena.AthenaEvidenceError,
                "cleanup failed",
            ):
                legacy_athena._finalize_process_resources(state)
        group_exists.assert_not_called()

    def test_darwin_cleanup_never_retries_reaped_numeric_group(self) -> None:
        process = SimpleNamespace(pid=999_999_999, returncode=0)
        state = {"process": process, "readers": [], "streams": [], "input_stream": None,
                 "status_read_descriptor": -1, "status_write_descriptor": -1}
        with patch.object(legacy_athena.sys, "platform", "darwin"), patch.object(
            legacy_athena, "_stop_process_group",
            side_effect=legacy_athena.AthenaEvidenceError("cleanup failed"),
        ) as stop, patch.object(legacy_athena, "_process_group_exists") as exists:
            with self.assertRaises(legacy_athena.AthenaEvidenceError):
                legacy_athena._finalize_process_resources(state)
        exists.assert_not_called()
        stop.assert_called_once()

    def test_fallback_cleanup_signals_before_reaping_the_leader(self) -> None:
        events: list[str] = []
        process = SimpleNamespace(
            pid=12345,
            returncode=None,
        )
        def reap(**_kwargs):
            events.append("wait")
            process.returncode = 0
            return 0
        process.wait = reap

        def kill_group(_process_group: int, signal_number: int) -> None:
            events.append(f"signal:{signal_number}")

        with patch.object(
            legacy_athena.sys,
            "platform",
            "darwin",
        ), patch.object(
            legacy_athena.os,
            "killpg",
            side_effect=kill_group,
        ), patch.object(
            legacy_athena,
            "_darwin_extinguish_group",
            side_effect=lambda _group: events.append("proof"),
        ):
            legacy_athena._stop_process_group(process)

        first_wait = events.index("wait")
        self.assertIn(f"signal:{signal.SIGTERM}", events[:first_wait])
        self.assertIn(f"signal:{signal.SIGKILL}", events[:first_wait])
        self.assertIn("proof", events[:first_wait])

    def test_chain_cleanup_never_signals_a_reaped_numeric_group(self) -> None:
        process = SimpleNamespace(pid=12345, returncode=0, wait=lambda **_kw: 0)
        with patch.object(athena_readonly_chain.os, "killpg") as signal_group:
            with self.assertRaises(athena_readonly_chain.VerificationError):
                athena_readonly_chain._stop_gh_process_group(process)
        signal_group.assert_not_called()

    def test_portable_cleanup_never_signals_a_reaped_numeric_group(self) -> None:
        process = SimpleNamespace(pid=12345, returncode=0, wait=lambda **_kw: 0)
        with patch.object(legacy_athena.os, "killpg") as signal_group, \
                patch.object(legacy_athena, "_darwin_extinguish_group"):
            with self.assertRaises(legacy_athena.AthenaEvidenceError):
                legacy_athena._stop_process_group(process)
        signal_group.assert_not_called()

    def test_chain_finalization_proves_group_before_reaping(self) -> None:
        events = []
        process = SimpleNamespace(pid=12345, returncode=None)

        def reap(**_kwargs):
            events.append("wait")
            process.returncode = 0
            return 0

        process.wait = reap
        with patch.object(athena_readonly_chain.os, "waitid", return_value=None), \
                patch.object(athena_readonly_chain.os, "killpg",
                             side_effect=lambda *_args: events.append("signal")), \
                patch.object(athena_readonly_chain, "_gh_group_is_extinct",
                             side_effect=lambda _pid: events.append("proof") or True,
                             create=True):
            athena_readonly_chain._stop_gh_process_group(process)
        self.assertIn("proof", events[:events.index("wait")])
        self.assertNotIn("signal", events[events.index("wait") + 1:])
        self.assertNotIn("proof", events[events.index("wait") + 1:])

    def test_chain_rejects_structurally_unbounded_github_json(self) -> None:
        class Delivery:
            payload = ""

            def _gh(self, *_arguments: str, input_text: str | None = None) -> str:
                if input_text is not None:
                    raise AssertionError("read-only JSON calls do not accept input")
                return self.payload

        delivery = Delivery()
        athena_readonly_chain._install_read_only_gh(
            delivery, "HomericIntelligence/Odysseus"
        )
        payloads = {
            "depth": '{"value":' + "[" * 80 + "0" + "]" * 80 + "}",
            "nodes": '{"value":[' + ",".join("0" for _ in range(100_001)) + "]}",
            "digits": '{"value":' + "1" * 129 + "}",
            "string": '{"value":"' + "x" * (1024 * 1024 + 1) + '"}',
        }
        for resource, payload in payloads.items():
            with self.subTest(resource=resource):
                delivery.payload = payload
                with self.assertRaisesRegex(
                    athena_readonly_chain.VerificationError,
                    "resource bounds",
                ):
                    delivery._gh("api", "--hostname", "github.com", "user")

    def test_verified_helper_broker_admits_only_bounded_canonical_gh_json(self) -> None:
        payloads = {
            "duplicate": '{"login":"trusted","login":"other"}',
            "depth": '[' * 80 + '0' + ']' * 80,
            "nodes": '[' + ','.join('0' for _ in range(100_001)) + ']',
            "digits": '1' * 129,
            "string": '"' + 'x' * (1024 * 1024 + 1) + '"',
            "aggregate": json.dumps(['x' * (1024 * 1024)] * 9),
        }
        with patch.object(athena_readonly_chain, "_admit_broker_command",
                          return_value=(("/sealed/gh", "api", "user"), 73)):
            for label, payload in payloads.items():
                with self.subTest(label=label), patch.object(
                    athena_readonly_chain, "_run_bounded_gh",
                    return_value=subprocess.CompletedProcess([], 0, payload, ""),
                ):
                    with self.assertRaises(athena_readonly_chain.VerificationError):
                        athena_readonly_chain._broker_run(
                            ["gh", "api", "user"], capture_output=True, text=True,
                        )
            with patch.object(athena_readonly_chain, "_run_bounded_gh",
                              return_value=subprocess.CompletedProcess(
                                  [], 0, '{ "z": 1, "a": 2 }', "")):
                result = athena_readonly_chain._broker_run(
                    ["gh", "api", "user"], capture_output=True, text=True,
                )
                self.assertEqual(result.stdout, '{"a":2,"z":1}')

    def test_collector_accepts_same_actor_in_distinct_logical_roles(self) -> None:
        self.assertEqual(legacy_athena._collector_author_login(
            {"pull_request": {"author": {"login": "athena-reviewer"}}},
            "athena-reviewer",
        ), "athena-reviewer")

    def test_remote_helper_requires_aggregate_quota_before_spawn(self) -> None:
        with patch.object(legacy_athena.sys, "platform", "linux"), patch.object(
            legacy_athena, "_AggregateQuota", create=True,
            side_effect=legacy_athena.AthenaEvidenceError("aggregate quota unavailable"),
        ), patch.object(legacy_athena, "_trusted_python_executable") as interpreter, \
                patch.object(legacy_athena, "_run_bounded_process_impl") as spawn:
            with self.assertRaisesRegex(legacy_athena.AthenaEvidenceError, "aggregate quota"):
                legacy_athena._run_bounded_process(
                    ["helper"], input_text=None, cwd=None,
                    environment={"ODYSSEUS_GH_EXECUTABLE_FD": "73"},
                )
        spawn.assert_not_called()
        interpreter.assert_not_called()

    def test_aggregate_quota_requires_one_nsdelegated_mount_before_creation(self) -> None:
        import io
        rows = (
            "1 0 0:1 / /sys/fs/cgroup rw - cgroup2 cgroup rw\n",
            "1 0 0:1 / /sys/fs/cgroup rw - cgroup2 cgroup rw,nsdelegate\n"
            "2 0 0:1 / /alias rw - cgroup2 cgroup rw,nsdelegate\n",
        )
        for content in rows:
            with self.subTest(content=content), patch.object(
                legacy_athena.sys, "platform", "linux",
            ), patch.dict(os.environ, {"ODYSSEUS_CGROUP_ROOT": "/sys/fs/cgroup/test"}), \
                    patch("builtins.open", return_value=io.StringIO(content)), \
                    patch.object(legacy_athena.os, "open", side_effect=
                                 legacy_athena.AthenaEvidenceError("premature filesystem access")), \
                    patch.object(legacy_athena.os, "mkdir") as mkdir:
                with self.assertRaisesRegex(legacy_athena.AthenaEvidenceError, "nsdelegate"):
                    legacy_athena._AggregateQuota()
                mkdir.assert_not_called()

    def _kernel_setup_unavailable(self, reason):
        if os.environ.get("HOMERIC_RUN_CGROUP_KERNEL_TESTS") == "1":
            self.fail("authoritative Linux kernel proof setup failed: " + reason)
        self.skipTest("NON_PROOF_SKIP: " + reason)

    def test_authoritative_kernel_mode_cannot_skip_missing_setup(self):
        with patch.dict(os.environ, {"HOMERIC_RUN_CGROUP_KERNEL_TESTS": "1"}):
            with self.assertRaisesRegex(AssertionError, "authoritative Linux kernel proof setup failed"):
                self._kernel_setup_unavailable("missing delegation")
        with patch.dict(os.environ, {"HOMERIC_RUN_CGROUP_KERNEL_TESTS": "0"}):
            with self.assertRaisesRegex(unittest.SkipTest, "NON_PROOF_SKIP"):
                self._kernel_setup_unavailable("missing delegation")

    @unittest.skipUnless(sys.platform == "linux", "NON_PROOF_SKIP: Linux delegated cgroup v2 fanout oracle")
    def test_aggregate_kernel_quota_stops_fanout_and_owns_exact_extinction(self) -> None:
        root = os.environ.get("ODYSSEUS_CGROUP_ROOT")
        if root is None:
            membership = Path("/proc/self/cgroup").read_text().strip()
            if not membership.startswith("0::/"):
                self._kernel_setup_unavailable("CI requires cgroup v2 delegation")
            root = "/sys/fs/cgroup" + membership[3:].rstrip("/")
        controls = Path(root) / "cgroup.subtree_control"
        if not controls.is_file() or not os.access(root, os.W_OK):
            self._kernel_setup_unavailable("CI requires a writable delegated cgroup v2 root")
        if not {"cpu", "memory", "pids"}.issubset(controls.read_text().split()):
            self._kernel_setup_unavailable("CI requires delegated cpu, memory, and pids controllers")
        if "nsdelegate" not in Path("/proc/self/mountinfo").read_text():
            self._kernel_setup_unavailable("CI requires a kernel nsdelegate cgroup v2 mount")
        quota = legacy_athena._AggregateQuota()
        process = None
        try:
            quota._write("pids.max", "4")
            process = subprocess.Popen(
                [sys.executable, "-I", "-S", "-c",
                 "import os,signal,sys\n"
                 "assert os.read(0,1)==b'1'\n"
                 "count=0\n"
                 "for _ in range(40):\n"
                 " try: pid=os.fork()\n"
                 " except OSError: break\n"
                 " if pid==0:\n"
                 "  while True: signal.pause()\n"
                 " count+=1\n"
                 "print(count,flush=True)\n"
                 "while True: signal.pause()\n"],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE, start_new_session=True,
            )
            quota.admit(process)
            process.stdin.write(b"1")
            process.stdin.flush()
            self.assertTrue(legacy_athena.select.select([process.stdout], [], [], 5)[0])
            spawned = int(process.stdout.readline())
            self.assertLessEqual(spawned, 3)
            events = dict(line.split() for line in quota._read("pids.events").splitlines())
            self.assertGreater(int(events["max"]), 0)
            self.assertLessEqual(int(quota._read("pids.current")), 4)
            self.assertEqual(quota._read("cpu.max").strip(), "100000 100000")
            self.assertEqual(int(quota._read("memory.max")), legacy_athena.PROCESS_MAX_ADDRESS_SPACE_BYTES)
            name = quota.name
            quota.close()
            self.assertFalse((Path(root) / name).exists())
            self.assertEqual(process.wait(timeout=2), -signal.SIGKILL)
        finally:
            quota.close()
            if process is not None:
                if process.returncode is None:
                    process.kill()
                    process.wait(timeout=2)
                process.stdin.close()
                process.stdout.close()

    @unittest.skipUnless(sys.platform == "linux", "NON_PROOF_SKIP: Linux cgroup namespace tamper oracle")
    def test_aggregate_quota_cannot_be_lifted_from_a_nested_namespace(self) -> None:
        try:
            probe = legacy_athena._AggregateQuota()
        except (OSError, legacy_athena.AthenaEvidenceError) as exc:
            self._kernel_setup_unavailable(f"CI requires delegated nsdelegate cgroup v2: {exc}")
        probe.close()
        # Only this bounded child attempts to mutate its own disposable cgroup.
        # It remounts cgroupfs after obtaining nested user/mount authority; the
        # kernel nsdelegate boundary must still prevent lifting the parent cap.
        program = '''
import ctypes, errno, os, pathlib, tempfile
assert pathlib.Path('/proc/self/cgroup').read_text().strip() == '0::/'
assert not pathlib.Path('/sys/fs/cgroup/memory.max').exists()
libc = ctypes.CDLL(None, use_errno=True)
def call(result):
    if result != 0:
        raise OSError(ctypes.get_errno(), 'namespace probe')
uid, gid = os.geteuid(), os.getegid()
try:
    call(libc.unshare(0x10000000))
    pathlib.Path('/proc/self/setgroups').write_text('deny\\n')
    pathlib.Path('/proc/self/uid_map').write_text(f'0 {uid} 1\\n')
    pathlib.Path('/proc/self/gid_map').write_text(f'0 {gid} 1\\n')
    call(libc.unshare(0x00020000 | 0x02000000))
    with tempfile.TemporaryDirectory() as directory:
        call(libc.mount(b'cgroup2', directory.encode(), b'cgroup2', 0, None))
        try:
            pathlib.Path(directory, 'memory.max').write_text('max\\n')
        finally:
            call(libc.umount(directory.encode()))
except OSError as exc:
    assert exc.errno in (errno.EPERM, errno.EACCES), repr(exc)
    print('kernel-denied-quota-lift')
else:
    raise AssertionError('descendant lifted its aggregate limit')
'''
        result = legacy_athena._run_bounded_process(
            [sys.executable, "-I", "-S", "-c", program], input_text=None, cwd=None,
            environment={"PATH": "/usr/bin:/bin", "ODYSSEUS_REQUIRE_AGGREGATE_QUOTA": "1"},
            timeout_seconds=10,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "kernel-denied-quota-lift")

    def test_legacy_json_structure_is_bounded_before_full_decode(self) -> None:
        payloads = ['[' * 80 + '0' + ']' * 80,
                    '{"key":"first","key":"second"}',
                    json.dumps(['x' * (1024 * 1024)] * 9)]
        for payload in payloads:
            with self.subTest(prefix=payload[:20]), patch.object(
                legacy_athena.json, "loads", side_effect=AssertionError("decoded before admission"),
            ):
                with self.assertRaises(legacy_athena.AthenaEvidenceError):
                    legacy_athena._load_json(payload, "hostile response")

    def test_live_evidence_has_one_aggregate_deadline(self) -> None:
        class Clock:
            def __init__(self) -> None:
                self.value = 1000.0

            def monotonic(self) -> float:
                return self.value

        clock = Clock()
        calls = 0

        def runner(*_args: object, **_kwargs: object) -> str:
            nonlocal calls
            calls += 1
            clock.value += 30.0
            return "{}"

        stable_source = {
            "reviewed_identity": {},
            "reviewed_scope": {"sha256": "a" * 64},
            "reviewed_linked_requirements": {"sha256": "b" * 64},
        }
        with patch.object(legacy_athena.time, "monotonic", clock.monotonic), \
                patch.object(legacy_athena, "COMMAND_TIMEOUT_SECONDS", 100.0), \
                patch.object(
                    legacy_athena,
                    "_validated_collector",
                    return_value=stable_source,
                ), patch.object(
                    legacy_athena, "_validated_checks", return_value={}
                ), patch.object(
                    legacy_athena, "_validated_readiness", return_value={}
                ), patch.object(
                    legacy_athena, "_validated_policy", return_value={}
                ), patch.object(
                    legacy_athena,
                    "_validated_branch_protection",
                    return_value={},
                ), patch.object(
                    legacy_athena, "_validated_chain", return_value=None
                ), patch.object(
                    legacy_athena,
                    "_collector_author_login",
                    return_value="athena-author",
                ), patch.object(
                    legacy_athena, "_load_json", return_value={}
                ), patch.object(
                    legacy_athena, "_load_object", return_value={}
                ), patch.object(
                    legacy_athena, "_canonical_json", return_value="{}"
                ):
            with self.assertRaisesRegex(
                legacy_athena.AthenaEvidenceError,
                "workflow deadline",
            ):
                legacy_athena.require_live_evidence(
                    runner,
                    pr_url="https://github.com/HomericIntelligence/Odysseus/pull/9",
                    repository="HomericIntelligence/Odysseus",
                    base_oid="b" * 40,
                    head_oid="c" * 40,
                    envelope={"state_sha256": "d" * 64},
                    requirement_url=(
                        "https://github.com/HomericIntelligence/Odysseus/issues/1"
                    ),
                    reviewer_login="athena-reviewer",
                    expected_base_ref="main",
                    expected_head_ref="feature",
                )
        self.assertLess(calls, 12)

    def test_collector_inherits_the_aggregate_chain_deadline(self) -> None:
        class Binding:
            def __init__(self, descriptor: int) -> None:
                self.descriptor = descriptor
                self.execution_path = f"/proc/self/fd/{descriptor}"
                self.sha256 = "a" * 64

            def close(self) -> None:
                return None

        observed_environment: dict[str, str] = {}

        def bounded_process(
            _command: object, **options: object
        ) -> subprocess.CompletedProcess[str]:
            observed_environment.update(options["environment"])
            return subprocess.CompletedProcess([], 0, "{}\n", "")

        deadline = time.monotonic() + 60.0
        token = legacy_athena._ACTIVE_EVIDENCE_DEADLINE.set(deadline)
        try:
            with patch.object(
                legacy_athena, "_verified_plugin_root", return_value="/athena"
            ), patch.object(
                legacy_athena, "_trusted_gh_executable", return_value=Binding(10)
            ), patch.object(
                legacy_athena, "_trusted_git_executable", return_value=Binding(11)
            ), patch.object(
                legacy_athena, "_trusted_python_executable", return_value=Binding(12)
            ), patch.object(
                legacy_athena, "_trusted_git_exec_path", return_value="/usr/lib/git-core"
            ), patch.object(
                legacy_athena,
                "_verified_adapter_command",
                return_value=["/proc/self/fd/12", "collector"],
            ), patch.object(
                legacy_athena, "_run_bounded_process", side_effect=bounded_process
            ), patch.object(
                legacy_athena.sys, "platform", "linux"
            ):
                legacy_athena.run_command(
                    "/athena",
                    str(_E2E_ROOT / "legacy_athena.py"),
                    "skills/pr-review/scripts/collect_evidence.py",
                    ["1"],
                )
        finally:
            legacy_athena._ACTIVE_EVIDENCE_DEADLINE.reset(token)

        raw_deadline = observed_environment.get(
            "ODYSSEUS_ATHENA_CHAIN_DEADLINE_MONOTONIC"
        )
        self.assertIsNotNone(raw_deadline)
        self.assertAlmostEqual(float(raw_deadline), deadline - 5.0, places=3)

    def test_live_chain_uses_role_specific_carrier_publishers(self) -> None:
        repository = "HomericIntelligence/Odysseus"
        number = 9
        url = f"https://github.com/{repository}/pull/{number}"
        base = "b" * 40
        head = "c" * 40
        state_digest = "d" * 64
        scope_digest = "e" * 64
        requirements_digest = "f" * 64
        state = {
            "surface": "pull_request",
            "phase": "complete",
            "verdict": "GO",
            "next_action": "finalize",
            "coverage_complete": True,
            "artifact_binding": {"revision": head, "sha256": scope_digest},
            "requirements_sha256": requirements_digest,
        }
        state_envelope = {"state_sha256": state_digest, "state": state}
        author_envelope = {
            "schema_id": "athena.review-exchange.author-event",
            "state_sha256": "a" * 64,
            "state": {"artifact_binding": {"revision": head}},
        }
        reviewer = SimpleNamespace(
            id="PRR_reviewer",
            author="athena-reviewer",
            head_oid=head,
            body="reviewer\n<!-- HomericIntelligence:review-exchange:v1 -->",
            viewer_did_author=True,
        )
        author = SimpleNamespace(
            id="PRR_author",
            author="athena-author",
            head_oid=head,
            body="author\n<!-- HomericIntelligence:review-exchange:v1 -->",
            viewer_did_author=False,
        )
        snapshot = SimpleNamespace(
            reviews=[author, reviewer],
            threads=[],
            labels=["state:implementation-go"],
        )

        def review_carriers(value: object, _binding: object):
            records = {item.id: item for item in value.reviews}
            return (
                {state_digest: (records["PRR_reviewer"], state_envelope)},
                ((records["PRR_author"], author_envelope),),
            )

        delivery = SimpleNamespace(
            _gh=lambda *_args, **_kwargs: '{"login":"athena-reviewer"}',
            _json_object=lambda payload, _context: json.loads(payload),
            ReviewBinding=lambda **values: SimpleNamespace(**values),
            GitHubForge=lambda _binding, _host: SimpleNamespace(),
            _snapshot=lambda _forge, _binding: snapshot,
            _review_carriers=review_carriers,
            _verify_state_chain=lambda *_args, **_kwargs: SimpleNamespace(
                selected_state_sha256s={state_digest},
                verified_state_sha256s={state_digest},
            ),
            review_exchange=SimpleNamespace(
                CARRIER_PREFIX="<!-- HomericIntelligence:review-exchange:",
                STATE_SCHEMA_ID="athena.review-exchange.state",
                AUTHOR_EVENT_SCHEMA_ID="athena.review-exchange.author-event",
                extract_carrier=lambda body: (
                    author_envelope if body is author.body else {
                        "schema_id": "athena.review-exchange.state",
                        **state_envelope,
                    }
                ),
            ),
        )
        arguments = SimpleNamespace(
            plugin_root="/verified-athena",
            repository=repository,
            number=number,
            url=url,
            base_oid=base,
            head_oid=head,
            terminal_state_sha256=state_digest,
            reviewer_login="athena-reviewer",
            author_login="athena-author",
        )
        with patch.object(
            athena_readonly_chain,
            "_verified_plugin_payloads",
            return_value={"verified": b"bytes"},
        ), patch.object(
            athena_readonly_chain,
            "_load_delivery_module",
            return_value=delivery,
        ), patch.object(
            athena_readonly_chain, "_install_read_only_gh"
        ):
            try:
                proof = athena_readonly_chain.verify_chain(arguments)
            except athena_readonly_chain.VerificationError as exc:
                self.fail(f"a valid role-specific chain was rejected: {exc}")
        self.assertEqual(proof["terminal"]["reviewer_login"], "athena-reviewer")

        # Logical author and reviewer roles may share the authenticated actor.
        arguments.author_login = "athena-reviewer"
        author.author = "athena-reviewer"
        author.viewer_did_author = True
        with patch.object(athena_readonly_chain, "_verified_plugin_payloads",
                          return_value={"verified": b"bytes"}), patch.object(
            athena_readonly_chain, "_load_delivery_module", return_value=delivery,
        ), patch.object(athena_readonly_chain, "_install_read_only_gh"):
            proof = athena_readonly_chain.verify_chain(arguments)
            self.assertEqual(proof["terminal"]["reviewer_login"], "athena-reviewer")
            author.viewer_did_author = False
            with self.assertRaisesRegex(athena_readonly_chain.VerificationError,
                                        "publisher identity"):
                athena_readonly_chain.verify_chain(arguments)

        arguments.author_login = "athena-author"
        author.viewer_did_author = False

        author.author = "athena-reviewer"
        with patch.object(
            athena_readonly_chain,
            "_verified_plugin_payloads",
            return_value={"verified": b"bytes"},
        ), patch.object(
            athena_readonly_chain,
            "_load_delivery_module",
            return_value=delivery,
        ), patch.object(
            athena_readonly_chain, "_install_read_only_gh"
        ):
            with self.assertRaisesRegex(
                athena_readonly_chain.VerificationError,
                "publisher identity",
            ):
                athena_readonly_chain.verify_chain(arguments)


if __name__ == "__main__":
    unittest.main()
