#!/usr/bin/env bash
# run-bounded.sh — run a memory-hungry command under a virtual-memory cap.
#
# Wrap pixi / cmake / podman / pytest invocations so an over-budget process
# fails as a recoverable error of ITS OWN, instead of letting the kernel
# OOM-killer thrash swap and hang the whole WSL VM. This is the defense that
# would have contained the `hermes` host overload (see Odysseus AGENTS.md
# "Safe autonomy"): `ulimit -v` turns the uncatchable SIGKILL
# into a normal non-zero exit / MemoryError that unwinds cleanly.
#
# Usage:
#   scripts/run-bounded.sh pixi install
#   scripts/run-bounded.sh cmake --build --preset release -j2
#   RUN_BOUNDED_VMEM_KB=4194304 scripts/run-bounded.sh pytest tests/
#
# Env:
#   RUN_BOUNDED_VMEM_KB   Virtual-memory cap in KiB (default 5242880 = 5 GiB).
#                         Must be a canonical positive decimal. Invoke a command
#                         directly when an explicitly unbounded run is intended.
#
# Sizing: on the 16 GB / 8-core host, ~5 GiB/process lets one heavy solve/build
# run comfortably while keeping 3 concurrent bounded processes < 16 GB.
set -euo pipefail

if [[ $# -eq 0 ]]; then
    echo "usage: $(basename "$0") <command> [args...]" >&2
    exit 2
fi

VMEM_KB="${RUN_BOUNDED_VMEM_KB:-5242880}"
MAX_VMEM_KB=67108864

is_canonical_vmem_limit() {
    local value=$1
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ ${#value} -lt ${#MAX_VMEM_KB} ]] && return 0
    [[ ${#value} -eq ${#MAX_VMEM_KB} ]] || return 1
    (( 10#$value <= MAX_VMEM_KB ))
}

if ! is_canonical_vmem_limit "$VMEM_KB"; then
    echo "ERROR: RUN_BOUNDED_VMEM_KB must be a canonical decimal from 1 through $MAX_VMEM_KB" >&2
    exit 2
fi

# Root cause of the old `ulimit -v ... || true`: `ulimit -v` fails when asked
# to raise a soft limit. Apply it only for a genuine lowering, but treat both
# inspection and application as required rather than running unbounded.
if ! _cur_vmem="$(ulimit -v)"; then
    echo "ERROR: cannot inspect the inherited virtual-memory limit" >&2
    exit 1
fi
if [[ "$_cur_vmem" == "unlimited" || "$_cur_vmem" -gt "$VMEM_KB" ]]; then
    if ! ulimit -v "$VMEM_KB"; then
        echo "ERROR: cannot apply the required virtual-memory limit" >&2
        exit 1
    fi
fi

child_pid=
interrupted_signal=0
teardown_failed=false
cgroup_dir=
cgroup_oom_kill_start=0
cgroup_admitted=false

cgroup_value() {
    local key=$1 file=$2 name value
    while IFS=' ' read -r name value; do
        if [[ "$name" == "$key" && "$value" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$value"
            return 0
        fi
    done < "$file"
    return 1
}

cgroup_populated() {
    local populated
    [[ -n "$cgroup_dir" ]] || return 1
    if ! populated=$(cgroup_value populated "$cgroup_dir/cgroup.events"); then
        return 0
    fi
    [[ "$populated" != 0 ]]
}

remove_empty_cgroup() {
    [[ -n "$cgroup_dir" ]] || return 0
    if cgroup_populated; then
        echo "ERROR: refusing to remove a populated bounded workload cgroup" >&2
        teardown_failed=true
        return 1
    fi
    if ! /bin/rmdir -- "$cgroup_dir"; then
        echo "ERROR: cannot remove the bounded workload cgroup: $cgroup_dir" >&2
        teardown_failed=true
        return 1
    fi
    cgroup_dir=
}

prepare_cgroup() {
    local hierarchy controllers relative component parent candidate attempt
    local limit_bytes
    [[ -r /proc/self/cgroup && -d /sys/fs/cgroup ]] || return 1
    relative=
    while IFS=: read -r hierarchy controllers candidate; do
        if [[ "$hierarchy" == 0 && -z "$controllers" ]]; then
            relative=$candidate
            break
        fi
    done < /proc/self/cgroup
    [[ "$relative" == /* && "$relative" != *$'\n'* ]] || return 1
    IFS='/' read -r -a components <<< "$relative"
    for component in "${components[@]}"; do
        [[ "$component" != .. ]] || return 1
    done

    parent="/sys/fs/cgroup$relative"
    candidate=
    while [[ "$parent" == /sys/fs/cgroup* && "$parent" != /sys/fs ]]; do
        [[ -d "$parent" && ! -L "$parent" ]] || break
        for attempt in 1 2 3 4; do
            candidate="$parent/odysseus-run-bounded.$$.$RANDOM.$attempt"
            if /bin/mkdir -- "$candidate" 2>/dev/null; then
                if [[ -f "$candidate/memory.max" \
                    && -f "$candidate/memory.swap.max" \
                    && -f "$candidate/cgroup.kill" \
                    && -f "$candidate/cgroup.procs" \
                    && -f "$candidate/cgroup.events" \
                    && -f "$candidate/memory.events" ]]; then
                    cgroup_dir=$candidate
                    break 2
                fi
                if ! /bin/rmdir -- "$candidate"; then
                    echo "ERROR: cannot clean an unusable workload cgroup: $candidate" >&2
                    teardown_failed=true
                    return 1
                fi
            fi
            candidate=
        done
        parent=${parent%/*}
    done
    [[ -n "$cgroup_dir" ]] || return 1

    limit_bytes=$((10#$VMEM_KB * 1024))
    if ! printf '%s\n' "$limit_bytes" > "$cgroup_dir/memory.max" \
        || ! printf '0\n' > "$cgroup_dir/memory.swap.max" \
        || { [[ -f "$cgroup_dir/memory.oom.group" ]] \
            && ! printf '1\n' > "$cgroup_dir/memory.oom.group"; } \
        || ! cgroup_oom_kill_start=$(cgroup_value \
            oom_kill "$cgroup_dir/memory.events"); then
        remove_empty_cgroup
        teardown_failed=false
        return 1
    fi
    return 0
}

leader_alive() {
    [[ -n "$child_pid" ]] || return 1
    kill -0 -- "$child_pid" 2>/dev/null
}

workload_descendants_alive() {
    cgroup_populated
}

terminate_workload() {
    local attempt
    if $cgroup_admitted; then
        if cgroup_populated && ! printf '1\n' > "$cgroup_dir/cgroup.kill"; then
            echo "ERROR: cannot kill every process in the bounded workload cgroup" >&2
            teardown_failed=true
        fi
    elif leader_alive; then
        # Before cgroup admission only the stopped bootstrap leader exists.
        # Signal that exact PID; never treat its numeric PID as group authority.
        if ! kill -KILL -- "$child_pid" 2>/dev/null; then
            echo "ERROR: cannot stop the unadmitted workload leader" >&2
            teardown_failed=true
        fi
    fi
    for attempt in 1 2 3 4 5 6 7 8 9 10; do
        if ! cgroup_populated; then
            return 0
        fi
        /bin/sleep 0.1
    done
    echo "ERROR: bounded workload descendants remain after cancellation" >&2
    teardown_failed=true
    return 1
}

# Invoked indirectly by the signal traps installed immediately below.
# shellcheck disable=SC2329
handle_signal() {
    if [[ "$interrupted_signal" -eq 0 ]]; then
        interrupted_signal=$1
    fi
    terminate_workload
}

child_is_stopped() {
    local key value
    [[ -r "/proc/$child_pid/status" ]] || return 1
    while IFS=':' read -r key value; do
        if [[ "$key" == State && "$value" == *T* ]]; then
            return 0
        fi
    done < "/proc/$child_pid/status"
    return 1
}

trap 'handle_signal 1' HUP
trap 'handle_signal 2' INT
trap 'handle_signal 15' TERM

if ! prepare_cgroup; then
    if ! $teardown_failed; then
        echo "ERROR: aggregate cgroup-v2 containment is unavailable" >&2
    fi
    exit 1
fi

# A signal delivered during containment setup is terminal.  In particular, it
# must not become permission to start the selected command after the handler
# returns.
# This named assignment is an intentional deterministic signal-injection seam
# for the focused lifecycle test.
# shellcheck disable=SC2034
run_bounded_checkpoint=prelaunch
if [[ "$interrupted_signal" -ne 0 ]]; then
    remove_empty_cgroup
    trap - HUP INT TERM
    exit $((128 + interrupted_signal))
fi
unset run_bounded_checkpoint

# Start one stopped bootstrap process, admit that exact process to the cgroup,
# and only then let it execute selected code.  Every later fork/session inherits
# cgroup membership, including setsid and double-fork descendants.
(
    kill -STOP "${BASHPID:?BASHPID is required for cgroup admission}"
    exec "$@"
) &
child_pid=$!

admitted=false
for attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    if child_is_stopped; then
        admitted=true
        break
    fi
    if ! leader_alive; then
        break
    fi
    /bin/sleep 0.01
done
if [[ "$interrupted_signal" -ne 0 ]] || ! $admitted \
    || ! printf '%s\n' "$child_pid" > "$cgroup_dir/cgroup.procs"; then
    echo "ERROR: cannot admit the workload to its bounded memory cgroup" >&2
    terminate_workload
    set +e
    wait "$child_pid" 2>/dev/null
    set -e
    remove_empty_cgroup
    trap - HUP INT TERM
    if [[ "$interrupted_signal" -ne 0 ]]; then
        exit $((128 + interrupted_signal))
    fi
    exit 1
fi
cgroup_admitted=true
if [[ "$interrupted_signal" -ne 0 ]] || ! kill -CONT "$child_pid"; then
    terminate_workload
    set +e
    wait "$child_pid" 2>/dev/null
    set -e
    remove_empty_cgroup
    trap - HUP INT TERM
    if [[ "$interrupted_signal" -ne 0 ]]; then
        exit $((128 + interrupted_signal))
    fi
    echo "ERROR: cannot start the admitted bounded workload" >&2
    exit 1
fi

set +e
wait "$child_pid"
workload_status=$?
set -e

# Reaping the leader and updating cgroup/process-group membership are separate
# kernel events. Allow that bounded bookkeeping interval before classifying a
# remaining member as a leaked descendant.
for attempt in 1 2 3 4 5 6 7 8 9 10; do
    workload_descendants_alive || break
    /bin/sleep 0.01
done

if [[ "$interrupted_signal" -ne 0 ]]; then
    terminate_workload
    set +e
    wait "$child_pid" 2>/dev/null
    set -e
    workload_status=$((128 + interrupted_signal))
elif workload_descendants_alive; then
    echo "ERROR: workload leader exited while descendants were still running" >&2
    terminate_workload
    workload_status=125
fi

if [[ -n "$cgroup_dir" ]]; then
    oom_kill_end=0
    if ! oom_kill_end=$(cgroup_value oom_kill "$cgroup_dir/memory.events"); then
        echo "ERROR: cannot verify bounded workload memory events" >&2
        teardown_failed=true
    elif [[ "$oom_kill_end" -gt "$cgroup_oom_kill_start" ]]; then
        echo "ERROR: the bounded workload exceeded its aggregate memory ceiling" >&2
        if [[ "$workload_status" -eq 0 ]]; then
            workload_status=125
        fi
    fi
    remove_empty_cgroup
fi

# Keep cancellation handlers installed until cgroup.kill has completed, the
# hierarchy reports unpopulated, and the exact cgroup object is gone.
trap - HUP INT TERM

if $teardown_failed; then
    exit 125
fi
exit "$workload_status"
