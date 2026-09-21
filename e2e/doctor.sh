#!/usr/bin/env bash
# HomericIntelligence Doctor — E2E Pipeline Prerequisite Checker
#
# Verifies dependencies for the selected local role. Cross-host topology,
# peer, and service checks run only after the explicit --cross-host selection.
# Checks follow the component hierarchy from docs/architecture.md.
#
# Usage:
#   just doctor                    # Check-only mode
#   just doctor --install          # Check + apply safe local-state repairs
#   just doctor --role worker      # Only check worker-host dependencies
#   just doctor --role control     # Only check control-host dependencies
#   just doctor --cross-host --worker-ip IP
#   just doctor --cross-host --capability-only
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
set -uo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
_PASS=0; _FAIL=0; _WARN=0; _SKIP=0

check_pass()  { _PASS=$((_PASS + 1));  echo -e "  ${GREEN}✓${NC} $1"; }
check_fail()  { _FAIL=$((_FAIL + 1));  echo -e "  ${RED}✗${NC} $1"; }
check_warn()  { _WARN=$((_WARN + 1));  echo -e "  ${YELLOW}⚠${NC} $1"; }
check_skip()  { _SKIP=$((_SKIP + 1));  echo -e "  ${DIM}–${NC} $1 ${DIM}(skipped)${NC}"; }
section()     { echo -e "\n${BOLD}${CYAN}$1${NC}"; }

# Parse peer targets with the standard-library IP parser. The parser rejects
# hostnames, ports, zone identifiers, brackets, and address-shaped text that is
# not a complete IPv4 or IPv6 literal. Its compressed output is the one value
# passed to topology and service commands.
canonicalize_ip_literal() {
    if ! run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import ipaddress
import sys

candidate = sys.argv[1]
if "%" in candidate:
    raise SystemExit(1)
try:
    address = ipaddress.ip_address(candidate)
except ValueError:
    raise SystemExit(1)
print(address.compressed)
' "$1"; then
        return 1
    fi
    printf '%s\n' "$BOUNDED_OUTPUT"
}

http_host_for_ip() {
    case "$1" in
        *:*) printf '[%s]\n' "$1" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

valid_tailscale_status() {
    run_bounded_command_with_stdin "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import ipaddress
import json
import sys

try:
    value = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeError):
    raise SystemExit(1)
if not isinstance(value, dict):
    raise SystemExit(1)
self_node = value.get("Self")
peers = value.get("Peer")
if not isinstance(self_node, dict) or not isinstance(peers, dict):
    raise SystemExit(1)
nodes = [self_node, *peers.values()]
for node in nodes:
    if not isinstance(node, dict) or type(node.get("Online")) is not bool:
        raise SystemExit(1)
    addresses = node.get("TailscaleIPs")
    if not isinstance(addresses, list) or any(not isinstance(item, str) for item in addresses):
        raise SystemExit(1)
    try:
        if any(ipaddress.ip_address(item).compressed != item for item in addresses):
            raise SystemExit(1)
    except ValueError:
        raise SystemExit(1)
' >/dev/null
}

is_online_tailscale_peer() {
    local target=$1
    run_bounded_command_with_stdin "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import ipaddress
import json
import sys

target = ipaddress.ip_address(sys.argv[1])
value = json.load(sys.stdin)
self_addresses = {
    ipaddress.ip_address(item) for item in value["Self"]["TailscaleIPs"]
}
if target in self_addresses:
    raise SystemExit(1)
matches = 0
for peer in value["Peer"].values():
    addresses = {ipaddress.ip_address(item) for item in peer["TailscaleIPs"]}
    if target in addresses and peer["Online"] is True:
        matches += 1
raise SystemExit(0 if matches == 1 else 1)
' "$target" >/dev/null
}

service_health_matches() (
    local kind=$1
    unset BASH_ENV ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT \
        PYTHONWARNINGS PYTHONSAFEPATH PYTHONUSERBASE
    # shellcheck disable=SC2329 # Called indirectly by http_response_matches.
    python3() { "$PYTHON3_BIN" -I -S "$@"; }
    http_response_matches "$kind"
)

check_service_health() {
    local label=$1 url=$2 kind=$3
    if run_bounded_curl_stream 15 1048580 \
        --connect-timeout 5 --max-time 15 --silent \
        --write-out '\n%{http_code}' --noproxy '*' "$url" \
        | service_health_matches "$kind"; then
        check_pass "$label"
    else
        check_fail "$label — response identity or health schema did not match"
    fi
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
INSTALL=false
ROLE="all"              # all | worker | control
CHECK_SERVICES=false
CROSS_HOST=false
CONFIGURE_FIREWALL=false
CAPABILITY_ONLY=false
WORKER_IP=""
CONTROL_IP=""
PYTHON3_READY=false
PYTHON3_BIN=""
PYTHON3_FD=""
GIT_BIN=""
GIT_FD=""
CURL_BIN=""
CURL_FD=""
BOUND_SNAPSHOT_PATHS=()
BOUND_SNAPSHOT_DIRECTORIES=()
BOUND_SNAPSHOT_FDS=()
BOUNDARY_PLATFORM=""
TAILSCALE_STATUS_JSON=""
TAILSCALE_STATUS_AVAILABLE=false
WORKER_PEER_VERIFIED=false
CONTROL_PEER_VERIFIED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)         INSTALL=true; shift ;;
        --role)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --role requires all, worker, or control" >&2
                exit 1
            fi
            ROLE="$2"
            shift 2
            ;;
        --cross-host)      CROSS_HOST=true; shift ;;
        --capability-only) CAPABILITY_ONLY=true; shift ;;
        --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
        --check-services)  CHECK_SERVICES=true; shift ;;
        --worker-ip)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --worker-ip requires an address" >&2
                exit 1
            fi
            WORKER_IP="$2"
            shift 2
            ;;
        --control-ip)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --control-ip requires an address" >&2
                exit 1
            fi
            CONTROL_IP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: just doctor [--install] [--role worker|control] [--cross-host (--worker-ip IP | --control-ip IP | --capability-only) [--check-services]]"
            echo "  --install applies safe local-state repairs; pre-provision verified packages and executables separately."
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

case "$ROLE" in
    all|worker|control) ;;
    *)
        echo "ERROR: role must be one of: all, worker, control" >&2
        exit 1
        ;;
esac
if $CHECK_SERVICES && [[ -z "$WORKER_IP" && -z "$CONTROL_IP" ]]; then
    echo "ERROR: --check-services requires --worker-ip or --control-ip" >&2
    exit 1
fi
if $CONFIGURE_FIREWALL; then
    echo "ERROR: broad trusted-interface firewall mutation is unavailable in doctor; use an exact deployment-owned listener/peer policy after operator approval" >&2
    exit 1
fi
if ! $CROSS_HOST; then
    if [[ -n "$WORKER_IP" ]]; then
        echo "ERROR: --worker-ip requires --cross-host" >&2
        exit 1
    fi
    if [[ -n "$CONTROL_IP" ]]; then
        echo "ERROR: --control-ip requires --cross-host" >&2
        exit 1
    fi
    if $CHECK_SERVICES; then
        echo "ERROR: --check-services requires --cross-host" >&2
        exit 1
    fi
    if $CAPABILITY_ONLY; then
        echo "ERROR: --capability-only requires --cross-host" >&2
        exit 1
    fi
fi
if $CROSS_HOST && [[ -z "$WORKER_IP" && -z "$CONTROL_IP" ]] \
        && ! $CAPABILITY_ONLY; then
    echo "ERROR: --cross-host requires an exact peer target (--worker-ip or --control-ip) or explicit --capability-only mode" >&2
    exit 1
fi
if $CAPABILITY_ONLY && [[ -n "$WORKER_IP" || -n "$CONTROL_IP" || "$CHECK_SERVICES" == true ]]; then
    echo "ERROR: --capability-only cannot be combined with peer or service targets" >&2
    exit 1
fi
# ─── Helpers ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Check if a command exists
has_cmd() { command -v "$1" &>/dev/null; }

resolve_python3() {
    local candidate
    candidate=$(type -P python3 2>/dev/null) || return 1
    bind_executable_snapshot "$candidate" PYTHON3_FD PYTHON3_BIN
}

resolve_git() {
    local candidate
    candidate=$(type -P git 2>/dev/null) || return 1
    bind_executable_snapshot "$candidate" GIT_FD GIT_BIN
}

resolve_curl() {
    local candidate
    candidate=$(type -P curl 2>/dev/null) || return 1
    bind_executable_snapshot "$candidate" CURL_FD CURL_BIN
}

scrub_bound_executable_snapshot() {
    local snapshot_path=$1 binding_directory=$2 expected_fd=${3:-}
    /usr/bin/env -i PATH=/usr/bin:/bin LC_ALL=C \
        /usr/bin/python3 -I -S - "$snapshot_path" "$binding_directory" \
        "$expected_fd" <<'PY'
import os
import secrets
import stat
import sys


snapshot_path, directory_path, expected_fd_text = sys.argv[1:]
if os.path.dirname(snapshot_path) != directory_path \
        or os.path.basename(snapshot_path) != "executable":
    raise SystemExit(1)
directory = os.open(
    directory_path,
    os.O_RDONLY
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0),
)
try:
    directory_info = os.fstat(directory)
    if not stat.S_ISDIR(directory_info.st_mode) \
            or directory_info.st_uid != os.geteuid() \
            or stat.S_IMODE(directory_info.st_mode) != 0o700:
        raise SystemExit(1)
    expected = None
    if expected_fd_text:
        expected = os.fstat(int(expected_fd_text))
    opened = os.open(
        "executable",
        os.O_WRONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=directory,
    )
    try:
        before = os.fstat(opened)
        if expected is not None and (before.st_dev, before.st_ino) != (
            expected.st_dev,
            expected.st_ino,
        ):
            raise SystemExit(1)
        quarantine = f".executable.cleanup-{secrets.token_hex(16)}"
        os.rename(
            "executable",
            quarantine,
            src_dir_fd=directory,
            dst_dir_fd=directory,
        )
        named = os.stat(quarantine, dir_fd=directory, follow_symlinks=False)
        if (named.st_dev, named.st_ino) != (before.st_dev, before.st_ino):
            raise SystemExit(1)
        os.fchmod(opened, 0)
        os.ftruncate(opened, 0)
        os.fsync(opened)
        print(os.path.join(directory_path, quarantine))
    finally:
        os.close(opened)
finally:
    os.close(directory)
PY
}

report_scrubbed_executable_snapshot() {
    local snapshot_path=$1 binding_directory=$2 expected_fd=${3:-}
    local recovery_path
    if recovery_path=$(scrub_bound_executable_snapshot "$snapshot_path" \
        "$binding_directory" "$expected_fd" 2>/dev/null); then
        printf '%s\n' \
            "WARNING: scrubbed executable quarantine retained for operator recovery at $recovery_path" >&2
        return 0
    else
        printf '%s\n' \
            "WARNING: executable snapshot cleanup was unsafe; operator recovery required at $binding_directory" >&2
        return 1
    fi
}

