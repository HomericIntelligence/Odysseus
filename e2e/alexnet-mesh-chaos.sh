#!/usr/bin/env bash
# e2e/alexnet-mesh-chaos.sh — Chaos/hardening tests for the AlexNet mesh pipeline
#
# Deliberately crashes the fleet scripts (deploy / wait / collect / teardown /
# train) and asserts they fail FAST + CLEANLY — no hangs, clear diagnostics,
# correct exit codes — then verifies recovery is possible. The intent is to
# harden the mesh by breaking it under test, per the repo's chaos convention
# (e2e/tests/chaos/*), but self-contained: it does NOT depend on the
# NATS/Agamemnon stack or e2e/lib/common.sh.
#
# Cases:
#   C1 [CHAOS_NETWORK=1] offline-host rejection: teardown must NOT hang when
#      an approved offline host (hermes) is selected.
#   C2 [CHAOS_NETWORK=1] unresolvable-host rejection: deploy must fail fast.
#   C3 missing-image: train must fail fast (rc 1) with a clear message.
#   C4 [CHAOS_LIVE=1] clobber guard: train must REFUSE to clobber a running
#      container (rc 1) instead of silently destroying an in-flight job.
#   C5 [CHAOS_LIVE=1] kill-mid-run: gate must detect a killed container
#      (non-zero exit) and fail with a diagnostic.
#   C6 smoke-gate: wait+gate --smoke must PASS a completed smoke run (marker
#      present; smoke mode intentionally saves no weights — run_train.mojo
#      #5551) and the strict default must FAIL the same run (weights missing).
#   C7 teardown idempotency: owned fixture removal and subsequent absence both
#      produce verified zero exits.
#
# Usage:
#   ALEXNET_CHAOS_APPROVED_HOST=<exact-local-host> just alexnet-mesh-chaos
#   ALEXNET_CHAOS_APPROVED_HOST=<exact-local-host> just alexnet-mesh-chaos-live
#
# Optional env:
#   FLEET          — hosts to exercise (default: epimetheus apollo aeolus
#                    hephaestus — same default as the protected workflow)
#   CHAOS_LIVE=1   — enable C4/C5 (launch/kill a real training container)
#   CHAOS_NETWORK=1 — enable C1/C2 current Tailscale inventory probes
#   CHAOS_TIMEOUT  — per-case kill guard, 1..600 seconds (default: 45)
#   ALEXNET_CHAOS_APPROVED_HOST — exact local host approved for container effects
#
# Exit codes:
#   0 — all enabled cases passed
#   1 — one or more cases failed (details printed per case)
#   2 — usage/environment error (invalid input or missing prerequisite)
set -euo pipefail
set -m

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus}"
LOCAL_HOST=$(hostname)
CHAOS_TIMEOUT="${CHAOS_TIMEOUT:-45}"
if [[ ! "$CHAOS_TIMEOUT" =~ ^[0-9]+$ ]] \
        || ((10#$CHAOS_TIMEOUT == 0 || 10#$CHAOS_TIMEOUT > 600)); then
    echo "ERROR: CHAOS_TIMEOUT must be an integer from 1 through 600 seconds." >&2
    exit 2
fi
LIVE=0
[[ "${CHAOS_LIVE:-0}" == "1" ]] && LIVE=1
if [[ "${CHAOS_LIVE:-0}" != 0 && "${CHAOS_LIVE:-0}" != 1 ]]; then
    echo "ERROR: CHAOS_LIVE must be 0 or 1." >&2
    exit 2
fi
NETWORK=0
[[ "${CHAOS_NETWORK:-0}" == "1" ]] && NETWORK=1
if [[ "${CHAOS_NETWORK:-0}" != 0 && "${CHAOS_NETWORK:-0}" != 1 ]]; then
    echo "ERROR: CHAOS_NETWORK must be 0 or 1." >&2
    exit 2
fi
if [[ "${ALEXNET_CHAOS_APPROVED_HOST:-}" != "$LOCAL_HOST" ]]; then
    echo "ERROR: AlexNet chaos can change the local training container." >&2
    echo "Set ALEXNET_CHAOS_APPROVED_HOST to the exact local host: $LOCAL_HOST" >&2
    exit 2
fi
LSOF_BIN=""
if discovered_lsof=$(command -v lsof 2>/dev/null); then
    LSOF_BIN=$discovered_lsof
fi
[[ -n "$LSOF_BIN" ]] || LSOF_BIN=/usr/sbin/lsof
if ! command -v python3 >/dev/null 2>&1 || [[ ! -x "$LSOF_BIN" ]]; then
    echo "ERROR: python3 and lsof are required for bound cleanup and worker extinction." >&2
    exit 2
fi
if ! chaos_stamp=$(date -u +%Y%m%dT%H%M%SZ); then
    echo "ERROR: could not create a chaos run timestamp." >&2
    exit 2
fi
CHAOS_INVOCATION_ID="chaos-$chaos_stamp-$$"

# Keep case output private to this invocation. A fixed PID-based path can be
# pre-created as a symbolic link before this process starts.
if ! CHAOS_OUT=$(umask 077 && \
        mktemp "${TMPDIR:-/tmp}/odysseus-alexnet-chaos.XXXXXX"); then
    echo "ERROR: could not create the chaos output file." >&2
    exit 2
fi
CHAOS_OUT_PARENT=${CHAOS_OUT%/*}
CHAOS_OUT_NAME=${CHAOS_OUT##*/}
if ! exec 16< "$CHAOS_OUT_PARENT" || ! exec 15<> "$CHAOS_OUT"; then
    echo "ERROR: could not bind the chaos output identity." >&2
    exit 2
fi
if ! CHAOS_RECEIPT_DIR=$(umask 077 && \
        mktemp -d "${TMPDIR:-/tmp}/odysseus-alexnet-chaos-receipts.XXXXXX") \
        || ! exec 6< "$CHAOS_RECEIPT_DIR"; then
    echo "ERROR: could not bind the chaos receipt directory; bound output retained at: $CHAOS_OUT" >&2
    exit 2
fi
CHAOS_RECEIPT_PARENT=${CHAOS_RECEIPT_DIR%/*}
CHAOS_RECEIPT_NAME=${CHAOS_RECEIPT_DIR##*/}
if ! exec 20< "$CHAOS_RECEIPT_PARENT"; then
    echo "ERROR: could not bind the chaos receipt parent." >&2
    exit 2
fi

quarantine_bound_object() {
    python3 -I -E -c '
import ctypes, errno, os, secrets, stat, sys
parent_fd, object_fd = map(int, sys.argv[1:3])
name, expected_kind = sys.argv[3:5]
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)
def key(value): return value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode)
def rename_noreplace(directory_fd, source, destination):
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        result = library.renameat2(directory_fd, os.fsencode(source), directory_fd,
                                   os.fsencode(destination), ctypes.c_uint(1))
    elif sys.platform == "darwin" and hasattr(library, "renameatx_np"):
        result = library.renameatx_np(directory_fd, os.fsencode(source), directory_fd,
                                      os.fsencode(destination), ctypes.c_uint(0x4))
    else: raise OSError(errno.ENOTSUP, "atomic no-replace quarantine unavailable")
    if result != 0:
        value = ctypes.get_errno()
        raise OSError(value, os.strerror(value), destination)
def quarantine(directory_fd, entry_name, expected):
    for _ in range(128):
        quarantine_name = ".alexnet-quarantine-" + secrets.token_hex(16)
        try:
            rename_noreplace(directory_fd, entry_name, quarantine_name)
            break
        except FileExistsError: continue
    else: raise OSError("could not allocate no-replace quarantine")
    moved = os.stat(quarantine_name, dir_fd=directory_fd, follow_symlinks=False)
    if key(moved) != key(expected):
        raise OSError("path changed at quarantine boundary; both objects retained")
    return quarantine_name
expected = os.fstat(object_fd)
if expected_kind == "directory" and not stat.S_ISDIR(expected.st_mode): raise OSError("bound object is not a directory")
if expected_kind == "file" and not stat.S_ISREG(expected.st_mode): raise OSError("bound object is not a file")
named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
if key(named) != key(expected): raise OSError("chaos pathname was replaced")
quarantine_name = quarantine(parent_fd, name, expected)
print("NOTICE: bound chaos object preserved after no-replace quarantine: " + quarantine_name,
      file=sys.stderr)
' "$@"
}
cleanup_chaos_output() {
    local failed=0
    if ! quarantine_bound_object 16 15 "$CHAOS_OUT_NAME" file; then
        echo "ERROR: could not safely remove the bound chaos output; retained evidence near: $CHAOS_OUT" >&2
        failed=1
    fi
    if ! quarantine_bound_object 20 6 "$CHAOS_RECEIPT_NAME" directory; then
        echo "ERROR: could not safely remove the bound chaos receipt directory; retained evidence near: $CHAOS_RECEIPT_DIR" >&2
        failed=1
    fi
    if ! exec 6<&- 15>&- 16<&- 20<&-; then :; fi
    return "$failed"
}

