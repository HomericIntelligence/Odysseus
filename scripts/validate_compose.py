#!/usr/bin/env python3
"""Validate Docker Compose files through bound objects and bounded YAML."""

from __future__ import annotations

import argparse
from dataclasses import dataclass, field
import fnmatch
import os
from pathlib import Path
import re
import stat
import sys
from typing import Any

import yaml
from yaml.events import AliasEvent, MappingStartEvent, SequenceStartEvent, StreamEndEvent


CANONICAL_COMPOSE_PATHS = (
    Path("docker-compose.e2e.yml"),
    Path("e2e/docker-compose.chaos.yml"),
    Path("e2e/docker-compose.cluster.yml"),
    Path("e2e/docker-compose.scale.yml"),
)
MAX_COMPOSE_BYTES = 1_048_576
MAX_YAML_DOCUMENTS = 1
MAX_YAML_NODES = 10_000
MAX_YAML_DEPTH = 50
MAX_YAML_ALIASES = 100
MAX_DIRECTORY_ENTRIES = 10_000
READ_CHUNK_BYTES = 65_536
DIGEST_REFERENCE = re.compile(r"[^\s\"'@#]+@sha256:[0-9a-f]{64}")


class ComposeResourceError(yaml.YAMLError):
    """Raised when a Compose document exceeds a parser resource budget."""


class BoundedSafeLoader(yaml.SafeLoader):
    """SafeLoader with pre-construction document, node, depth, and alias caps."""

    def __init__(self, stream: str) -> None:
        super().__init__(stream)
        self._compose_nodes = 0
        self._compose_depth = 0
        self._compose_aliases = 0

    def get_single_node(self) -> yaml.nodes.Node | None:
        """Compose exactly one document and reject a second before construction."""
        self.get_event()
        node = None
        if not self.check_event(StreamEndEvent):
            node = self.compose_document()
        if not self.check_event(StreamEndEvent):
            raise ComposeResourceError(
                f"YAML document limit ({MAX_YAML_DOCUMENTS}) exceeded"
            )
        self.get_event()
        return node

    def compose_node(
        self,
        parent: yaml.nodes.Node | None,
        index: Any,
    ) -> yaml.nodes.Node:
        """Count graph nodes and aliases before the loader allocates each node."""
        event = self.peek_event()
        self._compose_nodes += 1
        if self._compose_nodes > MAX_YAML_NODES:
            raise ComposeResourceError(
                f"YAML node limit ({MAX_YAML_NODES}) exceeded"
            )
        if isinstance(event, AliasEvent):
            self._compose_aliases += 1
            if self._compose_aliases > MAX_YAML_ALIASES:
                raise ComposeResourceError(
                    f"YAML alias limit ({MAX_YAML_ALIASES}) exceeded"
                )

        is_collection = isinstance(event, (MappingStartEvent, SequenceStartEvent))
        if is_collection:
            self._compose_depth += 1
            if self._compose_depth > MAX_YAML_DEPTH:
                raise ComposeResourceError(
                    f"YAML depth limit ({MAX_YAML_DEPTH}) exceeded"
                )
        try:
            return super().compose_node(parent, index)
        finally:
            if is_collection:
                self._compose_depth -= 1


def _required_open_flags() -> tuple[int, int]:
    required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW", "O_NONBLOCK")
    missing = [name for name in required if not hasattr(os, name)]
    if missing:
        raise OSError(
            "safe Compose file opening is unavailable: " + ", ".join(missing)
        )
    common = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
    return common | os.O_NONBLOCK, common | os.O_DIRECTORY


def _object_identity(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
    )