# Copy one verified executable into an owner-only snapshot before it receives
# authority. Linux executes an unlinked descriptor; other platforms retain a
# private, non-writable path until exit. A fixed host Python route performs the
# bootstrap, so later source replacement cannot change the captured bytes.
bind_executable_snapshot() {
    local source_path=$1 descriptor_name=$2 path_name=$3
    local binding_directory snapshot_path descriptor="" descriptor_candidate
    local captured_platform
    [[ "$source_path" == /* && -x /usr/bin/python3 ]] || return 1
    binding_directory=$(/usr/bin/mktemp -d \
        "/tmp/odysseus-doctor-bind.XXXXXX") || return 1
    snapshot_path="$binding_directory/executable"
    if ! captured_platform=$(/usr/bin/env -i \
        HOME=/dev/null PATH=/usr/bin:/bin LC_ALL=C \
        /usr/bin/python3 -I -S -c '
import fcntl
import os
import stat
import sys

source = os.path.realpath(sys.argv[1])
destination = sys.argv[2]
before = os.lstat(source)
descriptor = os.open(
    source,
    os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
)
lease = False
try:
    opened = os.fstat(descriptor)
    mode = stat.S_IMODE(opened.st_mode)
    if (
        not stat.S_ISREG(opened.st_mode)
        or opened.st_uid not in (0, os.geteuid())
        or mode & 0o022
        or (opened.st_uid == os.geteuid() and mode & 0o200)
        or mode & 0o111 == 0
        or opened.st_size <= 0
        or opened.st_size > 128 * 1024 * 1024
    ):
        raise OSError("unsafe executable source")
    if sys.platform.startswith("linux") and opened.st_uid == os.geteuid():
        fcntl.fcntl(descriptor, fcntl.F_SETLEASE, fcntl.F_RDLCK)
        lease = True
    data = bytearray()
    while len(data) <= 128 * 1024 * 1024:
        chunk = os.read(descriptor, 65536)
        if not chunk:
            break
        data.extend(chunk)
    after = os.lstat(source)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
    )
    if len(data) != opened.st_size \
            or identity(before) != identity(opened) \
            or identity(opened) != identity(after):
        raise OSError("executable source changed during capture")
    target = os.open(
        destination,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o500,
    )
    try:
        view = memoryview(data)
        while view:
            written = os.write(target, view)
            if written <= 0:
                raise OSError("short executable snapshot write")
            view = view[written:]
        os.fsync(target)
        os.fchmod(target, 0o500)
    finally:
        os.close(target)
finally:
    if lease:
        fcntl.fcntl(descriptor, fcntl.F_SETLEASE, fcntl.F_UNLCK)
    os.close(descriptor)
print("linux" if sys.platform.startswith("linux") else "other")
' "$source_path" "$snapshot_path"); then
        report_scrubbed_executable_snapshot "$snapshot_path" \
            "$binding_directory"
        return 1
    fi
    if [[ "$captured_platform" != linux && "$captured_platform" != other ]]; then
        report_scrubbed_executable_snapshot "$snapshot_path" \
            "$binding_directory"
        return 1
    fi
    if [[ -n "$BOUNDARY_PLATFORM" \
        && "$BOUNDARY_PLATFORM" != "$captured_platform" ]]; then
        report_scrubbed_executable_snapshot "$snapshot_path" \
            "$binding_directory"
        return 1
    fi
    BOUNDARY_PLATFORM=$captured_platform
    for descriptor_candidate in {9..63}; do
        if ! eval ": <&$descriptor_candidate" 2>/dev/null \
            && eval "exec $descriptor_candidate<\"\$snapshot_path\""; then
            descriptor=$descriptor_candidate
            break
        fi
    done
    [[ -n "$descriptor" ]] || {
        report_scrubbed_executable_snapshot "$snapshot_path" \
            "$binding_directory"
        return 1
    }
    printf -v "$descriptor_name" '%s' "$descriptor"
    BOUND_SNAPSHOT_PATHS+=("$snapshot_path")
    BOUND_SNAPSHOT_DIRECTORIES+=("$binding_directory")
    BOUND_SNAPSHOT_FDS+=("$descriptor")
    if [[ "$BOUNDARY_PLATFORM" == linux ]]; then
        printf -v "$path_name" '/dev/fd/%s' "$descriptor"
    else
        printf -v "$path_name" '%s' "$snapshot_path"
    fi
}

close_bound_descriptor() {
    local descriptor=$1 index
    [[ "$descriptor" =~ ^[0-9]+$ ]] || return 1
    for ((index = 0; index < ${#BOUND_SNAPSHOT_FDS[@]}; index++)); do
        [[ "${BOUND_SNAPSHOT_FDS[$index]}" == "$descriptor" ]] || continue
        if ! report_scrubbed_executable_snapshot \
            "${BOUND_SNAPSHOT_PATHS[$index]}" \
            "${BOUND_SNAPSHOT_DIRECTORIES[$index]}" \
            "$descriptor"; then
            return 1
        fi
        BOUND_SNAPSHOT_PATHS[$index]=""
        BOUND_SNAPSHOT_DIRECTORIES[$index]=""
        BOUND_SNAPSHOT_FDS[$index]=""
        break
    done
    eval "exec $descriptor<&-"
}

cleanup_bound_executable_snapshots() {
    local exit_status=$1 index
    trap - EXIT
    for ((index = 0; index < ${#BOUND_SNAPSHOT_PATHS[@]}; index++)); do
        [[ -n "${BOUND_SNAPSHOT_PATHS[$index]}" ]] || continue
        report_scrubbed_executable_snapshot \
            "${BOUND_SNAPSHOT_PATHS[$index]}" \
            "${BOUND_SNAPSHOT_DIRECTORIES[$index]}" \
            "${BOUND_SNAPSHOT_FDS[$index]}"
    done
    exit "$exit_status"
}
trap 'cleanup_bound_executable_snapshots "$?"' EXIT

VERSION_TIMEOUT_SECONDS=3
VERSION_MAX_BYTES=65536
PYTHON_CHECK_TIMEOUT_SECONDS=3
PYTHON_CHECK_MAX_BYTES=1048576
TAILSCALE_TIMEOUT_SECONDS=3
TAILSCALE_MAX_BYTES=131072
LOCAL_READ_TIMEOUT_SECONDS=5
LOCAL_READ_MAX_BYTES=1048576
REPAIR_TIMEOUT_SECONDS=5
REPAIR_MAX_BYTES=131072
BOUNDED_OUTPUT=""
BOUNDARY_EXTRA_FDS=""
BOUNDARY_GIT_MODE=false

# Run one argv vector behind a wall-clock and byte boundary. The helper creates
# a new process group, drains only the allowed output, and terminates the whole
# group on timeout, overflow, or interruption. Linux subreaper cleanup also
# extinguishes descendants after every successful or failed invocation. The
# interpreter used for the boundary is an already-resolved absolute path and
# is itself isolated from ambient Python startup state.
_run_bounded_process() {
    local environment_policy=$1 timeout_seconds=$2 maximum_bytes=$3
    local inherited_fds status
    local -a boundary_environment
    shift 3
    BOUNDED_OUTPUT=""
    [[ -n "$PYTHON3_BIN" && "$timeout_seconds" =~ ^[1-9][0-9]*$ \
        && "$maximum_bytes" =~ ^[1-9][0-9]*$ && "$#" -gt 0 ]] || return 2

    inherited_fds=$PYTHON3_FD
    [[ -n "$GIT_FD" ]] && inherited_fds="$inherited_fds,$GIT_FD"
    [[ -n "$BOUNDARY_EXTRA_FDS" ]] \
        && inherited_fds="$inherited_fds,$BOUNDARY_EXTRA_FDS"

    boundary_environment=(
        "HOME=${HOME:-/dev/null}"
        "PATH=${PATH:-/usr/bin:/bin}"
        "LC_ALL=C"
    )
    [[ -n "${USER:-}" ]] && boundary_environment+=("USER=$USER")
    [[ -n "${LOGNAME:-}" ]] && boundary_environment+=("LOGNAME=$LOGNAME")
    [[ -n "${TMPDIR:-}" ]] && boundary_environment+=("TMPDIR=$TMPDIR")
    [[ -n "${XDG_RUNTIME_DIR:-}" ]] \
        && boundary_environment+=("XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR")
    [[ -n "${DBUS_SESSION_BUS_ADDRESS:-}" ]] \
        && boundary_environment+=("DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS")
    if $BOUNDARY_GIT_MODE; then
        boundary_environment+=(
            XDG_CONFIG_HOME=/dev/null
            GIT_CONFIG_GLOBAL=/dev/null
            GIT_CONFIG_SYSTEM=/dev/null
            GIT_CONFIG_NOSYSTEM=1
            GIT_CONFIG_COUNT=0
            GIT_NO_REPLACE_OBJECTS=1
            GIT_TERMINAL_PROMPT=0
        )
    fi

    /usr/bin/env -i "${boundary_environment[@]}" \
            "$PYTHON3_BIN" -I -S -c '
import os
import atexit
import resource
import selectors
import secrets
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

if sys.platform.startswith("linux"):
    import ctypes

    libc = ctypes.CDLL(None, use_errno=True)
    if libc.prctl(36, 1, 0, 0, 0) != 0:  # PR_SET_CHILD_SUBREAPER
        raise SystemExit(126)

environment_policy = sys.argv[1]
if environment_policy not in ("read", "read-stdin", "effect", "curl"):
    raise SystemExit(2)
if environment_policy == "effect" and not sys.platform.startswith("linux"):
    raise SystemExit(126)
timeout = int(sys.argv[2])
maximum = int(sys.argv[3])
inherited_fds = tuple(int(value) for value in sys.argv[4].split(",") if value)
argv = sys.argv[5:]
deadline = time.monotonic() + timeout
interrupted = None


def catch_signal(signum, _frame):
    global interrupted
    interrupted = signum


for caught in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(caught, catch_signal)


def relay_interruption():
    if interrupted is None:
        return
    signal.signal(interrupted, signal.SIG_DFL)
    os.kill(os.getpid(), interrupted)


if environment_policy == "curl":
    environment = {"LC_ALL": "C", "PATH": "/usr/bin:/bin"}
else:
    environment = {
        name: os.environ[name]
        for name in (
            "HOME", "PATH", "USER", "LOGNAME", "TMPDIR", "XDG_RUNTIME_DIR",
            "DBUS_SESSION_BUS_ADDRESS", "LC_ALL", "XDG_CONFIG_HOME",
            "GIT_CONFIG_GLOBAL", "GIT_CONFIG_SYSTEM", "GIT_CONFIG_NOSYSTEM",
            "GIT_CONFIG_COUNT", "GIT_NO_REPLACE_OBJECTS", "GIT_TERMINAL_PROMPT",
        )
        if name in os.environ
    }
if environment_policy == "effect":
    environment["PATH"] = "/usr/bin:/bin"

candidate = argv[0] if os.path.isabs(argv[0]) else shutil.which(
    argv[0], path=environment.get("PATH", "")
)
if candidate is None:
    raise SystemExit(127)
before = os.stat(candidate)
executable_fd = os.open(
    candidate,
    os.O_RDONLY | getattr(os, "O_CLOEXEC", 0),
)
opened = os.fstat(executable_fd)
identity = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_mode,
    value.st_uid,
    value.st_nlink,
    value.st_size,
    value.st_mtime_ns,
)
mode = stat.S_IMODE(opened.st_mode)
if (
    identity(before) != identity(opened)
    or not stat.S_ISREG(opened.st_mode)
    or opened.st_uid not in (0, os.geteuid())
    or mode & 0o022
    or (opened.st_uid == os.geteuid() and mode & 0o200)
    or mode & 0o111 == 0
    or opened.st_size <= 0
    or opened.st_size > 128 * 1024 * 1024
):
    raise SystemExit(126)
data = bytearray()
while len(data) <= 128 * 1024 * 1024:
    if interrupted is not None or time.monotonic() >= deadline:
        relay_interruption()
        raise SystemExit(124)
    chunk = os.read(executable_fd, 65536)
    if not chunk:
        break
    data.extend(chunk)
after = os.stat(candidate)
if len(data) != opened.st_size or identity(opened) != identity(after):
    raise SystemExit(126)
snapshot_directory = None
snapshot_path = None
if sys.platform.startswith("linux") and hasattr(os, "memfd_create"):
    import fcntl

    snapshot_fd = os.memfd_create("odysseus-doctor-exec", os.MFD_ALLOW_SEALING)
else:
    snapshot_directory = tempfile.mkdtemp(
        prefix="odysseus-doctor-exec.", dir="/tmp"
    )
    snapshot_path = os.path.join(snapshot_directory, "executable")
    snapshot_fd = os.open(
        snapshot_path,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0),
        0o500,
    )

    def cleanup_snapshot():
        try:
            expected = os.fstat(snapshot_fd)
            scrub_fd = os.open(
                snapshot_path,
                os.O_WRONLY
                | getattr(os, "O_CLOEXEC", 0)
                | getattr(os, "O_NOFOLLOW", 0),
            )
            try:
                opened = os.fstat(scrub_fd)
                if (opened.st_dev, opened.st_ino) != (
                    expected.st_dev,
                    expected.st_ino,
                ):
                    raise OSError("snapshot name lost its bound identity")
                quarantine = (
                    f".executable.cleanup-{secrets.token_hex(16)}"
                )
                quarantine_path = os.path.join(
                    snapshot_directory, quarantine
                )
                os.rename(snapshot_path, quarantine_path)
                named = os.lstat(quarantine_path)
                if (named.st_dev, named.st_ino) != (
                    opened.st_dev,
                    opened.st_ino,
                ):
                    raise OSError("snapshot quarantine identity changed")
                os.fchmod(scrub_fd, 0)
                os.ftruncate(scrub_fd, 0)
                os.fsync(scrub_fd)
                print(
                    "WARNING: scrubbed executable quarantine retained for "
                    f"operator recovery at {quarantine_path}",
                    file=sys.stderr,
                )
            finally:
                os.close(scrub_fd)
        except OSError as error:
            print(
                "WARNING: executable snapshot cleanup was unsafe; operator "
                f"recovery required at {snapshot_directory}: {error}",
                file=sys.stderr,
            )

    atexit.register(cleanup_snapshot)
view = memoryview(data)
while view:
    written = os.write(snapshot_fd, view)
    if written <= 0:
        raise SystemExit(126)
    view = view[written:]
os.fchmod(snapshot_fd, 0o500)
os.fsync(snapshot_fd)
if sys.platform.startswith("linux") and hasattr(os, "memfd_create"):
    seals = (
        fcntl.F_SEAL_WRITE
        | fcntl.F_SEAL_SHRINK
        | fcntl.F_SEAL_GROW
        | fcntl.F_SEAL_SEAL
    )
    fcntl.fcntl(snapshot_fd, fcntl.F_ADD_SEALS, seals)
    if fcntl.fcntl(snapshot_fd, fcntl.F_GET_SEALS) & seals != seals:
        raise SystemExit(126)
else:
    os.close(snapshot_fd)
    snapshot_fd = os.open(
        snapshot_path,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
    )
os.close(executable_fd)
os.set_inheritable(snapshot_fd, True)
inherited_fds = tuple(sorted(set((*inherited_fds, snapshot_fd))))
argv = [
    f"/dev/fd/{snapshot_fd}"
    if sys.platform.startswith("linux")
    else snapshot_path,
    *argv[1:],
]

preexec_fn = None
if not sys.platform.startswith("linux"):
    if not hasattr(resource, "RLIMIT_NPROC") or os.geteuid() == 0:
        raise SystemExit(126)

    def deny_descendant_creation():
        resource.setrlimit(resource.RLIMIT_NPROC, (0, 0))

    preexec_fn = deny_descendant_creation

proc_fd = -1
if sys.platform.startswith("linux"):
    proc_flags = os.O_RDONLY \
        | getattr(os, "O_CLOEXEC", 0) \
        | getattr(os, "O_DIRECTORY", 0) \
        | getattr(os, "O_NOFOLLOW", 0)
    try:
        proc_fd = os.open("/proc", proc_flags)
    except OSError:
        raise SystemExit(126)
    proc_metadata = os.fstat(proc_fd)
    if not stat.S_ISDIR(proc_metadata.st_mode):
        raise SystemExit(126)


def descendant_processes():
    if not sys.platform.startswith("linux"):
        return ()
    if proc_fd < 0:
        raise RuntimeError("proc containment descriptor is unavailable")
    parents = {}
    with os.scandir(proc_fd) as entries:
        for entry in entries:
            if not entry.name.isdecimal():
                continue
            descriptor = -1
            try:
                descriptor = os.open(
                    f"{entry.name}/stat",
                    os.O_RDONLY
                    | getattr(os, "O_CLOEXEC", 0)
                    | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=proc_fd,
                )
                record = os.read(descriptor, 8192).decode("ascii")
                if os.read(descriptor, 1):
                    raise RuntimeError("oversized proc stat record")
                fields = record[record.rfind(")") + 2 :].split()
                if len(fields) > 1:
                    parents[int(entry.name)] = int(fields[1])
            except FileNotFoundError:
                continue
            except (PermissionError, UnicodeError, ValueError, OSError):
                continue
            finally:
                if descriptor >= 0:
                    os.close(descriptor)
    if os.getpid() not in parents:
        raise RuntimeError("proc inventory omitted the boundary process")
    descendants = set()
    frontier = {os.getpid()}
    while frontier:
        discovered = {
            child for child, parent in parents.items()
            if parent in frontier and child not in descendants
        }
        descendants.update(discovered)
        frontier = discovered
    return tuple(descendants)


def preflight_effect_containment():
    # Exercise the same descriptor-bound /proc inventory that post-launch
    # extinction uses. A setsid, double-forked probe must be reparented to this
    # subreaper, discovered as a descendant, killed, and reaped before any
    # caller-authorized effect is allowed to launch.
    descendant_processes()
    read_fd, write_fd = os.pipe()
    probe_pid = None
    first_pid = os.fork()
    if first_pid == 0:
        try:
            os.close(read_fd)
            os.setsid()
            second_pid = os.fork()
            if second_pid != 0:
                os._exit(0)
            os.write(write_fd, str(os.getpid()).encode("ascii"))
            os.close(write_fd)
            while True:
                signal.pause()
        except BaseException:
            os._exit(127)
    os.close(write_fd)
    selector = selectors.DefaultSelector()
    selector.register(read_fd, selectors.EVENT_READ)
    try:
        try:
            os.waitpid(first_pid, 0)
        except ChildProcessError:
            raise RuntimeError("containment probe parent was not reaped")
        events = selector.select(0.5)
        if not events:
            raise RuntimeError("containment probe did not publish its identity")
        payload = os.read(read_fd, 64)
        if not payload.isdigit():
            raise RuntimeError("containment probe identity is malformed")
        probe_pid = int(payload)
        discovery_deadline = time.monotonic() + 0.5
        while probe_pid not in descendant_processes():
            if time.monotonic() >= discovery_deadline:
                raise RuntimeError("proc inventory omitted an escaped descendant")
            time.sleep(0.01)
    finally:
        selector.close()
        os.close(read_fd)
        # The first child becomes the session and process-group leader before
        # forking the probe. Its numeric group remains valid after that leader
        # exits, so this known, supervisor-created boundary is the only safe
        # fallback when /proc fails before the grandchild identity is read.
        try:
            os.killpg(first_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        if probe_pid is not None:
            try:
                os.kill(probe_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        reap_deadline = time.monotonic() + 0.5
        while True:
            try:
                child, _ = os.waitpid(-1, os.WNOHANG)
            except ChildProcessError:
                break
            if child == 0:
                if time.monotonic() >= reap_deadline:
                    raise RuntimeError("containment probe did not become extinct")
                time.sleep(0.01)
                continue


if environment_policy == "effect":
    try:
        preflight_effect_containment()
    except (OSError, RuntimeError):
        if interrupted is not None:
            relay_interruption()
        raise SystemExit(126)
if interrupted is not None:
    relay_interruption()
if time.monotonic() >= deadline:
    raise SystemExit(124)

process = subprocess.Popen(
    argv,
    stdin=None if environment_policy == "read-stdin" else subprocess.DEVNULL,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    close_fds=True,
    pass_fds=(snapshot_fd,),
    env=environment,
    preexec_fn=preexec_fn,
)
assert process.stdout is not None
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
output = bytearray()
failure = None
pipe_closed = False


def group_exists():
    try:
        os.killpg(process.pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def signal_group(signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


def reap_children():
    while True:
        try:
            child, _status = os.waitpid(-1, os.WNOHANG)
        except ChildProcessError:
            return
        if child == 0:
            return


def extinguish_descendants():
    deadline = time.monotonic() + 0.5
    while True:
        reap_children()
        children = descendant_processes()
        if not children:
            return True
        for child in children:
            try:
                os.kill(child, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if time.monotonic() >= deadline:
            return False
        time.sleep(0.01)


while True:
    now = time.monotonic()
    if interrupted is not None:
        failure = "interrupted"
        break
    if now >= deadline:
        failure = "timeout"
        break
    for key, _mask in selector.select(min(0.05, deadline - now)):
        chunk = os.read(key.fd, min(65536, maximum - len(output) + 1))
        if chunk:
            output.extend(chunk)
            if len(output) > maximum:
                failure = "overflow"
                break
        else:
            pipe_closed = True
            selector.unregister(process.stdout)
    if failure is not None:
        break
    returncode = process.poll()
    if returncode is not None and pipe_closed:
        if group_exists():
            failure = "descendant"
        break

if failure is not None:
    signal_group(signal.SIGTERM)
    grace_deadline = time.monotonic() + 0.2
    while group_exists() and time.monotonic() < grace_deadline:
        time.sleep(0.01)
    if group_exists():
        signal_group(signal.SIGKILL)
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        signal_group(signal.SIGKILL)
        process.wait(timeout=0.5)
    if not extinguish_descendants():
        raise SystemExit(126)
    if interrupted is not None:
        relay_interruption()
    raise SystemExit(125 if failure == "overflow" else 124)

if not extinguish_descendants():
    raise SystemExit(126)

if output:
    os.write(sys.stdout.fileno(), output)
raise SystemExit(process.returncode)
' "$environment_policy" "$timeout_seconds" "$maximum_bytes" \
            "$inherited_fds" "$@"
    status=$?
    return "$status"
}

run_bounded_command() {
    local status
    BOUNDED_OUTPUT=$(_run_bounded_process read "$@")
    status=$?
    return "$status"
}

run_bounded_command_with_stdin() {
    local status
    BOUNDED_OUTPUT=$(_run_bounded_process read-stdin "$@")
    status=$?
    return "$status"
}

run_bounded_command_with_fds() {
    local extra_fds=$1 previous_fds=$BOUNDARY_EXTRA_FDS status
    shift
    BOUNDARY_EXTRA_FDS=$extra_fds
    run_bounded_command "$@"
    status=$?
    BOUNDARY_EXTRA_FDS=$previous_fds
    return "$status"
}

run_bounded_command_stream_with_fds() {
    local extra_fds=$1 previous_fds=$BOUNDARY_EXTRA_FDS status
    shift
    BOUNDARY_EXTRA_FDS=$extra_fds
    _run_bounded_process read "$@"
    status=$?
    BOUNDARY_EXTRA_FDS=$previous_fds
    return "$status"
}

run_bounded_curl() {
    local previous_fds=$BOUNDARY_EXTRA_FDS status
    BOUNDARY_EXTRA_FDS=$CURL_FD
    BOUNDED_OUTPUT=$(_run_bounded_process curl "$1" "$2" \
        "$CURL_BIN" -q "${@:3}")
    status=$?
    BOUNDARY_EXTRA_FDS=$previous_fds
    return "$status"
}

run_bounded_curl_stream() {
    local previous_fds=$BOUNDARY_EXTRA_FDS status
    BOUNDARY_EXTRA_FDS=$CURL_FD
    _run_bounded_process curl "$1" "$2" \
        "$CURL_BIN" -q "${@:3}"
    status=$?
    BOUNDARY_EXTRA_FDS=$previous_fds
    return "$status"
}

run_bounded_effect() {
    local status
    [[ "$BOUNDARY_PLATFORM" == linux ]] || return 126
    BOUNDED_OUTPUT=$(_run_bounded_process effect "$@")
    status=$?
    return "$status"
}

run_bounded_effect_with_fds() {
    local extra_fds=$1 previous_fds=$BOUNDARY_EXTRA_FDS status
    shift
    BOUNDARY_EXTRA_FDS=$extra_fds
    run_bounded_effect "$@"
    status=$?
    BOUNDARY_EXTRA_FDS=$previous_fds
    return "$status"
}

# Run a version command and return a parseable version only when the command
# itself succeeds. Presence alone is not evidence that a tool is usable.
get_version() {
    local output first_line version
    if ! run_bounded_command "$VERSION_TIMEOUT_SECONDS" \
        "$VERSION_MAX_BYTES" "$@"; then
        return 1
    fi
    output=$BOUNDED_OUTPUT
    first_line=${output%%$'\n'*}
    if ! version=$(printf '%s\n' "$first_line" \
        | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1); then
        return 1
    fi
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

get_version_with_fds() {
    local descriptors=$1 output first_line version
    shift
    if ! run_bounded_command_with_fds "$descriptors" \
        "$VERSION_TIMEOUT_SECONDS" "$VERSION_MAX_BYTES" "$@"; then
        return 1
    fi
    output=$BOUNDED_OUTPUT
    first_line=${output%%$'\n'*}
    if ! version=$(printf '%s\n' "$first_line" \
        | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1); then
        return 1
    fi
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

get_curl_version() {
    local output first_line version
    if ! run_bounded_curl "$VERSION_TIMEOUT_SECONDS" \
        "$VERSION_MAX_BYTES" --version; then
        return 1
    fi
    output=$BOUNDED_OUTPUT
    first_line=${output%%$'\n'*}
    if ! version=$(printf '%s\n' "$first_line" \
        | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1); then
        return 1
    fi
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

check_tool_version() {
    local label="$1" version
    shift
    if version=$(get_version "$@"); then
        check_pass "$label $version"
        return 0
    fi
    check_fail "$label — version readback failed"
    return 1
}

python3_canonicalizes_ip_literals() {
    local canonical
    if ! canonical=$(canonicalize_ip_literal '2001:0DB8:0:0:0:0:0:1'); then
        return 1
    fi
    [[ "$canonical" == '2001:db8::1' ]]
}

# `dpkg -l` can exit successfully for packages in a removed or otherwise
# incomplete state. Accept only an exact `ii` state and a nonempty version from
# the requested package row.
get_dpkg_installed_version() {
    local package="$1" output version
    if ! run_bounded_command "$LOCAL_READ_TIMEOUT_SECONDS" \
        "$LOCAL_READ_MAX_BYTES" dpkg -l "$package"; then
        return 1
    fi
    output=$BOUNDED_OUTPUT
    version=$(printf '%s\n' "$output" | awk -v package="$package" '
        $1 == "ii" && ($2 == package || index($2, package ":") == 1) \
            && NF >= 3 && $3 != "" { print $3; exit }
    ')
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

# Compare version: returns 0 if $1 >= $2
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V | head -1 | grep -qF "$2"
}

should_check_worker()  { [[ "$ROLE" == "all" || "$ROLE" == "worker" ]]; }
should_check_control() { [[ "$ROLE" == "all" || "$ROLE" == "control" ]]; }

bind_effect_executable() {
    local command_name=$1 descriptor_name=$2 path_name=$3 candidate
    candidate=$(type -P "$command_name" 2>/dev/null) || return 1
    bind_executable_snapshot "$candidate" "$descriptor_name" "$path_name"
}

remaining_deadline_seconds() {
    local deadline=$1 remaining
    remaining=$((deadline - SECONDS))
    [[ "$remaining" -gt 0 ]] || return 1
    printf '%s\n' "$remaining"
}

inspect_aardvark_pid_file() {
    local path=$1 expected_executable=${2:-}
    run_bounded_command "$LOCAL_READ_TIMEOUT_SECONDS" \
        "$LOCAL_READ_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import os
import re
import signal
import stat
import sys


def stable_file_identity(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
    )


path, expected_executable = sys.argv[1:]
before = os.lstat(path)
if (
    not stat.S_ISREG(before.st_mode)
    or before.st_uid != os.geteuid()
    or before.st_nlink != 1
    or before.st_size <= 0
    or before.st_size > 64
    or stat.S_IMODE(before.st_mode) & 0o022
):
    raise SystemExit(1)
descriptor = os.open(
    path,
    os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
)
try:
    opened = os.fstat(descriptor)
    data = os.read(descriptor, 65)
finally:
    os.close(descriptor)
after = os.lstat(path)
try:
    value = data.decode("ascii").strip()
except UnicodeDecodeError:
    raise SystemExit(1)
if (
    stable_file_identity(before) != stable_file_identity(opened)
    or stable_file_identity(opened) != stable_file_identity(after)
    or not re.fullmatch(r"[1-9][0-9]*", value)
):
    raise SystemExit(1)
pid = int(value)

if not sys.platform.startswith("linux"):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        print(f"stale|{pid}")
        raise SystemExit(0)
    except PermissionError:
        raise SystemExit(1)
    raise SystemExit(1)

if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
    raise SystemExit(1)
try:
    process_fd = os.pidfd_open(pid, 0)
except ProcessLookupError:
    print(f"stale|{pid}")
    raise SystemExit(0)
except OSError:
    raise SystemExit(1)


def pidfd_still_names_expected_process():
    try:
        with open(f"/proc/self/fdinfo/{process_fd}", encoding="ascii") as stream:
            fields = dict(
                line.rstrip("\n").split(":\t", 1)
                for line in stream
                if ":\t" in line
            )
    except OSError:
        return False
    return fields.get("Pid") == str(pid)


try:
    try:
        signal.pidfd_send_signal(process_fd, 0)
    except ProcessLookupError:
        print(f"stale|{pid}")
        raise SystemExit(0)
    if not pidfd_still_names_expected_process():
        raise SystemExit(1)
    try:
        with open(f"/proc/{pid}/status", encoding="ascii") as stream:
            status_lines = stream.read(65536).splitlines()
        uid_line = next(line for line in status_lines if line.startswith("Uid:"))
        uids = uid_line.split()[1:]
        with open(f"/proc/{pid}/stat", encoding="ascii") as stream:
            process_stat = stream.read(8192)
    except (FileNotFoundError, PermissionError, StopIteration, OSError):
        try:
            signal.pidfd_send_signal(process_fd, 0)
        except ProcessLookupError:
            print(f"stale|{pid}")
            raise SystemExit(0)
        raise SystemExit(1)
    if not expected_executable or not os.path.isabs(expected_executable):
        raise SystemExit(1)
    try:
        expected_before = os.lstat(expected_executable)
        expected_fd = os.open(
            expected_executable,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
        )
    except OSError:
        raise SystemExit(1)
    try:
        expected_opened = os.fstat(expected_fd)
        expected_after = os.lstat(expected_executable)
        expected_mode = stat.S_IMODE(expected_opened.st_mode)
        if (
            stable_file_identity(expected_before)
            != stable_file_identity(expected_opened)
            or stable_file_identity(expected_opened)
            != stable_file_identity(expected_after)
            or not stat.S_ISREG(expected_opened.st_mode)
            or expected_opened.st_uid not in (0, os.geteuid())
            or expected_mode & 0o022
            or (expected_opened.st_uid == os.geteuid() and expected_mode & 0o200)
            or expected_mode & 0o111 == 0
            or expected_opened.st_size <= 0
            or expected_opened.st_size > 128 * 1024 * 1024
        ):
            raise SystemExit(1)
        try:
            process_executable_fd = os.open(
                f"/proc/{pid}/exe",
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0),
            )
        except OSError:
            raise SystemExit(1)
        try:
            process_executable = os.fstat(process_executable_fd)
            if (process_executable.st_dev, process_executable.st_ino) != (
                expected_opened.st_dev,
                expected_opened.st_ino,
            ):
                raise SystemExit(1)
        finally:
            os.close(process_executable_fd)
        if stable_file_identity(os.lstat(expected_executable)) \
                != stable_file_identity(expected_opened):
            raise SystemExit(1)
    finally:
        os.close(expected_fd)
    fields = process_stat[process_stat.rfind(")") + 2 :].split()
    if (
        len(uids) != 4
        or any(not uid.isdigit() for uid in uids)
        or int(uids[0]) != os.geteuid()
        or len(fields) <= 19
        or not fields[19].isdigit()
    ):
        raise SystemExit(1)
    signal.pidfd_send_signal(process_fd, 0)
    if not pidfd_still_names_expected_process():
        raise SystemExit(1)
    print(f"live|{pid}|{fields[19]}")
finally:
    os.close(process_fd)
' "$path" "$expected_executable" || return
    printf '%s\n' "$BOUNDED_OUTPUT"
}

clear_bound_stale_pid_file() {
    local path=$1 expected_pid=$2 status
    run_bounded_effect "$REPAIR_TIMEOUT_SECONDS" "$REPAIR_MAX_BYTES" \
        "$PYTHON3_BIN" -I -S -c '
import os
import secrets
import stat
import sys

path, expected = sys.argv[1:]
parent_path, name = os.path.split(path)
if not parent_path or name != "aardvark.pid":
    raise SystemExit(1)
parent = os.open(
    parent_path,
    os.O_RDONLY
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_DIRECTORY", 0)
    | getattr(os, "O_NOFOLLOW", 0),
)
try:
    parent_info = os.fstat(parent)
    if (
        not stat.S_ISDIR(parent_info.st_mode)
        or parent_info.st_uid != os.geteuid()
        or stat.S_IMODE(parent_info.st_mode) & 0o022
    ):
        raise SystemExit(1)
    before = os.stat(name, dir_fd=parent, follow_symlinks=False)
    if (
        not stat.S_ISREG(before.st_mode)
        or before.st_uid != os.geteuid()
        or before.st_nlink != 1
        or before.st_size <= 0
        or before.st_size > 64
        or stat.S_IMODE(before.st_mode) & 0o022
    ):
        raise SystemExit(1)
    descriptor = os.open(
        name,
        os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
        dir_fd=parent,
    )
    try:
        opened = os.fstat(descriptor)
        data = os.read(descriptor, 65)
    finally:
        os.close(descriptor)
    after = os.stat(name, dir_fd=parent, follow_symlinks=False)
    identity = lambda value: (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
    )
    if (
        identity(before) != identity(opened)
        or identity(opened) != identity(after)
        or data.decode("ascii").strip() != expected
    ):
        raise SystemExit(1)
    quarantine = f".{name}.cleanup-{secrets.token_hex(16)}"
    try:
        os.stat(quarantine, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        raise SystemExit(1)
    os.rename(name, quarantine, src_dir_fd=parent, dst_dir_fd=parent)
    recovery_path = os.path.join(parent_path, quarantine)
    try:
        quarantine_fd = os.open(
            quarantine,
            os.O_RDONLY
            | getattr(os, "O_CLOEXEC", 0)
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent,
        )
    except OSError as error:
        print(
            "ERROR: stale aardvark PID quarantine retained for operator "
            f"recovery at {recovery_path}: {error}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    try:
        quarantined = os.fstat(quarantine_fd)
        if identity(quarantined) != identity(opened):
            print(
                "ERROR: aardvark PID replacement retained for operator "
                f"recovery at {recovery_path}",
                file=sys.stderr,
            )
            raise SystemExit(1)
    finally:
        os.close(quarantine_fd)
    try:
        os.stat(name, dir_fd=parent, follow_symlinks=False)
    except FileNotFoundError:
        pass
    else:
        print(
            "ERROR: same-name aardvark PID replacement preserved; "
            f"bound evidence retained for operator recovery at "
            f"{recovery_path}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    print(
        "ERROR: exact inode-bound deletion is unavailable; stale aardvark "
        f"PID evidence retained for operator recovery at "
        f"{recovery_path}",
        file=sys.stderr,
    )
    raise SystemExit(1)
finally:
    os.close(parent)
' "$path" "$expected_pid"
    status=$?
    if [[ "$status" -ne 0 && -n "$BOUNDED_OUTPUT" ]]; then
        printf '%s\n' "$BOUNDED_OUTPUT" >&2
    fi
    return "$status"
}

# Execute read-only Git diagnosis with repository/configuration routing
# detached from the caller. Doctor never grants this path update authority.
doctor_git() {
    local previous_git_mode=$BOUNDARY_GIT_MODE status
    local -a command
    [[ -n "$GIT_BIN" ]] || return 127
    command=(
        "$GIT_BIN"
        -c core.attributesFile=/dev/null
        -c core.fsmonitor=false
        -c core.hooksPath=/dev/null
        -c credential.helper=
        -c credential.interactive=false
        -c protocol.allow=never
        -c protocol.https.allow=always
        -c protocol.file.allow=never
        -c protocol.ext.allow=never
        -c protocol.git.allow=never
        -c protocol.ssh.allow=never
        -c http.sslVerify=true
        -c http.sslCAInfo=
        -c http.sslCAPath=
        -c http.curloptResolve=
        -c http.proxy=
        -c http.extraHeader=
        "$@"
    )
    BOUNDARY_GIT_MODE=true
    run_bounded_command "$LOCAL_READ_TIMEOUT_SECONDS" \
        "$LOCAL_READ_MAX_BYTES" "${command[@]}"
    status=$?
    BOUNDARY_GIT_MODE=$previous_git_mode
    [[ "$status" -eq 0 ]] || return "$status"
    printf '%s' "$BOUNDED_OUTPUT"
}

SUBMODULE_POLICY_ERROR=""
EXPECTED_SUBMODULES=""
EXPECTED_SUBMODULE_URLS=""
EXPECTED_TOTAL=0

load_submodule_declarations() {
    local key path extra name url expected_url url_count seen_paths=""
    SUBMODULE_POLICY_ERROR=""
    if ! submodule_manifest_is_safe; then
        SUBMODULE_POLICY_ERROR=".gitmodules identity or permissions changed"
        return 1
    fi
    if ! EXPECTED_SUBMODULES=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.path$' 2>/dev/null); then
        SUBMODULE_POLICY_ERROR="cannot read .gitmodules paths"
        return 1
    fi
    if ! EXPECTED_SUBMODULE_URLS=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.url$' 2>/dev/null); then
        SUBMODULE_POLICY_ERROR="cannot read .gitmodules URLs"
        return 1
    fi

    EXPECTED_TOTAL=0
    while read -r key path extra; do
        [[ -n "$key" && -n "$path" && -z "$extra" \
            && "$key" == submodule.*.path \
            && "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ \
            && "$path" != *'/.' && "$path" != *'/..' ]] || {
            SUBMODULE_POLICY_ERROR="unsafe submodule path declaration"
            return 1
        }
        name=${key#submodule.}
        name=${name%.path}
        [[ "$name" == "$path" ]] || {
            SUBMODULE_POLICY_ERROR="submodule name/path binding mismatch"
            return 1
        }
        if printf '%s\n' "$seen_paths" | grep -qxF "$path"; then
            SUBMODULE_POLICY_ERROR="duplicate submodule path declaration"
            return 1
        fi
        seen_paths="${seen_paths}${path}"$'\n'

        url_count=$(printf '%s\n' "$EXPECTED_SUBMODULE_URLS" \
            | awk -v wanted="submodule.${name}.url" '$1 == wanted { count++ } END { print count+0 }')
        [[ "$url_count" -eq 1 ]] || {
            SUBMODULE_POLICY_ERROR="missing or duplicate submodule URL binding"
            return 1
        }
        url=$(printf '%s\n' "$EXPECTED_SUBMODULE_URLS" \
            | awk -v wanted="submodule.${name}.url" '$1 == wanted { print $2; exit }')
        expected_url="https://github.com/HomericIntelligence/${path##*/}.git"
        [[ "$url" == "$expected_url" ]] || {
            SUBMODULE_POLICY_ERROR="non-canonical submodule URL"
            return 1
        }
        EXPECTED_TOTAL=$((EXPECTED_TOTAL + 1))
    done <<< "$EXPECTED_SUBMODULES"

    [[ "$EXPECTED_TOTAL" -gt 0 ]] || {
        SUBMODULE_POLICY_ERROR="empty submodule declaration inventory"
        return 1
    }
    url_count=$(printf '%s\n' "$EXPECTED_SUBMODULE_URLS" \
        | awk 'NF { count++ } END { print count+0 }')
    [[ "$url_count" -eq "$EXPECTED_TOTAL" ]] || {
        SUBMODULE_POLICY_ERROR="submodule path/URL inventory mismatch"
        return 1
    }
    if ! submodule_manifest_is_safe; then
        SUBMODULE_POLICY_ERROR=".gitmodules identity or permissions changed"
        return 1
    fi
}

submodule_config_has_forbidden_policy() {
    local output status scope=$1
    local forbidden='^(include(\..*)?\.path|submodule\..*\.update|url\..*\.(insteadOf|pushInsteadOf)|protocol\..*\.allow)$'
    if [[ "$scope" == modules ]]; then
        output=$(doctor_git -C "$ODYSSEUS_ROOT" config --no-includes \
            -f .gitmodules --get-regexp "$forbidden" 2>/dev/null)
    else
        output=$(doctor_git -C "$ODYSSEUS_ROOT" config --local --no-includes \
            --get-regexp "$forbidden" 2>/dev/null)
    fi
    status=$?
    if [[ "$status" -eq 0 ]]; then
        [[ -n "$output" ]] || return 2
        return 0
    fi
    [[ "$status" -eq 1 ]] && return 1
    return 2
}

validate_submodule_git_policy() {
    local current_paths current_urls key path extra name declared_url local_url status
    SUBMODULE_POLICY_ERROR=""
    if ! submodule_manifest_is_safe; then
        SUBMODULE_POLICY_ERROR=".gitmodules identity or permissions changed"
        return 1
    fi
    if ! current_paths=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.path$' 2>/dev/null) \
        || [[ "$current_paths" != "$EXPECTED_SUBMODULES" ]]; then
        SUBMODULE_POLICY_ERROR="submodule path declarations changed during inspection"
        return 1
    fi
    if ! current_urls=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.url$' 2>/dev/null) \
        || [[ "$current_urls" != "$EXPECTED_SUBMODULE_URLS" ]]; then
        SUBMODULE_POLICY_ERROR="submodule URL declarations changed during inspection"
        return 1
    fi
    if submodule_config_has_forbidden_policy modules; then
        SUBMODULE_POLICY_ERROR=".gitmodules contains a forbidden update or routing policy"
        return 1
    else
        status=$?
        [[ "$status" -eq 1 ]] || {
            SUBMODULE_POLICY_ERROR="cannot validate .gitmodules update/routing policy"
            return 1
        }
    fi
    if submodule_config_has_forbidden_policy local; then
        SUBMODULE_POLICY_ERROR="local Git config contains a forbidden update or routing policy"
        return 1
    else
        status=$?
        [[ "$status" -eq 1 ]] || {
            SUBMODULE_POLICY_ERROR="cannot validate local Git update/routing policy"
            return 1
        }
    fi

    while read -r key path extra; do
        name=${key#submodule.}
        name=${name%.path}
        declared_url="https://github.com/HomericIntelligence/${path##*/}.git"
        local_url=$(doctor_git -C "$ODYSSEUS_ROOT" config --local \
            --no-includes --get "submodule.${name}.url" 2>/dev/null)
        status=$?
        if [[ "$status" -eq 0 ]]; then
            [[ "$local_url" == "$declared_url" ]] || {
                SUBMODULE_POLICY_ERROR="local submodule URL override does not match its declaration"
                return 1
            }
        elif [[ "$status" -ne 1 ]]; then
            SUBMODULE_POLICY_ERROR="cannot validate local submodule URL override"
            return 1
        fi
    done <<< "$EXPECTED_SUBMODULES"
    if ! submodule_manifest_is_safe; then
        SUBMODULE_POLICY_ERROR=".gitmodules identity or permissions changed"
        return 1
    fi
}

submodule_manifest_is_safe() {
    local manifest="$ODYSSEUS_ROOT/.gitmodules"
    run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import os
import stat
import sys

path = sys.argv[1]
before = os.lstat(path)
if (
    not stat.S_ISREG(before.st_mode)
    or before.st_uid != os.geteuid()
    or stat.S_IMODE(before.st_mode) & 0o022
    or before.st_nlink != 1
    or before.st_size <= 0
    or before.st_size > 1024 * 1024
):
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
descriptor = os.open(path, flags)
try:
    opened = os.fstat(descriptor)
finally:
    os.close(descriptor)
after = os.lstat(path)
identity = lambda value: (
    value.st_dev,
    value.st_ino,
    value.st_mode,
    value.st_uid,
    value.st_nlink,
    value.st_size,
    value.st_mtime_ns,
)
if identity(before) != identity(opened) or identity(opened) != identity(after):
    raise SystemExit(1)
' "$manifest" >/dev/null
}

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}HomericIntelligence Doctor — E2E Pipeline Prerequisites${NC}"
echo "═══════════════════════════════════════════════════════"
echo -e "  Role: ${CYAN}${ROLE}${NC}    Safe repair: ${CYAN}${INSTALL}${NC}    Cross-host: ${CYAN}${CROSS_HOST}${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# Section 1: Core Tooling (all hosts)
# Required by: Odysseus meta-repo, E2E scripts, Myrmidons provisioning
# ═════════════════════════════════════════════════════════════════════════════
section "Core Tooling"

# python3 is the sole prerequisite for peer target canonicalization. Verify it
# before the target boundary, then keep every unrelated tool, repair, and
# network effect behind that boundary.
PYTHON3_VERSION=""
PYTHON3_FAILURE="missing"
if resolve_python3; then
    if ! PYTHON3_VERSION=$(get_version "$PYTHON3_BIN" -I -S --version); then
        PYTHON3_FAILURE="version"
    elif python3_canonicalizes_ip_literals; then
        check_pass "python3 $PYTHON3_VERSION"
        PYTHON3_READY=true
    else
        PYTHON3_FAILURE="canonicalization"
    fi
fi
if ! $PYTHON3_READY; then
    if $INSTALL; then
        case "$PYTHON3_FAILURE" in
            missing)
                check_fail "python3 — not installed; pre-provision a verified python3 executable"
                ;;
            version)
                check_fail "python3 — version readback failed; pre-provision a verified python3 executable"
                ;;
            canonicalization)
                check_fail "python3 — IP literal canonicalization unavailable; pre-provision a verified python3 executable"
                ;;
        esac
    else
        case "$PYTHON3_FAILURE" in
            missing)
                check_fail "python3 — NOT FOUND (required prerequisite)"
                ;;
            version)
                check_fail "python3 — version readback failed"
                ;;
            canonicalization)
                check_fail "python3 — IP literal canonicalization unavailable"
                ;;
        esac
    fi
