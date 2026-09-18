#!/usr/bin/env python3
"""Unit tests for the content-pinned NATS parser provisioner."""

from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import signal
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import validate_nats_config
import render_nomad_configs
from validate_nats_config import ParserRelease, provision_nats_server


class _Response(io.BytesIO):
    def __init__(self, payload: bytes, final_url: str) -> None:
        super().__init__(payload)
        self._final_url = final_url

    def __enter__(self) -> "_Response":
        return self

    def __exit__(self, *_args: object) -> None:
        self.close()

    def geturl(self) -> str:
        return self._final_url


class _DribbleResponse(_Response):
    def read(self, size: int = -1) -> bytes:
        time.sleep(0.06)
        return super().read(max(1, min(size, max(1, len(self.getbuffer()) // 2))))


def _archive(*, member_type: bytes = tarfile.REGTYPE) -> bytes:
    payload = io.BytesIO()
    with tarfile.open(fileobj=payload, mode="w:gz") as archive:
        member = tarfile.TarInfo("nats-server-v9.9.9-test/nats-server")
        member.type = member_type
        if member_type == tarfile.REGTYPE:
            binary = b"#!/bin/sh\nprintf 'nats-server: v9.9.9\\n'\n"
            member.size = len(binary)
            member.mode = 0o755
            archive.addfile(member, io.BytesIO(binary))
        else:
            member.linkname = "/tmp/foreign-parser"
            archive.addfile(member)
    return payload.getvalue()


def _release(payload: bytes, *, sha256: str | None = None) -> ParserRelease:
    return ParserRelease(
        url=(
            "https://github.com/nats-io/nats-server/releases/download/"
            "v9.9.9/nats-server-v9.9.9-test.tar.gz"
        ),
        member="nats-server-v9.9.9-test/nats-server",
        sha256=sha256 or hashlib.sha256(payload).hexdigest(),
    )


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(0o700)


def _process_is_gone(pid: int) -> bool:
    for _ in range(40):
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            return True
        time.sleep(0.05)
    return False


def _read_pid(path: Path) -> int:
    for _ in range(40):
        try:
            return int(path.read_text(encoding="utf-8"))
        except FileNotFoundError:
            time.sleep(0.05)
    raise AssertionError(f"child PID receipt was not created: {path}")


def _swap_selected_on_run(
    selected: Path,
    hostile: Path,
    executable_name: str,
) -> mock._patch:
    swapped = False

    def swap() -> None:
        nonlocal swapped
        if swapped:
            return
        swapped = True
        selected.rename(selected.with_name(selected.name + ".selected"))
        hostile.rename(selected)

    if hasattr(validate_nats_config, "_run_supervised"):
        real_run = validate_nats_config._run_supervised

        def supervised(bound, *args, **kwargs):
            if bound.name == executable_name:
                swap()
            return real_run(bound, *args, **kwargs)

        return mock.patch.object(
            validate_nats_config,
            "_run_supervised",
            side_effect=supervised,
        )

    real_run = validate_nats_config.subprocess.run

    def subprocess_run(command, *args, **kwargs):
        if Path(command[0]) == selected:
            swap()
        return real_run(command, *args, **kwargs)

    return mock.patch.object(
        validate_nats_config.subprocess,
        "run",
        side_effect=subprocess_run,
    )


class ProvisionNatsServerTests(unittest.TestCase):
    def test_default_release_matches_current_config_validation_pin(self) -> None:
        self.assertEqual(validate_nats_config._NATS_SERVER_VERSION, "2.10.22")
        expected_sha256 = {
            ("linux", "x86_64"): (
                "db0b3ccbe4cbdd3872ae7486ec4f6b0f85824632a0789f4da2e0a8518390483e"
            ),
            ("linux", "aarch64"): (
                "b4da77b2b194dc5fcf13a1df0dad59ba7e87ae4423f254c50534015b7c8a2369"
            ),
            ("darwin", "x86_64"): (
                "e99eb01a886b5de05972445e362e48cf8ad10b45e4cd5a5592475b184f8f81c9"
            ),
            ("darwin", "arm64"): (
                "93ce74f61a49d8fa9dfbf420e5a844e25309e429c5c8e27b54b3283d0712fcff"
            ),
        }
        self.assertEqual(
            set(validate_nats_config._PARSER_RELEASES),
            set(expected_sha256),
        )
        for host, release in validate_nats_config._PARSER_RELEASES.items():
            self.assertIn("/v2.10.22/", release.url)
            self.assertIn("nats-server-v2.10.22-", release.member)
            self.assertEqual(release.sha256, expected_sha256[host])

    def test_verified_regular_member_is_materialized_privately(self) -> None:
        payload = _archive()
        with tempfile.TemporaryDirectory() as tmp:
            parser = provision_nats_server(
                Path(tmp),
                release=_release(payload),
                opener=lambda *_args, **_kwargs: _Response(
                    payload,
                    "https://release-assets.githubusercontent.com/pinned/archive",
                ),
            )
            parser_path = Path(parser)
            self.assertEqual(parser_path, Path(tmp) / "nats-server")
            self.assertTrue(parser_path.is_file())
            self.assertFalse(parser_path.is_symlink())
            self.assertEqual(parser_path.stat().st_mode & 0o777, 0o700)
            self.assertIn(b"nats-server: v9.9.9", parser_path.read_bytes())

    def test_provision_receipt_carries_exact_extracted_binary_digest(self) -> None:
        payload = _archive()
        expected_binary = b"#!/bin/sh\nprintf 'nats-server: v9.9.9\\n'\n"
        with tempfile.TemporaryDirectory() as tmp:
            receipt = provision_nats_server(
                Path(tmp),
                release=_release(payload),
                opener=lambda *_args, **_kwargs: _Response(
                    payload,
                    "https://release-assets.githubusercontent.com/pinned/archive",
                ),
            )
            self.assertEqual(
                getattr(receipt, "sha256", None),
                hashlib.sha256(expected_binary).hexdigest(),
            )
            self.assertEqual(Path(receipt), Path(tmp) / "nats-server")

    def test_checksum_mismatch_is_rejected_before_extraction(self) -> None:
        payload = _archive()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, "SHA-256"):
                provision_nats_server(
                    Path(tmp),
                    release=_release(payload, sha256="0" * 64),
                    opener=lambda *_args, **_kwargs: _Response(
                        payload,
                        "https://release-assets.githubusercontent.com/pinned/archive",
                    ),
                )
            self.assertFalse((Path(tmp) / "nats-server").exists())

    def test_redirect_to_non_https_url_is_rejected(self) -> None:
        payload = _archive()
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, "HTTPS"):
                provision_nats_server(
                    Path(tmp),
                    release=_release(payload),
                    opener=lambda *_args, **_kwargs: _Response(
                        payload,
                        "http://example.invalid/archive",
                    ),
                )

    def test_link_archive_member_is_rejected(self) -> None:
        payload = _archive(member_type=tarfile.SYMTYPE)
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(RuntimeError, "regular file"):
                provision_nats_server(
                    Path(tmp),
                    release=_release(payload),
                    opener=lambda *_args, **_kwargs: _Response(
                        payload,
                        "https://release-assets.githubusercontent.com/pinned/archive",
                    ),
                )

    def test_download_has_one_end_to_end_monotonic_deadline(self) -> None:
        payload = _archive()
        with tempfile.TemporaryDirectory() as tmp:
            started = time.monotonic()
            with (
                mock.patch.object(
                    validate_nats_config, "PARSER_DOWNLOAD_TIMEOUT_SECONDS", 0.1
                ),
                self.assertRaisesRegex(RuntimeError, "timed out"),
            ):
                provision_nats_server(
                    Path(tmp),
                    release=_release(payload),
                    opener=lambda *_args, **_kwargs: _DribbleResponse(
                        payload,
                        "https://release-assets.githubusercontent.com/pinned/archive",
                    ),
                )
            self.assertLess(time.monotonic() - started, 0.3)
            self.assertFalse((Path(tmp) / "nats-server").exists())

    def test_destination_parent_swap_cannot_redirect_materialization(self) -> None:
        payload = _archive()
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            destination = root / "destination"
            displaced = root / "destination.bound"
            destination.mkdir(mode=0o700)

            class SwapResponse(_Response):
                def __exit__(self, *_args: object) -> None:
                    super().__exit__(*_args)
                    destination.rename(displaced)
                    destination.mkdir(mode=0o700)

            with self.assertRaisesRegex(RuntimeError, "destination.*changed"):
                provision_nats_server(
                    destination,
                    release=_release(payload),
                    opener=lambda *_args, **_kwargs: SwapResponse(
                        payload,
                        "https://release-assets.githubusercontent.com/pinned/archive",
                    ),
                )
            self.assertFalse((destination / "nats-server").exists())
            self.assertFalse((displaced / "nats-server").exists())

    def test_short_write_removes_only_the_owned_partial_parser(self) -> None:
        payload = _archive()
        with tempfile.TemporaryDirectory() as tmp:
            real_write = validate_nats_config.os.write
            writes = 0

            def short_write(descriptor: int, content: bytes) -> int:
                nonlocal writes
                writes += 1
                if writes == 1:
                    return real_write(descriptor, content[:1])
                return 0

            with (
                mock.patch.object(
                    validate_nats_config.os, "write", side_effect=short_write
                ),
                self.assertRaisesRegex(RuntimeError, "short write"),
            ):
                provision_nats_server(
                    Path(tmp),
                    release=_release(payload),
                    opener=lambda *_args, **_kwargs: _Response(
                        payload,
                        "https://release-assets.githubusercontent.com/pinned/archive",
                    ),
                )
            self.assertFalse((Path(tmp) / "nats-server").exists())

    @unittest.skipUnless(hasattr(os, "fork"), "requires POSIX signal semantics")
    def test_signal_removes_exact_partial_parser_before_reraise(self) -> None:
        payload = _archive()
        for signal_number in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signal_number), tempfile.TemporaryDirectory() as tmp:
                destination = Path(tmp)
                child = os.fork()
                if child == 0:
                    real_write = validate_nats_config.os.write
                    signalled = False

                    def interrupted_write(descriptor: int, content: bytes) -> int:
                        nonlocal signalled
                        written = real_write(descriptor, content[:1])
                        if not signalled:
                            signalled = True
                            os.kill(os.getpid(), signal_number)
                        return written

                    validate_nats_config.os.write = interrupted_write
                    with validate_nats_config._deferred_termination():
                        provision_nats_server(
                            destination,
                            release=_release(payload),
                            opener=lambda *_args, **_kwargs: _Response(
                                payload,
                                "https://release-assets.githubusercontent.com/pinned/archive",
                            ),
                        )
                    os._exit(97)
                _, status = os.waitpid(child, 0)
                self.assertTrue(os.WIFSIGNALED(status))
                self.assertEqual(os.WTERMSIG(status), signal_number)
                self.assertFalse((destination / "nats-server").exists())

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_selected_parser_bytes_survive_path_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            sentinel = root / "hostile-parser-ran"
            hostile = root / "hostile-parser"
            _write_executable(
                parser,
                """#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'nats-server: v2.10.22'
  exit 0
fi
if grep -q 'authorization = \\[\\]' "$3"; then exit 1; fi
exit 0
""",
            )
            _write_executable(
                hostile,
                f"""#!/bin/sh
printf '%s\n' hostile > '{sentinel}'
exec "$0.selected" "$@"
""",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            with _swap_selected_on_run(parser, hostile, "nats-server"):
                error = validate_nats_config._verify_parser(
                    parser, workspace, environment
                )
            self.assertIsNone(error)
            self.assertFalse(sentinel.exists())

    def test_snapshot_leaf_replacement_cannot_execute_hostile_bytes(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            sentinel = root / "hostile-snapshot-leaf-ran"
            _write_executable(
                parser,
                """#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'nats-server: v2.10.22'
  exit 0
fi
if grep -q 'authorization = \\[\\]' "$3"; then exit 1; fi
exit 0
""",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            real_popen = validate_nats_config._popen_bound
            swapped = False

            def swap_leaf(bound, *args, **kwargs):
                nonlocal swapped
                if not swapped and bound.name == "nats-server":
                    swapped = True
                    os.fchmod(bound.directory_descriptor, 0o700)
                    os.rename(
                        bound.snapshot_name,
                        bound.snapshot_name + ".selected",
                        src_dir_fd=bound.directory_descriptor,
                        dst_dir_fd=bound.directory_descriptor,
                    )
                    descriptor = os.open(
                        bound.snapshot_name,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o500,
                        dir_fd=bound.directory_descriptor,
                    )
                    try:
                        os.write(
                            descriptor,
                            f"#!/bin/sh\nprintf hostile > '{sentinel}'\nexit 1\n".encode(),
                        )
                    finally:
                        os.close(descriptor)
                    os.fchmod(bound.directory_descriptor, 0o500)
                try:
                    return real_popen(bound, *args, **kwargs)
                finally:
                    if swapped:
                        os.fchmod(bound.directory_descriptor, 0o700)
                        try:
                            os.unlink(
                                bound.snapshot_name + ".selected",
                                dir_fd=bound.directory_descriptor,
                            )
                        except FileNotFoundError:
                            pass
                        os.fchmod(bound.directory_descriptor, 0o500)

            with mock.patch.object(
                validate_nats_config, "_popen_bound", side_effect=swap_leaf
            ):
                error = validate_nats_config._verify_parser(
                    parser, workspace, environment
                )
            self.assertIsNotNone(error)
            self.assertFalse(sentinel.exists())

    def test_non_linux_launch_fails_before_spawn_side_effects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            sentinel = root / "spawn-reached"
            _write_executable(parser, "#!/bin/sh\nexit 0\n")
            bound = validate_nats_config._bind_executable(parser, "nats-server")

            def spawn_reached(*_args, **_kwargs):
                sentinel.write_text("spawned\n", encoding="utf-8")
                raise OSError("spawn reached")

            observed = ""
            try:
                with (
                    mock.patch.object(validate_nats_config.sys, "platform", "darwin"),
                    mock.patch.object(
                        validate_nats_config.subprocess,
                        "Popen",
                        side_effect=spawn_reached,
                    ),
                ):
                    try:
                        validate_nats_config._popen_bound(
                            bound,
                            ("--version",),
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            env=validate_nats_config._controlled_environment(root),
                            cwd=root,
                            start_new_session=True,
                        )
                    except (OSError, RuntimeError) as exc:
                        observed = str(exc)
            finally:
                bound.close()
            self.assertIn("Linux descriptor execution", observed)
            self.assertFalse(sentinel.exists())

    def test_renderer_non_linux_launch_fails_before_spawn_side_effects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary_directory = root / "bin"
            binary_directory.mkdir(mode=0o700)
            selected = binary_directory / "envsubst"
            sentinel = root / "renderer-spawn-reached"
            _write_executable(selected, "#!/bin/sh\nexit 0\n")
            with mock.patch.dict(
                os.environ,
                {"PATH": f"{binary_directory}:{os.defpath}"},
            ):
                bound = render_nomad_configs.bind_executable(
                    "envsubst", "unavailable"
                )

            def spawn_reached(*_args, **_kwargs):
                sentinel.write_text("spawned\n", encoding="utf-8")
                raise OSError("spawn reached")

            observed = ""
            try:
                with (
                    mock.patch.object(render_nomad_configs.sys, "platform", "darwin"),
                    mock.patch.object(
                        render_nomad_configs.subprocess,
                        "Popen",
                        side_effect=spawn_reached,
                    ),
                ):
                    try:
                        render_nomad_configs.popen_bound(
                            bound,
                            (),
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            start_new_session=True,
                        )
                    except (OSError, RuntimeError) as exc:
                        observed = str(exc)
            finally:
                bound.close()
            self.assertIn("Linux descriptor execution", observed)
            self.assertFalse(sentinel.exists())

    def test_nested_script_interpreter_chain_is_rejected_before_effects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            interpreter = root / "interpreter"
            parser = root / "nats-server"
            sentinel = root / "nested-interpreter-ran"
            _write_executable(
                interpreter,
                f"#!/bin/sh\nprintf nested > '{sentinel}'\nexec /bin/sh \"$@\"\n",
            )
            _write_executable(
                parser,
                f"#!{interpreter}\nif [ \"${{1:-}}\" = --version ]; then\n"
                "  printf 'nats-server: v2.10.22\\n'\n  exit 0\nfi\nexit 1\n",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            error = validate_nats_config._verify_parser(
                parser,
                workspace,
                validate_nats_config._controlled_environment(workspace),
            )
            self.assertIsNotNone(error)
            self.assertIn("nested script interpreter", error or "")
            self.assertFalse(sentinel.exists())

    def test_renderer_nested_script_interpreter_is_rejected_before_effects(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary_directory = root / "bin"
            binary_directory.mkdir(mode=0o700)
            interpreter = root / "interpreter"
            selected = binary_directory / "envsubst"
            sentinel = root / "renderer-nested-interpreter-ran"
            _write_executable(
                interpreter,
                f"#!/bin/sh\nprintf nested > '{sentinel}'\nexec /bin/sh \"$@\"\n",
            )
            _write_executable(selected, f"#!{interpreter}\nexit 0\n")
            observed = ""
            bound = None
            try:
                with mock.patch.dict(
                    os.environ,
                    {"PATH": f"{binary_directory}:{os.defpath}"},
                ):
                    try:
                        bound = render_nomad_configs.bind_executable(
                            "envsubst", "unavailable"
                        )
                        process = render_nomad_configs.popen_bound(
                            bound,
                            (),
                            stdin=subprocess.DEVNULL,
                            stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE,
                            start_new_session=True,
                        )
                        process.communicate(timeout=2)
                    except (OSError, RuntimeError) as exc:
                        observed = str(exc)
            finally:
                if bound is not None:
                    bound.close()
            self.assertIn("nested script interpreter", observed)
            self.assertFalse(sentinel.exists())

    def test_post_chmod_bind_failure_preserves_cause_and_removes_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            created: list[Path] = []
            real_mkdtemp = validate_nats_config.tempfile.mkdtemp

            def tracked_mkdtemp(*args, **kwargs):
                path = Path(real_mkdtemp(*args, dir=root, **kwargs))
                created.append(path)
                return str(path)

            def fail_after_chmod() -> None:
                raise RuntimeError("post-chmod marker")

            observed: BaseException | None = None
            try:
                with (
                    mock.patch.object(validate_nats_config.sys, "platform", "linux"),
                    mock.patch.object(
                        validate_nats_config.tempfile,
                        "mkdtemp",
                        side_effect=tracked_mkdtemp,
                    ),
                    mock.patch.object(
                        validate_nats_config.BoundExecutable,
                        "verify",
                        side_effect=fail_after_chmod,
                    ),
                ):
                    try:
                        validate_nats_config._bind_executable(
                            Path("/usr/bin/true"), "nats-server"
                        )
                    except BaseException as exc:
                        observed = exc
                self.assertIsInstance(observed, RuntimeError)
                self.assertIn("post-chmod marker", str(observed))
                self.assertTrue(created)
                self.assertFalse(created[0].exists())
            finally:
                for path in created:
                    if path.exists():
                        path.chmod(0o700)
                        for child in path.iterdir():
                            child.unlink()
                        path.rmdir()

    def test_expected_digest_rejects_post_handoff_parser_swap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            sentinel = root / "post-handoff-parser-ran"
            config = root / "server.conf"
            config.write_text("port = 4222\n", encoding="utf-8")
            _write_executable(parser, "#!/bin/sh\nexit 0\n")
            expected = hashlib.sha256(parser.read_bytes()).hexdigest()
            _write_executable(
                parser,
                f"#!/bin/sh\nprintf hostile > '{sentinel}'\nexit 0\n",
            )
            completed = subprocess.run(
                [
                    sys.executable,
                    str(Path(validate_nats_config.__file__)),
                    "--nats-server",
                    str(parser),
                    "--expected-nats-server-sha256",
                    expected,
                    str(config),
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                text=True,
                check=False,
            )
            self.assertNotEqual(completed.returncode, 0)
            self.assertIn("SHA-256", completed.stderr)
            self.assertFalse(sentinel.exists())

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_snapshot_parent_replacement_cannot_redirect_execution(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            sentinel = root / "hostile-snapshot-ran"
            _write_executable(
                parser,
                """#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'nats-server: v2.10.22'
  exit 0
fi
if grep -q 'authorization = \\[\\]' "$3"; then exit 1; fi
exit 0
""",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            real_popen = validate_nats_config._popen_bound
            swapped = False

            def swap_parent(bound, *args, **kwargs):
                nonlocal swapped
                if not swapped and bound.name == "nats-server":
                    swapped = True
                    snapshot = Path(bound.snapshot_directory)
                    snapshot.rename(snapshot.with_name(snapshot.name + ".bound"))
                    snapshot.mkdir(mode=0o700)
                    _write_executable(
                        snapshot / bound.snapshot_name,
                        f"#!/bin/sh\nprintf hostile > '{sentinel}'\nexit 1\n",
                    )
                return real_popen(bound, *args, **kwargs)

            with mock.patch.object(
                validate_nats_config, "_popen_bound", side_effect=swap_parent
            ):
                error = validate_nats_config._verify_parser(
                    parser, workspace, environment
                )
            self.assertIsNone(error)
            self.assertFalse(sentinel.exists())

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_shebang_path_swap_cannot_select_a_hostile_interpreter(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary_directory = root / "bin"
            binary_directory.mkdir(mode=0o700)
            parser = root / "nats-server"
            sentinel = root / "hostile-interpreter-ran"
            _write_executable(
                parser,
                """#!/usr/bin/env sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'nats-server: v2.10.22'
  exit 0
fi
if grep -q 'authorization = \\[\\]' "$3"; then exit 1; fi
exit 0
""",
            )
            (binary_directory / "sh").symlink_to("/bin/sh")
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            environment["PATH"] = f"{binary_directory}:{os.defpath}"
            real_run = validate_nats_config._run_supervised
            swapped = False

            def swap_interpreter(bound, *args, **kwargs):
                nonlocal swapped
                if not swapped and bound.name == "nats-server":
                    swapped = True
                    (binary_directory / "sh").unlink()
                    _write_executable(
                        binary_directory / "sh",
                        f"#!/bin/sh\nprintf hostile > '{sentinel}'\nexit 1\n",
                    )
                return real_run(bound, *args, **kwargs)

            with mock.patch.object(
                validate_nats_config, "_run_supervised", side_effect=swap_interpreter
            ):
                error = validate_nats_config._verify_parser(
                    parser, workspace, environment
                )
            self.assertIsNone(error)
            self.assertFalse(sentinel.exists())

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_selected_openssl_bytes_survive_path_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            binary_directory = root / "bin"
            binary_directory.mkdir(mode=0o700)
            openssl = binary_directory / "openssl"
            sentinel = root / "hostile-openssl-ran"
            hostile = root / "hostile-openssl"
            implementation = """#!/bin/sh
while [ "$#" -gt 0 ]; do
  case "$1" in
    -keyout) shift; printf '%s\n' key > "$1" ;;
    -out) shift; printf '%s\n' cert > "$1" ;;
  esac
  shift
done
"""
            _write_executable(openssl, implementation)
            _write_executable(
                hostile,
                f"""#!/bin/sh
printf '%s\n' hostile > '{sentinel}'
exec "$0.selected" "$@"
""",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            environment["PATH"] = str(binary_directory)
            with _swap_selected_on_run(openssl, hostile, "openssl"):
                certificates = validate_nats_config._generate_certificates(
                    workspace, environment
                )
            self.assertFalse(sentinel.exists())
            self.assertTrue(certificates["key_file"].is_file())
            self.assertTrue(certificates["cert_file"].is_file())

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_timeout_extinguishes_term_ignoring_descendant(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            child_pid = root / "child.pid"
            _write_executable(
                parser,
                f"""#!/bin/sh
sh -c '
trap "" TERM
printf "%s\\n" "$$" > "{child_pid}"
exec </dev/null >/dev/null 2>&1
while :; do sleep 1; done
' &
sleep 30
""",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            descendant = 0
            try:
                with (
                    mock.patch.object(
                        validate_nats_config, "PARSER_TIMEOUT_SECONDS", 0.5
                    ),
                    mock.patch.object(
                        validate_nats_config, "TERM_GRACE_SECONDS", 0.1,
                        create=True,
                    ),
                    mock.patch.object(
                        validate_nats_config, "KILL_GRACE_SECONDS", 0.5,
                        create=True,
                    ),
                ):
                    error = validate_nats_config._verify_parser(
                        parser, workspace, environment
                    )
                self.assertIsNotNone(error)
                self.assertIn("timed out", error or "")
                descendant = _read_pid(child_pid)
                self.assertTrue(_process_is_gone(descendant))
            finally:
                if descendant and not _process_is_gone(descendant):
                    try:
                        os.kill(descendant, signal.SIGKILL)
                    except ProcessLookupError:
                        pass

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_parser_output_flood_fails_closed(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            parser = root / "nats-server"
            _write_executable(
                parser,
                """#!/bin/sh
if [ "${1:-}" = "--version" ]; then
  printf '%s\n' 'nats-server: v2.10.22'
  head -c 2097152 /dev/zero | tr '\\000' x >&2
  exit 0
fi
if grep -q 'authorization = \\[\\]' "$3"; then exit 1; fi
exit 0
""",
            )
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            with mock.patch.object(
                validate_nats_config,
                "MAX_PARSER_OUTPUT_BYTES",
                32 * 1024,
                create=True,
            ):
                error = validate_nats_config._verify_parser(
                    parser, workspace, environment
                )
            self.assertIsNotNone(error)
            self.assertIn("output limit", error or "")

    @unittest.skipUnless(
        sys.platform.startswith("linux"), "requires Linux descriptor execution"
    )
    def test_term_and_hup_extinguish_descendants_before_reraise(self) -> None:
        for signal_number in (signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=signal_number), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                parser = root / "nats-server"
                child_pid = root / "child.pid"
                config = root / "server.conf"
                config.write_text("port = 4222\n", encoding="utf-8")
                _write_executable(
                    parser,
                    f"""#!/bin/sh
sh -c '
trap "" TERM HUP
printf "%s\\n" "$$" > "{child_pid}"
exec </dev/null >/dev/null 2>&1
while :; do sleep 1; done
' &
wait "$!"
""",
                )
                process = subprocess.Popen(
                    [
                        sys.executable,
                        str(Path(validate_nats_config.__file__)),
                        "--nats-server",
                        str(parser),
                        str(config),
                    ],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
                descendant = 0
                try:
                    descendant = _read_pid(child_pid)
                    os.kill(process.pid, signal_number)
                    self.assertEqual(process.wait(timeout=5), -signal_number)
                    self.assertTrue(_process_is_gone(descendant))
                finally:
                    if process.poll() is None:
                        process.kill()
                        process.wait(timeout=2)
                    if descendant and not _process_is_gone(descendant):
                        try:
                            os.kill(descendant, signal.SIGKILL)
                        except ProcessLookupError:
                            pass

    def test_term_and_hup_reap_darwin_signer_groups_before_reraise(self) -> None:
        modules = (
            (
                "renderer",
                render_nomad_configs,
                "adhoc_sign_darwin_system_snapshot",
                "deferred_termination",
            ),
            (
                "nats",
                validate_nats_config,
                "_adhoc_sign_darwin_system_snapshot",
                "_deferred_termination",
            ),
        )
        for label, module, signer_name, context_name in modules:
            for signal_number in (signal.SIGTERM, signal.SIGHUP):
                with (
                    self.subTest(module=label, signal=signal_number),
                    tempfile.TemporaryDirectory() as tmp,
                ):
                    root = Path(tmp)
                    fake_signer = root / "codesign"
                    child_pid = root / "child.pid"
                    snapshot = root / "snapshot"
                    snapshot.write_bytes(b"snapshot")
                    _write_executable(
                        fake_signer,
                        f"""#!/bin/sh
sh -c '
trap "" TERM HUP
printf "%s\\n" "$$" > "{child_pid}"
exec </dev/null >/dev/null 2>&1
while :; do sleep 1; done
' &
wait "$!"
""",
                    )
                    runner = root / "runner.py"
                    runner.write_text(
                        f"""import contextlib
import importlib.util
import os
import subprocess
import sys

spec = importlib.util.spec_from_file_location("target", {str(Path(module.__file__))!r})
assert spec is not None and spec.loader is not None
target = importlib.util.module_from_spec(spec)
sys.modules["target"] = target
spec.loader.exec_module(target)
real_popen = target.subprocess.Popen
real_stat = target.os.stat
target.sys.platform = "darwin"

def fake_stat(path, *args, **kwargs):
    if os.fspath(path) == "/usr/bin/codesign":
        return real_stat("/usr/bin/true")
    return real_stat(path, *args, **kwargs)

def fake_popen(command, *args, **kwargs):
    if command[0] == "/usr/bin/codesign":
        command = [{str(fake_signer)!r}]
    return real_popen(command, *args, **kwargs)

target.os.stat = fake_stat
target.subprocess.Popen = fake_popen
with getattr(target, {context_name!r})():
    getattr(target, {signer_name!r})("/usr/bin/true", {str(snapshot)!r})
raise SystemExit(97)
""",
                        encoding="utf-8",
                    )
                    process = subprocess.Popen(
                        [sys.executable, str(runner)],
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    descendant = 0
                    try:
                        descendant = _read_pid(child_pid)
                        os.kill(process.pid, signal_number)
                        self.assertEqual(process.wait(timeout=5), -signal_number)
                        self.assertTrue(_process_is_gone(descendant))
                    finally:
                        if process.poll() is None:
                            process.kill()
                            process.wait(timeout=2)
                        if descendant and not _process_is_gone(descendant):
                            try:
                                os.kill(descendant, signal.SIGKILL)
                            except ProcessLookupError:
                                pass


if __name__ == "__main__":
    unittest.main()
