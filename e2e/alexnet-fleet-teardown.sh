#!/usr/bin/env bash
# e2e/alexnet-fleet-teardown.sh — verified AlexNet container teardown
#
# The protected manual workflow defines the default fleet. Interactive use must
# confirm that exact fleet; non-interactive use must provide the same ordered
# host list in ALEXNET_TEARDOWN_APPROVED_FLEET.
#
# Usage (from the Odysseus root on the approved central host):
#   just alexnet-fleet-teardown
#   FLEET="epimetheus apollo" \
#     ALEXNET_TEARDOWN_APPROVED_FLEET="epimetheus apollo" \
#     ALEXNET_RUN_ID="<exact-deployed-run-id>" \
#     just alexnet-fleet-teardown
#
# This operation removes only the `alexnet-training` container whose immutable
# ID, run label, and result mount match the exact approved run. It never removes
# distributed scripts or training results. Those require a separate,
# exact-target retention/removal procedure and approval.

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
    for sentinel in "$receipt_dir"/.worker-sentinel-*; do
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

if [[ ${FLEET+x} == x ]]; then
    fleet_was_explicit=1
    requested_fleet=$FLEET
else
    fleet_was_explicit=0
fi
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus}"
if [[ "$fleet_was_explicit" == "0" ]]; then
    requested_fleet=$FLEET
fi
RESULTS_DIR="${RESULTS_DIR:-alexnet-results}"

