"""Exact-pin, read-only Athena evidence adapter for legacy myrmidon shipping."""

from __future__ import annotations

import base64
import array
from contextlib import contextmanager
import contextvars
import ctypes
import errno
import hashlib
import json
import math
import os
import re
import resource
import select
import signal
import socket
import stat
import struct
import subprocess
import sys
import sysconfig
import tempfile
import threading
import time
import traceback
from typing import Callable


MAX_INPUT_BYTES = 1024 * 1024
MAX_OUTPUT_BYTES = 16 * 1024 * 1024
MAX_STDERR_BYTES = 64 * 1024
MAX_RULE_PAGES = 100
MAX_RULES_PER_PAGE = 100
MAX_CHECK_RUNS = 10_000
MAX_JSON_DEPTH = 64
MAX_JSON_NODES = 100_000
MAX_JSON_STRING_BYTES = 1024 * 1024
MAX_JSON_TOTAL_STRING_BYTES = 8 * 1024 * 1024
MAX_JSON_NUMBER_CHARACTERS = 128
COMMAND_TIMEOUT_SECONDS = 180.0
CHAIN_CLEANUP_RESERVE_SECONDS = 5.0
PROCESS_TERMINATE_SECONDS = 0.5
PROCESS_REAP_SECONDS = 2.0
PROCESS_POLL_SECONDS = 0.01
READ_CHUNK_BYTES = 64 * 1024
PROCESS_STATUS_BYTES = 5
PROCESS_ACQUISITION_BYTES = 5
MAX_VERIFIED_ADAPTER_BYTES = 1024 * 1024
MAX_BOUND_EXECUTABLE_BYTES = 256 * 1024 * 1024
MAX_BOUNDED_PROCESS_OUTPUT_BYTES = 64 * 1024 * 1024
MAX_BOUNDED_PROCESS_TIMEOUT_SECONDS = 24 * 60 * 60.0
MAX_CONTAINER_INPUT_BYTES = 16 * 1024 * 1024
MAX_CONTAINER_STDERR_BYTES = 1024 * 1024
MAX_CONTAINER_REQUEST_BYTES = 128 * 1024 * 1024
PROCESS_MAX_ADDRESS_SPACE_BYTES = 2 * 1024 * 1024 * 1024
HEX_40 = re.compile(r"[0-9a-f]{40}")
HEX_64 = re.compile(r"[0-9a-f]{64}")
REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
OCI_DIGEST_REFERENCE = re.compile(
    r"[a-z0-9]+(?:[._:/-][a-z0-9]+)*@sha256:[0-9a-f]{64}"
)
OCI_IMAGE_ID = re.compile(r"sha256:[0-9a-f]{64}")
_GH_EXECUTABLE_CANDIDATES = (
    "/usr/bin/gh",
    "/usr/local/bin/gh",
    "/opt/homebrew/bin/gh",
)
_GIT_EXECUTABLE_CANDIDATES = (
    "/usr/bin/git",
    "/usr/local/bin/git",
    "/opt/homebrew/bin/git",
)
_GIT_EXEC_PATH_CANDIDATES = (
    "/usr/lib/git-core",
    "/usr/libexec/git-core",
    "/usr/local/libexec/git-core",
)
RUNTIME_PATH = "/usr/sbin:/usr/bin:/sbin:/bin"
_CONTAINER_RUNTIME_CANDIDATES = {
    "podman": (
        "/usr/bin/podman",
        "/usr/local/bin/podman",
        "/opt/homebrew/bin/podman",
    ),
    "docker": (
        "/usr/bin/docker",
        "/usr/local/bin/docker",
        "/opt/homebrew/bin/docker",
    ),
}
ATHENA_RELEASE_VERSION = "0.5.3"
ATHENA_RELEASE_COMMIT = "8c72148529a38efb4dd97e8e78c1b2193d852403"
ATHENA_RELEASE_SOURCE = "https://github.com/HomericIntelligence/Athena.git"
PLUGIN_MANIFEST = ".codex-plugin/plugin.json"
INSTALL_MANIFEST = ".codex-marketplace-install.json"
PLUGIN_MANIFEST_SHA256 = (
    "dd4c5f7eccbc919d34936f8514ba0de5acf37f46ab3432a7058b2750dab319f5"
)
INSTALL_MANIFEST_SHA256 = (
    "1d1d0d693dc4b93b688ebb6463a636fa5008d52703f4616661373d86b4d1eead"
)
HELPER_SHA256 = {
    "skills/pr-review/scripts/resolve_pr.py": (
        "978b71a2c79b1fe4a66489c899876403d7ef3d79b589f9128499772e97cb5222"
    ),
    "skills/pr-review/scripts/collect_evidence.py": (
        "961f1af29296763fb1f0297d9dcf873001f0008a93dfcd4a2bf2044c049777a0"
    ),
    "skills/pr-review/scripts/deliver_go.py": (
        "6c12b7c953980ec703e154d8f98989fb2fb1d155f61584768f0ad70c174cfa06"
    ),
    "skills/pr-review/scripts/anchor_proofs.py": (
        "388b1d167bc3eb44ffcd07cc50ec0f6f19f0e6ab4f309d3bd8d0c0c8491975d1"
    ),
    "skills/pr-review/scripts/pr_identity.py": (
        "274f6fff920f5a8d970a8018e3c8cee7d93af26e9aea3fa869e78cbeb32a5a3a"
    ),
    "skills/pr-review/scripts/materialize_snapshot.py": (
        "f560d2ef785bb1a8fd604373e65268cdfaeb1d3360778dfe73bc83dce45e37f2"
    ),
    "skills/review-exchange/scripts/review_exchange.py": (
        "7f6db45e9d4e9364441c0ac8f3c9ab303b165fd9ac8cd54fbdca6585dad0d693"
    ),
    "skills/_cli.py": (
        "80e6189d94f7e7f0d7cc32d57d3e0d1cb11093fb2aed30209624c5939cf2d7d9"
    ),
}
PLUGIN_COMMANDS = frozenset({
    "skills/pr-review/scripts/collect_evidence.py",
    "skills/review-exchange/scripts/review_exchange.py",
})
CHAIN_COMMAND = "e2e/athena_readonly_chain.py"
CHAIN_ADAPTER_SHA256 = (
    "a02b63ed2fbde333d69b16105ed0c750d4decbbd9e4a72eba0209021109a69ad"
)
RULES_COMMAND = "github/effective-branch-rules"
BRANCH_PROTECTION_COMMAND = "github/branch-protection"
CHECK_RUNS_COMMAND = "github/head-check-runs"
MERGE_READINESS_COMMAND = "github/pr-merge-readiness"
GITHUB_CREDENTIAL_VARIABLES = (
    "GH_TOKEN",
    "GITHUB_TOKEN",
    "GH_ENTERPRISE_TOKEN",
    "GITHUB_ENTERPRISE_TOKEN",
)
_ACTIVE_EVIDENCE_DEADLINE: contextvars.ContextVar[float | None] = (
    contextvars.ContextVar("odysseus_athena_evidence_deadline", default=None)
)

# This program executes only trusted container clients. Container workloads do
# not inherit its control channel, mount namespace handles, or runtime FD.
_ENDPOINT_BROKER = r'''
import array, ctypes, fcntl, json, math, os, re, select, selectors
import signal, socket, stat, struct, subprocess, sys, time

channel = socket.socket(fileno=int(sys.argv[1]))
socket_fd = int(sys.argv[2])
MAX_REQUEST = 128 * 1024 * 1024
MAX_INPUT = 16 * 1024 * 1024
MAX_OUTPUT = 16 * 1024 * 1024
MAX_ERROR = 1024 * 1024
libc = ctypes.CDLL(None, use_errno=True)

def check(result):
    if result != 0:
        raise OSError(ctypes.get_errno(), "endpoint containment setup failed")

def write_mapping(path, value):
    with open(path, "w", encoding="ascii") as stream:
        stream.write(value)

uid, gid = os.geteuid(), os.getegid()
check(libc.unshare(0x10000000 | 0x00020000))
write_mapping("/proc/self/setgroups", "deny")
write_mapping("/proc/self/uid_map", f"0 {uid} 1\n")
write_mapping("/proc/self/gid_map", f"0 {gid} 1\n")
check(libc.prctl(4, 0, 0, 0, 0))  # PR_SET_DUMPABLE
check(libc.prctl(36, 1, 0, 0, 0))  # PR_SET_CHILD_SUBREAPER
check(libc.prctl(38, 1, 0, 0, 0))  # PR_SET_NO_NEW_PRIVS
libc.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
                       ctypes.c_ulong, ctypes.c_void_p]
check(libc.mount(None, b"/", None, 0x4000 | 0x40000, None))
check(libc.mount(b"tmpfs", b"/tmp", b"tmpfs", 2 | 4 | 8,
                 b"mode=0700,size=16777216"))
endpoint = "/tmp/endpoint.sock"
fd = os.open(endpoint, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
os.close(fd)
source = os.fstat(socket_fd)
check(libc.mount(f"/proc/self/fd/{socket_fd}".encode(), endpoint.encode(),
                 None, 0x1000, None))
bound = os.stat(endpoint, follow_symlinks=False)
if not stat.S_ISSOCK(bound.st_mode) or (source.st_dev, source.st_ino) != (bound.st_dev, bound.st_ino):
    raise RuntimeError("endpoint mount does not retain the acquired socket")
with open("/proc/self/mountinfo", "rb") as stream:
    mounts = stream.read(1048577)
if len(mounts) > 1048576 or not any(line.split()[4] == endpoint.encode() for line in mounts.splitlines()):
    raise RuntimeError("endpoint mount cannot be verified")
os.close(socket_fd)
os.mkdir("/tmp/home", 0o700)
os.mkdir("/tmp/home/docker", 0o700)
with open("/tmp/home/connections.json", "x", encoding="ascii") as stream:
    stream.write("{}\n")
environment = {
    "HOME": "/tmp/home", "XDG_CONFIG_HOME": "/tmp/home",
    "DOCKER_CONFIG": "/tmp/home/docker",
    "PODMAN_CONNECTIONS_CONF": "/tmp/home/connections.json",
    "CONTAINER_HOST": "unix://" + endpoint, "DOCKER_HOST": "unix://" + endpoint,
    "PATH": "/usr/sbin:/usr/bin:/sbin:/bin", "LANG": "C", "LC_ALL": "C",
    "TMPDIR": "/tmp",
}

def remaining(deadline):
    value = deadline - time.monotonic()
    if value <= 0:
        raise TimeoutError("endpoint command deadline expired")
    return value

def children():
    result = set()
    tasks = os.listdir("/proc/self/task")
    if len(tasks) > 4096:
        raise RuntimeError("broker task inventory exceeded its bound")
    for task in tasks:
        try:
            with open(f"/proc/self/task/{task}/children", "rb") as stream:
                data = stream.read(1048577)
        except FileNotFoundError:
            continue
        if len(data) > 1048576:
            raise RuntimeError("broker child inventory exceeded its bound")
        result.update(int(value) for value in data.split())
    return result

def extinguish(deadline):
    # As a subreaper, killing each generation adopts the next generation.
    # pidfds are acquired for unreaped children; no numeric signal follows reap.
    while True:
        owned = children()
        if not owned:
            return
        for pid in owned:
            try:
                descriptor = os.pidfd_open(pid, 0)
            except ProcessLookupError:
                continue
            try:
                try:
                    signal.pidfd_send_signal(descriptor, signal.SIGKILL, None, 0)
                except ProcessLookupError:
                    pass
                if select.select([descriptor], [], [], 0)[0]:
                    os.waitpid(pid, os.WNOHANG)
            finally:
                os.close(descriptor)
        remaining(deadline)
        time.sleep(0.005)

def run(descriptors, references, arguments, input_text, deadline):
    runtime_fd = descriptors[0]
    for original, retained in zip(references, descriptors[1:]):
        if not stat.S_ISDIR(os.fstat(retained).st_mode):
            raise ValueError("retained command reference is not a directory")
        pattern = rf"/proc/{os.getppid()}/fd/{original}(?=/|:|$)"
        # --cidfile is opened by the client in this namespace. Volume sources
        # are opened by the external daemon and retain the parent's authority;
        # a rootless daemon cannot traverse this nondumpable broker's /proc.
        arguments = [
            re.sub(pattern, f"/proc/self/fd/{retained}", value)
            if index and arguments[index - 1] == "--cidfile" else value
            for index, value in enumerate(arguments)
        ]
    required = fcntl.F_SEAL_WRITE | fcntl.F_SEAL_GROW | fcntl.F_SEAL_SHRINK | fcntl.F_SEAL_SEAL
    metadata = os.fstat(runtime_fd)
    if (not stat.S_ISREG(metadata.st_mode) or not metadata.st_mode & 0o111
            or not 0 < metadata.st_size <= 256 * 1024 * 1024
            or fcntl.fcntl(runtime_fd, fcntl.F_GET_SEALS) & required != required):
        raise ValueError("runtime is not one sealed executable")
    process = None
    selector = selectors.DefaultSelector()
    outputs = [bytearray(), bytearray()]
    pending = memoryview(input_text.encode("utf-8") if input_text is not None else b"")
    try:
        process = subprocess.Popen(
            [f"/proc/self/fd/{runtime_fd}", *arguments],
            stdin=subprocess.PIPE if pending else subprocess.DEVNULL,
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            env=environment, close_fds=True, pass_fds=tuple(descriptors),
            start_new_session=True,
        )
        for index, stream in enumerate((process.stdout, process.stderr)):
            os.set_blocking(stream.fileno(), False)
            selector.register(stream, selectors.EVENT_READ, index)
        if pending:
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, 2)
        while selector.get_map():
            for key, _ in selector.select(min(remaining(deadline), 0.05)):
                if key.data == 2:
                    try:
                        pending = pending[os.write(key.fd, pending[:65536]):]
                    except BrokenPipeError:
                        pending = memoryview(b"")
                    except BlockingIOError:
                        continue
                    if not pending:
                        selector.unregister(key.fileobj)
                        key.fileobj.close()
                    continue
                try:
                    chunk = os.read(key.fd, 65536)
                except BlockingIOError:
                    continue
                if not chunk:
                    selector.unregister(key.fileobj)
                    continue
                outputs[key.data].extend(chunk)
                if len(outputs[key.data]) > (MAX_OUTPUT if key.data == 0 else MAX_ERROR):
                    raise RuntimeError("container command exceeded its output bound")
        code = process.wait(timeout=remaining(deadline))
        extinguish(time.monotonic() + 2)
        return code, bytes(outputs[0]), bytes(outputs[1])
    finally:
        selector.close()
        if process is not None:
            # A completed leader may leave reparented, detached descendants.
            extinguish(time.monotonic() + 2)
            process.wait(timeout=1)
            for stream in (process.stdin, process.stdout, process.stderr):
                if stream is not None:
                    stream.close()

def send(payload, deadline):
    view = memoryview(struct.pack("!I", len(payload)) + payload)
    while view:
        channel.settimeout(remaining(deadline))
        count = channel.send(view)
        if count <= 0:
            raise EOFError("broker parent channel closed")
        view = view[count:]

def receive(size, deadline):
    output = bytearray()
    while len(output) < size:
        channel.settimeout(remaining(deadline))
        chunk = channel.recv(size - len(output))
        if not chunk:
            raise EOFError("broker parent channel closed")
        output.extend(chunk)
    return bytes(output)

def unique(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate request key")
        result[key] = value
    return result

send(b"ready", time.monotonic() + 5)
try:
    while True:
        channel.settimeout(None)
        header, ancillary, flags, _ = channel.recvmsg(4, socket.CMSG_SPACE(33 * 4))
        descriptors = []
        try:
            for level, kind, data in ancillary:
                if level != socket.SOL_SOCKET or kind != socket.SCM_RIGHTS or len(data) % 4:
                    raise ValueError("invalid command authority")
                values = array.array("i")
                values.frombytes(data)
                descriptors.extend(values)
            if not header:
                break
            if flags & (socket.MSG_CTRUNC | socket.MSG_TRUNC):
                raise ValueError("truncated command authority")
            deadline = time.monotonic() + 5
            header += receive(4 - len(header), deadline)
            size = struct.unpack("!I", header)[0]
            if not 0 < size <= MAX_REQUEST:
                raise ValueError("request exceeded its bound")
            request = json.loads(receive(size, deadline).decode("utf-8"), object_pairs_hook=unique)
            if not isinstance(request, dict):
                raise ValueError("invalid command request")
            if request == {"operation": "close"} and not descriptors:
                extinguish(time.monotonic() + 2)
                send(b"closed", time.monotonic() + 2)
                break
            if set(request) != {"operation", "arguments", "input", "deadline", "references"} or request["operation"] != "run":
                raise ValueError("invalid command request")
            references = request["references"]
            if (not isinstance(references, list) or len(references) > 32
                    or any(type(value) is not int or value < 0 for value in references)
                    or len(set(references)) != len(references)
                    or len(descriptors) != 1 + len(references)):
                raise ValueError("invalid command references")
            arguments, input_text, deadline = request["arguments"], request["input"], request["deadline"]
            if (not isinstance(arguments, list) or not 1 <= len(arguments) <= 4096
                    or any(not isinstance(value, str) or "\0" in value or len(value.encode("utf-8")) > 131072 for value in arguments)
                    or sum(len(value.encode("utf-8")) for value in arguments) > 1048576
                    or (input_text is not None and (not isinstance(input_text, str) or len(input_text.encode("utf-8")) > MAX_INPUT))
                    or isinstance(deadline, bool) or not isinstance(deadline, (int, float))
                    or not math.isfinite(deadline) or not 0 < remaining(deadline) <= 86400):
                raise ValueError("invalid command bounds")
            code, stdout, stderr = run(descriptors, references, arguments, input_text, deadline)
            send(struct.pack("!iII", code, len(stdout), len(stderr)) + stdout + stderr,
                 time.monotonic() + 2)
        finally:
            for descriptor in descriptors:
                os.close(descriptor)
finally:
    extinguish(time.monotonic() + 2)
    channel.close()
'''