# ── Result helpers (self-contained: no e2e/lib dependency) ──
PASS=0
FAIL=0
declare -a FAILED_CASES=()

info()  { printf '\n=== %s ===\n' "$*"; }
pass()  { PASS=$((PASS + 1)); printf '  [PASS] %s\n' "$*"; }
fail()  { FAIL=$((FAIL + 1)); FAILED_CASES+=("$*"); printf '  [FAIL] %s\n' "$*" >&2; }

# C4-C6 create destructive fixtures. Keep one exact ownership receipt live at
# a time and make the EXIT path authoritative for every normal, error, and
# signal return. Result directories are opened before use and are removed
# through those descriptors only after the exact container is extinct.
OWNED_CONTAINER_ID=""
OWNED_CONTAINER_RUN=""
OWNED_CONTAINER_IMAGE=""
OWNED_CONTAINER_MOUNT=""
PENDING_CONTAINER_RUN=""
PENDING_CONTAINER_IMAGE=""
PENDING_CONTAINER_MOUNT=""
PENDING_CONTAINER_CID_NAME=""
PENDING_RECEIPT_ACTIVE=0
PENDING_RECEIPT_PATH=""
OWNED_RESULTS_ACTIVE=0
OWNED_RESULTS_PARENT_ID=""
OWNED_RESULTS_ID=""
OWNED_RESULTS_NAME=""
EXPECTED_RESULTS_ACTIVE=0
EXPECTED_RESULTS_PARENT_ID=""
EXPECTED_RESULTS_NAME=""
EXPECTED_RESULTS_PATH=""
SPAWN_CRITICAL=0
SPAWN_WORKER_PID=""
SPAWN_SENTINEL=""
SPAWN_SENTINEL_ID=""
SPAWN_SENTINEL_FD=""
SPAWN_CONTROLLER_PID=$$
SPAWN_SHUTDOWN_FAILED=0
PENDING_SIGNAL_STATUS=0

container_binding_matches() {
    local binding=$1 actual_id actual_name actual_run actual_image actual_mount extra
    [[ "$binding" != *$'\n'* ]] || return 1
    IFS='|' read -r actual_id actual_name actual_run actual_image \
        actual_mount extra <<< "$binding"
    [[ -z "$extra" \
        && "$actual_id" == "$OWNED_CONTAINER_ID" \
        && ( "$actual_name" == alexnet-training \
            || "$actual_name" == /alexnet-training ) \
        && "$actual_run" == "$OWNED_CONTAINER_RUN" \
        && "$actual_image" == "$OWNED_CONTAINER_IMAGE" \
        && "$actual_mount" == "$OWNED_CONTAINER_MOUNT" ]]
}

