"""Retain the trusted Git/index boundary used by staged-blob validators."""

import hashlib
import os
from pathlib import Path
import resource
import selectors
import signal
import stat
import sys
import tempfile
import time


GIT = "/usr/bin/git"
COMMAND_DEADLINE_SECONDS = 5.0
MAX_STDERR_BYTES = 64 * 1024
MAX_GIT_POINTER_BYTES = 8 * 1024
MAX_INDEX_BYTES = 16 * 1024 * 1024


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
    if process_group_ready and _process_group_exists(pid):
        group_deadline = time.monotonic() + 1.0
        while _process_group_exists(pid):
            _signal_containment(pid, True)
            if time.monotonic() >= group_deadline:
                break
            time.sleep(0.01)
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
        raise CheckFailure("trusted Git command failed with status %d" % return_code)
    return bytes(buffers["stdout"])


def _run_git_to_fd(
    git_fd,
    index_fd,
    arguments,
    output_fd,
    output_limit,
    deadline,
):
    """Run fixed Git and stream stdout to a caller-owned file descriptor."""
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
            for descriptor in (
                stdout_read,
                stdout_write,
                stderr_read,
                stderr_write,
                output_fd,
            ):
                if descriptor not in (1, 2, index_fd):
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
    stderr = bytearray()
    command_deadline = min(deadline, time.monotonic() + COMMAND_DEADLINE_SECONDS)
    status = None
    failure = None
    process_group_ready = False
    unexpected = None
    stdout_bytes = 0
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
                if key.data == "stdout":
                    if stdout_bytes + len(chunk) > output_limit:
                        failure = "trusted Git stdout exceeded its exact byte limit"
                        break
                    view = memoryview(chunk)
                    while view:
                        written = os.write(output_fd, view)
                        if written <= 0:
                            raise OSError("could not spool trusted Git output")
                        view = view[written:]
                    stdout_bytes += len(chunk)
                else:
                    if len(stderr) + len(chunk) > MAX_STDERR_BYTES:
                        failure = "trusted Git stderr exceeded its byte limit"
                        break
                    stderr.extend(chunk)
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
        raise CheckFailure("trusted Git command failed with status %d" % return_code)
    return stdout_bytes


def _verify_blob(object_id, body):
    algorithm = "sha1" if len(object_id) == 40 else "sha256"
    framed = b"blob " + str(len(body)).encode("ascii") + b"\0" + body
    actual = hashlib.new(algorithm, framed).hexdigest()
    if actual != object_id:
        raise CheckFailure("Git returned blob bytes with the wrong object ID")


def _self_test_runner_descendant(runner_name):
    global GIT, _apply_git_resource_limits

    with tempfile.TemporaryDirectory() as directory:
        fake_git = Path(directory) / "git-descendant-fixture"
        fake_git.write_text(
            "#!%s -IB\n" % sys.executable
            + """import os
import signal
import sys

marker = "--descendant-pid-fd"
pid_descriptor = int(sys.argv[sys.argv.index(marker) + 1])
ready_read, ready_write = os.pipe()
descendant = os.fork()
if descendant == 0:
    os.close(ready_read)
    for descriptor in range(256):
        if descriptor == ready_write:
            continue
        try:
            os.close(descriptor)
        except OSError:
            pass
    os.write(ready_write, b"1")
    os.close(ready_write)
    while True:
        signal.pause()

os.close(ready_write)
if os.read(ready_read, 1) != b"1":
    os._exit(2)
os.close(ready_read)
os.write(
    pid_descriptor,
    ("%d %d\\n" % (os.getpid(), descendant)).encode("ascii"),
)
os.close(pid_descriptor)
os._exit(0)
""",
            encoding="utf-8",
        )
        fake_git.chmod(0o700)
        directory_fd = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
        pid_read, pid_write = os.pipe()
        os.set_inheritable(pid_write, True)
        index = tempfile.TemporaryFile()
        original_git = GIT
        original_limits = _apply_git_resource_limits
        failure = None
        try:
            GIT = os.fspath(fake_git)
            _apply_git_resource_limits = lambda: None
            arguments = ["--descendant-pid-fd", str(pid_write)]
            deadline = time.monotonic() + 4.0
            try:
                if runner_name == "_run_git":
                    _run_git(
                        directory_fd,
                        index.fileno(),
                        arguments,
                        64,
                        deadline,
                    )
                else:
                    with tempfile.TemporaryFile() as output:
                        _run_git_to_fd(
                            directory_fd,
                            index.fileno(),
                            arguments,
                            output.fileno(),
                            64,
                            deadline,
                        )
            except CheckFailure as error:
                failure = str(error)
        finally:
            GIT = original_git
            _apply_git_resource_limits = original_limits
            os.close(pid_write)
            os.close(directory_fd)
            index.close()

        record = os.read(pid_read, 128)
        os.close(pid_read)
        try:
            group_pid, descendant_pid = (
                int(item) for item in record.decode("ascii").split()
            )
        except (UnicodeError, ValueError):
            return (
                False,
                "fixture_identity=missing; runner_failure=%s"
                % (failure or "none"),
            )

        extinct_on_return = not _process_group_exists(group_pid)
        if not extinct_on_return:
            _signal_containment(group_pid, True)
        try:
            os.kill(descendant_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        cleanup_deadline = time.monotonic() + 2.0
        while (
            _process_group_exists(group_pid)
            and time.monotonic() < cleanup_deadline
        ):
            time.sleep(0.01)
        runner_rejected = failure is not None and "process group" in failure
        cleanup_extinct = not _process_group_exists(group_pid)
        return (
            runner_rejected and extinct_on_return and cleanup_extinct,
            "runner_rejected=%s; group_extinct_on_return=%s; "
            "cleanup_extinct=%s"
            % (runner_rejected, extinct_on_return, cleanup_extinct),
        )


def _self_test():
    cases = (
        (
            "buffered_git_runner_extinguishes_successful_leader_descendant",
            "_run_git",
        ),
        (
            "streaming_git_runner_extinguishes_successful_leader_descendant",
            "_run_git_to_fd",
        ),
    )
    failures = 0
    for name, runner_name in cases:
        passed, detail = _self_test_runner_descendant(runner_name)
        print(
            "  [%s] %s%s"
            % (
                "PASS" if passed else "FAIL",
                name,
                "" if passed else " (" + detail + ")",
            )
        )
        failures += int(not passed)
    if failures:
        print("SELF-TEST FAILED: %d/%d cases failed." % (failures, len(cases)))
        return 1
    print("SELF-TEST OK: %d/%d cases passed." % (len(cases), len(cases)))
    return 0


if __name__ == "__main__" and sys.argv[1:] == ["--self-test"]:
    raise SystemExit(_self_test())
