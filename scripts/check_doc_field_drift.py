#!/usr/bin/python3
"""Check exact staged Markdown blobs for deprecated workflow field keys."""

import argparse
import errno
import hashlib
import os
from pathlib import Path
import re
import resource
import selectors
import signal
import stat
import sys
import tempfile
import time


GIT = "/usr/bin/git"
MAX_INVENTORY_BYTES = 1_048_576
MAX_DOCUMENT_BYTES = 1_048_576
MAX_TOTAL_DOCUMENT_BYTES = 16 * 1024 * 1024
MAX_DOCUMENTS = 2_048
MAX_DIAGNOSTICS = 1_000
MAX_DIAGNOSTIC_BYTES = 64 * 1024
MAX_PATH_BYTES = 4 * 1024
GLOBAL_DEADLINE_SECONDS = 30.0
COMMAND_DEADLINE_SECONDS = 5.0
MAX_STDERR_BYTES = 64 * 1024
MAX_GIT_POINTER_BYTES = 8 * 1024
MAX_INDEX_BYTES = 16 * 1024 * 1024
DEPRECATED_FIELD = re.compile(
    rb"^[\t ]*-?[\t ]*(?:title|depends_on):",
    re.MULTILINE,
)
EXCLUDED_PREFIXES = (
    b"infrastructure/",
    b"control/",
    b"provisioning/",
    b"ci-cd/",
    b"research/",
    b"shared/",
    b"testing/",
    b".github/",
)


class CheckFailure(RuntimeError):
    """A fail-closed validation or execution error."""


def _directory_identity(metadata):
    return (metadata.st_dev, metadata.st_ino, metadata.st_mode)


class BoundDirectory:
    """Retain and later revalidate every no-follow component below `/`."""

    def __init__(self, path):
        required = ("O_CLOEXEC", "O_DIRECTORY", "O_NOFOLLOW")
        if any(not hasattr(os, name) for name in required):
            raise CheckFailure("safe repository binding is unavailable")
        absolute = Path(os.path.abspath(path))
        self.path = os.fspath(absolute)
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_DIRECTORY | os.O_NOFOLLOW
        self.fds = []
        self.links = []
        try:
            root_fd = os.open("/", flags)
            self.fds.append(root_fd)
            current = root_fd
            for component in absolute.parts[1:]:
                child = os.open(component, flags, dir_fd=current)
                metadata = os.fstat(child)
                if not stat.S_ISDIR(metadata.st_mode):
                    os.close(child)
                    raise CheckFailure("repository component is not a directory")
                self.links.append(
                    (current, component, child, _directory_identity(metadata))
                )
                self.fds.append(child)
                current = child
            self.fd = current
        except BaseException:
            self.close()
            raise

    def revalidate(self):
        for parent_fd, name, child_fd, expected in self.links:
            try:
                current = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
                opened = os.fstat(child_fd)
            except OSError as error:
                raise CheckFailure("repository path changed during validation") from error
            if (
                not stat.S_ISDIR(current.st_mode)
                or _directory_identity(current) != expected
                or _directory_identity(opened) != expected
            ):
                raise CheckFailure("repository path changed during validation")

    def close(self):
        for descriptor in reversed(getattr(self, "fds", [])):
            try:
                os.close(descriptor)
            except OSError:
                pass
        self.fds = []
        self.fd = -1


def _file_identity(metadata):
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