fi

# Relationship errors were rejected before inspection. Literal validation now
# follows only the verified Python prerequisite check and still precedes every
# unrelated inspection, repair, topology, and network effect.
if [[ -n "$WORKER_IP" || -n "$CONTROL_IP" ]]; then
    if ! $PYTHON3_READY; then
        echo "ERROR: peer target validation requires a working python3 prerequisite" >&2
        exit 1
    fi
    if [[ -n "$WORKER_IP" ]] \
        && ! WORKER_IP=$(canonicalize_ip_literal "$WORKER_IP"); then
        echo "ERROR: peer targets must be literal IP addresses" >&2
        exit 1
    fi
    if [[ -n "$CONTROL_IP" ]] \
        && ! CONTROL_IP=$(canonicalize_ip_literal "$CONTROL_IP"); then
        echo "ERROR: peer targets must be literal IP addresses" >&2
        exit 1
    fi
fi

# git
if resolve_git; then
    if ! check_tool_version git "$GIT_BIN" --version; then :; fi
else
    if $INSTALL; then
        check_fail "git — not installed; pre-provision a verified git executable"
    else
        check_fail "git — NOT FOUND"
    fi
fi

# just
if has_cmd just; then
    if ! check_tool_version just just --version; then :; fi
else
    if $INSTALL; then
        check_fail "just — not installed; pre-provision a verified just executable"
    else
        check_fail "just — NOT FOUND"
    fi
