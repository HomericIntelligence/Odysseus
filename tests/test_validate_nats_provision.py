#!/usr/bin/env python3
"""Unit tests for the content-pinned NATS parser provisioner."""

from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import signal
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import time
import unittest
from contextlib import ExitStack, redirect_stderr
from unittest import mock


sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

import validate_nats_config
import render_nomad_configs
from validate_nats_config import ParserRelease, provision_nats_server


class LeafAccountAuthenticationTests(unittest.TestCase):
    def test_account_url_declarations_require_the_matching_local_account(self):
        server = Path(__file__).resolve().parents[1] / "configs/nats/server.conf"
        for account in ("HERMES", "AGENTS", "KEYSTONE", "TELEMACHY"):
            for local_account, accepted in ((account, True), ("SYS", False)):
                with self.subTest(account=account, local_account=local_account):
                    with tempfile.TemporaryDirectory() as directory:
                        leaf = Path(directory) / "leaf.conf"
                        leaf.write_text(
                            "leafnodes { remotes [{ "
                            f"url = $NATS_LEAF_{account}_URL; "
                            f'account = "{local_account}"'
                            " }] }\n",
                            encoding="utf-8",
                        )
                        errors = validate_nats_config.validate_auth(leaf, server)
                        self.assertEqual(not errors, accepted, errors)

    def test_endpoint_only_variable_does_not_declare_authentication(self):
        server = Path(__file__).resolve().parents[1] / "configs/nats/server.conf"
        with tempfile.TemporaryDirectory() as directory:
            leaf = Path(directory) / "leaf.conf"
            leaf.write_text(
                'leafnodes { remotes [{ url = $NATS_LEAF_URL; account = "HERMES" }] }\n',
                encoding="utf-8",
            )
            self.assertTrue(validate_nats_config.validate_auth(leaf, server))


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
    # Ordinary shell fixtures must reach the behavior under test rather than
    # fail the independent no-symlink interpreter boundary first.
    if content.startswith("#!/bin/sh\n"):
        content = f"#!{Path('/bin/sh').resolve(strict=True)}\n" + content.split("\n", 1)[1]
    path.write_text(content, encoding="utf-8")
    path.chmod(0o700)


def _simulate_certificate_run(
    _executable,
    arguments,
    *,
    boundary,
    **_kwargs,
):
    outputs = {"-keyout": b"generated-key\n", "-out": b"generated-cert\n"}
    for option, content in outputs.items():
        output = arguments[arguments.index(option) + 1]
        if output.startswith("/proc/self/fd/"):
            descriptor = int(output.rsplit("/", 1)[1])
            os.ftruncate(descriptor, 0)
            os.pwrite(descriptor, content, 0)
        else:
            Path(output).write_bytes(content)
    boundary()
    return validate_nats_config.CommandResult(0, "", "")


def _test_anonymous_file(_label: str, _workspace_descriptor: int) -> int:
    with tempfile.TemporaryFile() as stream:
        descriptor = os.dup(stream.fileno())
    os.fchmod(descriptor, 0o600)
    return descriptor


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


_FIFO_OPEN_PROBE = r'''
from __future__ import annotations

import hashlib
import io
import os
from pathlib import Path
import stat
import sys
import tarfile
import tempfile

sys.path.insert(0, sys.argv[1])
import render_nomad_configs as nomad
import validate_nats_config as nats


def rejected(callable_object) -> None:
    try:
        callable_object()
    except (OSError, RuntimeError):
        return
    raise AssertionError("expected-regular open accepted a FIFO")


case = sys.argv[2]
with tempfile.TemporaryDirectory() as temporary:
    root = Path(temporary)
    if case == "nomad-input":
        os.mkfifo(root / "client.hcl", 0o600)
        directory = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        try:
            rejected(lambda: nomad.read_bound_regular(directory, "client.hcl"))
        finally:
            os.close(directory)
    elif case in {"nomad-source", "nats-source"}:
        module = nomad if case == "nomad-source" else nats
        target = root / "tool"
        target.write_bytes(b"selected executable\n")
        target.chmod(0o700)
        real_stat = os.stat
        swapped = False

        def racing_stat(path, *args, **kwargs):
            global swapped
            result = real_stat(path, *args, **kwargs)
            if not swapped and os.path.abspath(os.fspath(path)) == str(target):
                swapped = True
                target.unlink()
                os.mkfifo(target, 0o700)
            return result

        module.os.stat = racing_stat
        if module is nomad:
            module.shutil.which = lambda _name: str(target)
            rejected(lambda: module.bind_executable("tool", "tool unavailable"))
        else:
            rejected(lambda: module._bind_executable(target, "tool"))
    elif case in {"nomad-launch", "nats-launch"}:
        module = nomad if case == "nomad-launch" else nats
        snapshot = root / "snapshot"
        snapshot.mkdir(mode=0o700)
        executable = snapshot / "executable"
        content = b"selected executable\n"
        executable.write_bytes(content)
        executable.chmod(0o500)
        directory = os.open(snapshot, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
        os.fchmod(directory, 0o500)
        state = executable.stat()
        bound = module.BoundExecutable(
            name="tool",
            selected_path=str(executable),
            snapshot_directory=str(snapshot),
            directory_descriptor=directory,
            snapshot_name=executable.name,
            snapshot_state=state,
            directory_state=os.fstat(directory),
            digest=hashlib.sha256(content).digest(),
        )
        os.fchmod(directory, 0o700)
        executable.rename(snapshot / "selected")
        os.mkfifo(executable, 0o500)
        os.fchmod(directory, 0o500)
        module.sys.platform = "linux"
        if module is nomad:
            rejected(lambda: module.popen_bound(bound, ()))
        else:
            rejected(
                lambda: module._popen_bound(
                    bound,
                    (),
                    env={},
                    pass_fds=(),
                )
            )
    elif case in {"nomad-snapshot", "nats-snapshot"}:
        module = nomad if case == "nomad-snapshot" else nats
        source = root / "tool"
        source.write_bytes(b"selected executable\n")
        source.chmod(0o700)

        def swap_snapshot(_selected: str, snapshot_path: str) -> bool:
            snapshot = Path(snapshot_path)
            snapshot.rename(snapshot.with_name("selected"))
            os.mkfifo(snapshot, 0o500)
            return case == "nomad-snapshot"

        if module is nomad:
            module.shutil.which = lambda _name: str(source)
            module.adhoc_sign_darwin_system_snapshot = swap_snapshot
            rejected(lambda: module.bind_executable("tool", "tool unavailable"))
        else:
            module._adhoc_sign_darwin_system_snapshot = swap_snapshot
            rejected(lambda: module._bind_executable(source, "tool"))
    elif case == "nats-config-snapshot":
        workspace = root / "workspace"
        workspace.mkdir(mode=0o700)
        directory = os.open(
            workspace,
            os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
        )
        real_fsync = os.fsync
        swapped = False

        def racing_fsync(descriptor: int) -> None:
            global swapped
            real_fsync(descriptor)
            if not swapped and stat.S_ISREG(os.fstat(descriptor).st_mode):
                names = os.listdir(directory)
                if names:
                    swapped = True
                    name = names[0]
                    os.rename(
                        name,
                        name + ".selected",
                        src_dir_fd=directory,
                        dst_dir_fd=directory,
                    )
                    os.mkfifo(name, 0o400, dir_fd=directory)

        nats.os.fsync = racing_fsync

        def bind() -> None:
            with nats._bound_config_input(
                workspace,
                b"port = 4222\n",
                "FIFO probe",
                directory,
            ):
                raise AssertionError("FIFO config snapshot was accepted")

        try:
            rejected(bind)
        finally:
            os.close(directory)
    elif case == "nats-provisioned-parser":
        member_name = "nats-server-v9.9.9-test/nats-server"
        parser_bytes = b"selected parser\n"
        payload = io.BytesIO()
        with tarfile.open(fileobj=payload, mode="w:gz") as archive:
            member = tarfile.TarInfo(member_name)
            member.size = len(parser_bytes)
            member.mode = 0o755
            archive.addfile(member, io.BytesIO(parser_bytes))
        archive_bytes = payload.getvalue()
        release = nats.ParserRelease(
            url=(
                "https://github.com/nats-io/nats-server/releases/download/"
                "v9.9.9/nats-server-v9.9.9-test.tar.gz"
            ),
            member=member_name,
            sha256=hashlib.sha256(archive_bytes).hexdigest(),
        )

        class Response(io.BytesIO):
            def __enter__(self):
                return self

            def __exit__(self, *_args):
                self.close()

            def geturl(self):
                return release.url

        real_stat = os.stat
        swapped = False

        def racing_stat(path, *args, **kwargs):
            global swapped
            result = real_stat(path, *args, **kwargs)
            if (
                not swapped
                and os.fspath(path) == "nats-server"
                and kwargs.get("dir_fd") is not None
            ):
                swapped = True
                directory = kwargs["dir_fd"]
                os.rename(
                    "nats-server",
                    "nats-server.selected",
                    src_dir_fd=directory,
                    dst_dir_fd=directory,
                )
                os.mkfifo("nats-server", 0o700, dir_fd=directory)
            return result

        nats.os.stat = racing_stat
        destination = root / "parser"
        destination.mkdir(mode=0o700)
        rejected(
            lambda: nats.provision_nats_server(
                destination,
                release=release,
                opener=lambda *_args, **_kwargs: Response(archive_bytes),
            )
        )
    else:
        raise AssertionError(f"unknown FIFO probe: {case}")
'''


def _run_fifo_open_probe(case: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [
            sys.executable,
            "-I",
            "-B",
            "-c",
            _FIFO_OPEN_PROBE,
            str(Path(__file__).resolve().parent.parent / "scripts"),
            case,
        ],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=2,
        check=False,
    )


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