def _file_state(metadata: os.stat_result) -> tuple[int, ...]:
    return (
        *_object_identity(metadata),
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


@dataclass(frozen=True)
class _DirectoryLink:
    parent_fd: int
    name: str
    child_fd: int
    identity: tuple[int, ...]


@dataclass
class DirectoryChain:
    """Retained no-follow descriptors for every component below `/`."""

    fds: list[int] = field(default_factory=list)
    links: list[_DirectoryLink] = field(default_factory=list)
    final_fd: int = -1

    def open_child(self, name: str) -> int:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise OSError("invalid directory component")
        _, directory_flags = _required_open_flags()
        child_fd = os.open(name, directory_flags, dir_fd=self.final_fd)
        metadata = os.fstat(child_fd)
        if not stat.S_ISDIR(metadata.st_mode):
            os.close(child_fd)
            raise OSError(f"directory component is not a directory: {name}")
        self.links.append(
            _DirectoryLink(
                parent_fd=self.final_fd,
                name=name,
                child_fd=child_fd,
                identity=_object_identity(metadata),
            )
        )
        self.fds.append(child_fd)
        self.final_fd = child_fd
        return child_fd

    def revalidate(self) -> None:
        for link in self.links:
            try:
                current = os.stat(
                    link.name,
                    dir_fd=link.parent_fd,
                    follow_symlinks=False,
                )
                opened = os.fstat(link.child_fd)
            except OSError as error:
                raise OSError(
                    f"Compose root changed or a directory replacement occurred: {error}"
                ) from error
            if (
                not stat.S_ISDIR(current.st_mode)
                or _object_identity(current) != link.identity
                or _object_identity(opened) != link.identity
            ):
                raise OSError(
                    "Compose root changed or a directory replacement occurred"
                )

    def close(self) -> None:
        while self.fds:
            fd = self.fds.pop()
            try:
                os.close(fd)
            except OSError:
                pass
        self.links.clear()
        self.final_fd = -1


def open_directory_chain(path: Path) -> DirectoryChain:
    """Bind an absolute directory from `/` without following any component."""
    absolute = Path(os.path.abspath(path))
    if not absolute.is_absolute():
        raise OSError("Compose directory must be absolute")
    _, directory_flags = _required_open_flags()
    chain = DirectoryChain()
    try:
        root_fd = os.open("/", directory_flags)
        chain.fds.append(root_fd)
        chain.final_fd = root_fd
        for component in absolute.parts[1:]:
            chain.open_child(component)
        return chain
    except BaseException:
        chain.close()
        raise


@dataclass
class BoundComposeFile:
    """One exact, singly-linked regular file retained through parsing."""

    parent_fd: int
    name: str
    fd: int
    state: tuple[int, ...]
    source: str

    @classmethod
    def open(cls, parent_fd: int, name: str) -> BoundComposeFile:
        if not name or name in {".", ".."} or "/" in name or "\x00" in name:
            raise OSError("invalid Compose file name")
        file_flags, _ = _required_open_flags()
        fd = os.open(name, file_flags, dir_fd=parent_fd)
        try:
            before = os.fstat(fd)
            if not stat.S_ISREG(before.st_mode):
                raise OSError("Compose entry is not a regular file")
            if before.st_nlink != 1:
                raise OSError("Compose file must be a singly linked regular file")
            if before.st_size > MAX_COMPOSE_BYTES:
                raise OSError(
                    f"Compose file exceeds the {MAX_COMPOSE_BYTES}-byte limit"
                )

            chunks: list[bytes] = []
            total = 0
            while True:
                chunk = os.read(
                    fd,
                    min(READ_CHUNK_BYTES, MAX_COMPOSE_BYTES + 1 - total),
                )
                if not chunk:
                    break
                chunks.append(chunk)
                total += len(chunk)
                if total > MAX_COMPOSE_BYTES:
                    raise OSError(
                        f"Compose file exceeds the {MAX_COMPOSE_BYTES}-byte limit"
                    )

            after = os.fstat(fd)
            if _file_state(before) != _file_state(after):
                raise OSError("Compose file changed while it was read")
            try:
                source = b"".join(chunks).decode("utf-8")
            except UnicodeDecodeError as error:
                raise OSError(f"Compose file is not valid UTF-8: {error}") from error
            return cls(parent_fd, name, fd, _file_state(after), source)
        except BaseException:
            os.close(fd)
            raise

    def revalidate(self) -> None:
        try:
            opened = os.fstat(self.fd)
            current = os.stat(
                self.name,
                dir_fd=self.parent_fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise OSError(
                f"Compose file changed or a filename replacement occurred: {error}"
            ) from error
        if (
            not stat.S_ISREG(current.st_mode)
            or current.st_nlink != 1
            or _file_state(opened) != self.state
            or _file_state(current) != self.state
        ):
            raise OSError("Compose file changed or a filename replacement occurred")

    def close(self) -> None:
        if self.fd >= 0:
            os.close(self.fd)
            self.fd = -1


def _parse(source: str) -> object:
    return yaml.load(source, Loader=BoundedSafeLoader)


def _check_document(document: object) -> tuple[bool, str]:
    if not isinstance(document, dict):
        return False, "top level is not a mapping"
    services = document.get("services")
    if not isinstance(services, dict) or not services:
        return False, "missing or empty 'services' mapping"
    for name, service in services.items():
        if not isinstance(service, dict):
            return False, f"service '{name}' is not a mapping"
    return True, f"{len(services)} service(s)"


def load_compose_path(path: Path) -> object:
    """Parse one path and prove its full lexical chain still names the object."""
    absolute = Path(os.path.abspath(path))
    chain = open_directory_chain(absolute.parent)
    bound: BoundComposeFile | None = None
    try:
        bound = BoundComposeFile.open(chain.final_fd, absolute.name)
        document = _parse(bound.source)
        bound.revalidate()
        chain.revalidate()
        return document
    finally:
        if bound is not None:
            bound.close()
        chain.close()


def check(path: Path) -> tuple[bool, str]:
    """Safely read and check one explicit Compose path."""
    try:
        document = load_compose_path(path)
    except OSError as error:
        return False, f"could not safely open Compose file: {error}"
    except yaml.YAMLError as error:
        return False, f"YAML parse error: {error}"
    return _check_document(document)


def _discover(parent_fd: int) -> list[str]:
    names: list[str] = []
    with os.scandir(parent_fd) as entries:
        for count, entry in enumerate(entries, start=1):
            if count > MAX_DIRECTORY_ENTRIES:
                raise OSError(
                    "Compose directory exceeds the "
                    f"{MAX_DIRECTORY_ENTRIES}-entry inventory limit"
                )
            if fnmatch.fnmatchcase(entry.name, "docker-compose*.yml"):
                names.append(entry.name)
    return sorted(names)


def _validate_inventory() -> int:
    root_path = Path(os.path.abspath(__file__)).parent.parent
    chain = open_directory_chain(root_path)
    root_fd = chain.final_fd
    bindings: list[BoundComposeFile] = []
    try:
        e2e_fd = chain.open_child("e2e")
        initial_root_names = _discover(root_fd)
        initial_e2e_names = _discover(e2e_fd)
        files = [Path(name) for name in initial_root_names]
        files.extend(Path("e2e") / name for name in initial_e2e_names)
        directory_fds = {Path("."): root_fd, Path("e2e"): e2e_fd}
        missing = [path for path in CANONICAL_COMPOSE_PATHS if path not in set(files)]
        if missing:
            for path in missing:
                print(
                    f"FAILED: missing canonical Compose file: {path}",
                    file=sys.stderr,
                )
            return 1

        results: list[tuple[Path, bool, str]] = []
        for path in sorted(files):
            try:
                bound = BoundComposeFile.open(directory_fds[path.parent], path.name)
                bindings.append(bound)
                document = _parse(bound.source)
                ok, message = _check_document(document)
                results.append((path, ok, message))
            except OSError as error:
                results.append(
                    (path, False, f"could not safely open regular file: {error}")
                )
            except yaml.YAMLError as error:
                results.append((path, False, f"YAML parse error: {error}"))

        for binding in bindings:
            binding.revalidate()
        if (
            _discover(root_fd) != initial_root_names
            or _discover(e2e_fd) != initial_e2e_names
        ):
            raise OSError("Compose inventory changed during validation")
        chain.revalidate()

        failed = 0
        for path, ok, message in results:
            if ok:
                print(f"OK ({message}): {path}")
            else:
                print(f"FAILED: {path} -- {message}", file=sys.stderr)
                failed += 1
        return 1 if failed else 0
    except OSError as error:
        print(f"FAILED: cannot safely validate Compose inventory: {error}", file=sys.stderr)
        return 1
    finally:
        for binding in bindings:
            binding.close()
        chain.close()


def _validate_image_pins(path: Path) -> int:
    try:
        document = load_compose_path(path)
    except OSError as error:
        print(f"ERROR: could not safely open regular Compose file: {error}", file=sys.stderr)
        return 2
    except yaml.YAMLError as error:
        print(f"ERROR: YAML parse failed for {path}: {error}", file=sys.stderr)
        return 1

    services = document.get("services") if isinstance(document, dict) else None
    images: list[tuple[str, object]] = []
    if isinstance(services, dict):
        for service_name, service in services.items():
            if isinstance(service, dict) and "image" in service:
                images.append((str(service_name), service["image"]))
    if not images:
        print(f"ERROR: no image declarations found in {path}.", file=sys.stderr)
        return 1

    unpinned = [
        (service_name, image)
        for service_name, image in images
        if not isinstance(image, str) or DIGEST_REFERENCE.fullmatch(image) is None
    ]
    if unpinned:
        print(f"ERROR: unpinned (non-digest) image references in {path}:", file=sys.stderr)
        for service_name, image in unpinned:
            print(f"  - services.{service_name}.image: {image!r}", file=sys.stderr)
        print(
            "Pin each to name:<version>@sha256:<manifest-list-digest> "
            "for reproducible e2e runs (#188).",
            file=sys.stderr,
        )
        return 1
    print(f"OK: all parsed service image references in {path} are digest-pinned.")
    return 0


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--image-pins", type=Path)
    arguments = parser.parse_args(argv)
    if arguments.image_pins is not None:
        return _validate_image_pins(arguments.image_pins)
    return _validate_inventory()


if __name__ == "__main__":
    sys.exit(main())
