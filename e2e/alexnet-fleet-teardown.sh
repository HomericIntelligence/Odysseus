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
LSOF_BIN=""
if discovered_lsof=$(command -v lsof 2>/dev/null); then
    LSOF_BIN=$discovered_lsof
fi
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
            if ! exec 17<&- 18<&-; then :; fi
        fi
    fi
}
trap cleanup_receipts EXIT

handle_worker_signal() {
    local signal_name=$1
    local exit_status=$2
    if [[ "$worker_launch_critical" == 1 ]]; then
        pending_worker_signal_name=$signal_name
        pending_worker_signal_status=$exit_status
        return 0
    fi
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

honor_pending_worker_signal() {
    local signal_name=$pending_worker_signal_name
    local exit_status=$pending_worker_signal_status
    if [[ "$exit_status" != 0 ]]; then
        pending_worker_signal_name=""
        pending_worker_signal_status=0
        handle_worker_signal "$signal_name" "$exit_status"
    fi
}
trap 'handle_worker_signal INT 130' INT
trap 'handle_worker_signal TERM 143' TERM
trap 'handle_worker_signal HUP 129' HUP

pids=()
receipt_files=()
worker_sentinel_paths=()
worker_sentinel_ids=()
worker_sentinel_fds=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    target=${resolved_targets[$host_index]}
    receipt_file="$receipt_dir/$host.receipt"
    create_worker_sentinel "$receipt_dir" "$host_index" || exit 2
    worker_sentinel=$CREATED_WORKER_SENTINEL_PATH
    worker_sentinel_id=$CREATED_WORKER_SENTINEL_ID
    worker_sentinel_fd=$CREATED_WORKER_SENTINEL_FD
    worker_sentinel_paths+=("$worker_sentinel")
    worker_sentinel_ids+=("$worker_sentinel_id")
    worker_sentinel_fds+=("$worker_sentinel_fd")
    receipt_files+=("$receipt_file")
done

for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    target=${resolved_targets[$host_index]}
    receipt_file=${receipt_files[$host_index]}
    worker_sentinel=${worker_sentinel_paths[$host_index]}
    worker_sentinel_id=${worker_sentinel_ids[$host_index]}
    worker_sentinel_fd=${worker_sentinel_fds[$host_index]}
    worker_launch_critical=1
    if [[ "$target" == "localhost" ]]; then
        (
            prepare_worker_sentinel "$worker_sentinel_fd" \
                "$worker_sentinel_id" "${worker_sentinel_fds[@]}"
            teardown_local
        ) >"$receipt_file" 2>&1 &
    else
        (
            prepare_worker_sentinel "$worker_sentinel_fd" \
                "$worker_sentinel_id" "${worker_sentinel_fds[@]}"
            teardown_remote "$target" "$host"
        ) >"$receipt_file" 2>&1 &
    fi
    worker_pid=$!
    pids+=("$worker_pid")
    remember_worker_pid "$worker_pid" "$worker_sentinel_id" \
        "$worker_sentinel_fd"
    if ! wait_worker_sentinel_ready "$worker_pid" "$worker_sentinel_fd" \
            "$worker_sentinel_id"; then
        if ! extinguish_worker_sentinel "$worker_sentinel_id"; then
            receipt_cleanup_allowed=0
        else
            if ! wait "$worker_pid" 2>/dev/null; then :; fi
            forget_worker_pid "$worker_pid" || receipt_cleanup_allowed=0
        fi
        worker_launch_critical=0
        honor_pending_worker_signal
        echo "ERROR: teardown worker failed before its readiness receipt." >&2
        exit 1
    fi
    worker_launch_critical=0
    honor_pending_worker_signal
done

fleet_failed=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    receipt_file=${receipt_files[$host_index]}
    if wait "${pids[$host_index]}"; then
        if ! retire_worker_pid "${pids[$host_index]}" \
                "${worker_sentinel_ids[$host_index]}"; then
            echo "$host: failed (escaped worker survived)" >&2
            fleet_failed=1
            receipt_cleanup_allowed=0
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
        receipt=$(<"$receipt_file")
        echo "$host: failed" >&2
        if [[ -n "$receipt" ]]; then
            echo "  $receipt" >&2
        else
            echo "  teardown job exited $job_rc without a receipt" >&2
        fi
        fleet_failed=1
        if ! retire_worker_pid "${pids[$host_index]}" \
                "${worker_sentinel_ids[$host_index]}"; then
            fleet_failed=1
            receipt_cleanup_allowed=0
        fi
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