if [[ ! "${ALEXNET_RUN_ID:-}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; then
    echo "ERROR: ALEXNET_RUN_ID must name the exact approved run with a safe identifier of at most 128 characters." >&2
    exit 2
fi
run_id=$ALEXNET_RUN_ID
if [[ ! "$RESULTS_DIR" =~ ^[A-Za-z0-9._/-]+$ \
        || "$RESULTS_DIR" == /* \
        || "/$RESULTS_DIR/" == *"/../"* \
        || "/$RESULTS_DIR/" == *"/./"* ]]; then
    echo "ERROR: RESULTS_DIR must be a safe relative path." >&2
    exit 2
fi

if [[ "${CLEAN_SCRIPTS:-0}" != "0" ]]; then
    echo "ERROR: CLEAN_SCRIPTS is unavailable; helper-script removal requires a separate exact-target procedure." >&2
    exit 2
fi
LSOF_BIN=$(command -v lsof 2>/dev/null || true)
[[ -n "$LSOF_BIN" ]] || LSOF_BIN=/usr/sbin/lsof
if ! command -v python3 >/dev/null 2>&1 || [[ ! -x "$LSOF_BIN" ]]; then
    echo "ERROR: python3 and lsof are required for bound cleanup and worker extinction." >&2
    exit 2
fi

read -r -a fleet_hosts <<< "$requested_fleet"
if [[ ${#fleet_hosts[@]} -eq 0 ]]; then
    echo "ERROR: FLEET must contain at least one host." >&2
    exit 2
fi

canonical_fleet="${fleet_hosts[*]}"
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    if [[ ! "$host" =~ ^[A-Za-z0-9][A-Za-z0-9.-]*$ ]]; then
        echo "ERROR: invalid host token in FLEET: '$host'." >&2
        exit 2
    fi
    for ((prior_index = 0; prior_index < host_index; prior_index++)); do
        if [[ "${fleet_hosts[$prior_index]}" == "$host" ]]; then
            echo "ERROR: duplicate host in FLEET: '$host'." >&2
            exit 2
        fi
    done
done

approval=${ALEXNET_TEARDOWN_APPROVED_FLEET:-}
if [[ -n "$approval" ]]; then
    read -r -a approved_hosts <<< "$approval"
    canonical_approval="${approved_hosts[*]}"
    if [[ "$canonical_approval" != "$canonical_fleet" ]]; then
        echo "ERROR: ALEXNET_TEARDOWN_APPROVED_FLEET does not match the requested fleet." >&2
        echo "Requested: $canonical_fleet" >&2
        exit 2
    fi
elif [[ -t 0 ]]; then
    echo "=== AlexNet Fleet Teardown ==="
    echo "Exact container: alexnet-training"
    echo "Exact run: $run_id"
    echo "Exact fleet: $canonical_fleet"
    echo "Training results and distributed scripts are preserved."
    read -r -p "Type the exact fleet to approve teardown: " typed_approval
    if [[ "$typed_approval" != "$canonical_fleet" ]]; then
        echo "Aborted: typed approval did not match the exact fleet." >&2
        exit 2
    fi
else
    echo "ERROR: non-interactive teardown requires exact target approval." >&2
    echo "Set ALEXNET_TEARDOWN_APPROVED_FLEET to: $canonical_fleet" >&2
    exit 2
fi

if ! local_host=$(hostname); then
    echo "ERROR: could not determine the local host." >&2
    exit 2
fi

remote_targets=0
local_targets=0
for host in "${fleet_hosts[@]}"; do
    if [[ "$host" == "$local_host" || "$host" == "localhost" ]]; then
        ((local_targets += 1))
    else
        ((remote_targets += 1))
    fi
done

if ((local_targets > 0)) && ! command -v podman >/dev/null 2>&1; then
    echo "ERROR: podman is required for local teardown." >&2
    exit 2
fi

tailscale_json=""
if ((remote_targets > 0)); then
    for dependency in tailscale jq ssh timeout; do
        if ! command -v "$dependency" >/dev/null 2>&1; then
            echo "ERROR: $dependency is required to resolve and verify remote teardown targets." >&2
            exit 2
        fi
    done
    if ! tailscale_json=$(tailscale status --json); then
        echo "ERROR: tailscale inventory readback failed; no container changes were attempted." >&2
        exit 2
    fi
fi

# Resolve the complete fleet before starting any container mutation. The
# indexed array preserves the exact requested host order for receipts.
resolved_targets=()
resolution_failed=0
for host in "${fleet_hosts[@]}"; do
    if [[ "$host" == "$local_host" || "$host" == "localhost" ]]; then
        resolved_targets+=(localhost)
        continue
    fi

    resolved_ip=""
    if resolved_ip=$(printf '%s\n' "$tailscale_json" | jq -er --arg h "$host" \
        '[.Peer // {} | to_entries[] | .value | select(.HostName == $h and .Online == true) | .TailscaleIPs[0]] | if length == 1 then .[0] else empty end'); then
        :
    else
        resolved_ip=""
    fi
    if [[ -z "$resolved_ip" || "$resolved_ip" == *$'\n'* \
            || ! "$resolved_ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
        echo "ERROR: cannot resolve one exact Tailscale IP for '$host'." >&2
        resolution_failed=1
        resolved_targets+=(unresolved)
    else
        resolved_targets+=("$resolved_ip")
    fi
done
if ((resolution_failed != 0)); then
    echo "ERROR: fleet resolution is incomplete; no container changes were attempted." >&2
    exit 2
fi
for ((host_index = 0; host_index < ${#resolved_targets[@]}; host_index++)); do
    for ((prior_index = 0; prior_index < host_index; prior_index++)); do
        if [[ "${resolved_targets[$prior_index]}" == "${resolved_targets[$host_index]}" ]]; then
            echo "ERROR: hosts '${fleet_hosts[$prior_index]}' and '${fleet_hosts[$host_index]}' resolve to duplicate resolved target '${resolved_targets[$host_index]}'; no container changes were attempted." >&2
            exit 2
        fi
    done
done

teardown_local() {
    local probe_rc binding revalidated
    local container_id actual_name actual_run actual_results extra
    local expected_results="$HOME/$RESULTS_DIR/runs/$run_id/$local_host"
    if podman container exists alexnet-training >/dev/null 2>&1; then
        if ! binding=$(podman inspect alexnet-training \
            --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null); then
            echo "container identity binding failed"
            return 1
        fi
        IFS='|' read -r container_id actual_name actual_run actual_results extra \
            <<< "$binding"
        if [[ "$binding" == *$'\n'* || -n "$extra" \
                || ! "$container_id" =~ ^[A-Fa-f0-9]{64}$ \
                || ( "$actual_name" != alexnet-training \
                    && "$actual_name" != /alexnet-training ) \
                || "$actual_run" != "$run_id" \
                || "$actual_results" != "$expected_results" ]]; then
            echo "container run or result binding does not match the approved run"
            return 1
        fi
        if ! revalidated=$(podman inspect "$container_id" \
            --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null) || [[ "$revalidated" != "$binding" ]]; then
            echo "container identity changed before removal"
            return 1
        fi
        if ! podman rm -f "$container_id" >/dev/null; then
            echo "container removal failed"
            return 1
        fi
        if podman container exists "$container_id" >/dev/null 2>&1; then
            echo "bound container still exists after removal"
            return 1
        else
            probe_rc=$?
            if [[ $probe_rc -ne 1 ]]; then
                echo "post-removal bound-ID probe failed (exit $probe_rc)"
                return 1
            fi
        fi
        if podman container exists alexnet-training >/dev/null 2>&1; then
            echo "replacement container appeared during removal and was preserved"
            return 1
        else
            probe_rc=$?
            if [[ $probe_rc -ne 1 ]]; then
                echo "post-removal container-name probe failed (exit $probe_rc)"
                return 1
            fi
        fi
        echo removed
        return 0
    else
        probe_rc=$?
        if [[ $probe_rc -eq 1 ]]; then
            echo absent
            return 0
        fi
        echo "container probe failed (exit $probe_rc)"
        return 1
    fi
}

teardown_remote() {
    local remote_ip=$1
    local result_host=$2
    local remote_output
    local ssh_rc
    if remote_output=$(timeout 15 ssh -o ConnectTimeout=5 -o BatchMode=yes \
        "$remote_ip" "bash -s -- '$RESULTS_DIR' '$run_id' '$result_host'" <<'REMOTE_SCRIPT'
set -u
results_dir=$1
run_id=$2
result_host=$3
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
expected_results="$HOME/$results_dir/runs/$run_id/$result_host"

binding_matches() {
    probe=$1
    [[ "$probe" != *$'\n'* ]] || return 1
    IFS='|' read -r actual_id actual_name actual_run actual_results extra <<EOF
$probe
EOF
    [ -z "${extra:-}" ] || return 1
    [[ "$actual_id" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
    [ "$actual_name" = alexnet-training ] \
        || [ "$actual_name" = /alexnet-training ] \
        || return 1
    [ "$actual_run" = "$run_id" ] || return 1
    [ "$actual_results" = "$expected_results" ] || return 1
    return 0
}

if podman container exists alexnet-training >/dev/null 2>&1; then
    if ! binding=$(podman inspect alexnet-training \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null); then
        echo "container identity binding failed" >&2
        exit 24
    fi
    if ! binding_matches "$binding"; then
        echo "container run or result binding does not match the approved run" >&2
        exit 25
    fi
    container_id=${binding%%|*}
    if ! revalidated=$(podman inspect "$container_id" \
        --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
        2>/dev/null) || [ "$revalidated" != "$binding" ]; then
        echo "container identity changed before removal" >&2
        exit 26
    fi
    if ! podman rm -f "$container_id" >/dev/null; then
        echo "container removal failed" >&2
        exit 27
    fi
    if podman container exists "$container_id" >/dev/null 2>&1; then
        echo "bound container still exists after removal" >&2
        exit 28
    else
        probe_rc=$?
        if [ "$probe_rc" -ne 1 ]; then
            echo "post-removal bound-ID probe failed (exit $probe_rc)" >&2
            exit 29
        fi
    fi
    if podman container exists alexnet-training >/dev/null 2>&1; then
        echo "replacement container appeared during removal and was preserved" >&2
        exit 30
    else
        probe_rc=$?
        if [ "$probe_rc" -ne 1 ]; then
            echo "post-removal container-name probe failed (exit $probe_rc)" >&2
            exit 31
        fi
    fi
    echo removed
else
    probe_rc=$?
    if [ "$probe_rc" -eq 1 ]; then
        echo absent
        exit 0
    fi
    echo "container probe failed (exit $probe_rc)" >&2
    exit 32
fi
REMOTE_SCRIPT
    ); then
        if [[ "$remote_output" == "removed" || "$remote_output" == "absent" ]]; then
            echo "$remote_output"
            return 0
        fi
        echo "invalid remote receipt: $remote_output"
        return 1
    else
        ssh_rc=$?
        echo "remote teardown failed (exit $ssh_rc): $remote_output"
        return 1
    fi
}

if ! receipt_dir=$(mktemp -d "${TMPDIR:-/tmp}/odysseus-alexnet-teardown.XXXXXX"); then
    echo "ERROR: could not create the local receipt directory." >&2
    exit 2
fi
receipt_parent=${receipt_dir%/*}
receipt_name=${receipt_dir##*/}
if ! exec 18< "$receipt_parent" || ! exec 17< "$receipt_dir"; then
    echo "ERROR: could not retain the local receipt directory identity." >&2
    exit 2
fi

quarantine_bound_tree() {
    python3 -I -E -c '
import ctypes, errno, os, secrets, stat, sys
parent_fd, object_fd = map(int, sys.argv[1:3])
name = sys.argv[3]
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
if not stat.S_ISDIR(expected.st_mode): raise OSError("bound receipt object is not a directory")
named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
if key(named) != key(expected): raise OSError("receipt pathname was replaced")
quarantine_name = quarantine(parent_fd, name, expected)
quarantine_fd = os.open(quarantine_name, directory_flags, dir_fd=parent_fd)
try:
    if key(os.fstat(quarantine_fd)) != key(expected): raise OSError("quarantined receipt identity changed")
finally: os.close(quarantine_fd)
print("NOTICE: bound receipts preserved after no-replace quarantine: " + quarantine_name,
      file=sys.stderr)
' 18 17 "$receipt_name"
}
receipt_cleanup_pending=1
receipt_cleanup_allowed=1
cleanup_receipts() {
    if [[ "$receipt_cleanup_allowed" == 1 \
            && "$receipt_cleanup_pending" == "1" ]]; then
        if ! quarantine_bound_tree; then
            echo "ERROR: could not safely remove the bound local receipt directory; retained evidence near: $receipt_dir" >&2
        else
            receipt_cleanup_pending=0
            exec 17<&- 18<&- || true
        fi
    fi
}
trap cleanup_receipts EXIT

handle_worker_signal() {
    local signal_name=$1
    local exit_status=$2
    trap ':' INT TERM HUP
    echo "ERROR: received SIG$signal_name; stopping active teardown workers." >&2
    if stop_owned_workers; then
        cleanup_receipts
    else
        receipt_cleanup_allowed=0
        echo "ERROR: worker extinction or reap could not be verified; retained receipt directory: $receipt_dir" >&2
    fi
    exit "$exit_status"
}
trap 'handle_worker_signal INT 130' INT
trap 'handle_worker_signal TERM 143' TERM
trap 'handle_worker_signal HUP 129' HUP

pids=()
receipt_files=()
worker_sentinels=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    target=${resolved_targets[$host_index]}
    receipt_file="$receipt_dir/$host.receipt"
    worker_sentinel=$(mktemp "$receipt_dir/.worker-sentinel-${host_index}.XXXXXX") \
        || exit 2
    chmod 600 "$worker_sentinel"
    worker_sentinels+=("$worker_sentinel")
    receipt_files+=("$receipt_file")
    if [[ "$target" == "localhost" ]]; then
        ( exec 19< "$worker_sentinel"; teardown_local ) >"$receipt_file" 2>&1 &
    else
        ( exec 19< "$worker_sentinel"; teardown_remote "$target" "$host" ) >"$receipt_file" 2>&1 &
    fi
    pids+=("$!")
    remember_worker_pid "$!"
done

fleet_failed=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    receipt_file=${receipt_files[$host_index]}
    if wait "${pids[$host_index]}"; then
        forget_worker_pid "${pids[$host_index]}"
        if ! extinguish_worker_sentinel "${worker_sentinels[$host_index]}"; then
            echo "$host: failed (escaped worker survived)" >&2
            fleet_failed=1
            continue
        fi
        receipt=$(<"$receipt_file")
        if [[ "$receipt" == "removed" || "$receipt" == "absent" ]]; then
            echo "$host: $receipt"
        else
            echo "$host: failed" >&2
            echo "  invalid terminal receipt: $receipt" >&2
            fleet_failed=1
        fi
    else
        job_rc=$?
        forget_worker_pid "${pids[$host_index]}"
        receipt=$(<"$receipt_file")
        echo "$host: failed" >&2
        if [[ -n "$receipt" ]]; then
            echo "  $receipt" >&2
        else
            echo "  teardown job exited $job_rc without a receipt" >&2
        fi
        fleet_failed=1
        extinguish_worker_sentinel "${worker_sentinels[$host_index]}" \
            || fleet_failed=1
    fi
done

cleanup_receipts
if [[ "$receipt_cleanup_pending" == 1 ]]; then
    fleet_failed=1
fi

if ((fleet_failed != 0)); then
    echo "ERROR: teardown was not verified for every requested host." >&2
    exit 1
fi

echo "Teardown verified for ${#fleet_hosts[@]} host(s)."
echo "To start a fresh approved run: just alexnet-fleet-deploy"
