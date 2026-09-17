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

remember_worker_pid() {
    active_worker_pids+=("$1")
}

forget_worker_pid() {
    local completed_pid=$1
    local active_index
    for active_index in "${!active_worker_pids[@]}"; do
        if [[ "${active_worker_pids[$active_index]}" == "$completed_pid" ]]; then
            unset 'active_worker_pids[active_index]'
            return
        fi
    done
}

worker_sentinel_holders() {
    local sentinel=$1 output rc=0
    output=$("$LSOF_BIN" -t -- "$sentinel" 2>/dev/null) || rc=$?
    [[ "$rc" == 0 || "$rc" == 1 ]] || return 2
    if [[ "$rc" == 0 ]]; then
        printf '%s\n' "$output" | awk '/^[0-9]+$/ && !seen[$0]++'
    fi
    return 0
}

signal_worker_holder() {
    local holder=$1 sentinel=$2 signal_name=$3
    if [[ "$(uname -s)" == Linux ]]; then
        python3 -I -E -c '
import os, signal, sys
pid, path, signal_name = int(sys.argv[1]), sys.argv[2], sys.argv[3]
if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"): raise SystemExit(2)
expected = os.stat(path, follow_symlinks=False)
pidfd = os.pidfd_open(pid)
try:
    held = any((value.st_dev, value.st_ino) == (expected.st_dev, expected.st_ino)
        for name in os.listdir(f"/proc/{pid}/fd")
        for value in [os.stat(f"/proc/{pid}/fd/{name}")])
    if held: signal.pidfd_send_signal(pidfd, getattr(signal, "SIG" + signal_name))
finally: os.close(pidfd)
' "$holder" "$sentinel" "$signal_name"
    elif "$LSOF_BIN" -t -a -p "$holder" -- "$sentinel" 2>/dev/null \
            | grep -Fxq "$holder"; then
        kill -"$signal_name" "$holder" 2>/dev/null
    fi
}

extinguish_worker_sentinel() {
    local sentinel=$1 signal_name holder holders attempt rc
    [[ -f "$sentinel" && ! -L "$sentinel" ]] || return 1
    for signal_name in TERM KILL; do
        for ((attempt = 0; attempt < 20; attempt++)); do
            rc=0
            holders=$(worker_sentinel_holders "$sentinel") || rc=$?
            [[ "$rc" == 0 ]] || return 1
            [[ -n "$holders" ]] || return 0
            while IFS= read -r holder; do
                [[ "$holder" =~ ^[0-9]+$ ]] || continue
                signal_worker_holder "$holder" "$sentinel" "$signal_name" || true
            done <<< "$holders"
            sleep 0.1 || true
        done
    done
    rc=0
    holders=$(worker_sentinel_holders "$sentinel") || rc=$?
    [[ "$rc" == 0 && -z "$holders" ]]
}

stop_owned_workers() {
    local worker_pid sentinel shutdown_failed=0
    for sentinel in "$staging_root"/.worker-sentinel-*; do
        [[ -e "$sentinel" ]] || continue
        extinguish_worker_sentinel "$sentinel" || shutdown_failed=1
    done
    for worker_pid in $(jobs -pr 2>/dev/null); do
        wait "$worker_pid" 2>/dev/null || true
    done
    [[ "$shutdown_failed" == 0 ]] || return 1
    active_worker_pids=("")
    return 0
}

handle_worker_signal() {
    local signal_name=$1
    local exit_status=$2
    trap ':' INT TERM HUP
    echo "ERROR: received SIG$signal_name; stopping active collection workers." >&2
    if ! stop_owned_workers; then
        echo "ERROR: worker extinction or reap could not be verified; collection staging was retained." >&2
    fi
    exit "$exit_status"
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
LSOF_BIN=$(command -v lsof 2>/dev/null || true)
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
worker_sentinels=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    worker_sentinel=$(mktemp "$staging_root/.worker-sentinel-transfer-${host_index}.XXXXXX") \
        || usage_error "could not create a worker ownership sentinel."
    chmod 600 "$worker_sentinel"
    worker_sentinels+=("$worker_sentinel")
    ( exec 19< "$worker_sentinel"; transfer_one "$host_index" ) &
    pids+=("$!")
    remember_worker_pid "$!"
done

transfer_failed=0
transfer_results=()
host_identities=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    receipt_name="$host_index.detail"
    if wait "${pids[$host_index]}" \
            && host_identity=$(result_filesystem identify-host \
                7 "$host" "$run_id") \
            && extinguish_worker_sentinel "${worker_sentinels[$host_index]}"; then
        forget_worker_pid "${pids[$host_index]}"
        echo "$host: transfer verified"
        transfer_results+=(1)
        host_identities+=("$host_identity")
    else
        transfer_rc=$?
        forget_worker_pid "${pids[$host_index]}"
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
        extinguish_worker_sentinel "${worker_sentinels[$host_index]}" \
            || transfer_failed=1
    fi
done

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