fi

# pip3
if has_cmd pip3; then
    if ! check_tool_version pip3 pip3 --version; then :; fi
else
    if $INSTALL; then
        check_fail "pip3 — not installed; pre-provision a verified pip3 executable"
    else
        check_fail "pip3 — NOT FOUND"
    fi
fi

# curl
if resolve_curl; then
    if CURL_VERSION=$(get_curl_version); then
        check_pass "curl $CURL_VERSION"
    else
        check_fail "curl — version readback failed"
    fi
else
    if $INSTALL; then
        check_fail "curl — not installed; pre-provision a verified curl executable"
    else
        check_fail "curl — NOT FOUND"
    fi
fi

# jq
if has_cmd jq; then
    if ! check_tool_version jq jq --version; then :; fi
else
    if $INSTALL; then
        check_fail "jq — not installed; pre-provision a verified jq executable"
    else
        check_fail "jq — NOT FOUND"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 2: Tailscale (Network Topology — all hosts)
# Required by: Cross-host NATS, Agamemnon/Nestor communication over mesh
# ═════════════════════════════════════════════════════════════════════════════
if $CROSS_HOST; then
section "Tailscale (Network Topology)"

if has_cmd tailscale; then
    if ! check_tool_version tailscale tailscale --version; then :; fi
else
    if $INSTALL; then
        check_fail "tailscale — not installed; pre-provision a verified package (see https://tailscale.com/download)"
    else
        check_fail "tailscale — NOT FOUND"
    fi