_PROCESS_SUPERVISOR = """
import ctypes
import os
import resource
import select
import signal
import struct
import subprocess
import sys
import time
import traceback

quota_gate = os.environ.pop("ODYSSEUS_QUOTA_GATE_FD", "")
if quota_gate:
    descriptor = int(quota_gate)
    try:
        if os.read(descriptor, 1) != b"1":
            raise SystemExit("aggregate quota admission failed")
    finally:
        os.close(descriptor)

status_descriptor = int(sys.argv[1])
acquisition_descriptor = int(sys.argv[2])
inherited_descriptors = tuple(
    int(value) for value in sys.argv[3].split(",") if value
)
target_executable = sys.argv[4] or None
target_cwd = sys.argv[5] or None
target_returncode = 125
detached_descendant = False
stop_requested = [False]

def request_stop(_signum, _frame):
    stop_requested[0] = True

for signal_number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
    signal.signal(signal_number, request_stop)
if hasattr(signal, "pthread_sigmask"):
    signal.pthread_sigmask(signal.SIG_SETMASK, set())

def bounded_limit(kind, ceiling):
    soft, hard = resource.getrlimit(kind)
    bounded_hard = ceiling if hard == resource.RLIM_INFINITY else min(hard, ceiling)
    bounded_soft = bounded_hard if soft == resource.RLIM_INFINITY else min(soft, bounded_hard)
    resource.setrlimit(kind, (bounded_soft, bounded_hard))

def write_mapping(path, value):
    descriptor = os.open(path, os.O_WRONLY | getattr(os, "O_CLOEXEC", 0))
    try:
        payload = value.encode("ascii")
        if os.write(descriptor, payload) != len(payload):
            raise RuntimeError("namespace identity mapping is incomplete")
    finally:
        os.close(descriptor)

def enter_linux_namespaces():
    if not sys.platform.startswith("linux"):
        return False
    if not callable(getattr(os, "pidfd_open", None)) or not callable(
        getattr(signal, "pidfd_send_signal", None)
    ):
        raise RuntimeError("Linux PID-namespace containment is unavailable")
    outer_uid = os.geteuid()
    outer_gid = os.getegid()
    if outer_uid == 0 or outer_gid == 0:
        raise RuntimeError("separate target authority is unavailable for host root")
    library = ctypes.CDLL(None, use_errno=True)
    unshare = getattr(library, "unshare", None)
    if unshare is None:
        raise RuntimeError("Linux namespace containment is unavailable")
    unshare.argtypes = [ctypes.c_int]
    unshare.restype = ctypes.c_int
    clone_newuser = 0x10000000
    clone_newns = 0x00020000
    clone_newpid = 0x20000000
    ctypes.set_errno(0)
    if unshare(clone_newuser) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not create user namespace")
    try:
        write_mapping("/proc/self/setgroups", "deny\\n")
    except FileNotFoundError:
        pass
    write_mapping("/proc/self/uid_map", f"1 {outer_uid} 1\\n")
    write_mapping("/proc/self/gid_map", f"1 {outer_gid} 1\\n")
    ctypes.set_errno(0)
    clone_newcgroup = 0x02000000 if quota_gate else 0
    if unshare(clone_newns | clone_newpid | clone_newcgroup) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not create PID namespace")
    return True

def mount_private_proc():
    library = ctypes.CDLL(None, use_errno=True)
    mount = getattr(library, "mount", None)
    if mount is None:
        raise RuntimeError("Linux mount containment is unavailable")
    mount.argtypes = [
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_char_p,
        ctypes.c_ulong,
        ctypes.c_void_p,
    ]
    mount.restype = ctypes.c_int
    mount_private = 1 << 18
    mount_recursive = 16384
    if mount(None, b"/", None, mount_private | mount_recursive, None) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not privatize mounts")
    mount_flags = 2 | 4 | 8
    if mount(b"proc", b"/proc", b"proc", mount_flags, None) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not mount private procfs")
    if quota_gate and mount(
        b"tmpfs", b"/sys/fs/cgroup", b"tmpfs", mount_flags | 1,
        ctypes.c_char_p(b"mode=000,size=4096"),
    ) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not hide quota authority")

def lock_target_privileges():
    library = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(library, "prctl", None)
    if prctl is None:
        raise RuntimeError("Linux target privilege isolation is unavailable")
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    pr_set_no_new_privs = 38
    if prctl(pr_set_no_new_privs, 1, 0, 0, 0) != 0:
        raise OSError(ctypes.get_errno() or 1, "could not lock target privileges")

def namespace_init(ready_descriptor, result_descriptor):
    target = None
    try:
        for number in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
            signal.signal(number, lambda _signum, _frame: None)
        mount_private_proc()
        lock_target_privileges()
        target = subprocess.Popen(
            sys.argv[8:], executable=target_executable,
            pass_fds=inherited_descriptors, cwd=target_cwd
        )
        os.write(ready_descriptor, b"1")
        os.close(ready_descriptor)
        returncode = target.wait()
        remaining = {
            entry.name for entry in os.scandir("/proc")
            if entry.name.isdecimal() and int(entry.name) > 1
        }
        detached = bool(remaining)
        os.write(result_descriptor, struct.pack("!iB", returncode, int(detached)))
    except BaseException:
        try:
            os.write(ready_descriptor, b"0")
        except OSError:
            pass
        traceback.print_exc()
    finally:
        for descriptor in (ready_descriptor, result_descriptor):
            try:
                os.close(descriptor)
            except OSError:
                pass
        os._exit(0 if target is not None else 125)

def run_linux_target():
    if not enter_linux_namespaces():
        raise RuntimeError("PID-namespace containment is unavailable")
    process_count = 0
    for entry in os.scandir("/proc"):
        if not entry.name.isdecimal():
            continue
        try:
            same_identity = (
                entry.stat(follow_symlinks=False).st_uid == os.geteuid()
            )
        except (FileNotFoundError, PermissionError, ProcessLookupError):
            continue
        process_count += int(same_identity)
    if not quota_gate:
        bounded_limit(resource.RLIMIT_NPROC, process_count + 16)
    ready_read, ready_write = os.pipe()
    result_read, result_write = os.pipe()
    namespace_process_id = os.fork()
    if namespace_process_id == 0:
        # Only the outer supervisor may publish host-visible acquisition and
        # terminal status.  Closing its control descriptors before entering
        # the target namespace prevents a target from reopening them through
        # /proc/1/fd and forging a parent-owned authority receipt.
        os.close(acquisition_descriptor)
        os.close(status_descriptor)
        os.close(ready_read)
        os.close(result_read)
        namespace_init(ready_write, result_write)
    os.close(ready_write)
    os.close(result_write)
    namespace_descriptor = os.pidfd_open(namespace_process_id, 0)
    ready = os.read(ready_read, 1)
    os.close(ready_read)
    if ready != b"1":
        raise RuntimeError("the contained target did not become ready")
    os.write(acquisition_descriptor, struct.pack("!BI", 1, namespace_process_id))
    os.close(acquisition_descriptor)
    while True:
        reaped, wait_status = os.waitpid(namespace_process_id, os.WNOHANG)
        if reaped == namespace_process_id:
            break
        if stop_requested[0]:
            signal.pidfd_send_signal(namespace_descriptor, signal.SIGKILL, None, 0)
        time.sleep(0.005)
    readable, _writable, _exceptional = select.select(
        [namespace_descriptor], [], [], 0
    )
    if not readable:
        raise RuntimeError("the PID namespace did not become extinct")
    os.close(namespace_descriptor)
    result = b""
    while len(result) < 5:
        block = os.read(result_read, 5 - len(result))
        if not block:
            break
        result += block
    os.close(result_read)
    if len(result) == 5:
        return struct.unpack("!iB", result)
    if os.waitstatus_to_exitcode(wait_status) != 0:
        raise RuntimeError("the PID namespace exited without target status")
    return 125, 0

try:
    address_space = int(sys.argv[6])
    cpu_seconds = int(sys.argv[7])
    bounded_limit(resource.RLIMIT_AS, address_space)
    resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
    bounded_limit(resource.RLIMIT_CPU, cpu_seconds)
    if sys.platform.startswith("linux"):
        target_returncode, detached = run_linux_target()
        acquisition_descriptor = -1
        detached_descendant = bool(detached)
    else:
        target = subprocess.Popen(
            sys.argv[8:], executable=target_executable,
            pass_fds=inherited_descriptors, cwd=target_cwd
        )
        os.write(acquisition_descriptor, struct.pack("!BI", 1, target.pid))
        os.close(acquisition_descriptor)
        acquisition_descriptor = -1
        target_returncode = target.wait()
except BaseException:
    try:
        os.write(acquisition_descriptor, struct.pack("!BI", 0, 0))
    except OSError:
        pass
    traceback.print_exc()
    target_returncode = 125
if acquisition_descriptor >= 0:
    os.close(acquisition_descriptor)
os.write(
    status_descriptor,
    struct.pack("!iB", target_returncode, int(detached_descendant)),
)
os.close(status_descriptor)
os.close(1)
os.close(2)
"""

_VERIFIED_SOURCE_RUNNER = """
import base64
import binascii
import sys

try:
    payload = base64.b64decode(sys.argv[1].encode("ascii"), validate=True)
except (UnicodeError, binascii.Error, ValueError):
    raise SystemExit("verified source payload is malformed")
filename = sys.argv[2]
sys.argv = [filename, *sys.argv[3:]]
namespace = {
    "__builtins__": __builtins__,
    "__file__": filename,
    "__name__": "__main__",
    "__package__": None,
}
exec(compile(payload, filename, "exec"), namespace, namespace)
"""


class AthenaEvidenceError(RuntimeError):
    """Athena evidence is missing, stale, ambiguous, or unsafe."""


class _AggregateQuota:
    """Parent-held cgroup v2 authority for one complete helper process tree.

    The service must have memory/cpu/pids controllers delegated to its current
    cgroup (or an explicit ODYSSEUS_CGROUP_ROOT). No controller is enabled or
    ancestor limit changed by this adapter. Targets receive no cgroup descriptor.
    """

    def __init__(self) -> None:
        self.parent = self.descriptor = -1
        self.name = "odysseus-athena-" + os.urandom(16).hex()
        if sys.platform != "linux":
            raise AthenaEvidenceError(
                "credential-bearing descendant containment and aggregate quota require Linux cgroup v2"
            )
        try:
            with open("/proc/self/mountinfo", encoding="ascii") as source:
                mountinfo = source.read(256 * 1024 + 1)
            cgroups = []
            for line in mountinfo.splitlines():
                before, separator, after = line.partition(" - ")
                fields, filesystem = before.split(), after.split()
                if separator and filesystem and filesystem[0] == "cgroup2":
                    cgroups.append((fields, filesystem))
            if (len(mountinfo) > 256 * 1024 or len(cgroups) != 1
                    or len(cgroups[0][0]) < 6 or len(cgroups[0][1]) != 3
                    or cgroups[0][0][3:5] != ["/", "/sys/fs/cgroup"]
                    or "nsdelegate" not in cgroups[0][1][2].split(",")):
                raise AthenaEvidenceError(
                    "aggregate quota requires one canonical nsdelegate cgroup v2 mount"
                )
            root = os.environ.get("ODYSSEUS_CGROUP_ROOT")
            if root is None:
                with open("/proc/self/cgroup", encoding="ascii") as source:
                    membership = source.read(4097)
                lines = membership.splitlines()
                if len(lines) != 1 or not lines[0].startswith("0::/") or len(membership) > 4096:
                    raise AthenaEvidenceError("aggregate cgroup membership is unproven")
                root = "/sys/fs/cgroup" + lines[0][3:].rstrip("/")
            if (not isinstance(root, str) or os.path.normpath(root) != root
                    or not (root == "/sys/fs/cgroup" or root.startswith("/sys/fs/cgroup/"))):
                raise AthenaEvidenceError("aggregate cgroup root is not canonical")
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
            self.parent = os.open("/", flags)
            for component in root.split("/")[1:]:
                child = os.open(component, flags, dir_fd=self.parent)
                os.close(self.parent)
                self.parent = child
            filesystem = ctypes.create_string_buffer(256)
            libc = ctypes.CDLL(None, use_errno=True)
            if (libc.fstatfs(self.parent, ctypes.byref(filesystem)) != 0
                    or ctypes.c_long.from_buffer(filesystem).value != 0x63677270):
                raise AthenaEvidenceError("aggregate quota root is not cgroup v2")
            controllers = self._read("cgroup.subtree_control", self.parent).split()
            if not {"cpu", "memory", "pids"}.issubset(controllers):
                raise AthenaEvidenceError("aggregate cgroup controllers are not delegated")
            os.mkdir(self.name, 0o700, dir_fd=self.parent)
            self.descriptor = os.open(self.name, flags, dir_fd=self.parent)
            self.identity = os.fstat(self.descriptor)
            self._verify()
            for name, value in (
                ("memory.max", str(PROCESS_MAX_ADDRESS_SPACE_BYTES)),
                ("memory.swap.max", "0"),
                ("memory.oom.group", "1"),
                ("pids.max", "32"),
                ("cpu.max", "100000 100000"),
            ):
                self._write(name, value)
                if self._read(name).strip() != value:
                    raise AthenaEvidenceError("aggregate kernel quota did not bind")
        except BaseException:
            self.close()
            raise

    def _read(self, name: str, descriptor: int | None = None) -> str:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                     dir_fd=self.descriptor if descriptor is None else descriptor)
        try:
            value = os.read(fd, 8193)
            if len(value) > 8192:
                raise AthenaEvidenceError("aggregate quota status exceeded its bound")
            return value.decode("ascii")
        finally:
            os.close(fd)

    def _write(self, name: str, value: str) -> None:
        self._verify()
        fd = os.open(name, os.O_WRONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
                     dir_fd=self.descriptor)
        try:
            payload = (value + "\n").encode("ascii")
            if os.write(fd, payload) != len(payload):
                raise AthenaEvidenceError("aggregate kernel quota write was incomplete")
        finally:
            os.close(fd)

    def _verify(self) -> None:
        current = os.stat(self.name, dir_fd=self.parent, follow_symlinks=False)
        if (not stat.S_ISDIR(current.st_mode) or current.st_uid != os.geteuid()
                or stat.S_IMODE(current.st_mode) != 0o700
                or (current.st_dev, current.st_ino) != (self.identity.st_dev, self.identity.st_ino)):
            raise AthenaEvidenceError("aggregate quota authority changed")

    def admit(self, process: _OwnedProcess) -> None:
        if process.returncode is not None:
            raise AthenaEvidenceError("aggregate quota lost its child authority")
        os.waitid(os.P_PID, process.pid, os.WEXITED | os.WNOHANG | os.WNOWAIT)
        self._write("cgroup.procs", str(process.pid))
        with open(f"/proc/{process.pid}/cgroup", encoding="ascii") as source:
            membership = source.read(4097)
        if len(membership) > 4096 or not membership.strip().endswith("/" + self.name):
            raise AthenaEvidenceError("aggregate quota did not acquire the child")

    def close(self) -> None:
        if self.descriptor >= 0:
            self._verify()
            self._write("cgroup.kill", "1")
            deadline = time.monotonic() + PROCESS_REAP_SECONDS
            while True:
                events = dict(line.split() for line in self._read("cgroup.events").splitlines())
                if events.get("populated") == "0":
                    break
                if events.get("populated") != "1" or time.monotonic() >= deadline:
                    raise AthenaEvidenceError("aggregate cgroup extinction is unproven")
                time.sleep(PROCESS_POLL_SECONDS)
            self._verify()
            os.rmdir(self.name, dir_fd=self.parent)
            os.close(self.descriptor)
            self.descriptor = -1
        if self.parent >= 0:
            os.close(self.parent)
            self.parent = -1


def _unique_object(pairs: list[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise AthenaEvidenceError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _scan_json_resource_bounds(payload: str, context: str) -> None:
    """Bound tokens and reject duplicate keys before allocating the JSON tree."""
    if not isinstance(payload, str) or len(payload) > MAX_OUTPUT_BYTES:
        raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
    containers: list[tuple[set[str] | None, bool]] = []
    nodes = total_strings = index = 0
    while index < len(payload):
        character = payload[index]
        if character == '"':
            start = index + 1
            index = start
            escaped = False
            token_bytes = 0
            while index < len(payload):
                character = payload[index]
                if character == '"' and not escaped:
                    break
                token_bytes += len(character.encode("utf-8"))
                if token_bytes > MAX_JSON_STRING_BYTES:
                    raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
                escaped = character == "\\" and not escaped
                index += 1
            total_strings += token_bytes
            nodes += 1
            if containers and containers[-1][0] is not None and containers[-1][1]:
                try:
                    key, _end = json.decoder.scanstring(payload, start)
                except (ValueError, UnicodeError) as exc:
                    raise AthenaEvidenceError(f"{context} is not valid JSON") from exc
                keys = containers[-1][0]
                if key in keys:
                    raise AthenaEvidenceError(f"{context} has duplicate JSON keys")
                keys.add(key)
        elif character in "[{":
            containers.append((set(), True) if character == "{" else (None, False))
            nodes += 1
        elif character in "]}":
            if not containers:
                raise AthenaEvidenceError(f"{context} is not valid JSON")
            containers.pop()
        elif character in ":," and containers:
            keys, _expect_key = containers[-1]
            containers[-1] = (keys, character == ",")
        elif character not in " \t\r\n":
            start = index
            while index + 1 < len(payload) and payload[index + 1] not in " \t\r\n,]}:":
                index += 1
            if index - start + 1 > MAX_JSON_NUMBER_CHARACTERS:
                raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
            nodes += 1
        if (len(containers) > MAX_JSON_DEPTH or nodes > MAX_JSON_NODES
                or total_strings > MAX_JSON_TOTAL_STRING_BYTES):
            raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
        index += 1


def _load_json(payload: str, context: str) -> object:
    _scan_json_resource_bounds(payload, context)
    def bounded_integer(value: str) -> int:
        if len(value) > MAX_JSON_NUMBER_CHARACTERS:
            raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
        return int(value)

    def bounded_float(value: str) -> float:
        if len(value) > MAX_JSON_NUMBER_CHARACTERS:
            raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
        parsed = float(value)
        if not math.isfinite(parsed):
            raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
        return parsed

    try:
        value = json.loads(
            payload,
            object_pairs_hook=_unique_object,
            parse_int=bounded_integer,
            parse_float=bounded_float,
            parse_constant=lambda item: (_ for _ in ()).throw(
                AthenaEvidenceError(f"nonfinite JSON value: {item}")
            ),
        )
    except AthenaEvidenceError:
        raise
    except (json.JSONDecodeError, RecursionError, UnicodeError, ValueError) as exc:
        raise AthenaEvidenceError(f"{context} is not valid JSON") from exc
    pending = [(value, 1)]
    nodes = 0
    string_bytes = 0
    while pending:
        current, depth = pending.pop()
        nodes += 1
        if depth > MAX_JSON_DEPTH or nodes > MAX_JSON_NODES:
            raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
        if isinstance(current, dict):
            nodes += len(current)
            if nodes > MAX_JSON_NODES:
                raise AthenaEvidenceError(
                    f"{context} exceeds JSON resource bounds"
                )
            for key, item in current.items():
                encoded = key.encode("utf-8")
                if len(encoded) > MAX_JSON_STRING_BYTES:
                    raise AthenaEvidenceError(
                        f"{context} exceeds JSON resource bounds"
                    )
                string_bytes += len(encoded)
                pending.append((item, depth + 1))
        elif isinstance(current, list):
            pending.extend((item, depth + 1) for item in current)
        elif isinstance(current, str):
            encoded = current.encode("utf-8")
            if len(encoded) > MAX_JSON_STRING_BYTES:
                raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
            string_bytes += len(encoded)
        if string_bytes > MAX_JSON_TOTAL_STRING_BYTES:
            raise AthenaEvidenceError(f"{context} exceeds JSON resource bounds")
    return value


def _load_object(payload: str, context: str) -> dict:
    value = _load_json(payload, context)
    if not isinstance(value, dict):
        raise AthenaEvidenceError(f"{context} is not a JSON object")
    return value


def _canonical_json(value: object) -> str:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            allow_nan=False,
            sort_keys=True,
            separators=(",", ":"),
        )
    except (TypeError, UnicodeError, ValueError) as exc:
        raise AthenaEvidenceError("Athena data is not canonical JSON") from exc


def validated_terminal_security_receipt(
    value: object,
    *,
    repository: str,
    pr_url: str,
    expected_base_ref: str,
    expected_head: str,
    reviewer_login: str,
) -> dict:
    """Validate one durable base, head, reviewer, chain, and policy receipt."""
    expected_keys = {
        "schema_id", "schema_version", "repository", "url",
        "base_ref", "base_oid", "head_ref", "head_oid",
        "reviewer_login", "athena_chain", "effective_policy",
    }
    head_ref = value.get("head_ref") if isinstance(value, dict) else None
    if (
        not isinstance(value, dict)
        or set(value) != expected_keys
        or value.get("schema_id")
        != "odysseus.child-terminal-security-receipt"
        or value.get("schema_version") != 1
        or value.get("repository") != repository
        or value.get("url") != pr_url
        or value.get("base_ref") != expected_base_ref
        or HEX_40.fullmatch(value.get("base_oid", "")) is None
        or not isinstance(head_ref, str)
        or re.fullmatch(r"[A-Za-z0-9._/-]{1,255}", head_ref) is None
        or head_ref.startswith("/")
        or ".." in head_ref.split("/")
        or value.get("head_oid") != expected_head
        or HEX_40.fullmatch(expected_head) is None
        or value.get("reviewer_login") != reviewer_login
        or not isinstance(value.get("athena_chain"), dict)
        or not isinstance(value.get("effective_policy"), dict)
    ):
        raise AthenaEvidenceError("terminal security receipt is malformed")
    return _load_object(_canonical_json(value), "terminal security receipt")


def build_terminal_security_receipt(
    *,
    repository: str,
    pr_url: str,
    base_ref: str,
    base_oid: str,
    head_ref: str,
    head_oid: str,
    reviewer_login: str,
    athena_chain: dict,
    effective_policy: dict,
) -> dict:
    """Build one canonical durable terminal security receipt."""
    return validated_terminal_security_receipt(
        {
            "schema_id": "odysseus.child-terminal-security-receipt",
            "schema_version": 1,
            "repository": repository,
            "url": pr_url,
            "base_ref": base_ref,
            "base_oid": base_oid,
            "head_ref": head_ref,
            "head_oid": head_oid,
            "reviewer_login": reviewer_login,
            "athena_chain": athena_chain,
            "effective_policy": effective_policy,
        },
        repository=repository,
        pr_url=pr_url,
        expected_base_ref=base_ref,
        expected_head=head_oid,
        reviewer_login=reviewer_login,
    )


def _read_no_follow(path: str, maximum_bytes: int = 8 * 1024 * 1024) -> bytes:
    no_follow = getattr(os, "O_NOFOLLOW", None)
    if not isinstance(no_follow, int) or no_follow == 0:
        raise AthenaEvidenceError("O_NOFOLLOW is required for Athena helpers")
    try:
        descriptor = os.open(path, os.O_RDONLY | no_follow)
    except OSError as exc:
        raise AthenaEvidenceError("an Athena helper cannot be opened safely") from exc
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise AthenaEvidenceError("an Athena helper is not a regular file")
        with os.fdopen(descriptor, "rb", closefd=False) as stream:
            payload = stream.read(maximum_bytes + 1)
    finally:
        os.close(descriptor)
    if len(payload) > maximum_bytes:
        raise AthenaEvidenceError("an Athena helper exceeds its size bound")
    return payload


def _release_path(root: str, relative: str) -> str:
    candidate = os.path.normpath(os.path.join(root, relative))
    if (
        os.path.commonpath((root, candidate)) != root
        or os.path.realpath(candidate) != candidate
    ):
        raise AthenaEvidenceError("Athena release metadata escapes the plugin root")
    return candidate


def _release_object(path: str, context: str, expected_sha256: str) -> dict:
    try:
        release_bytes = _read_no_follow(path, 64 * 1024)
        if hashlib.sha256(release_bytes).hexdigest() != expected_sha256:
            raise AthenaEvidenceError(
                f"{context} bytes do not match release 0.5.3"
            )
        payload = release_bytes.decode("utf-8")
    except UnicodeError as exc:
        raise AthenaEvidenceError(f"{context} is not valid UTF-8") from exc
    return _load_object(payload, context)


def _verify_release_metadata(root: str) -> None:
    plugin = _release_object(
        _release_path(root, PLUGIN_MANIFEST),
        "the Athena plugin manifest",
        PLUGIN_MANIFEST_SHA256,
    )
    if (
        plugin.get("name") != "athena"
        or plugin.get("version") != ATHENA_RELEASE_VERSION
        or plugin.get("repository")
        != "https://github.com/HomericIntelligence/Athena"
    ):
        raise AthenaEvidenceError("the Athena plugin manifest is not release 0.5.3")
    installation = _release_object(
        _release_path(root, INSTALL_MANIFEST),
        "the Athena install manifest",
        INSTALL_MANIFEST_SHA256,
    )
    if installation != {
        "source_type": "git",
        "source": ATHENA_RELEASE_SOURCE,
        "ref_name": "main",
        "sparse_paths": [],
        "revision": ATHENA_RELEASE_COMMIT,
    }:
        raise AthenaEvidenceError("the Athena install manifest is not the pinned release")


def _verified_plugin_root(plugin_root: str) -> str:
    if (
        not plugin_root
        or not os.path.isabs(plugin_root)
        or os.path.normpath(plugin_root) != plugin_root
        or os.path.realpath(plugin_root) != plugin_root
    ):
        raise AthenaEvidenceError("ATHENA_PLUGIN_ROOT is not an exact safe path")
    try:
        metadata = os.lstat(plugin_root)
    except OSError as exc:
        raise AthenaEvidenceError("ATHENA_PLUGIN_ROOT is unavailable") from exc
    if not stat.S_ISDIR(metadata.st_mode):
        raise AthenaEvidenceError("ATHENA_PLUGIN_ROOT is not a directory")
    _verify_release_metadata(plugin_root)
    for relative, expected in HELPER_SHA256.items():
        candidate = _release_path(plugin_root, relative)
        if hashlib.sha256(_read_no_follow(candidate)).hexdigest() != expected:
            raise AthenaEvidenceError("the dependency-locked Athena digest changed")
    return plugin_root


def _verified_adapter_command(
    path: str,
    expected_sha256: str,
    arguments: list[str],
    python_executable: _BoundExecutable | None,
) -> list[str]:
    """Return an isolated interpreter command bound to the verified bytes."""
    payload = _read_no_follow(path, MAX_VERIFIED_ADAPTER_BYTES)
    if hashlib.sha256(payload).hexdigest() != expected_sha256:
        raise AthenaEvidenceError("the read-only chain adapter digest changed")
    encoded = base64.b64encode(payload).decode("ascii")
    return [
        python_executable.execution_path
        if python_executable is not None
        else sys.executable,
        "-I",
        "-S",
        "-B",
        "-c",
        _VERIFIED_SOURCE_RUNNER,
        encoded,
        path,
        *arguments,
    ]


class _BoundExecutable:
    """Retain one verified executable object until all child calls finish."""

    def __init__(self, descriptor: int, sha256: str) -> None:
        self.descriptor = descriptor
        self.execution_path = _descriptor_execution_path(descriptor)
        self.sha256 = sha256

    def close(self) -> None:
        descriptor = self.descriptor
        self.descriptor = -1
        if descriptor >= 0:
            os.close(descriptor)


def _descriptor_execution_path(descriptor: int) -> str:
    """Return the Linux descriptor path or fail before a path reopen."""
    if sys.platform != "linux" or not os.path.isdir("/proc/self/fd"):
        raise AthenaEvidenceError(
            "descriptor-bound trusted executable execution is unavailable"
        )
    return f"/proc/self/fd/{descriptor}"


def _executable_identity(metadata: os.stat_result) -> tuple[int, ...]:
    """Bind content-relevant metadata, including unforgeable change time."""
    return (
        metadata.st_dev,
        metadata.st_ino,
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_nlink,
        metadata.st_size,
        metadata.st_mtime_ns,
        metadata.st_ctime_ns,
    )


def _require_root_owned_ancestry(path: str, context: str) -> None:
    parent = os.path.dirname(path)
    while True:
        try:
            ancestor = os.stat(parent, follow_symlinks=False)
        except OSError as exc:
            raise AthenaEvidenceError(
                f"{context} has no independent trust anchor"
            ) from exc
        if (
            not stat.S_ISDIR(ancestor.st_mode)
            or ancestor.st_uid != 0
            or ancestor.st_mode & 0o022
        ):
            raise AthenaEvidenceError(
                f"{context} has no independent trust anchor"
            )
        next_parent = os.path.dirname(parent)
        if next_parent == parent:
            break
        parent = next_parent


def _require_independent_executable_trust(
    path: str, metadata: os.stat_result, context: str
) -> None:
    """Require a root-owned executable and root-owned immutable path ancestry."""
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_mode & 0o022
        or metadata.st_mode & 0o111 == 0
    ):
        raise AthenaEvidenceError(
            f"{context} has no independent trust anchor"
        )
    _require_root_owned_ancestry(path, context)


