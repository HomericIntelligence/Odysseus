#!/usr/bin/env bash
#
# check-submodule-drift.sh — Detect when Odysseus submodule pins differ from
# their upstream default branch.
#
# Each submodule in Odysseus is pinned to a specific SHA representing the last
# known-good cross-repo integration point. Over time these pins go stale. This
# script compares each pinned SHA against the upstream default-branch HEAD and
# reports whether each different pin is behind, ahead, diverged, or of unknown
# ancestry.
#
# Usage:
#   check-submodule-drift.sh           Print a human-readable table.
#   check-submodule-drift.sh --ci      Also write drift-report.json and emit
#                                      has_drift=<bool> to stdout.
#
# Exit codes:
#   0  No drift — all submodule pins match their upstream default branch.
#   1  Drift detected — one or more submodule pins differ from upstream.
#   2  Usage or environment error (network failure, bad arguments, etc.).
# In --ci mode, a complete published report exits 0 even when drift exists.
# Consumers capture the stdout has_drift value and use drift-report.json.
#
# Used by both the GitHub Actions workflow and `just check-submodule-drift`.

# Imported Bash functions must not replace the builtins used below.
if ! unset -f -- builtin cd command declare eval exec exit local printf pwd read \
  return set shift source test trap type unset '[' 2>/dev/null; then :; fi
set -uo pipefail

# Scrub file-producing diagnostics and dynamic-loader controls before the
# first trusted executable is started; `env -i` cannot protect its own loader.
unset BASH_ENV ENV GIT_TRACE GIT_TRACE2 GIT_TRACE2_EVENT \
  GIT_TRACE2_PERF GIT_TRACE_CURL GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS \
  GIT_TRACE_SETUP GIT_TRACE_SHALLOW LD_PRELOAD LD_LIBRARY_PATH \
  LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
  DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_PRINT_TO_FILE

TRUSTED_PYTHON=/usr/bin/python3
TRUSTED_GIT=/usr/bin/git
TRUSTED_ENV=/usr/bin/env
TRUSTED_DATE=/bin/date
GIT_CALL_TIMEOUT_SECONDS=20
GIT_MAX_OUTPUT_BYTES=262144
PROCESS_CALL_TIMEOUT_SECONDS=20
PYTHON_MAX_OUTPUT_BYTES=2097152
DATE_MAX_OUTPUT_BYTES=4096
TOTAL_OPERATION_TIMEOUT_SECONDS=120
GIT_RUNNER_TEST_ENV_KEYS=()
PYTHON_RUNNER_TEST_ENV_KEYS=()
DATE_RUNNER_TEST_ENV_KEYS=()
if [ ! -x "$TRUSTED_PYTHON" ] || [ ! -x "$TRUSTED_GIT" ] \
  || [ ! -x "$TRUSTED_ENV" ] || [ ! -x "$TRUSTED_DATE" ]; then
  printf 'error: trusted Git or Python runtime is unavailable\n' >&2
  exit 2
fi

OPERATION_DEADLINE_NS=""

append_test_environment() {
  local destination_name="$1" keys_name="$2" key
  local keys=()
  case "$keys_name" in
    GIT_RUNNER_TEST_ENV_KEYS) keys=("${GIT_RUNNER_TEST_ENV_KEYS[@]+"${GIT_RUNNER_TEST_ENV_KEYS[@]}"}") ;;
    PYTHON_RUNNER_TEST_ENV_KEYS) keys=("${PYTHON_RUNNER_TEST_ENV_KEYS[@]+"${PYTHON_RUNNER_TEST_ENV_KEYS[@]}"}") ;;
    DATE_RUNNER_TEST_ENV_KEYS) keys=("${DATE_RUNNER_TEST_ENV_KEYS[@]+"${DATE_RUNNER_TEST_ENV_KEYS[@]}"}") ;;
    *) return 2 ;;
  esac
  case "$destination_name" in test_environment|deadline_environment) ;; *) return 2 ;; esac
  for key in "${keys[@]+"${keys[@]}"}"; do
    if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && [ -n "${!key+x}" ]; then
      case "$destination_name" in
        test_environment) test_environment+=("$key=${!key}") ;;
        deadline_environment) deadline_environment+=("$key=${!key}") ;;
      esac
    fi
  done
}

bounded_process() {
  local profile="$1" input_mode="$2" call_timeout="$3" output_limit="$4"
  local keys_name="$5" key test_keys=""
  local test_environment=()
  shift 5
  append_test_environment test_environment "$keys_name"
  if [ "$keys_name" != PYTHON_RUNNER_TEST_ENV_KEYS ]; then
    append_test_environment test_environment PYTHON_RUNNER_TEST_ENV_KEYS
  fi
  local runner_keys=()
  case "$keys_name" in
    GIT_RUNNER_TEST_ENV_KEYS) runner_keys=("${GIT_RUNNER_TEST_ENV_KEYS[@]+"${GIT_RUNNER_TEST_ENV_KEYS[@]}"}") ;;
    PYTHON_RUNNER_TEST_ENV_KEYS) runner_keys=("${PYTHON_RUNNER_TEST_ENV_KEYS[@]+"${PYTHON_RUNNER_TEST_ENV_KEYS[@]}"}") ;;
    DATE_RUNNER_TEST_ENV_KEYS) runner_keys=("${DATE_RUNNER_TEST_ENV_KEYS[@]+"${DATE_RUNNER_TEST_ENV_KEYS[@]}"}") ;;
    *) return 2 ;;
  esac
  for key in "${runner_keys[@]+"${runner_keys[@]}"}"; do
    if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
      test_keys="${test_keys}${test_keys:+,}${key}"
    fi
  done
  "$TRUSTED_ENV" -i HOME=/dev/null PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
    "${test_environment[@]+"${test_environment[@]}"}" "$TRUSTED_PYTHON" -I -S - \
    "$OPERATION_DEADLINE_NS" "$call_timeout" "$output_limit" \
    "$profile" "$input_mode" "$test_keys" "$@" 4<&0 <<'PY'
import ctypes
import os
import select
import selectors
import signal
import subprocess
import sys
import time


operation_deadline_ns = int(sys.argv[1])
call_timeout = int(sys.argv[2])
output_limit = int(sys.argv[3])
profile = sys.argv[4]
input_mode = sys.argv[5]
test_keys = tuple(filter(None, sys.argv[6].split(",")))
argv = sys.argv[7:]
if (
    operation_deadline_ns < 1
    or call_timeout < 1
    or call_timeout > 86400
    or output_limit < 1024
    or profile not in {"git", "python", "date"}
    or input_mode not in {"forward", "null"}
    or not argv
):
    raise SystemExit(2)

command_label = {
    "git": "Git command",
    "python": "Python command",
    "date": "date command",
}[profile]
process_label = {"git": "Git", "python": "Python", "date": "date"}[profile]
requires_exact_containment = profile == "git" and "ls-remote" in argv[1:]
child_environment = {
    "HOME": "/dev/null",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
    "TZ": "UTC",
}
if profile == "git":
    child_environment.update(
        {
            "GIT_CONFIG_COUNT": "0",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_SYSTEM": "/dev/null",
            "GIT_NO_REPLACE_OBJECTS": "1",
            "GIT_OPTIONAL_LOCKS": "0",
            "GIT_TERMINAL_PROMPT": "0",
            "XDG_CONFIG_HOME": "/dev/null",
        }
    )
for key in test_keys:
    if key in os.environ:
        child_environment[key] = os.environ[key]

input_data = b""
if input_mode == "forward":
    with os.fdopen(4, "rb") as input_stream:
        input_data = input_stream.read(output_limit + 1)
    if len(input_data) > output_limit:
        print(
            f"error: {command_label} input exceeded the "
            f"{output_limit}-byte limit",
            file=sys.stderr,
        )
        raise SystemExit(124)

