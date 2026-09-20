#!/usr/bin/env bash
# e2e/alexnet-collect-results.sh — exact AlexNet fleet result collection
#
# Preflight every requested current-run source and transfer each host into an
# invocation-only staging directory. Publish each verified safe tree for
# forensics, but report failure unless every requested transfer succeeds. An
# existing central destination is never treated as a new collection.

set -euo pipefail
set -m

active_worker_pids=("")
active_worker_sentinel_ids=("")
active_worker_sentinel_fds=("")
worker_controller_pid=$$
worker_launch_critical=0
pending_worker_signal_name=""
pending_worker_signal_status=0
CREATED_WORKER_SENTINEL_PATH=""
CREATED_WORKER_SENTINEL_ID=""
CREATED_WORKER_SENTINEL_FD=""
next_worker_sentinel_fd=40

# Bash 3.2 has no {var} descriptor syntax. Only a controller-generated,
# range-checked integer is interpolated; the hostile pathname remains a
# quoted shell variable when the fixed redirection is evaluated.
open_worker_sentinel_descriptor() {
    local descriptor=$1 candidate=$2
    [[ "$descriptor" =~ ^[0-9]+$ \
        && "$descriptor" -ge 40 && "$descriptor" -le 255 ]] || return 1
    eval "exec ${descriptor}> \"\$candidate\""
}

close_worker_sentinel_descriptor() {
    local descriptor=$1
    [[ "$descriptor" =~ ^[0-9]+$ \
        && "$descriptor" -ge 40 && "$descriptor" -le 255 ]] || return 1
    eval "exec ${descriptor}>&-"
}

inherit_worker_sentinel_descriptor() {
    local descriptor=$1
    [[ "$descriptor" =~ ^[0-9]+$ \
        && "$descriptor" -ge 40 && "$descriptor" -le 255 ]] || return 1
    eval "exec 19>&${descriptor}"
}

remember_worker_pid() {
    active_worker_pids+=("$1")
    active_worker_sentinel_ids+=("$2")
    active_worker_sentinel_fds+=("$3")
}

forget_worker_pid() {
    local completed_pid=$1
    local active_index
    for active_index in "${!active_worker_pids[@]}"; do
        if [[ "${active_worker_pids[$active_index]}" == "$completed_pid" ]]; then
            local descriptor=${active_worker_sentinel_fds[$active_index]}
            if ! close_worker_sentinel_descriptor "$descriptor"; then
                return 1
            fi
            unset 'active_worker_pids[active_index]'
            unset 'active_worker_sentinel_ids[active_index]'
            unset 'active_worker_sentinel_fds[active_index]'
            return
        fi
    done
    return 1
}

create_worker_sentinel() {
    local directory=$1 tag=$2 attempt candidate descriptor identity
    local saved_umask noclobber_was_set=0
    CREATED_WORKER_SENTINEL_PATH=""
    CREATED_WORKER_SENTINEL_ID=""
    CREATED_WORKER_SENTINEL_FD=""
    saved_umask=$(umask)
    [[ -o noclobber ]] && noclobber_was_set=1
    umask 077
    set -o noclobber
    for ((attempt = 0; attempt < 128; attempt++)); do
        candidate="$directory/.worker-sentinel-$tag.$$.$RANDOM.$attempt"
        descriptor=$next_worker_sentinel_fd
        ((next_worker_sentinel_fd += 1))
        if open_worker_sentinel_descriptor "$descriptor" "$candidate"; then
            break
        fi
        descriptor=""
    done
    if [[ "$noclobber_was_set" == 0 ]]; then
        set +o noclobber
    fi
    umask "$saved_umask"
    [[ "$descriptor" =~ ^[0-9]+$ ]] || return 1
    if ! identity=$(python3 -I -E -c '
import os, stat, sys
descriptor = int(sys.argv[1])
opened = os.fstat(descriptor)
named = os.stat(sys.argv[2], follow_symlinks=False)
key = lambda value: (value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode))
if (not stat.S_ISREG(opened.st_mode) or opened.st_nlink != 1
        or opened.st_uid != os.geteuid() or key(opened) != key(named)
        or stat.S_IMODE(opened.st_mode) & 0o077):
    raise SystemExit(1)
print(f"{opened.st_dev}:{opened.st_ino}")
' "$descriptor" "$candidate"); then
        close_worker_sentinel_descriptor "$descriptor"
        return 1
    fi
    CREATED_WORKER_SENTINEL_PATH=$candidate
    CREATED_WORKER_SENTINEL_ID=$identity
    CREATED_WORKER_SENTINEL_FD=$descriptor
}

