#!/bin/bash -p
# Read-only GitHub security and Code Quality discovery for HomericIntelligence.

set -euo pipefail

unset BASH_ENV ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP \
  GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_CONFIG GIT_CONFIG_GLOBAL \
  GIT_CONFIG_SYSTEM GIT_CONFIG_PARAMETERS GIT_SSH GIT_SSH_COMMAND \
  LD_PRELOAD LD_LIBRARY_PATH LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
  DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
  DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_PRINT_TO_FILE

TRUSTED_PYTHON=/usr/bin/python3
ORG=HomericIntelligence
OUTPUT_PATH=""
ALL_ORG=0

usage() {
  printf '%s\n' \
    'Usage: tools/probe-code-quality.sh [--all] [--output PATH]' \
    '' \
    'Read current GitHub security and Code Quality state without changing it.' \
    '' \
    '  --all          Probe the complete live organization inventory.' \
    '  --output PATH  Atomically publish the same Markdown report to PATH.'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      OUTPUT_PATH="${2:-}"
      [ -n "$OUTPUT_PATH" ] || {
        printf 'error: --output requires a path\n' >&2
        exit 2
      }
      shift 2
      ;;
    --all) ALL_ORG=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

case "$OSTYPE" in
  linux*) ;;
  *)
    printf 'error: Linux descendant containment is required for GitHub reads\n' >&2
    exit 2
    ;;
esac

[ -x "$TRUSTED_PYTHON" ] || {
  printf 'error: trusted Python runtime is unavailable\n' >&2
  exit 2
}