now_ns = time.monotonic_ns()
call_deadline_ns = now_ns + call_timeout * 1_000_000_000
deadline_ns = min(operation_deadline_ns, call_deadline_ns)
deadline_kind = (
    "operation" if operation_deadline_ns <= call_deadline_ns else "call"
)
if deadline_ns <= now_ns:
    print("error: submodule drift operation deadline expired", file=sys.stderr)
    raise SystemExit(124)

selector = None
buffers = {"stdout": bytearray(), "stderr": bytearray()}
input_offset = 0
total = 0
failure = None
runner_failure = None
cleanup_failure = None
status = None
leader_observer = {"kind": None, "queue": None, "seen": False}


def linux_process_identity(process_id):
    try:
        with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
            content = stream.read(65537)
    except (FileNotFoundError, ProcessLookupError):
        return None
    if len(content) > 65536:
        raise RuntimeError("Linux process identity exceeded its byte ceiling")
    closing = content.rfind(b")")
    if closing < 1:
        raise RuntimeError("Linux process identity is malformed")
    fields = content[closing + 2 :].split()
    if len(fields) <= 19:
        raise RuntimeError("Linux process identity is incomplete")
    try:
        return process_id, int(fields[19])
    except ValueError as error:
        raise RuntimeError("Linux process identity is malformed") from error


def linux_child_pids(process_id):
    task_root = f"/proc/{process_id}/task"
    try:
        task_ids = tuple(
            entry
            for entry in os.listdir(task_root)
            if entry.isdecimal()
        )
    except (FileNotFoundError, ProcessLookupError):
        return set()
    children = set()
    for task_id in task_ids:
        try:
            with open(
                f"{task_root}/{task_id}/children", "rb", buffering=0
            ) as stream:
                content = stream.read(1048577)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if len(content) > 1048576:
            raise RuntimeError("Linux child inventory exceeded its byte ceiling")
        for value in content.split():
            if not value.isdigit():
                raise RuntimeError("Linux child inventory is malformed")
            child = int(value)
            if child > 1:
                children.add(child)
    return children


class LinuxProcessScope:
    """Bind descendants by kernel identity, including reparented sessions."""

    def __init__(self):
        if not callable(getattr(os, "pidfd_open", None)) or not callable(
            getattr(signal, "pidfd_send_signal", None)
        ):
            raise RuntimeError("Linux pidfd containment is unavailable")
        library = ctypes.CDLL(None, use_errno=True)
        prctl = getattr(library, "prctl", None)
        if prctl is None:
            raise RuntimeError("Linux subreaper containment is unavailable")
        prctl.argtypes = [
            ctypes.c_int,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
            ctypes.c_ulong,
        ]
        prctl.restype = ctypes.c_int
        ctypes.set_errno(0)
        if prctl(36, 1, 0, 0, 0) != 0:
            error_number = ctypes.get_errno() or 1
            raise OSError(
                error_number, "could not enable Linux subreaper containment"
            )
        state = ctypes.c_int(0)
        ctypes.set_errno(0)
        if prctl(37, ctypes.addressof(state), 0, 0, 0) != 0:
            error_number = ctypes.get_errno() or 1
            raise OSError(
                error_number, "could not verify Linux subreaper containment"
            )
        if state.value != 1:
            raise RuntimeError("Linux subreaper containment is not active")
        self.supervisor = os.getpid()
        self.baseline = {
            identity
            for child in linux_child_pids(self.supervisor)
            if (identity := linux_process_identity(child)) is not None
        }
        self.owned = {}

    def _track(self, process_id, *, root=False):
        identity = linux_process_identity(process_id)
        if identity is None or (not root and identity in self.baseline):
            return False
        previous = self.owned.get(process_id)
        if previous is not None and previous[0] == identity[1]:
            return False
        if previous is not None:
            os.close(previous[1])
        try:
            descriptor = os.pidfd_open(process_id, 0)
        except ProcessLookupError:
            return False
        rebound = linux_process_identity(process_id)
        if rebound != identity:
            os.close(descriptor)
            if rebound is None:
                return False
            raise RuntimeError("Linux process identity changed while binding")
        self.owned[process_id] = (identity[1], descriptor)
        return True

    def track_root(self, process_id):
        if not self._track(process_id, root=True):
            raise RuntimeError("could not bind the command leader")

    def discover(self):
        discovered = False
        while True:
            candidates = set(linux_child_pids(self.supervisor))
            for process_id, (start_time, _descriptor) in tuple(
                self.owned.items()
            ):
                if linux_process_identity(process_id) == (
                    process_id,
                    start_time,
                ):
                    candidates.update(linux_child_pids(process_id))
            changed = False
            for process_id in candidates:
                changed = self._track(process_id) or changed
            discovered = discovered or changed
            if not changed:
                return discovered

    @staticmethod
    def _exited(descriptor):
        ready, _writable, _exceptional = select.select(
            [descriptor], [], [], 0
        )
        return bool(ready)

    def live_snapshot(self):
        return tuple(
            (process_id, descriptor)
            for process_id, (_start_time, descriptor) in self.owned.items()
            if not self._exited(descriptor)
        )

    def live(self):
        self.discover()
        live = self.live_snapshot()
        if live:
            return live
        # Close the fork-after-inventory race only after every bound parent is
        # exited and consecutive adopted-child rescans find no new identity.
        unchanged_scans = 0
        while unchanged_scans < 2:
            changed = self.discover()
            live = self.live_snapshot()
            if live:
                return live
            unchanged_scans = 0 if changed else unchanged_scans + 1
        return ()

    def live_descendants(self, leader):
        return tuple(item for item in self.live() if item[0] != leader)

    @staticmethod
    def _send(descriptor, signal_number):
        try:
            signal.pidfd_send_signal(descriptor, signal_number, None, 0)
        except ProcessLookupError:
            pass

    def terminate_all(self, grace):
        cleanup_error = None
        for signal_number, interval in (
            (signal.SIGTERM, max(0.0, grace)),
            (signal.SIGKILL, max(0.1, grace)),
        ):
            deadline = time.monotonic() + interval
            while True:
                try:
                    live = self.live()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
                    live = tuple(
                        (process_id, descriptor)
                        for process_id, (_start, descriptor) in self.owned.items()
                        if not self._exited(descriptor)
                    )
                if not live:
                    break
                for _process_id, descriptor in live:
                    try:
                        self._send(descriptor, signal_number)
                    except BaseException as error:
                        cleanup_error = cleanup_error or error
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.01)
        if self.live():
            raise RuntimeError(
                "owned descendant processes survived containment cleanup"
            ) from cleanup_error
        if cleanup_error is not None:
            raise RuntimeError(
                "descendant containment cleanup failed"
            ) from cleanup_error

    def reap_adopted(self, leader):
        for process_id in tuple(self.owned):
            if process_id == leader:
                continue
            try:
                os.waitpid(process_id, os.WNOHANG)
            except ChildProcessError:
                pass

    def close(self):
        for _start_time, descriptor in self.owned.values():
            os.close(descriptor)
        self.owned.clear()


def prepare_leader_observer(process_id):
    required = ("waitid", "P_PID", "WEXITED", "WNOHANG", "WNOWAIT")
    if all(hasattr(os, name) for name in required):
        leader_observer["kind"] = "waitid"
        return
    kqueue_names = (
        "kqueue",
        "kevent",
        "KQ_FILTER_PROC",
        "KQ_EV_ADD",
        "KQ_EV_ENABLE",
        "KQ_NOTE_EXIT",
    )
    if sys.platform != "darwin" or any(
        not hasattr(select, name) for name in kqueue_names
    ):
        raise RuntimeError("safe no-reap process observation is unavailable")
    queue = select.kqueue()
    leader_observer["kind"] = "kqueue"
    leader_observer["queue"] = queue
    event = select.kevent(
        process_id,
        filter=select.KQ_FILTER_PROC,
        flags=select.KQ_EV_ADD | select.KQ_EV_ENABLE,
        fflags=select.KQ_NOTE_EXIT,
    )
    try:
        queue.control([event], 0, 0)
    except ProcessLookupError:
        # Popen still owns the unreaped child, so its PID cannot have been
        # reused. ESRCH while installing NOTE_EXIT therefore means it exited.
        leader_observer["seen"] = True