prepare_worker_sentinel() {
    local own_fd=$1 expected=$2 descriptor actual
    shift 2
    for descriptor in "$@"; do
        [[ "$descriptor" =~ ^[0-9]+$ ]] || return 1
        if [[ "$descriptor" != "$own_fd" ]]; then
            close_worker_sentinel_descriptor "$descriptor"
        fi
    done
    if [[ "$own_fd" != 19 ]]; then
        inherit_worker_sentinel_descriptor "$own_fd"
        descriptor=$own_fd
        close_worker_sentinel_descriptor "$descriptor"
    fi
    actual=$(python3 -I -E -c '
import os, stat
value = os.fstat(19)
if not stat.S_ISREG(value.st_mode): raise SystemExit(1)
print(f"{value.st_dev}:{value.st_ino}")
') || return 1
    [[ "$actual" == "$expected" ]] || return 1
    printf R >&19
}

wait_worker_sentinel_ready() {
    local worker_pid=$1 descriptor=$2 expected=$3 attempt
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
' "$descriptor" "$expected"; then
            return 0
        fi
        [[ "$pending_worker_signal_status" == 0 ]] || return 1
    done
    return 1
}

worker_sentinel_holders() {
    local expected=$1 output rc=0 holder
    [[ "$expected" =~ ^[0-9]+:[0-9]+$ ]] || return 2
    # This function runs in command substitution. Drop the substitution
    # shell's inherited controller descriptors before its scanner starts, or
    # that short-lived shell would report itself as an escaped worker.
    for holder in "${active_worker_sentinel_fds[@]}"; do
        [[ -n "$holder" ]] || continue
        close_worker_sentinel_descriptor "$holder" || return 2
    done
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
' "$expected" "$worker_controller_pid"
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
' "$expected" "$worker_controller_pid" <<< "$output"
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

retire_worker_pid() {
    local worker_pid=$1 expected=$2
    extinguish_worker_sentinel "$expected" || return 1
    forget_worker_pid "$worker_pid"
}

stop_owned_workers() {
    local worker_pid expected shutdown_failed=0
    for expected in "${active_worker_sentinel_ids[@]}"; do
        [[ -n "$expected" ]] || continue
        extinguish_worker_sentinel "$expected" || shutdown_failed=1
    done
    [[ "$shutdown_failed" == 0 ]] || return 1
    for worker_pid in $(jobs -pr 2>/dev/null); do
        if ! wait "$worker_pid" 2>/dev/null; then :; fi
    done
    active_worker_pids=("")
    active_worker_sentinel_ids=("")
    for expected in "${active_worker_sentinel_fds[@]}"; do
        [[ -n "$expected" ]] || continue
        local descriptor=$expected
        close_worker_sentinel_descriptor "$descriptor"
    done
    active_worker_sentinel_fds=("")
    return 0
}

handle_worker_signal() {
    local signal_name=$1
    local exit_status=$2
    if [[ "$worker_launch_critical" == 1 ]]; then
        pending_worker_signal_name=$signal_name
        pending_worker_signal_status=$exit_status
        return 0
    fi
    trap ':' INT TERM HUP
    echo "ERROR: received SIG$signal_name; stopping active collection workers." >&2
    if ! stop_owned_workers; then
        echo "ERROR: worker extinction or reap could not be verified; collection staging was retained." >&2
    fi
    exit "$exit_status"
}

honor_pending_worker_signal() {
    local signal_name=$pending_worker_signal_name
    local exit_status=$pending_worker_signal_status
    if [[ "$exit_status" != 0 ]]; then
        pending_worker_signal_name=""
        pending_worker_signal_status=0
        handle_worker_signal "$signal_name" "$exit_status"
    fi
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAFE_FS="$SCRIPT_DIR/alexnet-collect-fs.py"
DEFAULT_FLEET="epimetheus apollo aeolus hephaestus"
if [[ ${FLEET+x} == x ]]; then
    fleet_was_explicit=1
    requested_fleet=$FLEET
else
    fleet_was_explicit=0
    requested_fleet=$DEFAULT_FLEET
fi
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus}"
if [[ "$fleet_was_explicit" == 1 ]]; then
    FLEET=$requested_fleet
fi

CENTRAL_DIR="${CENTRAL_DIR:-$HOME/alexnet-fleet-results}"
REMOTE_RESULTS_DIR="${REMOTE_RESULTS_DIR:-alexnet-results}"
ALEXNET_RUN_STATE_DIR="${ALEXNET_RUN_STATE_DIR:-$HOME/.cache/odysseus-alexnet}"

usage_error() {
    echo "ERROR: $*" >&2
    exit 2
}

if ! PYTHON_BIN=$(command -v python3); then
    usage_error "python3 is required for safe result publication."
fi
LSOF_BIN=""
if discovered_lsof=$(command -v lsof 2>/dev/null); then
    LSOF_BIN=$discovered_lsof
fi
[[ -n "$LSOF_BIN" ]] || LSOF_BIN=/usr/sbin/lsof
[[ -x "$LSOF_BIN" ]] \
    || usage_error "lsof is required for descriptor-bound worker extinction."
[[ -f "$SAFE_FS" && ! -L "$SAFE_FS" ]] \
    || usage_error "the safe result filesystem helper is unavailable."

if ! exec 10< "$SAFE_FS"; then
    usage_error "the safe result filesystem helper could not be bound."
fi
if ! SAFE_FS_DIGEST=$("$PYTHON_BIN" -I -E -c '
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
opened = os.fstat(descriptor)
named = os.lstat(sys.argv[2])
if (
    not stat.S_ISREG(opened.st_mode)
    or not stat.S_ISREG(named.st_mode)
    or (opened.st_dev, opened.st_ino) != (named.st_dev, named.st_ino)
):
    raise SystemExit(1)
parts = []
offset = 0
while offset < opened.st_size:
    part = os.pread(descriptor, min(65536, opened.st_size - offset), offset)
    if not part:
        raise SystemExit(1)
    parts.append(part)
    offset += len(part)
after = os.fstat(descriptor)
if (
    (opened.st_dev, opened.st_ino, opened.st_size)
    != (after.st_dev, after.st_ino, after.st_size)
):
    raise SystemExit(1)
print(hashlib.sha256(b"".join(parts)).hexdigest())
' 10 "$SAFE_FS"); then
    exec 10<&-
    usage_error "the safe result filesystem helper changed while binding."
fi
[[ "$SAFE_FS_DIGEST" =~ ^[0-9a-f]{64}$ ]] \
    || usage_error "the safe result filesystem helper digest is invalid."
SAFE_FS_FD=10

result_filesystem() {
    "$PYTHON_BIN" -I -E -c '
import hashlib
import os
import stat
import sys

descriptor = int(sys.argv[1])
expected_digest = sys.argv[2]
before = os.fstat(descriptor)
if not stat.S_ISREG(before.st_mode):
    raise SystemExit("bound result helper is not a regular file")
parts = []
offset = 0
while offset < before.st_size:
    part = os.pread(descriptor, min(65536, before.st_size - offset), offset)
    if not part:
        raise SystemExit("bound result helper became unreadable")
    parts.append(part)
    offset += len(part)
after = os.fstat(descriptor)
if (
    (before.st_dev, before.st_ino, before.st_size)
    != (after.st_dev, after.st_ino, after.st_size)
):
    raise SystemExit("bound result helper changed while reading")
source = b"".join(parts)
if hashlib.sha256(source).hexdigest() != expected_digest:
    raise SystemExit("bound result helper content digest changed")
display_name = f"<bound-result-helper:{before.st_dev}:{before.st_ino}>"
sys.argv = [display_name, *sys.argv[3:]]
scope = {"__name__": "__main__", "__file__": display_name}
exec(compile(source, display_name, "exec"), scope, scope)
' "$SAFE_FS_FD" "$SAFE_FS_DIGEST" "$@"
}

[[ "$REMOTE_RESULTS_DIR" =~ ^[A-Za-z0-9._/-]+$ \
        && "$REMOTE_RESULTS_DIR" != /* \
        && "/$REMOTE_RESULTS_DIR/" != *"/../"* \
        && "/$REMOTE_RESULTS_DIR/" != *"/./"* ]] \
    || usage_error "REMOTE_RESULTS_DIR must be a safe relative path."
[[ -n "$CENTRAL_DIR" && "$CENTRAL_DIR" != / && "$CENTRAL_DIR" != "$HOME" \
        && "$CENTRAL_DIR" != *$'\n'* \
        && "/$CENTRAL_DIR/" != *"/../"* ]] \
    || usage_error "CENTRAL_DIR must identify a narrow result directory."

if [[ "$CENTRAL_DIR" != /* ]]; then
    central_path="$PWD/${CENTRAL_DIR#./}"
else
    central_path=${CENTRAL_DIR%/}
fi
local_source_root="$HOME/$REMOTE_RESULTS_DIR"
case "$central_path/" in
    "$local_source_root/"*)
        usage_error "CENTRAL_DIR must not be inside the source result tree."
        ;;
esac
if [[ -e "$central_path" || -L "$central_path" ]]; then
    usage_error "CENTRAL_DIR already exists; choose a new collection directory: $central_path."
fi

read -r -a fleet_hosts <<< "$FLEET"
if [[ ${#fleet_hosts[@]} -eq 0 ]]; then
    usage_error "FLEET must contain at least one host."
fi
canonical_fleet="${fleet_hosts[*]}"
echo "Exact fleet: $canonical_fleet"
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    [[ "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]] \
        || usage_error "invalid host token in FLEET: '$host'."
    for ((prior_index = 0; prior_index < host_index; prior_index++)); do
        if [[ "${fleet_hosts[$prior_index]}" == "$host" ]]; then
            usage_error "duplicate host in FLEET: '$host'."
        fi
    done
done

if ! local_host=$(hostname); then
    usage_error "could not determine the local host."
fi

if [[ ${ALEXNET_RUN_ID:-} != "" ]]; then
    [[ "$ALEXNET_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || usage_error "ALEXNET_RUN_ID must be a safe identifier of at most 128 characters."
else
    run_state_file="$ALEXNET_RUN_STATE_DIR/current-run.tsv"
    if [[ ! -f "$run_state_file" || -L "$run_state_file" ]]; then
        usage_error "current run state is unavailable; set ALEXNET_RUN_ID to the exact deployed run."
    fi
    if ! IFS=$'\t' read -r state_version state_run_id state_status state_fleet \
        < "$run_state_file"; then
        usage_error "current run state is unreadable."
    fi
    [[ "$state_version" == 1 \
            && "$state_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ \
            && ("$state_status" == launching || "$state_status" == launched) \
            && "$state_fleet" == "$canonical_fleet" ]] \
        || usage_error "current run state does not identify the exact fleet."
    ALEXNET_RUN_ID=$state_run_id
fi
run_id=$ALEXNET_RUN_ID

remote_targets=0
for host in "${fleet_hosts[@]}"; do
    if [[ "$host" != "$local_host" && "$host" != localhost ]]; then
        remote_targets=$((remote_targets + 1))
    fi
done

tailscale_json=""
if [[ "$remote_targets" -gt 0 ]]; then
    for dependency in tailscale jq ssh timeout rsync; do
        command -v "$dependency" >/dev/null 2>&1 \
            || usage_error "$dependency is required for remote result collection."
    done
    if ! tailscale_json=$(tailscale status --json); then
        usage_error "tailscale inventory readback failed; no output was created."
    fi
fi

resolved_targets=()
resolution_failed=0
for host in "${fleet_hosts[@]}"; do
    if [[ "$host" == "$local_host" || "$host" == localhost ]]; then
        resolved_targets+=(localhost)
        continue
    fi
    resolved_ip=""
    if resolved_ip=$(printf '%s\n' "$tailscale_json" | jq -er --arg h "$host" '
        [(.Peer // {}) | to_entries[] | .value
          | select(.HostName == $h and .Online == true)
          | .TailscaleIPs[0]
          | select(type == "string" and length > 0)]
        | if length == 1 then .[0] else empty end
    '); then
        :
    else
        resolved_ip=""
    fi
    if [[ -z "$resolved_ip" || "$resolved_ip" == *$'\n'* \
            || ! "$resolved_ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        echo "ERROR: cannot resolve one current Tailscale IP for '$host'." >&2
        resolution_failed=1
        resolved_targets+=(unresolved)
    else
        resolved_targets+=("$resolved_ip")
    fi
done
if [[ "$resolution_failed" != 0 ]]; then
    echo "ERROR: fleet resolution is incomplete; no output was created." >&2
    exit 2
fi
for ((host_index = 0; host_index < ${#resolved_targets[@]}; host_index++)); do
    for ((prior_index = 0; prior_index < host_index; prior_index++)); do
        if [[ "${resolved_targets[$prior_index]}" == "${resolved_targets[$host_index]}" ]]; then
            usage_error "hosts '${fleet_hosts[$prior_index]}' and '${fleet_hosts[$host_index]}' resolve to duplicate resolved target '${resolved_targets[$host_index]}'; no output was created."
        fi
    done
done

result_hosts=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    if [[ "${resolved_targets[$host_index]}" == localhost ]]; then
        result_hosts+=("$local_host")
    else
        result_hosts+=("${fleet_hosts[$host_index]}")
    fi
done

SSH_BASE=(timeout 15 ssh -o ConnectTimeout=5 -o BatchMode=yes)
preflight_failed=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    result_host=${result_hosts[$host_index]}
    target=${resolved_targets[$host_index]}
    if [[ "$target" == localhost ]]; then
        source_path="$HOME/$REMOTE_RESULTS_DIR/runs/$run_id/$result_host"
        launch_log="$source_path/training.log"
        if [[ ! -L "$HOME/$REMOTE_RESULTS_DIR" \
                && ! -L "$HOME/$REMOTE_RESULTS_DIR/runs" \
                && ! -L "$HOME/$REMOTE_RESULTS_DIR/runs/$run_id" \
                && ! -L "$source_path" \
                && -d "$source_path" \
                && -f "$launch_log" \
                && ! -L "$launch_log" \
                && -n "$(find "$source_path" -type f -print -quit 2>/dev/null)" ]] \
            && grep -Fxq "Run ID:   $run_id" "$launch_log"; then
            echo "$host: source preflight verified"
        else
            echo "$host: current run source preflight failed (missing or empty: $source_path)" >&2
            preflight_failed=1
        fi
    elif "${SSH_BASE[@]}" "$target" \
        "bash -s -- '$REMOTE_RESULTS_DIR' '$run_id' '$result_host'" >/dev/null <<'REMOTE'
set -eu
results_dir=$1
run_id=$2
host=$3
source_path="$HOME/$results_dir/runs/$run_id/$host"
launch_log="$source_path/training.log"
test ! -L "$HOME/$results_dir"
test ! -L "$HOME/$results_dir/runs"
test ! -L "$HOME/$results_dir/runs/$run_id"
test ! -L "$source_path"
test -d "$source_path"
test -f "$launch_log"
test ! -L "$launch_log"
grep -Fxq "Run ID:   $run_id" "$launch_log"
test -n "$(find "$source_path" -type f -print -quit)"
REMOTE
    then
        echo "$host: source preflight verified"
    else
        echo "$host: current run source preflight failed (remote source missing, empty, or unreadable)" >&2
        preflight_failed=1
    fi
done
if [[ "$preflight_failed" != 0 ]]; then
    echo "ERROR: current run source preflight failed; no output was created." >&2
    exit 1
fi

central_parent=$(dirname "$central_path")
central_name=${central_path##*/}
if ! prepare_info=$(result_filesystem prepare \
        "$central_parent" "$central_name"); then
    usage_error "could not bind collection staging beside CENTRAL_DIR."
fi
IFS=$'\t' read -r parent_identity staging_name staging_identity \
    data_identity receipts_identity <<< "$prepare_info"
if [[ -z "$parent_identity" || -z "$staging_name" \
        || -z "$staging_identity" || -z "$data_identity" \
        || -z "$receipts_identity" ]]; then
    usage_error "safe result staging returned an incomplete binding."
fi
staging_root="$central_parent/$staging_name"
if ! exec 9< "$central_parent" \
        || ! exec 8< "$staging_root" \
        || ! exec 7< "$staging_root/data" \
        || ! exec 6< "$staging_root/receipts"; then
    usage_error "could not open the bound collection directories."
fi
if ! result_filesystem verify-bindings \
        "$central_parent" "$parent_identity" 9 \
        "$staging_name" "$staging_identity" 8 \
        "$data_identity" 7 "$receipts_identity" 6; then
    usage_error "collection directory binding changed before transfer."
fi

transfer_one() {
    local index=$1
    local host=${fleet_hosts[$index]}
    local result_host=${result_hosts[$index]}
    local target=${resolved_targets[$index]}
    local host_identity
    local receipt_name="$index.detail"
    if ! host_identity=$(result_filesystem create-host 7 "$host"); then
        return 1
    fi
    if [[ "$target" == localhost ]]; then
        result_filesystem transfer-local \
            7 "$host" "$host_identity" 6 "$receipt_name" \
            "$HOME/$REMOTE_RESULTS_DIR/runs/$run_id/$result_host"
    else
        result_filesystem transfer-remote \
            7 "$host" "$host_identity" 6 "$receipt_name" \
            "$target:~/$REMOTE_RESULTS_DIR/runs/$run_id/$result_host/"
    fi
}

trap 'handle_worker_signal INT 130' INT
trap 'handle_worker_signal TERM 143' TERM
trap 'handle_worker_signal HUP 129' HUP

pids=()
worker_sentinel_paths=()
worker_sentinel_ids=()
worker_sentinel_fds=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    create_worker_sentinel "$staging_root" "transfer-$host_index" \
        || usage_error "could not create a bound worker ownership sentinel."
    worker_sentinel=$CREATED_WORKER_SENTINEL_PATH
    worker_sentinel_id=$CREATED_WORKER_SENTINEL_ID
    worker_sentinel_fd=$CREATED_WORKER_SENTINEL_FD
    worker_sentinel_paths+=("$worker_sentinel")
    worker_sentinel_ids+=("$worker_sentinel_id")
    worker_sentinel_fds+=("$worker_sentinel_fd")
done

for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    worker_sentinel=${worker_sentinel_paths[$host_index]}
    worker_sentinel_id=${worker_sentinel_ids[$host_index]}
    worker_sentinel_fd=${worker_sentinel_fds[$host_index]}
    worker_launch_critical=1
    (
        prepare_worker_sentinel "$worker_sentinel_fd" "$worker_sentinel_id" \
            "${worker_sentinel_fds[@]}"
        transfer_one "$host_index"
    ) &
    worker_pid=$!
    pids+=("$worker_pid")
    remember_worker_pid "$worker_pid" "$worker_sentinel_id" \
        "$worker_sentinel_fd"
    if ! wait_worker_sentinel_ready "$worker_pid" "$worker_sentinel_fd" \
            "$worker_sentinel_id"; then
        if ! extinguish_worker_sentinel "$worker_sentinel_id"; then
            echo "ERROR: collection worker failed before readiness and could not be extinguished; staging retained." >&2
        else
            if ! wait "$worker_pid" 2>/dev/null; then :; fi
            if ! forget_worker_pid "$worker_pid"; then
                echo "ERROR: collection worker sentinel could not be retired; staging retained." >&2
            fi
        fi
        worker_launch_critical=0
        honor_pending_worker_signal
        echo "ERROR: collection worker failed before its readiness receipt." >&2
        exit 1
    fi
    worker_launch_critical=0
    honor_pending_worker_signal
done

transfer_failed=0
worker_extinction_failed=0
transfer_results=()
host_identities=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    receipt_name="$host_index.detail"
    transfer_rc=0
    wait "${pids[$host_index]}" || transfer_rc=$?
    worker_extinct=0
    if retire_worker_pid "${pids[$host_index]}" \
            "${worker_sentinel_ids[$host_index]}"; then
        worker_extinct=1
    fi
    if [[ "$transfer_rc" == 0 && "$worker_extinct" == 1 ]] \
            && host_identity=$(result_filesystem identify-host \
                7 "$host" "$run_id"); then
        echo "$host: transfer verified"
        transfer_results+=(1)
        host_identities+=("$host_identity")
    else
        if [[ "$worker_extinct" == 0 ]]; then
            echo "$host: escaped transfer worker survived; staging retained" >&2
            worker_extinction_failed=1
            if [[ "$transfer_rc" == 0 ]]; then
                transfer_rc=1
            fi
        elif [[ "$transfer_rc" == 0 ]]; then
            transfer_rc=1
        fi
        echo "$host: transfer failed (exit $transfer_rc)" >&2
        transfer_detail=""
        if ! transfer_detail=$(result_filesystem read-receipt \
                6 "$receipt_name" 2>/dev/null); then
            transfer_detail="receipt unavailable"
        fi
        if [[ -n "$transfer_detail" ]]; then
            while IFS= read -r detail_line; do
                echo "  $detail_line" >&2
            done <<< "$transfer_detail"
        fi
        transfer_failed=1
        transfer_results+=(0)
        host_identities+=("")
    fi
done

if [[ "$worker_extinction_failed" != 0 ]]; then
    echo "ERROR: transfer worker extinction was not verified; collection staging was retained: $staging_root" >&2
    exit 1
fi

if ! central_identity=$(result_filesystem create-central \
        "$central_parent" "$parent_identity" 9 "$central_name"); then
    echo "ERROR: collection parent changed before publication: $central_parent." >&2
    exit 1
fi
if ! exec 5< "$central_path" \
        || ! result_filesystem verify-central \
            "$central_parent" "$parent_identity" 9 \
            "$central_name" "$central_identity" 5; then
    echo "ERROR: could not open the bound collection destination: $central_path." >&2
    exit 1
fi
publish_failed=0
published_count=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    if [[ "${transfer_results[$host_index]}" == 0 ]]; then
        continue
    fi
    if result_filesystem publish-host 7 5 "$host" \
            "${host_identities[$host_index]}" "$run_id"; then
        echo "$host: collected -> $central_path/$host"
        published_count=$((published_count + 1))
    else
        echo "$host: publish failed -> $central_path/$host" >&2
        publish_failed=1
    fi
done

echo "Collection staging retained for safe manual review: $staging_root" >&2

if [[ "$transfer_failed" != 0 || "$publish_failed" != 0 ]]; then
    echo "ERROR: fleet collection was incomplete; published $published_count fresh result set(s) and withheld terminal completion." >&2
    exit 1
fi

echo "=== Fleet result receipts ==="
for host in "${fleet_hosts[@]}"; do
    if ! receipt=$(result_filesystem receipt 5 "$host" "$run_id"); then
        echo "ERROR: published result receipt failed for '$host'." >&2
        exit 1
    fi
    echo "$host: $receipt"
done
if ! result_filesystem verify-central \
        "$central_parent" "$parent_identity" 9 \
        "$central_name" "$central_identity" 5; then
    echo "ERROR: collection destination binding changed before completion." >&2
    exit 1
fi
echo "Collection transfer verified for ${#fleet_hosts[@]} requested host(s) in run '$run_id': $central_path"