class BoundFile:
    """Retain one direct regular file and its exact bounded bytes."""

    def __init__(self, parent_fd, name, byte_limit, description):
        required = ("O_CLOEXEC", "O_NOFOLLOW")
        if any(not hasattr(os, item) for item in required):
            raise CheckFailure("safe file binding is unavailable")
        self.parent_fd = parent_fd
        self.name = name
        self.byte_limit = byte_limit
        self.description = description
        flags = os.O_RDONLY | os.O_CLOEXEC | os.O_NOFOLLOW
        self.fd = os.open(name, flags, dir_fd=parent_fd)
        try:
            metadata = os.fstat(self.fd)
            if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1:
                raise CheckFailure("%s is not a direct regular file" % description)
            if metadata.st_size > byte_limit:
                raise CheckFailure("%s exceeds its byte limit" % description)
            self.identity = _file_identity(metadata)
            self.data = self._read()
            if _file_identity(os.fstat(self.fd)) != self.identity:
                raise CheckFailure("%s changed while it was read" % description)
        except BaseException:
            self.close()
            raise

    def _read(self):
        os.lseek(self.fd, 0, os.SEEK_SET)
        chunks = []
        total = 0
        while True:
            chunk = os.read(self.fd, min(65_536, self.byte_limit + 1 - total))
            if not chunk:
                break
            chunks.append(chunk)
            total += len(chunk)
            if total > self.byte_limit:
                raise CheckFailure("%s exceeds its byte limit" % self.description)
        return b"".join(chunks)

    def revalidate(self):
        try:
            named = os.stat(
                self.name, dir_fd=self.parent_fd, follow_symlinks=False
            )
            opened = os.fstat(self.fd)
        except OSError as error:
            raise CheckFailure("%s changed during validation" % self.description) from error
        if (
            not stat.S_ISREG(named.st_mode)
            or named.st_nlink != 1
            or _file_identity(named) != self.identity
            or _file_identity(opened) != self.identity
            or self._read() != self.data
            or _file_identity(os.fstat(self.fd)) != self.identity
        ):
            raise CheckFailure("%s changed during validation" % self.description)

    def close(self):
        if getattr(self, "fd", -1) >= 0:
            try:
                os.close(self.fd)
            except OSError:
                pass
        self.fd = -1


def _pointer_path(data, prefix, base, description):
    if data.endswith(b"\n"):
        data = data[:-1]
    if not data or b"\0" in data or b"\n" in data or b"\r" in data:
        raise CheckFailure("%s is malformed" % description)
    if prefix is not None:
        if not data.startswith(prefix) or len(data) == len(prefix):
            raise CheckFailure("%s is malformed" % description)
        data = data[len(prefix) :]
    decoded = os.fsdecode(data)
    if os.path.isabs(decoded):
        return os.path.normpath(decoded)
    return os.path.normpath(os.path.join(base, decoded))


class RepositoryBinding:
    """Bind worktree metadata and provide an immutable index snapshot to Git."""

    def __init__(self, repository):
        self.root = None
        self.git_file = None
        self.git_directory = None
        self.common_file = None
        self.common_directory = None
        self.objects_directory = None
        self.index_file = None
        self.index_snapshot = None
        try:
            physical_root = os.path.realpath(os.path.abspath(repository))
            self.root = BoundDirectory(physical_root)
            git_metadata = os.stat(
                ".git", dir_fd=self.root.fd, follow_symlinks=False
            )
            if stat.S_ISDIR(git_metadata.st_mode):
                git_path = os.path.join(self.root.path, ".git")
            elif stat.S_ISREG(git_metadata.st_mode):
                self.git_file = BoundFile(
                    self.root.fd,
                    ".git",
                    MAX_GIT_POINTER_BYTES,
                    "worktree Git pointer",
                )
                git_path = _pointer_path(
                    self.git_file.data,
                    b"gitdir: ",
                    self.root.path,
                    "worktree Git pointer",
                )
            else:
                raise CheckFailure("worktree .git entry is not a direct file or directory")
            self.git_directory = BoundDirectory(git_path)
            try:
                self.common_file = BoundFile(
                    self.git_directory.fd,
                    "commondir",
                    MAX_GIT_POINTER_BYTES,
                    "Git common-directory pointer",
                )
            except FileNotFoundError:
                common_path = self.git_directory.path
            else:
                common_path = _pointer_path(
                    self.common_file.data,
                    None,
                    self.git_directory.path,
                    "Git common-directory pointer",
                )
            if common_path == self.git_directory.path:
                self.common_directory = self.git_directory
            else:
                self.common_directory = BoundDirectory(common_path)
            self.objects_directory = BoundDirectory(
                os.path.join(self.common_directory.path, "objects")
            )
            self.index_file = BoundFile(
                self.git_directory.fd,
                "index",
                MAX_INDEX_BYTES,
                "Git index",
            )
            self.index_snapshot = tempfile.TemporaryFile()
            self.index_snapshot.write(self.index_file.data)
            self.index_snapshot.flush()
            self.index_snapshot.seek(0)
        except BaseException:
            self.close()
            raise

    @property
    def git_fd(self):
        return self.common_directory.fd

    @property
    def index_fd(self):
        return self.index_snapshot.fileno()

    def revalidate(self):
        self.index_file.revalidate()
        self.objects_directory.revalidate()
        if self.common_directory is not self.git_directory:
            self.common_directory.revalidate()
        if self.common_file is not None:
            self.common_file.revalidate()
        self.git_directory.revalidate()
        if self.git_file is not None:
            self.git_file.revalidate()
        self.root.revalidate()

    def close(self):
        if self.index_snapshot is not None:
            self.index_snapshot.close()
            self.index_snapshot = None
        if self.index_file is not None:
            self.index_file.close()
            self.index_file = None
        if self.objects_directory is not None:
            self.objects_directory.close()
            self.objects_directory = None
        if (
            self.common_directory is not None
            and self.common_directory is not self.git_directory
        ):
            self.common_directory.close()
        self.common_directory = None
        if self.common_file is not None:
            self.common_file.close()
            self.common_file = None
        if self.git_directory is not None:
            self.git_directory.close()
            self.git_directory = None
        if self.git_file is not None:
            self.git_file.close()
            self.git_file = None
        if self.root is not None:
            self.root.close()
            self.root = None


