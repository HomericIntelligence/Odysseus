"""Protocol tests for the one-shot NATS evidence capture helper."""

from __future__ import annotations

import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch


_HELPER = Path(__file__).resolve().parent.parent.parent / "capture-nats-event.py"


class _NatsFixture:
    def __init__(
        self,
        ready: Path | None,
        *,
        truncate: bool = False,
        prefix_payloads: tuple[object, ...] = (),
        allow_no_connection: bool = False,
    ) -> None:
        self.ready = ready
        self.truncate = truncate
        self.prefix_payloads = prefix_payloads
        self.allow_no_connection = allow_no_connection
        self.error: BaseException | None = None
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.listener.settimeout(0.1)
        self.stopping = threading.Event()
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "_NatsFixture":
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.stopping.set()
        self.listener.close()
        self.thread.join(timeout=2)
        if self.thread.is_alive():
            raise AssertionError("fake NATS server did not stop")
        if self.error is not None:
            raise self.error

    def _serve(self) -> None:
        try:
            try:
                while True:
                    try:
                        connection, _ = self.listener.accept()
                        break
                    except socket.timeout:
                        if self.stopping.is_set():
                            if self.allow_no_connection:
                                return
                            raise AssertionError("capture helper never connected")
            except OSError:
                if self.allow_no_connection:
                    return
                raise
            with connection:
                connection.settimeout(2)
                connection.sendall(b'INFO {"auth_required":false}\r\n')
                request = b""
                while b"PING\r\n" not in request:
                    chunk = connection.recv(4096)
                    if not chunk:
                        raise AssertionError("capture helper disconnected before PING")
                    request += chunk
                if b"CONNECT " not in request:
                    raise AssertionError("capture helper omitted CONNECT")
                if (
                    b"SUB hi.tasks.team-1.task-1.updated ODYSSEUS_E2E\r\n"
                    not in request
                ):
                    raise AssertionError(
                        "capture helper subscribed to the wrong subject"
                    )
                connection.sendall(b"PONG\r\n")
                if self.ready is not None:
                    deadline = time.monotonic() + 2
                    while not self.ready.exists() and time.monotonic() < deadline:
                        time.sleep(0.005)
                    if not self.ready.exists():
                        raise AssertionError("capture helper did not publish readiness")

                payload = json.dumps(
                    {
                        "schema_version": 1,
                        "event": "task.updated",
                        "data": {"team_id": "team-1", "task_id": "task-1"},
                        "request_id": "request-1",
                    },
                    separators=(",", ":"),
                ).encode()
                frames = []
                for prefix_payload in self.prefix_payloads:
                    prefix = json.dumps(prefix_payload, separators=(",", ":")).encode()
                    frames.append(
                        b"MSG hi.tasks.team-1.task-1.updated ODYSSEUS_E2E "
                        + str(len(prefix)).encode()
                        + b"\r\n"
                        + prefix
                        + b"\r\n"
                    )
                frames.append(
                    b"MSG hi.tasks.team-1.task-1.updated ODYSSEUS_E2E "
                    + str(len(payload)).encode()
                    + b"\r\n"
                    + payload
                    + b"\r\n"
                )
                frame = b"".join(frames)
                if self.truncate:
                    frame = frame[:-3]
                if self.prefix_payloads:
                    connection.sendall(frame)
                else:
                    for byte in frame:
                        connection.sendall(bytes((byte,)))
        except BaseException as error:  # surfaced in the owning test thread
            self.error = error