script_location="${BASH_SOURCE[0]}"
case "$script_location" in
  */*) script_parent="${script_location%/*}"; [ -n "$script_parent" ] || script_parent=/ ;;
  *) script_parent=. ;;
esac
TOOL_ROOT="$(CDPATH='' cd -P -- "$script_parent" && pwd -P)" || {
  printf 'error: tool directory is unavailable\n' >&2
  exit 2
}
REPO_ROOT="${TOOL_ROOT%/tools}"
REPORT_RUNTIME="$REPO_ROOT/scripts/safe_report_publish.py"
[ -f "$REPORT_RUNTIME" ] && [ ! -L "$REPORT_RUNTIME" ] || {
  printf 'error: trusted reporting runtime is unavailable\n' >&2
  exit 2
}

PYTHON_ENV_LAUNCHER_SOURCE=$(/bin/cat <<'PY'
import os
import sys

if (
    len(sys.argv) < 4
    or sys.argv[1] != "/usr/bin/python3"
    or sys.argv[2] not in {"plain", "github"}
):
    raise SystemExit(2)
profile = sys.argv[2]
environment = {
    "HOME": "/dev/null",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
    "TZ": "UTC",
    "XDG_CONFIG_HOME": "/dev/null",
}
if profile == "github":
    for name in ("GH_TOKEN", "GITHUB_TOKEN"):
        value = os.environ.get(name)
        if value:
            environment[name] = value
os.execve(sys.argv[1], [sys.argv[1], *sys.argv[3:]], environment)
PY
)
minimal_python() {
  "$TRUSTED_PYTHON" -I -S -c "$PYTHON_ENV_LAUNCHER_SOURCE" \
    "$TRUSTED_PYTHON" plain "$@"
}
github_python() {
  "$TRUSTED_PYTHON" -I -S -c "$PYTHON_ENV_LAUNCHER_SOURCE" \
    "$TRUSTED_PYTHON" github "$@"
}

load_runtime_source() {
  minimal_python -I -S - "$1" <<'PY'
import os
import stat
import sys

maximum = 2 * 1024 * 1024
path = os.path.abspath(sys.argv[1])
parent, name = os.path.dirname(path), os.path.basename(path)
if os.path.realpath(parent) != parent or name in {"", ".", ".."}:
    raise SystemExit(2)
parent_descriptor = os.open(
    parent,
    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
)
try:
    named = os.lstat(name, dir_fd=parent_descriptor)
    if (
        not stat.S_ISREG(named.st_mode)
        or named.st_uid != os.geteuid()
        or named.st_nlink != 1
        or stat.S_IMODE(named.st_mode) & 0o022
        or named.st_size > maximum
    ):
        raise OSError("unsafe runtime source")
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC,
        dir_fd=parent_descriptor,
    )
    try:
        opened = os.fstat(descriptor)
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum:
                raise OSError("runtime source is too large")
            chunks.append(chunk)
        content = b"".join(chunks)
        final = os.fstat(descriptor)
        rebound = os.lstat(name, dir_fd=parent_descriptor)
        def record(value):
            return (
                value.st_ctime_ns,
                value.st_dev,
                value.st_gid,
                value.st_ino,
                value.st_mode,
                value.st_mtime_ns,
                value.st_nlink,
                value.st_size,
                value.st_uid,
            )
        if record(opened) != record(final) or record(opened) != record(rebound):
            raise OSError("runtime source changed")
    finally:
        os.close(descriptor)
finally:
    os.close(parent_descriptor)
source = content.decode("utf-8")
compile(source, path, "exec")
sys.stdout.write(source)
PY
}

RUNTIME_SOURCE=$(load_runtime_source "$REPORT_RUNTIME") || {
  printf 'error: trusted reporting runtime is unavailable\n' >&2
  exit 2
}
PROCESS_SUPERVISOR_SOURCE=$(/bin/cat <<'PY'
import ctypes
import os
from pathlib import Path
import select
import signal
import subprocess
import sys
import time
from contextlib import contextmanager


PR_SET_CHILD_SUBREAPER = 36
PR_GET_CHILD_SUBREAPER = 37
PR_SET_PDEATHSIG = 1
QUIESCENT_SCANS = 2
TERMINATION_SIGNALS = frozenset({signal.SIGINT, signal.SIGTERM, signal.SIGHUP})


class TerminationRequested(BaseException):
    def __init__(self, signal_number):
        super().__init__(f"termination requested by signal {signal_number}")
        self.signal_number = signal_number


@contextmanager
def blocked_termination_signals():
    blocker = getattr(signal, "pthread_sigmask", None)
    pending_reader = getattr(signal, "sigpending", None)
    if not callable(blocker) or not callable(pending_reader):
        raise NotImplementedError("signal-safe process acquisition is unavailable")
    previous = blocker(signal.SIG_BLOCK, TERMINATION_SIGNALS)
    try:
        yield
    finally:
        blocker(signal.SIG_SETMASK, previous)


def raise_for_pending_termination():
    pending = signal.sigpending()
    for signal_number in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        if signal_number in pending:
            raise TerminationRequested(signal_number)


def enable_subreaper():
    if not sys.platform.startswith("linux"):
        raise NotImplementedError("Linux descendant containment is unavailable")
    if not callable(getattr(os, "pidfd_open", None)) or not callable(
        getattr(signal, "pidfd_send_signal", None)
    ):
        raise NotImplementedError("Linux pidfd containment is unavailable")
    library = ctypes.CDLL(None, use_errno=True)
    prctl = getattr(library, "prctl", None)
    if prctl is None:
        raise NotImplementedError("Linux subreaper containment is unavailable")
    prctl.argtypes = [
        ctypes.c_int,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
        ctypes.c_ulong,
    ]
    prctl.restype = ctypes.c_int
    parent = os.getppid()
    ctypes.set_errno(0)
    if prctl(PR_SET_PDEATHSIG, signal.SIGTERM, 0, 0, 0) != 0:
        number = ctypes.get_errno() or 1
        raise OSError(number, "could not bind supervisor lifetime to its parent")
    if os.getppid() != parent:
        os.kill(os.getpid(), signal.SIGTERM)
    ctypes.set_errno(0)
    if prctl(PR_SET_CHILD_SUBREAPER, 1, 0, 0, 0) != 0:
        number = ctypes.get_errno() or 1
        raise OSError(number, "could not enable Linux subreaper containment")
    state = ctypes.c_int(0)
    ctypes.set_errno(0)
    if prctl(PR_GET_CHILD_SUBREAPER, ctypes.addressof(state), 0, 0, 0) != 0:
        number = ctypes.get_errno() or 1
        raise OSError(number, "could not verify Linux subreaper containment")
    if state.value != 1:
        raise OSError("Linux subreaper containment is not active")


def process_identity(process_id):
    try:
        with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
            content = stream.read(65537)
    except (FileNotFoundError, ProcessLookupError):
        return None
    if len(content) > 65536:
        raise OSError("process identity exceeds its byte ceiling")
    closing = content.rfind(b")")
    fields = content[closing + 2 :].split() if closing >= 1 else ()
    if len(fields) <= 19:
        raise OSError("process identity is malformed")
    return process_id, int(fields[19])


def child_pids(process_id):
    task_root = Path(f"/proc/{process_id}/task")
    try:
        tasks = tuple(entry.name for entry in task_root.iterdir() if entry.name.isdecimal())
    except (FileNotFoundError, ProcessLookupError):
        return set()
    children = set()
    for task in tasks:
        try:
            with open(task_root / task / "children", "rb", buffering=0) as stream:
                content = stream.read(1048577)
        except (FileNotFoundError, ProcessLookupError):
            continue
        if len(content) > 1048576:
            raise OSError("child inventory exceeds its byte ceiling")
        for value in content.split():
            if not value.isdigit():
                raise OSError("child inventory is malformed")
            child = int(value)
            if child > 1:
                children.add(child)
    return children


class Scope:
    def __init__(self):
        enable_subreaper()
        self.supervisor = os.getpid()
        self.baseline = {
            identity
            for process_id in child_pids(self.supervisor)
            if (identity := process_identity(process_id)) is not None
        }
        self.owned = {}

    def track(self, process_id, root=False):
        identity = process_identity(process_id)
        if identity is None or (not root and identity in self.baseline):
            return False
        previous = self.owned.get(process_id)
        if previous is not None and previous[0] == identity[1]:
            return False
        if previous is not None:
            os.close(previous[1])
        descriptor = os.pidfd_open(process_id, 0)
        if process_identity(process_id) != identity:
            os.close(descriptor)
            raise OSError("process identity changed while binding")
        self.owned[process_id] = (identity[1], descriptor)
        return True

    def track_root(self, process_id):
        if not self.track(process_id, root=True):
            raise OSError("could not bind command leader")
        return self.owned[process_id][1]

    def discover(self):
        discovered = False
        while True:
            candidates = set(child_pids(self.supervisor))
            for process_id, (start_time, _descriptor) in tuple(self.owned.items()):
                if process_identity(process_id) == (process_id, start_time):
                    candidates.update(child_pids(process_id))
            changed = False
            for process_id in candidates:
                changed = self.track(process_id) or changed
            discovered = discovered or changed
            if not changed:
                return discovered

    @staticmethod
    def exited(descriptor):
        ready, _writable, _exceptional = select.select([descriptor], [], [], 0)
        return bool(ready)

    def live_snapshot(self):
        return tuple(
            (process_id, descriptor)
            for process_id, (_start, descriptor) in self.owned.items()
            if not self.exited(descriptor)
        )

    def live(self):
        self.discover()
        live = self.live_snapshot()
        if live:
            return live
        # A bound parent can fork after its children inventory was read and
        # exit before its pidfd is checked. Once every bound parent is exited,
        # consecutive unchanged rescans bind all children adopted here.
        unchanged_scans = 0
        while unchanged_scans < QUIESCENT_SCANS:
            changed = self.discover()
            live = self.live_snapshot()
            if live:
                return live
            unchanged_scans = 0 if changed else unchanged_scans + 1
        return ()

    def descendants(self, leader):
        return tuple(item for item in self.live() if item[0] != leader)

    def send(self, descriptor, number):
        try:
            signal.pidfd_send_signal(descriptor, number, None, 0)
        except ProcessLookupError:
            pass

    def terminate(self, process):
        cleanup_error = None
        for number, interval in ((signal.SIGTERM, 0.25), (signal.SIGKILL, 0.5)):
            deadline = time.monotonic() + interval
            while True:
                try:
                    live = self.live()
                except BaseException as error:
                    cleanup_error = cleanup_error or error
                    live = tuple(
                        (process_id, descriptor)
                        for process_id, (_start, descriptor) in self.owned.items()
                        if not self.exited(descriptor)
                    )
                if not live:
                    break
                for _process_id, descriptor in live:
                    try:
                        self.send(descriptor, number)
                    except BaseException as error:
                        cleanup_error = cleanup_error or error
                if time.monotonic() >= deadline:
                    break
                time.sleep(0.01)
        if self.live():
            raise OSError("owned descendants survived containment cleanup")
        process.wait(timeout=1.0)
        self.reap(process.pid)
        if cleanup_error is not None:
            raise OSError("descendant containment cleanup failed") from cleanup_error

    def reap(self, leader):
        for process_id in tuple(self.owned):
            if process_id == leader:
                continue
            try:
                os.waitpid(process_id, os.WNOHANG)
            except ChildProcessError:
                pass

    def close(self):
        for _start, descriptor in self.owned.values():
            os.close(descriptor)
        self.owned.clear()


def main():
    if len(sys.argv) < 6 or sys.argv[3:5] != ["run", "gh"]:
        raise ValueError("invalid supervised runtime invocation")
    python_path, runtime_source = sys.argv[1:3]
    runtime_arguments = sys.argv[3:]
    deadline_ns = int(runtime_arguments[2])
    if deadline_ns <= time.monotonic_ns():
        print(
            "error: trusted command timed out: operation deadline expired",
            file=sys.stderr,
        )
        raise SystemExit(124)
    with blocked_termination_signals():
        scope = Scope()
        process = None
        try:
            raise_for_pending_termination()
            process = subprocess.Popen(
                [python_path, "-I", "-S", "-c", runtime_source, *runtime_arguments],
                stdin=subprocess.DEVNULL,
                close_fds=True,
                start_new_session=True,
            )
            leader = scope.track_root(process.pid)
            raise_for_pending_termination()
            while not scope.exited(leader):
                raise_for_pending_termination()
                remaining = (deadline_ns - time.monotonic_ns()) / 1_000_000_000
                if remaining <= 0:
                    raise TimeoutError("trusted command operation deadline expired")
                scope.discover()
                select.select([leader], [], [], min(0.05, remaining))
            if scope.descendants(process.pid):
                scope.terminate(process)
                print(
                    "error: trusted command left a detached descendant",
                    file=sys.stderr,
                )
                raise SystemExit(124)
            raise_for_pending_termination()
            status = process.wait(timeout=1.0)
            scope.reap(process.pid)
            raise SystemExit(status)
        except TerminationRequested:
            if process is not None:
                scope.terminate(process)
            raise
        except TimeoutError as error:
            if process is not None:
                scope.terminate(process)
            print(f"error: trusted command timed out: {error}", file=sys.stderr)
            raise SystemExit(124)
        except SystemExit:
            raise
        except BaseException:
            if process is not None:
                scope.terminate(process)
            print("error: Linux command containment failed", file=sys.stderr)
            raise SystemExit(2)
        finally:
            scope.close()


main()
PY
)
runtime_call() {
  if [ "${1:-}" = run ]; then
    github_python -I -S -c "$PROCESS_SUPERVISOR_SOURCE" \
      "$TRUSTED_PYTHON" "$RUNTIME_SOURCE" "$@"
  else
    minimal_python -I -S -c "$RUNTIME_SOURCE" "$@"
  fi
}

REMOTE_TIMEOUT_SECONDS=30
REMOTE_OUTPUT_BYTES=8388608
REMOTE_OPERATION_SECONDS=300

OUTPUT_BINDING=""
if [ -n "$OUTPUT_PATH" ]; then
  OUTPUT_BINDING=$(runtime_call bind "$OUTPUT_PATH" replace) || exit 2
fi
OPERATION_DEADLINE=$(runtime_call deadline "$REMOTE_OPERATION_SECONDS") || exit 2
GH_BINDING=$(runtime_call resolve gh "") || exit 2
gh_call() {
  runtime_call run gh "$OPERATION_DEADLINE" "$REMOTE_TIMEOUT_SECONDS" \
    "$REMOTE_OUTPUT_BYTES" "$GH_BINDING" "$@"
}

parse_repository_pages() {
  minimal_python -I -S -c '
import json
import re
import sys
pages = json.load(sys.stdin)
if not isinstance(pages, list) or not pages:
    raise SystemExit(1)
seen = set()
for page in pages:
    if not isinstance(page, list):
        raise SystemExit(1)
    for item in page:
        name = item.get("name") if isinstance(item, dict) else None
        if not isinstance(name, str) or re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,99}", name) is None:
            raise SystemExit(1)
        if name in seen or len(seen) >= 1000:
            raise SystemExit(1)
        seen.add(name)
        print(name)
if not seen:
    raise SystemExit(1)
'
}

parse_feature_state() {
  minimal_python -I -S -c '
import json
import sys
key = sys.argv[1]
value = json.load(sys.stdin)
if not isinstance(value, dict):
    raise SystemExit(1)
security = value.get("security_and_analysis")
entry = security.get(key) if isinstance(security, dict) else None
if not isinstance(entry, dict):
    raise SystemExit(1)
enabled = entry.get("enabled")
status = entry.get("status")
has_enabled = "enabled" in entry
has_status = "status" in entry
if has_enabled and type(enabled) is not bool:
    raise SystemExit(1)
if has_status and status not in {"enabled", "disabled"}:
    raise SystemExit(1)
states = []
if has_enabled:
    states.append("enabled" if enabled else "disabled")
if has_status:
    states.append(status)
if not states or any(state != states[0] for state in states[1:]):
    raise SystemExit(1)
print(states[0])
' "$1"
}

parse_scanning_state() {
  minimal_python -I -S -c '
import json
import sys
value = json.load(sys.stdin)
state = value.get("state") if isinstance(value, dict) else None
if state not in {"configured", "not-configured"}:
    raise SystemExit(1)
print(state)
'
}

parse_quality_state() {
  minimal_python -I -S -c '
import json
import sys
decoder = json.JSONDecoder()
source = sys.stdin.read()
value, end = decoder.raw_decode(source)
if source[end:].strip() or not isinstance(value, dict):
    raise SystemExit(1)
enabled = value.get("enabled")
if enabled is True:
    print("enabled")
elif enabled is False:
    print("disabled")
else:
    raise SystemExit(1)
'
}

valid_json_object() {
  minimal_python -I -S -c '
import json
import sys
value = json.load(sys.stdin)
if not isinstance(value, dict):
    raise SystemExit(1)
'
}

REPOS=()
if [ "$ALL_ORG" -eq 1 ]; then
  pages=$(gh_call api --paginate --slurp \
    "orgs/${ORG}/repos?per_page=100&type=all") || {
    printf 'error: could not read the organization repository inventory\n' >&2
    exit 2
  }
  names=$(printf '%s' "$pages" | parse_repository_pages) || {
    printf 'error: organization repository inventory is malformed\n' >&2
    exit 2
  }
  while IFS= read -r name; do REPOS+=("$name"); done <<< "$names"
  scope_mode="organization inventory"
else
  GITMODULES="$REPO_ROOT/.gitmodules"
  inventory=$(runtime_call inventory "$GITMODULES") || {
    printf 'error: could not read the canonical gitlink inventory\n' >&2
    exit 2
  }
  REPOS=(Odysseus)
  while IFS= read -r repository; do
    [ -n "$repository" ] || continue
    REPOS+=("${repository#"$ORG/"}")
  done <<< "$inventory"
  scope_mode="canonical gitlink inventory plus Odysseus"
fi
[ "${#REPOS[@]}" -gt 0 ] || {
  printf 'error: no repos resolved\n' >&2
  exit 2
}

feature_state() {
  local repo="$1" key="$2" body
  body=$(gh_call api "repos/${ORG}/${repo}") || {
    printf 'warn: repository feature read unavailable for %s\n' "$repo" >&2
    printf 'unavailable'
    return
  }
  printf '%s' "$body" | parse_feature_state "$key" 2>/dev/null \
    || printf 'unavailable'
}

scanning_state() {
  local repo="$1" body
  body=$(gh_call api "repos/${ORG}/${repo}/code-scanning/default-setup") || {
    printf 'warn: Code Scanning read unavailable for %s\n' "$repo" >&2
    printf 'unavailable'
    return
  }
  printf '%s' "$body" | parse_scanning_state 2>/dev/null \
    || printf 'unavailable'
}

quality_state() {
  local repo="$1" body
  body=$(gh_call api "repos/${ORG}/${repo}/code-quality") || {
    printf 'warn: Code Quality read unavailable for %s\n' "$repo" >&2
    printf 'unavailable'
    return
  }
  printf '%s' "$body" | parse_quality_state 2>/dev/null \
    || printf 'unavailable'
}

file_state() {
  local repo="$1" path="$2" body
  body=$(gh_call api "repos/${ORG}/${repo}/contents/${path}") || {
    printf 'unavailable'
    return
  }
  if printf '%s' "$body" | valid_json_object 2>/dev/null; then
    printf 'present'
  else
    printf 'unavailable'
  fi
}

generated_at=$(minimal_python -I -S -c \
  'import datetime; print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))') \
  || { printf 'error: report timestamp unavailable\n' >&2; exit 2; }
report=""
append() { report+="$1"$'\n'; }
append "# HomericIntelligence — repository security readbacks"
append ""
append "> Generated $generated_at by \`tools/probe-code-quality.sh\`"
append "> Scope: **${#REPOS[@]}** repositories (mode: $scope_mode)"
append ""
append "## Per-repo state"
append ""
append "| Repo | Dependabot sec | Secret scan | Push prot | Code Scanning | Code Quality | CQ config |"
append "|------|----|----|----|----|----|----|"

for repo in "${REPOS[@]}"; do
  dependabot=$(feature_state "$repo" dependabot_security_updates)
  secrets=$(feature_state "$repo" secret_scanning)
  push=$(feature_state "$repo" secret_scanning_push_protection)
  scanning=$(scanning_state "$repo")
  quality=$(quality_state "$repo")
  config=$(file_state "$repo" .github/codeql/code-quality-config.yml)
  append "| $repo | $dependabot | $secrets | $push | $scanning | $quality | $config |"
done

append ""
append "## Readback boundaries"
append ""
append "- \`enabled\` and \`disabled\` are explicit API values from this run."
append "- \`unavailable\` means transport, authorization, endpoint, or schema state did not permit a readback. Do not infer a setting from it."
append "- \`present\` means that this run read the listed repository path."
append "- Consult current official GitHub documentation and \`docs/runbooks/disable-code-quality.md\` before a separately authorized setting change."

if [ -n "$OUTPUT_PATH" ]; then
  printf '%s' "$report" \
    | runtime_call publish "$OUTPUT_PATH" replace "$OUTPUT_BINDING" || exit 2
fi
printf '%s' "$report"
