#!/usr/bin/env python3
"""No-follow reads for tracked worktree security gates."""

from __future__ import annotations

import errno
import os
import stat
import sys
import tempfile
from collections.abc import Callable
from pathlib import Path


class UnsafeTrackedPathError(RuntimeError):
    """A tracked path could not be opened as one stable regular file."""


OpenFn = Callable[..., int]


def _same_file(before: os.stat_result, after: os.stat_result) -> bool:
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
    return all(getattr(before, field) == getattr(after, field) for field in fields)


def _same_object(before: os.stat_result, after: os.stat_result) -> bool:
    """Compare a path component without making atime part of the contract."""
    fields = ("st_dev", "st_ino", "st_mode", "st_size", "st_mtime_ns", "st_ctime_ns")
    return all(getattr(before, field) == getattr(after, field) for field in fields)


def read_regular_no_follow(
    root: Path,
    relative: str,
    *,
    open_fn: OpenFn = os.open,
) -> bytes | None:
    """Open each path component without following links and read one stable FD.

    A missing tracked worktree path is an ordinary deletion and returns None.
    Every other unsafe type, open failure, or concurrent content change raises.
    """
    if not relative or relative.startswith("/"):
        raise UnsafeTrackedPathError(f"invalid tracked relative path: {relative!r}")
    parts = relative.split("/")
    if any(part in {"", ".", ".."} for part in parts):
        raise UnsafeTrackedPathError(f"invalid tracked relative path: {relative!r}")

    cloexec = getattr(os, "O_CLOEXEC", 0)
    nofollow = getattr(os, "O_NOFOLLOW", 0)
    nonblock = getattr(os, "O_NONBLOCK", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    if not nofollow or not directory:
        raise UnsafeTrackedPathError("required no-follow directory opens unavailable")

    opened: list[int] = []
    component_stats: list[os.stat_result] = []

    def verify_still_missing() -> None:
        """Require a tracked deletion to remain absent on a full re-resolution."""
        # The recorded list contains the root plus every directory opened
        # before the first missing component.  That next component is the only
        # one that may still be absent: accepting an earlier missing component
        # would hide a rename/replacement of an already-opened parent.
        expected_missing_index = len(component_stats) - 1
        checked: list[int] = []
        try:
            try:
                resolved = open_fn(
                    root, os.O_RDONLY | cloexec | nofollow | directory
                )
            except OSError as exc:
                raise UnsafeTrackedPathError(
                    f"cannot re-open repository root for deletion check: {exc}"
                ) from exc
            checked.append(resolved)
            if component_stats and not _same_object(
                component_stats[0], os.fstat(resolved)
            ):
                raise UnsafeTrackedPathError(
                    f"repository root changed during deletion check: {relative!r}"
                )
            for index, component in enumerate(parts):
                flags = os.O_RDONLY | cloexec | nofollow | nonblock
                if index < len(parts) - 1:
                    flags |= directory
                try:
                    candidate = open_fn(component, flags, dir_fd=resolved)
                except FileNotFoundError:
                    if index == expected_missing_index:
                        return
                    raise UnsafeTrackedPathError(
                        f"tracked prefix changed during deletion check: {relative!r}"
                    )
                except OSError as exc:
                    detail = "symbolic link" if exc.errno == errno.ELOOP else str(exc)
                    raise UnsafeTrackedPathError(
                        f"tracked deletion cannot be verified for {relative!r}: {detail}"
                    ) from exc
                checked.append(candidate)
                resolved = candidate
                if index < expected_missing_index:
                    if not _same_object(
                        component_stats[index + 1], os.fstat(candidate)
                    ):
                        raise UnsafeTrackedPathError(
                            f"tracked prefix changed during deletion check: {relative!r}"
                        )
                    continue
                raise UnsafeTrackedPathError(
                    f"tracked path reappeared during deletion check: {relative!r}"
                )
        finally:
            for descriptor in reversed(checked):
                try:
                    os.close(descriptor)
                except OSError:
                    pass

    try:
        try:
            current = open_fn(root, os.O_RDONLY | cloexec | nofollow | directory)
        except OSError as exc:
            raise UnsafeTrackedPathError(
                f"cannot open repository root without following links: {exc}"
            ) from exc
        opened.append(current)
        component_stats.append(os.fstat(current))

        for component in parts[:-1]:
            try:
                current = open_fn(
                    component,
                    os.O_RDONLY | cloexec | nofollow | directory,
                    dir_fd=current,
                )
            except FileNotFoundError:
                verify_still_missing()
                return None
            except OSError as exc:
                raise UnsafeTrackedPathError(
                    f"cannot open tracked directory in {relative!r}: {exc}"
                ) from exc
            opened.append(current)
            component_stats.append(os.fstat(current))

        try:
            file_fd = open_fn(
                parts[-1],
                os.O_RDONLY | cloexec | nofollow | nonblock,
                dir_fd=current,
            )
        except FileNotFoundError:
            verify_still_missing()
            return None
        except OSError as exc:
            detail = "symbolic link" if exc.errno == errno.ELOOP else str(exc)
            raise UnsafeTrackedPathError(
                f"cannot open tracked path {relative!r} safely: {detail}"
            ) from exc
        opened.append(file_fd)

        before = os.fstat(file_fd)
        if not stat.S_ISREG(before.st_mode):
            raise UnsafeTrackedPathError(
                f"tracked path is not a regular file: {relative!r}"
            )

        chunks: list[bytes] = []
        while True:
            chunk = os.read(file_fd, 1024 * 1024)
            if not chunk:
                break
            chunks.append(chunk)
        data = b"".join(chunks)
        after = os.fstat(file_fd)
        if len(data) != before.st_size or not _same_file(before, after):
            raise UnsafeTrackedPathError(
                f"tracked path changed while it was scanned: {relative!r}"
            )

        # An open FD remains valid after its pathname (or a parent directory)
        # is renamed and replaced. Re-resolve the complete path from the bound
        # root after the read, without following links, so the bytes just
        # inspected still belong to the tracked pathname.
        recheck: list[int] = []
        try:
            try:
                resolved = open_fn(root, os.O_RDONLY | cloexec | nofollow | directory)
            except OSError as exc:
                raise UnsafeTrackedPathError(
                    f"cannot re-open repository root safely: {exc}"
                ) from exc
            recheck.append(resolved)
            if not _same_object(component_stats[0], os.fstat(resolved)):
                raise UnsafeTrackedPathError(
                    f"repository root changed while scanning {relative!r}"
                )

            for index, component in enumerate(parts[:-1], start=1):
                try:
                    resolved = open_fn(
                        component,
                        os.O_RDONLY | cloexec | nofollow | directory,
                        dir_fd=resolved,
                    )
                except OSError as exc:
                    raise UnsafeTrackedPathError(
                        f"tracked directory changed while scanning {relative!r}: {exc}"
                    ) from exc
                recheck.append(resolved)
                if not _same_object(component_stats[index], os.fstat(resolved)):
                    raise UnsafeTrackedPathError(
                        f"tracked directory changed while scanning {relative!r}"
                    )

            try:
                resolved_file = open_fn(
                    parts[-1],
                    os.O_RDONLY | cloexec | nofollow | nonblock,
                    dir_fd=resolved,
                )
            except OSError as exc:
                raise UnsafeTrackedPathError(
                    f"tracked path changed after it was scanned {relative!r}: {exc}"
                ) from exc
            recheck.append(resolved_file)
            current_stat = os.fstat(resolved_file)
            if not stat.S_ISREG(current_stat.st_mode) or not _same_file(
                after, current_stat
            ):
                raise UnsafeTrackedPathError(
                    f"tracked pathname was replaced after it was scanned: {relative!r}"
                )
        finally:
            for descriptor in reversed(recheck):
                try:
                    os.close(descriptor)
                except OSError:
                    pass
        return data
    finally:
        for descriptor in reversed(opened):
            try:
                os.close(descriptor)
            except OSError:
                pass


def _self_test() -> int:
    results: list[tuple[str, bool]] = []
    with tempfile.TemporaryDirectory() as directory_name:
        root = Path(directory_name)
        regular = root / "regular.md"
        regular.write_bytes(b"safe\n")
        results.append(("regular", read_regular_no_follow(root, "regular.md") == b"safe\n"))
        results.append(("deletion", read_regular_no_follow(root, "missing.md") is None))

        link = root / "link.md"
        link.symlink_to("missing.md")
        try:
            read_regular_no_follow(root, "link.md")
        except UnsafeTrackedPathError:
            results.append(("static_symlink", True))
        else:
            results.append(("static_symlink", False))

        swap = root / "swap.md"
        swap.write_bytes(b"safe\n")
        swapped = False
        real_open = os.open

        def swapping_open(path: object, flags: int, mode: int = 0o600, **kwargs: object) -> int:
            nonlocal swapped
            if path == "swap.md" and kwargs.get("dir_fd") is not None and not swapped:
                swapped = True
                swap.unlink()
                swap.symlink_to("missing.md")
            return real_open(path, flags, mode, **kwargs)

        try:
            read_regular_no_follow(root, "swap.md", open_fn=swapping_open)
        except UnsafeTrackedPathError:
            results.append(("swap_at_open", True))
        else:
            results.append(("swap_at_open", False))

        post = root / "post.md"
        post.write_bytes(b"safe\n")
        post_open_count = 0

        def replacing_open(
            path: object, flags: int, mode: int = 0o600, **kwargs: object
        ) -> int:
            nonlocal post_open_count
            if path == "post.md" and kwargs.get("dir_fd") is not None:
                post_open_count += 1
                if post_open_count == 2:
                    post.rename(root / "post.old")
                    post.write_bytes(b"replacement\n")
            return real_open(path, flags, mode, **kwargs)

        try:
            read_regular_no_follow(root, "post.md", open_fn=replacing_open)
        except UnsafeTrackedPathError:
            results.append(("replace_after_read", True))
        else:
            results.append(("replace_after_read", False))

        transient = root / "transient.md"
        transient.write_bytes(b"unsafe\n")
        transient_bytes = transient.read_bytes()
        transient_deleted = False
        transient_root_opens = 0

        def transient_open(
            path: object, flags: int, mode: int = 0o600, **kwargs: object
        ) -> int:
            nonlocal transient_deleted, transient_root_opens
            if path == root:
                transient_root_opens += 1
                if transient_root_opens == 2 and transient_deleted:
                    transient.write_bytes(transient_bytes)
            if (
                path == "transient.md"
                and kwargs.get("dir_fd") is not None
                and not transient_deleted
            ):
                transient.unlink()
                transient_deleted = True
            return real_open(path, flags, mode, **kwargs)

        try:
            read_regular_no_follow(root, "transient.md", open_fn=transient_open)
        except UnsafeTrackedPathError:
            results.append(("transient_delete_restore", True))
        else:
            results.append(("transient_delete_restore", False))

        parent = root / "parent"
        parent.mkdir()
        parent_open_count = 0

        def replacing_parent_open(
            path: object, flags: int, mode: int = 0o600, **kwargs: object
        ) -> int:
            nonlocal parent_open_count
            if path == "parent" and kwargs.get("dir_fd") is not None:
                parent_open_count += 1
                if parent_open_count == 2:
                    parent.rename(root / "parent.old")
                    parent.mkdir()
            return real_open(path, flags, mode, **kwargs)

        try:
            read_regular_no_follow(
                root, "parent/missing.md", open_fn=replacing_parent_open
            )
        except UnsafeTrackedPathError:
            results.append(("missing_leaf_replaced_parent", True))
        else:
            results.append(("missing_leaf_replaced_parent", False))

    for name, passed in results:
        print(f"  [{'PASS' if passed else 'FAIL'}] {name}")
    failed = [name for name, passed in results if not passed]
    if failed:
        print(f"tracked_scan self-test FAILED: {', '.join(failed)}", file=sys.stderr)
        return 1
    print(f"tracked_scan self-test OK: {len(results)}/{len(results)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(_self_test() if "--self-test" in sys.argv[1:] else 2)
