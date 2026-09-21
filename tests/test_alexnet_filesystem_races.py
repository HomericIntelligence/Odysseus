#!/usr/bin/env python3
"""Adversarial filesystem checks for AlexNet result publication."""

from __future__ import annotations

import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


ROOT = Path(__file__).resolve().parent.parent
HELPER = ROOT / "e2e" / "alexnet-collect-fs.py"


def load_helper():
    spec = importlib.util.spec_from_file_location("alexnet_result_fs", HELPER)
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load the AlexNet result filesystem helper")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def identity_text(path: Path) -> str:
    value = path.stat()
    return f"{value.st_dev}:{value.st_ino}"


def make_valid_host(root: Path, host: str = "node", run_id: str = "test-run") -> Path:
    path = root / host
    path.mkdir(mode=0o700)
    (path / "training.log").write_text(
        f"=== AlexNet Training on {host} ===\nRun ID:   {run_id}\n",
        encoding="utf-8",
    )
    weights = path / "alexnet_weights"
    weights.mkdir(mode=0o700)
    (weights / "weights.bin").write_bytes(b"weights\n")
    return path


class CollectionFilesystemRaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="alexnet-fs-race-")
        self.root = Path(self.temporary.name).resolve()
        self.helper = load_helper()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_directory_creation_fails_closed_without_trusted_boundary(self) -> None:
        parent = self.root / "parent"
        parent.mkdir(mode=0o700)
        parent_fd = os.open(parent, self.helper.DIRECTORY_FLAGS)
        try:
            with self.assertRaisesRegex(OSError, "trusted directory creation"):
                self.helper.create_private_directory_fd(parent_fd, "child")
        finally:
            os.close(parent_fd)
        self.assertFalse((parent / "child").exists())

    def test_cleanup_action_is_unavailable_and_retains_forensic_staging(self) -> None:
        parent = self.root / "parent"
        staging = parent / ".alexnet-collect.bound"
        data = staging / "data"
        receipts = staging / "receipts"
        receipts.mkdir(parents=True, mode=0o700)
        data.mkdir(mode=0o700)
        victim = data / "victim.txt"
        victim.write_bytes(b"retained forensic bytes\n")
        victim_state = victim.stat()

        parent_fd = os.open(parent, self.helper.DIRECTORY_FLAGS)
        staging_fd = os.open(staging, self.helper.DIRECTORY_FLAGS)
        try:
            with self.assertRaises(OSError):
                self.helper.main(
                    [
                        "cleanup",
                        str(parent_fd),
                        identity_text(parent),
                        staging.name,
                        identity_text(staging),
                        str(staging_fd),
                    ]
                )
        finally:
            os.close(staging_fd)
            os.close(parent_fd)

        retained = victim.stat()
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (victim_state.st_dev, victim_state.st_ino),
        )
        self.assertEqual(victim.read_bytes(), b"retained forensic bytes\n")

    def test_publish_copies_from_bound_source_without_rename(self) -> None:
        data = self.root / "data"
        central = self.root / "central"
        data.mkdir(mode=0o700)
        central.mkdir(mode=0o700)
        source = make_valid_host(data)
        source_state = source.stat()
        data_fd = os.open(data, self.helper.DIRECTORY_FLAGS)
        central_fd = os.open(central, self.helper.DIRECTORY_FLAGS)
        try:
            with mock.patch.object(
                self.helper.os,
                "rename",
                side_effect=AssertionError(
                    "publication must not rename a mutable pathname"
                ),
            ):
                try:
                    self.helper.publish_host(
                        data_fd,
                        central_fd,
                        "node",
                        identity_text(source),
                        "test-run",
                    )
                except OSError as error:
                    self.fail(f"bound result publication failed: {error}")
        finally:
            os.close(central_fd)
            os.close(data_fd)

        retained = source.stat()
        published = central / "node"
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (source_state.st_dev, source_state.st_ino),
        )
        self.assertNotEqual(published.stat().st_ino, source_state.st_ino)
        self.assertEqual(
            (published / "training.log").read_bytes(),
            (source / "training.log").read_bytes(),
        )

    def test_publish_rejects_source_replacement_without_reading_replacement(
        self,
    ) -> None:
        data = self.root / "data"
        central = self.root / "central"
        data.mkdir(mode=0o700)
        central.mkdir(mode=0o700)
        source = make_valid_host(data)
        held_source = self.root / "held-source"
        replacement = self.root / "source-replacement"
        replacement.mkdir(mode=0o700)
        sentinel = replacement / "sentinel.txt"
        sentinel.write_bytes(b"source victim\n")
        sentinel_state = sentinel.stat()
        real_copy_tree = self.helper.copy_tree

        def replace_source(source_fd: int, destination_fd: int) -> None:
            os.rename(source, held_source)
            os.rename(replacement, source)
            with mock.patch.object(self.helper, "copy_tree", real_copy_tree):
                real_copy_tree(source_fd, destination_fd)

        data_fd = os.open(data, self.helper.DIRECTORY_FLAGS)
        central_fd = os.open(central, self.helper.DIRECTORY_FLAGS)
        try:
            with mock.patch.object(
                self.helper, "copy_tree", side_effect=replace_source
            ):
                with self.assertRaises(OSError):
                    self.helper.publish_host(
                        data_fd,
                        central_fd,
                        "node",
                        identity_text(source),
                        "test-run",
                    )
        finally:
            os.close(central_fd)
            os.close(data_fd)

        replacement_sentinel = source / "sentinel.txt"
        retained = replacement_sentinel.stat()
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (sentinel_state.st_dev, sentinel_state.st_ino),
        )
        self.assertEqual(replacement_sentinel.read_bytes(), b"source victim\n")
        self.assertFalse((source / "training.log").exists())
        self.assertTrue((held_source / "training.log").is_file())

    def test_publish_rejects_destination_replacement_without_writing_replacement(
        self,
    ) -> None:
        data = self.root / "data"
        central = self.root / "central"
        data.mkdir(mode=0o700)
        central.mkdir(mode=0o700)
        source = make_valid_host(data)
        held_destination = self.root / "held-destination"
        replacement = self.root / "destination-replacement"
        replacement.mkdir(mode=0o700)
        sentinel = replacement / "sentinel.txt"
        sentinel.write_bytes(b"destination victim\n")
        sentinel_state = sentinel.stat()
        real_copy_tree = self.helper.copy_tree

        def replace_destination(source_fd: int, destination_fd: int) -> None:
            os.rename(central / "node", held_destination)
            os.rename(replacement, central / "node")
            with mock.patch.object(self.helper, "copy_tree", real_copy_tree):
                real_copy_tree(source_fd, destination_fd)

        data_fd = os.open(data, self.helper.DIRECTORY_FLAGS)
        central_fd = os.open(central, self.helper.DIRECTORY_FLAGS)
        try:
            with mock.patch.object(
                self.helper,
                "copy_tree",
                side_effect=replace_destination,
            ):
                with self.assertRaises(OSError):
                    self.helper.publish_host(
                        data_fd,
                        central_fd,
                        "node",
                        identity_text(source),
                        "test-run",
                    )
        finally:
            os.close(central_fd)
            os.close(data_fd)

        replacement_sentinel = central / "node" / "sentinel.txt"
        retained = replacement_sentinel.stat()
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (sentinel_state.st_dev, sentinel_state.st_ino),
        )
        self.assertEqual(replacement_sentinel.read_bytes(), b"destination victim\n")
        self.assertFalse((central / "node" / "training.log").exists())
        self.assertTrue((held_destination / "training.log").is_file())

    def test_create_central_preserves_atomic_publish_replacement(self) -> None:
        parent = self.root / "parent"
        parent.mkdir(mode=0o700)
        replacement = self.root / "central-replacement"
        replacement.mkdir(mode=0o700)
        sentinel = replacement / "sentinel.txt"
        sentinel.write_bytes(b"preserve central replacement\n")
        sentinel_state = sentinel.stat()
        parent_fd = os.open(parent, self.helper.DIRECTORY_FLAGS)
        real_publish = self.helper.rename_noreplace

        def swap_at_publish(*args, **kwargs) -> None:
            os.rename(replacement, parent / "central")
            real_publish(*args, **kwargs)

        try:
            with mock.patch.object(
                self.helper, "rename_noreplace", side_effect=swap_at_publish
            ):
                with self.assertRaises(OSError):
                    self.helper.create_central(
                        str(parent), identity_text(parent), parent_fd, "central"
                    )
        finally:
            os.close(parent_fd)

        retained = (parent / "central" / "sentinel.txt").stat()
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (sentinel_state.st_dev, sentinel_state.st_ino),
        )
        isolated = list(parent.glob(".alexnet-create.*"))
        self.assertEqual(len(isolated), 1)
        self.assertTrue((isolated[0] / "object").is_dir())

    def test_publish_host_preserves_atomic_publish_replacement(self) -> None:
        data = self.root / "data"
        central = self.root / "central"
        data.mkdir(mode=0o700)
        central.mkdir(mode=0o700)
        source = make_valid_host(data)
        replacement = self.root / "host-replacement"
        replacement.mkdir(mode=0o700)
        replacement_state = replacement.stat()
        data_fd = os.open(data, self.helper.DIRECTORY_FLAGS)
        central_fd = os.open(central, self.helper.DIRECTORY_FLAGS)
        real_publish = self.helper.rename_noreplace

        def swap_at_publish(*args, **kwargs) -> None:
            os.rename(replacement, central / "node")
            real_publish(*args, **kwargs)

        try:
            with mock.patch.object(
                self.helper, "rename_noreplace", side_effect=swap_at_publish
            ):
                with self.assertRaises(OSError):
                    self.helper.publish_host(
                        data_fd, central_fd, "node", identity_text(source), "test-run"
                    )
        finally:
            os.close(central_fd)
            os.close(data_fd)

        self.assertEqual(central.joinpath("node").stat().st_ino, replacement_state.st_ino)
        self.assertEqual(list((central / "node").iterdir()), [])
        isolated = list(central.glob(".alexnet-create.*"))
        self.assertEqual(len(isolated), 1)
        self.assertTrue((isolated[0] / "object").is_dir())

    def test_host_validation_rejects_wrong_mode_without_changing_it(self) -> None:
        data = self.root / "data"
        data.mkdir(mode=0o700)
        source = make_valid_host(data)
        source.chmod(0o770)
        source_fd = os.open(source, self.helper.DIRECTORY_FLAGS)
        try:
            with self.assertRaises(OSError):
                self.helper.validate_host(
                    source_fd,
                    identity_text(source),
                    "test-run",
                )
        finally:
            os.close(source_fd)

        self.assertEqual(source.stat().st_mode & 0o777, 0o770)

    def _run_transfer(
        self,
        data: Path,
        receipts: Path,
        source: Path,
        fake_bin: Path,
    ) -> subprocess.CompletedProcess[str]:
        data_fd = os.open(data, self.helper.DIRECTORY_FLAGS)
        receipts_fd = os.open(receipts, self.helper.DIRECTORY_FLAGS)
        try:
            environment = os.environ.copy()
            environment["PATH"] = f"{fake_bin}:/usr/bin:/bin"
            return subprocess.run(
                [
                    sys.executable,
                    "-I",
                    "-E",
                    str(HELPER),
                    "transfer-local",
                    str(data_fd),
                    "node",
                    identity_text(data / "node"),
                    str(receipts_fd),
                    "0.detail",
                    str(source),
                ],
                check=False,
                capture_output=True,
                text=True,
                close_fds=True,
                pass_fds=(data_fd, receipts_fd),
                env=environment,
            )
        finally:
            os.close(receipts_fd)
            os.close(data_fd)

    def test_transfer_executes_in_bound_directory_without_lexical_destination(
        self,
    ) -> None:
        data = self.root / "data"
        receipts = self.root / "receipts"
        source = self.root / "source"
        fake_bin = self.root / "bin"
        marker = self.root / "copy.marker"
        for path in (data, receipts, source, fake_bin):
            path.mkdir(mode=0o700)
        host = data / "node"
        host.mkdir(mode=0o700)
        fake_cp = fake_bin / "cp"
        fake_cp.write_text(
            "#!/bin/sh\n"
            'printf \'%s\\n\' "$(pwd -P)" > "$ALEXNET_COPY_MARKER"\n'
            'printf \'%s\\n\' "$*" >> "$ALEXNET_COPY_MARKER"\n',
            encoding="utf-8",
        )
        fake_cp.chmod(0o700)

        with mock.patch.dict(os.environ, {"ALEXNET_COPY_MARKER": str(marker)}):
            result = self._run_transfer(data, receipts, source, fake_bin)

        self.assertEqual(result.returncode, 0, result.stderr)
        lines = marker.read_text(encoding="utf-8").splitlines()
        self.assertEqual(Path(lines[0]).stat().st_ino, host.stat().st_ino)
        self.assertEqual(lines[1].split()[-1], ".")

    def test_transfer_receipt_refuses_symlink_without_changing_victim(self) -> None:
        data = self.root / "data"
        receipts = self.root / "receipts"
        source = self.root / "source"
        fake_bin = self.root / "bin"
        for path in (data, receipts, source, fake_bin):
            path.mkdir(mode=0o700)
        (data / "node").mkdir(mode=0o700)
        victim = self.root / "receipt-victim.txt"
        victim.write_bytes(b"preserve receipt victim\n")
        victim_state = victim.stat()
        (receipts / "0.detail").symlink_to(victim)
        fake_cp = fake_bin / "cp"
        fake_cp.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
        fake_cp.chmod(0o700)

        result = self._run_transfer(data, receipts, source, fake_bin)

        retained = victim.stat()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("transfer receipt", result.stderr)
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (victim_state.st_dev, victim_state.st_ino),
        )
        self.assertEqual(victim.read_bytes(), b"preserve receipt victim\n")

    def test_transfer_receipt_replacement_cannot_redirect_process_output(self) -> None:
        data = self.root / "data"
        receipts = self.root / "receipts"
        source = self.root / "source"
        fake_bin = self.root / "bin"
        for path in (data, receipts, source, fake_bin):
            path.mkdir(mode=0o700)
        (data / "node").mkdir(mode=0o700)
        victim = self.root / "receipt-race-victim.txt"
        victim.write_bytes(b"preserve raced receipt victim\n")
        victim_state = victim.stat()
        receipt = receipts / "0.detail"
        fake_cp = fake_bin / "cp"
        fake_cp.write_text(
            "#!/bin/sh\n"
            'rm -- "$ALEXNET_RECEIPT_PATH"\n'
            'ln -s -- "$ALEXNET_RECEIPT_VICTIM" "$ALEXNET_RECEIPT_PATH"\n'
            "printf '%s\\n' 'transfer output after receipt replacement'\n",
            encoding="utf-8",
        )
        fake_cp.chmod(0o700)

        with mock.patch.dict(
            os.environ,
            {
                "ALEXNET_RECEIPT_PATH": str(receipt),
                "ALEXNET_RECEIPT_VICTIM": str(victim),
            },
        ):
            result = self._run_transfer(data, receipts, source, fake_bin)

        retained = victim.stat()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(receipt.is_symlink())
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (victim_state.st_dev, victim_state.st_ino),
        )
        self.assertEqual(victim.read_bytes(), b"preserve raced receipt victim\n")


class TrainingFilesystemRaceTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="alexnet-train-fs-race-")
        self.root = Path(self.temporary.name).resolve()
        self.helper = load_helper()

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def test_failed_directory_validation_retains_created_object_without_rmdir(
        self,
    ) -> None:
        result = self.root / "runs" / "test-run" / "node"
        with (
            mock.patch.object(
                self.helper,
                "validate_private_directory",
                side_effect=OSError("controlled post-create validation failure"),
            ),
            mock.patch.object(
                self.helper.os,
                "rmdir",
                side_effect=AssertionError(
                    "failure handling must not remove a pathname"
                ),
            ),
        ):
            with self.assertRaises(OSError):
                self.helper.create_train_directory(str(result))

        self.assertFalse(result.exists())
        retained = list(result.parent.glob(".alexnet-create.*"))
        self.assertEqual(len(retained), 1)
        self.assertTrue(retained[0].is_dir())

    def test_create_train_directory_preserves_atomic_publish_replacement(self) -> None:
        result = self.root / "runs" / "test-run" / "node"
        result.parent.mkdir(parents=True, mode=0o700)
        replacement = self.root / "train-replacement"
        replacement.mkdir(mode=0o700)
        sentinel = replacement / "sentinel.txt"
        sentinel.write_bytes(b"preserve train replacement\n")
        sentinel_state = sentinel.stat()
        real_publish = self.helper.rename_noreplace

        def swap_at_publish(*args, **kwargs) -> None:
            os.rename(replacement, result)
            real_publish(*args, **kwargs)

        with mock.patch.object(
            self.helper, "rename_noreplace", side_effect=swap_at_publish
        ):
            with self.assertRaises(OSError):
                self.helper.create_train_directory(str(result))

        retained = (result / "sentinel.txt").stat()
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (sentinel_state.st_dev, sentinel_state.st_ino),
        )
        isolated = list(result.parent.glob(".alexnet-create.*"))
        self.assertEqual(len(isolated), 1)
        self.assertTrue((isolated[0] / "object").is_dir())

    def test_failed_header_write_retains_created_object_without_unlink(self) -> None:
        result = self.root / "result"
        result.mkdir(mode=0o700)
        victim = self.root / "header-victim.txt"
        victim.write_bytes(b"preserve header victim\n")
        victim_state = victim.stat()
        result_fd = os.open(result, self.helper.DIRECTORY_FLAGS)

        def fail_after_write(descriptor: int, payload: bytes) -> None:
            os.write(descriptor, payload[:1])
            raise OSError("controlled header write failure")

        try:
            with (
                mock.patch.object(
                    self.helper, "write_all", side_effect=fail_after_write
                ),
                mock.patch.object(
                    self.helper.os,
                    "unlink",
                    side_effect=AssertionError(
                        "failure handling must not unlink a pathname"
                    ),
                ),
            ):
                with self.assertRaises(OSError):
                    self.helper.publish_train_header(
                        result_fd,
                        identity_text(result),
                        "header payload",
                    )
        finally:
            os.close(result_fd)

        retained = victim.stat()
        self.assertTrue((result / "training.log").is_file())
        self.assertEqual(
            (retained.st_dev, retained.st_ino),
            (victim_state.st_dev, victim_state.st_ino),
        )
        self.assertEqual(victim.read_bytes(), b"preserve header victim\n")


if __name__ == "__main__":
    unittest.main(verbosity=2)