fi

# Capture one parseable live topology snapshot. A successful status exit alone
# is not peer identity or topology evidence.
if has_cmd tailscale; then
    if run_bounded_command "$TAILSCALE_TIMEOUT_SECONDS" \
        "$TAILSCALE_MAX_BYTES" tailscale status --json; then
        TAILSCALE_STATUS_JSON=$BOUNDED_OUTPUT
    else
        TAILSCALE_STATUS_JSON=""
    fi
    if [[ -n "$TAILSCALE_STATUS_JSON" ]] \
        && printf '%s\n' "$TAILSCALE_STATUS_JSON" | valid_tailscale_status; then
        TAILSCALE_STATUS_AVAILABLE=true
        check_pass "tailscaled running"
    else
        if $INSTALL; then
            TAILSCALE_REPAIR_DEADLINE=$((SECONDS + REPAIR_TIMEOUT_SECONDS))
            TAILSCALE_REPAIR_STATUS=1
            if [[ "$BOUNDARY_PLATFORM" != linux ]]; then
                TAILSCALE_REPAIR_STATUS=126
            elif ! bind_effect_executable systemctl \
                TAILSCALE_SYSTEMCTL_FD TAILSCALE_SYSTEMCTL_BIN; then
                TAILSCALE_REPAIR_STATUS=127
            elif TAILSCALE_REMAINING=$(remaining_deadline_seconds \
                "$TAILSCALE_REPAIR_DEADLINE") \
                && run_bounded_effect_with_fds "$TAILSCALE_SYSTEMCTL_FD" \
                    "$TAILSCALE_REMAINING" "$REPAIR_MAX_BYTES" \
                    "$TAILSCALE_SYSTEMCTL_BIN" start tailscaled; then
                TAILSCALE_REPAIR_STATUS=0
            else
                TAILSCALE_REPAIR_STATUS=$?
            fi
            if [[ -n "${TAILSCALE_SYSTEMCTL_FD:-}" ]]; then
                close_bound_descriptor "$TAILSCALE_SYSTEMCTL_FD"
                TAILSCALE_SYSTEMCTL_FD=""
            fi
            if [[ "$TAILSCALE_REPAIR_STATUS" -eq 0 ]] \
                && TAILSCALE_REMAINING=$(remaining_deadline_seconds \
                    "$TAILSCALE_REPAIR_DEADLINE") \
                && run_bounded_command "$TAILSCALE_REMAINING" \
                    "$TAILSCALE_MAX_BYTES" tailscale status --json; then
                TAILSCALE_STATUS_JSON=$BOUNDED_OUTPUT
            else
                TAILSCALE_STATUS_JSON=""
            fi
            if [[ -n "$TAILSCALE_STATUS_JSON" ]] \
                && printf '%s\n' "$TAILSCALE_STATUS_JSON" \
                    | valid_tailscale_status; then
                TAILSCALE_STATUS_AVAILABLE=true
                check_pass "tailscaled running after start"
            else
                check_fail "tailscaled — start or post-start readback failed"
            fi
        else
            check_fail "tailscaled not running"
        fi
    fi
