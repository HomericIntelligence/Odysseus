#!/usr/bin/env python3
"""Fail-closed syntax validation for canonical Nomad HCL2 configuration."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import stat
import sys
from typing import Protocol, TextIO


class HCL2Parser(Protocol):
    """The maintained python-hcl2 surface used by this validator."""

    def load(self, stream: TextIO) -> object: ...


REPOSITORY_ROOT = Path(__file__).resolve().parent.parent
MAX_NOMAD_HCL_BYTES = 1024 * 1024


def _required_flag(name: str) -> int:
    value = getattr(os, name, None)
    if not isinstance(value, int) or value == 0:
        raise RuntimeError(f"{name} is required for safe Nomad validation")
    return value


DIRECTORY_FLAGS = (
    os.O_RDONLY
    | _required_flag("O_DIRECTORY")
    | _required_flag("O_NOFOLLOW")
    | _required_flag("O_CLOEXEC")
)
FILE_FLAGS = (
    os.O_RDONLY
    | _required_flag("O_NOFOLLOW")
    | _required_flag("O_CLOEXEC")
    | _required_flag("O_NONBLOCK")
)


def load_parser() -> HCL2Parser:
    try:
        import hcl2
    except ImportError as error:
        raise RuntimeError(
            "python-hcl2 is required for fail-closed Nomad HCL validation"
        ) from error
    return hcl2


def _repository_relative(path: Path) -> tuple[Path, tuple[str, ...]]:
    root = Path(os.path.abspath(REPOSITORY_ROOT))
    candidate = path if path.is_absolute() else root / path
    absolute = Path(os.path.abspath(candidate))
    try:
        common = os.path.commonpath((os.fspath(root), os.fspath(absolute)))
    except ValueError as error:
        raise RuntimeError(
            f"Nomad HCL input is outside the repository: {path}"
        ) from error
    if common != os.fspath(root) or absolute == root:
        raise RuntimeError(f"Nomad HCL input is outside the repository: {path}")
    relative = absolute.relative_to(root)
    if not relative.parts or any(part in {"", ".", ".."} for part in relative.parts):
        raise RuntimeError(f"Nomad HCL input path is malformed: {path}")
    return absolute, relative.parts


def _directory_identity(metadata: os.stat_result) -> tuple[int, int]:
    return metadata.st_dev, metadata.st_ino


def _require_direct_directory(metadata: os.stat_result, path: Path) -> None:
    if not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid not in {0, os.geteuid()}:
        raise RuntimeError(
            f"Nomad directory is not an owner-bound non-symlink directory: {path}"
        )


class _BoundDirectoryChain:
    """Keep and verify every no-follow directory descriptor in one path."""

    def __init__(
        self,
        descriptors: list[int],
        names: list[str],
        paths: list[Path],
        identities: list[tuple[int, int]],
    ) -> None:
        self._descriptors = descriptors
        self._names = names
        self._paths = paths
        self._identities = identities

    @property
    def descriptor(self) -> int:
        return self._descriptors[-1]

    def verify(self) -> None:
        root_info = os.fstat(self._descriptors[0])
        _require_direct_directory(root_info, self._paths[0])
        if _directory_identity(root_info) != self._identities[0]:
            raise RuntimeError("Nomad directory chain changed during validation")
        for index, name in enumerate(self._names):
            named = os.stat(
                name,
                dir_fd=self._descriptors[index],
                follow_symlinks=False,
            )
            opened = os.fstat(self._descriptors[index + 1])
            path = self._paths[index + 1]
            _require_direct_directory(named, path)
            _require_direct_directory(opened, path)
            expected = self._identities[index + 1]
            if (
                _directory_identity(named) != expected
                or _directory_identity(opened) != expected
            ):
                raise RuntimeError("Nomad directory chain changed during validation")

    def close(self) -> None:
        for descriptor in reversed(self._descriptors):
            os.close(descriptor)
        self._descriptors.clear()


def _open_directory(parts: tuple[str, ...]) -> _BoundDirectoryChain:
    root = Path(os.path.abspath(REPOSITORY_ROOT))
    names = [*root.parts[1:], *parts]
    descriptors: list[int] = []
    paths = [Path(os.sep)]
    identities: list[tuple[int, int]] = []
    current_path = paths[0]
    try:
        descriptor = os.open(os.sep, DIRECTORY_FLAGS)
        descriptors.append(descriptor)
        root_info = os.fstat(descriptor)
        _require_direct_directory(root_info, current_path)
        identities.append(_directory_identity(root_info))
        for name in names:
            current_path /= name
            named = os.stat(
                name,
                dir_fd=descriptors[-1],
                follow_symlinks=False,
            )
            _require_direct_directory(named, current_path)
            descriptor = os.open(name, DIRECTORY_FLAGS, dir_fd=descriptors[-1])
            descriptors.append(descriptor)
            opened = os.fstat(descriptor)
            _require_direct_directory(opened, current_path)
            if _directory_identity(named) != _directory_identity(opened):
                raise RuntimeError("Nomad directory chain changed while opening")
            paths.append(current_path)
            identities.append(_directory_identity(opened))
        binding = _BoundDirectoryChain(descriptors, names, paths, identities)
        binding.verify()
        return binding
    except BaseException:
        for descriptor in reversed(descriptors):
            os.close(descriptor)
        raise


def canonical_paths() -> list[Path]:
    directory, parts = _repository_relative(Path("configs/nomad"))
    try:
        binding = _open_directory(parts)
        try:
            names = sorted(
                name for name in os.listdir(binding.descriptor) if name.endswith(".hcl")
            )
            binding.verify()
        finally:
            binding.close()
    except OSError as error:
        raise RuntimeError(
            f"cannot safely enumerate canonical Nomad configs: {error}"
        ) from error
    required = {"client.hcl", "server.hcl"}
    if not required.issubset(names):
        missing = ", ".join(
            str(directory / name) for name in sorted(required.difference(names))
        )
        raise RuntimeError(f"required Nomad HCL config is missing: {missing}")
    return [directory / name for name in names]


def _file_record(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _require_direct_file(metadata: os.stat_result, path: Path) -> None:
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
    ):
        raise RuntimeError(
            f"Nomad HCL input is not an owner-bound regular non-symlink file: {path}"
        )


def _require_hcl_size(metadata: os.stat_result, path: Path) -> None:
    if metadata.st_size > MAX_NOMAD_HCL_BYTES:
        raise RuntimeError(f"Nomad HCL input exceeds the size ceiling: {path}")


def validate(path: Path, parser: HCL2Parser) -> None:
    absolute, parts = _repository_relative(path)
    parent_binding = None
    descriptor = None
    try:
        parent_binding = _open_directory(parts[:-1])
        parent_binding.verify()
        named_before = os.stat(
            parts[-1],
            dir_fd=parent_binding.descriptor,
            follow_symlinks=False,
        )
        _require_direct_file(named_before, absolute)
        _require_hcl_size(named_before, absolute)
        descriptor = os.open(parts[-1], FILE_FLAGS, dir_fd=parent_binding.descriptor)
        opened_before = os.fstat(descriptor)
        _require_direct_file(opened_before, absolute)
        _require_hcl_size(opened_before, absolute)
        if _file_record(named_before) != _file_record(opened_before):
            raise RuntimeError(f"Nomad HCL input changed while opening: {absolute}")
        parent_binding.verify()
        stream_descriptor = os.dup(descriptor)
        with os.fdopen(stream_descriptor, "r", encoding="utf-8") as stream:
            parser.load(stream)
        parent_binding.verify()
        opened_after = os.fstat(descriptor)
        named_after = os.stat(
            parts[-1],
            dir_fd=parent_binding.descriptor,
            follow_symlinks=False,
        )
        _require_hcl_size(opened_after, absolute)
        _require_hcl_size(named_after, absolute)
        if _file_record(opened_after) != _file_record(opened_before) or _file_record(
            named_after
        ) != _file_record(opened_before):
            raise RuntimeError(f"Nomad HCL input changed during validation: {absolute}")
        _require_direct_file(opened_after, absolute)
        _require_direct_file(named_after, absolute)
        parent_binding.verify()
    except (OSError, UnicodeError) as error:
        raise RuntimeError(
            f"cannot safely read Nomad HCL {absolute}: {error}"
        ) from error
    except RuntimeError:
        raise
    except Exception as error:
        raise RuntimeError(f"invalid Nomad HCL {absolute}: {error}") from error
    finally:
        if descriptor is not None:
            os.close(descriptor)
        if parent_binding is not None:
            parent_binding.close()


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "paths",
        nargs="*",
        type=Path,
        help="HCL files to validate (defaults to configs/nomad/*.hcl)",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    arguments = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        parser = load_parser()
        paths = arguments.paths or canonical_paths()
        for path in paths:
            validate(path, parser)
    except RuntimeError as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 1
    for path in paths:
        print(f"OK: {path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