def _git_environment(index_fd):
    return {
        "GCM_INTERACTIVE": "Never",
        "GIT_ALLOW_PROTOCOL": "",
        "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_SYSTEM": "/dev/null",
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_NO_LAZY_FETCH": "1",
        "GIT_NO_REPLACE_OBJECTS": "1",
        "GIT_INDEX_FILE": "/dev/fd/%d" % index_fd,
        "GIT_OPTIONAL_LOCKS": "0",
        "GIT_PROTOCOL_FROM_USER": "0",
        "GIT_TERMINAL_PROMPT": "0",
        "HOME": "/nonexistent",
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "XDG_CONFIG_HOME": "/nonexistent",
    }


def _decode_status(status):
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    if os.WIFSIGNALED(status):
        return 128 + os.WTERMSIG(status)
    return 255


def _apply_git_resource_limits():
    resource.setrlimit(resource.RLIMIT_CPU, (3, 3))
    resource.setrlimit(resource.RLIMIT_FSIZE, (0, 0))
    resource.setrlimit(resource.RLIMIT_NOFILE, (64, 64))
    if hasattr(resource, "RLIMIT_NPROC"):
        resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))
    memory_limit_installed = False
    if sys.platform != "darwin":
        for name in ("RLIMIT_AS", "RLIMIT_DATA"):
            if not hasattr(resource, name):
                continue
            try:
                resource.setrlimit(
                    getattr(resource, name),
                    (512 * 1024 * 1024, 512 * 1024 * 1024),
                )
                memory_limit_installed = True
            except (OSError, ValueError):
                continue
        if not memory_limit_installed:
            raise CheckFailure("trusted Git memory limits are unavailable")