class _SlowNatsFixture:
    def __init__(self, ready: Path, stage: str) -> None:
        self.ready = ready
        self.stage = stage
        self.error: BaseException | None = None
        self.listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.listener.bind(("127.0.0.1", 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.thread = threading.Thread(target=self._serve, daemon=True)

    def __enter__(self) -> "_SlowNatsFixture":
        self.thread.start()
        return self

    def __exit__(self, *_args: object) -> None:
        self.listener.close()
        self.thread.join(timeout=3)
        if self.thread.is_alive():
            raise AssertionError("slow fake NATS server did not stop")
        if self.error is not None:
            raise self.error

    @staticmethod
    def _trickle(connection: socket.socket, value: bytes, delay: float) -> None:
        for byte in value:
            connection.sendall(bytes((byte,)))
            time.sleep(delay)

    def _serve(self) -> None:
        try:
            connection, _ = self.listener.accept()
            with connection:
                connection.settimeout(2)
                info = b'INFO {"auth_required":false}\r\n'
                if self.stage == "info":
                    self._trickle(connection, info, 0.05)
                    return
                connection.sendall(info)
                request = b""
                while b"PING\r\n" not in request:
                    chunk = connection.recv(4096)
                    if not chunk:
                        return
                    request += chunk
                if self.stage == "control":
                    self._trickle(connection, b"PONG\r\n", 0.18)
                    return
                connection.sendall(b"PONG\r\n")
                deadline = time.monotonic() + 2
                while not self.ready.exists() and time.monotonic() < deadline:
                    time.sleep(0.005)
                if not self.ready.exists():
                    return
                connection.sendall(
                    b"MSG hi.tasks.team-1.task-1.updated ODYSSEUS_E2E 2\r\n"
                )
                self._trickle(connection, b"{}\r\n", 0.18)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass
        except BaseException as error:  # surfaced in the owning test thread
            self.error = error


class CaptureNatsEventTest(unittest.TestCase):
    def _run(
        self,
        root: Path,
        port: int,
        *,
        capture_timeout: str = "2",
        host: str = "127.0.0.1",
    ) -> subprocess.CompletedProcess[str]:
        directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
        try:
            return subprocess.run(
                [
                    sys.executable,
                    str(_HELPER),
                    "--host",
                    host,
                    "--port",
                    str(port),
                    "--subject",
                    "hi.tasks.team-1.task-1.updated",
                    "--event",
                    "task.updated",
                    "--team-id",
                    "team-1",
                    "--task-id",
                    "task-1",
                    "--evidence-dir-fd",
                    str(directory_fd),
                    "--ready-name",
                    "ready",
                    "--output-name",
                    "event.json",
                    "--timeout",
                    capture_timeout,
                ],
                capture_output=True,
                text=True,
                timeout=5,
                check=False,
                pass_fds=(directory_fd,),
            )
        finally:
            os.close(directory_fd)

    def test_host_must_be_numeric_before_any_connection(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with _NatsFixture(
                root / "ready", allow_no_connection=True
            ) as server:
                result = self._run(root, server.port, host="localhost")

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("numeric", result.stderr.lower())
            self.assertFalse((root / "ready").exists())

    def test_one_deadline_interrupts_evidence_publication(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("capture_nats_event", _HELPER)
        if spec is None or spec.loader is None:
            self.fail("could not load capture helper")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        class FakeSocket:
            def __init__(self) -> None:
                self._payload = bytearray(
                    b'INFO {"auth_required":false}\r\nPONG\r\n'
                )

            def __enter__(self):
                return self

            def __exit__(self, *_args: object) -> None:
                return None

            def settimeout(self, _timeout: float) -> None:
                return None

            def sendall(self, _value: bytes) -> None:
                return None

            def recv(self, maximum: int) -> bytes:
                value = bytes(self._payload[:maximum])
                del self._payload[:maximum]
                return value

        args = SimpleNamespace(
            host="127.0.0.1",
            port=4222,
            subject="hi.tasks.team-1.task-1.updated",
            event="task.updated",
            team_id="team-1",
            task_id="task-1",
            evidence_dir_fd=None,
            ready_name=None,
            output_name=None,
            ready_fd=10,
            output_fd=11,
            timeout=0.05,
        )

        def stalled_publication(_descriptor: int, _value: bytes) -> None:
            time.sleep(0.5)

        started = time.monotonic()
        with (
            patch.object(module, "_parse_args", return_value=args),
            patch.object(
                module,
                "_connect_numeric",
                return_value=FakeSocket(),
                create=True,
            ),
            patch.object(
                module,
                "_publish_descriptor",
                side_effect=stalled_publication,
            ),
            self.assertRaisesRegex(TimeoutError, "timed out"),
        ):
            module.main()

        self.assertLess(time.monotonic() - started, 0.3)

    def test_fragmented_exact_event_is_captured(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with _NatsFixture(root / "ready") as server:
                result = self._run(root, server.port)

            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads((root / "event.json").read_text(encoding="utf-8"))
            self.assertEqual(evidence["subject"], "hi.tasks.team-1.task-1.updated")
            self.assertEqual(evidence["payload"]["request_id"], "request-1")

    def test_truncated_event_fails_without_output(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with _NatsFixture(root / "ready", truncate=True) as server:
                result = self._run(root, server.port)

            self.assertNotEqual(result.returncode, 0)
            self.assertIn("truncated", result.stderr)
            self.assertFalse((root / "event.json").exists())

    def test_non_object_json_is_ignored_before_exact_event(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            with _NatsFixture(
                root / "ready",
                prefix_payloads=([], "unrelated", None),
            ) as server:
                result = self._run(root, server.port)

            self.assertEqual(result.returncode, 0, result.stderr)
            evidence = json.loads((root / "event.json").read_text(encoding="utf-8"))
            self.assertEqual(evidence["payload"]["request_id"], "request-1")

    def test_publication_retries_partial_writes(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("capture_nats_event", _HELPER)
        if spec is None or spec.loader is None:
            self.fail("could not load capture helper")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        real_write = os.write

        def partial_write(descriptor: int, value: bytes | memoryview) -> int:
            return real_write(descriptor, value[:1])

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            try:
                with patch.object(module.os, "write", side_effect=partial_write):
                    module._publish_file(directory_fd, "evidence", b"complete\n")
            finally:
                os.close(directory_fd)
            self.assertEqual((root / "evidence").read_bytes(), b"complete\n")

    def test_publication_stays_bound_when_parent_name_is_retargeted(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("capture_nats_event", _HELPER)
        if spec is None or spec.loader is None:
            self.fail("could not load capture helper")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            evidence = root / "evidence-dir"
            displaced = root / "displaced"
            outside = root / "outside"
            evidence.mkdir(mode=0o700)
            outside.mkdir(mode=0o700)
            directory_fd = os.open(evidence, os.O_RDONLY | os.O_DIRECTORY)
            evidence.rename(displaced)
            evidence.symlink_to(outside, target_is_directory=True)
            try:
                module._publish_file(directory_fd, "evidence", b"complete\n")
            finally:
                os.close(directory_fd)

            self.assertEqual((displaced / "evidence").read_bytes(), b"complete\n")
            self.assertFalse((outside / "evidence").exists())

    def test_publication_rejects_a_post_open_name_replacement(self) -> None:
        import importlib.util

        spec = importlib.util.spec_from_file_location("capture_nats_event", _HELPER)
        if spec is None or spec.loader is None:
            self.fail("could not load capture helper")
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)

        real_open = os.open
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            destination = root / "evidence"
            displaced = root / "displaced"
            directory_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY)

            def replace_after_open(
                path: os.PathLike[str] | str,
                flags: int,
                mode: int = 0o777,
                **kwargs: object,
            ) -> int:
                descriptor = real_open(path, flags, mode, **kwargs)
                if path == "evidence":
                    os.rename(
                        "evidence",
                        "displaced",
                        src_dir_fd=directory_fd,
                        dst_dir_fd=directory_fd,
                    )
                    replacement_fd = real_open(
                        "evidence",
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=directory_fd,
                    )
                    try:
                        os.write(replacement_fd, b"preserve\n")
                    finally:
                        os.close(replacement_fd)
                return descriptor

            try:
                with patch.object(module.os, "open", side_effect=replace_after_open):
                    with self.assertRaises(RuntimeError):
                        module._publish_file(directory_fd, "evidence", b"complete\n")
            finally:
                os.close(directory_fd)

            self.assertEqual(destination.read_text(encoding="utf-8"), "preserve\n")
            self.assertEqual(displaced.read_bytes(), b"")

    def test_retained_capabilities_ignore_final_name_replacements(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            ready_path = root / "ready"
            output_path = root / "event.json"
            ready_fd = os.open(
                ready_path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600
            )
            output_fd = os.open(
                output_path, os.O_RDWR | os.O_CREAT | os.O_EXCL, 0o600
            )
            try:
                ready_path.rename(root / "ready.displaced")
                output_path.rename(root / "event.displaced")
                ready_path.write_text("forged-ready\n", encoding="utf-8")
                output_path.write_text('{"forged":true}\n', encoding="utf-8")
                with _NatsFixture(None, allow_no_connection=True) as server:
                    result = subprocess.run(
                        [
                            sys.executable,
                            str(_HELPER),
                            "--host",
                            "127.0.0.1",
                            "--port",
                            str(server.port),
                            "--subject",
                            "hi.tasks.team-1.task-1.updated",
                            "--event",
                            "task.updated",
                            "--team-id",
                            "team-1",
                            "--task-id",
                            "task-1",
                            "--ready-fd",
                            str(ready_fd),
                            "--output-fd",
                            str(output_fd),
                            "--timeout",
                            "2",
                        ],
                        capture_output=True,
                        text=True,
                        timeout=5,
                        check=False,
                        pass_fds=(ready_fd, output_fd),
                    )

                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(os.pread(ready_fd, 7, 0), b"ready\n")
                evidence = json.loads(os.pread(output_fd, 1024 * 1024, 0))
                self.assertEqual(evidence["payload"]["request_id"], "request-1")
                self.assertEqual(ready_path.read_text(encoding="utf-8"), "forged-ready\n")
                self.assertEqual(output_path.read_text(encoding="utf-8"), '{"forged":true}\n')
            finally:
                os.close(output_fd)
                os.close(ready_fd)

    def test_one_deadline_covers_slow_info_control_and_payload_reads(self) -> None:
        for stage in ("info", "control", "payload"):
            with self.subTest(stage=stage):
                with tempfile.TemporaryDirectory() as temporary:
                    root = Path(temporary)
                    with _SlowNatsFixture(root / "ready", stage) as server:
                        started = time.monotonic()
                        result = self._run(root, server.port, capture_timeout="0.2")
                        elapsed = time.monotonic() - started

                    self.assertNotEqual(result.returncode, 0)
                    self.assertLess(elapsed, 0.5, result.stderr)
                    self.assertFalse((root / "event.json").exists())


if __name__ == "__main__":
    unittest.main()