def _require_independent_directory_trust(path: str, context: str) -> None:
    canonical = os.path.realpath(path)
    try:
        metadata = os.stat(canonical, follow_symlinks=False)
    except OSError as exc:
        raise AthenaEvidenceError(f"{context} is unavailable") from exc
    if (
        not stat.S_ISDIR(metadata.st_mode)
        or metadata.st_uid != 0
        or metadata.st_mode & 0o022
    ):
        raise AthenaEvidenceError(f"{context} has no independent trust anchor")
    _require_root_owned_ancestry(
        os.path.join(canonical, "dependency-anchor"), context
    )


def _python_dependency_closure() -> None:
    """Require root-owned standard-library and loaded native dependencies."""
    roots: set[str] = set()
    for key in ("stdlib", "platstdlib"):
        value = sysconfig.get_paths().get(key)
        if not isinstance(value, str) or not value:
            raise AthenaEvidenceError("the Python dependency closure is unavailable")
        _require_independent_directory_trust(
            value, "the Python dependency closure"
        )
        roots.add(os.path.realpath(value))
    # Import every module the isolated supervisor starts with before sealing the
    # closure, then authenticate each loaded stdlib source/cache object as well
    # as the native mappings below.
    required_modules = (ctypes, resource, traceback)
    module_paths: set[str] = set()
    for module in (*tuple(sys.modules.values()), *required_modules):
        for attribute in ("__file__", "__cached__"):
            path = getattr(module, attribute, None)
            if (
                not isinstance(path, str)
                or (attribute == "__cached__" and not os.path.lexists(path))
            ):
                continue
            canonical = os.path.realpath(path)
            if any(
                os.path.commonpath((root, canonical)) == root
                for root in roots
            ):
                module_paths.add(canonical)
    for path in module_paths:
        try:
            metadata = os.stat(path, follow_symlinks=False)
        except OSError as exc:
            raise AthenaEvidenceError(
                "the Python dependency closure is unavailable"
            ) from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or metadata.st_mode & 0o022
        ):
            raise AthenaEvidenceError(
                "the Python dependency closure has no independent trust anchor"
            )
        _require_root_owned_ancestry(path, "the Python dependency closure")
    if not sys.platform.startswith("linux"):
        return
    try:
        mappings = _read_no_follow("/proc/self/maps", 8 * 1024 * 1024).decode(
            "utf-8"
        )
    except (AthenaEvidenceError, UnicodeError) as exc:
        raise AthenaEvidenceError("the Python dependency closure is unavailable") from exc
    dependencies = {
        line.split(maxsplit=5)[-1].removesuffix(" (deleted)")
        for line in mappings.splitlines()
        if len(line.split(maxsplit=5)) == 6
        and line.split(maxsplit=5)[-1].startswith("/")
        and (
            ".so" in line.split(maxsplit=5)[-1]
            or line.split(maxsplit=5)[-1] == os.path.realpath(sys.executable)
        )
    }
    for dependency in dependencies:
        canonical = os.path.realpath(dependency)
        try:
            metadata = os.stat(canonical, follow_symlinks=False)
        except OSError as exc:
            raise AthenaEvidenceError(
                "the Python dependency closure is unavailable"
            ) from exc
        if (
            not stat.S_ISREG(metadata.st_mode)
            or metadata.st_uid != 0
            or metadata.st_mode & 0o022
        ):
            raise AthenaEvidenceError(
                "the Python dependency closure has no independent trust anchor"
            )
        _require_root_owned_ancestry(
            canonical, "the Python dependency closure"
        )


def _trusted_python_executable() -> _BoundExecutable:
    """Retain one root-owned interpreter after verifying its dependency closure."""
    if not sys.platform.startswith("linux"):
        raise AthenaEvidenceError(
            "descriptor-bound trusted Python execution is unavailable"
        )
    canonical = os.path.realpath(sys.executable)
    descriptor = -1
    try:
        initial = os.stat(canonical, follow_symlinks=False)
        descriptor = os.open(
            canonical,
            os.O_RDONLY
            | getattr(os, "O_NOFOLLOW", 0)
            | getattr(os, "O_CLOEXEC", 0),
        )
        metadata = os.fstat(descriptor)
        _require_independent_executable_trust(
            canonical, metadata, "the Python interpreter"
        )
        if _executable_identity(initial) != _executable_identity(metadata):
            raise AthenaEvidenceError("the Python interpreter changed before binding")
        _python_dependency_closure()
        digest = hashlib.sha256()
        offset = 0
        while offset < metadata.st_size:
            chunk = os.pread(
                descriptor,
                min(READ_CHUNK_BYTES, metadata.st_size - offset),
                offset,
            )
            if not chunk:
                raise AthenaEvidenceError("the Python interpreter binding is incomplete")
            digest.update(chunk)
            offset += len(chunk)
        if _executable_identity(os.fstat(descriptor)) != _executable_identity(metadata):
            raise AthenaEvidenceError("the Python interpreter changed while binding")
        return _BoundExecutable(descriptor, digest.hexdigest())
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        raise


def _sealed_executable_snapshot(
    source_descriptor: int, source_metadata: os.stat_result
) -> _BoundExecutable:
    """Copy one executable into a sealed memfd and verify the exact snapshot."""
    if (
        sys.platform != "linux"
        or not os.path.isdir("/proc/self/fd")
        or not hasattr(os, "memfd_create")
        or not hasattr(os, "MFD_ALLOW_SEALING")
    ):
        raise AthenaEvidenceError(
            "sealed descriptor-bound trusted executable execution is unavailable"
        )
    try:
        import fcntl

        required_seals = (
            fcntl.F_SEAL_WRITE
            | fcntl.F_SEAL_GROW
            | fcntl.F_SEAL_SHRINK
            | fcntl.F_SEAL_SEAL
        )
        add_seals = fcntl.F_ADD_SEALS
        get_seals = fcntl.F_GET_SEALS
    except (AttributeError, ImportError) as exc:
        raise AthenaEvidenceError(
            "sealed descriptor-bound trusted executable execution is unavailable"
        ) from exc
    if (
        not stat.S_ISREG(source_metadata.st_mode)
        or source_metadata.st_size <= 0
        or source_metadata.st_size > MAX_BOUND_EXECUTABLE_BYTES
    ):
        raise AthenaEvidenceError("the trusted executable exceeds its size bound")

    flags = os.MFD_ALLOW_SEALING | getattr(os, "MFD_CLOEXEC", 0)
    snapshot_descriptor = -1
    try:
        snapshot_descriptor = os.memfd_create("odysseus-executable", flags)
        digest = hashlib.sha256()
        offset = 0
        while offset < source_metadata.st_size:
            chunk = os.pread(
                source_descriptor,
                min(READ_CHUNK_BYTES, source_metadata.st_size - offset),
                offset,
            )
            if not chunk:
                raise AthenaEvidenceError(
                    "the trusted executable changed while it was bound"
                )
            written = 0
            while written < len(chunk):
                count = os.write(snapshot_descriptor, chunk[written:])
                if count <= 0:
                    raise AthenaEvidenceError(
                        "the trusted executable snapshot is incomplete"
                    )
                written += count
            digest.update(chunk)
            offset += len(chunk)
        if os.pread(source_descriptor, 1, source_metadata.st_size):
            raise AthenaEvidenceError(
                "the trusted executable changed while it was bound"
            )
        os.fchmod(snapshot_descriptor, 0o500)
        fcntl.fcntl(snapshot_descriptor, add_seals, required_seals)
        if fcntl.fcntl(snapshot_descriptor, get_seals) & required_seals != required_seals:
            raise AthenaEvidenceError("the trusted executable snapshot is not sealed")

        snapshot_metadata = os.fstat(snapshot_descriptor)
        if (
            not stat.S_ISREG(snapshot_metadata.st_mode)
            or snapshot_metadata.st_size != source_metadata.st_size
            or snapshot_metadata.st_mode & 0o777 != 0o500
        ):
            raise AthenaEvidenceError("the trusted executable snapshot is unsafe")
        expected_digest = digest.hexdigest()
        verified_digest = hashlib.sha256()
        offset = 0
        while offset < snapshot_metadata.st_size:
            chunk = os.pread(
                snapshot_descriptor,
                min(READ_CHUNK_BYTES, snapshot_metadata.st_size - offset),
                offset,
            )
            if not chunk:
                raise AthenaEvidenceError(
                    "the trusted executable snapshot is incomplete"
                )
            verified_digest.update(chunk)
            offset += len(chunk)
        if verified_digest.hexdigest() != expected_digest:
            raise AthenaEvidenceError("the trusted executable snapshot digest changed")
        source_digest = hashlib.sha256()
        offset = 0
        while offset < source_metadata.st_size:
            chunk = os.pread(
                source_descriptor,
                min(READ_CHUNK_BYTES, source_metadata.st_size - offset),
                offset,
            )
            if not chunk:
                raise AthenaEvidenceError(
                    "the trusted executable changed while it was bound"
                )
            source_digest.update(chunk)
            offset += len(chunk)
        if (
            os.pread(source_descriptor, 1, source_metadata.st_size)
            or source_digest.hexdigest() != expected_digest
            or _executable_identity(os.fstat(source_descriptor))
            != _executable_identity(source_metadata)
        ):
            raise AthenaEvidenceError(
                "the trusted executable changed while it was bound"
            )
        return _BoundExecutable(snapshot_descriptor, expected_digest)
    except AthenaEvidenceError:
        if snapshot_descriptor >= 0:
            os.close(snapshot_descriptor)
        raise
    except (OSError, ValueError) as exc:
        if snapshot_descriptor >= 0:
            os.close(snapshot_descriptor)
        raise AthenaEvidenceError(
            "the trusted executable cannot be sealed"
        ) from exc


def _trusted_gh_executable() -> _BoundExecutable:
    """Open one canonical GitHub CLI and retain its verified object."""
    configured = os.environ.get("ODYSSEUS_GH_EXECUTABLE", "")
    candidates = (configured,) if configured else _GH_EXECUTABLE_CANDIDATES
    for candidate in candidates:
        if not candidate or not os.path.isabs(candidate):
            continue
        canonical = os.path.realpath(candidate)
        descriptor = -1
        try:
            initial = os.stat(canonical, follow_symlinks=False)
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            flags |= getattr(os, "O_CLOEXEC", 0)
            descriptor = os.open(canonical, flags)
            metadata = os.fstat(descriptor)
        except OSError:
            if descriptor >= 0:
                os.close(descriptor)
            continue
        try:
            _require_independent_executable_trust(
                canonical, metadata, "the GitHub CLI executable"
            )
        except AthenaEvidenceError:
            os.close(descriptor)
            if configured:
                raise
            continue
        if _executable_identity(initial) != _executable_identity(metadata):
            os.close(descriptor)
            if configured:
                raise AthenaEvidenceError(
                    "the GitHub CLI executable changed before binding"
                )
            continue
        if configured and canonical != configured:
            os.close(descriptor)
            raise AthenaEvidenceError(
                "ODYSSEUS_GH_EXECUTABLE must be a canonical executable path"
            )
        identity = _executable_identity(metadata)
        try:
            bound = _sealed_executable_snapshot(descriptor, metadata)
            after = os.fstat(descriptor)
            if identity != _executable_identity(after):
                bound.close()
                raise AthenaEvidenceError(
                    "the trusted executable changed while it was bound"
                )
            return bound
        finally:
            os.close(descriptor)
    raise AthenaEvidenceError("a trusted GitHub CLI executable is unavailable")


def _trusted_git_executable() -> _BoundExecutable:
    """Open one independently trusted Git executable and retain its snapshot."""
    configured = os.environ.get("ODYSSEUS_GIT_EXECUTABLE", "")
    candidates = (configured,) if configured else _GIT_EXECUTABLE_CANDIDATES
    for candidate in candidates:
        if not candidate or not os.path.isabs(candidate):
            continue
        canonical = os.path.realpath(candidate)
        descriptor = -1
        try:
            initial = os.stat(canonical, follow_symlinks=False)
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            flags |= getattr(os, "O_CLOEXEC", 0)
            descriptor = os.open(canonical, flags)
            metadata = os.fstat(descriptor)
        except OSError:
            if descriptor >= 0:
                os.close(descriptor)
            continue
        try:
            _require_independent_executable_trust(
                canonical, metadata, "the Git executable"
            )
        except AthenaEvidenceError:
            os.close(descriptor)
            if configured:
                raise
            continue
        if configured and canonical != configured:
            os.close(descriptor)
            raise AthenaEvidenceError(
                "ODYSSEUS_GIT_EXECUTABLE must be a canonical executable path"
            )
        if _executable_identity(initial) != _executable_identity(metadata):
            os.close(descriptor)
            if configured:
                raise AthenaEvidenceError(
                    "the Git executable changed before binding"
                )
            continue
        identity = _executable_identity(metadata)
        try:
            bound = _sealed_executable_snapshot(descriptor, metadata)
            if identity != _executable_identity(os.fstat(descriptor)):
                bound.close()
                raise AthenaEvidenceError(
                    "the Git executable changed while it was bound"
                )
            return bound
        finally:
            os.close(descriptor)
    raise AthenaEvidenceError("a trusted Git executable is unavailable")


def _trusted_git_exec_path() -> str:
    """Bind Git's required HTTPS helper directory to root-owned dependencies."""
    configured = os.environ.get("ODYSSEUS_GIT_EXEC_PATH", "")
    candidates = (configured,) if configured else _GIT_EXEC_PATH_CANDIDATES
    for candidate in candidates:
        if not candidate or not os.path.isabs(candidate):
            continue
        canonical = os.path.realpath(candidate)
        if configured and canonical != configured:
            raise AthenaEvidenceError(
                "ODYSSEUS_GIT_EXEC_PATH must be a canonical directory"
            )
        try:
            _require_independent_directory_trust(
                canonical, "the Git helper dependency closure"
            )
            for helper in ("git-remote-http", "git-remote-https"):
                path = os.path.realpath(os.path.join(canonical, helper))
                metadata = os.stat(path, follow_symlinks=False)
                _require_independent_executable_trust(
                    path, metadata, "the Git helper dependency closure"
                )
        except (AthenaEvidenceError, OSError):
            if configured:
                raise AthenaEvidenceError(
                    "the configured Git helper dependency closure is unsafe"
                )
            continue
        return canonical
    raise AthenaEvidenceError("a trusted Git helper dependency closure is unavailable")