def leader_has_exited_without_reaping(process_id, timeout=0.0):
    if leader_observer["seen"]:
        return True
    if leader_observer["kind"] == "waitid":
        observation = os.waitid(
            os.P_PID,
            process_id,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
        leader_observer["seen"] = (
            observation is not None
            and getattr(observation, "si_pid", 0) == process_id
        )
    elif leader_observer["kind"] == "kqueue":
        leader_observer["seen"] = bool(
            leader_observer["queue"].control(None, 1, timeout)
        )
    return leader_observer["seen"]


def close_leader_observer():
    queue = leader_observer["queue"]
    leader_observer["queue"] = None
    if queue is not None:
        queue.close()


process_scope = None
if sys.platform.startswith("linux"):
    try:
        process_scope = LinuxProcessScope()
    except BaseException as error:
        print(
            f"error: exact process containment is unavailable: {error}",
            file=sys.stderr,
        )
        raise SystemExit(125) from error
elif requires_exact_containment:
    print(
        "error: exact remote Git process containment is Linux-only",
        file=sys.stderr,
    )
    raise SystemExit(125)

mask_signals = getattr(signal, "pthread_sigmask", None)
set_wakeup_descriptor = getattr(signal, "set_wakeup_fd", None)
guarded_signals = {
    candidate
    for name in ("SIGHUP", "SIGINT", "SIGQUIT", "SIGTERM")
    if isinstance((candidate := getattr(signal, name, None)), int)
}
if mask_signals is None or set_wakeup_descriptor is None or not guarded_signals:
    if process_scope is not None:
        process_scope.close()
    print(
        "error: controlled runner cancellation is unavailable",
        file=sys.stderr,
    )
    raise SystemExit(125)


class RunnerCancellation(Exception):
    """A fatal caller signal converted into owned-tree cleanup."""


cancellation_signal = [None]


def request_cancellation(signal_number, _frame):
    cancellation_signal[0] = signal_number


def raise_if_cancelled():
    if cancellation_signal[0] is None:
        return
    raise RunnerCancellation(
        f"received {signal.Signals(cancellation_signal[0]).name}"
    )


cancellation_read, cancellation_write = os.pipe()
for descriptor in (cancellation_read, cancellation_write):
    os.set_blocking(descriptor, False)
    os.set_inheritable(descriptor, False)
set_wakeup_descriptor(cancellation_write)
for signal_number in guarded_signals:
    signal.signal(signal_number, request_cancellation)

try:
    process = subprocess.Popen(
        argv,
        cwd="/",
        env=child_environment,
        stdin=(subprocess.PIPE if input_mode == "forward" else subprocess.DEVNULL),
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
except OSError as error:
    if process_scope is not None:
        process_scope.close()
    print(
        f"error: could not start trusted {process_label}: {error}",
        file=sys.stderr,
    )
    raise SystemExit(127) from error

try:
    if process_scope is not None:
        process_scope.track_root(process.pid)
    prepare_leader_observer(process.pid)
    raise_if_cancelled()
    if process.stdout is None or process.stderr is None:
        raise RuntimeError(f"trusted {process_label} output pipes are unavailable")
    if input_mode == "forward" and process.stdin is None:
        raise RuntimeError(f"trusted {process_label} input pipe is unavailable")
    selector = selectors.DefaultSelector()
    selector.register(cancellation_read, selectors.EVENT_READ, "cancel")
    if process.stdin is not None:
        if input_data:
            os.set_blocking(process.stdin.fileno(), False)
            selector.register(process.stdin, selectors.EVENT_WRITE, "stdin")
        else:
            process.stdin.close()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    while any(
        key.data != "cancel" for key in selector.get_map().values()
    ):
        raise_if_cancelled()
        remaining = (deadline_ns - time.monotonic_ns()) / 1_000_000_000
        if remaining <= 0:
            failure = (
                "submodule drift operation deadline expired"
                if deadline_kind == "operation"
                else f"{command_label} timed out after {call_timeout}s"
            )
            break
        events = selector.select(remaining)
        if not events:
            failure = (
                "submodule drift operation deadline expired"
                if deadline_kind == "operation"
                else f"{command_label} timed out after {call_timeout}s"
            )
            break
        for key, _ in events:
            stream = key.fileobj
            if key.data == "cancel":
                try:
                    os.read(cancellation_read, 65536)
                except BlockingIOError:
                    pass
                raise_if_cancelled()
                continue
            if key.data == "stdin":
                try:
                    written = os.write(
                        stream.fileno(),
                        input_data[input_offset : input_offset + 65536],
                    )
                except BrokenPipeError:
                    input_offset = len(input_data)
                else:
                    input_offset += written
                if input_offset == len(input_data):
                    selector.unregister(stream)
                    stream.close()
                continue
            chunk = os.read(stream.fileno(), 65536)
            if not chunk:
                selector.unregister(stream)
                stream.close()
                continue
            total += len(chunk)
            if total > output_limit:
                failure = (
                    f"{command_label} exceeded the "
                    f"{output_limit}-byte output limit"
                )
                break
            buffers[key.data].extend(chunk)
        if process_scope is not None:
            process_scope.discover()
        if failure is not None:
            break
    raise_if_cancelled()
    if failure is None:
        # Let a child that closed both output pipes finish exiting without
        # polling or reaping it; its PID remains reserved through both signals.
        grace = min(
            0.02,
            max(0.0, (deadline_ns - time.monotonic_ns()) / 1_000_000_000),
        )
        if grace:
            time.sleep(grace)
        if process_scope is not None:
            detached_descendants = process_scope.live_descendants(process.pid)
            if requires_exact_containment and detached_descendants:
                runner_failure = (
                    f"{command_label} left a detached descendant process running"
                )
except BaseException as error:
    runner_failure = (
        f"{command_label} runner failed: {type(error).__name__}: {error}"
    )
finally:
    mask_signals(signal.SIG_BLOCK, guarded_signals)
    set_wakeup_descriptor(-1)
    if selector is not None:
        try:
            selector.close()
        except BaseException as error:
            cleanup_failure = (
                f"could not close trusted {process_label} selector: {error}"
            )
    if process.stdin is not None and not process.stdin.closed:
        try:
            process.stdin.close()
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not close trusted {process_label} input: {error}"
            )
    term_sent = False
    group_permission_errors = []
    try:
        os.killpg(process.pid, signal.SIGTERM)
        term_sent = True
    except ProcessLookupError:
        pass
    except PermissionError as error:
        if sys.platform == "darwin":
            group_permission_errors.append(("terminate", error))
        else:
            cleanup_failure = (
                f"could not terminate {process_label} process group: {error}"
            )
    except OSError as error:
        cleanup_failure = (
            f"could not terminate {process_label} process group: {error}"
        )
    except BaseException as error:
        cleanup_failure = (
            f"could not terminate {process_label} process group: {error}"
        )
    if term_sent:
        try:
            time.sleep(0.05 if profile == "git" else 0.01)
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not pause before killing {process_label}: {error}"
            )
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        if sys.platform == "darwin":
            group_permission_errors.append(("kill", error))
        else:
            cleanup_failure = cleanup_failure or (
                f"could not kill {process_label} process group: {error}"
            )
    except OSError as error:
        cleanup_failure = cleanup_failure or (
            f"could not kill {process_label} process group: {error}"
        )
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not kill {process_label} process group: {error}"
        )
    if process_scope is not None:
        try:
            process_scope.terminate_all(0.05 if profile == "git" else 0.01)
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not contain trusted {process_label} descendants: {error}"
            )
    if group_permission_errors:
        leader_exited = False
        try:
            leader_exited = leader_has_exited_without_reaping(process.pid, 0.05)
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not observe trusted {process_label} without reaping: "
                f"{error}"
            )
        if not leader_exited:
            action, error = group_permission_errors[0]
            cleanup_failure = cleanup_failure or (
                f"could not {action} {process_label} process group: {error}"
            )
    try:
        close_leader_observer()
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not close trusted {process_label} observer: {error}"
        )
    if cleanup_failure is not None:
        try:
            process.kill()
        except ProcessLookupError:
            pass
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not kill trusted {process_label} leader: {error}"
            )
    try:
        status = process.wait(timeout=1)
    except subprocess.TimeoutExpired as error:
        cleanup_failure = cleanup_failure or (
            f"could not reap trusted {process_label}: {error}"
        )
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not reap trusted {process_label}: {error}"
        )
    if process_scope is not None:
        try:
            process_scope.reap_adopted(process.pid)
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not reap trusted {process_label} descendants: {error}"
            )
        try:
            process_scope.close()
        except BaseException as error:
            cleanup_failure = cleanup_failure or (
                f"could not close trusted {process_label} containment: {error}"
            )
    for stream in (process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except BaseException as error:
                cleanup_failure = cleanup_failure or (
                    f"could not close trusted {process_label} output: {error}"
                )
    for descriptor in (cancellation_read, cancellation_write):
        try:
            os.close(descriptor)
        except OSError as error:
            cleanup_failure = cleanup_failure or (
                f"could not close cancellation descriptor: {error}"
            )

if cleanup_failure is not None:
    print(f"error: {cleanup_failure}", file=sys.stderr)
    raise SystemExit(125)
if runner_failure is not None:
    print(f"error: {runner_failure}", file=sys.stderr)
    raise SystemExit(125)
if failure is not None:
    print(f"error: {failure}", file=sys.stderr)
    raise SystemExit(124)
if status is None:
    print(f"error: trusted {process_label} status is unavailable", file=sys.stderr)
    raise SystemExit(125)
if status < 0:
    print(
        f"error: {command_label} closed output before it terminated",
        file=sys.stderr,
    )
    raise SystemExit(124)
sys.stdout.buffer.write(buffers["stdout"])
sys.stderr.buffer.write(buffers["stderr"])
raise SystemExit(status)
PY
}