class RuntimeBoundaryTests(unittest.TestCase):
    def test_expected_regular_opens_reject_fifo_swaps_without_blocking(self) -> None:
        cases = (
            "nomad-input",
            "nomad-source",
            "nomad-snapshot",
            "nomad-launch",
            "nats-source",
            "nats-snapshot",
            "nats-launch",
            "nats-config-snapshot",
            "nats-provisioned-parser",
        )
        for case in cases:
            with self.subTest(case=case):
                try:
                    completed = _run_fifo_open_probe(case)
                except subprocess.TimeoutExpired as error:
                    self.fail(f"{case} blocked on a FIFO: {error}")
                self.assertEqual(completed.returncode, 0, completed.stdout)

    def test_nomad_children_receive_only_required_environment(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            snapshot = root / "snapshot"
            snapshot.mkdir(mode=0o700)
            executable = snapshot / "executable"
            executable.write_bytes(b"probe")
            executable.chmod(0o500)
            directory_descriptor = os.open(
                snapshot,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            os.fchmod(directory_descriptor, 0o500)
            state = executable.stat()
            bound = render_nomad_configs.BoundExecutable(
                name="environment-probe",
                selected_path=str(executable),
                snapshot_directory=str(snapshot),
                directory_descriptor=directory_descriptor,
                snapshot_name=executable.name,
                snapshot_state=state,
                directory_state=os.fstat(directory_descriptor),
                digest=hashlib.sha256(b"probe").digest(),
            )
            with mock.patch.dict(
                os.environ,
                {
                    "PATH": "/hostile/path",
                    "NOMAD_SERVER_IP": "192.0.2.10",
                    "NOMAD_ADVERTISE_ADDR": "192.0.2.11",
                    "ODYSSEUS_SECRET_CANARY": "must-not-cross",
                    "LD_PRELOAD": "/dev/null",
                },
                clear=True,
            ), mock.patch.object(
                render_nomad_configs.sys, "platform", "linux"
            ), mock.patch.object(
                render_nomad_configs.subprocess, "Popen", return_value=object()
            ) as popen:
                render_nomad_configs.popen_bound(bound, ())
            environment = popen.call_args.kwargs["env"]
            self.assertEqual(
                environment,
                {
                    "PATH": os.defpath,
                    "LANG": "C",
                    "LC_ALL": "C",
                    "NOMAD_SERVER_IP": "192.0.2.10",
                    "NOMAD_ADVERTISE_ADDR": "192.0.2.11",
                },
            )
            bound.close()

    def test_snapshot_close_preserves_replacement_leaf_and_directory(self) -> None:
        for module in (validate_nats_config, render_nomad_configs):
            with self.subTest(module=module.__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                snapshot = root / "snapshot"
                snapshot.mkdir(mode=0o700)
                executable = snapshot / "executable"
                executable.write_bytes(b"selected")
                executable.chmod(0o500)
                directory_descriptor = os.open(
                    snapshot,
                    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                )
                os.fchmod(directory_descriptor, 0o500)
                state = executable.stat()
                bound = module.BoundExecutable(
                    name="test-tool",
                    selected_path=str(executable),
                    snapshot_directory=str(snapshot),
                    directory_descriptor=directory_descriptor,
                    snapshot_name=executable.name,
                    snapshot_state=state,
                    directory_state=os.fstat(directory_descriptor),
                    digest=hashlib.sha256(b"selected").digest(),
                )
                os.fchmod(directory_descriptor, 0o700)
                os.rename(
                    "executable",
                    "displaced",
                    src_dir_fd=directory_descriptor,
                    dst_dir_fd=directory_descriptor,
                )
                os.unlink("displaced", dir_fd=directory_descriptor)
                replacement_descriptor = os.open(
                    "executable",
                    os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                    0o500,
                    dir_fd=directory_descriptor,
                )
                os.write(replacement_descriptor, b"replacement")
                replacement_state = os.fstat(replacement_descriptor)
                os.close(replacement_descriptor)
                os.fchmod(directory_descriptor, 0o500)

                bound.close()

                self.assertTrue(snapshot.is_dir())
                self.assertEqual(executable.read_bytes(), b"replacement")
                self.assertEqual(executable.stat().st_ino, replacement_state.st_ino)
                executable.unlink()
                snapshot.rmdir()

                second_snapshot = root / "second-snapshot"
                second_snapshot.mkdir(mode=0o700)
                second_executable = second_snapshot / "executable"
                second_executable.write_bytes(b"selected")
                second_executable.chmod(0o500)
                second_descriptor = os.open(
                    second_snapshot,
                    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                )
                os.fchmod(second_descriptor, 0o500)
                second_state = second_executable.stat()
                second_bound = module.BoundExecutable(
                    name="test-tool",
                    selected_path=str(second_executable),
                    snapshot_directory=str(second_snapshot),
                    directory_descriptor=second_descriptor,
                    snapshot_name=second_executable.name,
                    snapshot_state=second_state,
                    directory_state=os.fstat(second_descriptor),
                    digest=hashlib.sha256(b"selected").digest(),
                )
                displaced_directory = root / "second-snapshot.displaced"
                second_snapshot.rename(displaced_directory)
                second_snapshot.mkdir(mode=0o700)
                replacement_directory_state = second_snapshot.stat()

                second_bound.close()

                self.assertTrue(second_snapshot.is_dir())
                self.assertEqual(
                    second_snapshot.stat().st_ino,
                    replacement_directory_state.st_ino,
                )
                second_snapshot.rmdir()
                displaced_directory.rmdir()

    def test_bind_failure_preserves_primary_error_and_replacements(self) -> None:
        true_path = shutil.which("true", path=os.defpath)
        self.assertIsNotNone(true_path)
        assert true_path is not None
        for module in (validate_nats_config, render_nomad_configs):
            for replacement in ("leaf", "directory"):
                with (
                    self.subTest(module=module.__name__, replacement=replacement),
                    tempfile.TemporaryDirectory() as tmp,
                ):
                    root = Path(tmp)
                    created: list[Path] = []
                    real_mkdtemp = module.tempfile.mkdtemp

                    def tracked_mkdtemp(*args, **kwargs):
                        path = Path(real_mkdtemp(*args, dir=root, **kwargs))
                        created.append(path)
                        return str(path)

                    replacement_state: os.stat_result | None = None

                    def replace_then_fail(bound) -> None:
                        nonlocal replacement_state
                        snapshot = Path(bound.snapshot_directory)
                        if replacement == "leaf":
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
                            os.write(descriptor, b"replacement")
                            replacement_state = os.fstat(descriptor)
                            os.close(descriptor)
                            os.fchmod(bound.directory_descriptor, 0o500)
                        else:
                            displaced = snapshot.with_name(snapshot.name + ".selected")
                            snapshot.rename(displaced)
                            snapshot.mkdir(mode=0o700)
                            replacement_state = snapshot.stat()
                        raise RuntimeError("primary bind failure")

                    with (
                        mock.patch.object(
                            module.tempfile,
                            "mkdtemp",
                            side_effect=tracked_mkdtemp,
                        ),
                        mock.patch.object(
                            module.BoundExecutable,
                            "verify",
                            new=replace_then_fail,
                        ),
                        mock.patch.dict(os.environ, {"PATH": os.defpath}),
                    ):
                        with self.assertRaisesRegex(
                            RuntimeError, "primary bind failure"
                        ):
                            if module is validate_nats_config:
                                module._bind_executable(Path(true_path), "test-tool")
                            else:
                                module.bind_executable("true", "test-tool unavailable")

                    self.assertTrue(created)
                    created_path = created[0]
                    assert replacement_state is not None
                    if replacement == "leaf":
                        replacement_path = created_path / "executable"
                        self.assertEqual(replacement_path.read_bytes(), b"replacement")
                        self.assertEqual(
                            replacement_path.stat().st_ino,
                            replacement_state.st_ino,
                        )
                    else:
                        self.assertTrue(created_path.is_dir())
                        self.assertEqual(
                            created_path.stat().st_ino,
                            replacement_state.st_ino,
                        )
                    for path in root.iterdir():
                        if path.is_dir():
                            path.chmod(0o700)
                            for child in path.iterdir():
                                child.unlink()
                            path.rmdir()

    def test_certificate_leaf_replacements_cannot_capture_output(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            key_victim = root / "key-victim"
            cert_victim = root / "cert-victim"
            key_victim.write_text("key-victim\n", encoding="utf-8")
            cert_victim.write_text("cert-victim\n", encoding="utf-8")
            key_victim_state = key_victim.stat()
            cert_victim_state = cert_victim.stat()
            environment = validate_nats_config._controlled_environment(workspace)
            executable = mock.Mock()
            executable.name = "openssl"

            def plant_leaf_replacements(bound, *args, **kwargs):
                (workspace / "server-key.pem").symlink_to(key_victim)
                (workspace / "server-cert.pem").symlink_to(cert_victim)
                return _simulate_certificate_run(bound, *args, **kwargs)

            with (
                mock.patch.object(
                    validate_nats_config.shutil,
                    "which",
                    return_value="/controlled/openssl",
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_bind_executable",
                    return_value=executable,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_run_supervised",
                    side_effect=plant_leaf_replacements,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_new_anonymous_file",
                    side_effect=_test_anonymous_file,
                ),
                self.assertRaisesRegex(RuntimeError, "workspace|certificate"),
            ):
                validate_nats_config._generate_certificates(
                    workspace, environment
                )

            self.assertEqual(key_victim.read_text(encoding="utf-8"), "key-victim\n")
            self.assertEqual(
                cert_victim.read_text(encoding="utf-8"), "cert-victim\n"
            )
            self.assertEqual(key_victim.stat().st_ino, key_victim_state.st_ino)
            self.assertEqual(key_victim.stat().st_mode, key_victim_state.st_mode)
            self.assertEqual(cert_victim.stat().st_ino, cert_victim_state.st_ino)
            self.assertEqual(cert_victim.stat().st_mode, cert_victim_state.st_mode)
            self.assertTrue((workspace / "server-key.pem").is_symlink())
            self.assertTrue((workspace / "server-cert.pem").is_symlink())

    def test_generated_certificates_are_anonymous_bound_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            workspace.mkdir(mode=0o700)
            environment = validate_nats_config._controlled_environment(workspace)
            executable = mock.Mock()
            executable.name = "openssl"

            with (
                mock.patch.object(
                    validate_nats_config.shutil,
                    "which",
                    return_value="/controlled/openssl",
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_bind_executable",
                    return_value=executable,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_run_supervised",
                    side_effect=_simulate_certificate_run,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_new_anonymous_file",
                    side_effect=_test_anonymous_file,
                ),
            ):
                certificates = validate_nats_config._generate_certificates(
                    workspace, environment
                )
            try:
                key_path = os.fspath(certificates["key_file"])
                cert_path = os.fspath(certificates["cert_file"])
                self.assertTrue(key_path.startswith("/proc/self/fd/"))
                self.assertTrue(cert_path.startswith("/proc/self/fd/"))
                self.assertEqual(
                    os.fspath(certificates["ca_file"]), cert_path
                )
                key_descriptor = int(key_path.rsplit("/", 1)[1])
                cert_descriptor = int(cert_path.rsplit("/", 1)[1])
                self.assertEqual(
                    os.pread(key_descriptor, 1024, 0), b"generated-key\n"
                )
                self.assertEqual(
                    os.pread(cert_descriptor, 1024, 0), b"generated-cert\n"
                )
                self.assertEqual(list(workspace.iterdir()), [])
            finally:
                close = getattr(certificates, "close", None)
                if close is not None:
                    close()

    def test_parser_inherits_and_revalidates_certificate_inputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp) / "workspace"
            workspace.mkdir(mode=0o700)
            workspace_descriptor = os.open(
                workspace,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            writer = _test_anonymous_file(
                "retained-certificate",
                workspace_descriptor,
            )
            os.write(writer, b"certificate")
            retained = validate_nats_config._bind_anonymous_input(
                writer,
                "retained certificate",
                maximum_size=validate_nats_config.MAX_CERTIFICATE_BYTES,
                require_nonempty=True,
            )
            executable = mock.Mock()
            executable.name = "nats-server"
            observed_pass_fds: list[tuple[int, ...]] = []

            def supervised(_executable, _arguments, **kwargs):
                observed_pass_fds.append(tuple(kwargs.get("pass_fds", ())))
                return validate_nats_config.CommandResult(0, "", "")

            try:
                with mock.patch.object(
                    validate_nats_config,
                    "_run_supervised",
                    side_effect=supervised,
                ):
                    validate_nats_config._run_parser_with_config(
                        executable,
                        ("-t", "-c"),
                        "port = 4222\n",
                        label="retained input propagation",
                        environment={},
                        workspace=workspace,
                        boundary=lambda: None,
                        workspace_descriptor=workspace_descriptor,
                        retained_inputs=(retained,),
                        deadline=time.monotonic() + 1,
                    )
                self.assertEqual(len(observed_pass_fds), 1)
                self.assertIn(retained.descriptor, observed_pass_fds[0])

                def mutate_then_succeed(_executable, _arguments, **_kwargs):
                    os.fchmod(writer, 0o600)
                    os.pwrite(writer, b"substitute!", 0)
                    os.fchmod(writer, 0o400)
                    return validate_nats_config.CommandResult(0, "", "")

                with (
                    mock.patch.object(
                        validate_nats_config,
                        "_run_supervised",
                        side_effect=mutate_then_succeed,
                    ),
                    self.assertRaisesRegex(
                        RuntimeError, "retained certificate"
                    ),
                ):
                    validate_nats_config._run_parser_with_config(
                        executable,
                        ("-t", "-c"),
                        "port = 4222\n",
                        label="retained input mutation",
                        environment={},
                        workspace=workspace,
                        boundary=lambda: None,
                        workspace_descriptor=workspace_descriptor,
                        retained_inputs=(retained,),
                        deadline=time.monotonic() + 1,
                    )
            finally:
                retained.close()
                os.close(writer)
                os.close(workspace_descriptor)

    def test_certificate_generation_rejects_workspace_ancestor_swap(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            workspace.mkdir(mode=0o700)
            displaced = root / "workspace.displaced"
            key_victim = root / "key-victim"
            cert_victim = root / "cert-victim"
            key_victim.write_text("key-victim\n", encoding="utf-8")
            cert_victim.write_text("cert-victim\n", encoding="utf-8")
            key_victim_state = key_victim.stat()
            cert_victim_state = cert_victim.stat()
            environment = validate_nats_config._controlled_environment(workspace)
            executable = mock.Mock()
            executable.name = "openssl"

            def swap_workspace(bound, *args, **kwargs):
                workspace.rename(displaced)
                workspace.mkdir(mode=0o700)
                (workspace / "server-key.pem").symlink_to(key_victim)
                (workspace / "server-cert.pem").symlink_to(cert_victim)
                return _simulate_certificate_run(bound, *args, **kwargs)

            with (
                mock.patch.object(
                    validate_nats_config.shutil,
                    "which",
                    return_value="/controlled/openssl",
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_bind_executable",
                    return_value=executable,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_run_supervised",
                    side_effect=swap_workspace,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_new_anonymous_file",
                    side_effect=_test_anonymous_file,
                ),
                self.assertRaisesRegex(RuntimeError, "workspace|certificate"),
            ):
                validate_nats_config._generate_certificates(workspace, environment)

            self.assertEqual(key_victim.read_text(encoding="utf-8"), "key-victim\n")
            self.assertEqual(
                cert_victim.read_text(encoding="utf-8"), "cert-victim\n"
            )
            self.assertEqual(key_victim.stat().st_ino, key_victim_state.st_ino)
            self.assertEqual(key_victim.stat().st_mode, key_victim_state.st_mode)
            self.assertEqual(cert_victim.stat().st_ino, cert_victim_state.st_ino)
            self.assertEqual(cert_victim.stat().st_mode, cert_victim_state.st_mode)
            self.assertTrue((workspace / "server-key.pem").is_symlink())
            self.assertTrue((workspace / "server-cert.pem").is_symlink())

    def test_replaced_validation_workspace_survives_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real_mkdtemp = validate_nats_config.tempfile.mkdtemp
            replacement: Path | None = None
            displaced: Path | None = None
            sentinel: Path | None = None

            def tracked_mkdtemp(suffix=None, prefix=None, dir=None):
                del dir
                return real_mkdtemp(suffix=suffix, prefix=prefix, dir=root)

            def replace_workspace(_executable, workspace, *_args, **_kwargs):
                nonlocal replacement, displaced, sentinel
                replacement = Path(workspace)
                displaced = replacement.with_name(replacement.name + ".selected")
                replacement.rename(displaced)
                replacement.mkdir(mode=0o700)
                sentinel = replacement / "replacement-sentinel"
                sentinel.write_text("replacement\n", encoding="utf-8")
                return "primary workspace failure"

            stderr = io.StringIO()
            with (
                mock.patch.object(
                    validate_nats_config.tempfile,
                    "mkdtemp",
                    side_effect=tracked_mkdtemp,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_verify_parser",
                    side_effect=replace_workspace,
                ),
                redirect_stderr(stderr),
            ):
                result = validate_nats_config._validate_syntax(
                    [],
                    validate_nats_config.ParserExecutable(
                        Path(shutil.which("true", path=os.defpath) or "/usr/bin/true"),
                        None,
                    ),
                )

            self.assertEqual(result, 1)
            self.assertIn("primary workspace failure", stderr.getvalue())
            assert replacement is not None and displaced is not None and sentinel is not None
            self.assertTrue(replacement.is_dir())
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "replacement\n")
            replacement.chmod(0o700)
            sentinel.unlink()
            replacement.rmdir()
            displaced.chmod(0o700)
            displaced.rmdir()

    def test_replaced_parser_workspace_survives_cleanup(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            real_mkdtemp = validate_nats_config.tempfile.mkdtemp
            replacement: Path | None = None
            displaced: Path | None = None
            sentinel: Path | None = None

            def tracked_mkdtemp(suffix=None, prefix=None, dir=None):
                del dir
                return real_mkdtemp(suffix=suffix, prefix=prefix, dir=root)

            def provision(workspace: Path) -> validate_nats_config.ParserExecutable:
                parser = workspace / "nats-server"
                parser.write_bytes(b"selected parser\n")
                parser.chmod(0o700)
                return validate_nats_config.ParserExecutable(
                    parser,
                    hashlib.sha256(parser.read_bytes()).hexdigest(),
                )

            with (
                mock.patch.object(
                    validate_nats_config.tempfile,
                    "mkdtemp",
                    side_effect=tracked_mkdtemp,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "provision_nats_server",
                    side_effect=provision,
                ),
            ):
                with validate_nats_config._parser_context(None) as parser:
                    replacement = parser.path.parent
                    displaced = replacement.with_name(replacement.name + ".selected")
                    replacement.rename(displaced)
                    replacement.mkdir(mode=0o700)
                    sentinel = replacement / "replacement-sentinel"
                    sentinel.write_text("replacement\n", encoding="utf-8")

            assert replacement is not None and displaced is not None and sentinel is not None
            self.assertTrue(replacement.is_dir())
            self.assertEqual(sentinel.read_text(encoding="utf-8"), "replacement\n")

    def test_syntax_revalidates_source_immediately_before_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "server.conf"
            source.write_text("port = 4222\n", encoding="utf-8")
            executable = mock.Mock()

            def mutate_source(*_args, **_kwargs):
                source.write_text("port = 4333\n", encoding="utf-8")
                return validate_nats_config.CommandResult(0, "", ""), "/proc/self/fd/9"

            with (
                mock.patch.object(
                    validate_nats_config,
                    "_bind_executable",
                    return_value=executable,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_verify_parser",
                    return_value=None,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_run_parser_with_config",
                    side_effect=mutate_source,
                ),
                redirect_stderr(io.StringIO()) as stderr,
            ):
                result = validate_nats_config._validate_syntax(
                    [source],
                    validate_nats_config.ParserExecutable(Path("/unused"), None),
                )

            self.assertEqual(result, 1)
            self.assertIn("changed", stderr.getvalue())
            executable.close.assert_called_once_with()

    def test_syntax_revalidates_parent_route_before_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config_root = root / "config-root"
            config_root.mkdir()
            source = config_root / "server.conf"
            source.write_text("port = 4222\n", encoding="utf-8")
            executable = mock.Mock()

            def replace_parent(*_args, **_kwargs):
                config_root.rename(root / "selected-config-root")
                config_root.mkdir()
                (config_root / source.name).write_text(
                    "port = 4222\n", encoding="utf-8"
                )
                return validate_nats_config.CommandResult(0, "", ""), "/proc/self/fd/9"

            with (
                mock.patch.object(
                    validate_nats_config,
                    "_bind_executable",
                    return_value=executable,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_verify_parser",
                    return_value=None,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_run_parser_with_config",
                    side_effect=replace_parent,
                ),
                redirect_stderr(io.StringIO()) as stderr,
            ):
                result = validate_nats_config._validate_syntax(
                    [source],
                    validate_nats_config.ParserExecutable(Path("/unused"), None),
                )

            self.assertEqual(result, 1)
            self.assertIn("parent route changed", stderr.getvalue())
            executable.close.assert_called_once_with()

    def test_auth_keeps_quoted_delimiters_as_scalar_values(self) -> None:
        for value in ("{", "}", "[", "]", "(", ")", ":", "="):
            with self.subTest(value=value), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp)
                leaf = root / "leaf.conf"
                server = root / "server.conf"
                leaf.write_text(
                    'leafnodes { remotes = [{ url = "nats://user:pass@127.0.0.1:7422" }] }\n',
                    encoding="utf-8",
                )
                server.write_text(
                    f'description = "{value}"\n'
                    'authorization { token = $NATS_CLIENT_TOKEN }\n'
                    'leafnodes { authorization { user = $NATS_LEAF_USER '
                    'password = $NATS_LEAF_PASSWORD } }\n',
                    encoding="utf-8",
                )
                self.assertEqual(validate_nats_config.validate_auth(leaf, server), [])

    def test_auth_revalidates_sources_immediately_before_success(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            leaf = root / "leaf.conf"
            server = root / "server.conf"
            leaf.write_text(
                'leafnodes { remotes = [{ url = "nats://user:pass@127.0.0.1:7422" }] }\n',
                encoding="utf-8",
            )
            server.write_text(
                'authorization { token = $NATS_CLIENT_TOKEN }\n'
                'leafnodes { authorization { user = $NATS_LEAF_USER '
                'password = $NATS_LEAF_PASSWORD } }\n',
                encoding="utf-8",
            )
            real_pairs = validate_nats_config._delimiter_pairs
            calls = 0

            def mutate_after_read(tokens):
                nonlocal calls
                parsed = real_pairs(tokens)
                calls += 1
                if calls == 2:
                    server.write_text("port = 4333\n", encoding="utf-8")
                return parsed

            with mock.patch.object(
                validate_nats_config,
                "_delimiter_pairs",
                side_effect=mutate_after_read,
            ):
                errors = validate_nats_config.validate_auth(leaf, server)

            self.assertTrue(any("changed" in error for error in errors), errors)

    def test_syntax_rejects_same_inode_mutation_during_terminal_verify(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "server.conf"
            source.write_text("port = 4222\n", encoding="utf-8")
            source_inode = source.stat().st_ino
            executable = mock.Mock()
            armed = False
            mutated = False
            real_pread = validate_nats_config.os.pread

            def succeed_and_arm(*_args, **_kwargs):
                nonlocal armed
                armed = True
                return validate_nats_config.CommandResult(0, "", ""), "/proc/self/fd/9"

            def mutate_after_observation(
                descriptor: int,
                size: int,
                offset: int,
            ) -> bytes:
                nonlocal mutated
                observed = real_pread(descriptor, size, offset)
                current = os.fstat(descriptor)
                if armed and not mutated and current.st_ino == source_inode:
                    source.write_text("port = 4333\n", encoding="utf-8")
                    mutated = True
                return observed

            with (
                mock.patch.object(
                    validate_nats_config,
                    "_bind_executable",
                    return_value=executable,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_verify_parser",
                    return_value=None,
                ),
                mock.patch.object(
                    validate_nats_config,
                    "_run_parser_with_config",
                    side_effect=succeed_and_arm,
                ),
                mock.patch.object(
                    validate_nats_config.os,
                    "pread",
                    side_effect=mutate_after_observation,
                ),
                redirect_stderr(io.StringIO()) as stderr,
            ):
                result = validate_nats_config._validate_syntax(
                    [source],
                    validate_nats_config.ParserExecutable(Path("/unused"), None),
                )

            self.assertTrue(mutated)
            self.assertEqual(result, 1)
            self.assertIn("changed", stderr.getvalue())

    def test_auth_rejects_parent_swap_during_terminal_verify(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            leaf_root = root / "leaf-root"
            server_root = root / "server-root"
            leaf_root.mkdir()
            server_root.mkdir()
            leaf = leaf_root / "leaf.conf"
            server = server_root / "server.conf"
            leaf.write_text(
                'leafnodes { remotes = [{ url = "nats://user:pass@127.0.0.1:7422" }] }\n',
                encoding="utf-8",
            )
            server_content = (
                'authorization { token = $NATS_CLIENT_TOKEN }\n'
                'leafnodes { authorization { user = $NATS_LEAF_USER '
                'password = $NATS_LEAF_PASSWORD } }\n'
            )
            server.write_text(server_content, encoding="utf-8")
            displaced = root / "server-root.selected"
            real_pairs = validate_nats_config._delimiter_pairs
            selected_server_root = server_root.stat()
            real_fstat = validate_nats_config.os.fstat
            parsed_sources = 0
            armed = False
            swapped = False

            def arm_after_server(tokens):
                nonlocal parsed_sources, armed
                result = real_pairs(tokens)
                parsed_sources += 1
                if parsed_sources == 2:
                    armed = True
                return result

            def swap_after_route_observation(descriptor: int):
                nonlocal swapped
                observed = real_fstat(descriptor)
                if (
                    armed
                    and not swapped
                    and stat.S_ISDIR(observed.st_mode)
                    and observed.st_dev == selected_server_root.st_dev
                    and observed.st_ino == selected_server_root.st_ino
                ):
                    server_root.rename(displaced)
                    server_root.mkdir()
                    (server_root / server.name).write_text(
                        server_content,
                        encoding="utf-8",
                    )
                    swapped = True
                return observed

            with (
                mock.patch.object(
                    validate_nats_config,
                    "_delimiter_pairs",
                    side_effect=arm_after_server,
                ),
                mock.patch.object(
                    validate_nats_config.os,
                    "fstat",
                    side_effect=swap_after_route_observation,
                ),
            ):
                errors = validate_nats_config.validate_auth(leaf, server)

            self.assertTrue(swapped)
            self.assertTrue(any("parent route changed" in error for error in errors), errors)

    def test_snapshot_cleanup_race_never_deletes_replacement_leaf(self) -> None:
        for module, cleanup_name in (
            (validate_nats_config, "_cleanup_private_snapshot"),
            (render_nomad_configs, "cleanup_private_snapshot"),
        ):
            with self.subTest(module=module.__name__), tempfile.TemporaryDirectory() as tmp:
                root = Path(tmp) / "snapshot"
                root.mkdir(mode=0o700)
                target = root / "executable"
                held = root / "owned-held"
                intruder = root / "replacement-ready"
                sentinel = root / "sentinel"
                target.write_bytes(b"owned")
                intruder.write_bytes(b"replacement")
                sentinel.write_bytes(b"retain-directory")
                created = target.stat()
                directory = os.open(
                    root,
                    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
                )
                raced = False
                real_unlink = os.unlink

                def install_replacement_before_unlink(
                    path,
                    *args,
                    dir_fd=None,
                    **kwargs,
                ):
                    nonlocal raced
                    if path == target.name and not raced:
                        raced = True
                        os.rename(
                            target.name,
                            held.name,
                            src_dir_fd=directory,
                            dst_dir_fd=directory,
                        )
                        os.rename(
                            intruder.name,
                            target.name,
                            src_dir_fd=directory,
                            dst_dir_fd=directory,
                        )
                    return real_unlink(path, *args, dir_fd=dir_fd, **kwargs)

                with ExitStack() as stack:
                    if hasattr(module, "_rename_noreplace"):
                        real_rename = module._rename_noreplace

                        def install_replacement_before_quarantine(
                            parent: int,
                            source_name: str,
                            quarantine_name: str,
                        ) -> None:
                            nonlocal raced
                            if source_name == target.name and not raced:
                                raced = True
                                os.rename(
                                    target.name,
                                    held.name,
                                    src_dir_fd=directory,
                                    dst_dir_fd=directory,
                                )
                                os.rename(
                                    intruder.name,
                                    target.name,
                                    src_dir_fd=directory,
                                    dst_dir_fd=directory,
                                )
                            real_rename(parent, source_name, quarantine_name)

                        stack.enter_context(
                            mock.patch.object(
                                module,
                                "_rename_noreplace",
                                side_effect=install_replacement_before_quarantine,
                            )
                        )
                    else:
                        stack.enter_context(
                            mock.patch.object(
                                module.os,
                                "unlink",
                                side_effect=install_replacement_before_unlink,
                            )
                        )
                    getattr(module, cleanup_name)(
                        directory,
                        str(root),
                        target.name,
                        created,
                    )
                os.close(directory)

                self.assertTrue(raced)
                self.assertTrue(target.exists())
                self.assertEqual(target.read_bytes(), b"replacement")
                self.assertEqual(held.read_bytes(), b"owned")

    def test_publication_cleanup_race_never_deletes_replacement_leaf(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "client.hcl"
            held = root / "owned-held"
            intruder = root / "replacement-ready"
            target.write_bytes(b"owned")
            intruder.write_bytes(b"replacement")
            created = target.stat()
            directory = os.open(
                root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            raced = False
            real_unlink = os.unlink

            def install_replacement_before_unlink(
                path,
                *args,
                dir_fd=None,
                **kwargs,
            ):
                nonlocal raced
                if path == target.name and not raced:
                    raced = True
                    os.rename(
                        target.name,
                        held.name,
                        src_dir_fd=directory,
                        dst_dir_fd=directory,
                    )
                    os.rename(
                        intruder.name,
                        target.name,
                        src_dir_fd=directory,
                        dst_dir_fd=directory,
                    )
                return real_unlink(path, *args, dir_fd=dir_fd, **kwargs)

            with ExitStack() as stack:
                if hasattr(render_nomad_configs, "_rename_noreplace"):
                    real_rename = render_nomad_configs._rename_noreplace

                    def install_replacement_before_quarantine(
                        parent: int,
                        source_name: str,
                        quarantine_name: str,
                    ) -> None:
                        nonlocal raced
                        if source_name == target.name and not raced:
                            raced = True
                            os.rename(
                                target.name,
                                held.name,
                                src_dir_fd=directory,
                                dst_dir_fd=directory,
                            )
                            os.rename(
                                intruder.name,
                                target.name,
                                src_dir_fd=directory,
                                dst_dir_fd=directory,
                            )
                        real_rename(parent, source_name, quarantine_name)

                    stack.enter_context(
                        mock.patch.object(
                            render_nomad_configs,
                            "_rename_noreplace",
                            side_effect=install_replacement_before_quarantine,
                        )
                    )
                else:
                    stack.enter_context(
                        mock.patch.object(
                            render_nomad_configs.os,
                            "unlink",
                            side_effect=install_replacement_before_unlink,
                        )
                    )
                removed = render_nomad_configs.remove_exact_publication(
                    directory,
                    target.name,
                    created,
                )
            os.close(directory)

            self.assertTrue(raced)
            self.assertFalse(removed)
            self.assertEqual(target.read_bytes(), b"replacement")
            self.assertEqual(held.read_bytes(), b"owned")

    def test_private_workspace_cleanup_race_never_deletes_replacement_directory(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            workspace = root / "workspace"
            held = root / "owned-held"
            workspace.mkdir(mode=0o700)
            raced = False
            real_rmdir = os.rmdir

            def install_replacement_before_rmdir(path, *args, **kwargs):
                nonlocal raced
                if Path(path) == workspace and not raced:
                    raced = True
                    workspace.rename(held)
                    workspace.mkdir(mode=0o700)
                return real_rmdir(path, *args, **kwargs)

            with ExitStack() as stack:
                stack.enter_context(
                    mock.patch.object(
                        validate_nats_config.tempfile,
                        "mkdtemp",
                        return_value=str(workspace),
                    )
                )
                if hasattr(validate_nats_config, "_rename_noreplace"):
                    real_rename = validate_nats_config._rename_noreplace

                    def install_replacement_before_quarantine(
                        parent: int,
                        source_name: str,
                        quarantine_name: str,
                    ) -> None:
                        nonlocal raced
                        if source_name == workspace.name and not raced:
                            raced = True
                            workspace.rename(held)
                            workspace.mkdir(mode=0o700)
                        real_rename(parent, source_name, quarantine_name)

                    stack.enter_context(
                        mock.patch.object(
                            validate_nats_config,
                            "_rename_noreplace",
                            side_effect=install_replacement_before_quarantine,
                        )
                    )
                else:
                    stack.enter_context(
                        mock.patch.object(
                            validate_nats_config.os,
                            "rmdir",
                            side_effect=install_replacement_before_rmdir,
                        )
                    )
                with validate_nats_config._private_workspace("unused-"):
                    pass

            self.assertTrue(raced)
            self.assertTrue(workspace.is_dir())
            self.assertTrue(held.is_dir())

    def test_supervised_cleanup_preserves_pending_timeout_and_attempts_all(self) -> None:
        class Probe:
            def __init__(self, event: str, events: list[str], failing: str) -> None:
                self.event = event
                self.events = events
                self.failing = failing

            def write(self, _content: bytes) -> None:
                return None

            def seek(self, _offset: int) -> None:
                return None

            def close(self) -> None:
                self.events.append(self.event)
                if self.event == self.failing:
                    raise OSError(f"{self.event} cleanup failed")

        class Selector(Probe):
            def register(self, *_args) -> None:
                return None

            def get_map(self):
                return {}

        class Process:
            def __init__(self, events: list[str], failing: str) -> None:
                self.stdout = Probe("stdout", events, failing)
                self.stderr = Probe("stderr", events, failing)
                self.pid = 991
                self.returncode = -15

            def poll(self):
                return None

        for module, finalizers in (
            (
                validate_nats_config,
                ("selector", "stdout", "stderr", "verify", "boundary"),
            ),
            (
                render_nomad_configs,
                ("selector", "stdin", "stdout", "stderr", "verify", "boundary"),
            ),
        ):
            for failing in finalizers:
                with self.subTest(module=module.__name__, failing=failing):
                    events: list[str] = []
                    verify_calls = 0
                    boundary_calls = 0

                    class Executable:
                        name = "validator"

                        def verify(self) -> None:
                            nonlocal verify_calls
                            verify_calls += 1
                            if verify_calls > 1:
                                events.append("verify")
                                if failing == "verify":
                                    raise OSError("verify cleanup failed")

                    def boundary() -> None:
                        nonlocal boundary_calls
                        boundary_calls += 1
                        minimum = 2 if module is validate_nats_config else 1
                        if boundary_calls >= minimum:
                            events.append("boundary")
                            if failing == "boundary":
                                raise OSError("boundary cleanup failed")

                    selector = Selector("selector", events, failing)
                    process = Process(events, failing)
                    with ExitStack() as stack:
                        stack.enter_context(
                            mock.patch.object(
                                module.selectors,
                                "DefaultSelector",
                                return_value=selector,
                            )
                        )
                        stack.enter_context(
                            mock.patch.object(
                                module.time,
                                "monotonic",
                                side_effect=(0.0, 0.0, 2.0),
                            )
                        )
                        if module is validate_nats_config:
                            stack.enter_context(
                                mock.patch.object(
                                    module,
                                    "_popen_bound",
                                    return_value=process,
                                )
                            )
                            stack.enter_context(
                                mock.patch.object(
                                    module,
                                    "_terminate_process_group",
                                    return_value=True,
                                )
                            )
                            invoke = lambda: module._run_supervised(
                                Executable(),
                                (),
                                environment={},
                                workspace=Path(tempfile.gettempdir()),
                                boundary=boundary,
                                deadline=1.0,
                            )
                        else:
                            stack.enter_context(
                                mock.patch.object(
                                    module.tempfile,
                                    "TemporaryFile",
                                    return_value=Probe("stdin", events, failing),
                                )
                            )
                            stack.enter_context(
                                mock.patch.object(
                                    module,
                                    "popen_bound",
                                    return_value=process,
                                )
                            )
                            stack.enter_context(
                                mock.patch.object(
                                    module,
                                    "terminate_process_group",
                                    return_value=True,
                                )
                            )
                            invoke = lambda: module.run_supervised(
                                Executable(),
                                (),
                                b"",
                                boundary,
                                deadline=1.0,
                            )
                        with self.assertRaises(BaseException) as raised:
                            invoke()
                    self.assertIsInstance(raised.exception, RuntimeError)
                    self.assertIn("timed out", str(raised.exception))
                    self.assertEqual(events, list(finalizers))

    def test_supervised_termination_failure_preserves_primary_and_finalizers(
        self,
    ) -> None:
        """A failed process-group cleanup cannot replace an established error."""

        class Probe:
            def __init__(self, event: str, events: list[str]) -> None:
                self.event = event
                self.events = events

            def write(self, _content: bytes) -> None:
                return None

            def seek(self, _offset: int) -> None:
                return None

            def close(self) -> None:
                self.events.append(self.event)

        class Process:
            def __init__(self, events: list[str]) -> None:
                self.stdout = Probe("stdout", events)
                self.stderr = Probe("stderr", events)
                self.pid = 991
                self.returncode = -15

            def poll(self):
                return None

        for module, finalizers in (
            (
                validate_nats_config,
                ("selector", "stdout", "stderr", "verify", "boundary"),
            ),
            (
                render_nomad_configs,
                ("selector", "stdin", "stdout", "stderr", "verify", "boundary"),
            ),
        ):
            for primary in ("pending", "active"):
                with self.subTest(module=module.__name__, primary=primary):
                    events: list[str] = []

                    class Selector(Probe):
                        def register(self, *_args) -> None:
                            return None

                        def get_map(self):
                            return {}

                        def select(self, _timeout: float):
                            if primary == "active":
                                raise RuntimeError("active primary")
                            return []

                    class Executable:
                        name = "validator"

                        def verify(self) -> None:
                            events.append("verify")

                    def boundary() -> None:
                        events.append("boundary")

                    selector = Selector("selector", events)
                    process = Process(events)
                    with ExitStack() as stack:
                        stack.enter_context(
                            mock.patch.object(
                                module.selectors,
                                "DefaultSelector",
                                return_value=selector,
                            )
                        )
                        stack.enter_context(
                            mock.patch.object(
                                module.time,
                                "monotonic",
                                side_effect=(0.0, 0.0, 2.0)
                                if primary == "pending"
                                else (0.0, 0.0, 0.0),
                            )
                        )
                        terminate_name = (
                            "_terminate_process_group"
                            if module is validate_nats_config
                            else "terminate_process_group"
                        )
                        terminator = stack.enter_context(
                            mock.patch.object(
                                module,
                                terminate_name,
                                side_effect=PermissionError("termination denied"),
                            )
                        )
                        if module is validate_nats_config:
                            stack.enter_context(
                                mock.patch.object(
                                    module,
                                    "_popen_bound",
                                    return_value=process,
                                )
                            )
                            invoke = lambda: module._run_supervised(
                                Executable(),
                                (),
                                environment={},
                                workspace=Path(tempfile.gettempdir()),
                                boundary=boundary,
                                deadline=1.0,
                            )
                        else:
                            stack.enter_context(
                                mock.patch.object(
                                    module.tempfile,
                                    "TemporaryFile",
                                    return_value=Probe("stdin", events),
                                )
                            )
                            stack.enter_context(
                                mock.patch.object(
                                    module,
                                    "popen_bound",
                                    return_value=process,
                                )
                            )
                            invoke = lambda: module.run_supervised(
                                Executable(), (), b"", boundary, deadline=1.0
                            )
                        with self.assertRaises(RuntimeError) as raised:
                            invoke()
                    expected = "timed out" if primary == "pending" else "active primary"
                    self.assertIn(expected, str(raised.exception))
                    self.assertEqual(events[-len(finalizers) :], list(finalizers))
                    terminator.assert_called_once_with(process)

    def test_nomad_reader_rejects_mutation_after_terminal_fstat(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "client.hcl"
            source.write_bytes(b"alpha")
            source_inode = source.stat().st_ino
            directory = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            real_fstat = render_nomad_configs.os.fstat
            observations = 0
            mutated = False

            def mutate_after_terminal_fstat(descriptor: int):
                nonlocal observations, mutated
                observed = real_fstat(descriptor)
                if stat.S_ISREG(observed.st_mode) and observed.st_ino == source_inode:
                    observations += 1
                    if observations == 2:
                        source.write_bytes(b"bravo")
                        mutated = True
                return observed

            try:
                with (
                    mock.patch.object(
                        render_nomad_configs.os,
                        "fstat",
                        side_effect=mutate_after_terminal_fstat,
                    ),
                    self.assertRaisesRegex(RuntimeError, "changed"),
                ):
                    render_nomad_configs.read_bound_regular(
                        directory,
                        source.name,
                    )
            finally:
                os.close(directory)
            self.assertTrue(mutated)

    def test_nomad_run_revalidates_retained_sources_after_publication(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            output = root / "output"
            source.mkdir()
            output.mkdir(mode=0o700)
            output.chmod(0o700)
            client = source / "client.hcl"
            server = source / "server.hcl"
            client_content = b'servers = ["${NOMAD_SERVER_IP}:4647"]\n'
            server_content = (
                b'advertise {\n'
                b'  http = "${NOMAD_ADVERTISE_ADDR}:4646"\n'
                b'  rpc  = "${NOMAD_ADVERTISE_ADDR}:4647"\n'
                b'  serf = "${NOMAD_ADVERTISE_ADDR}:4648"\n'
                b'}\nclient_addr = "${NOMAD_ADVERTISE_ADDR}"\n'
            )
            client.write_bytes(client_content)
            server.write_bytes(server_content)
            output_state = output.stat()
            arguments = mock.Mock(source_dir=str(source), output_dir=str(output))
            envsubst = mock.Mock(name="envsubst")
            envsubst.name = "envsubst"
            parser = mock.Mock(name="parser")
            parser.name = "hclfmt"
            real_write = render_nomad_configs.write_new_regular
            mutated = False

            def substitute(_executable, _arguments, content, _boundary, **_kwargs):
                rendered = content.replace(
                    b"${NOMAD_SERVER_IP}", b"192.0.2.10"
                ).replace(
                    b"${NOMAD_ADVERTISE_ADDR}", b"192.0.2.11"
                )
                return render_nomad_configs.CommandResult(0, rendered, b"")

            def publish_then_mutate(directory: int, name: str, content: bytes):
                nonlocal mutated
                identity = real_write(directory, name, content)
                if not mutated:
                    client.write_bytes(client_content.replace(b"4647", b"4648"))
                    mutated = True
                return identity

            with (
                mock.patch.object(
                    render_nomad_configs,
                    "parse_arguments",
                    return_value=arguments,
                ),
                mock.patch.object(
                    render_nomad_configs,
                    "bind_executable",
                    return_value=envsubst,
                ),
                mock.patch.object(
                    render_nomad_configs,
                    "select_parser",
                    return_value=render_nomad_configs.BoundCommand(parser, ()),
                ),
                mock.patch.object(
                    render_nomad_configs,
                    "run_supervised",
                    side_effect=substitute,
                ),
                mock.patch.object(render_nomad_configs, "validate_rendered"),
                mock.patch.object(
                    render_nomad_configs,
                    "write_new_regular",
                    side_effect=publish_then_mutate,
                ),
                mock.patch.dict(
                    os.environ,
                    {
                        "NOMAD_SERVER_IP": "192.0.2.10",
                        "NOMAD_ADVERTISE_ADDR": "192.0.2.11",
                        "NOMAD_RENDER_APPROVED_DIR": str(output),
                        "NOMAD_RENDER_APPROVED_ID": (
                            f"{output_state.st_dev}:{output_state.st_ino}"
                        ),
                    },
                ),
                self.assertRaisesRegex(RuntimeError, "source changed"),
            ):
                render_nomad_configs.run()

            self.assertTrue(mutated)
            self.assertEqual(list(output.iterdir()), [])

    def test_bound_executable_close_attempts_all_cleanup_steps(self) -> None:
        for module in (render_nomad_configs, validate_nats_config):
            for primary in (False, True):
                with self.subTest(module=module.__name__, primary=primary):
                    events: list[str] = []

                    class Interpreter:
                        def close(self) -> None:
                            events.append("interpreter")
                            raise OSError("interpreter cleanup failed")

                    bound = module.BoundExecutable(
                        name="cleanup-probe",
                        selected_path="/unused",
                        snapshot_directory="/unused",
                        directory_descriptor=91,
                        snapshot_name="executable",
                        snapshot_state=os.stat_result((0,) * 10),
                        directory_state=os.stat_result((0,) * 10),
                        digest=b"",
                        interpreter=Interpreter(),
                    )

                    def fail_snapshot(*_args) -> None:
                        events.append("snapshot")
                        raise OSError("snapshot cleanup failed")

                    def fail_close(descriptor: int) -> None:
                        self.assertEqual(descriptor, 91)
                        events.append("directory")
                        raise OSError("directory cleanup failed")

                    def invoke() -> None:
                        if primary:
                            try:
                                raise RuntimeError("primary operation failed")
                            finally:
                                bound.close()
                        bound.close()

                    expected = "primary operation failed" if primary else "snapshot cleanup failed"
                    with (
                        mock.patch.object(
                            module,
                            "cleanup_private_snapshot"
                            if module is render_nomad_configs
                            else "_cleanup_private_snapshot",
                            side_effect=fail_snapshot,
                        ),
                        mock.patch.object(module.os, "close", side_effect=fail_close),
                        self.assertRaisesRegex((RuntimeError, OSError), expected),
                    ):
                        invoke()
                    self.assertEqual(events, ["snapshot", "directory", "interpreter"])

    def test_private_workspace_cleanup_preserves_primary_and_attempts_all(self) -> None:
        for primary in (False, True):
            with self.subTest(primary=primary), tempfile.TemporaryDirectory() as tmp:
                workspace = Path(tmp) / "workspace"
                workspace.mkdir(mode=0o700)
                events: list[str] = []
                real_close = os.close

                def fail_remove(*_args, **_kwargs) -> None:
                    events.append("remove")
                    raise OSError("workspace removal failed")

                def fail_close(descriptor: int) -> None:
                    events.append("close")
                    real_close(descriptor)
                    raise OSError("workspace close failed")

                def invoke() -> None:
                    with validate_nats_config._private_workspace("unused-"):
                        if primary:
                            raise RuntimeError("workspace primary failed")

                expected = (
                    "workspace primary failed"
                    if primary
                    else "workspace removal failed"
                )
                with (
                    mock.patch.object(
                        validate_nats_config.tempfile,
                        "mkdtemp",
                        return_value=str(workspace),
                    ),
                    mock.patch.object(
                        validate_nats_config.os,
                        "rmdir",
                        side_effect=fail_remove,
                    ),
                    mock.patch.object(
                        validate_nats_config.os,
                        "close",
                        side_effect=fail_close,
                    ),
                    self.assertRaisesRegex((RuntimeError, OSError), expected),
                ):
                    invoke()
                self.assertEqual(events, ["remove", "close", "close", "close"])

    def test_bound_config_cleanup_preserves_primary_and_attempts_all(self) -> None:
        for primary in (False, True):
            with self.subTest(primary=primary), tempfile.TemporaryDirectory() as tmp:
                workspace = Path(tmp) / "workspace"
                workspace.mkdir(mode=0o700)
                manager = validate_nats_config._bound_config_input(
                    workspace,
                    b"port = 4222\n",
                    "cleanup probe",
                )
                bound = manager.__enter__()
                events: list[str] = []
                real_close = os.close

                def fail_bound_close() -> None:
                    events.append("bound")
                    raise OSError("bound cleanup failed")

                def fail_directory_close(descriptor: int) -> None:
                    events.append("directory")
                    real_close(descriptor)
                    raise OSError("directory cleanup failed")

                def finish() -> None:
                    if primary:
                        try:
                            raise RuntimeError("config primary failed")
                        except RuntimeError:
                            if not manager.__exit__(*sys.exc_info()):
                                raise
                    else:
                        manager.__exit__(None, None, None)

                expected = "config primary failed" if primary else "bound cleanup failed"
                try:
                    with (
                        mock.patch.object(
                            bound,
                            "close",
                            side_effect=fail_bound_close,
                        ),
                        mock.patch.object(
                            validate_nats_config.os,
                            "close",
                            side_effect=fail_directory_close,
                        ),
                        self.assertRaisesRegex((RuntimeError, OSError), expected),
                    ):
                        finish()
                finally:
                    real_close(bound.descriptor)
                self.assertEqual(events, ["bound", "directory"])

    def test_certificate_cleanup_preserves_primary_and_attempts_all(self) -> None:
        events: list[str] = []
        executable = mock.Mock()

        def fail_close(descriptor: int) -> None:
            events.append(f"descriptor:{descriptor}")
            raise OSError(f"descriptor {descriptor} cleanup failed")

        def fail_executable_close() -> None:
            events.append("executable")
            raise OSError("executable cleanup failed")

        executable.close.side_effect = fail_executable_close
        with (
            mock.patch.object(
                validate_nats_config,
                "_bind_executable",
                return_value=executable,
            ),
            mock.patch.object(
                validate_nats_config,
                "_verify_private_directory",
            ),
            mock.patch.object(
                validate_nats_config,
                "_new_anonymous_file",
                side_effect=(91, 92),
            ),
            mock.patch.object(
                validate_nats_config,
                "_run_supervised",
                side_effect=RuntimeError("certificate primary failed"),
            ),
            mock.patch.object(
                validate_nats_config.os,
                "close",
                side_effect=fail_close,
            ),
            self.assertRaisesRegex(RuntimeError, "certificate primary failed"),
        ):
            validate_nats_config._generate_certificates(
                Path("/unused"),
                {"PATH": os.defpath},
                workspace_descriptor=90,
            )
        self.assertEqual(events, ["descriptor:91", "descriptor:92", "executable"])

    def test_parser_verification_cleanup_preserves_primary_and_attempts_all(self) -> None:
        class PrimaryFailure(BaseException):
            pass

        events: list[str] = []
        executable = mock.Mock()

        def fail_close(descriptor: int) -> None:
            self.assertEqual(descriptor, 91)
            events.append("workspace")
            raise OSError("workspace cleanup failed")

        def fail_executable_close() -> None:
            events.append("executable")
            raise OSError("executable cleanup failed")

        executable.close.side_effect = fail_executable_close
        with (
            mock.patch.object(
                validate_nats_config,
                "_bind_executable",
                return_value=executable,
            ),
            mock.patch.object(validate_nats_config.os, "open", return_value=91),
            mock.patch.object(
                validate_nats_config.os,
                "close",
                side_effect=fail_close,
            ),
            mock.patch.object(
                validate_nats_config,
                "_verify_private_directory",
            ),
            mock.patch.object(
                validate_nats_config,
                "_run_supervised",
                side_effect=PrimaryFailure("parser primary failed"),
            ),
            self.assertRaisesRegex(PrimaryFailure, "parser primary failed"),
        ):
            validate_nats_config._verify_parser(
                Path("/unused"),
                Path("/unused-workspace"),
                {},
            )
        self.assertEqual(events, ["workspace", "executable"])

    def test_nomad_run_cleanup_preserves_primary_and_attempts_all(self) -> None:
        class PrimaryFailure(BaseException):
            pass

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source"
            output = root / "output"
            source.mkdir()
            output.mkdir()
            source.chmod(0o700)
            output.chmod(0o700)
            output_state = output.stat()
            arguments = mock.Mock(source_dir=str(source), output_dir=str(output))
            envsubst = mock.Mock()
            parser_executable = mock.Mock()
            parser_command = render_nomad_configs.BoundCommand(
                parser_executable,
                (),
            )
            events: list[str] = []
            real_close = os.close

            def fail_descriptor_close(descriptor: int) -> None:
                events.append("descriptor")
                real_close(descriptor)
                raise OSError("descriptor cleanup failed")

            def fail_parser_close() -> None:
                events.append("parser")
                raise OSError("parser cleanup failed")

            def fail_envsubst_close() -> None:
                events.append("envsubst")
                raise OSError("envsubst cleanup failed")

            close_patcher = mock.patch.object(
                render_nomad_configs.os,
                "close",
                side_effect=fail_descriptor_close,
            )

            def fail_render(*_args, **_kwargs):
                close_patcher.start()
                raise PrimaryFailure("render primary failed")

            parser_executable.close.side_effect = fail_parser_close
            envsubst.close.side_effect = fail_envsubst_close
            try:
                with (
                    mock.patch.object(
                        render_nomad_configs,
                        "parse_arguments",
                        return_value=arguments,
                    ),
                    mock.patch.object(
                        render_nomad_configs,
                        "bind_executable",
                        return_value=envsubst,
                    ),
                    mock.patch.object(
                        render_nomad_configs,
                        "select_parser",
                        return_value=parser_command,
                    ),
                    mock.patch.object(
                        render_nomad_configs,
                        "render_sources",
                        side_effect=fail_render,
                    ),
                    mock.patch.dict(
                        os.environ,
                        {
                            "NOMAD_SERVER_IP": "192.0.2.10",
                            "NOMAD_ADVERTISE_ADDR": "192.0.2.11",
                            "NOMAD_RENDER_APPROVED_DIR": str(output),
                            "NOMAD_RENDER_APPROVED_ID": (
                                f"{output_state.st_dev}:{output_state.st_ino}"
                            ),
                        },
                    ),
                    self.assertRaisesRegex(PrimaryFailure, "render primary failed"),
                ):
                    render_nomad_configs.run()
            finally:
                close_patcher.stop()
            self.assertEqual(
                events,
                ["descriptor", "descriptor", "descriptor", "parser", "envsubst"],
            )

    def test_nats_executable_verification_caps_a_growing_snapshot(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            snapshot = root / "executable"
            initial = b"12345678"
            snapshot.write_bytes(initial)
            snapshot.chmod(0o500)
            directory = os.open(
                root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            root.chmod(0o500)
            executable = validate_nats_config.BoundExecutable(
                name="nats-server",
                selected_path=str(snapshot),
                snapshot_directory=str(root),
                directory_descriptor=directory,
                snapshot_name=snapshot.name,
                snapshot_state=snapshot.stat(),
                directory_state=os.fstat(directory),
                digest=hashlib.sha256(initial).digest(),
            )
            real_read = validate_nats_config.os.read
            grew = False

            def growing_read(descriptor: int, size: int) -> bytes:
                nonlocal grew
                if not grew and os.fstat(descriptor).st_ino == snapshot.stat().st_ino:
                    grew = True
                    snapshot.chmod(0o700)
                    with snapshot.open("ab") as stream:
                        stream.write(b"9")
                    snapshot.chmod(0o500)
                return real_read(descriptor, size)

            try:
                with (
                    mock.patch.object(
                        validate_nats_config,
                        "MAX_PARSER_BINARY_BYTES",
                        len(initial),
                    ),
                    mock.patch.object(
                        validate_nats_config.os,
                        "read",
                        side_effect=growing_read,
                    ),
                    self.assertRaisesRegex(RuntimeError, "size limit"),
                ):
                    executable.verify()
            finally:
                executable.close()

    def test_nats_reader_rejects_hardlinked_config(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "source.conf"
            linked = root / "linked.conf"
            source.write_text("port = 4222\n", encoding="utf-8")
            os.link(source, linked)
            with self.assertRaisesRegex(
                validate_nats_config.ConfigStructureError,
                "singly linked",
            ):
                validate_nats_config._read_config(linked)

    def test_nats_reader_rejects_post_open_name_replacement(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            target = root / "server.conf"
            displaced = root / "server.bound"
            target.write_text("port = 4222\n", encoding="utf-8")
            real_read = validate_nats_config.os.read
            swapped = False

            def racing_read(descriptor: int, size: int) -> bytes:
                nonlocal swapped
                if not swapped:
                    swapped = True
                    target.rename(displaced)
                    target.write_text("port = 4333\n", encoding="utf-8")
                return real_read(descriptor, size)

            with (
                mock.patch.object(
                    validate_nats_config.os,
                    "read",
                    side_effect=racing_read,
                ),
                self.assertRaisesRegex(
                    validate_nats_config.ConfigStructureError,
                    "changed while it was read",
                ),
            ):
                validate_nats_config._read_config(target)

    def test_nomad_reader_rejects_source_above_explicit_byte_ceiling(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source = root / "client.hcl"
            limit = getattr(
                render_nomad_configs,
                "MAX_NOMAD_CONFIG_BYTES",
                1024 * 1024,
            )
            source.write_bytes(b"x" * (limit + 1))
            directory = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            try:
                with self.assertRaisesRegex(RuntimeError, "byte limit"):
                    render_nomad_configs.read_bound_regular(
                        directory,
                        source.name,
                        max_bytes=limit,
                    )
            finally:
                os.close(directory)

    def test_nomad_pipeline_threads_one_absolute_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "client.hcl").write_bytes(
                b'servers = ["${NOMAD_SERVER_IP}:4647"]\n'
            )
            (root / "server.hcl").write_bytes(
                b'advertise {\n'
                b'  http = "${NOMAD_ADVERTISE_ADDR}:4646"\n'
                b'  rpc  = "${NOMAD_ADVERTISE_ADDR}:4647"\n'
                b'  serf = "${NOMAD_ADVERTISE_ADDR}:4648"\n'
                b'}\nclient_addr = "${NOMAD_ADVERTISE_ADDR}"\n'
            )
            directory = os.open(root, os.O_RDONLY | getattr(os, "O_DIRECTORY", 0))
            executable = mock.MagicMock()
            executable.name = "envsubst"
            deadline = time.monotonic() + 30
            observed: list[float | None] = []

            def supervised(_executable, _arguments, content, _boundary, **kwargs):
                observed.append(kwargs.get("deadline"))
                if len(observed) <= 2:
                    output = content.replace(
                        b"${NOMAD_SERVER_IP}", b"192.0.2.10"
                    ).replace(
                        b"${NOMAD_ADVERTISE_ADDR}", b"192.0.2.11"
                    )
                else:
                    output = b""
                return render_nomad_configs.CommandResult(0, output, b"")

            try:
                with mock.patch.object(
                    render_nomad_configs,
                    "run_supervised",
                    side_effect=supervised,
                ):
                    rendered, _, _ = render_nomad_configs.render_sources(
                        directory,
                        {
                            b"${NOMAD_SERVER_IP}": b"192.0.2.10",
                            b"${NOMAD_ADVERTISE_ADDR}": b"192.0.2.11",
                        },
                        executable,
                        lambda: None,
                        deadline=deadline,
                    )
                    render_nomad_configs.validate_rendered(
                        render_nomad_configs.BoundCommand(executable, ()),
                        rendered,
                        lambda: None,
                        deadline=deadline,
                    )
            finally:
                os.close(directory)
            self.assertEqual(observed, [deadline, deadline, deadline, deadline])

    def test_expired_nomad_deadline_stops_before_spawn(self) -> None:
        executable = mock.MagicMock()
        executable.name = "envsubst"
        with (
            mock.patch.object(
                render_nomad_configs,
                "popen_bound",
                side_effect=AssertionError("spawn reached"),
            ),
            self.assertRaisesRegex(RuntimeError, "deadline"),
        ):
            render_nomad_configs.run_supervised(
                executable,
                (),
                b"",
                lambda: None,
                deadline=time.monotonic() - 1,
            )

    def test_nomad_deadline_crossed_during_verify_stops_before_spawn(self) -> None:
        executable = mock.MagicMock()
        executable.name = "envsubst"
        with (
            mock.patch.object(
                render_nomad_configs.time,
                "monotonic",
                side_effect=(10.0, 12.0),
            ),
            mock.patch.object(
                render_nomad_configs,
                "popen_bound",
                side_effect=RuntimeError("spawn reached"),
            ) as spawn,
            self.assertRaisesRegex(RuntimeError, "deadline"),
        ):
            render_nomad_configs.run_supervised(
                executable,
                (),
                b"",
                lambda: None,
                deadline=11.0,
            )
        spawn.assert_not_called()

    def test_nomad_launch_rechecks_deadline_after_descriptor_verify(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            snapshot = root / "executable"
            content = b"nomad-validator"
            snapshot.write_bytes(content)
            snapshot.chmod(0o500)
            directory = os.open(
                root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            root.chmod(0o500)
            executable = render_nomad_configs.BoundExecutable(
                name="envsubst",
                selected_path=str(snapshot),
                snapshot_directory=str(root),
                directory_descriptor=directory,
                snapshot_name=snapshot.name,
                snapshot_state=snapshot.stat(),
                directory_state=os.fstat(directory),
                digest=hashlib.sha256(content).digest(),
            )
            clock = [10.0]

            def verification_crosses_deadline(*_args) -> None:
                clock[0] = 12.0

            try:
                with (
                    mock.patch.object(render_nomad_configs.sys, "platform", "linux"),
                    mock.patch.object(
                        render_nomad_configs,
                        "verify_open_executable",
                        side_effect=verification_crosses_deadline,
                    ),
                    mock.patch.object(
                        render_nomad_configs.time,
                        "monotonic",
                        side_effect=lambda: clock[0],
                    ),
                    mock.patch.object(
                        render_nomad_configs.subprocess,
                        "Popen",
                        side_effect=RuntimeError("spawn reached"),
                    ) as spawn,
                    self.assertRaisesRegex(RuntimeError, "deadline"),
                ):
                    render_nomad_configs.popen_bound(
                        executable,
                        (),
                        deadline=11.0,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        start_new_session=True,
                    )
                spawn.assert_not_called()
            finally:
                executable.close()

    def test_nats_canaries_use_bound_bytes_and_one_absolute_deadline(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            workspace = Path(tmp)
            workspace.chmod(0o700)
            executable = validate_nats_config.BoundExecutable(
                name="nats-server",
                selected_path="/bound/nats-server",
                snapshot_directory="",
                directory_descriptor=-1,
                snapshot_name="",
                snapshot_state=os.stat_result((0,) * 10),
                directory_state=os.stat_result((0,) * 10),
                digest=b"",
            )
            deadlines: list[float | None] = []
            observed_inputs: list[bytes] = []

            def supervised(_executable, arguments, **kwargs):
                deadlines.append(kwargs.get("deadline"))
                if tuple(arguments) == ("--version",):
                    return validate_nats_config.CommandResult(
                        0, "nats-server: v2.10.22\n", ""
                    )
                config_path = str(arguments[-1])
                self.assertRegex(config_path, r"^/proc/self/fd/[0-9]+$")
                descriptor = int(config_path.rsplit("/", 1)[1])
                self.assertIn(descriptor, kwargs.get("pass_fds", ()))
                body = os.pread(descriptor, 4096, 0)
                observed_inputs.append(body)
                return validate_nats_config.CommandResult(
                    1 if b"authorization = []" in body else 0,
                    "",
                    "",
                )

            with mock.patch.object(
                validate_nats_config,
                "_run_supervised",
                side_effect=supervised,
            ):
                error = validate_nats_config._verify_parser(
                    executable,
                    workspace,
                    validate_nats_config._controlled_environment(workspace),
                    lambda: None,
                )
            self.assertIsNone(error)
            self.assertEqual(
                observed_inputs,
                [b"authorization = []\n", b"port = 4222\n"],
            )
            self.assertEqual(len(deadlines), 3)
            self.assertIsNotNone(deadlines[0])
            self.assertEqual(deadlines, [deadlines[0]] * 3)

    def test_expired_nats_deadline_stops_before_spawn(self) -> None:
        executable = mock.MagicMock()
        executable.name = "nats-server"
        workspace = Path(tempfile.gettempdir())
        with (
            mock.patch.object(
                validate_nats_config,
                "_popen_bound",
                side_effect=AssertionError("spawn reached"),
            ),
            self.assertRaisesRegex(RuntimeError, "deadline"),
        ):
            validate_nats_config._run_supervised(
                executable,
                ("--version",),
                environment={},
                workspace=workspace,
                boundary=lambda: None,
                deadline=time.monotonic() - 1,
            )

    def test_nats_deadline_crossed_during_verify_stops_before_spawn(self) -> None:
        executable = mock.MagicMock()
        executable.name = "nats-server"
        workspace = Path(tempfile.gettempdir())
        with (
            mock.patch.object(
                validate_nats_config.time,
                "monotonic",
                side_effect=(10.0, 12.0),
            ),
            mock.patch.object(
                validate_nats_config,
                "_popen_bound",
                side_effect=RuntimeError("spawn reached"),
            ) as spawn,
            self.assertRaisesRegex(RuntimeError, "deadline"),
        ):
            validate_nats_config._run_supervised(
                executable,
                ("--version",),
                environment={},
                workspace=workspace,
                boundary=lambda: None,
                deadline=11.0,
            )
        spawn.assert_not_called()

    def test_nats_launch_rechecks_deadline_after_descriptor_verify(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            snapshot = root / "executable"
            content = b"nats-validator"
            snapshot.write_bytes(content)
            snapshot.chmod(0o500)
            directory = os.open(
                root,
                os.O_RDONLY | getattr(os, "O_DIRECTORY", 0),
            )
            root.chmod(0o500)
            executable = validate_nats_config.BoundExecutable(
                name="nats-server",
                selected_path=str(snapshot),
                snapshot_directory=str(root),
                directory_descriptor=directory,
                snapshot_name=snapshot.name,
                snapshot_state=snapshot.stat(),
                directory_state=os.fstat(directory),
                digest=hashlib.sha256(content).digest(),
            )
            clock = [10.0]

            def verification_crosses_deadline(*_args) -> None:
                clock[0] = 12.0

            try:
                with (
                    mock.patch.object(validate_nats_config.sys, "platform", "linux"),
                    mock.patch.object(
                        validate_nats_config,
                        "_verify_open_executable",
                        side_effect=verification_crosses_deadline,
                    ),
                    mock.patch.object(
                        validate_nats_config.time,
                        "monotonic",
                        side_effect=lambda: clock[0],
                    ),
                    mock.patch.object(
                        validate_nats_config.subprocess,
                        "Popen",
                        side_effect=RuntimeError("spawn reached"),
                    ) as spawn,
                    self.assertRaisesRegex(RuntimeError, "deadline"),
                ):
                    validate_nats_config._popen_bound(
                        executable,
                        ("--version",),
                        deadline=11.0,
                        stdin=subprocess.DEVNULL,
                        stdout=subprocess.PIPE,
                        stderr=subprocess.PIPE,
                        env={},
                        cwd=root,
                        start_new_session=True,
                    )
                spawn.assert_not_called()
            finally:
                executable.close()


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
            try:
                self.assertFalse(sentinel.exists())
                self.assertTrue(certificates["key_file"].is_file())
                self.assertTrue(certificates["cert_file"].is_file())
            finally:
                certificates.close()

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