fi

# Firewall readiness is deployment-specific. Whole-interface trust is neither
# inspected as proof nor mutated here; bind exact listeners, peers, and current
# policy in an operator-owned deployment procedure.
if should_check_worker; then
    check_skip "firewall readiness requires an exact deployment-owned listener/peer policy"
fi

# Check peer reachability (if IPs provided)
if [[ -n "$WORKER_IP" ]]; then
    if $TAILSCALE_STATUS_AVAILABLE \
        && printf '%s\n' "$TAILSCALE_STATUS_JSON" \
            | is_online_tailscale_peer "$WORKER_IP"; then
        WORKER_PEER_VERIFIED=true
        check_pass "Worker host ($WORKER_IP) is an online Tailscale peer"
    else
        check_fail "Worker host ($WORKER_IP) is not an online Tailscale peer"
    fi
    if $WORKER_PEER_VERIFIED; then
        if run_bounded_command "$TAILSCALE_TIMEOUT_SECONDS" \
            "$TAILSCALE_MAX_BYTES" ping -c1 -W3 "$WORKER_IP"; then
            check_pass "Worker host ($WORKER_IP) reachable"
        else
            check_fail "Worker host ($WORKER_IP) NOT reachable"
        fi
    fi
fi
if [[ -n "$CONTROL_IP" ]]; then
    if $TAILSCALE_STATUS_AVAILABLE \
        && printf '%s\n' "$TAILSCALE_STATUS_JSON" \
            | is_online_tailscale_peer "$CONTROL_IP"; then
        CONTROL_PEER_VERIFIED=true
        check_pass "Control host ($CONTROL_IP) is an online Tailscale peer"
    else
        check_fail "Control host ($CONTROL_IP) is not an online Tailscale peer"
    fi
    if $CONTROL_PEER_VERIFIED; then
        if run_bounded_command "$TAILSCALE_TIMEOUT_SECONDS" \
            "$TAILSCALE_MAX_BYTES" ping -c1 -W3 "$CONTROL_IP"; then
            check_pass "Control host ($CONTROL_IP) reachable"
        else
            check_fail "Control host ($CONTROL_IP) NOT reachable"
        fi
    fi