isolated_python() {
  bounded_process python null "$PROCESS_CALL_TIMEOUT_SECONDS" \
    "$PYTHON_MAX_OUTPUT_BYTES" PYTHON_RUNNER_TEST_ENV_KEYS \
    "$TRUSTED_PYTHON" -I -S "$@"
}

isolated_python_input() {
  bounded_process python forward "$PROCESS_CALL_TIMEOUT_SECONDS" \
    "$PYTHON_MAX_OUTPUT_BYTES" PYTHON_RUNNER_TEST_ENV_KEYS \
    "$TRUSTED_PYTHON" -I -S "$@"
}

isolated_date() {
  bounded_process date null "$PROCESS_CALL_TIMEOUT_SECONDS" \
    "$DATE_MAX_OUTPUT_BYTES" DATE_RUNNER_TEST_ENV_KEYS "$TRUSTED_DATE" "$@"
}

usage() {
  printf '%s\n' \
    'Usage: check-submodule-drift.sh [--ci]' \
    '' \
    'Compare each canonical submodule pin with its upstream default branch.' \
    '' \
    'Options:' \
    '  --ci       Publish a validated report and print has_drift to stdout.' \
    '  -h, --help Print this help and exit.' \
    '' \
    'Exit codes:' \
    '  0  No drift, or a complete CI report was published.' \
    '  1  Drift was detected outside CI mode.' \
    '  2  The comparison or publication was unavailable.'
}

CI_MODE=0
if [ "$#" -gt 1 ]; then
  printf 'error: expected at most one argument\n' >&2
  exit 2
fi
case "${1:-}" in
  "")        ;;
  --ci)      CI_MODE=1 ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    printf 'error: unknown argument: %s\n' "$1" >&2
    exit 2
    ;;
esac

# Select the checkout from this script, not from ambient Git routing. Reject a
# logical path that reaches the script through a symlinked checkout root.
case "${BASH_SOURCE[0]}" in
  /*) script_source="${BASH_SOURCE[0]}" ;;
  *) script_source="$PWD/${BASH_SOURCE[0]}" ;;
esac
if [ -L "$script_source" ]; then
  printf 'error: checker entry point is a symlink\n' >&2
  exit 2
fi
script_parent="${script_source%/*}"
logical_script_dir=$(CDPATH='' builtin cd -L -- "$script_parent" 2>/dev/null \
  && builtin pwd -L) || {
  printf 'error: checker directory unavailable\n' >&2
  exit 2
}
SCRIPT_DIR=$(CDPATH='' builtin cd -P -- "$script_parent" 2>/dev/null \
  && builtin pwd -P) || {
  printf 'error: checker directory unavailable\n' >&2
  exit 2
}
if [ "$logical_script_dir" != "$SCRIPT_DIR" ] \
  || [ "${SCRIPT_DIR##*/}" != scripts ]; then
  printf 'error: checker path is not a direct repository entry\n' >&2
  exit 2
fi
REPO_ROOT="${SCRIPT_DIR%/scripts}"
[ -n "$REPO_ROOT" ] || {
  printf 'error: repository root unavailable\n' >&2
  exit 2
}

# Bind one monotonic deadline before the first repository observation. Every
# later trusted child receives this same absolute deadline.
deadline_environment=()
append_test_environment deadline_environment PYTHON_RUNNER_TEST_ENV_KEYS
OPERATION_DEADLINE_NS=$("$TRUSTED_ENV" -i \
  HOME=/dev/null PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
  "${deadline_environment[@]+"${deadline_environment[@]}"}" "$TRUSTED_PYTHON" -I -S -c \
  'import sys,time; print(time.monotonic_ns() + int(sys.argv[1]) * 1_000_000_000)' \
  "$TOTAL_OPERATION_TIMEOUT_SECONDS") || {
  printf 'error: submodule drift operation deadline unavailable\n' >&2
  exit 2
}
if [[ ! "$OPERATION_DEADLINE_NS" =~ ^[0-9]+$ ]]; then
  printf 'error: submodule drift operation deadline is invalid\n' >&2
  exit 2
fi

