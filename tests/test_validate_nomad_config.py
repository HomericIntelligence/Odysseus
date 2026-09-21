#!/usr/bin/env python3
"""Focused trust-boundary tests for the Nomad HCL validator."""

import importlib.util
import os
from pathlib import Path
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/validate_nomad_config.py"
SPEC = importlib.util.spec_from_file_location("validate_nomad_config_subject", SCRIPT)
validator = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(validator)


class RecordingParser:
    def __init__(self):
        self.contents = []

    def load(self, stream):
        self.contents.append(stream.read())
        return {}


class TestNomadValidatorBoundary(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(os.path.realpath(self.temporary.name)) / "repo"
        self.configs = self.root / "configs/nomad"
        self.configs.mkdir(parents=True)
        (self.configs / "client.hcl").write_text("client {}\n")
        (self.configs / "server.hcl").write_text("server {}\n")
        self.original_root = getattr(validator, "REPOSITORY_ROOT", None)
        validator.REPOSITORY_ROOT = self.root

    def tearDown(self):
        if self.original_root is None:
            delattr(validator, "REPOSITORY_ROOT")
        else:
            validator.REPOSITORY_ROOT = self.original_root
        self.temporary.cleanup()

    def test_default_inventory_is_anchored_outside_repository_cwd(self):
        outside = Path(self.temporary.name) / "outside-cwd"
        outside.mkdir()
        previous = Path.cwd()
        try:
            os.chdir(outside)
            paths = validator.canonical_paths()
            parser = RecordingParser()
            for path in paths:
                validator.validate(path, parser)
        finally:
            os.chdir(previous)

        self.assertEqual(
            paths,
            [
                self.configs / "client.hcl",
                self.configs / "server.hcl",
            ],
        )
        self.assertEqual(parser.contents, ["client {}\n", "server {}\n"])

    def test_off_root_and_symlink_inputs_fail_closed(self):
        parser = RecordingParser()
        outside = Path(self.temporary.name) / "outside.hcl"
        outside.write_text("outside {}\n")
        final_link = self.configs / "linked.hcl"
        final_link.symlink_to(outside)
        outside_directory = Path(self.temporary.name) / "outside-directory"
        outside_directory.mkdir()
        (outside_directory / "nested.hcl").write_text("nested {}\n")
        ancestor_link = self.root / "linked-configs"
        ancestor_link.symlink_to(outside_directory, target_is_directory=True)

        for path in (outside, final_link, ancestor_link / "nested.hcl"):
            with self.subTest(path=path), self.assertRaises(RuntimeError):
                validator.validate(path, parser)
        self.assertEqual(parser.contents, [])

    def test_parser_reads_bound_fd_and_name_swap_is_rejected(self):
        target = self.configs / "swap.hcl"
        original = self.configs / "swap.original"
        replacement = Path(self.temporary.name) / "replacement.hcl"
        target.write_text("bound original {}\n")
        replacement.write_text("foreign replacement {}\n")

        class SwapParser(RecordingParser):
            def load(inner_self, stream):
                target.rename(original)
                target.symlink_to(replacement)
                return super().load(stream)

        parser = SwapParser()
        with self.assertRaisesRegex(RuntimeError, "changed"):
            validator.validate(target, parser)
        self.assertEqual(parser.contents, ["bound original {}\n"])
        self.assertEqual(replacement.read_text(), "foreign replacement {}\n")

    def test_parent_directory_swap_during_parse_is_rejected(self):
        target = self.configs / "parent-swap.hcl"
        detached = self.root / "configs/nomad.detached"
        replacement = Path(self.temporary.name) / "replacement.hcl"
        target.write_text("bound original {}\n")
        replacement.write_text("invalid live replacement\n")

        class ParentSwapParser(RecordingParser):
            def load(inner_self, stream):
                self.configs.rename(detached)
                self.configs.mkdir()
                target.symlink_to(replacement)
                return super().load(stream)

        parser = ParentSwapParser()
        with self.assertRaisesRegex(RuntimeError, "directory.*changed"):
            validator.validate(target, parser)
        self.assertEqual(parser.contents, ["bound original {}\n"])
        self.assertTrue(target.is_symlink())
        self.assertEqual(replacement.read_text(), "invalid live replacement\n")

    def test_repository_root_symlink_is_rejected_before_read(self):
        original_root = self.root.with_name("repo-original")
        self.root.rename(original_root)
        foreign_root = Path(self.temporary.name) / "foreign-repo"
        foreign_config = foreign_root / "configs/nomad/client.hcl"
        foreign_config.parent.mkdir(parents=True)
        foreign_config.write_text("foreign {}\n")
        self.root.symlink_to(foreign_root, target_is_directory=True)

        parser = RecordingParser()
        with self.assertRaises(RuntimeError):
            validator.validate(self.root / "configs/nomad/client.hcl", parser)
        self.assertEqual(parser.contents, [])

    def test_hcl_size_ceiling_accepts_limit_and_rejects_limit_plus_one(self):
        exact = self.configs / "exact-limit.hcl"
        oversized = self.configs / "oversized.hcl"
        exact.write_bytes(b"x" * validator.MAX_NOMAD_HCL_BYTES)
        oversized.write_bytes(b"x" * (validator.MAX_NOMAD_HCL_BYTES + 1))

        exact_parser = RecordingParser()
        validator.validate(exact, exact_parser)
        self.assertEqual(
            len(exact_parser.contents[0].encode()),
            validator.MAX_NOMAD_HCL_BYTES,
        )

        oversized_parser = RecordingParser()
        with self.assertRaisesRegex(RuntimeError, "size ceiling"):
            validator.validate(oversized, oversized_parser)
        self.assertEqual(oversized_parser.contents, [])

    def test_hcl_growth_past_ceiling_during_parse_is_rejected(self):
        target = self.configs / "growing.hcl"
        target.write_text("client {}\n")

        class GrowingParser(RecordingParser):
            def load(inner_self, stream):
                contents = super().load(stream)
                target.write_bytes(b"x" * (validator.MAX_NOMAD_HCL_BYTES + 1))
                return contents

        with self.assertRaisesRegex(RuntimeError, "size ceiling"):
            validator.validate(target, GrowingParser())


if __name__ == "__main__":
    unittest.main()