register_owned_container() {
    local container_id=$1 run_id=$2 image_id=$3 result_mount=$4
    [[ -z "$OWNED_CONTAINER_ID" \
        && "$container_id" =~ ^[0-9a-f]{64}$ \
        && "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ \
        && "$image_id" =~ ^sha256:[0-9a-f]{64}$ \
        && ( -z "$result_mount" || "$result_mount" == /* ) ]] || return 1
    OWNED_CONTAINER_ID=$container_id
    OWNED_CONTAINER_RUN=$run_id
    OWNED_CONTAINER_IMAGE=$image_id
    OWNED_CONTAINER_MOUNT=$result_mount
    PENDING_CONTAINER_RUN=""
    PENDING_CONTAINER_IMAGE=""
    PENDING_CONTAINER_MOUNT=""
    PENDING_CONTAINER_CID_NAME=""
}

begin_container_spawn() {
    local receipt_saved_umask receipt_noclobber_was_set=0
    local local_sentinel_attempt local_sentinel_path local_saved_umask
    local local_noclobber_was_set
    [[ "$SPAWN_CRITICAL" == 0 && -z "$SPAWN_WORKER_PID" \
        && -z "$OWNED_CONTAINER_ID" && -z "$PENDING_CONTAINER_RUN" ]] || {
        echo "ERROR: a prior fixture ownership receipt is still active." >&2
        return 1
    }
    PENDING_CONTAINER_RUN=$1
    PENDING_CONTAINER_IMAGE=$2
    PENDING_CONTAINER_MOUNT=$3
    PENDING_CONTAINER_CID_NAME=$4
    [[ "$PENDING_CONTAINER_CID_NAME" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
    PENDING_RECEIPT_PATH="$CHAOS_RECEIPT_DIR/$PENDING_CONTAINER_CID_NAME"
    receipt_saved_umask=$(umask)
    [[ -o noclobber ]] && receipt_noclobber_was_set=1
    umask 077
    # Linux creates the receipt exclusively, then upgrades that exact open
    # object through procfs. Other platforms perform one nonblocking O_RDWR
    # open inside the bound private directory and validate it immediately.
    # FD 12 is the sole retained receipt authority in both cases.
    if [[ "$(uname -s)" == Linux ]]; then
        set -o noclobber
        if ! exec 13> "$PENDING_RECEIPT_PATH" 2>/dev/null; then
            if [[ "$receipt_noclobber_was_set" == 0 ]]; then
                set +o noclobber
            fi
            umask "$receipt_saved_umask"
            PENDING_CONTAINER_RUN=""
            PENDING_CONTAINER_IMAGE=""
            PENDING_CONTAINER_MOUNT=""
            PENDING_CONTAINER_CID_NAME=""
            PENDING_RECEIPT_PATH=""
            return 1
        fi
        if [[ "$receipt_noclobber_was_set" == 0 ]]; then
            set +o noclobber
        fi
        if ! exec 12<> "/proc/$$/fd/13"; then
            exec 13>&-
            umask "$receipt_saved_umask"
            PENDING_CONTAINER_RUN=""
            PENDING_CONTAINER_IMAGE=""
            PENDING_CONTAINER_MOUNT=""
            PENDING_CONTAINER_CID_NAME=""
            PENDING_RECEIPT_PATH=""
            return 1
        fi
    else
        if [[ -e "$PENDING_RECEIPT_PATH" \
                || -L "$PENDING_RECEIPT_PATH" ]] \
                || ! exec 12<> "$PENDING_RECEIPT_PATH"; then
            umask "$receipt_saved_umask"
            PENDING_CONTAINER_RUN=""
            PENDING_CONTAINER_IMAGE=""
            PENDING_CONTAINER_MOUNT=""
            PENDING_CONTAINER_CID_NAME=""
            PENDING_RECEIPT_PATH=""
            return 1
        fi
    fi
    umask "$receipt_saved_umask"
    if ! python3 -I -E -c '
import os, stat, sys
directory_fd, receipt_fd = map(int, sys.argv[1:3])
name = sys.argv[3]
directory = os.fstat(directory_fd)
receipt = os.fstat(receipt_fd)
named = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
def key(value): return value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode)
if (
    not stat.S_ISDIR(directory.st_mode)
    or not stat.S_ISREG(receipt.st_mode)
    or receipt.st_nlink != 1
    or receipt.st_uid != os.geteuid()
    or stat.S_IMODE(receipt.st_mode) & 0o077
    or key(receipt) != key(named)
):
    raise SystemExit(1)
' 6 12 "$PENDING_CONTAINER_CID_NAME"; then
        if ! exec 12>&- 13>&-; then :; fi
        PENDING_CONTAINER_RUN=""
        PENDING_CONTAINER_IMAGE=""
        PENDING_CONTAINER_MOUNT=""
        PENDING_CONTAINER_CID_NAME=""
        PENDING_RECEIPT_PATH=""
        return 1
    fi
    if ! exec 13>&-; then :; fi
    PENDING_RECEIPT_ACTIVE=1
    local_sentinel_attempt=0
    local_sentinel_path=""
    local_saved_umask=$(umask)
    local_noclobber_was_set=0
    [[ -o noclobber ]] && local_noclobber_was_set=1
    umask 077
    set -o noclobber
    while ((local_sentinel_attempt < 128)); do
        local_sentinel_path="$CHAOS_RECEIPT_DIR/.worker-sentinel.$$.$RANDOM.$local_sentinel_attempt"
        if exec 14> "$local_sentinel_path"; then
            break
        fi
        ((local_sentinel_attempt += 1))
    done
    if [[ "$local_noclobber_was_set" == 0 ]]; then
        set +o noclobber
    fi
    umask "$local_saved_umask"
    if ((local_sentinel_attempt == 128)); then
        if ! exec 12>&-; then :; fi
        PENDING_RECEIPT_ACTIVE=0
        PENDING_CONTAINER_RUN=""
        PENDING_CONTAINER_IMAGE=""
        PENDING_CONTAINER_MOUNT=""
        PENDING_CONTAINER_CID_NAME=""
        PENDING_RECEIPT_PATH=""
        return 1
    fi
    SPAWN_SENTINEL=$local_sentinel_path
    SPAWN_SENTINEL_FD=14
    if ! SPAWN_SENTINEL_ID=$(python3 -I -E -c '
import os, stat, sys
fd = int(sys.argv[1])
value = os.fstat(fd)
named = os.stat(sys.argv[2], follow_symlinks=False)
if (not stat.S_ISREG(value.st_mode) or value.st_nlink != 1
        or value.st_uid != os.geteuid()
        or stat.S_IMODE(value.st_mode) & 0o077
        or (value.st_dev, value.st_ino) != (named.st_dev, named.st_ino)):
    raise SystemExit(1)
print(f"{value.st_dev}:{value.st_ino}")
' "$SPAWN_SENTINEL_FD" "$SPAWN_SENTINEL"); then
        exec 12>&-
        exec 14>&-
        PENDING_RECEIPT_ACTIVE=0
        PENDING_CONTAINER_RUN=""
        PENDING_CONTAINER_IMAGE=""
        PENDING_CONTAINER_MOUNT=""
        PENDING_CONTAINER_CID_NAME=""
        PENDING_RECEIPT_PATH=""
        SPAWN_SENTINEL=""
        SPAWN_SENTINEL_ID=""
        SPAWN_SENTINEL_FD=""
        return 1
    fi
    SPAWN_CRITICAL=1
}

pending_container_id() {
    [[ "$PENDING_RECEIPT_ACTIVE" == 1 ]] || return 1
    python3 -I -E -c '
import os, sys
receipt_fd = int(sys.argv[1])
data = os.pread(receipt_fd, 66, 0)
data = data.decode("ascii")
if len(data) != 65 or data[-1] != "\n" or any(c not in "0123456789abcdef" for c in data[:-1]):
    raise SystemExit(1)
print(data[:-1])
' 12
}

prepare_spawn_worker() {
    local actual
    [[ "$SPAWN_SENTINEL_FD" == 14 ]] || return 1
    actual=$(python3 -I -E -c '
import os, stat
value = os.fstat(14)
if not stat.S_ISREG(value.st_mode): raise SystemExit(1)
print(f"{value.st_dev}:{value.st_ino}")
') || return 1
    [[ "$actual" == "$SPAWN_SENTINEL_ID" ]] || return 1
    printf R >&14
}

wait_spawn_worker_ready() {
    local descriptor=$SPAWN_SENTINEL_FD attempt
    [[ "$descriptor" =~ ^[0-9]+$ \
        && "$SPAWN_WORKER_PID" =~ ^[0-9]+$ ]] || return 1
    for ((attempt = 0; attempt < 100; attempt++)); do
        if python3 -I -E -c '
import os, stat, sys, time
descriptor = int(sys.argv[1])
device, inode = map(int, sys.argv[2].split(":"))
value = os.fstat(descriptor)
if (not stat.S_ISREG(value.st_mode)
        or (value.st_dev, value.st_ino) != (device, inode)):
    raise SystemExit(2)
if value.st_size == 1:
    raise SystemExit(0)
if value.st_size != 0:
    raise SystemExit(2)
time.sleep(0.02)
raise SystemExit(1)
' "$descriptor" "$SPAWN_SENTINEL_ID"; then
            return 0
        fi
        [[ "$PENDING_SIGNAL_STATUS" == 0 ]] || return 1
    done
    return 1
}

worker_sentinel_holders() {
    local expected=$1 output rc=0
    [[ "$expected" =~ ^[0-9]+:[0-9]+$ ]] || return 2
    # This function runs in command substitution. Close the substitution
    # shell's inherited controller descriptor before its scanner starts, or
    # that short-lived shell would report itself as an escaped worker.
    exec 14>&-
    if [[ "$(uname -s)" == Linux ]]; then
        python3 -I -E -c '
import glob, os, sys
device, inode = map(int, sys.argv[1].split(":"))
controller = sys.argv[2]
for proc in glob.glob("/proc/[0-9]*"):
    pid = proc.rsplit("/", 1)[-1]
    if pid == controller or int(pid) == os.getpid(): continue
    try: entries = os.listdir(proc + "/fd")
    except (FileNotFoundError, PermissionError): continue
    for entry in entries:
        try: value = os.stat(proc + "/fd/" + entry)
        except (FileNotFoundError, PermissionError): continue
        if (value.st_dev, value.st_ino) == (device, inode):
            print(pid)
            break
' "$expected" "$SPAWN_CONTROLLER_PID"
        return
    fi
    output=$("$LSOF_BIN" -F pDi 2>/dev/null) || rc=$?
    [[ "$rc" == 0 || "$rc" == 1 ]] || return 2
    [[ "$rc" == 0 ]] || return 0
    python3 -I -E -c '
import sys
device, inode = map(int, sys.argv[1].split(":"))
controller = sys.argv[2]
pid = None; current_device = None; seen = set()
for raw in sys.stdin:
    line = raw.rstrip("\n")
    if line.startswith("p") and line[1:].isdigit():
        pid = line[1:]; current_device = None
    elif line.startswith("D"):
        try: current_device = int(line[1:], 0)
        except ValueError: current_device = None
    elif line.startswith("i") and pid is not None and current_device == device:
        try: current_inode = int(line[1:])
        except ValueError: continue
        if current_inode == inode and pid != controller and pid not in seen:
            print(pid); seen.add(pid)
' "$expected" "$SPAWN_CONTROLLER_PID" <<< "$output"
}

signal_worker_holder() {
    local holder=$1 expected=$2 signal_name=$3
    if [[ "$(uname -s)" == Linux ]]; then
        python3 -I -E -c '
import os, signal, sys
pid, expected, signal_name = int(sys.argv[1]), sys.argv[2], sys.argv[3]
device, inode = map(int, expected.split(":"))
if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"): raise SystemExit(2)
try: pidfd = os.pidfd_open(pid)
except ProcessLookupError: raise SystemExit(0)
try:
    held = False
    try: names = os.listdir(f"/proc/{pid}/fd")
    except FileNotFoundError: names = ()
    for name in names:
        try: value = os.stat(f"/proc/{pid}/fd/{name}")
        except (FileNotFoundError, PermissionError): continue
        if (value.st_dev, value.st_ino) == (device, inode):
            held = True
            break
    if held:
        try: signal.pidfd_send_signal(pidfd, getattr(signal, "SIG" + signal_name))
        except ProcessLookupError: pass
finally: os.close(pidfd)
' "$holder" "$expected" "$signal_name"
    else
        return 2
    fi
}

extinguish_worker_sentinel() {
    local expected=$1 signal_name holder holders attempt rc
    [[ "$expected" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    for signal_name in TERM KILL; do
        for ((attempt = 0; attempt < 20; attempt++)); do
            rc=0
            holders=$(worker_sentinel_holders "$expected") || rc=$?
            [[ "$rc" == 0 ]] || return 1
            [[ -n "$holders" ]] || return 0
            while IFS= read -r holder; do
                [[ "$holder" =~ ^[0-9]+$ ]] || continue
                signal_worker_holder "$holder" "$expected" "$signal_name" \
                    || return 1
            done <<< "$holders"
            if ! sleep 0.1; then :; fi
        done
    done
    rc=0
    holders=$(worker_sentinel_holders "$expected") || rc=$?
    [[ "$rc" == 0 && -z "$holders" ]]
}

stop_spawn_worker() {
    local worker_pid=$SPAWN_WORKER_PID
    [[ -n "$SPAWN_SENTINEL_ID" ]] || return 0
    extinguish_worker_sentinel "$SPAWN_SENTINEL_ID" || return 1
    if [[ "$worker_pid" =~ ^[0-9]+$ ]]; then
        if ! wait "$worker_pid" 2>/dev/null; then :; fi
    fi
    SPAWN_WORKER_PID=""
    return 0
}

consume_pending_spawn_signal() {
    if [[ "$PENDING_SIGNAL_STATUS" != 0 ]]; then
        if ! stop_spawn_worker; then
            SPAWN_SHUTDOWN_FAILED=1
        fi
        end_container_spawn
    fi
}

honor_pending_signal() {
    local status=$PENDING_SIGNAL_STATUS
    if [[ "$status" != 0 ]]; then
        PENDING_SIGNAL_STATUS=0
        exit "$status"
    fi
}

end_container_spawn() {
    if [[ "$PENDING_RECEIPT_ACTIVE" == 1 ]]; then
        if ! exec 12>&-; then :; fi
        PENDING_RECEIPT_ACTIVE=0
        PENDING_RECEIPT_PATH=""
    fi
    if [[ "$SPAWN_SENTINEL_FD" =~ ^[0-9]+$ ]]; then
        if ! exec 14>&-; then :; fi
    fi
    SPAWN_SENTINEL=""
    SPAWN_SENTINEL_ID=""
    SPAWN_SENTINEL_FD=""
    SPAWN_CRITICAL=0
    honor_pending_signal
}

handle_chaos_signal() {
    local status=$1
    if [[ "$SPAWN_CRITICAL" == 1 ]]; then
        PENDING_SIGNAL_STATUS=$status
        trap ':' INT TERM HUP
        return 0
    fi
    trap ':' INT TERM HUP
    if [[ -n "$SPAWN_SENTINEL_ID" ]]; then
        if ! stop_spawn_worker; then
            SPAWN_SHUTDOWN_FAILED=1
        fi
        end_container_spawn
    fi
    exit "$status"
}

bind_owned_result_tree() {
    local result_path=$1 parent identity expected_parent=""
    [[ "$OWNED_RESULTS_ACTIVE" == 0 && "$result_path" == /* \
        && "$result_path" != / ]] || return 1
    parent=${result_path%/*}
    OWNED_RESULTS_NAME=${result_path##*/}
    [[ -n "$parent" && -n "$OWNED_RESULTS_NAME" ]] || return 1
    if ! exec 8< "$parent" || ! exec 9< "$result_path"; then
        if ! exec 8<&-; then :; fi
        if ! exec 9<&-; then :; fi
        return 1
    fi
    if [[ "$EXPECTED_RESULTS_ACTIVE" == 1 ]]; then
        [[ "$result_path" == "$EXPECTED_RESULTS_PATH" ]] || {
            exec 8<&-
            exec 9<&-
            return 1
        }
        expected_parent=$EXPECTED_RESULTS_PARENT_ID
    fi
    if ! identity=$(python3 -I -E -c '
import os
import stat
import sys

parent_fd, result_fd = map(int, sys.argv[1:3])
name = sys.argv[3]
expected_parent = sys.argv[4]
parent = os.fstat(parent_fd)
result = os.fstat(result_fd)
named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
if not stat.S_ISDIR(parent.st_mode) or not stat.S_ISDIR(result.st_mode):
    raise SystemExit(1)
parent_identity = f"{parent.st_dev}:{parent.st_ino}"
if expected_parent and parent_identity != expected_parent:
    raise SystemExit(1)
if (result.st_dev, result.st_ino) != (named.st_dev, named.st_ino):
    raise SystemExit(1)
print(f"{parent_identity} {result.st_dev}:{result.st_ino}")
' 8 9 "$OWNED_RESULTS_NAME" "$expected_parent"); then
        exec 8<&-
        exec 9<&-
        return 1
    fi
    IFS=' ' read -r OWNED_RESULTS_PARENT_ID OWNED_RESULTS_ID extra <<< "$identity"
    if [[ -n "${extra:-}" \
            || ! "$OWNED_RESULTS_PARENT_ID" =~ ^[0-9]+:[0-9]+$ \
            || ! "$OWNED_RESULTS_ID" =~ ^[0-9]+:[0-9]+$ ]]; then
        exec 8<&-
        exec 9<&-
        return 1
    fi
    OWNED_RESULTS_ACTIVE=1
}

bind_expected_result_absence() {
    local result_path=$1 parent identity
    [[ "$EXPECTED_RESULTS_ACTIVE" == 0 && "$result_path" == /* \
        && "$result_path" != / ]] || return 1
    parent=${result_path%/*}
    EXPECTED_RESULTS_NAME=${result_path##*/}
    [[ -n "$parent" && -n "$EXPECTED_RESULTS_NAME" ]] || return 1
    if ! mkdir -p -- "$parent" || ! exec 7< "$parent"; then
        if ! exec 7<&-; then :; fi
        EXPECTED_RESULTS_NAME=""
        return 1
    fi
    if ! identity=$(python3 -I -E -c '
import os
import stat
import sys

parent_fd = int(sys.argv[1])
name = sys.argv[2]
parent = os.fstat(parent_fd)
if not stat.S_ISDIR(parent.st_mode):
    raise SystemExit(1)
try:
    os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
except FileNotFoundError:
    pass
else:
    raise SystemExit(1)
print(f"{parent.st_dev}:{parent.st_ino}")
' 7 "$EXPECTED_RESULTS_NAME"); then
        exec 7<&-
        EXPECTED_RESULTS_NAME=""
        return 1
    fi
    [[ "$identity" =~ ^[0-9]+:[0-9]+$ ]] || {
        exec 7<&-
        EXPECTED_RESULTS_NAME=""
        return 1
    }
    EXPECTED_RESULTS_PARENT_ID=$identity
    EXPECTED_RESULTS_PATH=$result_path
    EXPECTED_RESULTS_ACTIVE=1
}

release_expected_result_absence() {
    [[ "$EXPECTED_RESULTS_ACTIVE" == 1 ]] || return 0
    if ! python3 -I -E -c '
import os
import stat
import sys

parent_fd = int(sys.argv[1])
name, expected_parent = sys.argv[2:4]
parent = os.fstat(parent_fd)
if not stat.S_ISDIR(parent.st_mode):
    raise SystemExit(1)
if f"{parent.st_dev}:{parent.st_ino}" != expected_parent:
    raise SystemExit(1)
try:
    os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
raise SystemExit(1)
' 7 "$EXPECTED_RESULTS_NAME" "$EXPECTED_RESULTS_PARENT_ID"; then
        return 1
    fi
    exec 7<&-
    EXPECTED_RESULTS_ACTIVE=0
    EXPECTED_RESULTS_PARENT_ID=""
    EXPECTED_RESULTS_NAME=""
    EXPECTED_RESULTS_PATH=""
}

retain_result_bindings() {
    if [[ "$OWNED_RESULTS_ACTIVE" == 1 ]]; then
        exec 8<&-
        exec 9<&-
        OWNED_RESULTS_ACTIVE=0
        OWNED_RESULTS_PARENT_ID=""
        OWNED_RESULTS_ID=""
        OWNED_RESULTS_NAME=""
    fi
    if [[ "$EXPECTED_RESULTS_ACTIVE" == 1 ]]; then
        exec 7<&-
        EXPECTED_RESULTS_ACTIVE=0
        EXPECTED_RESULTS_PARENT_ID=""
        EXPECTED_RESULTS_NAME=""
        EXPECTED_RESULTS_PATH=""
    fi
}

discover_pending_container() {
    local binding actual_id inspected_id actual_name actual_run actual_image actual_mount extra exists_rc=0 name_rc=0
    [[ -z "$OWNED_CONTAINER_ID" && -n "$PENDING_CONTAINER_RUN" ]] || return 0
    if ! actual_id=$(pending_container_id 2>/dev/null); then
        actual_id=""
    fi
    if [[ -z "$actual_id" ]]; then
        exists_rc=1
    else
        podman container exists "$actual_id" 2>/dev/null || exists_rc=$?
    fi
    if [[ "$exists_rc" == 1 ]]; then
        podman container exists alexnet-training 2>/dev/null || name_rc=$?
        if [[ "$name_rc" == 0 ]]; then
            echo "ERROR: pending exact fixture is absent but a same-name replacement was preserved." >&2
            return 1
        elif [[ "$name_rc" != 1 ]]; then
            echo "ERROR: pending replacement existence state is unavailable (rc=$name_rc)." >&2
            return 1
        fi
        if [[ -n "$PENDING_CONTAINER_MOUNT" \
                && "$OWNED_RESULTS_ACTIVE" == 0 \
                && ( -e "$PENDING_CONTAINER_MOUNT" \
                    || -L "$PENDING_CONTAINER_MOUNT" ) ]]; then
            if [[ "$EXPECTED_RESULTS_ACTIVE" == 1 ]] \
                    && bind_owned_result_tree "$PENDING_CONTAINER_MOUNT"; then
                echo "pending fixture created an exactly bound result tree; cleanup will remove it: $PENDING_CONTAINER_MOUNT" >&2
                PENDING_CONTAINER_RUN=""
                PENDING_CONTAINER_IMAGE=""
                PENDING_CONTAINER_MOUNT=""
                PENDING_CONTAINER_CID_NAME=""
                return 0
            else
                echo "ERROR: pending fixture left an unbound result tree; retained at: $PENDING_CONTAINER_MOUNT" >&2
            fi
            retain_result_bindings
            PENDING_CONTAINER_RUN=""
            PENDING_CONTAINER_IMAGE=""
            PENDING_CONTAINER_MOUNT=""
            PENDING_CONTAINER_CID_NAME=""
            return 1
        fi
        PENDING_CONTAINER_RUN=""
        PENDING_CONTAINER_IMAGE=""
        PENDING_CONTAINER_MOUNT=""
        PENDING_CONTAINER_CID_NAME=""
        return 0
    elif [[ "$exists_rc" != 0 ]]; then
        echo "ERROR: pending fixture existence state is unavailable (rc=$exists_rc)." >&2
        return 1
    fi
    if ! binding=$(podman inspect "$actual_id" \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null); then
        echo "ERROR: pending fixture identity is unavailable; replacement was preserved." >&2
        return 1
    fi
    IFS='|' read -r inspected_id actual_name actual_run actual_image \
        actual_mount extra <<< "$binding"
    if [[ -n "$extra" || "$inspected_id" != "$actual_id" \
            || ( "$actual_name" != alexnet-training \
                && "$actual_name" != /alexnet-training ) \
            || "$actual_run" != "$PENDING_CONTAINER_RUN" \
            || "$actual_image" != "$PENDING_CONTAINER_IMAGE" \
            || "$actual_mount" != "$PENDING_CONTAINER_MOUNT" ]]; then
        echo "ERROR: pending fixture binding changed; replacement was preserved." >&2
        return 1
    fi
    register_owned_container "$actual_id" "$actual_run" \
        "$actual_image" "$actual_mount" || return 1
    if [[ -n "$actual_mount" && "$OWNED_RESULTS_ACTIVE" == 0 \
            && ( -e "$actual_mount" || -L "$actual_mount" ) ]] \
            && { [[ "$EXPECTED_RESULTS_ACTIVE" != 1 ]] \
                || ! bind_owned_result_tree "$actual_mount"; }; then
        echo "ERROR: pending fixture result tree could not be bound; retained at: $actual_mount" >&2
        return 1
    fi
}

clear_extinct_container_binding() {
    local name_rc=0
    podman container exists alexnet-training 2>/dev/null || name_rc=$?
    if [[ "$name_rc" == 0 ]]; then
        echo "ERROR: same-name replacement was preserved; bound results were retained." >&2
        return 1
    elif [[ "$name_rc" != 1 ]]; then
        echo "ERROR: replacement existence state is unavailable (rc=$name_rc)." >&2
        return 1
    fi
    OWNED_CONTAINER_ID=""
    OWNED_CONTAINER_RUN=""
    OWNED_CONTAINER_IMAGE=""
    OWNED_CONTAINER_MOUNT=""
}

remove_bound_result_tree() {
    python3 -I -E -c '
import errno
import os
import stat
import sys

parent_fd, result_fd = map(int, sys.argv[1:3])
name, expected_parent, expected_result = sys.argv[3:6]

def identity(value):
    return f"{value.st_dev}:{value.st_ino}"

def object_key(value):
    return value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode)

def quarantine_bound_result_entry(directory_fd, entry_name, expected):
    import ctypes
    import secrets
    library = ctypes.CDLL(None, use_errno=True)
    for _ in range(128):
        quarantine_name = ".alexnet-quarantine-" + secrets.token_hex(16)
        if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
            result = library.renameat2(directory_fd, os.fsencode(entry_name), directory_fd,
                                       os.fsencode(quarantine_name), ctypes.c_uint(1))
        elif sys.platform == "darwin" and hasattr(library, "renameatx_np"):
            result = library.renameatx_np(directory_fd, os.fsencode(entry_name), directory_fd,
                                          os.fsencode(quarantine_name), ctypes.c_uint(0x4))
        else:
            raise OSError(errno.ENOTSUP, "atomic no-replace quarantine unavailable")
        if result == 0: break
        value = ctypes.get_errno()
        if value == errno.EEXIST: continue
        raise OSError(value, os.strerror(value), quarantine_name)
    else: raise OSError("could not allocate no-replace quarantine")
    moved = os.stat(quarantine_name, dir_fd=directory_fd, follow_symlinks=False)
    if object_key(moved) == object_key(expected):
        return quarantine_name
    raise OSError("result entry changed at quarantine boundary; evidence retained")

parent = os.fstat(parent_fd)
result = os.fstat(result_fd)
if not stat.S_ISDIR(parent.st_mode) or not stat.S_ISDIR(result.st_mode):
    raise SystemExit("bound result object is no longer a directory")
if identity(parent) != expected_parent or identity(result) != expected_result:
    raise SystemExit("bound result identity changed")
try:
    named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
except FileNotFoundError:
    raise SystemExit(0)
if identity(named) != expected_result or not stat.S_ISDIR(named.st_mode):
    raise SystemExit("result pathname was replaced")

quarantine_name = quarantine_bound_result_entry(parent_fd, name, result)
print("NOTICE: bound results preserved after no-replace quarantine: " + quarantine_name,
      file=sys.stderr)
' 8 9 "$OWNED_RESULTS_NAME" "$OWNED_RESULTS_PARENT_ID" "$OWNED_RESULTS_ID"
}

cleanup_owned_fixture() {
    local exists_rc=0 binding cleanup_failed=0
    if ! discover_pending_container; then
        cleanup_failed=1
    fi
    if [[ -n "$OWNED_CONTAINER_ID" ]]; then
        podman container exists "$OWNED_CONTAINER_ID" 2>/dev/null || exists_rc=$?
        if [[ "$exists_rc" == 0 ]]; then
            if ! binding=$(podman inspect "$OWNED_CONTAINER_ID" \
                --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
                2>/dev/null) || ! container_binding_matches "$binding"; then
                echo "ERROR: bound fixture identity is unavailable; replacement was preserved." >&2
                cleanup_failed=1
            elif ! podman rm -f "$OWNED_CONTAINER_ID" >/dev/null 2>&1; then
                echo "ERROR: could not remove the exact owned fixture container." >&2
                cleanup_failed=1
            else
                exists_rc=0
                podman container exists "$OWNED_CONTAINER_ID" 2>/dev/null || exists_rc=$?
                if [[ "$exists_rc" != 1 ]]; then
                    echo "ERROR: exact fixture container extinction was not verified (rc=$exists_rc)." >&2
                    cleanup_failed=1
                elif ! clear_extinct_container_binding; then
                    cleanup_failed=1
                fi
            fi
        elif [[ "$exists_rc" == 1 ]]; then
            if ! clear_extinct_container_binding; then
                cleanup_failed=1
            fi
        else
            echo "ERROR: exact fixture existence state is unavailable (rc=$exists_rc)." >&2
            cleanup_failed=1
        fi
    fi
    if [[ "$cleanup_failed" == 0 && "$OWNED_RESULTS_ACTIVE" == 1 ]]; then
        if remove_bound_result_tree; then
            exec 8<&-
            exec 9<&-
            OWNED_RESULTS_ACTIVE=0
            OWNED_RESULTS_PARENT_ID=""
            OWNED_RESULTS_ID=""
            OWNED_RESULTS_NAME=""
        else
            echo "ERROR: bound fixture result tree could not be removed safely." >&2
            cleanup_failed=1
        fi
    fi
    if [[ "$cleanup_failed" == 0 && "$EXPECTED_RESULTS_ACTIVE" == 1 ]]; then
        if ! release_expected_result_absence; then
            echo "ERROR: expected fixture result absence could not be verified; retained at: $EXPECTED_RESULTS_PATH" >&2
            cleanup_failed=1
        fi
    fi
    [[ "$cleanup_failed" == 0 ]]
}

finish_chaos() {
    local status=$? cleanup_rc=0
    trap - EXIT
    trap ':' INT TERM HUP
    if [[ "$SPAWN_SHUTDOWN_FAILED" == 1 ]]; then
        echo "ERROR: fixture launcher extinction was not verified; owned resources were retained." >&2
        cleanup_rc=1
    else
        cleanup_owned_fixture || cleanup_rc=$?
    fi
    cleanup_chaos_output || cleanup_rc=$?
    if [[ "$cleanup_rc" != 0 && "$status" == 0 ]]; then
        status=1
    fi
    exit "$status"
}

trap finish_chaos EXIT
trap 'handle_chaos_signal 130' INT
trap 'handle_chaos_signal 143' TERM
trap 'handle_chaos_signal 129' HUP

# run_expected_failure <label> <timeout-s> <cmd...> — the bounded command must
# fail for the case to pass. Both a timeout and an unexpected zero exit fail.
run_expected_failure() {
    # NOTE: never let the wrapped command's non-zero exit abort this suite
    # under `set -euo pipefail` — capture the rc with `|| rc=$?` instead.
    local label="$1" to="$2"
    shift 2
    local rc=0
    timeout "$to" "$@" >"$CHAOS_OUT" 2>&1 || rc=$?
    if [[ "$rc" -eq 124 ]]; then
        fail "$label: HUNG (killed after ${to}s)"
    elif [[ "$rc" -eq 0 ]]; then
        fail "$label: unexpectedly succeeded"
    else
        pass "$label: failed fast with rc=$rc (expected non-zero)"
    fi
    return 0
}

echo "=== AlexNet Mesh Chaos Suite ==="
echo "Fleet:            $FLEET"
echo "Local host:       $LOCAL_HOST"
echo "CHAOS_LIVE:       $LIVE"
echo "CHAOS_NETWORK:    $NETWORK"
echo "Per-case timeout: ${CHAOS_TIMEOUT}s"
echo ""

# ── Prerequisites ──
if ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman not found — this suite must run on a fleet host." >&2
    exit 2
fi
if ! command -v python3 >/dev/null 2>&1; then
    echo "ERROR: python3 is required for descriptor-bound fixture cleanup." >&2
    exit 2
fi
if [[ "$NETWORK" == 1 ]]; then
    for dependency in tailscale jq python3; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "ERROR: $dependency is required for CHAOS_NETWORK=1." >&2
            exit 2
        fi
    done
fi

# ── C1: explicitly approved offline-host tolerance ────────────────────────
info "C1: teardown with an offline host in FLEET must not hang"
# The dated runbook observation does not authorize a new probe. Run this case
# only when current inventory is offline and the operator names that host.
if [[ "$NETWORK" != 1 ]]; then
    echo "  SKIP: hermetic mode does not query Tailscale; set CHAOS_NETWORK=1 after approval."
else
    inventory_state=""
    if ! inventory_state=$(tailscale status --json 2>/dev/null | python3 -c "
import json, sys
d = json.load(sys.stdin)
peers = [dev for dev in d.get('Peer', {}).values() if dev.get('HostName') == 'hermes']
if not peers:
    print('absent')
elif len(peers) != 1 or not isinstance(peers[0].get('Online'), bool):
    raise SystemExit(3)
else:
    print('online' if peers[0]['Online'] else 'offline')
" 2>/dev/null); then
        fail "C1: current Tailscale inventory readback failed"
    elif [[ "$inventory_state" == offline ]]; then
        echo "  (hermes offline — this is the real-world crash case)"
        if [[ "${ALEXNET_CHAOS_APPROVED_OFFLINE_HOST:-}" == hermes ]]; then
            run_expected_failure "C1 teardown FLEET='hermes'" "$CHAOS_TIMEOUT" \
                env FLEET=hermes ALEXNET_TEARDOWN_APPROVED_FLEET=hermes \
                ALEXNET_RUN_ID="$CHAOS_INVOCATION_ID-c1" \
                bash "$SCRIPT_DIR/alexnet-fleet-teardown.sh"
            echo "  teardown output (tail):"
            tail -4 "$CHAOS_OUT" | sed 's/^/    /'
            if grep -Fq 'fleet resolution is incomplete' "$CHAOS_OUT"; then
                pass "C1: offline target was rejected by complete resolution"
            else
                fail "C1: teardown failure did not prove complete target resolution"
            fi
        else
            echo "  SKIP: set ALEXNET_CHAOS_APPROVED_OFFLINE_HOST=hermes to probe that exact offline target."
        fi
    else
        echo "  SKIP: hermes is $inventory_state in the current inventory."
    fi
fi

# ── C2: unresolvable-host rejection (deploy must fail fast, never hang) ────
info "C2: deploy with an unresolvable host must reject it without hanging"
if [[ "$NETWORK" == 1 ]]; then
    run_expected_failure "C2 deploy FLEET='$LOCAL_HOST no-such-host-xyz'" "$CHAOS_TIMEOUT" \
        env FLEET="$LOCAL_HOST no-such-host-xyz" DRY_RUN=1 \
        SKIP_BUILD=1 SKIP_DISTRIBUTE=1 SKIP_LAUNCH=1 \
        bash "$SCRIPT_DIR/alexnet-deploy-fleet.sh"
    echo "  deploy output (tail):"
    tail -4 "$CHAOS_OUT" | sed 's/^/    /'
    if grep -Fq 'fleet resolution is incomplete' "$CHAOS_OUT"; then
        pass "C2: unresolved target was rejected by complete resolution"
    else
        fail "C2: deploy failure did not prove complete target resolution"
    fi
else
    echo "  SKIP: hermetic mode does not query Tailscale; set CHAOS_NETWORK=1 after approval."
fi

# ── C3: missing image must fail fast ───────────────────────────────────────
info "C3: train with a missing image must fail fast with a clear message"
run_expected_failure "C3 train IMAGE_NAME=odyssey:nonexistent" "$CHAOS_TIMEOUT" \
    env IMAGE_NAME="odyssey:nonexistent" MAX_BATCHES=3 bash "$SCRIPT_DIR/alexnet-train.sh"
echo "  train output (tail):"
tail -4 "$CHAOS_OUT" | sed 's/^/    /'
if grep -q "not loaded" "$CHAOS_OUT"; then
    pass "C3: clear 'image not loaded' diagnostic present"
else
    fail "C3: missing clear 'image not loaded' diagnostic"
fi

# ── C4 [LIVE]: clobber guard must refuse to destroy a running container ────
if [[ "$LIVE" -eq 1 ]]; then
    info "C4 [LIVE]: train must REFUSE to clobber a running container"
    c4_seeded=0
    c4_exists_rc=0
    podman container exists alexnet-training 2>/dev/null || c4_exists_rc=$?
    if [[ "$c4_exists_rc" == 0 ]]; then
        fail "C4: an existing alexnet-training container is not owned by this invocation"
    elif [[ "$c4_exists_rc" != 1 ]]; then
        fail "C4: container existence state is unavailable (rc=$c4_exists_rc)"
    elif ! c4_image_id=$(podman image inspect localhost/odyssey:dev \
        --format '{{.Id}}' 2>/dev/null) \
        || [[ ! "$c4_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        fail "C4: exact local fixture image identity is unavailable"
    else
        c4_run_id="$CHAOS_INVOCATION_ID-c4"
        c4_container_id=""
        c4_launch_rc=0
        c4_cid_name=c4.receipt
        c4_cid_path="$CHAOS_RECEIPT_DIR/c4.podman.cid"
        begin_container_spawn "$c4_run_id" "$c4_image_id" "" "$c4_cid_name"
        (
            prepare_spawn_worker
            created_id=$(podman create --cidfile "$c4_cid_path" --name alexnet-training \
                --label "io.homeric.alexnet.run-id=$c4_run_id" \
                --userns=keep-id "$c4_image_id" sleep 600)
            [[ "$created_id" != *$'\n'* && "$created_id" =~ ^[0-9a-f]{64}$ ]]
            printf '%s\n' "$created_id" >&12
            podman start "$created_id" >/dev/null
        ) >"$CHAOS_OUT" 2>&1 &
        SPAWN_WORKER_PID=$!
        if ! wait_spawn_worker_ready; then
            c4_launch_rc=1
            if ! stop_spawn_worker; then
                SPAWN_SHUTDOWN_FAILED=1
            fi
        fi
        SPAWN_CRITICAL=0
        consume_pending_spawn_signal
        if [[ "$c4_launch_rc" == 0 ]]; then
            wait "$SPAWN_WORKER_PID" || c4_launch_rc=$?
        fi
        if ! extinguish_worker_sentinel "$SPAWN_SENTINEL_ID"; then
            c4_launch_rc=1
        fi
        SPAWN_WORKER_PID=""
        c4_container_id=""
        if ! c4_container_id=$(pending_container_id 2>/dev/null); then
            c4_container_id=""
        fi
        if [[ "$c4_launch_rc" == 0 \
                && "$c4_container_id" =~ ^[0-9a-f]{64}$ ]] \
                && register_owned_container "$c4_container_id" \
                    "$c4_run_id" "$c4_image_id" ""; then
            c4_seeded=1
        else
            fail "C4: fixture seed unavailable"
        fi
        end_container_spawn
        if [[ "$c4_seeded" == 1 ]]; then
            c4_binding=""
            if ! c4_binding=$(podman inspect "$c4_container_id" \
                --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}' \
                2>/dev/null); then
                fail "C4: seeded fixture state is unavailable"
            else
                IFS='|' read -r c4_actual_id c4_name c4_state c4_run c4_image c4_extra \
                    <<< "$c4_binding"
                if [[ -n "$c4_extra" || "$c4_actual_id" != "$c4_container_id" \
                        || ( "$c4_name" != alexnet-training \
                            && "$c4_name" != /alexnet-training ) \
                        || "$c4_run" != "$c4_run_id" \
                        || "$c4_image" != "$c4_image_id" ]]; then
                    fail "C4: seeded fixture identity did not match this invocation"
                elif [[ "$c4_state" != running ]]; then
                    fail "C4: seeded fixture was not running (state '$c4_state')"
                else
                    run_expected_failure "C4 train while container RUNNING" "$CHAOS_TIMEOUT" \
                        env ALEXNET_RUN_ID="$c4_run_id" \
                        IMAGE_NAME="localhost/odyssey:dev" MAX_BATCHES=3 \
                        bash "$SCRIPT_DIR/alexnet-train.sh"
                    echo "  train output (tail):"
                    tail -4 "$CHAOS_OUT" | sed 's/^/    /'
                    if grep -Fq "cannot safely replace 'alexnet-training'" "$CHAOS_OUT"; then
                        c4_after=""
                        if ! c4_after=$(podman inspect "$c4_container_id" \
                            --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}' \
                            2>/dev/null); then
                            c4_after=""
                        fi
                        if [[ "$c4_after" == "$c4_binding" ]]; then
                            pass "C4: clobber guard rejected the running fixture and left the exact fixture unchanged"
                        else
                            fail "C4: exact seeded fixture changed after clobber rejection"
                        fi
                    else
                        fail "C4: missing clobber-guard message"
                    fi
                fi
            fi
        fi
    fi
    if [[ "$c4_seeded" == 1 || "$PENDING_CONTAINER_RUN" == *-c4 ]]; then
        if cleanup_owned_fixture; then
            echo "  (C4 cleanup: seed container removed)" >&2
        else
            fail "C4: could not safely remove the owned fixture container"
        fi
    fi
else
    info "C4 [LIVE]: skipped (set CHAOS_LIVE=1 to exercise the clobber guard)"
fi

# ── C5: kill-mid-run (LIVE) — gate must detect a killed container ─────────
# Crash the gate's failure path: launch a REAL training container, SIGKILL it
# while it is genuinely running, and assert the gate FAILS fast with a clear
# diagnostic instead of passing or hanging. A killed container leaves no
# completion marker and a non-zero exit — the gate must not be fooled.
info "C5 [LIVE]: kill a real training container mid-run; gate must detect it"
if [[ "$LIVE" -eq 1 ]]; then
    c5_owned=0
    c5_exists_rc=0
    podman container exists alexnet-training 2>/dev/null || c5_exists_rc=$?
    if [[ "$c5_exists_rc" == 0 ]]; then
        fail "C5: an existing alexnet-training container is not owned by this invocation"
    elif [[ "$c5_exists_rc" != 1 ]]; then
        fail "C5: container existence state is unavailable (rc=$c5_exists_rc)"
    elif ! c5_image_id=$(podman image inspect localhost/odyssey:dev \
        --format '{{.Id}}' 2>/dev/null) \
        || [[ ! "$c5_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        fail "C5: exact local training image identity is unavailable"
    else
        echo "  launching real training container (MAX_BATCHES=1 EPOCHS=1)..."
        rc=0
        c5_run_id="$CHAOS_INVOCATION_ID-c5"
        c5_results="$HOME/alexnet-results/runs/$c5_run_id/$LOCAL_HOST"
        if ! bind_expected_result_absence "$c5_results"; then
            fail "C5: result parent or expected absence could not be bound"
        else
            c5_cid_name=c5.receipt
            begin_container_spawn "$c5_run_id" "$c5_image_id" "$c5_results" "$c5_cid_name"
            (
                prepare_spawn_worker
                exec timeout 720 env ALEXNET_RUN_ID="$c5_run_id" \
                    ALEXNET_CONTAINER_ID_FD=12 \
                    IMAGE_NAME="localhost/odyssey:dev" MAX_BATCHES=1 EPOCHS=1 \
                    bash "$SCRIPT_DIR/alexnet-train.sh"
            ) >"$CHAOS_OUT" 2>&1 &
            SPAWN_WORKER_PID=$!
            if ! wait_spawn_worker_ready; then
                rc=1
                if ! stop_spawn_worker; then
                    SPAWN_SHUTDOWN_FAILED=1
                fi
            fi
            SPAWN_CRITICAL=0
            consume_pending_spawn_signal
            if [[ "$rc" == 0 ]]; then
                wait "$SPAWN_WORKER_PID" || rc=$?
            fi
            if ! extinguish_worker_sentinel "$SPAWN_SENTINEL_ID"; then
                rc=1
            fi
            SPAWN_WORKER_PID=""
            if [[ "$rc" -ne 0 ]]; then
                end_container_spawn
                echo "  launch failed (rc=$rc):" >&2
                tail -5 "$CHAOS_OUT" >&2
                fail "C5: training launch unavailable (rc=$rc)"
            else
                c5_binding=""
                c5_container_id=""
                if ! c5_container_id=$(pending_container_id 2>/dev/null); then
                    c5_container_id=""
                fi
                if [[ ! "$c5_container_id" =~ ^[0-9a-f]{64}$ ]] \
                        || ! c5_binding=$(podman inspect "$c5_container_id" \
                    --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
                    2>/dev/null); then
                    fail "C5: launched victim identity is unavailable"
                    c5_container_id=""
                else
                    IFS='|' read -r c5_actual_id c5_name c5_run c5_image \
                        c5_mount c5_extra \
                        <<< "$c5_binding"
                    if [[ -n "$c5_extra" \
                            || "$c5_actual_id" != "$c5_container_id" \
                            || ( "$c5_name" != alexnet-training \
                                && "$c5_name" != /alexnet-training ) \
                            || "$c5_run" != "$c5_run_id" \
                            || "$c5_image" != "$c5_image_id" \
                            || "$c5_mount" != "$c5_results" \
                            || ! -d "$c5_results" ]]; then
                        fail "C5: launched victim identity did not match this invocation"
                        c5_container_id=""
                    elif ! bind_owned_result_tree "$c5_results"; then
                        fail "C5: launched victim result tree could not be bound"
                        c5_container_id=""
                    elif ! register_owned_container "$c5_container_id" \
                            "$c5_run_id" "$c5_image_id" "$c5_results"; then
                        fail "C5: launched victim ownership could not be registered"
                        c5_container_id=""
                    else
                        c5_owned=1
                    fi
                fi
                end_container_spawn
            fi
            if [[ "$rc" == 0 ]]; then
                # Mojo compile dominates the first minutes; wait (bounded) until the
                # container is genuinely running. An early exit does not prove the
                # kill-mid-run case.
                st=created
                for _i in $(seq 1 66); do
                if [[ -z "$c5_container_id" ]]; then
                    st=unavailable
                    break
                elif ! c5_probe=$(podman inspect "$c5_container_id" \
                    --format '{{.Id}}|{{.Name}}|{{.State.Status}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}' \
                    2>/dev/null); then
                    st=unavailable
                    break
                fi
                IFS='|' read -r c5_actual_id c5_name st c5_run c5_extra \
                    <<< "$c5_probe"
                if [[ -n "$c5_extra" || "$c5_actual_id" != "$c5_container_id" \
                        || ( "$c5_name" != alexnet-training \
                            && "$c5_name" != /alexnet-training ) \
                        || "$c5_run" != "$c5_run_id" ]]; then
                    st=unavailable
                    break
                fi
                [[ "$st" == running ]] && break
                [[ "$st" == exited* ]] && break
                sleep 10
                done
                echo "  container state before kill: $st"
                if [[ "$st" == unavailable ]]; then
                    fail "C5: bound victim identity is unavailable; replacement was preserved"
                elif [[ "$st" != running ]]; then
                    fail "C5: victim was not running before kill (state '$st')"
                else
                kill_rc=0
                podman kill "$c5_container_id" >/dev/null 2>&1 || kill_rc=$?
                echo "  kill rc: $kill_rc (0 = SIGKILL delivered)"
                if [[ "$kill_rc" -ne 0 ]]; then
                    fail "C5: victim kill failed (rc=$kill_rc)"
                else
                    state_after=""
                    if ! state_after=$(podman inspect "$c5_container_id" \
                        --format '{{.Id}}|{{.Name}}|{{.State.Status}} exit={{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}' \
                        2>/dev/null); then
                        fail "C5: killed victim state is unavailable"
                    else
                        IFS='|' read -r c5_actual_id c5_name c5_state_after \
                            c5_run c5_extra <<< "$state_after"
                        if [[ -n "$c5_extra" \
                                || "$c5_actual_id" != "$c5_container_id" \
                                || ( "$c5_name" != alexnet-training \
                                    && "$c5_name" != /alexnet-training ) \
                                || "$c5_run" != "$c5_run_id" ]]; then
                            fail "C5: killed victim identity changed before readback"
                        elif [[ ! "$c5_state_after" =~ ^exited[[:space:]]+exit=[1-9][0-9]*$ ]]; then
                            fail "C5: killed victim did not report a non-zero exit (state '$c5_state_after')"
                        else
                            echo "  state after kill: $c5_state_after"
                            # The gate must detect the same non-zero exit.
                            rc=0
                            FLEET="$LOCAL_HOST" ALEXNET_RUN_ID="$c5_run_id" POLL_INTERVAL=5 \
                                bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" \
                                --timeout-minutes 1 --smoke >"$CHAOS_OUT" 2>&1 || rc=$?
                            echo "  gate rc: $rc (expect non-zero — killed container must NOT pass)"
                            tail -8 "$CHAOS_OUT" | sed 's/^/    /'
                            if [[ "$rc" -ne 0 ]] \
                                && grep -q "container(s) exited non-zero" "$CHAOS_OUT"; then
                                pass "C5: gate detected the killed container's non-zero exit"
                            else
                                fail "C5: gate rc=$rc — killed container was NOT detected as incomplete"
                            fi
                        fi
                    fi
                fi
                fi
            fi
        fi
        if [[ "$c5_owned" == 1 || "$PENDING_CONTAINER_RUN" == *-c5 ]]; then
            if cleanup_owned_fixture; then
                echo "  (C5 cleanup: owned container and results removed)" >&2
            else
                fail "C5: could not safely remove the owned fixture"
            fi
        fi
    fi
else
    info "C5 [LIVE]: skipped (set CHAOS_LIVE=1 to kill a real training container mid-run)"
fi

# ── C6: smoke gate must pass with --smoke, strict default must fail ────────
# The fixture is synthetic gate input, not training evidence. It has one run
# identity, a matching result mount, exit 0, and a completion marker. It has no
# weights.
info "C6: gate semantics — --smoke passes a smoke run, strict default fails it"
c6_run_id="$CHAOS_INVOCATION_ID-c6"
c6_results_root="$HOME/.cache/odysseus-alexnet-chaos"
c6_results="$c6_results_root/runs/$c6_run_id/$LOCAL_HOST"
c6_seeded=0
c6_results_created=0
c6_image_id=""
c6_container_id=""
c6_binding=""
c6_fixture_matches() {
    local actual_id actual_name actual_run actual_image actual_results extra
    local binding=$1
    [[ "$binding" != *$'\n'* ]] || return 1
    IFS='|' read -r actual_id actual_name actual_run actual_image \
        actual_results extra <<< "$binding"
    [[ -z "$extra" \
        && "$actual_id" == "$c6_container_id" \
        && ( "$actual_name" == alexnet-training \
            || "$actual_name" == /alexnet-training ) \
        && "$actual_run" == "$c6_run_id" \
        && "$actual_image" == "$c6_image_id" \
        && "$actual_results" == "$c6_results" ]]
}
c6_verify_fixture() {
    if [[ -z "$c6_container_id" ]]; then
        fail "C6: seeded fixture has no immutable container ID"
        return 1
    elif ! c6_binding=$(podman inspect "$c6_container_id" \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{.Image}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null); then
        fail "C6: seeded fixture identity is unavailable; replacement was preserved"
        return 1
    elif ! c6_fixture_matches "$c6_binding"; then
        fail "C6: seeded fixture identity changed; replacement was preserved"
        return 1
    fi
    return 0
}
c6_exists_rc=0
podman container exists alexnet-training 2>/dev/null || c6_exists_rc=$?
if [[ "$c6_exists_rc" == 0 ]]; then
    fail "C6: an existing alexnet-training container is not owned by this invocation"
elif [[ "$c6_exists_rc" != 1 ]]; then
    fail "C6: container existence state is unavailable (rc=$c6_exists_rc)"
elif ! podman image exists localhost/odyssey:dev 2>/dev/null; then
    fail "C6: exact local fixture image is unavailable; no pull attempted"
elif ! c6_image_id=$(podman image inspect localhost/odyssey:dev \
        --format '{{.Id}}' 2>/dev/null) \
        || [[ ! "$c6_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
    fail "C6: exact local fixture image identity is unavailable"
elif [[ -e "$c6_results" || -L "$c6_results" ]]; then
    fail "C6: synthetic result path already exists: $c6_results"
elif mkdir -p "$c6_results"; then
    c6_results_created=1
    if ! bind_owned_result_tree "$c6_results"; then
        fail "C6: could not bind the synthetic result path"
    else
        printf '%s\n' "=== Synthetic AlexNet gate fixture on $LOCAL_HOST ===" \
            > "$c6_results/training.log"
        c6_launch_rc=0
        c6_cid_name=c6.receipt
        c6_cid_path="$CHAOS_RECEIPT_DIR/c6.podman.cid"
        begin_container_spawn "$c6_run_id" "$c6_image_id" "$c6_results" "$c6_cid_name"
        (
            prepare_spawn_worker
            created_id=$(podman create --cidfile "$c6_cid_path" --name alexnet-training \
                --userns=keep-id \
                --label "io.homeric.alexnet.run-id=$c6_run_id" \
                -v "$c6_results:/results:Z" "$c6_image_id" \
                sh -c 'echo "Training complete!"')
            [[ "$created_id" != *$'\n'* && "$created_id" =~ ^[0-9a-f]{64}$ ]]
            printf '%s\n' "$created_id" >&12
            podman start "$created_id" >/dev/null
        ) >"$CHAOS_OUT" 2>&1 &
        SPAWN_WORKER_PID=$!
        if ! wait_spawn_worker_ready; then
            c6_launch_rc=1
            if ! stop_spawn_worker; then
                SPAWN_SHUTDOWN_FAILED=1
            fi
        fi
        SPAWN_CRITICAL=0
        consume_pending_spawn_signal
        if [[ "$c6_launch_rc" == 0 ]]; then
            wait "$SPAWN_WORKER_PID" || c6_launch_rc=$?
        fi
        if ! extinguish_worker_sentinel "$SPAWN_SENTINEL_ID"; then
            c6_launch_rc=1
        fi
        SPAWN_WORKER_PID=""
        c6_container_id=""
        if ! c6_container_id=$(pending_container_id 2>/dev/null); then
            c6_container_id=""
        fi
        if [[ "$c6_launch_rc" != 0 \
                || ! "$c6_container_id" =~ ^[0-9a-f]{64}$ ]]; then
            fail "C6: synthetic fixture launch did not return an immutable container ID"
        elif ! register_owned_container "$c6_container_id" "$c6_run_id" \
                "$c6_image_id" "$c6_results"; then
            fail "C6: synthetic fixture ownership could not be registered"
        fi
        end_container_spawn
        if [[ -n "$OWNED_CONTAINER_ID" ]] && c6_verify_fixture; then
            c6_seeded=1
        fi
    fi
else
    fail "C6: could not create the synthetic result path"
fi

if [[ "$c6_seeded" == 1 ]]; then
    if c6_verify_fixture; then
        rc=0
        FLEET="$LOCAL_HOST" ALEXNET_RUN_ID="$c6_run_id" \
            RESULTS_DIR=.cache/odysseus-alexnet-chaos POLL_INTERVAL=5 \
            bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" --timeout-minutes 1 --smoke \
            >"$CHAOS_OUT" 2>&1 || rc=$?
        if [[ "$rc" == 0 ]]; then
            pass "C6: smoke gate accepted the exact marker-only run"
        else
            fail "C6: smoke gate rejected the exact marker-only run (rc=$rc)"
        fi
    fi

    if c6_verify_fixture; then
        rc=0
        FLEET="$LOCAL_HOST" ALEXNET_RUN_ID="$c6_run_id" \
            RESULTS_DIR=.cache/odysseus-alexnet-chaos POLL_INTERVAL=5 \
            bash "$SCRIPT_DIR/alexnet-fleet-wait.sh" --timeout-minutes 1 \
            >"$CHAOS_OUT" 2>&1 || rc=$?
        if [[ "$rc" == 1 ]]; then
            pass "C6b: strict gate rejected the same run without current weights"
        else
            fail "C6b: strict gate returned $rc; expected current-weight failure"
        fi
    fi
fi

# ── C7: teardown idempotency (removed -> absent, both rc 0) ────────────────
info "C7: teardown succeeds once for removal and again for absence"
if [[ "$c6_seeded" == 1 ]]; then
    for c7_expectation in removal absence; do
        if [[ "$c7_expectation" == removal ]] && ! c6_verify_fixture; then
            break
        fi
        rc=0
        timeout "$CHAOS_TIMEOUT" env \
            FLEET="$LOCAL_HOST" \
            ALEXNET_TEARDOWN_APPROVED_FLEET="$LOCAL_HOST" \
            ALEXNET_RUN_ID="$c6_run_id" \
            RESULTS_DIR=.cache/odysseus-alexnet-chaos \
            bash "$SCRIPT_DIR/alexnet-fleet-teardown.sh" \
            >"$CHAOS_OUT" 2>&1 || rc=$?
        if [[ "$rc" == 0 ]]; then
            pass "C7: teardown verified $c7_expectation"
        elif [[ "$rc" == 124 ]]; then
            fail "C7: teardown hung while verifying $c7_expectation"
        else
            fail "C7: teardown failed while verifying $c7_expectation (rc=$rc)"
        fi
        echo "  teardown output (tail):"
        tail -4 "$CHAOS_OUT" | sed 's/^/    /'
    done
else
    fail "C7: C6 did not create the teardown fixture"
fi
if [[ "$c6_results_created" == 1 || "$c6_seeded" == 1 \
        || "$PENDING_CONTAINER_RUN" == *-c6 ]]; then
    if ! cleanup_owned_fixture; then
        fail "C7: could not safely remove the exact synthetic fixture"
    fi
fi

# ── Summary ──
echo ""
echo "=== Chaos Suite Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
    echo "Failed cases:"
    for c in "${FAILED_CASES[@]}"; do
        echo "  - $c"
    done
    exit 1
fi
echo "All enabled cases passed."