# Run Python without user site initialization. The guard binds the repository,
# the canonical .gitmodules bytes, and optional local submodule repositories by
# descriptor identity. Its token is verified after each read-only operation.
path_guard() {
  isolated_python_input - "$@" <<'PY'
import base64
import configparser
import hashlib
import json
import os
import re
import stat
import sys


DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC
MAX_BOUND_FILE_BYTES = 1024 * 1024
MAX_SUBMODULES = 256


def identity(value):
    return {
        "dev": value.st_dev,
        "gid": value.st_gid,
        "ino": value.st_ino,
        "mode": value.st_mode,
        "uid": value.st_uid,
    }


def file_state(value, content):
    result = identity(value)
    result.update({
        "ctime_ns": value.st_ctime_ns,
        "digest": hashlib.sha256(content).hexdigest(),
        "mtime_ns": value.st_mtime_ns,
        "nlink": value.st_nlink,
        "size": value.st_size,
    })
    return result


def require_directory(value):
    if not stat.S_ISDIR(value.st_mode) or value.st_uid != os.geteuid():
        raise OSError("untrusted directory")


def require_git_entry(value):
    if value.st_uid != os.geteuid():
        raise OSError("untrusted Git entry owner")
    if stat.S_ISDIR(value.st_mode):
        return
    if not stat.S_ISREG(value.st_mode) or value.st_nlink != 1:
        raise OSError("untrusted Git entry")


def read_all(descriptor, maximum=MAX_BOUND_FILE_BYTES):
    chunks = []
    total = 0
    while True:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            return b"".join(chunks)
        total += len(chunk)
        if total > maximum:
            raise OSError("bound file exceeds its byte limit")
        chunks.append(chunk)


def open_root(path):
    descriptor = os.open(path, DIR_FLAGS)
    value = os.fstat(descriptor)
    require_directory(value)
    return descriptor, identity(value)


def open_named_file(parent, name):
    named = os.lstat(name, dir_fd=parent)
    if (
        not stat.S_ISREG(named.st_mode)
        or named.st_uid != os.geteuid()
        or named.st_nlink != 1
    ):
        raise OSError("untrusted direct file")
    descriptor = os.open(name, READ_FLAGS, dir_fd=parent)
    try:
        opened = os.fstat(descriptor)
        content = read_all(descriptor)
        final = os.fstat(descriptor)
        rebound = os.lstat(name, dir_fd=parent)
        expected = file_state(opened, content)
        if (
            file_state(final, content) != expected
            or file_state(rebound, content) != expected
        ):
            raise OSError("direct file changed")
        return expected, content
    finally:
        os.close(descriptor)


def open_optional_file(parent, name):
    try:
        os.lstat(name, dir_fd=parent)
    except FileNotFoundError:
        return None, None
    return open_named_file(parent, name)


def open_optional_nested_file(parent, parts):
    descriptor = os.dup(parent)
    try:
        for component in parts[:-1]:
            try:
                next_descriptor = os.open(component, DIR_FLAGS, dir_fd=descriptor)
            except FileNotFoundError:
                return None, None
            os.close(descriptor)
            descriptor = next_descriptor
            require_directory(os.fstat(descriptor))
        return open_optional_file(descriptor, parts[-1])
    finally:
        os.close(descriptor)


def open_directory_path(path):
    absolute = os.path.abspath(path)
    if os.path.realpath(absolute) != absolute:
        raise OSError("Git directory path contains a symlink")
    named = os.lstat(absolute)
    require_directory(named)
    descriptor = os.open(absolute, DIR_FLAGS)
    try:
        opened = os.fstat(descriptor)
        rebound = os.lstat(absolute)
        require_directory(opened)
        require_directory(rebound)
        if identity(opened) != identity(named) or identity(rebound) != identity(named):
            raise OSError("Git directory changed")
        return descriptor, absolute, identity(opened)
    except Exception:
        os.close(descriptor)
        raise


def direct_path(content, prefix, base):
    text = content.decode("utf-8")
    lines = text.splitlines()
    if len(lines) != 1 or not lines[0].startswith(prefix):
        raise ValueError("invalid Git directory pointer")
    value = lines[0][len(prefix):]
    if not value or "\x00" in value:
        raise ValueError("invalid Git directory pointer")
    if not os.path.isabs(value):
        value = os.path.join(base, value)
    return os.path.abspath(value)


def reject_external_config(content):
    text = content.decode("utf-8")
    include_section = re.compile(
        r'^\s*\[\s*include(?:if\b[^]]*)?\]\s*(?:[#;].*)?$',
        re.IGNORECASE,
    )
    if any(include_section.fullmatch(line) for line in text.splitlines()):
        raise ValueError("external Git configuration is unavailable")


def config_state(parent, name):
    state, content = open_optional_file(parent, name)
    if content is not None:
        reject_external_config(content)
    return state


def capture_git_repository(checkout, checkout_path):
    named = os.lstat(".git", dir_fd=checkout)
    require_git_entry(named)
    if stat.S_ISDIR(named.st_mode):
        descriptor = os.open(".git", DIR_FLAGS, dir_fd=checkout)
        try:
            opened = os.fstat(descriptor)
            rebound = os.lstat(".git", dir_fd=checkout)
            require_git_entry(opened)
            if (
                identity(opened) != identity(named)
                or identity(rebound) != identity(named)
            ):
                raise OSError("Git directory changed")
            entry = {"kind": "directory", "state": identity(opened)}
        finally:
            os.close(descriptor)
        gitdir_path = os.path.join(checkout_path, ".git")
    else:
        entry_state, content = open_named_file(checkout, ".git")
        entry = {"kind": "file", "state": entry_state}
        gitdir_path = direct_path(content, "gitdir: ", checkout_path)

    gitdir, gitdir_path, gitdir_state = open_directory_path(gitdir_path)
    common = -1
    try:
        commondir_state, commondir_content = open_optional_file(
            gitdir, "commondir"
        )
        if commondir_content is None:
            common_path = gitdir_path
        else:
            common_path = direct_path(commondir_content, "", gitdir_path)
        common, common_path, common_state = open_directory_path(common_path)
        head_state, _ = open_named_file(gitdir, "HEAD")
        graph_files = {}
        for label, parent, parts in (
            ("gitdir_shallow", gitdir, ("shallow",)),
            ("common_shallow", common, ("shallow",)),
            ("grafts", common, ("info", "grafts")),
            ("alternates", common, ("objects", "info", "alternates")),
        ):
            state, graph_content = open_optional_nested_file(parent, parts)
            graph_files[label] = state
            if graph_content not in (None, b""):
                graph_files["safe"] = False
        graph_files.setdefault("safe", True)
        return {
            "common": {"path": common_path, "state": common_state},
            "commondir": commondir_state,
            "config": config_state(common, "config"),
            "config_worktree": config_state(gitdir, "config.worktree"),
            "entry": entry,
            "gitdir": {"path": gitdir_path, "state": gitdir_state},
            "graph": graph_files,
            "head": head_state,
        }
    finally:
        if common >= 0:
            os.close(common)
        os.close(gitdir)


def encode(value):
    raw = json.dumps(value, sort_keys=True, separators=(",", ":")).encode()
    return base64.urlsafe_b64encode(raw).decode("ascii")


def decode(value):
    raw = base64.b64decode(value.encode("ascii"), altchars=b"-_", validate=True)
    result = json.loads(raw.decode("utf-8"))
    if not isinstance(result, dict):
        raise ValueError("invalid binding")
    return result


def parse_inventory(content):
    text = content.decode("utf-8")
    parser = configparser.RawConfigParser(
        interpolation=None,
        strict=True,
        empty_lines_in_values=False,
    )
    parser.optionxform = str
    parser.read_string(text)
    rows = []
    pattern = re.compile(r'^submodule "([^"]+)"$')
    for section in parser.sections():
        match = pattern.fullmatch(section)
        if match is None or set(parser.options(section)) != {"path", "url"}:
            raise ValueError("invalid submodule section")
        rows.append((
            match.group(1),
            parser.get(section, "path").strip(),
            parser.get(section, "url").strip(),
        ))
        if len(rows) > MAX_SUBMODULES:
            raise ValueError("submodule inventory exceeds its count limit")
    if not rows:
        raise ValueError("empty submodule inventory")
    return rows


def capture_root(path, include_inventory):
    root, root_state = open_root(path)
    try:
        modules_state, content = open_named_file(root, ".gitmodules")
        git_state = capture_git_repository(root, path)
        if not git_state["graph"]["safe"]:
            raise OSError("root repository graph metadata is unsafe")
        rebound, rebound_state = open_root(path)
        try:
            if rebound_state != root_state:
                raise OSError("repository root changed")
        finally:
            os.close(rebound)
        binding = {
            "git": git_state,
            "gitmodules": modules_state,
            "root": root_state,
        }
        return binding, parse_inventory(content) if include_inventory else []
    finally:
        os.close(root)


def traverse(root, relative):
    descriptor = os.dup(root)
    states = []
    try:
        for component in relative.split("/"):
            if component in {"", ".", ".."}:
                raise ValueError("invalid submodule path")
            next_descriptor = os.open(component, DIR_FLAGS, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            value = os.fstat(descriptor)
            require_directory(value)
            states.append(identity(value))
        return descriptor, states
    except Exception:
        os.close(descriptor)
        raise


def capture_submodule(root_path, relative, root_binding):
    root, root_state = open_root(root_path)
    try:
        if root_state != root_binding["root"]:
            raise OSError("repository root changed")
        checkout, path_states = traverse(root, relative)
        try:
            git_state = capture_git_repository(
                checkout, os.path.join(root_path, relative)
            )
        finally:
            os.close(checkout)
        return {
            "git": git_state,
            "path": path_states,
            "root": root_state,
        }
    finally:
        os.close(root)


operation = sys.argv[1]
if operation == "bind-root" and len(sys.argv) == 3:
    root_binding, inventory = capture_root(sys.argv[2], True)
    print("BINDING\t" + encode(root_binding))
    for row in inventory:
        print("ROW\t" + "\t".join(row))
elif operation == "verify-root" and len(sys.argv) == 4:
    current, _ = capture_root(sys.argv[2], False)
    if current != decode(sys.argv[3]):
        raise OSError("repository snapshot changed")
elif operation == "bind-submodule" and len(sys.argv) == 5:
    snapshot = capture_submodule(sys.argv[2], sys.argv[3], decode(sys.argv[4]))
    safety = "SAFE" if snapshot["git"]["graph"]["safe"] else "UNSAFE"
    print(safety + "\t" + encode(snapshot))
elif operation == "verify-submodule" and len(sys.argv) == 6:
    current = capture_submodule(sys.argv[2], sys.argv[3], decode(sys.argv[4]))
    if current != decode(sys.argv[5]):
        raise OSError("submodule snapshot changed")
else:
    raise ValueError("invalid path guard invocation")
PY
}

# Load the trusted publisher once. Later path swaps cannot replace the code
# that interprets the descriptor-bound publication tokens.
load_publisher_source() {
  isolated_python_input - "$1" <<'PY'
import hashlib
import os
import stat
import sys


MAX_SOURCE_BYTES = 1024 * 1024
DIR_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
READ_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC


def record(value, content):
    return (
        value.st_ctime_ns,
        value.st_dev,
        hashlib.sha256(content).digest(),
        value.st_gid,
        value.st_ino,
        value.st_mode,
        value.st_mtime_ns,
        value.st_nlink,
        value.st_size,
        value.st_uid,
    )


def identity(value):
    return (
        value.st_dev,
        value.st_gid,
        value.st_ino,
        value.st_mode,
        value.st_nlink,
        value.st_uid,
    )


path = os.path.abspath(sys.argv[1])
parent, name = os.path.dirname(path), os.path.basename(path)
if os.path.realpath(parent) != parent or name in {"", ".", ".."}:
    raise OSError("unsafe publisher path")
parent_descriptor = os.open(parent, DIR_FLAGS)
try:
    named = os.lstat(name, dir_fd=parent_descriptor)
    if (
        not stat.S_ISREG(named.st_mode)
        or named.st_uid != os.geteuid()
        or named.st_nlink != 1
        or stat.S_IMODE(named.st_mode) & 0o022
        or named.st_size > MAX_SOURCE_BYTES
    ):
        raise OSError("unsafe publisher source")
    descriptor = os.open(name, READ_FLAGS, dir_fd=parent_descriptor)
    try:
        opened = os.fstat(descriptor)
        if identity(opened) != identity(named):
            raise OSError("publisher source changed while opening")
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > MAX_SOURCE_BYTES:
                raise OSError("publisher source is too large")
            chunks.append(chunk)
        content = b"".join(chunks)
        final = os.fstat(descriptor)
        rebound = os.lstat(name, dir_fd=parent_descriptor)
        expected = record(opened, content)
        if record(final, content) != expected or record(rebound, content) != expected:
            raise OSError("publisher source changed")
    finally:
        os.close(descriptor)
finally:
    os.close(parent_descriptor)

source = content.decode("utf-8")
compile(source, path, "exec")
sys.stdout.write(source)
PY
}

publisher_call() {
  if [ "${1:-}" = publish ]; then
    isolated_python_input -c "$PUBLISHER_SOURCE" "$@"
  else
    isolated_python -c "$PUBLISHER_SOURCE" "$@"
  fi
}

validate_report_json() {
  isolated_python_input -c '
import datetime
import json
import re
import sys

report = json.load(sys.stdin)
if set(report) != {"generated_at", "drift_count", "error_count", "submodules"}:
    raise SystemExit(2)
if re.fullmatch(r"[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z", report["generated_at"]) is None:
    raise SystemExit(2)
try:
    datetime.datetime.strptime(report["generated_at"], "%Y-%m-%dT%H:%M:%SZ")
except (TypeError, ValueError):
    raise SystemExit(2)
if report["drift_count"] != int(sys.argv[1]) or report["error_count"] != int(sys.argv[2]):
    raise SystemExit(2)
if not isinstance(report["submodules"], list) or len(report["submodules"]) != int(sys.argv[3]):
    raise SystemExit(2)
' "$1" "$2" "$3"
}

git_clean() {
  bounded_process git null "$GIT_CALL_TIMEOUT_SECONDS" \
    "$GIT_MAX_OUTPUT_BYTES" GIT_RUNNER_TEST_ENV_KEYS "$TRUSTED_GIT" "$@"
}

repo_git() {
  git_clean -C "$REPO_ROOT" "$@"
}

remote_git() {
  git_clean "$@"
}

local_git() {
  local checkout="$1"
  shift
  git_clean -C "$checkout" "$@"
}

repo_snapshot=$(path_guard bind-root "$REPO_ROOT") || {
  printf 'error: repository identity or .gitmodules is unavailable\n' >&2
  exit 2
}
ROOT_BINDING=""
inventory=""
while IFS=$'\t' read -r record first second third extra; do
  case "$record" in
    BINDING)
      if [ -n "$ROOT_BINDING" ] || [ -z "$first" ] \
        || [ -n "${second:-}${third:-}${extra:-}" ]; then
        printf 'error: malformed repository binding\n' >&2
        exit 2
      fi
      ROOT_BINDING="$first"
      ;;
    ROW)
      if [ -z "$first" ] || [ -z "$second" ] || [ -z "$third" ] \
        || [ -n "${extra:-}" ]; then
        printf 'error: malformed canonical submodule inventory row\n' >&2
        exit 2
      fi
      inventory="${inventory}${first} ${second} ${third}"$'\n'
      ;;
    *)
      printf 'error: malformed repository snapshot\n' >&2
      exit 2
      ;;
  esac