def _signal_containment(pid, process_group_ready):
    if process_group_ready:
        try:
            os.killpg(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError:
            pass
    try:
        os.kill(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass


def _process_group_exists(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def _finish_child(pid, status, process_group_ready, terminate):
    """Reap the leader and prove its contained process group is extinct."""
    cleanup_deadline = time.monotonic() + 1.0
    if terminate:
        _signal_containment(pid, process_group_ready)
    while status is None and time.monotonic() < cleanup_deadline:
        try:
            waited, candidate_status = os.waitpid(pid, os.WNOHANG)
        except ChildProcessError:
            break
        if waited == pid:
            status = candidate_status
            break
        if terminate:
            _signal_containment(pid, process_group_ready)
        time.sleep(0.01)
    if status is None:
        _signal_containment(pid, process_group_ready)
        return None, "trusted Git process could not be reaped"
    if process_group_ready:
        while _process_group_exists(pid) and time.monotonic() < cleanup_deadline:
            time.sleep(0.01)
        if _process_group_exists(pid):
            return status, "trusted Git process group did not terminate"
    return status, None


def _run_git(git_fd, index_fd, arguments, output_limit, deadline):
    """Run fixed Git from the bound repository FD with capped output/time."""
    stdout_read, stdout_write = os.pipe()
    stderr_read, stderr_write = os.pipe()
    ready_read, ready_write = os.pipe()
    try:
        pid = os.fork()
    except BaseException:
        for descriptor in (
            stdout_read,
            stdout_write,
            stderr_read,
            stderr_write,
            ready_read,
            ready_write,
        ):
            os.close(descriptor)
        raise

    if pid == 0:  # pragma: no cover - behavior is asserted through the parent
        try:
            os.setsid()
            os.close(ready_read)
            os.write(ready_write, b"1")
            os.close(ready_write)
            _apply_git_resource_limits()
            os.fchdir(git_fd)
            os.set_inheritable(index_fd, True)
            os.dup2(stdout_write, 1)
            os.dup2(stderr_write, 2)
            for descriptor in (stdout_read, stdout_write, stderr_read, stderr_write):
                if descriptor not in (1, 2):
                    os.close(descriptor)
            argv = [
                GIT,
                "--no-replace-objects",
                "--git-dir=.",
                "-c",
                "core.attributesFile=/dev/null",
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/dev/null",
                "-c",
                "protocol.allow=never",
            ] + list(arguments)
            os.execve(GIT, argv, _git_environment(index_fd))
        except BaseException as error:
            try:
                os.write(2, ("trusted Git launch failed: %s\n" % error).encode())
            finally:
                os._exit(127)

    os.close(stdout_write)
    os.close(stderr_write)
    os.close(ready_write)
    for descriptor in (stdout_read, stderr_read, ready_read):
        os.set_blocking(descriptor, False)
    selector = selectors.DefaultSelector()
    selector.register(stdout_read, selectors.EVENT_READ, "stdout")
    selector.register(stderr_read, selectors.EVENT_READ, "stderr")
    selector.register(ready_read, selectors.EVENT_READ, "ready")
    buffers = {"stdout": bytearray(), "stderr": bytearray()}
    limits = {"stdout": output_limit, "stderr": MAX_STDERR_BYTES}
    command_deadline = min(deadline, time.monotonic() + COMMAND_DEADLINE_SECONDS)
    status = None
    failure = None
    process_group_ready = False
    unexpected = None
    try:
        while selector.get_map() or status is None:
            if status is None and not selector.get_map():
                try:
                    waited, candidate_status = os.waitpid(pid, os.WNOHANG)
                except ChildProcessError:
                    failure = "trusted Git process could not be supervised"
                    break
                if waited == pid:
                    status = candidate_status
            remaining = command_deadline - time.monotonic()
            if remaining <= 0:
                failure = "trusted Git command exceeded its deadline"
                break
            if selector.get_map():
                events = selector.select(min(remaining, 0.05))
            else:
                time.sleep(min(remaining, 0.01))
                events = []
            for key, _mask in events:
                try:
                    chunk = os.read(key.fd, 65_536)
                except BlockingIOError:
                    continue
                if key.data == "ready":
                    selector.unregister(key.fd)
                    os.close(key.fd)
                    if chunk == b"1":
                        process_group_ready = True
                    else:
                        failure = "trusted Git process did not establish containment"
                    continue
                if not chunk:
                    selector.unregister(key.fd)
                    os.close(key.fd)
                    continue
                target = buffers[key.data]
                if len(target) + len(chunk) > limits[key.data]:
                    failure = "trusted Git output exceeded its byte limit"
                    break
                target.extend(chunk)
            if failure:
                break
    except BaseException as error:
        unexpected = error
    finally:
        status, cleanup_failure = _finish_child(
            pid,
            status,
            process_group_ready,
            terminate=failure is not None or unexpected is not None or status is None,
        )
        failure = failure or cleanup_failure
        for key in list(selector.get_map().values()):
            try:
                selector.unregister(key.fd)
                os.close(key.fd)
            except OSError:
                pass
        selector.close()
    if unexpected is not None:
        raise unexpected
    if failure:
        raise CheckFailure(failure)
    if status is None:
        raise CheckFailure("trusted Git process returned no terminal status")
    return_code = _decode_status(status)
    if return_code != 0:
        diagnostic = bytes(buffers["stderr"]).decode("utf-8", "replace").strip()
        raise CheckFailure(
            "trusted Git command failed"
            + ((": " + diagnostic) if diagnostic else "")
        )
    return bytes(buffers["stdout"])


def _parse_inventory(raw):
    if raw and not raw.endswith(b"\0"):
        raise CheckFailure("Git returned a malformed tracked-file inventory")
    records = raw[:-1].split(b"\0") if raw else []
    if len(records) > MAX_DOCUMENTS * 4:
        raise CheckFailure("tracked-file inventory exceeds its entry limit")
    documents = []
    for record in records:
        try:
            metadata, path = record.split(b"\t", 1)
            mode, object_id, stage = metadata.split(b" ")
        except ValueError as error:
            raise CheckFailure("Git returned a malformed index entry") from error
        if stage != b"0":
            raise CheckFailure("unmerged index entries cannot be validated")
        if not path.endswith(b".md") or path.startswith(EXCLUDED_PREFIXES):
            continue
        if len(path) > MAX_PATH_BYTES:
            raise CheckFailure("tracked documentation path exceeds its byte limit")
        if mode not in (b"100644", b"100755"):
            raise CheckFailure("tracked documentation must be a regular blob")
        if not re.fullmatch(rb"[0-9a-f]{40}|[0-9a-f]{64}", object_id):
            raise CheckFailure("Git returned an invalid documentation object ID")
        documents.append((path, object_id.decode("ascii")))
        if len(documents) > MAX_DOCUMENTS:
            raise CheckFailure(
                "first-party documentation exceeds the %d-file limit" % MAX_DOCUMENTS
            )
    return documents


def _verify_blob(object_id, body):
    algorithm = "sha1" if len(object_id) == 40 else "sha256"
    framed = b"blob " + str(len(body)).encode("ascii") + b"\0" + body
    actual = hashlib.new(algorithm, framed).hexdigest()
    if actual != object_id:
        raise CheckFailure("Git returned documentation bytes with the wrong object ID")


def _render_path(path):
    truncated = len(path) > 512
    rendered = repr(os.fsdecode(path[:512]))
    return rendered + ("..." if truncated else "")


def check_repository(repository):
    bound = RepositoryBinding(repository)
    deadline = time.monotonic() + GLOBAL_DEADLINE_SECONDS
    try:
        initial_inventory = _run_git(
            bound.git_fd,
            bound.index_fd,
            ["ls-files", "--stage", "-z"],
            MAX_INVENTORY_BYTES,
            deadline,
        )
        documents = _parse_inventory(initial_inventory)
        cache = {}
        total_bytes = 0
        findings = []
        finding_bytes = 0
        findings_truncated = False
        for path, object_id in documents:
            if object_id not in cache:
                body = _run_git(
                    bound.git_fd,
                    bound.index_fd,
                    ["cat-file", "blob", object_id],
                    MAX_DOCUMENT_BYTES + 1,
                    deadline,
                )
                if len(body) > MAX_DOCUMENT_BYTES:
                    raise CheckFailure(
                        "documentation blob exceeds the %d-byte limit"
                        % MAX_DOCUMENT_BYTES
                    )
                _verify_blob(object_id, body)
                cache[object_id] = body
            body = cache[object_id]
            rendered_path = _render_path(path)
            total_bytes += len(body)
            if total_bytes > MAX_TOTAL_DOCUMENT_BYTES:
                raise CheckFailure(
                    "documentation exceeds the aggregate byte limit"
                )
            for match in DEPRECATED_FIELD.finditer(body):
                line = body.count(b"\n", 0, match.start()) + 1
                diagnostic_size = len(rendered_path.encode("utf-8", "replace")) + 32
                if finding_bytes + diagnostic_size > MAX_DIAGNOSTIC_BYTES:
                    findings_truncated = True
                    break
                findings.append((rendered_path, line))
                finding_bytes += diagnostic_size
                if len(findings) >= MAX_DIAGNOSTICS:
                    findings_truncated = True
                    break
            if findings_truncated:
                break

        final_inventory = _run_git(
            bound.git_fd,
            bound.index_fd,
            ["ls-files", "--stage", "-z"],
            MAX_INVENTORY_BYTES,
            deadline,
        )
        if final_inventory != initial_inventory:
            raise CheckFailure("Git index changed during documentation validation")
        bound.revalidate()
        if not documents:
            print("check-doc-field-drift: no first-party docs to scan")
            return 0
        if findings:
            for path, line in findings:
                print("%s:%d: deprecated workflow field key" % (path, line))
            if findings_truncated:
                print("additional diagnostics omitted after the output limit")
            print(
                "ERROR: deprecated workflow field name(s) found in first-party docs.",
                file=sys.stderr,
            )
            print(
                "Use 'subject' instead of 'title' and 'blocked_by' instead of "
                "'depends_on'.",
                file=sys.stderr,
            )
            return 1
        print(
            "check-doc-field-drift: OK — no deprecated workflow field names "
            "in first-party docs"
        )
        return 0
    finally:
        bound.close()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo-root", required=True, type=Path)
    arguments = parser.parse_args()
    if not sys.flags.isolated or not sys.flags.no_site:
        print(
            "error: checker requires isolated Python with site loading disabled",
            file=sys.stderr,
        )
        return 2
    try:
        return check_repository(arguments.repo_root)
    except CheckFailure as error:
        print("error: %s" % error, file=sys.stderr)
        return 2
    except OSError as error:
        if error.errno in (errno.ELOOP, errno.ENOTDIR):
            print("error: repository path is not a direct directory", file=sys.stderr)
        else:
            print("error: documentation validation failed: %s" % error, file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