fi
else
    section "Tailscale (Network Topology)"
    check_skip "cross-host checks not selected"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 3: Container Runtime (Worker host — AchaeanFleet / supported Compose paths)
# Required by: docker-compose.e2e.yml and component-owned container workflows
# ═════════════════════════════════════════════════════════════════════════════
if should_check_worker; then
    section "Container Runtime (AchaeanFleet)"

    # podman
    if has_cmd podman; then
        if ! check_tool_version podman podman --version; then :; fi
    else
        if $INSTALL; then
            check_fail "podman — not installed; pre-provision a verified podman executable"
        else
            check_fail "podman — NOT FOUND"
        fi
    fi

    # podman compose
    if has_cmd podman; then
        if COMPOSE_VER=$(get_version podman compose version); then
            check_pass "podman compose ${COMPOSE_VER}"
        else
            check_fail "podman compose — version readback failed"
        fi
    else
        if $INSTALL; then
            check_fail "podman compose — unavailable; pre-provision a verified podman compose provider"
        else
            check_fail "podman compose — NOT FOUND"
        fi
    fi

    # podman socket
    PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$UID}/podman/podman.sock"
    if [[ -S "$PODMAN_SOCK" ]]; then
        check_pass "podman socket active ($PODMAN_SOCK)"
    else
        if $INSTALL; then
            # Ensure XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are set —
            # SSH sessions can omit these, breaking systemctl --user.
            export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}"
            export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

            # Enabling a service is safe only when the selected Podman package
            # already owns a verifiable unit. Doctor does not synthesize host
            # service definitions from guessed source-tree paths.
            PODMAN_SOCKET_REPAIR_RESULT=boundary
            if [[ "$BOUNDARY_PLATFORM" == linux ]] \
                && bind_effect_executable systemctl \
                    PODMAN_SYSTEMCTL_FD PODMAN_SYSTEMCTL_BIN; then
                PODMAN_SOCKET_REPAIR_DEADLINE=$((SECONDS + REPAIR_TIMEOUT_SECONDS))
                if PODMAN_SOCKET_REMAINING=$(remaining_deadline_seconds \
                    "$PODMAN_SOCKET_REPAIR_DEADLINE") \
                    && run_bounded_effect_with_fds "$PODMAN_SYSTEMCTL_FD" \
                        "$PODMAN_SOCKET_REMAINING" "$REPAIR_MAX_BYTES" \
                        "$PODMAN_SYSTEMCTL_BIN" --user cat podman.socket; then
                    if PODMAN_SOCKET_REMAINING=$(remaining_deadline_seconds \
                        "$PODMAN_SOCKET_REPAIR_DEADLINE") \
                        && run_bounded_effect_with_fds \
                            "$PODMAN_SYSTEMCTL_FD" \
                            "$PODMAN_SOCKET_REMAINING" \
                            "$REPAIR_MAX_BYTES" "$PODMAN_SYSTEMCTL_BIN" \
                            --user enable --now podman.socket; then
                        PODMAN_SOCKET_REPAIR_RESULT=enabled
                    else
                        PODMAN_SOCKET_REPAIR_RESULT=enable-failed
                    fi
                else
                    PODMAN_SOCKET_REPAIR_RESULT=unit-unavailable
                fi
                close_bound_descriptor "$PODMAN_SYSTEMCTL_FD"
                PODMAN_SYSTEMCTL_FD=""
            fi

            if [[ "$PODMAN_SOCKET_REPAIR_RESULT" == enabled \
                && -S "$PODMAN_SOCK" ]]; then
                check_pass "podman socket enabled and active"
            elif [[ "$PODMAN_SOCKET_REPAIR_RESULT" == unit-unavailable ]]; then
                check_fail "packaged podman.socket unit is unavailable; stop for an operator-owned package repair"
            else
                check_fail "podman socket — repair unavailable or post-enable readback failed"
                echo -e "    ${DIM}This usually means no systemd user session is running (common over SSH).${NC}"
                echo -e "    ${DIM}Fix: run 'sudo loginctl enable-linger $USER' then reconnect,${NC}"
                echo -e "    ${DIM}or run 'systemctl --user enable --now podman.socket' from a desktop session.${NC}"
            fi
        else
            check_fail "podman socket not found"
        fi
    fi

    # aardvark-dns stale check (WSL2 specific)
    AARDVARK_PID_DIR="${XDG_RUNTIME_DIR:-/run/user/$UID}/containers/networks/aardvark-dns"
    if [[ -f "$AARDVARK_PID_DIR/aardvark.pid" ]]; then
        AARDVARK_EXPECTED_EXECUTABLE=""
        if ! AARDVARK_EXPECTED_EXECUTABLE=$(type -P aardvark-dns 2>/dev/null); then
            AARDVARK_EXPECTED_EXECUTABLE=""
        fi
        if ! AARDVARK_STATE=$(inspect_aardvark_pid_file \
            "$AARDVARK_PID_DIR/aardvark.pid" \
            "$AARDVARK_EXPECTED_EXECUTABLE" 2>/dev/null); then
            check_fail "aardvark-dns PID metadata or process identity is unavailable"
        else
            IFS='|' read -r AARDVARK_STATUS AARDVARK_PID \
                AARDVARK_START_TOKEN <<< "$AARDVARK_STATE"
            case "$AARDVARK_STATUS" in
                stale)
                    if ! [[ "$AARDVARK_PID" =~ ^[1-9][0-9]*$ ]] \
                        || [[ -n "$AARDVARK_START_TOKEN" ]]; then
                        check_fail "aardvark-dns stale PID result is malformed"
                    else
                        check_warn "aardvark-dns PID stale (PID $AARDVARK_PID not running)"
                        if $INSTALL; then
                            if clear_bound_stale_pid_file \
                                "$AARDVARK_PID_DIR/aardvark.pid" "$AARDVARK_PID"; then
                                check_pass "stale aardvark-dns PID cleared"
                            else
                                check_fail "stale aardvark-dns PID repair unavailable or failed"
                            fi
                        fi
                    fi
                    ;;
                live)
                    if [[ "$AARDVARK_PID" =~ ^[1-9][0-9]*$ \
                        && "$AARDVARK_START_TOKEN" =~ ^[1-9][0-9]*$ ]]; then
                        check_pass "aardvark-dns OK"
                    else
                        check_fail "aardvark-dns live identity result is malformed"
                    fi
                    ;;
                *)
                    check_fail "aardvark-dns PID inspection returned an unknown state"
                    ;;
            esac
        fi
    else
        check_pass "aardvark-dns no stale PID"
    fi
else
    section "Container Runtime (AchaeanFleet)"
    check_skip "Container runtime checks (role=$ROLE)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 4: C++ Build Chain (Control host — builds Nestor, Charybdis)
# Required by: just _build-nestor, just _build-agamemnon, just _build-charybdis
# ═════════════════════════════════════════════════════════════════════════════
if should_check_control; then
    section "C++ Build Chain"

    # cmake >= 3.20
    if has_cmd cmake; then
        CMAKE_VER=$(get_version cmake --version)
        if version_gte "$CMAKE_VER" "3.20"; then
            check_pass "cmake $CMAKE_VER (>= 3.20)"
        else
            check_fail "cmake $CMAKE_VER — need >= 3.20"
        fi
    else
        if $INSTALL; then
            check_fail "cmake — not installed; pre-provision a verified cmake >= 3.20 executable"
        else
            check_fail "cmake — NOT FOUND"
        fi
    fi

    # ninja
    if has_cmd ninja; then
        if ! check_tool_version ninja ninja --version; then :; fi
    else
        if $INSTALL; then
            check_fail "ninja — not installed; pre-provision a verified ninja executable"
        else
            check_fail "ninja — NOT FOUND"
        fi
    fi

    # g++ >= 11
    if has_cmd g++; then
        GPP_VER=$(get_version g++ --version)
        if version_gte "$GPP_VER" "11"; then
            check_pass "g++ $GPP_VER (>= 11)"
        else
            check_fail "g++ $GPP_VER — need >= 11 for C++20"
        fi
    else
        if $INSTALL; then
            check_fail "g++ — not installed; pre-provision a verified g++ >= 11 executable"
        else
            check_fail "g++ — NOT FOUND"
        fi
    fi

    # libssl-dev
    if LIBSSL_VER=$(get_dpkg_installed_version libssl-dev); then
        check_pass "libssl-dev $LIBSSL_VER"
    else
        if $INSTALL; then
            check_fail "libssl-dev — unavailable; pre-provision a verified libssl-dev package"
        else
            check_fail "libssl-dev — NOT FOUND or package state/version check failed"
        fi
    fi

    # make (needed for gtest CMake recipe)
    if has_cmd make; then
        if ! check_tool_version make make --version; then :; fi
    else
        if $INSTALL; then
            check_fail "make — not installed; pre-provision a verified make executable"
        else
            check_fail "make — NOT FOUND"
        fi
    fi

    # conan >= 2.0
    if has_cmd conan; then
        CONAN_VER=$(get_version conan --version)
        if version_gte "$CONAN_VER" "2.0"; then
            check_pass "conan $CONAN_VER (>= 2.0)"
        else
            check_fail "conan $CONAN_VER — need >= 2.0"
        fi
    else
        if $INSTALL; then
            check_fail "conan — not installed; pre-provision a verified Conan 2 package"
        else
            check_fail "conan — NOT FOUND"
        fi
    fi

    # Conan default profile
    if has_cmd conan; then
        CONAN_PROFILE_PRESENT=false
        CONAN_REPAIR_AVAILABLE=false
        if $INSTALL && [[ "$BOUNDARY_PLATFORM" == linux ]] \
            && bind_effect_executable conan CONAN_REPAIR_FD CONAN_REPAIR_BIN; then
            CONAN_REPAIR_AVAILABLE=true
            CONAN_REPAIR_DEADLINE=$((SECONDS + REPAIR_TIMEOUT_SECONDS))
            if CONAN_REMAINING=$(remaining_deadline_seconds \
                "$CONAN_REPAIR_DEADLINE") \
                && run_bounded_command_with_fds "$CONAN_REPAIR_FD" \
                    "$CONAN_REMAINING" "$REPAIR_MAX_BYTES" \
                    "$CONAN_REPAIR_BIN" profile show; then
                CONAN_PROFILE_PRESENT=true
            fi
        elif run_bounded_command "$LOCAL_READ_TIMEOUT_SECONDS" \
            "$LOCAL_READ_MAX_BYTES" conan profile show; then
            CONAN_PROFILE_PRESENT=true
        fi

        if $CONAN_PROFILE_PRESENT; then
            check_pass "Conan default profile exists"
        elif $INSTALL; then
            if $CONAN_REPAIR_AVAILABLE \
                && CONAN_REMAINING=$(remaining_deadline_seconds \
                    "$CONAN_REPAIR_DEADLINE") \
                && run_bounded_effect_with_fds "$CONAN_REPAIR_FD" \
                    "$CONAN_REMAINING" "$REPAIR_MAX_BYTES" \
                    "$CONAN_REPAIR_BIN" profile detect --force \
                && CONAN_REMAINING=$(remaining_deadline_seconds \
                    "$CONAN_REPAIR_DEADLINE") \
                && run_bounded_command_with_fds "$CONAN_REPAIR_FD" \
                    "$CONAN_REMAINING" "$REPAIR_MAX_BYTES" \
                    "$CONAN_REPAIR_BIN" profile show; then
                check_pass "Conan default profile created and verified"
            else
                check_fail "Conan profile repair unavailable or readback failed"
            fi
        else
            check_fail "Conan default profile missing"
        fi
        if [[ -n "${CONAN_REPAIR_FD:-}" ]]; then
            close_bound_descriptor "$CONAN_REPAIR_FD"
            CONAN_REPAIR_FD=""
        fi
    fi

    # pixi
    if has_cmd pixi; then
        if ! check_tool_version pixi pixi --version; then :; fi
    else
        if $INSTALL; then
            check_fail "pixi — not installed; pre-provision a verified pixi executable (see https://pixi.sh)"
        else
            check_fail "pixi — NOT FOUND"
        fi
    fi