done <<< "$repo_snapshot"
[ -n "$ROOT_BINDING" ] && [ -n "$inventory" ] || {
  printf 'error: canonical submodule inventory unavailable\n' >&2
  exit 2
}
inventory="${inventory%$'\n'}"

# Bind the publication implementation before any repository or network
# observation can run attacker-controlled helpers that replace its pathname.
PUBLISHER_SOURCE=""
if [ "$CI_MODE" -eq 1 ]; then
  publisher="$REPO_ROOT/scripts/safe_report_publish.py"
  if ! path_guard verify-root "$REPO_ROOT" "$ROOT_BINDING" 2>/dev/null; then
    printf 'error: repository changed before report publisher binding\n' >&2
    exit 2
  fi
  PUBLISHER_SOURCE=$(load_publisher_source "$publisher" 2>/dev/null) || {
    printf 'error: safe report publisher unavailable\n' >&2
    exit 2
  }
  [ -n "$PUBLISHER_SOURCE" ] || {
    printf 'error: safe report publisher unavailable\n' >&2
    exit 2
  }
  if ! path_guard verify-root "$REPO_ROOT" "$ROOT_BINDING" 2>/dev/null; then
    printf 'error: repository changed while binding report publisher\n' >&2
    exit 2
  fi
fi

git_root=$(repo_git rev-parse --show-toplevel) || {
  printf 'error: repository Git identity unavailable\n' >&2
  exit 2
}
if [ "$git_root" != "$REPO_ROOT" ]; then
  printf 'error: repository Git identity does not match the checker\n' >&2
  exit 2
