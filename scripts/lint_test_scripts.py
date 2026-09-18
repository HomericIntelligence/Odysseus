#!/usr/bin/python3
"""Validate exact staged Bash test blobs with bounded trusted tooling."""

import argparse
import os
from pathlib import Path
import resource
import signal
import stat
import subprocess
import sys
import time
import types


MAX_HELPER_BYTES = 256 * 1024
MAX_INVENTORY_BYTES = 2 * 1024 * 1024
MAX_TEST_BYTES = 1_048_576
MAX_TOTAL_TEST_BYTES = 32 * 1024 * 1024
MAX_TESTS = 2_048
GLOBAL_DEADLINE_SECONDS = 30.0
BASH_DEADLINE_SECONDS = 2.0
MAX_DIAGNOSTIC_BYTES = 64 * 1024
BASH = "/bin/bash"


def _load_git_guard():
    """Compile the exact sibling Git guard from a retained nofollow route."""
    required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")
    if any(not hasattr(os, name) for name in required):
        raise RuntimeError("safe helper loading is unavailable")
    directory = os.path.dirname(os.path.abspath(__file__))
    name = "check_doc_field_drift.py"
    directory_flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
    descriptors = []
    links = []
    helper_fd = -1
    try:
        root_fd = os.open("/", directory_flags)
        descriptors.append(root_fd)
        current = root_fd
        for component in Path(directory).parts[1:]:
            child = os.open(component, directory_flags, dir_fd=current)
            metadata = os.fstat(child)
            identity = (metadata.st_dev, metadata.st_ino, metadata.st_mode)
            links.append((current, component, child, identity))
            descriptors.append(child)
            current = child
        helper_fd = os.open(
            name,
            os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW,
            dir_fd=current,
        )
        before = os.fstat(helper_fd)
        if (
            not stat.S_ISREG(before.st_mode)
            or before.st_nlink != 1
            or before.st_size > MAX_HELPER_BYTES
        ):
            raise RuntimeError("Git guard helper is not a bounded direct file")
        chunks = []
        total = 0
        while True:
            chunk = os.read(helper_fd, min(65_536, MAX_HELPER_BYTES + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > MAX_HELPER_BYTES:
                raise RuntimeError("Git guard helper exceeds its byte limit")
        source = b"".join(chunks)

        def file_identity(metadata):
            return (
                metadata.st_dev,
                metadata.st_ino,
                metadata.st_mode,
                metadata.st_nlink,
                metadata.st_size,
                metadata.st_mtime_ns,
                metadata.st_ctime_ns,
            )

        after = os.fstat(helper_fd)
        named = os.stat(name, dir_fd=current, follow_symlinks=False)
        if file_identity(before) != file_identity(after):
            raise RuntimeError("Git guard helper changed while it was read")
        if file_identity(named) != file_identity(before):
            raise RuntimeError("Git guard helper name changed while it was read")
        for parent_fd, component, child_fd, expected in links:
            named_directory = os.stat(
                component, dir_fd=parent_fd, follow_symlinks=False
            )
            opened_directory = os.fstat(child_fd)
            if (
                (
                    named_directory.st_dev,
                    named_directory.st_ino,
                    named_directory.st_mode,
                )
                != expected
                or (
                    opened_directory.st_dev,
                    opened_directory.st_ino,
                    opened_directory.st_mode,
                )
                != expected
            ):
                raise RuntimeError("Git guard helper route changed while loading")
        module = types.ModuleType("_odysseus_test_script_git_guard")
        module.__file__ = os.path.join(directory, name)
        module.__package__ = None
        exec(compile(source, module.__file__, "exec"), module.__dict__)
        return module
    finally:
        if helper_fd >= 0:
            os.close(helper_fd)
        for descriptor in reversed(descriptors):
            os.close(descriptor)


_GIT_GUARD = _load_git_guard()
CheckFailure = _GIT_GUARD.CheckFailure
RepositoryBinding = _GIT_GUARD.RepositoryBinding
run_git = _GIT_GUARD._run_git
verify_blob = _GIT_GUARD._verify_blob


def _display_path(path):
    decoded = os.fsdecode(path)
    if any(ord(character) < 32 or ord(character) == 127 for character in decoded):
        return repr(decoded)
    return decoded


def _is_candidate(path):
    if path.startswith(b"e2e/test-") and path.endswith(b".sh"):
        return b"/" not in path[len(b"e2e/") :]
    return path.startswith(b"tests/") and path.endswith(b".sh")


def _parse_inventory(raw):
    if raw and not raw.endswith(b"\0"):
        raise CheckFailure("Git returned a malformed tracked-file inventory")
    records = raw[:-1].split(b"\0") if raw else []
    scripts = []
    for record in records:
        try:
            metadata, path = record.split(b"\t", 1)
            mode, object_id, stage = metadata.split(b" ")
        except ValueError as error:
            raise CheckFailure("Git returned a malformed index entry") from error
        if stage != b"0":
            raise CheckFailure("unmerged index entries cannot be validated")
        if not _is_candidate(path):
            continue
        if mode not in (b"100644", b"100755"):
            raise CheckFailure(
                "%s: tracked test candidate is not a regular blob"
                % _display_path(path)
            )
        if not (
            len(object_id) in (40, 64)
            and all(character in b"0123456789abcdef" for character in object_id)
        ):
            raise CheckFailure("Git returned an invalid test-script object ID")
        scripts.append((path, object_id.decode("ascii")))
        if len(scripts) > MAX_TESTS:
            raise CheckFailure("tracked test-script count exceeds its limit")
    return scripts


def _bash_limits():
    resource.setrlimit(resource.RLIMIT_CPU, (2, 2))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    resource.setrlimit(resource.RLIMIT_NOFILE, (32, 32))
    if hasattr(resource, "RLIMIT_AS") and sys.platform != "darwin":
        resource.setrlimit(resource.RLIMIT_AS, (256 * 1024 * 1024,) * 2)


def _terminate(process):
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=1.0)
    except subprocess.TimeoutExpired as error:
        raise CheckFailure("Bash syntax parser could not be reaped") from error


def _check_syntax(body, deadline):
    remaining = min(BASH_DEADLINE_SECONDS, deadline - time.monotonic())
    if remaining <= 0:
        raise CheckFailure("test-script validation exceeded its deadline")
    try:
        process = subprocess.Popen(
            [BASH, "--noprofile", "--norc", "-n"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd="/",
            env={"LANG": "C", "LC_ALL": "C", "PATH": "/usr/bin:/bin"},
            close_fds=True,
            start_new_session=True,
            preexec_fn=_bash_limits,
        )
    except (OSError, subprocess.SubprocessError) as error:
        raise CheckFailure("could not start the trusted Bash syntax parser") from error
    try:
        stdout, stderr = process.communicate(body, timeout=remaining)
    except subprocess.TimeoutExpired as error:
        _terminate(process)
        raise CheckFailure("Bash syntax validation exceeded its deadline") from error
    if len(stdout) > MAX_DIAGNOSTIC_BYTES or len(stderr) > MAX_DIAGNOSTIC_BYTES:
        raise CheckFailure("Bash syntax diagnostic exceeds its byte limit")
    return process.returncode, stderr.decode("utf-8", "replace").strip()


def validate(repository):
    binding = RepositoryBinding(repository)
    deadline = time.monotonic() + GLOBAL_DEADLINE_SECONDS
    try:
        inventory = run_git(
            binding.git_fd,
            binding.index_fd,
            ["ls-files", "--stage", "-z"],
            MAX_INVENTORY_BYTES,
            deadline,
        )
        scripts = _parse_inventory(inventory)
        cache = {}
        total_bytes = 0
        failures = []
        for path, object_id in scripts:
            if object_id not in cache:
                body = run_git(
                    binding.git_fd,
                    binding.index_fd,
                    ["cat-file", "blob", object_id],
                    MAX_TEST_BYTES + 65_536,
                    deadline,
                )
                if len(body) > MAX_TEST_BYTES:
                    raise CheckFailure(
                        "%s: test script exceeds the %d-byte limit"
                        % (_display_path(path), MAX_TEST_BYTES)
                    )
                verify_blob(object_id, body)
                cache[object_id] = body
            body = cache[object_id]
            total_bytes += len(body)
            if total_bytes > MAX_TOTAL_TEST_BYTES:
                raise CheckFailure("test scripts exceed the aggregate byte limit")
            errors = []
            first_line = body.split(b"\n", 1)[0]
            if first_line not in (b"#!/usr/bin/env bash", b"#!/bin/bash"):
                errors.append("line 1 is not a supported Bash shebang")
            status, diagnostic = _check_syntax(body, deadline)
            if status != 0:
                errors.append("fails Bash syntax validation (bash -n)")
                if diagnostic:
                    errors.append("bash -n: " + diagnostic[:1_000])
            if errors:
                failures.append((_display_path(path), errors))
        final_inventory = run_git(
            binding.git_fd,
            binding.index_fd,
            ["ls-files", "--stage", "-z"],
            MAX_INVENTORY_BYTES,
            deadline,
        )
        if final_inventory != inventory:
            raise CheckFailure("Git index snapshot changed during validation")
        binding.revalidate()
        if failures:
            for path, errors in failures:
                print("FAIL: %s" % path)
                for error in errors:
                    print("    - %s" % error)
            print(
                "lint-test-scripts: %d invalid Bash test script(s) found."
                % len(failures),
                file=sys.stderr,
            )
            return 1
        if not scripts:
            print("OK: no test scripts discovered (nothing to lint).")
        else:
            print(
                "lint-test-scripts: all %d test script(s) are well-formed."
                % len(scripts)
            )
        return 0
    finally:
        binding.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    arguments = parser.parse_args()
    if not sys.flags.isolated or not sys.flags.no_site:
        print(
            "error: validator requires isolated Python with site loading disabled",
            file=sys.stderr,
        )
        return 2
    try:
        return validate(arguments.repo_root)
    except (CheckFailure, OSError, RuntimeError) as error:
        print("error: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