else
    section "C++ Build Chain"
    check_skip "C++ build chain checks (role=$ROLE)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 5: Python Dependencies (NATS observability bridge)
# Required by: e2e/nats-loki-bridge/; also needed by the planned console watch path
# ═════════════════════════════════════════════════════════════════════════════
section "Python Dependencies"

# nats-py (required by the NATS-to-Loki bridge)
read_nats_py_version() {
    run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import importlib.machinery
import importlib.metadata
import sysconfig

paths = []
for key in ("purelib", "platlib"):
    candidate = sysconfig.get_path(key)
    if candidate and candidate not in paths:
        paths.append(candidate)
if importlib.machinery.PathFinder.find_spec("nats", paths) is None:
    raise SystemExit(1)
for distribution in importlib.metadata.distributions(path=paths):
    name = distribution.metadata.get("Name", "").lower().replace("_", "-")
    if name == "nats-py":
        print(distribution.version)
        raise SystemExit(0)
print("installed")
'
}

if $PYTHON3_READY && read_nats_py_version; then
    NATS_PY_VER=$BOUNDED_OUTPUT
    check_pass "nats-py $NATS_PY_VER"
else
    if $INSTALL; then
        check_fail "nats-py — not installed; pre-provision the verified project environment"
    else
        check_fail "nats-py — NOT FOUND (required by e2e/nats-loki-bridge)"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 6: Submodule Health (Odysseus meta-repo)
# Required by: All submodule builds, Myrmidons provisioning
# ═════════════════════════════════════════════════════════════════════════════
section "Submodule Health"

# Check if we're in the Odysseus repo
if [[ -f "$ODYSSEUS_ROOT/.gitmodules" ]] && submodule_manifest_is_safe; then
    SUBMODULE_INVENTORY_AVAILABLE=true
    SUBMODULE_PATH_INVENTORY_COMPLETE=false
    if ! load_submodule_declarations; then
        check_fail "submodule inventory unavailable: $SUBMODULE_POLICY_ERROR"
        SUBMODULE_INVENTORY_AVAILABLE=false
    elif ! validate_submodule_git_policy; then
        check_fail "submodule Git policy rejected: $SUBMODULE_POLICY_ERROR"
        SUBMODULE_INVENTORY_AVAILABLE=false
    elif ! SUBMODULE_STATUS=$(doctor_git -C "$ODYSSEUS_ROOT" \
        submodule status 2>/dev/null); then
        check_fail "submodule inventory unavailable: git submodule status failed"
        SUBMODULE_INVENTORY_AVAILABLE=false
    fi

    if $SUBMODULE_INVENTORY_AVAILABLE; then
        TOTAL_SUBS=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF{n++} END{print n+0}')
        UNINIT_COUNT=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF && /^-/{n++} END{print n+0}')
        DRIFT_COUNT=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF && /^[+U]/{n++} END{print n+0}')
        EXPECTED_PATHS=$(printf '%s\n' "$EXPECTED_SUBMODULES" | awk 'NF{print $2}' | sort)
        STATUS_PATHS=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF{print $2}' | sort)
        SUBMODULE_PATH_INVENTORY_COMPLETE=true

        if [[ "$TOTAL_SUBS" -ne "$EXPECTED_TOTAL" \
            || "$STATUS_PATHS" != "$EXPECTED_PATHS" ]]; then
            check_fail "submodule inventory incomplete or mismatched: expected $EXPECTED_TOTAL exact paths, read $TOTAL_SUBS"
            SUBMODULE_PATH_INVENTORY_COMPLETE=false
        elif [[ "$DRIFT_COUNT" -ne 0 ]]; then
            check_fail "$DRIFT_COUNT / $TOTAL_SUBS submodules differ from their pinned gitlinks"
        elif [[ "$UNINIT_COUNT" -eq 0 ]]; then
            check_pass "All $TOTAL_SUBS submodules initialized at their pins"
        elif $INSTALL; then
            SUBMODULE_PATH_INVENTORY_COMPLETE=false
            check_fail "Submodule initialization through doctor is unavailable pending a trusted exact-pin updater; pre-provision the verified pins"
        else
            check_fail "$UNINIT_COUNT / $TOTAL_SUBS submodules NOT initialized"
        fi

        # Check Myrmidons not targeting ai-maestro (#77). A pinned component is
        # diagnostic-only here; repairs belong in its repository and integration PR.
        MYRMIDONS_DIR="$ODYSSEUS_ROOT/provisioning/Myrmidons"
        if [[ -d "$MYRMIDONS_DIR/scripts" ]]; then
            if run_bounded_command "$LOCAL_READ_TIMEOUT_SECONDS" \
                "$LOCAL_READ_MAX_BYTES" grep -rE \
                '(ai[-_]maestro|MAESTRO_URL|\baim_[a-z]+\()' \
                "$MYRMIDONS_DIR/scripts/"; then
                STALE_OUTPUT=$BOUNDED_OUTPUT
                STALE_REFS=$(printf '%s\n' "$STALE_OUTPUT" | awk 'NF{n++} END{print n+0}')
                check_fail "Myrmidons has $STALE_REFS stale ai-maestro references (aim_*)"
                if $INSTALL; then
                    check_warn "Pinned Myrmidons is not auto-updated; repair its owner repo, then integrate an approved gitlink"
                fi
            else
                GREP_STATUS=$?
                if [[ "$GREP_STATUS" -eq 1 ]]; then
                    check_pass "Myrmidons targets Agamemnon (not ai-maestro)"
                else
                    check_fail "Myrmidons reference scan unavailable"
                fi
            fi
        else
            check_warn "Myrmidons scripts directory not found — submodule may not be initialized"
        fi

        if $SUBMODULE_PATH_INVENTORY_COMPLETE; then
            BROKEN_PATHS=0
            while IFS= read -r line; do
                subpath=$(printf '%s\n' "$line" | awk '{print $2}')
                if [[ -z "$subpath" || -L "$ODYSSEUS_ROOT/$subpath" \
                    || ! -d "$ODYSSEUS_ROOT/$subpath" ]]; then
                    BROKEN_PATHS=$((BROKEN_PATHS + 1))
                fi
            done <<< "$SUBMODULE_STATUS"
            if [[ "$BROKEN_PATHS" -eq 0 ]]; then
                check_pass "All submodule paths are direct directories"
            else
                check_fail "$BROKEN_PATHS submodule paths are missing or symlinked"
            fi
        else
            check_skip "submodule path checks unavailable from an incomplete inventory"
        fi
    fi
elif [[ -e "$ODYSSEUS_ROOT/.gitmodules" \
        || -L "$ODYSSEUS_ROOT/.gitmodules" ]]; then
    check_fail "submodule metadata unavailable: .gitmodules must be a direct owner-bound regular file"
else
    check_fail "submodule metadata unavailable: .gitmodules is missing"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 7: Network Connectivity (cross-host service health)
# Only checked with --check-services --worker-ip IP --control-ip IP
# ═════════════════════════════════════════════════════════════════════════════
if $CHECK_SERVICES; then
    section "Service Health (Cross-Host)"

    if [[ -n "$WORKER_IP" ]]; then
        WORKER_HTTP_HOST=$(http_host_for_ip "$WORKER_IP")
        if $WORKER_PEER_VERIFIED; then
            check_service_health "NATS @ ${WORKER_IP}:8222" \
                "http://${WORKER_HTTP_HOST}:8222/healthz" nats
            check_service_health "Agamemnon @ ${WORKER_IP}:8080" \
                "http://${WORKER_HTTP_HOST}:8080/v1/health" status
            check_service_health "Hermes @ ${WORKER_IP}:8085" \
                "http://${WORKER_HTTP_HOST}:8085/health" hermes
            check_service_health "Grafana @ ${WORKER_IP}:3001" \
                "http://${WORKER_HTTP_HOST}:3001/api/health" grafana
            check_service_health "Prometheus @ ${WORKER_IP}:9090" \
                "http://${WORKER_HTTP_HOST}:9090/-/healthy" prometheus
            check_service_health "Argus Exporter @ ${WORKER_IP}:9100" \
                "http://${WORKER_HTTP_HOST}:9100/metrics" argus
        else
            check_skip "worker service checks require an exact online Tailscale peer"
        fi
    else
        check_warn "No --worker-ip provided — skipping worker service checks"
    fi

    if [[ -n "$CONTROL_IP" ]]; then
        CONTROL_HTTP_HOST=$(http_host_for_ip "$CONTROL_IP")
        if $CONTROL_PEER_VERIFIED; then
            check_service_health "Nestor @ ${CONTROL_IP}:8081" \
                "http://${CONTROL_HTTP_HOST}:8081/v1/health" status
        else
            check_skip "control service checks require an exact online Tailscale peer"
        fi
    else
        check_warn "No --control-ip provided — skipping control service checks"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
TOTAL=$((_PASS + _FAIL + _WARN))
if [[ "$_FAIL" -eq 0 && "$_WARN" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $TOTAL checks passed.${NC}"
elif [[ "$_FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}$_PASS passed${NC}, ${YELLOW}$_WARN warnings${NC}"
else
    echo -e "${RED}${BOLD}$_FAIL failed${NC}, ${GREEN}$_PASS passed${NC}, ${YELLOW}$_WARN warnings${NC}"
    if ! $INSTALL; then
        echo -e "Run ${CYAN}just doctor --install${NC} to apply safe local-state repairs."
    fi
fi
echo ""

# Exit with failure if any checks failed
[[ "$_FAIL" -eq 0 ]]