def _trusted_container_runtime(configured: str) -> _BoundExecutable:
    """Open one canonical runtime and retain an immutable executable snapshot."""
    if not isinstance(configured, str) or not configured or "\x00" in configured:
        raise AthenaEvidenceError("the container runtime configuration is malformed")
    if os.path.isabs(configured):
        if os.path.normpath(configured) != configured:
            raise AthenaEvidenceError(
                "CONTAINER_RUNTIME must be a canonical executable path"
            )
        candidates = (configured,)
        explicit = True
    else:
        candidates = _CONTAINER_RUNTIME_CANDIDATES.get(configured, ())
        explicit = False
        if not candidates:
            raise AthenaEvidenceError(
                "CONTAINER_RUNTIME must be an absolute path, podman, or docker"
            )
    for candidate in candidates:
        descriptor = -1
        try:
            canonical = os.path.realpath(candidate)
            if explicit and canonical != configured:
                raise AthenaEvidenceError(
                    "CONTAINER_RUNTIME must be a canonical executable path"
                )
            initial = os.stat(canonical, follow_symlinks=False)
            flags = os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0)
            flags |= getattr(os, "O_CLOEXEC", 0)
            descriptor = os.open(canonical, flags)
            metadata = os.fstat(descriptor)
        except AthenaEvidenceError:
            if descriptor >= 0:
                os.close(descriptor)
            raise
        except OSError:
            if descriptor >= 0:
                os.close(descriptor)
            continue
        try:
            _require_independent_executable_trust(
                canonical, metadata, "the container runtime executable"
            )
        except AthenaEvidenceError:
            os.close(descriptor)
            if explicit:
                raise
            continue
        if _executable_identity(initial) != _executable_identity(metadata):
            os.close(descriptor)
            if explicit:
                raise AthenaEvidenceError(
                    "the configured container runtime changed before binding"
                )
            continue
        identity = _executable_identity(metadata)
        try:
            bound = _sealed_executable_snapshot(descriptor, metadata)
            if identity != _executable_identity(os.fstat(descriptor)):
                bound.close()
                raise AthenaEvidenceError(
                    "the configured container runtime changed while it was bound"
                )
            return bound
        finally:
            os.close(descriptor)
    raise AthenaEvidenceError("a trusted container runtime executable is unavailable")




def _container_endpoint_path(runtime: str) -> str:
    """Resolve only explicit Unix routing or the documented local defaults."""
    kind = os.path.basename(runtime) if isinstance(runtime, str) else ""
    if kind not in _CONTAINER_RUNTIME_CANDIDATES:
        raise AthenaEvidenceError("the container runtime endpoint type is unknown")
    endpoint = os.environ.get(
        "ODYSSEUS_CONTAINER_ENDPOINT",
        f"unix:///run/user/{os.geteuid()}/podman/podman.sock"
        if kind == "podman" else "unix:///var/run/docker.sock",
    )
    if not endpoint.startswith("unix://") or "\x00" in endpoint:
        raise AthenaEvidenceError("the container endpoint must be an absolute Unix socket")
    path = endpoint[7:]
    if not os.path.isabs(path) or os.path.normpath(path) != path or path.startswith("//"):
        raise AthenaEvidenceError("the container endpoint must be an absolute Unix socket")
    return path


def _acquire_container_socket(path: str) -> int:
    """Retain one socket inode and verify its parent and dentry after open."""
    parent = descriptor = -1
    try:
        parent_path, name = os.path.split(path)
        flags = os.O_PATH | os.O_CLOEXEC | os.O_NOFOLLOW
        parent = os.open(os.path.realpath(parent_path), flags | os.O_DIRECTORY)
        parent_info = os.fstat(parent)
        if parent_info.st_uid not in {0, os.geteuid()} or parent_info.st_mode & 0o022:
            raise AthenaEvidenceError("the container runtime endpoint is unsafe")
        initial = os.stat(name, dir_fd=parent, follow_symlinks=False)
        descriptor = os.open(name, flags, dir_fd=parent)
        opened = os.fstat(descriptor)
        final = os.stat(name, dir_fd=parent, follow_symlinks=False)
        path_info = os.stat(path, follow_symlinks=False)
        if (not stat.S_ISSOCK(opened.st_mode) or opened.st_uid not in {0, os.geteuid()}
                or opened.st_nlink != 1 or any(
                    (value.st_dev, value.st_ino, value.st_mode, value.st_uid) !=
                    (opened.st_dev, opened.st_ino, opened.st_mode, opened.st_uid)
                    for value in (initial, final, path_info))):
            raise AthenaEvidenceError("the container runtime endpoint changed during acquisition")
        retained, descriptor = descriptor, -1
        return retained
    except OSError as exc:
        raise AthenaEvidenceError("the container runtime endpoint cannot be acquired") from exc
    finally:
        for fd in (parent, descriptor):
            if fd >= 0:
                os.close(fd)