fi
builtin cd "$REPO_ROOT" || exit 2

SUBMODULES=()
SUBMODULE_PATHS=()
SUBMODULE_URLS=()
while IFS=' ' read -r name path url extra; do
  if [ -z "$name" ] || [ -z "$path" ] || [ -z "$url" ] \
    || [ -n "${extra:-}" ]; then
    printf 'error: malformed canonical submodule inventory row\n' >&2
    exit 2
  fi
  if [[ ! "$name" =~ ^[A-Za-z0-9._/-]+$ ]] \
    || [[ ! "$path" =~ ^[A-Za-z0-9._/-]+$ ]]; then
    printf 'error: unsafe submodule identity or path\n' >&2
    exit 2
  fi
  case "/$name/" in */./*|*/../*|*//* )
    printf 'error: unsafe submodule identity: %s\n' "$name" >&2
    exit 2
    ;;
  esac
  case "/$path/" in */./*|*/../*|*//* )
    printf 'error: unsafe submodule path: %s\n' "$path" >&2
    exit 2
    ;;
  esac
  if [[ ! "$url" =~ ^https://github\.com/HomericIntelligence/[A-Za-z0-9][A-Za-z0-9._-]*\.git$ ]]; then
    printf 'error: unsupported submodule URL for %s\n' "$name" >&2
    exit 2
  fi
  for known_name in ${SUBMODULES[@]+"${SUBMODULES[@]}"}; do
    if [ "$known_name" = "$name" ]; then
      printf 'error: duplicate submodule name: %s\n' "$name" >&2
      exit 2
    fi
  done
  for known_path in ${SUBMODULE_PATHS[@]+"${SUBMODULE_PATHS[@]}"}; do
    if [ "$known_path" = "$path" ]; then
      printf 'error: duplicate submodule path: %s\n' "$path" >&2
      exit 2
    fi
  done
  for known_url in ${SUBMODULE_URLS[@]+"${SUBMODULE_URLS[@]}"}; do
    if [ "$known_url" = "$url" ]; then
      printf 'error: duplicate submodule URL: %s\n' "$url" >&2
      exit 2
    fi
  done
  SUBMODULES+=("$name")
  SUBMODULE_PATHS+=("$path")
  SUBMODULE_URLS+=("$url")
done <<< "$inventory"

[ "${#SUBMODULES[@]}" -gt 0 ] || {
  printf 'error: no valid submodule paths found in .gitmodules\n' >&2
  exit 2
}

is_oid() {
  [[ "$1" =~ ^[0-9a-fA-F]{40}$ || "$1" =~ ^[0-9a-fA-F]{64}$ ]] \
    && [[ ! "$1" =~ ^0+$ ]]
}

ROOT_COMMIT=$(repo_git rev-parse --verify 'HEAD^{commit}') || {
  printf 'error: repository commit identity unavailable\n' >&2
  exit 2
}
if ! is_oid "$ROOT_COMMIT"; then
  printf 'error: repository commit identity is invalid\n' >&2
  exit 2
fi

drift_count=0
error_count=0
json_rows=()

printf '## Submodule Drift Report\n\n'
printf '| Submodule | Pinned SHA | Upstream SHA | Relation | Distance | Last Updated |\n'
printf '|-----------|-----------|--------------|----------|----------|--------------|\n'

index=0
while [ "$index" -lt "${#SUBMODULES[@]}" ]; do
  name="${SUBMODULES[$index]}"
  path="${SUBMODULE_PATHS[$index]}"
  url="${SUBMODULE_URLS[$index]}"
  index=$((index + 1))

  # Bind the complete gitlink row. Partial stdout from a failed Git process is
  # unavailable evidence, never a usable object ID.
  tree_line=""
  if ! tree_line=$(repo_git ls-tree "$ROOT_COMMIT" -- "$path" 2>/dev/null); then
    printf '| %s | (unavailable) | - | - | - |\n' "$path"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"gitlink read failed"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi
  tree_mode=""
  tree_type=""
  pinned=""
  tree_path=""
  tree_extra=""
  if [[ "$tree_line" != *$'\n'* ]]; then
    read -r tree_mode tree_type pinned tree_path tree_extra <<< "$tree_line"
  fi
  if [[ "$tree_line" == *$'\n'* ]] \
    || [ "${tree_mode:-}" != 160000 ] || [ "${tree_type:-}" != commit ] \
    || ! is_oid "${pinned:-}" || [ "${tree_path:-}" != "$path" ] \
    || [ -n "${tree_extra:-}" ]; then
    printf '| %s | (unpinned) | - | - | - |\n' "$path"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"invalid gitlink"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi

  # Determine the upstream default branch HEAD via ls-remote.
  symref_output=""
  if ! symref_output=$(remote_git ls-remote --symref "$url" HEAD); then
    printf '| %s | %s | (unreachable) | - | - |\n' "$path" "${pinned:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"remote symref unavailable"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi
  symref_line=""
  head_line=""
  symref_marker=""
  remote_head=""
  symref_target=""
  symref_extra=""
  symref_oid=""
  head_target=""
  head_extra=""
  if [[ "$symref_output" == *$'\n'* ]]; then
    symref_line="${symref_output%%$'\n'*}"
    head_line="${symref_output#*$'\n'}"
    if [[ "$head_line" != *$'\n'* ]]; then
      read -r symref_marker remote_head symref_target symref_extra \
        <<< "$symref_line"
      read -r symref_oid head_target head_extra <<< "$head_line"
    fi
  fi
  if [ "$symref_marker" != 'ref:' ] || [ "$symref_target" != HEAD ] \
    || [ -n "$symref_extra" ] || ! is_oid "$symref_oid" \
    || [ "$head_target" != HEAD ] || [ -n "$head_extra" ] \
    || [[ ! "$remote_head" =~ ^refs/heads/[A-Za-z0-9._/-]+$ ]] \
    || [[ "$remote_head" == *..* ]] || [[ "$remote_head" == *//* ]]; then
    printf '| %s | %s | (invalid default branch) | - | - |\n' \
      "$path" "${pinned:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"invalid remote symref"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi

  upstream_output=""
  if ! upstream_output=$(remote_git ls-remote "$url" "$remote_head"); then
    printf '| %s | %s | (unreachable) | - | - |\n' "$path" "${pinned:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"remote head unavailable"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi
  upstream=""
  upstream_ref=""
  upstream_extra=""
  if [[ "$upstream_output" != *$'\n'* ]]; then
    read -r upstream upstream_ref upstream_extra <<< "$upstream_output"
  fi
  if [[ "$upstream_output" == *$'\n'* ]] \
    || ! is_oid "${upstream:-}" || [ "${upstream_ref:-}" != "$remote_head" ] \
    || [ "$upstream" != "$symref_oid" ] \
    || [ -n "${upstream_extra:-}" ]; then
    printf '| %s | %s | (invalid head) | - | - |\n' "$path" "${pinned:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"error","detail":"invalid remote head"}' "$path")")
    error_count=$((error_count + 1))
    continue
  fi

  if [ "$pinned" = "$upstream" ]; then
    printf '| %s | %s | %s | current | - | - |\n' \
      "$path" "${pinned:0:8}" "${upstream:0:8}"
    json_rows+=("$(printf '{"submodule":"%s","status":"current","relation":"current","pinned":"%s","upstream":"%s"}' "$path" "$pinned" "$upstream")")
    continue
  fi

  # A different object ID establishes drift, but it does not establish which
  # commit is an ancestor. Use only local commit objects for the read-only
  # ancestry check. If either object is unavailable, report the relation as
  # different instead of inventing a behind relationship.
  relation="different"
  distance="?"
  behind_distance="?"
  last_updated="unknown"
  local_root="$REPO_ROOT/$path"
  local_binding=""
  local_graph_safety=""
  local_snapshot=""
  if local_snapshot=$(path_guard bind-submodule "$REPO_ROOT" "$path" \
    "$ROOT_BINDING" 2>/dev/null); then
    local_extra=""
    IFS=$'\t' read -r local_graph_safety local_binding local_extra \
      <<< "$local_snapshot"
    if [ "$local_graph_safety" != SAFE ] || [ -z "$local_binding" ] \
      || [ -n "$local_extra" ]; then
      [ "$local_graph_safety" = UNSAFE ] \
        || printf 'warn: malformed local repository binding for %s\n' \
          "$path" >&2
      continue_local_ancestry=0
    else
      continue_local_ancestry=1
    fi
    if [ "$continue_local_ancestry" -eq 1 ]; then
    local_top=$(local_git "$local_root" rev-parse --show-toplevel 2>/dev/null) \
      || local_top=""
    if [ "$local_top" = "$local_root" ] \
      && local_git "$local_root" cat-file -e \
        "${pinned}^{commit}" 2>/dev/null \
      && local_git "$local_root" cat-file -e \
        "${upstream}^{commit}" 2>/dev/null; then
      if local_git "$local_root" merge-base --is-ancestor \
      "$pinned" "$upstream" 2>/dev/null; then
        relation="behind"
        if count=$(local_git "$local_root" rev-list --count \
          "${pinned}..${upstream}" 2>/dev/null) \
          && [[ "$count" =~ ^[0-9]+$ ]]; then
          distance="$count"
          behind_distance="$count"
        else
          printf 'warn: local behind-count evidence unavailable for %s\n' \
            "$path" >&2
        fi
      else
        ancestry_status=$?
        if [ "$ancestry_status" -eq 1 ]; then
          if local_git "$local_root" merge-base --is-ancestor \
            "$upstream" "$pinned" 2>/dev/null; then
            relation="ahead"
            behind_distance="0"
            if count=$(local_git "$local_root" rev-list --count \
              "${upstream}..${pinned}" 2>/dev/null) \
              && [[ "$count" =~ ^[0-9]+$ ]]; then
              distance="$count"
            else
              printf 'warn: local ahead-count evidence unavailable for %s\n' \
                "$path" >&2
            fi
          else
            reverse_status=$?
            if [ "$reverse_status" -eq 1 ]; then
              relation="diverged"
              ahead_count="?"
              behind_count="?"
              if count=$(local_git "$local_root" rev-list --count \
                "${upstream}..${pinned}" 2>/dev/null) \
                && [[ "$count" =~ ^[0-9]+$ ]]; then
                ahead_count="$count"
              fi
              if count=$(local_git "$local_root" rev-list --count \
                "${pinned}..${upstream}" 2>/dev/null) \
                && [[ "$count" =~ ^[0-9]+$ ]]; then
                behind_count="$count"
              fi
              behind_distance="$behind_count"
              distance="$ahead_count ahead / $behind_count behind"
            else
              printf 'warn: reverse ancestry evidence unavailable for %s\n' \
                "$path" >&2
            fi
          fi
        else
          printf 'warn: ancestry evidence unavailable for %s\n' "$path" >&2
        fi
      fi
      if date_str=$(local_git "$local_root" show -s --format=%cs \
        "$upstream" 2>/dev/null) \
        && [[ "$date_str" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
        last_updated="$date_str"
      else
        printf 'warn: local commit-date evidence unavailable for %s\n' \
          "$path" >&2
      fi
    elif [ -n "$local_top" ] && [ "$local_top" != "$local_root" ]; then
      printf 'warn: local repository identity unavailable for %s\n' "$path" >&2
    fi
    fi
    if ! path_guard verify-submodule "$REPO_ROOT" "$path" \
      "$ROOT_BINDING" "$local_binding" 2>/dev/null; then
      relation="different"
      distance="?"
      behind_distance="?"
      last_updated="unknown"
      printf 'warn: local repository changed during inspection: %s\n' \
        "$path" >&2
    fi
  fi

  if [ "$distance" = "?" ]; then
    distance_display="?"
  elif [ "$relation" = "diverged" ]; then
    distance_display="$distance"
  else
    distance_display="$distance commits"
  fi
  printf '| %s | %s | %s | %s | %s | %s |\n' \
    "$path" "${pinned:0:8}" "${upstream:0:8}" "$relation" \
    "$distance_display" "$last_updated"
  json_rows+=("$(printf '{"submodule":"%s","status":"%s","relation":"%s","pinned":"%s","upstream":"%s","distance":"%s","behind":"%s","last_updated":"%s"}' \
    "$path" "$relation" "$relation" "$pinned" "$upstream" \
    "$distance" "$behind_distance" "$last_updated")")
  drift_count=$((drift_count + 1))
done

if ! path_guard verify-root "$REPO_ROOT" "$ROOT_BINDING" 2>/dev/null; then
  printf 'error: repository or .gitmodules changed during inspection\n' >&2
  exit 2
fi

printf '\n'
if [ "$drift_count" -eq 0 ] && [ "$error_count" -eq 0 ]; then
  printf '**All %d submodule pins are up to date.**\n' "${#SUBMODULES[@]}"
else
  printf '**%d submodule pin(s) differ from upstream; %d error(s).**\n' \
    "$drift_count" "$error_count"
fi

if [ "$CI_MODE" -eq 1 ]; then
  report_path="$REPO_ROOT/drift-report.json"
  if ! path_guard verify-root "$REPO_ROOT" "$ROOT_BINDING" 2>/dev/null; then
    printf 'error: repository changed before report publication\n' >&2
    exit 2
  fi

  report_binding=$(publisher_call \
    bind "$report_path" replace) || exit 2
  generated_at=$(isolated_date -u +%Y-%m-%dT%H:%M:%SZ) || {
    printf 'error: could not generate report timestamp\n' >&2
    exit 2
  }
  if ! report_content="$({
    printf '{\n'
    printf '  "generated_at": "%s",\n' "$generated_at"
    printf '  "drift_count": %d,\n' "$drift_count"
    printf '  "error_count": %d,\n' "$error_count"
    printf '  "submodules": [\n'
    for i in "${!json_rows[@]}"; do
      sep=","
      [ "$i" -eq $((${#json_rows[@]} - 1)) ] && sep=""
      printf '    %s%s\n' "${json_rows[$i]}" "$sep"
    done
    printf '  ]\n'
    printf '}\n'
  })"; then
    printf 'error: could not render drift report\n' >&2
    exit 2
  fi
  report_content="${report_content}"$'\n'
  if ! printf '%s' "$report_content" | validate_report_json \
    "$drift_count" "$error_count" "${#SUBMODULES[@]}"; then
    printf 'error: generated drift report is invalid\n' >&2
    exit 2
  fi
  if ! printf '%s' "$report_content" | publisher_call \
    publish "$report_path" replace "$report_binding"; then
    exit 2
  fi
  has_drift="false"
  [ "$drift_count" -gt 0 ] && has_drift="true"
  printf 'has_drift=%s\n' "$has_drift"
fi

# Network errors take precedence so CI fails visibly rather than silently.
if [ "$error_count" -gt 0 ]; then
  exit 2
fi
if [ "$drift_count" -gt 0 ] && [ "$CI_MODE" -eq 0 ]; then
  exit 1
fi
exit 0