class _PodmanStorageAuthority:
    """Retained local storage identity, independent of socket-service lifetime."""

    @staticmethod
    def _path(value: object) -> str:
        if (not isinstance(value, str) or not value or len(value) > 4096
                or "\x00" in value or not value.startswith("/")
                or value.startswith("//") or os.path.normpath(value) != value):
            raise AthenaEvidenceError("Podman storage authority path is not canonical")
        return value

    @staticmethod
    def _metadata(info: os.stat_result) -> dict:
        return {"dev": info.st_dev, "ino": info.st_ino,
                "uid": info.st_uid, "gid": info.st_gid, "mode": info.st_mode}

    @classmethod
    def _open_root(cls, path: str) -> int:
        descriptor = os.open("/", os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
        try:
            for component in cls._path(path).split("/")[1:]:
                if not component:
                    continue
                child = os.open(component, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW
                                | os.O_CLOEXEC, dir_fd=descriptor)
                os.close(descriptor)
                descriptor = child
            info = os.fstat(descriptor)
            if info.st_uid != os.geteuid() or info.st_mode & 0o022:
                raise AthenaEvidenceError("Podman storage root has unsafe ownership or mode")
            result, descriptor = descriptor, -1
            return result
        except OSError as exc:
            raise AthenaEvidenceError("Podman storage root cannot be retained") from exc
        finally:
            if descriptor >= 0:
                os.close(descriptor)

    def __init__(self, endpoint, runtime) -> None:
        self.endpoint, self.runtime = endpoint, runtime
        self.roots: dict[str, int] = {}
        socket_identity = endpoint._socket_identity
        if (os.geteuid() == 0 or socket_identity["uid"] != os.geteuid()
                or socket_identity["gid"] != os.getegid()
                or not stat.S_ISSOCK(socket_identity["mode"])
                or socket_identity["mode"] & 0o002):
            raise AthenaEvidenceError("Podman socket is not owned by the rootless service")
        self.expected = self._info()
        try:
            for key in ("graphRoot", "runRoot"):
                self.roots[key] = self._open_root(self.expected["store"][key])
            self.expected["rootIdentities"] = {
                key: self._metadata(os.fstat(fd)) for key, fd in self.roots.items()
            }
            self.identity()  # A second service observation after retaining both roots.
        except BaseException:
            self.close()
            raise

    def _info(self) -> dict:
        result = self.endpoint.enter_command(
            self.runtime, ["info", "--format=json"], timeout_seconds=10,
        )
        if result.returncode != 0:
            raise AthenaEvidenceError("Podman storage authority info is unavailable")
        info = _load_json(result.stdout, "Podman storage authority")
        try:
            host, store = info["host"], info["store"]
            remote = host["remoteSocket"]
            socket_path = remote["path"]
            if isinstance(socket_path, str) and socket_path.startswith("unix://"):
                socket_path = socket_path[7:]
            if (self._path(socket_path) != self.endpoint._endpoint_path
                    or ("exists" in remote and remote["exists"] is not True)
                    or type(host["serviceIsRemote"]) is not bool
                    or host["security"]["rootless"] is not True
                    or store["transientStore"] is not False
                    or not isinstance(store["graphDriverName"], str)
                    or not re.fullmatch(r"[a-zA-Z0-9_.-]{1,128}", store["graphDriverName"])):
                raise AthenaEvidenceError("Podman storage authority fields are unproven")
            mappings = host["idMappings"]
            if not isinstance(mappings, dict) or set(mappings) != {"uidmap", "gidmap"}:
                raise AthenaEvidenceError("Podman user namespace mapping is unavailable")
            for kind, entries in mappings.items():
                if not isinstance(entries, list) or not 1 <= len(entries) <= 340:
                    raise AthenaEvidenceError("Podman user namespace mapping is unbounded")
                for entry in entries:
                    if (not isinstance(entry, dict) or set(entry) != {"container_id", "host_id", "size"}
                            or any(type(value) is not int or not 0 <= value < 2**32
                                   for value in entry.values()) or not entry["size"]):
                        raise AthenaEvidenceError("Podman user namespace mapping is malformed")
                entries.sort(key=lambda entry: entry["container_id"])
                service_id = os.geteuid() if kind == "uidmap" else os.getegid()
                if entries[0] != {"container_id": 0, "host_id": service_id, "size": 1}:
                    raise AthenaEvidenceError("Podman namespace does not anchor the service identity")
                next_container = 0
                ranges = []
                for entry in entries:
                    start, size = entry["host_id"], entry["size"]
                    if (entry["container_id"] != next_container or start == 0
                            or start + size > 2**32 - 1
                            or next_container + size > 2**32 - 1
                            or any(start < end and begin < start + size for begin, end in ranges)):
                        raise AthenaEvidenceError("Podman namespace mapping has a gap, overlap or unsafe range")
                    ranges.append((start, start + size))
                    next_container += size
            return {"version": 1, "engine": "podman", "endpoint": "unix://" + socket_path,
                    "socketIdentity": dict(self.endpoint._socket_identity),
                    "serviceIsRemote": host["serviceIsRemote"],
                    "rootless": host["security"]["rootless"], "idMappings": mappings,
                    "store": {"graphRoot": self._path(store["graphRoot"]),
                              "runRoot": self._path(store["runRoot"]),
                              "graphDriverName": store["graphDriverName"],
                              "transientStore": store["transientStore"]}}
        except (KeyError, TypeError) as exc:
            raise AthenaEvidenceError("Podman storage authority fields are missing") from exc

    def _check_roots(self) -> None:
        for key, descriptor in self.roots.items():
            current = self._open_root(self.expected["store"][key])
            try:
                expected = self.expected["rootIdentities"][key]
                if (self._metadata(os.fstat(descriptor)) != expected
                        or self._metadata(os.fstat(current)) != expected):
                    raise AthenaEvidenceError("Podman storage root was replaced")
            finally:
                os.close(current)

    def identity(self) -> dict:
        self._check_roots()
        current = self._info()
        self._check_roots()
        current["rootIdentities"] = self.expected["rootIdentities"]
        if current != self.expected:
            raise AthenaEvidenceError("Podman storage authority changed")
        # Socket, runRoot and service process belong to this authenticated
        # session. Persist only the non-transient graph-store authority so a
        # fresh rootless session can reconcile effects after service restart.
        durable = {"version": 2, "engine": "podman", "serviceUid": os.geteuid(),
                   "serviceGid": os.getegid(), "rootless": True,
                   "idMappings": current["idMappings"],
                   "store": {key: current["store"][key] for key in
                             ("graphRoot", "graphDriverName", "transientStore")},
                   "graphRootIdentity": current["rootIdentities"]["graphRoot"]}
        return json.loads(_canonical_json(durable))

    def close(self) -> None:
        for descriptor in self.roots.values():
            os.close(descriptor)
        self.roots.clear()


class _ContainerEndpointBinding:
    """Parent-owned RPC authority for one namespace-pinned runtime socket."""

    def __init__(self, descriptor: int, endpoint_path: str | None = None) -> None:
        self._lock = threading.RLock()
        self._effects: dict[object, object] = {}
        self._closed = False
        self._retired = False
        self._poisoned = False
        self._pidfd = -1
        self._process = None
        self._supervisor = None
        self._executor_registered = False
        self._identity = None
        self._endpoint_path = endpoint_path
        self._storage_authority = None
        self._channel, child = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
        python = None
        try:
            python = _trusted_python_executable()
            with _defer_process_acquisition_interrupt():
                self._process = subprocess.Popen(
                    [python.execution_path, "-I", "-S", "-c", _ENDPOINT_BROKER,
                     str(child.fileno()), str(descriptor)],
                    executable=python.execution_path,
                    stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    env={"PATH": RUNTIME_PATH, "LANG": "C", "LC_ALL": "C"},
                    close_fds=True, pass_fds=(python.descriptor, child.fileno(), descriptor),
                    start_new_session=True,
                )
            import legacy_runtime
            identity = legacy_runtime._linux_process_identity(self._process.pid)
            if identity is None:
                raise AthenaEvidenceError("endpoint broker exited before acquisition")
            self._pidfd = os.pidfd_open(self._process.pid, 0)
            if legacy_runtime._linux_process_identity(self._process.pid) != identity:
                raise AthenaEvidenceError("endpoint broker changed during acquisition")
            self._identity = identity
            child.close()
            if self._receive(time.monotonic() + 5) != b"ready":
                raise AthenaEvidenceError("endpoint broker did not prove its socket mount")
            self._socket_identity = _PodmanStorageAuthority._metadata(os.fstat(descriptor))
        except BaseException:
            if self._process is not None:
                if self._pidfd >= 0:
                    try:
                        signal.pidfd_send_signal(self._pidfd, signal.SIGKILL, None, 0)
                    except ProcessLookupError:
                        pass
                else:
                    self._process.kill()
                self._process.wait(timeout=PROCESS_REAP_SECONDS)
            self._channel.close()
            if self._pidfd >= 0:
                os.close(self._pidfd)
                self._pidfd = -1
            raise
        finally:
            child.close()
            if python is not None:
                python.close()

    def bind_storage_authority(self, runtime: _BoundExecutable, kind: str = "podman") -> None:
        with self._lock:
            if (self._closed or self._retired or self._poisoned
                    or os.path.basename(kind) != "podman" or not self._endpoint_path
                    or self._storage_authority is not None):
                raise AthenaEvidenceError("local Podman storage authority cannot be bound")
            self._storage_authority = _PodmanStorageAuthority(self, runtime)

    def durable_effect_identity(self) -> dict:
        with self._lock:
            if (self._closed or self._retired or self._poisoned
                    or self._storage_authority is None):
                raise AthenaEvidenceError("durable container storage authority is unavailable")
            try:
                return self._storage_authority.identity()
            except BaseException:
                self._poisoned = True
                raise

    @staticmethod
    def _remaining(deadline: float) -> float:
        value = deadline - time.monotonic()
        if value <= 0:
            raise AthenaEvidenceError("endpoint broker deadline expired")
        return value

    def _receive(self, deadline: float) -> bytes:
        def exact(size: int) -> bytes:
            output = bytearray()
            while len(output) < size:
                self._channel.settimeout(self._remaining(deadline))
                data = self._channel.recv(size - len(output))
                if not data:
                    raise AthenaEvidenceError("endpoint broker closed unexpectedly")
                output.extend(data)
            return bytes(output)
        size = struct.unpack("!I", exact(4))[0]
        if not 0 < size <= 12 + MAX_OUTPUT_BYTES + MAX_CONTAINER_STDERR_BYTES:
            raise AthenaEvidenceError("endpoint broker response exceeded its bound")
        return exact(size)

    def _request(self, request: dict, deadline: float, descriptors: tuple[int, ...] = ()) -> bytes:
        if self._closed or self._retired or self._poisoned or self._pidfd < 0:
            raise AthenaEvidenceError("endpoint broker authority is closed or unproven")
        if select.select([self._pidfd], [], [], 0)[0]:
            self._poisoned = True
            raise AthenaEvidenceError("endpoint broker lost its exact process authority")
        payload = json.dumps(request, ensure_ascii=True, allow_nan=False, separators=(",", ":")).encode("ascii")
        if len(payload) > MAX_CONTAINER_REQUEST_BYTES:
            raise AthenaEvidenceError("endpoint broker request exceeded its bound")
        framed = struct.pack("!I", len(payload)) + payload
        ancillary = [] if not descriptors else [
            (socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", descriptors))
        ]
        try:
            self._channel.settimeout(self._remaining(deadline))
            sent = self._channel.sendmsg([framed], ancillary)
            if sent <= 0:
                raise AthenaEvidenceError("endpoint broker command channel closed")
            view = memoryview(framed)[sent:]
            while view:
                self._channel.settimeout(self._remaining(deadline))
                sent = self._channel.send(view)
                if sent <= 0:
                    raise AthenaEvidenceError("endpoint broker command channel closed")
                view = view[sent:]
            return self._receive(deadline)
        except BaseException as exc:
            self._poisoned = True
            if isinstance(exc, (OSError, TimeoutError)):
                raise AthenaEvidenceError("endpoint broker command did not complete safely") from exc
            raise

    def enter_command(
        self, runtime: _BoundExecutable, argv: list[str], *,
        input_text: str | None = None, timeout_seconds: float = COMMAND_TIMEOUT_SECONDS,
    ) -> subprocess.CompletedProcess:
        if (not isinstance(runtime, _BoundExecutable) or runtime.descriptor < 0
                or not isinstance(argv, list) or not 1 <= len(argv) <= 4096
                or any(not isinstance(value, str) or "\x00" in value or len(value.encode("utf-8")) > 131072 for value in argv)
                or sum(len(value.encode("utf-8")) for value in argv) > MAX_INPUT_BYTES
                or (input_text is not None and (not isinstance(input_text, str) or len(input_text.encode("utf-8")) > MAX_CONTAINER_INPUT_BYTES))
                or isinstance(timeout_seconds, bool) or not isinstance(timeout_seconds, (int, float))
                or not math.isfinite(timeout_seconds) or not 0 < timeout_seconds <= MAX_BOUNDED_PROCESS_TIMEOUT_SECONDS):
            raise AthenaEvidenceError("endpoint broker command bounds are invalid")
        deadline = time.monotonic() + timeout_seconds
        if not self._lock.acquire(timeout=timeout_seconds):
            raise AthenaEvidenceError("endpoint broker command lock deadline expired")
        try:
            references = sorted({
                int(match.group(1))
                for index, value in enumerate(argv)
                if index and argv[index - 1] == "--cidfile"
                for match in re.finditer(rf"/proc/{os.getpid()}/fd/([0-9]+)(?=/|:|$)", value)
            })
            if len(references) > 32:
                raise AthenaEvidenceError("endpoint command has too many retained directories")
            retained = []
            try:
                for descriptor in references:
                    duplicate = os.dup(descriptor)
                    retained.append(duplicate)
                    if not stat.S_ISDIR(os.fstat(duplicate).st_mode):
                        raise AthenaEvidenceError("endpoint command reference is not a directory")
                response = self._request(
                    {"operation": "run", "arguments": argv, "input": input_text,
                     "deadline": deadline, "references": references},
                    deadline + PROCESS_REAP_SECONDS + 2, (runtime.descriptor, *retained),
                )
            finally:
                for descriptor in retained:
                    os.close(descriptor)
            if len(response) < 12:
                self._poisoned = True
                raise AthenaEvidenceError("endpoint broker response is malformed")
            code, out_size, err_size = struct.unpack("!iII", response[:12])
            if out_size > MAX_OUTPUT_BYTES or err_size > MAX_CONTAINER_STDERR_BYTES or len(response) != 12 + out_size + err_size:
                self._poisoned = True
                raise AthenaEvidenceError("endpoint broker response is malformed")
            return subprocess.CompletedProcess(
                [runtime.execution_path, *argv], code,
                response[12:12 + out_size].decode("utf-8", errors="replace"),
                response[12 + out_size:].decode("utf-8", errors="replace"),
            )
        finally:
            self._lock.release()

    def register_effect(self, effect: object, supervisor: object) -> None:
        with self._lock:
            if self._closed or self._retired or self._poisoned or effect in self._effects:
                raise AthenaEvidenceError("endpoint broker cannot register an external effect")
            if self._supervisor is not None and self._supervisor is not supervisor:
                raise AthenaEvidenceError("endpoint broker cannot cross worker authorities")
            if self._supervisor is None:
                supervisor._register_cleanup_executor(self._identity)
                self._executor_registered = True
                self._supervisor = supervisor
            self._effects[effect] = supervisor

    def release_effect(self, effect: object) -> None:
        with self._lock:
            if effect not in self._effects or not effect._extinction_proven:
                raise AthenaEvidenceError("endpoint broker cannot release an unproven effect")
            if len(self._effects) == 1:
                self._retire()
                if self._executor_registered:
                    self._supervisor._unregister_cleanup_executor(self._identity)
                    self._executor_registered = False
                self._supervisor._extinguish_descendants()
            del self._effects[effect]

    def _retire(self) -> None:
        if self._retired:
            return
        if self._request({"operation": "close"}, time.monotonic() + 5) != b"closed":
            raise AthenaEvidenceError("endpoint broker did not prove descendant extinction")
        self._process.wait(timeout=PROCESS_REAP_SECONDS)
        if self._process.returncode != 0 or not select.select([self._pidfd], [], [], 0)[0]:
            raise AthenaEvidenceError("endpoint broker extinction is unproven")
        self._retired = True

    def close(self) -> None:
        with self._lock:
            if self._closed:
                return
            if self._effects:
                raise AthenaEvidenceError("endpoint broker has registered external effects")
            self._retire()
            if self._storage_authority is not None:
                self._storage_authority.close()
            self._channel.close()
            os.close(self._pidfd)
            self._pidfd = -1
            self._closed = True

    def __enter__(self) -> _ContainerEndpointBinding:
        if self._closed or self._retired or self._poisoned:
            raise AthenaEvidenceError("endpoint broker authority is unavailable")
        return self

    def __exit__(self, *_exc: object) -> bool:
        self.close()
        return False


def trusted_container_endpoint(runtime: str = "podman") -> _ContainerEndpointBinding:
    """Prearm a Linux namespace broker before candidate execution or sealing."""
    if (sys.platform != "linux" or not hasattr(os, "O_PATH")
            or not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal")):
        raise AthenaEvidenceError("endpoint containment requires Linux namespace and pidfd authority")
    path = _container_endpoint_path(runtime)
    descriptor = _acquire_container_socket(path)
    try:
        return _ContainerEndpointBinding(descriptor, path)
    finally:
        os.close(descriptor)


def _trusted_container_endpoint() -> str:
    """Validate a socket whose pathname has an independent trust anchor."""
    endpoint = os.environ.get("ODYSSEUS_CONTAINER_ENDPOINT", "")
    if not endpoint.startswith("unix://") or "\x00" in endpoint:
        raise AthenaEvidenceError(
            "ODYSSEUS_CONTAINER_ENDPOINT must explicitly bind a Unix socket"
        )
    path = endpoint.removeprefix("unix://")
    if (
        not os.path.isabs(path)
        or os.path.normpath(path) != path
        or os.path.realpath(path) != path
    ):
        raise AthenaEvidenceError("the container runtime endpoint is not canonical")
    try:
        metadata = os.stat(path, follow_symlinks=False)
        parent_metadata = os.stat(os.path.dirname(path), follow_symlinks=False)
    except OSError as exc:
        raise AthenaEvidenceError(
            "the container runtime endpoint is unavailable"
        ) from exc
    if (
        not stat.S_ISSOCK(metadata.st_mode)
        or metadata.st_uid not in {0, os.geteuid()}
        or not stat.S_ISDIR(parent_metadata.st_mode)
        or parent_metadata.st_uid not in {0, os.geteuid()}
        or stat.S_IMODE(parent_metadata.st_mode) & 0o022
    ):
        raise AthenaEvidenceError("the container runtime endpoint is unsafe")
    # Container clients consume this pathname after this function returns.  A
    # socket descriptor cannot be handed to Docker or Podman, so bind the
    # pathname to a root-owned, non-writable directory chain instead of trying
    # to re-stat it immediately before the client process starts.
    _require_root_owned_ancestry(path, "the container runtime endpoint")
    return endpoint


def container_runtime_environment() -> dict[str, str]:
    """Reject environment-only container execution without retained authority."""
    raise AthenaEvidenceError("container commands require binding.enter_command")


def _sanitized_environment(
    gh_executable: _BoundExecutable | None,
    gh_config_directory: str,
    git_executable: _BoundExecutable | None = None,
    python_executable: _BoundExecutable | None = None,
    git_exec_path: str | None = None,
) -> dict[str, str]:
    """Return the fixed GitHub environment; ignore host routing and startup state."""
    environment = {
        "HOME": gh_config_directory,
        "GH_CONFIG_DIR": gh_config_directory,
        "GH_HOST": "github.com",
        "GH_PROMPT_DISABLED": "1",
        "GIT_TERMINAL_PROMPT": "0",
        "NO_PROXY": "*",
        "no_proxy": "*",
        "NO_COLOR": "1",
        "LANG": "C",
        "LC_ALL": "C",
    }
    if gh_executable is not None:
        environment["ODYSSEUS_GH_EXECUTABLE_FD"] = str(
            gh_executable.descriptor
        )
        environment["ODYSSEUS_GH_EXECUTABLE_SHA256"] = gh_executable.sha256
    if git_executable is not None:
        environment["ODYSSEUS_GIT_EXECUTABLE_FD"] = str(
            git_executable.descriptor
        )
        environment["ODYSSEUS_GIT_EXECUTABLE_SHA256"] = git_executable.sha256
        if git_exec_path is None:
            raise AthenaEvidenceError("the Git helper dependency closure is missing")
        environment["ODYSSEUS_GIT_EXEC_PATH"] = git_exec_path
    if python_executable is not None:
        environment["ODYSSEUS_PYTHON_EXECUTABLE_FD"] = str(
            python_executable.descriptor
        )
        environment["ODYSSEUS_PYTHON_EXECUTABLE_SHA256"] = python_executable.sha256
    token = os.environ.get("GH_TOKEN") or os.environ.get("GITHUB_TOKEN")
    if gh_executable is not None and token:
        if len(token) > 64 * 1024 or re.search(r"[\x00\r\n]", token):
            raise AthenaEvidenceError("the GitHub credential is malformed")
        environment["GH_TOKEN"] = token
    return environment


def _local_helper_environment() -> dict[str, str]:
    """Return only the deterministic locale required by source-only helpers."""
    return {"LANG": "C", "LC_ALL": "C"}


def run_github_cli(
    arguments: list[str],
    *,
    input_text: str | None = None,
    cwd: str | None = None,
    timeout_seconds: float = COMMAND_TIMEOUT_SECONDS,
    max_output_bytes: int = MAX_OUTPUT_BYTES,
) -> subprocess.CompletedProcess:
    """Run one GitHub CLI command through the retained, bounded authority."""
    if (
        not isinstance(arguments, list)
        or not arguments
        or not all(
            isinstance(argument, str)
            and argument
            and "\x00" not in argument
            and len(argument.encode("utf-8")) <= 1024 * 1024
            for argument in arguments
        )
    ):
        raise AthenaEvidenceError("GitHub CLI arguments are malformed")
    if arguments[0] == "gh":
        raise AthenaEvidenceError("GitHub CLI arguments must omit the executable")
    if input_text is not None and len(input_text.encode("utf-8")) > MAX_INPUT_BYTES:
        raise AthenaEvidenceError("GitHub CLI input exceeds 1 MiB")

    bound = _trusted_gh_executable()
    try:
        with tempfile.TemporaryDirectory(prefix="odysseus-gh-") as config_root:
            config_root = os.path.realpath(config_root)
            metadata = os.stat(config_root, follow_symlinks=False)
            if (
                not stat.S_ISDIR(metadata.st_mode)
                or metadata.st_uid != os.geteuid()
                or stat.S_IMODE(metadata.st_mode) != 0o700
            ):
                raise AthenaEvidenceError(
                    "the GitHub CLI private configuration directory is unsafe"
                )
            environment = _sanitized_environment(bound, config_root)
            return _run_bounded_process(
                [bound.execution_path, *arguments],
                executable=bound.execution_path,
                input_text=input_text,
                cwd=cwd,
                environment=environment,
                timeout_seconds=timeout_seconds,
                max_output_bytes=max_output_bytes,
                max_stderr_bytes=MAX_STDERR_BYTES,
                pass_fds=(bound.descriptor,),
            )
    finally:
        bound.close()


class _OwnedProcess:
    """Provide the small ``Popen`` surface for an OS-spawned supervisor."""

    def __init__(
        self,
        process_id: int,
        stdout_descriptor: int,
        stderr_descriptor: int,
    ) -> None:
        self.pid = process_id
        self.stdout = os.fdopen(stdout_descriptor, "rb", buffering=0)
        self.stderr = os.fdopen(stderr_descriptor, "rb", buffering=0)
        self.returncode: int | None = None
        self.supervisor_pidfd: int | None = None
        self.containment_pidfd: int | None = None
        if sys.platform.startswith("linux"):
            try:
                self.supervisor_pidfd = os.pidfd_open(process_id, 0)
            except (AttributeError, OSError):
                self.supervisor_pidfd = None

    def bind_containment(self, process_id: int) -> None:
        if not sys.platform.startswith("linux"):
            return
        if process_id <= 1 or process_id == self.pid:
            raise AthenaEvidenceError("the PID namespace identity is malformed")
        try:
            descriptor = os.pidfd_open(process_id, 0)
        except (AttributeError, OSError) as exc:
            raise AthenaEvidenceError(
                "the PID namespace authority object is unavailable"
            ) from exc
        if self.containment_pidfd is not None:
            os.close(descriptor)
            raise AthenaEvidenceError("the PID namespace authority was duplicated")
        self.containment_pidfd = descriptor

    def close_authority(self) -> None:
        for name in ("containment_pidfd", "supervisor_pidfd"):
            descriptor = getattr(self, name)
            if descriptor is not None:
                os.close(descriptor)
                setattr(self, name, None)

    def wait(self, timeout: float | None = None) -> int:
        if self.returncode is not None:
            return self.returncode
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            try:
                process_id, status = os.waitpid(self.pid, os.WNOHANG)
            except ChildProcessError:
                if self.returncode is None:
                    raise
                return self.returncode
            if process_id == self.pid:
                self.returncode = os.waitstatus_to_exitcode(status)
                return self.returncode
            if deadline is not None and time.monotonic() >= deadline:
                raise subprocess.TimeoutExpired(["owned-process"], timeout)
            time.sleep(PROCESS_POLL_SECONDS)


def _child_has_exited(process_id: int) -> bool:
    required = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if any(not hasattr(os, name) for name in required):
        raise AthenaEvidenceError(
            "safe no-reap process observation is unavailable"
        )
    try:
        result = os.waitid(
            os.P_PID,
            process_id,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except InterruptedError:
        return False
    except ChildProcessError as exc:
        raise AthenaEvidenceError("the Athena helper process lost ownership") from exc
    return result is not None


def _process_group_exists(process_group: int) -> bool:
    try:
        os.killpg(process_group, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


class _DarwinProcessInfo(ctypes.Structure):
    # proc_bsdinfo, PROC_PIDTBSDINFO, from the Darwin SDK sys/proc_info.h.
    _fields_ = [
        (name, ctypes.c_uint32) for name in (
            "flags", "status", "xstatus", "pid", "ppid", "uid", "gid",
            "ruid", "rgid", "svuid", "svgid", "reserved",
        )
    ] + [("comm", ctypes.c_char * 16), ("name", ctypes.c_char * 32)] + [
        (name, ctypes.c_uint32) for name in (
            "nfiles", "pgid", "jobc", "tty", "tty_pgid", "nice",
        )
    ] + [("start_seconds", ctypes.c_uint64), ("start_microseconds", ctypes.c_uint64)]


def _darwin_process_is_extinct(process_id: int) -> bool:
    """Read KERN_PROC_PID, which retains the state of unreaped zombies."""
    if sys.platform != "darwin" or ctypes.sizeof(ctypes.c_void_p) != 8:
        raise AthenaEvidenceError("Darwin kernel process-state proof is unavailable")

    class ProcessPrefix(ctypes.Structure):
        # kinfo_proc begins with extern_proc. This fixed 64-bit SDK prefix
        # ends before any version-dependent tail; validate both length and PID.
        _fields_ = [
            ("start", ctypes.c_uint64 * 2),
            ("vmspace", ctypes.c_void_p), ("sigacts", ctypes.c_void_p),
            ("flags", ctypes.c_int), ("status", ctypes.c_byte),
            ("pid", ctypes.c_int), ("original_parent", ctypes.c_int),
        ]

    library = ctypes.CDLL(None, use_errno=True)
    library.sysctl.argtypes = [
        ctypes.POINTER(ctypes.c_int), ctypes.c_uint, ctypes.c_void_p,
        ctypes.POINTER(ctypes.c_size_t), ctypes.c_void_p, ctypes.c_size_t,
    ]
    library.sysctl.restype = ctypes.c_int
    mib = (ctypes.c_int * 4)(1, 14, 1, process_id)  # CTL_KERN/KERN_PROC/PID
    buffer = ctypes.create_string_buffer(4096)
    size = ctypes.c_size_t(len(buffer))
    if library.sysctl(mib, 4, buffer, ctypes.byref(size), None, 0) != 0:
        raise AthenaEvidenceError("Darwin kernel process state cannot be read")
    if size.value == 0:
        return True
    if not ctypes.sizeof(ProcessPrefix) <= size.value <= len(buffer):
        raise AthenaEvidenceError("Darwin kernel process state is malformed")
    state = ProcessPrefix.from_buffer(buffer)
    if state.pid != process_id or state.status not in {1, 2, 3, 4, 5}:
        raise AthenaEvidenceError("Darwin kernel process identity is unproven")
    return state.status == 5  # SZOMB has no executable task.


def _darwin_extinguish_group(process_group: int) -> None:
    """Prove no executable group member remains while the leader pins PGID."""
    libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)
    libproc.proc_pidinfo.argtypes = [
        ctypes.c_int, ctypes.c_int, ctypes.c_uint64, ctypes.c_void_p, ctypes.c_int,
    ]
    libproc.proc_pidinfo.restype = ctypes.c_int
    libproc.proc_listpids.argtypes = [
        ctypes.c_uint32, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_int,
    ]
    libproc.proc_listpids.restype = ctypes.c_int

    def info(pid: int) -> _DarwinProcessInfo | None:
        while True:
            result = _DarwinProcessInfo()
            size = libproc.proc_pidinfo(pid, 3, 0, ctypes.byref(result), ctypes.sizeof(result))
            if size == 0 and ctypes.get_errno() == errno.ESRCH:
                if _darwin_process_is_extinct(pid):
                    return None
                # libproc can temporarily hide a task that KERN_PROC still
                # reports as executable. Never equate ESRCH with extinction;
                # require either its exact identity or a positive exit proof.
                if time.monotonic() >= deadline:
                    raise AthenaEvidenceError("Darwin executable process identity is unavailable")
                time.sleep(PROCESS_POLL_SECONDS)
                continue
            if size != ctypes.sizeof(result):
                raise AthenaEvidenceError("Darwin process identity cannot be verified")
            return result

    deadline = time.monotonic() + PROCESS_REAP_SECONDS

    def retain_leader() -> None:
        # A successful WNOWAIT (including a None/non-waitable result) proves
        # this is still our unreaped child. libproc can hide a dying process
        # slightly before waitid reports its exit, so exit status is not the
        # ownership oracle. ECHILD or an unresolvable interruption fails closed.
        while True:
            try:
                os.waitid(os.P_PID, process_group, os.WEXITED | os.WNOHANG | os.WNOWAIT)
                return
            except InterruptedError:
                if time.monotonic() >= deadline:
                    raise AthenaEvidenceError("Darwin leader ownership is unproven")
            except ChildProcessError as exc:
                raise AthenaEvidenceError("Darwin process group lost its retained leader") from exc

    retain_leader()
    leader = info(process_group)
    # libproc deliberately hides zombie BSD records. waitid(WNOWAIT) still
    # proves that this exact, unreaped child pins the numeric PID/PGID.
    if leader is not None and (leader.ppid != os.getpid() or leader.pgid != process_group):
        raise AthenaEvidenceError("Darwin process group has no retained leader authority")
    leader_identity = (leader.start_seconds, leader.start_microseconds) if leader is not None else None
    while True:
        retain_leader()
        current = info(process_group)
        if (current is not None and leader_identity is not None
            and (current.start_seconds, current.start_microseconds) != leader_identity
        ):
            raise AthenaEvidenceError("Darwin process group lost its retained leader")
        pids = (ctypes.c_int * 65536)()
        ctypes.set_errno(0)
        size = libproc.proc_listpids(2, process_group, pids, ctypes.sizeof(pids))
        if (size < 0 or (size == 0 and ctypes.get_errno() not in {0, errno.ESRCH})
                or size >= ctypes.sizeof(pids) or size % ctypes.sizeof(ctypes.c_int)):
            raise AthenaEvidenceError("Darwin process group inventory is unproven")
        live = []
        for pid in pids[:size // ctypes.sizeof(ctypes.c_int)]:
            if pid <= 0:
                continue
            member = info(pid)
            if member is None:
                continue
            if member.pgid != process_group:
                raise AthenaEvidenceError("Darwin process group membership changed")
            if member.status != 5:  # SZOMB cannot execute or create descendants.
                live.append(member)
        if not live:
            return
        for member in live:
            rebound = info(member.pid)
            if rebound is None:
                continue
            if (rebound.pgid, rebound.start_seconds, rebound.start_microseconds) != (
                process_group, member.start_seconds, member.start_microseconds,
            ):
                raise AthenaEvidenceError("Darwin descendant identity changed before signal")
            try:
                os.kill(member.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            except OSError as exc:
                raise AthenaEvidenceError("Darwin descendant cannot be killed") from exc
        if time.monotonic() >= deadline:
            raise AthenaEvidenceError("Darwin process group remains executable")
        time.sleep(PROCESS_POLL_SECONDS)


def _stop_process_group(process: subprocess.Popen) -> int:
    """Terminate, kill, and reap one private helper process group."""
    if sys.platform.startswith("linux") and isinstance(process, _OwnedProcess):
        if process.returncode is not None:
            process.close_authority()
            return process.returncode
        errors: list[BaseException] = []

        def active(descriptor: int | None) -> bool:
            if descriptor is None:
                return False
            readable, _writable, _exceptional = select.select(
                [descriptor], [], [], 0
            )
            return not bool(readable)

        supervisor = process.supervisor_pidfd
        containment = process.containment_pidfd
        if supervisor is None:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait(timeout=PROCESS_REAP_SECONDS)
            raise AthenaEvidenceError(
                "the kernel containment authority is incomplete"
            )
        try:
            if active(supervisor):
                signal.pidfd_send_signal(supervisor, signal.SIGTERM, None, 0)
            deadline = time.monotonic() + PROCESS_TERMINATE_SECONDS
            while active(supervisor) and time.monotonic() < deadline:
                time.sleep(PROCESS_POLL_SECONDS)
            if active(containment):
                signal.pidfd_send_signal(containment, signal.SIGKILL, None, 0)
            if active(supervisor):
                signal.pidfd_send_signal(supervisor, signal.SIGKILL, None, 0)
            if containment is None:
                try:
                    os.killpg(process.pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
            deadline = time.monotonic() + PROCESS_REAP_SECONDS
            while (
                (active(containment) or active(supervisor))
                and time.monotonic() < deadline
            ):
                time.sleep(PROCESS_POLL_SECONDS)
            if active(containment) or active(supervisor):
                raise AthenaEvidenceError(
                    "the kernel containment object did not become extinct"
                )
            process.wait(timeout=0)
        except BaseException as exc:
            errors.append(exc)
        finally:
            try:
                process.close_authority()
            except BaseException as exc:
                errors.append(exc)
        if errors:
            raise errors[0]
        if process.returncode is None:
            raise AthenaEvidenceError("the Athena helper leader was not reaped")
        return process.returncode

    if process.returncode is not None:
        raise AthenaEvidenceError("the Athena helper leader authority was already reaped")
    process_group = process.pid
    cleanup_error = None
    try:
        os.killpg(process_group, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except OSError as exc:
        cleanup_error = AthenaEvidenceError(
            "the Athena helper process group cannot be terminated"
        )
        cleanup_error.__cause__ = exc

    deadline = time.monotonic() + PROCESS_TERMINATE_SECONDS
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            break
        time.sleep(min(PROCESS_POLL_SECONDS, remaining))

    # Send the terminal group signal while the unreaped leader still owns its
    # numeric PID/PGID. Never signal or query that identifier after wait(2),
    # when the kernel may already have reused it for an unrelated process.
    try:
        os.killpg(process_group, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except OSError as exc:
        if cleanup_error is None:
            cleanup_error = AthenaEvidenceError(
                "the Athena helper process group cannot be killed"
            )
            cleanup_error.__cause__ = exc

    if sys.platform == "darwin":
        # Neither an accepted signal nor EPERM proves extinction. Inventory
        # and extinguish executable members before reaping the PGID owner.
        # A failed proof retains the unreaped leader for an exact retry.
        try:
            _darwin_extinguish_group(process_group)
        except (AthenaEvidenceError, OSError) as proof_error:
            raise AthenaEvidenceError(
                "the Athena helper process group extinction is unproven"
            ) from proof_error
        cleanup_error = None

    try:
        process.wait(timeout=PROCESS_REAP_SECONDS)
    except subprocess.TimeoutExpired:
        try:
            os.kill(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        except OSError as exc:
            if cleanup_error is None:
                cleanup_error = AthenaEvidenceError(
                    "the Athena helper leader cannot be killed"
                )
                cleanup_error.__cause__ = exc
        try:
            process.wait(timeout=PROCESS_REAP_SECONDS)
        except (ChildProcessError, subprocess.TimeoutExpired) as exc:
            if cleanup_error is None:
                cleanup_error = AthenaEvidenceError(
                    "the Athena helper leader cannot be reaped"
                )
                cleanup_error.__cause__ = exc
    except ChildProcessError as exc:
        if cleanup_error is None:
            cleanup_error = AthenaEvidenceError(
                "the Athena helper leader lost ownership"
            )
            cleanup_error.__cause__ = exc

    if cleanup_error is not None:
        raise cleanup_error
    if process.returncode is None:
        raise AthenaEvidenceError("the Athena helper leader was not reaped")
    return process.returncode


def _finalize_process_resources(state: dict[str, object]) -> None:
    """Finish process cleanup even when one cleanup operation is interrupted."""
    cleanup_errors: list[BaseException] = []
    process = state.get("process")
    if process is not None:
        try:
            state["leader_returncode"] = _stop_process_group(process)
        except BaseException as exc:
            cleanup_errors.append(exc)
            if sys.platform.startswith("linux") and isinstance(
                process, _OwnedProcess
            ):
                should_retry = process.returncode is None and (
                    process.supervisor_pidfd is not None
                    or process.containment_pidfd is not None
                )
            else:
                should_retry = process.returncode is None
            if should_retry:
                try:
                    state["leader_returncode"] = _stop_process_group(process)
                except BaseException as retry_exc:
                    cleanup_errors.append(retry_exc)
            elif process.returncode is not None:
                state["leader_returncode"] = process.returncode

    readers = state["readers"]
    reader_deadline = time.monotonic() + PROCESS_REAP_SECONDS
    for reader in readers:
        if reader.ident is None:
            continue
        while True:
            remaining = max(0.0, reader_deadline - time.monotonic())
            try:
                reader.join(remaining)
            except BaseException as exc:
                cleanup_errors.append(exc)
                if time.monotonic() >= reader_deadline:
                    break
                continue
            if not reader.is_alive() or remaining <= 0:
                break
    if any(
        reader.ident is not None and reader.is_alive()
        for reader in readers
    ):
        cleanup_errors.append(AthenaEvidenceError(
            "the Athena helper output readers did not stop"
        ))

    for stream in state["streams"]:
        try:
            stream.close()
        except BaseException as exc:
            cleanup_errors.append(exc)
    input_stream = state.get("input_stream")
    if input_stream is not None:
        try:
            input_stream.close()
        except BaseException as exc:
            cleanup_errors.append(exc)
    for name in ("status_read_descriptor", "status_write_descriptor"):
        descriptor = state[name]
        if descriptor < 0:
            continue
        try:
            os.close(descriptor)
        except OSError:
            pass
        except BaseException as exc:
            cleanup_errors.append(exc)
        finally:
            state[name] = -1

    if cleanup_errors:
        raise cleanup_errors[0]


@contextmanager
def _defer_process_acquisition_interrupt():
    """Defer Python SIGINT delivery until a spawned PID has an owner.

    pthread_sigmask alone is insufficient: another unblocked thread can receive
    a process-directed signal and schedule Python's handler on the main thread.
    """
    if threading.current_thread() is not threading.main_thread():
        yield
        return
    previous = signal.getsignal(signal.SIGINT)
    pending = False

    def defer(_number, _frame):
        nonlocal pending
        pending = True

    signal.signal(signal.SIGINT, defer)
    try:
        yield
    finally:
        signal.signal(signal.SIGINT, previous)
        if pending:
            if callable(previous):
                previous(signal.SIGINT, None)
            elif previous == signal.SIG_DFL:
                signal.raise_signal(signal.SIGINT)


def _spawn_owned_process(
    command: list[str],
    *,
    executable: str | None,
    stdin,
    status_descriptor: int,
    cwd: str | None,
    environment: dict[str, str],
    owner: dict[str, object],
    pass_fds: tuple[int, ...],
    supervisor_binding: _BoundExecutable | None = None,
    acquisition_deadline: float | None = None,
    address_space_bytes: int = PROCESS_MAX_ADDRESS_SPACE_BYTES,
    cpu_seconds: int | None = None,
    aggregate_quota: _AggregateQuota | None = None,
) -> _OwnedProcess:
    """Acquire a killable OS supervisor before it can create target authority."""
    if sys.platform.startswith("linux") and supervisor_binding is None:
        raise AthenaEvidenceError(
            "the independently trusted supervisor interpreter is unavailable"
        )
    if acquisition_deadline is None:
        acquisition_deadline = time.monotonic() + COMMAND_TIMEOUT_SECONDS
    if cpu_seconds is None:
        cpu_seconds = max(1, math.ceil(COMMAND_TIMEOUT_SECONDS) + 1)
    required_spawn_surface = (
        "posix_spawn",
        "POSIX_SPAWN_DUP2",
        "POSIX_SPAWN_OPEN",
    )
    if any(not hasattr(os, name) for name in required_spawn_surface) or not hasattr(
        signal, "pthread_sigmask"
    ):
        raise AthenaEvidenceError(
            "the killable process acquisition boundary is unavailable"
        )

    acquisition_read, acquisition_write = os.pipe()
    stdout_read, stdout_write = os.pipe()
    stderr_read, stderr_write = os.pipe()
    quota_read, quota_write = os.pipe() if aggregate_quota is not None else (-1, -1)
    process: _OwnedProcess | None = None
    receipt = bytearray()
    try:
        supervisor_descriptor = (
            supervisor_binding.descriptor
            if supervisor_binding is not None
            else None
        )
        sources = {
            status_descriptor,
            acquisition_write,
            stdout_write,
            stderr_write,
            *pass_fds,
        }
        if supervisor_descriptor is not None:
            sources.add(supervisor_descriptor)
        input_descriptor = None
        file_actions = []
        if stdin == subprocess.DEVNULL:
            file_actions.append(
                (os.POSIX_SPAWN_OPEN, 0, "/dev/null", os.O_RDONLY, 0)
            )
        else:
            input_descriptor = stdin.fileno()
            sources.add(input_descriptor)
            file_actions.append(
                (os.POSIX_SPAWN_DUP2, input_descriptor, 0)
            )
        file_actions.extend((
            (os.POSIX_SPAWN_DUP2, stdout_write, 1),
            (os.POSIX_SPAWN_DUP2, stderr_write, 2),
        ))

        mapped_descriptors: dict[int, int] = {}
        candidate = 64
        descriptors_to_map = [status_descriptor, acquisition_write]
        if quota_read >= 0:
            sources.add(quota_read)
            descriptors_to_map.append(quota_read)
        if supervisor_descriptor is not None:
            descriptors_to_map.append(supervisor_descriptor)
        descriptors_to_map.extend(pass_fds)
        for descriptor in descriptors_to_map:
            while candidate in sources or candidate in {0, 1, 2}:
                candidate += 1
            mapped_descriptors[descriptor] = candidate
            file_actions.append((os.POSIX_SPAWN_DUP2, descriptor, candidate))
            candidate += 1

        def remap_reference(value: str) -> str:
            for source, destination in mapped_descriptors.items():
                for prefix in ("/proc/self/fd/", "/dev/fd/"):
                    original = f"{prefix}{source}"
                    if value == original or value.startswith(original + "/"):
                        return f"{prefix}{destination}" + value[len(original):]
            return value

        child_environment = dict(environment)
        child_environment.pop("ODYSSEUS_QUOTA_GATE_FD", None)
        for name, value in tuple(child_environment.items()):
            child_environment[name] = remap_reference(value)
            if not name.endswith("_FD"):
                continue
            for source, destination in mapped_descriptors.items():
                if value == str(source):
                    child_environment[name] = str(destination)
                    break
        if quota_read >= 0:
            child_environment["ODYSSEUS_QUOTA_GATE_FD"] = str(mapped_descriptors[quota_read])
        child_pass_fds = tuple(
            mapped_descriptors[descriptor] for descriptor in pass_fds
        )
        supervisor_executable = (
            remap_reference(supervisor_binding.execution_path)
            if supervisor_binding is not None
            else sys.executable
        )
        supervisor_command = [
            supervisor_executable,
            "-I",
            "-S",
            "-B",
            "-c",
            _PROCESS_SUPERVISOR,
            str(mapped_descriptors[status_descriptor]),
            str(mapped_descriptors[acquisition_write]),
            ",".join(str(descriptor) for descriptor in child_pass_fds),
            remap_reference(executable or ""),
            remap_reference(cwd or ""),
            str(address_space_bytes),
            str(cpu_seconds),
            *(remap_reference(argument) for argument in command),
        ]
        if time.monotonic() >= acquisition_deadline:
            raise AthenaEvidenceError(
                "the Athena helper acquisition deadline expired"
            )
        previous_signal_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT}
        )
        with _defer_process_acquisition_interrupt():
            try:
                try:
                    spawn_options = (
                        {"setsid": True}
                        if sys.platform.startswith("linux")
                        else {"setpgroup": 0}
                    )
                    process_id = os.posix_spawn(
                        supervisor_executable,
                        supervisor_command,
                        child_environment,
                        file_actions=file_actions,
                        **spawn_options,
                    )
                except (NotImplementedError, TypeError):
                    process_id = os.posix_spawn(
                        supervisor_executable,
                        supervisor_command,
                        child_environment,
                        file_actions=file_actions,
                        setpgroup=0,
                    )
                os.close(stdout_write)
                stdout_write = -1
                os.close(stderr_write)
                stderr_write = -1
                os.close(acquisition_write)
                acquisition_write = -1
                process = _OwnedProcess(process_id, stdout_read, stderr_read)
                stdout_read = -1
                stderr_read = -1
                owner["process"] = process
                owner["streams"].extend((process.stdout, process.stderr))
                if (
                    sys.platform.startswith("linux")
                    and process.supervisor_pidfd is None
                ):
                    raise AthenaEvidenceError(
                        "the supervisor authority object is unavailable"
                    )
                if aggregate_quota is not None:
                    aggregate_quota.admit(process)
                    if os.write(quota_write, b"1") != 1:
                        raise AthenaEvidenceError("aggregate quota gate did not release")
                    os.close(quota_write)
                    quota_write = -1
            finally:
                signal.pthread_sigmask(signal.SIG_SETMASK, previous_signal_mask)

        while len(receipt) < PROCESS_ACQUISITION_BYTES:
            remaining = acquisition_deadline - time.monotonic()
            if remaining <= 0:
                raise AthenaEvidenceError(
                    "the Athena helper acquisition deadline expired"
                )
            readable, _writable, _exceptional = select.select(
                [acquisition_read], [], [], remaining
            )
            if not readable:
                raise AthenaEvidenceError(
                    "the Athena helper acquisition deadline expired"
                )
            block = os.read(
                acquisition_read,
                PROCESS_ACQUISITION_BYTES - len(receipt),
            )
            if not block:
                raise AthenaEvidenceError(
                    "the Athena helper acquisition receipt is incomplete"
                )
            receipt.extend(block)
        acquired, target_process_id = struct.unpack("!BI", receipt)
        if acquired != 1 or target_process_id <= 1:
            raise AthenaEvidenceError("the Athena helper process was not acquired")
        process.bind_containment(target_process_id)
        return process
    except BaseException:
        if process is not None:
            cleanup_complete = False
            try:
                _stop_process_group(process)
                cleanup_complete = True
            finally:
                if cleanup_complete:
                    owner["process"] = None
                    for stream in (process.stdout, process.stderr):
                        try:
                            stream.close()
                        except OSError:
                            pass
        raise
    finally:
        for descriptor in (
            acquisition_read,
            acquisition_write,
            stdout_read,
            stdout_write,
            stderr_read,
            stderr_write,
            quota_read,
            quota_write,
        ):
            if descriptor < 0:
                continue
            try:
                os.close(descriptor)
            except OSError:
                pass


def _run_bounded_process_impl(
    command: list[str],
    *,
    input_text: str | None,
    cwd: str | None,
    environment: dict[str, str],
    timeout_seconds: float | None = None,
    max_output_bytes: int | None = None,
    max_stderr_bytes: int | None = None,
    pass_fds: tuple[int, ...] = (),
    executable: str | None = None,
    on_spawn: Callable[[_OwnedProcess], None] | None = None,
    supervisor_binding: _BoundExecutable | None = None,
    aggregate_quota: _AggregateQuota | None = None,
) -> subprocess.CompletedProcess:
    """Run one command with bounded pipes and complete process-tree cleanup."""
    if sys.platform.startswith("linux") and supervisor_binding is None:
        raise AthenaEvidenceError(
            "the independently trusted supervisor interpreter is unavailable"
        )
    if timeout_seconds is None:
        timeout_seconds = COMMAND_TIMEOUT_SECONDS
    if max_output_bytes is None:
        max_output_bytes = MAX_OUTPUT_BYTES
    if max_stderr_bytes is None:
        max_stderr_bytes = MAX_STDERR_BYTES
    if (
        not isinstance(timeout_seconds, (int, float))
        or isinstance(timeout_seconds, bool)
        or not math.isfinite(timeout_seconds)
        or timeout_seconds <= 0
        or timeout_seconds > MAX_BOUNDED_PROCESS_TIMEOUT_SECONDS
    ):
        raise AthenaEvidenceError("the process timeout bound is invalid")
    for maximum_bytes in (max_output_bytes, max_stderr_bytes):
        if (
            type(maximum_bytes) is not int
            or maximum_bytes <= 0
            or maximum_bytes > MAX_BOUNDED_PROCESS_OUTPUT_BYTES
        ):
            raise AthenaEvidenceError("the process output bound is invalid")
    if (
        not isinstance(pass_fds, tuple)
        or any(type(descriptor) is not int or descriptor < 0 for descriptor in pass_fds)
        or len(set(pass_fds)) != len(pass_fds)
    ):
        raise AthenaEvidenceError("the inherited descriptor set is invalid")
    try:
        for descriptor in pass_fds:
            os.fstat(descriptor)
    except OSError as exc:
        raise AthenaEvidenceError("an inherited descriptor is unavailable") from exc
    if on_spawn is not None and not callable(on_spawn):
        raise AthenaEvidenceError("the process spawn observer is invalid")
    if executable is not None:
        match = re.fullmatch(r"/proc/self/fd/([0-9]+)", executable)
        if match is None or int(match.group(1)) not in pass_fds:
            raise AthenaEvidenceError("the retained executable binding is invalid")
    for name in ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT"):
        if not hasattr(os, name):
            raise AthenaEvidenceError(
                "safe no-reap process observation is unavailable"
            )

    if not sys.platform.startswith("linux") and any(
        environment.get(name) for name in GITHUB_CREDENTIAL_VARIABLES
    ):
        raise AthenaEvidenceError(
            "credential-bearing descendant containment is unavailable on this platform"
        )

    deadline = time.monotonic() + timeout_seconds

    process = None
    readers: list[threading.Thread] = []
    streams = []
    state: dict[str, object] = {
        "process": None,
        "readers": readers,
        "streams": streams,
        "input_stream": None,
        "status_read_descriptor": -1,
        "status_write_descriptor": -1,
        "leader_returncode": None,
        "detached_descendant": False,
    }
    chunks: dict[str, list[bytes]] = {
        "stdout": [], "stderr": [], "status": [],
    }
    overflow = threading.Event()
    activity = threading.Event()
    done = {
        "stdout": threading.Event(),
        "stderr": threading.Event(),
        "status": threading.Event(),
    }
    reader_errors: list[BaseException] = []
    finalize_requested = threading.Event()
    finalize_outcome: dict[str, object] = {}

    def finalize() -> None:
        while not finalize_requested.is_set():
            try:
                finalize_requested.wait(PROCESS_POLL_SECONDS)
            except BaseException as exc:
                finalize_outcome.setdefault(
                    "error", (exc, exc.__traceback__)
                )
        try:
            _finalize_process_resources(state)
        except BaseException as exc:
            finalize_outcome.setdefault("error", (exc, exc.__traceback__))

    finalizer = threading.Thread(
        target=finalize,
        daemon=False,
        name="athena-process-finalizer",
    )
    spawn_signal_mask: set[signal.Signals] | None = None
    spawn_signal_mask_active = False

    def restore_spawn_signal_mask() -> None:
        nonlocal spawn_signal_mask_active
        if not spawn_signal_mask_active:
            return
        try:
            signal.pthread_sigmask(signal.SIG_SETMASK, spawn_signal_mask)
        finally:
            spawn_signal_mask_active = False

    def read_stream(name: str, stream, maximum_bytes: int) -> None:
        observed = 0
        try:
            while True:
                block = os.read(stream.fileno(), READ_CHUNK_BYTES)
                if not block:
                    break
                remaining = maximum_bytes + 1 - observed
                if remaining > 0:
                    chunks[name].append(block[:remaining])
                observed += len(block)
                if observed > maximum_bytes:
                    overflow.set()
                    activity.set()
                    break
        except BaseException as exc:  # pragma: no cover - operating-system fault
            reader_errors.append(exc)
            activity.set()
        finally:
            try:
                stream.close()
            finally:
                done[name].set()
                activity.set()

    try:
        spawn_signal_mask = signal.pthread_sigmask(
            signal.SIG_BLOCK, {signal.SIGINT}
        )
        spawn_signal_mask_active = True
        finalizer.start()
        if input_text is not None:
            input_stream = tempfile.TemporaryFile()
            state["input_stream"] = input_stream
            input_stream.write(input_text.encode("utf-8"))
            input_stream.seek(0)
        else:
            input_stream = None
        stdin = subprocess.DEVNULL if input_stream is None else input_stream
        (
            state["status_read_descriptor"],
            state["status_write_descriptor"],
        ) = os.pipe()
        process = _spawn_owned_process(
            command,
            executable=executable,
            stdin=stdin,
            status_descriptor=state["status_write_descriptor"],
            cwd=cwd,
            environment=environment,
            owner=state,
            pass_fds=pass_fds,
            supervisor_binding=supervisor_binding,
            acquisition_deadline=deadline,
            address_space_bytes=PROCESS_MAX_ADDRESS_SPACE_BYTES,
            cpu_seconds=max(1, math.ceil(timeout_seconds) + 1),
            aggregate_quota=aggregate_quota,
        )
        os.close(state["status_write_descriptor"])
        state["status_write_descriptor"] = -1
        if process.stdout is None or process.stderr is None:
            raise AthenaEvidenceError("the Athena helper pipes are unavailable")
        restore_spawn_signal_mask()
        status_stream = os.fdopen(state["status_read_descriptor"], "rb")
        streams.append(status_stream)
        state["status_read_descriptor"] = -1
        readers.extend([
            threading.Thread(
                target=read_stream,
                args=("stdout", process.stdout, max_output_bytes),
                daemon=True,
                name="athena-stdout-reader",
            ),
            threading.Thread(
                target=read_stream,
                args=("stderr", process.stderr, max_stderr_bytes),
                daemon=True,
                name="athena-stderr-reader",
            ),
            threading.Thread(
                target=read_stream,
                args=("status", status_stream, PROCESS_STATUS_BYTES),
                daemon=True,
                name="athena-status-reader",
            ),
        ])
        for reader in readers:
            reader.start()

        if on_spawn is not None:
            on_spawn(process)

        failure = ""
        while True:
            if overflow.is_set():
                failure = "the Athena read exceeded its output bound"
                break
            if reader_errors:
                failure = "the Athena read output cannot be collected"
                break
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                failure = "the Athena read did not complete"
                break
            if all(marker.is_set() for marker in done.values()):
                if overflow.is_set():
                    failure = "the Athena read exceeded its output bound"
                break
            if _child_has_exited(process.pid):
                failure = "the Athena helper supervisor stopped unexpectedly"
                break
            activity.wait(min(PROCESS_POLL_SECONDS, remaining))
            activity.clear()

        if failure:
            raise AthenaEvidenceError(failure)
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        raise AthenaEvidenceError("the Athena read did not complete") from exc
    finally:
        active_error = sys.exc_info()[1]
        interrupted = None
        interrupted_traceback = None
        while spawn_signal_mask_active:
            try:
                restore_spawn_signal_mask()
            except BaseException as exc:
                if interrupted is None:
                    interrupted = exc
                    interrupted_traceback = exc.__traceback__
        while True:
            try:
                finalize_requested.set()
                break
            except BaseException as exc:
                if interrupted is None:
                    interrupted = exc
                    interrupted_traceback = exc.__traceback__
        if finalizer.ident is not None:
            while finalizer.is_alive():
                try:
                    finalizer.join(PROCESS_POLL_SECONDS)
                except BaseException as exc:
                    if interrupted is None:
                        interrupted = exc
                        interrupted_traceback = exc.__traceback__
        cleanup = finalize_outcome.get("error")
        if cleanup is not None:
            cleanup_error, cleanup_traceback = cleanup
            if active_error is not None:
                raise cleanup_error.with_traceback(cleanup_traceback) from active_error
            raise cleanup_error.with_traceback(cleanup_traceback)
        if interrupted is not None and active_error is None:
            raise interrupted.with_traceback(interrupted_traceback)

    leader_returncode = state["leader_returncode"]
    if leader_returncode is None:
        raise AthenaEvidenceError("the Athena helper leader was not reaped")
    status_payload = b"".join(chunks["status"])
    if len(status_payload) != PROCESS_STATUS_BYTES:
        raise AthenaEvidenceError("the Athena helper status is malformed")
    returncode, detached_descendant = struct.unpack("!iB", status_payload)
    if detached_descendant not in {0, 1}:
        raise AthenaEvidenceError("the Athena helper status is malformed")
    if detached_descendant:
        raise AthenaEvidenceError("the Athena helper left a detached descendant")
    try:
        stdout = b"".join(chunks["stdout"]).decode("utf-8")
        stderr = b"".join(chunks["stderr"]).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise AthenaEvidenceError("the Athena read output is not valid UTF-8") from exc
    return subprocess.CompletedProcess(command, returncode, stdout, stderr)


def _run_bounded_process(
    command: list[str],
    *,
    input_text: str | None,
    cwd: str | None,
    environment: dict[str, str],
    timeout_seconds: float | None = None,
    max_output_bytes: int | None = None,
    max_stderr_bytes: int | None = None,
    pass_fds: tuple[int, ...] = (),
    executable: str | None = None,
    on_spawn: Callable[[_OwnedProcess], None] | None = None,
) -> subprocess.CompletedProcess:
    """Run one command through its invocation-owned process supervisor."""
    binding_started = time.monotonic()
    requires_quota = bool(environment.get("ODYSSEUS_REQUIRE_AGGREGATE_QUOTA")) or (
        "ODYSSEUS_GH_EXECUTABLE_FD" in environment
        or any(environment.get(name) for name in GITHUB_CREDENTIAL_VARIABLES)
    )
    aggregate_quota = _AggregateQuota() if requires_quota else None
    supervisor_binding = None
    try:
        supervisor_binding = (
            _trusted_python_executable() if sys.platform.startswith("linux") else None
        )
        bounded_timeout = timeout_seconds
        if timeout_seconds is not None:
            bounded_timeout = timeout_seconds - (time.monotonic() - binding_started)
            if bounded_timeout <= 0:
                raise AthenaEvidenceError(
                    "the Athena evidence workflow deadline expired"
                )
        return _run_bounded_process_impl(
            command,
            input_text=input_text,
            cwd=cwd,
            environment=environment,
            timeout_seconds=bounded_timeout,
            max_output_bytes=max_output_bytes,
            max_stderr_bytes=max_stderr_bytes,
            pass_fds=pass_fds,
            executable=executable,
            on_spawn=on_spawn,
            supervisor_binding=supervisor_binding,
            aggregate_quota=aggregate_quota,
        )
    finally:
        try:
            if aggregate_quota is not None:
                aggregate_quota.close()
        finally:
            if supervisor_binding is not None:
                supervisor_binding.close()


def validated_oci_digest_reference(value: str) -> str:
    """Require one canonical digest-qualified OCI image reference."""
    if (
        not isinstance(value, str)
        or len(value) > 1024
        or OCI_DIGEST_REFERENCE.fullmatch(value) is None
    ):
        raise AthenaEvidenceError(
            "the agent image must be an exact digest-qualified OCI reference"
        )
    return value


def resolve_local_oci_image(
    runtime: str,
    reference: str,
    *,
    environment: dict[str, str] | None = None,
    runtime_binding: _BoundExecutable | None = None,
    endpoint_binding: _ContainerEndpointBinding | None = None,
) -> str:
    """Verify a configured repo digest and return its local content ID."""
    del environment
    trusted_reference = validated_oci_digest_reference(reference)
    if endpoint_binding is None:
        if runtime_binding is not None:
            raise AthenaEvidenceError("image resolution needs the retained endpoint binding")
        with trusted_container_endpoint(runtime) as endpoint:
            bound = _trusted_container_runtime(runtime)
            try:
                return resolve_local_oci_image(
                    runtime, reference, runtime_binding=bound, endpoint_binding=endpoint,
                )
            finally:
                bound.close()
    if runtime_binding is None:
        raise AthenaEvidenceError("image resolution needs the retained runtime binding")
    try:
        result = endpoint_binding.enter_command(
            runtime_binding,
            [
                "image",
                "inspect",
                "--format",
                "{{json .}}",
                trusted_reference,
            ],
            input_text=None,
            timeout_seconds=30.0,
        )
    except OSError as exc:
        raise AthenaEvidenceError("image resolution lost its endpoint authority") from exc
    if result.returncode != 0:
        raise AthenaEvidenceError("the configured agent image is unavailable locally")
    inspection = _load_object(result.stdout or "", "local agent image inspection")
    image_id = inspection.get("Id", inspection.get("ID"))
    repo_digests = inspection.get("RepoDigests")
    if (
        not isinstance(image_id, str)
        or OCI_IMAGE_ID.fullmatch(image_id) is None
        or not isinstance(repo_digests, list)
        or not repo_digests
        or len(repo_digests) > 1024
        or not all(isinstance(item, str) for item in repo_digests)
        or trusted_reference not in repo_digests
    ):
        raise AthenaEvidenceError(
            "the local agent image identity does not match its configured digest"
        )
    configured_digest = trusted_reference.rsplit("@", maxsplit=1)[1]
    reported_digest = inspection.get("Digest")
    if reported_digest is not None and reported_digest != configured_digest:
        raise AthenaEvidenceError(
            "the local agent image digest does not match its configured digest"
        )
    return image_id


def run_command(
    plugin_root: str,
    harness_file: str,
    relative: str,
    argv: list[str],
    *,
    input_text: str | None = None,
    cwd: str | None = None,
) -> str:
    """Run one audited read-only helper with fixed arguments and bounded output."""
    now = time.monotonic()
    workflow_deadline = _ACTIVE_EVIDENCE_DEADLINE.get()
    if workflow_deadline is None:
        workflow_deadline = now + COMMAND_TIMEOUT_SECONDS
    process_deadline = workflow_deadline - CHAIN_CLEANUP_RESERVE_SECONDS
    process_timeout = process_deadline - now
    if process_timeout <= 0:
        raise AthenaEvidenceError("the Athena evidence workflow deadline expired")

    def remaining_process_timeout() -> float:
        remaining = process_deadline - time.monotonic()
        if remaining <= 0:
            raise AthenaEvidenceError(
                "the Athena evidence workflow deadline expired"
            )
        return remaining
    if not isinstance(argv, list) or not argv or not all(
        isinstance(item, str) and item for item in argv
    ):
        raise AthenaEvidenceError("Athena helper arguments are malformed")
    root = _verified_plugin_root(plugin_root)
    if input_text is not None and len(input_text.encode("utf-8")) > MAX_INPUT_BYTES:
        raise AthenaEvidenceError("Athena helper input exceeds 1 MiB")
    if input_text is not None and relative in {
        RULES_COMMAND,
        BRANCH_PROTECTION_COMMAND,
        CHECK_RUNS_COMMAND,
        MERGE_READINESS_COMMAND,
    }:
        raise AthenaEvidenceError("read-only forge operations do not accept input")
    e2e_root = os.path.dirname(os.path.abspath(harness_file))
    adapter = os.path.join(e2e_root, "athena_readonly_chain.py")
    if os.path.realpath(adapter) != adapter:
        raise AthenaEvidenceError("the read-only chain adapter is symlinked")
    if relative in {RULES_COMMAND, BRANCH_PROTECTION_COMMAND}:
        if (
            len(argv) != 2
            or REPOSITORY.fullmatch(argv[0]) is None
            or re.fullmatch(r"[A-Za-z0-9._/-]{1,255}", argv[1]) is None
            or argv[1].startswith("/")
            or ".." in argv[1].split("/")
        ):
            raise AthenaEvidenceError("effective branch-rule arguments are malformed")
        endpoint = (
            f"repos/{argv[0]}/rules/branches/{argv[1]}"
            if relative == RULES_COMMAND
            else f"repos/{argv[0]}/branches/{argv[1]}/protection"
        )
        command = [
            "gh", "api", "--hostname", "github.com", "--method", "GET",
            "-H", "Accept: application/vnd.github+json",
            endpoint,
        ]
        if relative == RULES_COMMAND:
            command.extend(["-f", "per_page=100", "--paginate", "--slurp"])
    elif relative == CHECK_RUNS_COMMAND:
        if (
            len(argv) != 2
            or REPOSITORY.fullmatch(argv[0]) is None
            or HEX_40.fullmatch(argv[1]) is None
        ):
            raise AthenaEvidenceError("head check-run arguments are malformed")
        command = [
            "gh", "api", "--hostname", "github.com", "--method", "GET",
            "-H", "Accept: application/vnd.github+json",
            f"repos/{argv[0]}/commits/{argv[1]}/check-runs?per_page=100",
            "--paginate", "--slurp",
        ]
    elif relative == MERGE_READINESS_COMMAND:
        if (
            len(argv) != 3
            or REPOSITORY.fullmatch(argv[0]) is None
            or re.fullmatch(r"[1-9][0-9]*", argv[1]) is None
            or HEX_40.fullmatch(argv[2]) is None
        ):
            raise AthenaEvidenceError("pull-request readiness arguments are malformed")
        command = [
            "gh", "pr", "view", argv[1], "--repo", f"github.com/{argv[0]}",
            "--json", "url,state,headRefOid,reviewDecision",
        ]
    else:
        if relative not in PLUGIN_COMMANDS and relative != CHAIN_COMMAND:
            raise AthenaEvidenceError("the Athena helper is not allowlisted")
        command = []
    direct_reads = {
        RULES_COMMAND,
        BRANCH_PROTECTION_COMMAND,
        CHECK_RUNS_COMMAND,
        MERGE_READINESS_COMMAND,
    }
    external_plugin_helper = (
        relative == "skills/pr-review/scripts/collect_evidence.py"
    )
    gh_executable = (
        _trusted_gh_executable()
        if relative in direct_reads or relative == CHAIN_COMMAND
        or external_plugin_helper
        else None
    )
    git_executable = (
        _trusted_git_executable() if external_plugin_helper else None
    )
    git_exec_path = (
        _trusted_git_exec_path() if external_plugin_helper else None
    )
    python_executable = (
        _trusted_python_executable()
        if sys.platform.startswith("linux")
        and (relative in PLUGIN_COMMANDS or relative == CHAIN_COMMAND)
        else None
    )
    try:
        with tempfile.TemporaryDirectory(
            prefix="odysseus-athena-gh-config-"
        ) as gh_config_directory:
            os.chmod(gh_config_directory, 0o700)
            environment = (
                _sanitized_environment(
                    gh_executable,
                    os.path.realpath(gh_config_directory),
                    git_executable,
                    python_executable,
                    git_exec_path,
                )
                if gh_executable is not None or git_executable is not None
                else _local_helper_environment()
            )
            if relative == CHAIN_COMMAND or external_plugin_helper:
                if workflow_deadline <= now + CHAIN_CLEANUP_RESERVE_SECONDS:
                    raise AthenaEvidenceError(
                        "the Athena chain cleanup reserve is invalid"
                    )
                environment[
                    "ODYSSEUS_ATHENA_CHAIN_DEADLINE_MONOTONIC"
                ] = repr(process_deadline)
            if gh_executable is not None:
                environment["ODYSSEUS_REQUIRE_AGGREGATE_QUOTA"] = "1"
            if relative in direct_reads:
                if gh_executable is None:
                    raise AthenaEvidenceError(
                        "the trusted GitHub CLI binding is unavailable"
                    )
                command[0] = gh_executable.execution_path
                result = _run_bounded_process(
                    command,
                    input_text=input_text,
                    cwd=cwd,
                    environment=environment,
                    timeout_seconds=remaining_process_timeout(),
                    pass_fds=(gh_executable.descriptor,),
                )
            else:
                if relative in PLUGIN_COMMANDS:
                    arguments = [
                        "run-helper", "--plugin-root", root,
                        "--relative", relative, "--", *argv,
                    ]
                else:
                    arguments = ["--plugin-root", root, *argv]
                command = _verified_adapter_command(
                    adapter,
                    CHAIN_ADAPTER_SHA256,
                    arguments,
                    python_executable,
                )
                result = _run_bounded_process(
                    command,
                    input_text=input_text,
                    cwd=cwd,
                    environment=environment,
                    timeout_seconds=remaining_process_timeout(),
                    pass_fds=tuple(
                        executable.descriptor
                        for executable in (
                            gh_executable,
                            git_executable,
                            python_executable,
                        )
                        if executable is not None
                    ),
                    executable=(
                        python_executable.execution_path
                        if python_executable is not None
                        else None
                    ),
                )
    except (FileNotFoundError, OSError, subprocess.TimeoutExpired) as exc:
        raise AthenaEvidenceError("the Athena read did not complete") from exc
    finally:
        if gh_executable is not None:
            gh_executable.close()
        if git_executable is not None:
            git_executable.close()
        if python_executable is not None:
            python_executable.close()
    stdout = result.stdout if isinstance(result.stdout, str) else ""
    stderr = result.stderr if isinstance(result.stderr, str) else ""
    if (
        len(stdout.encode("utf-8")) > MAX_OUTPUT_BYTES
        or len(stderr.encode("utf-8")) > MAX_STDERR_BYTES
    ):
        raise AthenaEvidenceError("the Athena read exceeded its output bound")
    if result.returncode != 0:
        diagnostic = " ".join(stderr.split())[:300]
        raise AthenaEvidenceError(
            f"the Athena read failed: {diagnostic or 'no diagnostic'}"
        )
    if not stdout.strip():
        raise AthenaEvidenceError("the Athena read returned empty output")
    if relative == RULES_COMMAND:
        pages = _load_json(stdout, "live effective branch-rule pages")
        if not isinstance(pages, list) or not pages or len(pages) > MAX_RULE_PAGES:
            raise AthenaEvidenceError(
                "live effective branch-rule pagination is incomplete"
            )
        flattened: list[object] = []
        for page in pages:
            if not isinstance(page, list) or len(page) > MAX_RULES_PER_PAGE:
                raise AthenaEvidenceError(
                    "live effective branch-rule pagination is malformed"
                )
            flattened.extend(page)
        return _canonical_json(flattened)
    if relative == CHECK_RUNS_COMMAND:
        pages = _load_json(stdout, "live head check-run pages")
        if not isinstance(pages, list) or not pages or len(pages) > MAX_RULE_PAGES:
            raise AthenaEvidenceError("live head check-run pagination is incomplete")
        total: int | None = None
        checks: list[object] = []
        for page in pages:
            if not isinstance(page, dict):
                raise AthenaEvidenceError("live head check-run pagination is malformed")
            page_total = page.get("total_count")
            page_checks = page.get("check_runs")
            if (
                type(page_total) is not int
                or page_total < 0
                or page_total > MAX_CHECK_RUNS
                or not isinstance(page_checks, list)
                or len(page_checks) > MAX_RULES_PER_PAGE
            ):
                raise AthenaEvidenceError("live head check-run pagination is malformed")
            if total is None:
                total = page_total
            elif page_total != total:
                raise AthenaEvidenceError("live head check-run totals changed")
            checks.extend(page_checks)
        if total is None or len(checks) != total or not checks:
            raise AthenaEvidenceError("live head check-run pagination is incomplete")
        return _canonical_json(checks)
    if relative == MERGE_READINESS_COMMAND:
        value = _load_object(stdout, "live pull-request readiness")
        if set(value) != {"url", "state", "headRefOid", "reviewDecision"}:
            raise AthenaEvidenceError("live pull-request readiness is malformed")
        expected_url = f"https://github.com/{argv[0]}/pull/{argv[1]}"
        decision = value["reviewDecision"]
        if decision in {None, ""}:
            decision = "UNAVAILABLE"
        if (
            value["url"] != expected_url
            or value["state"] != "OPEN"
            or value["headRefOid"] != argv[2]
            or not isinstance(decision, str)
        ):
            raise AthenaEvidenceError("live pull-request readiness is stale or malformed")
        return _canonical_json({
            "repository": argv[0],
            "number": int(argv[1]),
            "url": expected_url,
            "state": "OPEN",
            "head_oid": argv[2],
            "review_decision": decision,
        })
    return stdout.strip()


def canonical_carrier(
    runner: Callable[..., str], body: str, *, cwd: str | None = None
) -> dict:
    """Extract and independently verify one carrier through Athena's public CLI."""
    extracted = _load_object(
        runner(
            "skills/review-exchange/scripts/review_exchange.py",
            ["extract", "-"],
            input_text=body,
            cwd=cwd,
        ),
        "Athena extracted carrier",
    )
    verified = _load_object(
        runner(
            "skills/review-exchange/scripts/review_exchange.py",
            ["verify", "-"],
            input_text=_canonical_json(extracted),
            cwd=cwd,
        ),
        "Athena verified carrier",
    )
    if verified != extracted:
        raise AthenaEvidenceError("Athena extract and verify results differ")
    return verified


def _collector_argv(
    pr_url: str,
    repository: str,
    number: int,
    base_oid: str,
    head_oid: str,
    requirement_url: str,
) -> list[str]:
    return [
        "--expected-base-oid",
        base_oid,
        "--expected-head-oid",
        head_oid,
        "--expected-host",
        "github.com",
        "--expected-repository",
        repository,
        "--expected-pr-number",
        str(number),
        "--expected-pr-url",
        pr_url,
        "--requirement-issue",
        requirement_url,
        str(number),
    ]


def _validated_collector(
    value: dict,
    *,
    pr_url: str,
    repository: str,
    number: int,
    base_oid: str,
    head_oid: str,
    requirement_url: str,
    envelope: dict,
    expected_base_ref: str,
    expected_head_ref: str,
) -> dict:
    identity = value.get("reviewed_identity")
    expected_identity = {
        "forge_host": "github.com",
        "repository": repository,
        "number": number,
        "url": pr_url,
        "state": "OPEN",
        "base_oid": base_oid,
        "head_oid": head_oid,
    }
    if identity != expected_identity:
        raise AthenaEvidenceError("Athena evidence does not bind the open PR")
    scope = value.get("reviewed_scope")
    requirements = value.get("reviewed_linked_requirements")
    expected_scope_fields = {
        "title", "body", "closingIssuesReferences", "state", "isDraft",
        "baseRefName", "headRefName",
    }
    if (
        not isinstance(scope, dict)
        or set(scope) != {"fields", "sha256"}
        or not isinstance(scope["fields"], dict)
        or set(scope["fields"]) != expected_scope_fields
        or not isinstance(scope["fields"]["title"], str)
        or (
            scope["fields"]["body"] is not None
            and not isinstance(scope["fields"]["body"], str)
        )
        or not isinstance(scope["fields"]["closingIssuesReferences"], list)
        or not all(
            isinstance(item, dict)
            for item in scope["fields"]["closingIssuesReferences"]
        )
        or scope["fields"]["state"] != "OPEN"
        or scope["fields"]["isDraft"] is not False
        or scope["fields"]["baseRefName"] != expected_base_ref
        or scope["fields"]["headRefName"] != expected_head_ref
        or HEX_64.fullmatch(scope.get("sha256", "")) is None
        or not isinstance(requirements, dict)
        or set(requirements) != {"count", "items", "sha256"}
        or type(requirements["count"]) is not int
        or not isinstance(requirements["items"], list)
        or requirements["count"] != len(requirements["items"])
        or HEX_64.fullmatch(requirements.get("sha256", "")) is None
    ):
        raise AthenaEvidenceError("Athena evidence is incomplete or malformed")
    requirement_urls: list[str] = []
    requirement_ids: set[str] = set()
    for item in requirements["items"]:
        if not isinstance(item, dict) or set(item) != {
            "id", "repository", "number", "url", "content_sha256"
        }:
            raise AthenaEvidenceError("Athena requirement evidence is malformed")
        issue_id = item["id"]
        issue_repo = item["repository"]
        issue_number = item["number"]
        expected_url = f"https://github.com/{issue_repo}/issues/{issue_number}"
        if (
            not isinstance(issue_id, str)
            or not issue_id
            or issue_id in requirement_ids
            or REPOSITORY.fullmatch(issue_repo or "") is None
            or type(issue_number) is not int
            or issue_number < 1
            or item["url"] != expected_url
            or HEX_64.fullmatch(item.get("content_sha256", "")) is None
        ):
            raise AthenaEvidenceError("Athena requirement evidence is malformed")
        requirement_ids.add(issue_id)
        requirement_urls.append(expected_url)
    if requirement_url not in requirement_urls or len(set(requirement_urls)) != len(
        requirement_urls
    ):
        raise AthenaEvidenceError("the trusted task requirement is not bound")
    state = envelope.get("state")
    if (
        not isinstance(state, dict)
        or state.get("artifact_binding", {}).get("revision") != head_oid
        or state.get("artifact_binding", {}).get("sha256") != scope["sha256"]
        or state.get("requirements_sha256") != requirements["sha256"]
    ):
        raise AthenaEvidenceError("the terminal state does not bind live evidence")
    return {
        "reviewed_identity": identity,
        "reviewed_scope": scope,
        "reviewed_linked_requirements": requirements,
    }


def _collector_author_login(value: dict, reviewer_login: str) -> str:
    """Bind the author-event role to the immutable pull-request author."""
    pull_request = value.get("pull_request")
    author = pull_request.get("author") if isinstance(pull_request, dict) else None
    login = author.get("login") if isinstance(author, dict) else None
    if (
        not isinstance(login, str)
        or re.fullmatch(r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", login) is None
    ):
        raise AthenaEvidenceError(
            "the pull-request author identity is unavailable or ambiguous"
        )
    return login


def _validated_checks(value: object, head_oid: str) -> dict:
    if not isinstance(value, list) or not value or len(value) > MAX_CHECK_RUNS:
        raise AthenaEvidenceError("live check evidence is incomplete or malformed")
    check_ids: set[int] = set()
    successful = False
    checks: list[dict] = []
    for check in value:
        if not isinstance(check, dict):
            raise AthenaEvidenceError("live check evidence is malformed")
        check_id = check.get("id")
        if (
            type(check_id) is not int
            or check_id < 1
            or check_id in check_ids
            or not isinstance(check.get("name"), str)
            or not check["name"].strip()
            or check.get("head_sha") != head_oid
            or check.get("status") != "completed"
            or check.get("conclusion") not in {"success", "neutral", "skipped"}
        ):
            raise AthenaEvidenceError("live check evidence is not successful")
        check_ids.add(check_id)
        successful = successful or check["conclusion"] == "success"
        checks.append(check)
    if not successful:
        raise AthenaEvidenceError("live check evidence has no successful check")
    return {
        "check_evidence": {
            "status": "head_bound",
            "head_oid": head_oid,
            "count": len(checks),
        },
        "checks": checks,
    }


def _validated_readiness(
    value: object,
    *,
    repository: str,
    number: int,
    pr_url: str,
    head_oid: str,
) -> dict:
    if (
        not isinstance(value, dict)
        or set(value) != {
            "repository", "number", "url", "state", "head_oid",
            "review_decision",
        }
        or value["repository"] != repository
        or value["number"] != number
        or type(value["number"]) is not int
        or value["url"] != pr_url
        or value["state"] != "OPEN"
        or value["head_oid"] != head_oid
        or value["review_decision"] not in {
            "APPROVED", "CHANGES_REQUESTED", "REVIEW_REQUIRED", "UNAVAILABLE"
        }
    ):
        raise AthenaEvidenceError("live pull-request readiness is stale or malformed")
    decision = value["review_decision"]
    approval_gate = {
        "APPROVED": "satisfied",
        "CHANGES_REQUESTED": "blocked",
        "REVIEW_REQUIRED": "blocked",
    }.get(decision, "unknown")
    return {
        "merge_readiness": {
            "auto_merge_approval_gate": approval_gate,
            "authority": "Repository policy is separate from Athena source review.",
            "review_decision": decision,
        },
    }


def _validated_policy(value: object, collector: dict) -> dict:
    """Bind live effective rules to exact successful Checks API contexts."""
    if not isinstance(value, list) or not value:
        raise AthenaEvidenceError("live effective branch rules are unavailable")
    required: set[tuple[str, int]] = set()
    pull_request_rules = 0
    approvals_required = 0
    thread_resolution_required = False
    allowed_merge_methods: set[str] | None = None
    for rule in value:
        if not isinstance(rule, dict) or not isinstance(rule.get("type"), str):
            raise AthenaEvidenceError("live effective branch rules are malformed")
        if rule["type"] == "required_status_checks":
            parameters = rule.get("parameters")
            if not isinstance(parameters, dict):
                raise AthenaEvidenceError("required-check policy is malformed")
            checks = parameters.get("required_status_checks")
            if not isinstance(checks, list) or not checks:
                raise AthenaEvidenceError("required-check policy is empty")
            for check in checks:
                if not isinstance(check, dict):
                    raise AthenaEvidenceError("required-check policy is malformed")
                context = check.get("context")
                integration_id = check.get("integration_id")
                if (
                    not isinstance(context, str)
                    or not context.strip()
                    or type(integration_id) is not int
                    or integration_id < 1
                ):
                    raise AthenaEvidenceError("required-check policy is malformed")
                required.add((context, integration_id))
        elif rule["type"] == "pull_request":
            parameters = rule.get("parameters")
            if not isinstance(parameters, dict):
                raise AthenaEvidenceError("pull-request policy is malformed")
            approval_count = parameters.get("required_approving_review_count")
            thread_resolution = parameters.get("required_review_thread_resolution")
            merge_methods = parameters.get("allowed_merge_methods")
            if (
                type(approval_count) is not int
                or approval_count < 0
                or type(thread_resolution) is not bool
                or not isinstance(merge_methods, list)
                or not merge_methods
                or not all(
                    method in {"merge", "squash", "rebase"}
                    for method in merge_methods
                )
            ):
                raise AthenaEvidenceError("pull-request policy is malformed")
            pull_request_rules += 1
            approvals_required = max(approvals_required, approval_count)
            thread_resolution_required = (
                thread_resolution_required or thread_resolution
            )
            methods = set(merge_methods)
            allowed_merge_methods = (
                methods
                if allowed_merge_methods is None
                else allowed_merge_methods.intersection(methods)
            )
    if (
        not required
        or pull_request_rules < 1
        or not thread_resolution_required
        or not allowed_merge_methods
    ):
        raise AthenaEvidenceError("live branch policy lacks required delivery gates")
    if (
        approvals_required > 0
        and collector["merge_readiness"]["auto_merge_approval_gate"] != "satisfied"
    ):
        raise AthenaEvidenceError("required pull-request approvals are not satisfied")
    observed: dict[tuple[str, int], list[dict]] = {}
    for check in collector["checks"]:
        app = check.get("app")
        app_id = app.get("id") if isinstance(app, dict) else None
        if type(app_id) is int and app_id > 0:
            observed.setdefault((check["name"], app_id), []).append(check)
    for identity in required:
        matches = observed.get(identity, [])
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise AthenaEvidenceError(
                "a live required check is missing, ambiguous, or unsuccessful"
            )
    return {
        "required_status_checks": [
            {"context": context, "integration_id": integration_id}
            for context, integration_id in sorted(required)
        ],
        "required_approvals": approvals_required,
        "required_thread_resolution": thread_resolution_required,
        "allowed_merge_methods": sorted(allowed_merge_methods),
    }


def _validated_branch_protection(value: object, collector: dict) -> dict:
    """Bind classic branch protection without assuming it matches rulesets."""
    if not isinstance(value, dict):
        raise AthenaEvidenceError("live branch protection is unavailable")
    conversation = value.get("required_conversation_resolution")
    force_pushes = value.get("allow_force_pushes")
    deletions = value.get("allow_deletions")
    reviews = value.get("required_pull_request_reviews")
    if (
        not isinstance(conversation, dict)
        or conversation.get("enabled") is not True
        or not isinstance(force_pushes, dict)
        or force_pushes.get("enabled") is not False
        or not isinstance(deletions, dict)
        or deletions.get("enabled") is not False
        or not isinstance(reviews, dict)
        or type(reviews.get("required_approving_review_count")) is not int
        or reviews["required_approving_review_count"] < 0
    ):
        raise AthenaEvidenceError("live branch protection is incomplete")
    approval_count = reviews["required_approving_review_count"]
    if (
        approval_count > 0
        and collector["merge_readiness"]["auto_merge_approval_gate"] != "satisfied"
    ):
        raise AthenaEvidenceError("branch-protection approvals are not satisfied")

    required = value.get("required_status_checks")
    app_bound: set[tuple[str, int]] = set()
    legacy_contexts: set[str] = set()
    if required is not None:
        if not isinstance(required, dict) or type(required.get("strict")) is not bool:
            raise AthenaEvidenceError("branch-protection checks are malformed")
        checks = required.get("checks", [])
        contexts = required.get("contexts", [])
        if not isinstance(checks, list) or not isinstance(contexts, list):
            raise AthenaEvidenceError("branch-protection checks are malformed")
        for check in checks:
            if not isinstance(check, dict):
                raise AthenaEvidenceError("branch-protection checks are malformed")
            context = check.get("context")
            app_id = check.get("app_id")
            if (
                not isinstance(context, str)
                or not context.strip()
                or type(app_id) is not int
                or app_id < 1
            ):
                raise AthenaEvidenceError("branch-protection checks are malformed")
            app_bound.add((context, app_id))
        for context in contexts:
            if not isinstance(context, str) or not context.strip():
                raise AthenaEvidenceError("branch-protection checks are malformed")
            legacy_contexts.add(context)

    checks_by_identity: dict[tuple[str, int], list[dict]] = {}
    checks_by_name: dict[str, list[dict]] = {}
    for check in collector["checks"]:
        app = check.get("app")
        app_id = app.get("id") if isinstance(app, dict) else None
        checks_by_name.setdefault(check["name"], []).append(check)
        if type(app_id) is int and app_id > 0:
            checks_by_identity.setdefault((check["name"], app_id), []).append(check)
    for identity in app_bound:
        matches = checks_by_identity.get(identity, [])
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise AthenaEvidenceError(
                "a branch-protection check is missing, ambiguous, or unsuccessful"
            )
    for context in legacy_contexts:
        matches = checks_by_name.get(context, [])
        if len(matches) != 1 or matches[0].get("conclusion") != "success":
            raise AthenaEvidenceError(
                "a branch-protection context is missing, ambiguous, or unsuccessful"
            )
    return {
        "required_approvals": approval_count,
        "required_conversation_resolution": True,
        "allow_force_pushes": False,
        "allow_deletions": False,
        "required_status_checks": [
            {"context": context, "integration_id": integration_id}
            for context, integration_id in sorted(app_bound)
        ],
        "required_legacy_contexts": sorted(legacy_contexts),
    }


def _validated_chain(
    value: dict,
    *,
    pr_url: str,
    repository: str,
    number: int,
    base_oid: str,
    head_oid: str,
    envelope: dict,
    collector: dict,
    reviewer_login: str,
) -> None:
    expected_keys = {
        "schema_id", "schema_version", "binding", "terminal",
        "selected_state_sha256s", "verified_state_sha256s",
        "implementation_labels", "unresolved_thread_count",
    }
    if set(value) != expected_keys:
        raise AthenaEvidenceError("Athena chain proof is malformed")
    binding = {
        "repository": repository,
        "number": number,
        "url": pr_url,
        "base_oid": base_oid,
        "head_oid": head_oid,
    }
    terminal = value.get("terminal")
    state_digest = envelope.get("state_sha256")
    if (
        value.get("schema_id") != "odysseus.athena-readonly-chain-proof"
        or value.get("schema_version") != 1
        or value.get("binding") != binding
        or not isinstance(terminal, dict)
        or set(terminal) != {
            "review_id", "reviewer_login", "state_sha256", "reviewed_scope_sha256",
            "requirements_sha256",
        }
        or not isinstance(terminal["review_id"], str)
        or not terminal["review_id"]
        or not isinstance(terminal["reviewer_login"], str)
        or terminal["reviewer_login"] != reviewer_login
        or terminal["state_sha256"] != state_digest
        or terminal["reviewed_scope_sha256"]
        != collector["reviewed_scope"]["sha256"]
        or terminal["requirements_sha256"]
        != collector["reviewed_linked_requirements"]["sha256"]
        or not isinstance(value.get("selected_state_sha256s"), list)
        or not isinstance(value.get("verified_state_sha256s"), list)
        or state_digest not in value["selected_state_sha256s"]
        or state_digest not in value["verified_state_sha256s"]
        or len(value["selected_state_sha256s"])
        != len(set(value["selected_state_sha256s"]))
        or len(value["verified_state_sha256s"])
        != len(set(value["verified_state_sha256s"]))
        or value.get("implementation_labels") != ["state:implementation-go"]
        or value.get("unresolved_thread_count") != 0
    ):
        raise AthenaEvidenceError("Athena chain proof does not authorize delivery")


def require_live_evidence(
    runner: Callable[..., str],
    *,
    pr_url: str,
    repository: str,
    base_oid: str,
    head_oid: str,
    envelope: dict,
    requirement_url: str,
    reviewer_login: str,
    expected_base_ref: str,
    expected_head_ref: str,
    cwd: str | None = None,
) -> dict:
    """Run the complete evidence workflow under one monotonic deadline."""
    deadline = time.monotonic() + COMMAND_TIMEOUT_SECONDS
    token = _ACTIVE_EVIDENCE_DEADLINE.set(deadline)

    def bounded_runner(*args, **kwargs) -> str:
        if time.monotonic() >= deadline - CHAIN_CLEANUP_RESERVE_SECONDS:
            raise AthenaEvidenceError(
                "the Athena evidence workflow deadline expired"
            )
        result = runner(*args, **kwargs)
        if time.monotonic() >= deadline - CHAIN_CLEANUP_RESERVE_SECONDS:
            raise AthenaEvidenceError(
                "the Athena evidence workflow deadline expired"
            )
        return result

    try:
        return _require_live_evidence_workflow(
            bounded_runner,
            pr_url=pr_url,
            repository=repository,
            base_oid=base_oid,
            head_oid=head_oid,
            envelope=envelope,
            requirement_url=requirement_url,
            reviewer_login=reviewer_login,
            expected_base_ref=expected_base_ref,
            expected_head_ref=expected_head_ref,
            cwd=cwd,
        )
    finally:
        _ACTIVE_EVIDENCE_DEADLINE.reset(token)


def _require_live_evidence_workflow(
    runner: Callable[..., str],
    *,
    pr_url: str,
    repository: str,
    base_oid: str,
    head_oid: str,
    envelope: dict,
    requirement_url: str,
    reviewer_login: str,
    expected_base_ref: str,
    expected_head_ref: str,
    cwd: str | None = None,
) -> dict:
    """Double-bind head checks and the exact live Athena logical chain."""
    if REPOSITORY.fullmatch(repository) is None:
        raise AthenaEvidenceError("the repository identity is malformed")
    if HEX_40.fullmatch(base_oid) is None or HEX_40.fullmatch(head_oid) is None:
        raise AthenaEvidenceError("the pull-request object identifiers are malformed")
    for name, reference in (
        ("base", expected_base_ref),
        ("head", expected_head_ref),
    ):
        if (
            not isinstance(reference, str)
            or re.fullmatch(r"[A-Za-z0-9._/-]{1,255}", reference) is None
            or reference.startswith("/")
            or ".." in reference.split("/")
        ):
            raise AthenaEvidenceError(f"the expected {name} reference is malformed")
    match = re.fullmatch(
        rf"https://github\.com/{re.escape(repository)}/pull/([1-9][0-9]*)",
        pr_url,
    )
    if match is None:
        raise AthenaEvidenceError("the pull-request URL is malformed")
    if not isinstance(reviewer_login, str) or re.fullmatch(
        r"[A-Za-z0-9](?:[A-Za-z0-9-]{0,38})", reviewer_login
    ) is None:
        raise AthenaEvidenceError("ATHENA_REVIEWER_LOGIN is not configured safely")
    number = int(match.group(1))
    collector_argv = _collector_argv(
        pr_url, repository, number, base_oid, head_oid, requirement_url
    )
    first_collector_value = _load_object(
        runner(
            "skills/pr-review/scripts/collect_evidence.py",
            collector_argv,
            cwd=cwd,
        ),
        "Athena evidence",
    )
    author_login = _collector_author_login(
        first_collector_value, reviewer_login
    )
    first_source = _validated_collector(
        first_collector_value,
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        requirement_url=requirement_url,
        envelope=envelope,
        expected_base_ref=expected_base_ref,
        expected_head_ref=expected_head_ref,
    )
    first_checks = _validated_checks(
        _load_json(
            runner(CHECK_RUNS_COMMAND, [repository, head_oid], cwd=cwd),
            "live head check runs",
        ),
        head_oid,
    )
    first_readiness = _validated_readiness(
        _load_object(
            runner(
                MERGE_READINESS_COMMAND,
                [repository, str(number), head_oid],
                cwd=cwd,
            ),
            "live pull-request readiness",
        ),
        repository=repository,
        number=number,
        pr_url=pr_url,
        head_oid=head_oid,
    )
    first = {**first_source, **first_checks, **first_readiness}
    base_branch = expected_base_ref
    first_rules_raw = _load_json(
        runner(RULES_COMMAND, [repository, base_branch], cwd=cwd),
        "live effective branch rules",
    )
    first_policy = _validated_policy(first_rules_raw, first)
    first_protection_raw = _load_json(
        runner(BRANCH_PROTECTION_COMMAND, [repository, base_branch], cwd=cwd),
        "live branch protection",
    )
    first_protection = _validated_branch_protection(first_protection_raw, first)
    chain_argv = [
        "--repository", repository,
        "--number", str(number),
        "--url", pr_url,
        "--base-oid", base_oid,
        "--head-oid", head_oid,
        "--terminal-state-sha256", envelope["state_sha256"],
        "--reviewer-login", reviewer_login,
        "--author-login", author_login,
    ]
    first_chain = _load_object(
        runner(CHAIN_COMMAND, chain_argv, cwd=cwd),
        "Athena chain proof",
    )
    _validated_chain(
        first_chain,
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        envelope=envelope,
        collector=first,
        reviewer_login=reviewer_login,
    )
    second_collector_value = _load_object(
        runner(
            "skills/pr-review/scripts/collect_evidence.py",
            collector_argv,
            cwd=cwd,
        ),
        "Athena evidence recheck",
    )
    if _collector_author_login(second_collector_value, reviewer_login) != author_login:
        raise AthenaEvidenceError(
            "the pull-request author changed during verification"
        )
    second_source = _validated_collector(
        second_collector_value,
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        requirement_url=requirement_url,
        envelope=envelope,
        expected_base_ref=expected_base_ref,
        expected_head_ref=expected_head_ref,
    )
    second_checks = _validated_checks(
        _load_json(
            runner(CHECK_RUNS_COMMAND, [repository, head_oid], cwd=cwd),
            "live head check-run recheck",
        ),
        head_oid,
    )
    second_readiness = _validated_readiness(
        _load_object(
            runner(
                MERGE_READINESS_COMMAND,
                [repository, str(number), head_oid],
                cwd=cwd,
            ),
            "live pull-request readiness recheck",
        ),
        repository=repository,
        number=number,
        pr_url=pr_url,
        head_oid=head_oid,
    )
    second = {**second_source, **second_checks, **second_readiness}
    if second != first:
        raise AthenaEvidenceError("Athena evidence changed during verification")
    second_rules_raw = _load_json(
        runner(RULES_COMMAND, [repository, base_branch], cwd=cwd),
        "live effective branch-rule recheck",
    )
    second_protection_raw = _load_json(
        runner(BRANCH_PROTECTION_COMMAND, [repository, base_branch], cwd=cwd),
        "live branch-protection recheck",
    )
    if _canonical_json(second_rules_raw) != _canonical_json(first_rules_raw):
        raise AthenaEvidenceError("live effective branch rules changed")
    if _canonical_json(second_protection_raw) != _canonical_json(
        first_protection_raw
    ):
        raise AthenaEvidenceError("live branch protection changed")
    second_policy = _validated_policy(second_rules_raw, second)
    second_protection = _validated_branch_protection(
        second_protection_raw, second
    )
    if second_policy != first_policy:
        raise AthenaEvidenceError("live effective branch policy changed")
    if second_protection != first_protection:
        raise AthenaEvidenceError("live branch protection changed")
    second_chain = _load_object(
        runner(CHAIN_COMMAND, chain_argv, cwd=cwd),
        "Athena chain-proof recheck",
    )
    _validated_chain(
        second_chain,
        pr_url=pr_url,
        repository=repository,
        number=number,
        base_oid=base_oid,
        head_oid=head_oid,
        envelope=envelope,
        collector=second,
        reviewer_login=reviewer_login,
    )
    if _canonical_json(second_chain) != _canonical_json(first_chain):
        raise AthenaEvidenceError("Athena chain proof changed during verification")
    return {
        **first,
        "effective_policy": {
            **first_policy,
            "branch_protection": first_protection,
        },
    }
