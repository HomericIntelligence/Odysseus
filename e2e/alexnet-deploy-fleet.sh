#!/usr/bin/env bash
# e2e/alexnet-deploy-fleet.sh — exact-target AlexNet fleet deployment
#
# Build an Odyssey image on the current host, copy it and its tools to each
# selected remote host, and start one verified training container per target.
# Every non-dry mutation requires approval for the exact requested fleet.

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
if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
    raise SystemExit(2)
expected = os.stat(path, follow_symlinks=False)
pidfd = os.pidfd_open(pid)
try:
    held = False
    for name in os.listdir(f"/proc/{pid}/fd"):
        try: value = os.stat(f"/proc/{pid}/fd/{name}")
        except (FileNotFoundError, PermissionError): continue
        if (value.st_dev, value.st_ino) == (expected.st_dev, expected.st_ino):
            held = True
            break
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
                # Re-resolve ownership from the live open-file table immediately
                # before signaling. A reused PID without this exact sentinel is
                # never a target; setsid/double-fork descendants retain the FD.
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
    for sentinel in "$scratch_dir"/.worker-sentinel-*; do
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
SAFE_FS="$SCRIPT_DIR/alexnet-collect-fs.py"
DEFAULT_FLEET="epimetheus apollo aeolus hephaestus"

if [[ ${FLEET+x} == x ]]; then
    fleet_was_explicit=1
    requested_fleet=$FLEET
else
    fleet_was_explicit=0
    requested_fleet=$DEFAULT_FLEET
fi
# Keep the executable default visibly aligned with the protected workflow.
FLEET="${FLEET:-epimetheus apollo aeolus hephaestus}"
if [[ "$fleet_was_explicit" == 1 ]]; then
    FLEET=$requested_fleet
fi

EPOCHS="${EPOCHS:-100}"
BATCH_SIZE="${BATCH_SIZE:-128}"
MAX_BATCHES="${MAX_BATCHES:-0}"
IMAGE_NAME="${IMAGE_NAME:-odyssey:dev}"
SKIP_BUILD="${SKIP_BUILD:-0}"
if [[ ${SKIP_DISTRIBUTE+x} != x && "$SKIP_BUILD" == 1 ]]; then
    # The protected workflow documents skip_build as reusing images that are
    # already present across the fleet.
    SKIP_DISTRIBUTE=1
elif [[ ${SKIP_DISTRIBUTE+x} != x ]]; then
    SKIP_DISTRIBUTE=0
fi
SKIP_LAUNCH="${SKIP_LAUNCH:-0}"
DRY_RUN="${DRY_RUN:-0}"
LOCAL_AS_BUILD="${LOCAL_AS_BUILD:-0}"
ALEXNET_RUN_STATE_DIR="${ALEXNET_RUN_STATE_DIR:-$HOME/.cache/odysseus-alexnet}"

usage_error() {
    echo "ERROR: $*" >&2
    exit 2
}

[[ "$DRY_RUN" == 0 || "$DRY_RUN" == 1 ]] \
    || usage_error "DRY_RUN must be 0 or 1."
[[ "$ALEXNET_RUN_STATE_DIR" == /* && "$ALEXNET_RUN_STATE_DIR" != / \
        && "$ALEXNET_RUN_STATE_DIR" != "$HOME" \
        && "$ALEXNET_RUN_STATE_DIR" != *$'\n'* ]] \
    || usage_error "ALEXNET_RUN_STATE_DIR must be a narrow absolute path."
run_state_file="$ALEXNET_RUN_STATE_DIR/current-run.tsv"

for flag_name in SKIP_BUILD SKIP_DISTRIBUTE SKIP_LAUNCH LOCAL_AS_BUILD; do
    flag_value=${!flag_name}
    [[ "$flag_value" == 0 || "$flag_value" == 1 ]] \
        || usage_error "$flag_name must be 0 or 1."
done
if [[ ! "$EPOCHS" =~ ^[0-9]+$ ]] || ((10#$EPOCHS == 0)); then
    usage_error "EPOCHS must be a positive integer."
fi
if [[ ! "$BATCH_SIZE" =~ ^[0-9]+$ ]] || ((10#$BATCH_SIZE == 0)); then
    usage_error "BATCH_SIZE must be a positive integer."
fi
[[ "$MAX_BATCHES" =~ ^[0-9]+$ ]] \
    || usage_error "MAX_BATCHES must be a non-negative integer."
[[ "$IMAGE_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._/@:-]*$ ]] \
    || usage_error "IMAGE_NAME contains unsupported characters."

if [[ ${ALEXNET_RUN_ID:-} != "" ]]; then
    [[ "$ALEXNET_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] \
        || usage_error "ALEXNET_RUN_ID must be a safe identifier of at most 128 characters."
else
    if ! run_stamp=$(date -u +%Y%m%dT%H%M%SZ); then
        usage_error "could not create a run timestamp."
    fi
    ALEXNET_RUN_ID="alexnet-$run_stamp-$$"
fi
run_id=$ALEXNET_RUN_ID

read -r -a fleet_hosts <<< "$FLEET"
if [[ ${#fleet_hosts[@]} -eq 0 ]]; then
    usage_error "FLEET must contain at least one host."
fi
canonical_fleet="${fleet_hosts[*]}"
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

local_is_target=0
remote_indices=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    if [[ "$host" == "$local_host" || "$host" == localhost ]]; then
        local_is_target=1
    else
        remote_indices+=("$host_index")
    fi
done

if [[ "$local_is_target" == 0 && "$LOCAL_AS_BUILD" != 1 ]]; then
    usage_error "build host '$local_host' is not in FLEET; set LOCAL_AS_BUILD=1 to authorize this build host."
fi

write_run_state() {
    local status=$1
    local state_tmp
    if ! state_tmp=$(mktemp "$ALEXNET_RUN_STATE_DIR/.current-run.XXXXXX"); then
        usage_error "could not create the local run-state file."
    fi
    if ! printf '1\t%s\t%s\t%s\n' "$run_id" "$status" "$canonical_fleet" \
        > "$state_tmp"; then
        rm -f -- "$state_tmp"
        usage_error "could not write the local run state."
    fi
    if ! mv -f -- "$state_tmp" "$run_state_file"; then
        rm -f -- "$state_tmp"
        usage_error "could not publish the local run state."
    fi
}
if [[ "$DRY_RUN" == 0 ]]; then
    approval=${ALEXNET_DEPLOY_APPROVED_FLEET:-}
    if [[ -n "$approval" ]]; then
        read -r -a approved_hosts <<< "$approval"
        [[ "${approved_hosts[*]}" == "$canonical_fleet" ]] \
            || usage_error "ALEXNET_DEPLOY_APPROVED_FLEET does not match the requested fleet."
    elif [[ -t 0 ]]; then
        echo "Exact fleet: $canonical_fleet"
        read -r -p "Type the exact fleet to approve deployment: " typed_approval
        [[ "$typed_approval" == "$canonical_fleet" ]] \
            || usage_error "typed deployment approval did not match the exact fleet."
    else
        usage_error "non-interactive deployment requires ALEXNET_DEPLOY_APPROVED_FLEET='$canonical_fleet'."
    fi
fi

need_local_podman=0
if [[ "$SKIP_BUILD" == 0 || ("$SKIP_DISTRIBUTE" == 0 && ${#remote_indices[@]} -gt 0) \
        || ("$SKIP_LAUNCH" == 0 && "$local_is_target" == 1) \
        || ${#remote_indices[@]} -gt 0 ]]; then
    need_local_podman=1
fi
if [[ "$need_local_podman" == 1 ]] && ! command -v podman >/dev/null 2>&1; then
    usage_error "podman is required for the requested local phases."
fi
LSOF_BIN=$(command -v lsof 2>/dev/null || true)
[[ -n "$LSOF_BIN" ]] || LSOF_BIN=/usr/sbin/lsof
[[ -x "$LSOF_BIN" ]] \
    || usage_error "lsof is required for descriptor-bound worker extinction."
if [[ "$SKIP_BUILD" == 0 && ! -d "$ODYSSEUS_ROOT/research/Odyssey" ]]; then
    usage_error "Odyssey workspace not found at $ODYSSEUS_ROOT/research/Odyssey."
fi
if [[ "$SKIP_LAUNCH" == 0 && ! -f "$SCRIPT_DIR/alexnet-train.sh" ]]; then
    usage_error "AlexNet launcher not found at $SCRIPT_DIR/alexnet-train.sh."
fi
if [[ ("$SKIP_DISTRIBUTE" == 0 || "$SKIP_LAUNCH" == 0) \
        && (! -f "$SAFE_FS" || -L "$SAFE_FS") ]]; then
    usage_error "AlexNet result helper not found at $SAFE_FS."
fi
helper_digest=""
launcher_digest=""
if [[ "$SKIP_DISTRIBUTE" == 0 || "$SKIP_LAUNCH" == 0 ]]; then
    command -v python3 >/dev/null 2>&1 \
        || usage_error "python3 is required to bind the AlexNet result helper."
    if ! exec 9< "$SAFE_FS"; then
        usage_error "could not open the AlexNet result helper for binding."
    fi
    if ! helper_digest=$(python3 -I -E -c '
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
' 9 "$SAFE_FS"); then
        exec 9<&-
        usage_error "the AlexNet result helper changed while binding."
    fi
    exec 9<&-
    [[ "$helper_digest" =~ ^[0-9a-f]{64}$ ]] \
        || usage_error "the AlexNet result helper digest is invalid."
fi
if [[ "$SKIP_LAUNCH" == 0 || "$SKIP_DISTRIBUTE" == 0 ]]; then
    if ! exec 10< "$SCRIPT_DIR/alexnet-train.sh"; then
        usage_error "could not open the AlexNet launcher for binding."
    fi
    if ! launcher_digest=$(python3 -I -E -c '
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
digest = hashlib.sha256()
offset = 0
while offset < opened.st_size:
    part = os.pread(descriptor, min(65536, opened.st_size - offset), offset)
    if not part:
        raise SystemExit(1)
    digest.update(part)
    offset += len(part)
after = os.fstat(descriptor)
if (opened.st_dev, opened.st_ino, opened.st_size, opened.st_mtime_ns) != (
    after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns
):
    raise SystemExit(1)
print(digest.hexdigest())
' 10 "$SCRIPT_DIR/alexnet-train.sh"); then
        exec 10<&-
        usage_error "the AlexNet launcher changed while binding."
    fi
    [[ "$launcher_digest" =~ ^[0-9a-f]{64}$ ]] \
        || usage_error "the AlexNet launcher digest is invalid."
fi

if [[ ${#remote_indices[@]} -gt 0 ]]; then
    for dependency in tailscale jq ssh timeout; do
        command -v "$dependency" >/dev/null 2>&1 \
            || usage_error "$dependency is required for remote deployment."
    done
    if [[ "$SKIP_DISTRIBUTE" == 0 ]] && ! command -v rsync >/dev/null 2>&1; then
        usage_error "rsync is required for remote distribution."
    fi
fi

# Publish a new resolving identity only after validation and approval. From
# this point, an operational failure must prevent an older launched run from
# becoming evidence for this authorized invocation.
if [[ "$DRY_RUN" == 0 ]]; then
    if ! mkdir -p "$ALEXNET_RUN_STATE_DIR"; then
        usage_error "could not create the local run-state directory."
    fi
    write_run_state resolving
fi

resolved_targets=()
tailscale_json=""
if [[ ${#remote_indices[@]} -gt 0 ]]; then
    if ! tailscale_json=$(tailscale status --json); then
        usage_error "tailscale inventory readback failed; no target changes were attempted."
    fi
fi

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
    echo "ERROR: fleet resolution is incomplete; no target changes were attempted." >&2
    exit 2
fi
for ((host_index = 0; host_index < ${#resolved_targets[@]}; host_index++)); do
    for ((prior_index = 0; prior_index < host_index; prior_index++)); do
        if [[ "${resolved_targets[$prior_index]}" == "${resolved_targets[$host_index]}" ]]; then
            usage_error "hosts '${fleet_hosts[$prior_index]}' and '${fleet_hosts[$host_index]}' resolve to duplicate resolved target '${resolved_targets[$host_index]}'; no target changes were attempted."
        fi
    done
done

if ! scratch_dir=$(mktemp -d "${TMPDIR:-/tmp}/odysseus-alexnet-deploy.XXXXXX"); then
    usage_error "could not create the invocation directory."
fi
scratch_parent=${scratch_dir%/*}
scratch_name=${scratch_dir##*/}
if ! exec 18< "$scratch_parent" || ! exec 17< "$scratch_dir"; then
    usage_error "could not retain the invocation directory identity."
fi

quarantine_bound_tree() {
    python3 -I -E -c '
import ctypes
import errno
import os
import secrets
import stat
import sys

parent_fd, object_fd = map(int, sys.argv[1:3])
name = sys.argv[3]
directory_flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | getattr(os, "O_NOFOLLOW", 0)

def key(value):
    return value.st_dev, value.st_ino, stat.S_IFMT(value.st_mode)

def rename_noreplace(directory_fd, source, destination):
    library = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux") and hasattr(library, "renameat2"):
        result = library.renameat2(directory_fd, os.fsencode(source), directory_fd,
                                   os.fsencode(destination), ctypes.c_uint(1))
    elif sys.platform == "darwin" and hasattr(library, "renameatx_np"):
        result = library.renameatx_np(directory_fd, os.fsencode(source), directory_fd,
                                      os.fsencode(destination), ctypes.c_uint(0x4))
    else:
        raise OSError(errno.ENOTSUP, "atomic no-replace quarantine unavailable")
    if result != 0:
        value = ctypes.get_errno()
        raise OSError(value, os.strerror(value), destination)

def quarantine(directory_fd, entry_name, expected):
    for _ in range(128):
        quarantine_name = ".alexnet-quarantine-" + secrets.token_hex(16)
        try:
            rename_noreplace(directory_fd, entry_name, quarantine_name)
            break
        except FileExistsError:
            continue
    else:
        raise OSError("could not allocate no-replace quarantine")
    moved = os.stat(quarantine_name, dir_fd=directory_fd, follow_symlinks=False)
    if key(moved) != key(expected):
        raise OSError("path changed at quarantine boundary; both objects retained")
    return quarantine_name

expected = os.fstat(object_fd)
if not stat.S_ISDIR(expected.st_mode):
    raise OSError("bound invocation object is not a directory")
named = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
if key(named) != key(expected):
    raise OSError("invocation pathname was replaced")
quarantine_name = quarantine(parent_fd, name, expected)
quarantine_fd = os.open(quarantine_name, directory_flags, dir_fd=parent_fd)
try:
    if key(os.fstat(quarantine_fd)) != key(expected):
        raise OSError("quarantined invocation identity changed")
finally:
    os.close(quarantine_fd)
print("NOTICE: bound invocation preserved after no-replace quarantine: " + quarantine_name,
      file=sys.stderr)
' 18 17 "$scratch_name"
}
scratch_cleanup_pending=1
scratch_cleanup_allowed=1
cleanup_scratch() {
    if [[ "$scratch_cleanup_allowed" == 1 \
            && "$scratch_cleanup_pending" == 1 ]]; then
        if ! quarantine_bound_tree; then
            echo "ERROR: could not safely remove the bound invocation directory; retained evidence near: $scratch_dir" >&2
        else
            scratch_cleanup_pending=0
            exec 17<&- 18<&- || true
        fi
    fi
}
trap cleanup_scratch EXIT

handle_worker_signal() {
    local signal_name=$1
    local exit_status=$2
    trap ':' INT TERM HUP
    echo "ERROR: received SIG$signal_name; stopping active fleet workers." >&2
    if stop_owned_workers; then
        cleanup_scratch
    else
        scratch_cleanup_allowed=0
        echo "ERROR: worker extinction or reap could not be verified; retained invocation directory: $scratch_dir" >&2
    fi
    exit "$exit_status"
}
trap 'handle_worker_signal INT 130' INT
trap 'handle_worker_signal TERM 143' TERM
trap 'handle_worker_signal HUP 129' HUP

artifact_run_id=$(basename "$scratch_dir")
remote_run_dir=".cache/odysseus-alexnet/$artifact_run_id"
SSH_BASE=(timeout 15 ssh -o ConnectTimeout=5 -o BatchMode=yes)
bound_launcher="$scratch_dir/alexnet-train.sh"
if [[ -n "$launcher_digest" ]]; then
    if ! cp /dev/fd/10 "$bound_launcher" \
            || [[ "$(python3 -I -E -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$bound_launcher")" \
                != "$launcher_digest" ]]; then
        usage_error "could not snapshot the bound AlexNet launcher."
    fi
    chmod 700 "$bound_launcher"
fi

run_parallel_phase() {
    local phase=$1
    local worker=$2
    shift 2
    local indices=("$@")
    local pids=()
    local detail_files=()
    local sentinels=()
    local index detail_file sentinel job_rc detail detail_line job_index phase_host
    local phase_failed=0

    for index in "${indices[@]}"; do
        detail_file="$scratch_dir/${phase}-${index}.detail"
        sentinel=$(mktemp "$scratch_dir/.worker-sentinel-${phase}-${index}.XXXXXX") \
            || return 1
        chmod 600 "$sentinel"
        detail_files+=("$detail_file")
        sentinels+=("$sentinel")
        ( exec 19< "$sentinel"; "$worker" "$index" ) >"$detail_file" 2>&1 &
        pids+=("$!")
        remember_worker_pid "$!"
    done

    for ((job_index = 0; job_index < ${#indices[@]}; job_index++)); do
        index=${indices[$job_index]}
        phase_host=${fleet_hosts[$index]}
        detail_file=${detail_files[$job_index]}
        if wait "${pids[$job_index]}"; then
            forget_worker_pid "${pids[$job_index]}"
            if extinguish_worker_sentinel "${sentinels[$job_index]}"; then
                echo "$phase_host: $phase verified"
            else
                echo "$phase_host: $phase failed (escaped worker survived)" >&2
                phase_failed=1
            fi
        else
            job_rc=$?
            forget_worker_pid "${pids[$job_index]}"
            echo "$phase_host: $phase failed (exit $job_rc)" >&2
            detail=$(<"$detail_file")
            if [[ -n "$detail" ]]; then
                while IFS= read -r detail_line; do
                    echo "  $detail_line" >&2
                done <<< "$detail"
            fi
            phase_failed=1
            extinguish_worker_sentinel "${sentinels[$job_index]}" || phase_failed=1
        fi
    done
    return "$phase_failed"
}

local_image_id=""
if [[ "$SKIP_BUILD" == 1 && "$need_local_podman" == 1 ]]; then
    if ! local_image_id=$(podman image inspect "$IMAGE_NAME" \
            --format '{{.Id}}' 2>/dev/null) \
            || [[ ! "$local_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        usage_error "local image '$IMAGE_NAME' has no valid immutable identity."
    fi
fi

preflight_target() {
    local index=$1
    local target=${resolved_targets[$index]}
    local local_workspace
    if [[ "$target" == localhost ]]; then
        if [[ "$need_local_podman" == 1 ]]; then
            podman info >/dev/null
        fi
        if [[ "$SKIP_BUILD" == 1 && "$need_local_podman" == 1 ]]; then
            podman image exists "$IMAGE_NAME" >/dev/null
            test "$(podman image inspect "$IMAGE_NAME" --format '{{.Id}}')" \
                = "$local_image_id"
        fi
        if [[ "$SKIP_LAUNCH" == 0 ]]; then
            local_workspace=${WORKSPACE_DIR:-$HOME/Projects/Odysseus}
            test -d "$local_workspace/research/Odyssey"
        fi
        return 0
    fi
    "${SSH_BASE[@]}" "$target" \
        "bash -s -- '$IMAGE_NAME' '$SKIP_DISTRIBUTE' '$SKIP_LAUNCH' '$local_image_id'" <<'REMOTE'
set -eu
image_name=$1
skip_distribute=$2
skip_launch=$3
expected_image_id=$4
command -v podman >/dev/null
podman info >/dev/null
if [ "$skip_distribute" = 1 ]; then
    podman image exists "$image_name" >/dev/null
    actual_image_id=$(podman image inspect "$image_name" --format '{{.Id}}')
    test "$actual_image_id" = "$expected_image_id"
    if [ "$skip_launch" = 0 ]; then
        launcher_dir="$HOME/alexnet-fleet-scripts"
        launcher="$launcher_dir/alexnet-train.sh"
        result_helper="$launcher_dir/alexnet-collect-fs.py"
        test -d "$launcher_dir"
        test ! -L "$launcher_dir"
        test -O "$launcher_dir"
        test -f "$launcher"
        test ! -L "$launcher"
        test -O "$launcher"
        test -f "$result_helper"
        test ! -L "$result_helper"
        test -O "$result_helper"
    fi
fi
if [ "$skip_distribute" = 0 ]; then
    test -w "$HOME"
    command -v install >/dev/null
    command -v cmp >/dev/null
    command -v ln >/dev/null
    command -v stat >/dev/null
    command -v python3 >/dev/null
fi
if [ "$skip_launch" = 0 ]; then
    command -v stat >/dev/null
    test -d "$HOME/Projects/Odysseus/research/Odyssey"
fi
REMOTE
}

all_indices=()
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    all_indices+=("$host_index")
done
echo "=== AlexNet fleet preflight ==="
echo "Exact fleet: $canonical_fleet"
if ! run_parallel_phase preflight preflight_target "${all_indices[@]}"; then
    echo "ERROR: fleet preflight failed; no build, distribution, or launch was attempted." >&2
    exit 1
fi

if [[ "$DRY_RUN" == 1 ]]; then
    echo "DRY RUN: preflight verified ${#fleet_hosts[@]} target(s); no target changes were made."
    cleanup_scratch
    if [[ "$scratch_cleanup_pending" == 1 ]]; then
        exit 1
    fi
    exit 0
fi

if [[ "$SKIP_BUILD" == 0 ]]; then
    echo "=== Build Odyssey image ==="
    workspace="$ODYSSEUS_ROOT/research/Odyssey"
    compose_log="$scratch_dir/podman-compose-build.log"
    user_id=$(id -u)
    group_id=$(id -g)
    user_name=${USER:-dev}
    if [[ "$IMAGE_NAME" == odyssey:dev ]]; then
        if ! (
            cd "$workspace"
            podman compose build odyssey-dev 2>"$compose_log"
        ); then
            echo "podman compose build failed; using the direct Containerfile path." >&2
            tail -20 "$compose_log" >&2
            (
                cd "$workspace"
                podman build -t "$IMAGE_NAME" \
                    --build-arg "USER_ID=$user_id" \
                    --build-arg "GROUP_ID=$group_id" \
                    --build-arg "USER_NAME=$user_name" \
                    .
            )
        fi
    else
        # The compose service owns the default tag. A nondefault tag must come
        # from this invocation, not from an image that happened to exist.
        (
            cd "$workspace"
            podman build -t "$IMAGE_NAME" \
                --build-arg "USER_ID=$user_id" \
                --build-arg "GROUP_ID=$group_id" \
                --build-arg "USER_NAME=$user_name" \
                .
        )
    fi
else
    echo "Build skipped: verified existing image '$IMAGE_NAME'."
fi
if [[ "$need_local_podman" == 1 ]]; then
    podman image exists "$IMAGE_NAME" >/dev/null
    if ! verified_local_image_id=$(podman image inspect "$IMAGE_NAME" \
            --format '{{.Id}}' 2>/dev/null) \
            || [[ ! "$verified_local_image_id" =~ ^sha256:[0-9a-f]{64}$ ]]; then
        echo "ERROR: local image '$IMAGE_NAME' has no valid immutable identity." >&2
        exit 1
    fi
    if [[ -n "$local_image_id" && "$verified_local_image_id" != "$local_image_id" ]]; then
        echo "ERROR: local image identity changed after preflight." >&2
        exit 1
    fi
    local_image_id=$verified_local_image_id
fi

image_tar="$scratch_dir/image.tar"
if [[ "$SKIP_DISTRIBUTE" == 0 && ${#remote_indices[@]} -gt 0 ]]; then
    podman save -o "$image_tar" "$IMAGE_NAME"
fi

prepare_remote() {
    local index=$1
    local target=${resolved_targets[$index]}
    local stage_identity stage_output
    stage_output="$scratch_dir/remote-stage-$index.output"
    if ! "${SSH_BASE[@]}" "$target" \
        "bash -s -- '$remote_run_dir'" >"$stage_output" <<'REMOTE'; then
set -eu
run_dir=$1
owner_token=${run_dir##*/}
test "$run_dir" = ".cache/odysseus-alexnet/$owner_token"
case "$owner_token" in
    odysseus-alexnet-deploy.*) ;;
    *) exit 2 ;;
esac
cache_dir="$HOME/.cache"
run_root="$cache_dir/odysseus-alexnet"
staging_dir="$HOME/$run_dir"
owner_file="$staging_dir/.odysseus-owner"
ensure_owned_directory() {
    path=$1
    if [ -e "$path" ] || [ -L "$path" ]; then
        test -d "$path"
        test ! -L "$path"
        test -O "$path"
    else
        (umask 077 && mkdir -- "$path")
        test -d "$path"
        test ! -L "$path"
        test -O "$path"
    fi
}
ensure_owned_directory "$HOME"
ensure_owned_directory "$cache_dir"
ensure_owned_directory "$run_root"
if [ -e "$staging_dir" ] || [ -L "$staging_dir" ]; then
    echo "remote invocation staging path already exists: $staging_dir" >&2
    exit 1
fi
(umask 077 && mkdir -- "$staging_dir")
test -d "$staging_dir"
test ! -L "$staging_dir"
test -O "$staging_dir"
if ! (umask 077 && printf '%s\n' "$owner_token" > "$owner_file"); then
    echo "remote owner marker write failed; staging was retained" >&2
    exit 1
fi
inode_of() {
    LC_ALL=C ls -di "$1" | awk 'NR == 1 { print $1 }'
}
stage_inode=$(inode_of "$staging_dir")
owner_inode=$(inode_of "$owner_file")
case "$stage_inode:$owner_inode" in
    *[!0-9:]*) exit 1 ;;
esac
printf '%s:%s\n' "$stage_inode" "$owner_inode"
REMOTE
        return 1
    fi
    stage_identity=$(<"$stage_output")
    [[ "$stage_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    printf '%s\n' "$stage_identity" \
        > "$scratch_dir/remote-stage-$index.identity"
}

transfer_remote() {
    local index=$1
    local target=${resolved_targets[$index]}
    rsync -az --timeout=60 \
        -e 'ssh -o ConnectTimeout=5 -o BatchMode=yes' -- \
        "$image_tar" "$bound_launcher" "$SAFE_FS" \
        "$target:~/$remote_run_dir/"
}

load_remote() {
    local index=$1
    local target=${resolved_targets[$index]}
    local stage_identity launcher_identity launcher_output
    [[ -f "$scratch_dir/remote-stage-$index.identity" ]] || return 1
    stage_identity=$(<"$scratch_dir/remote-stage-$index.identity")
    [[ "$stage_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
    launcher_output="$scratch_dir/remote-launcher-$index.output"
    if ! "${SSH_BASE[@]}" "$target" \
        "bash -s -- '$remote_run_dir' '$IMAGE_NAME' '$local_image_id' '$stage_identity' '$launcher_digest' '$helper_digest'" \
        >"$launcher_output" <<'REMOTE'; then
set -eu
run_dir=$1
image_name=$2
expected_image_id=$3
expected_stage_identity=$4
expected_launcher_digest=$5
expected_helper_digest=$6
owner_token=${run_dir##*/}
test "$run_dir" = ".cache/odysseus-alexnet/$owner_token"
case "$owner_token" in
    odysseus-alexnet-deploy.*) ;;
    *) exit 2 ;;
esac
cache_dir="$HOME/.cache"
run_root="$cache_dir/odysseus-alexnet"
staging_dir="$HOME/$run_dir"
owner_file="$staging_dir/.odysseus-owner"
archive="$staging_dir/image.tar"
launcher="$staging_dir/alexnet-train.sh"
result_helper="$staging_dir/alexnet-collect-fs.py"
launcher_dir="$HOME/alexnet-fleet-scripts"
launcher_stage="$launcher_dir/.$owner_token"
launcher_stage_owner="$launcher_stage/.odysseus-owner"
launcher_stage_file="$launcher_stage/alexnet-train.sh"
helper_stage_file="$launcher_stage/alexnet-collect-fs.py"
launcher_destination="$launcher_dir/alexnet-train.sh"
helper_destination="$launcher_dir/alexnet-collect-fs.py"
published_marker="$staging_dir/.launcher-published"
require_owned_directory() {
    path=$1
    test -d "$path"
    test ! -L "$path"
    test -O "$path"
}
require_owned_regular() {
    path=$1
    test -f "$path"
    test ! -L "$path"
    test -O "$path"
}
digest_of() {
    python3 -I -E -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$1"
}
require_owner_file() {
    path=$1
    expected=$2
    value=""
    test -f "$path"
    test ! -L "$path"
    test -O "$path"
    IFS= read -r value < "$path"
    test "$value" = "$expected"
}
inode_of() {
    LC_ALL=C ls -di "$1" | awk 'NR == 1 { print $1 }'
}
bound_inode_of() {
    if value=$(stat -Lc '%i' "$1" 2>/dev/null); then
        :
    else
        value=$(stat -f '%i' "$1")
    fi
    case "$value" in
        ''|*[!0-9]*) exit 1 ;;
    esac
    printf '%s\n' "$value"
}
require_inode() {
    path=$1
    expected=$2
    actual=$(inode_of "$path")
    test "$actual" = "$expected"
}
expected_stage_inode=${expected_stage_identity%%:*}
expected_owner_inode=${expected_stage_identity#*:}
require_owned_directory "$HOME"
require_owned_directory "$cache_dir"
require_owned_directory "$run_root"
require_owned_directory "$staging_dir"
require_owner_file "$owner_file" "$owner_token"
require_inode "$staging_dir" "$expected_stage_inode"
require_inode "$owner_file" "$expected_owner_inode"
test -f "$archive"
test ! -L "$archive"
test -O "$archive"
test -f "$launcher"
test ! -L "$launcher"
test -O "$launcher"
test -f "$result_helper"
test ! -L "$result_helper"
test -O "$result_helper"
test "$(digest_of "$launcher")" = "$expected_launcher_digest"
test "$(digest_of "$result_helper")" = "$expected_helper_digest"
archive_inode=$(inode_of "$archive")
main_launcher_inode=$(inode_of "$launcher")
main_helper_inode=$(inode_of "$result_helper")
require_inode "$staging_dir" "$expected_stage_inode"
require_inode "$owner_file" "$expected_owner_inode"
require_inode "$archive" "$archive_inode"
require_inode "$launcher" "$main_launcher_inode"
require_inode "$result_helper" "$main_helper_inode"
exec 3< "$archive"
require_inode "$archive" "$archive_inode"
test "$(bound_inode_of /dev/fd/3)" = "$archive_inode"
podman load -i /dev/fd/3 >/dev/null
exec 3<&-
podman image exists "$image_name" >/dev/null
actual_image_id=$(podman image inspect "$image_name" --format '{{.Id}}')
if [ "$actual_image_id" != "$expected_image_id" ]; then
    echo "remote image identity does not match the bound local image" >&2
    exit 1
fi
if [ -e "$launcher_dir" ] || [ -L "$launcher_dir" ]; then
    require_owned_directory "$launcher_dir"
else
    (umask 077 && mkdir -- "$launcher_dir")
    require_owned_directory "$launcher_dir"
fi
test ! -e "$launcher_stage"
test ! -L "$launcher_stage"
(umask 077 && mkdir -- "$launcher_stage")
require_owned_directory "$launcher_stage"
printf '%s\n' "$owner_token" > "$launcher_stage_owner"
install -m 755 "$launcher" "$launcher_stage_file"
install -m 644 "$result_helper" "$helper_stage_file"
cmp -s "$launcher" "$launcher_stage_file"
cmp -s "$result_helper" "$helper_stage_file"
printf '%s\n' "$owner_token" > "$published_marker"
if [ -e "$launcher_destination" ] || [ -L "$launcher_destination" ] \
        || [ -e "$helper_destination" ] || [ -L "$helper_destination" ]; then
    require_owned_regular "$launcher_destination"
    require_owned_regular "$helper_destination"
    cmp -s "$launcher_stage_file" "$launcher_destination"
    cmp -s "$helper_stage_file" "$helper_destination"
else
    ln -- "$launcher_stage_file" "$launcher_destination"
    ln -- "$helper_stage_file" "$helper_destination"
fi
cmp -s "$launcher_stage_file" "$launcher_destination"
cmp -s "$helper_stage_file" "$helper_destination"
test "$(digest_of "$launcher_stage_file")" = "$expected_launcher_digest"
test "$(digest_of "$launcher_destination")" = "$expected_launcher_digest"
test "$(digest_of "$helper_stage_file")" = "$expected_helper_digest"
test "$(digest_of "$helper_destination")" = "$expected_helper_digest"
test -x "$launcher_stage_file"
test -x "$launcher_destination"
launcher_stage_inode=$(inode_of "$launcher_stage")
launcher_stage_owner_inode=$(inode_of "$launcher_stage_owner")
launcher_file_inode=$(inode_of "$launcher_stage_file")
helper_file_inode=$(inode_of "$helper_stage_file")
launcher_destination_inode=$(inode_of "$launcher_destination")
helper_destination_inode=$(inode_of "$helper_destination")
published_marker_inode=$(inode_of "$published_marker")
case "$main_launcher_inode:$main_helper_inode:$archive_inode:$launcher_stage_inode:$launcher_stage_owner_inode:$launcher_file_inode:$helper_file_inode:$launcher_destination_inode:$helper_destination_inode:$published_marker_inode" in
    *[!0-9:]*) exit 1 ;;
esac
printf '%s:%s:%s:%s:%s:%s:%s:%s:%s:%s\n' \
    "$main_launcher_inode" "$main_helper_inode" "$archive_inode" "$launcher_stage_inode" \
    "$launcher_stage_owner_inode" "$launcher_file_inode" \
    "$helper_file_inode" "$launcher_destination_inode" \
    "$helper_destination_inode" "$published_marker_inode"
REMOTE
        return 1
    fi
    launcher_identity=$(<"$launcher_output")
    [[ "$launcher_identity" =~ ^[0-9]+(:[0-9]+){9}$ ]] || return 1
    printf '%s\n' "$launcher_identity" \
        > "$scratch_dir/remote-launcher-$index.identity"
}

verify_remote_retention() {
    local index=$1
    local target=${resolved_targets[$index]}
    local stage_receipt launcher_receipt stage_identity launcher_identity
    stage_receipt="$scratch_dir/remote-stage-$index.identity"
    launcher_receipt="$scratch_dir/remote-launcher-$index.identity"
    if [[ ! -f "$stage_receipt" ]]; then
        echo "remote artifact retention identity is unavailable" >&2
        return 1
    fi
    stage_identity=$(<"$stage_receipt")
    if [[ ! "$stage_identity" =~ ^[0-9]+:[0-9]+$ ]]; then
        echo "remote artifact retention identity is malformed" >&2
        return 1
    fi
    launcher_identity=""
    if [[ -f "$launcher_receipt" ]]; then
        launcher_identity=$(<"$launcher_receipt")
        if [[ ! "$launcher_identity" =~ ^[0-9]+(:[0-9]+){9}$ ]]; then
            echo "remote tool retention identity is malformed" >&2
            return 1
        fi
    fi
    "${SSH_BASE[@]}" "$target" \
        "bash -s -- '$remote_run_dir' '$stage_identity' '$launcher_identity'" <<'REMOTE'
set -eu
run_dir=$1
expected_stage_identity=$2
expected_launcher_identity=$3
owner_token=${run_dir##*/}
test "$run_dir" = ".cache/odysseus-alexnet/$owner_token"
case "$owner_token" in
    odysseus-alexnet-deploy.*) ;;
    *) exit 2 ;;
esac
cache_dir="$HOME/.cache"
run_root="$cache_dir/odysseus-alexnet"
staging_dir="$HOME/$run_dir"
owner_file="$staging_dir/.odysseus-owner"
launcher="$staging_dir/alexnet-train.sh"
result_helper="$staging_dir/alexnet-collect-fs.py"
archive="$staging_dir/image.tar"
published_marker="$staging_dir/.launcher-published"
launcher_dir="$HOME/alexnet-fleet-scripts"
launcher_stage="$launcher_dir/.$owner_token"
launcher_stage_owner="$launcher_stage/.odysseus-owner"
launcher_stage_file="$launcher_stage/alexnet-train.sh"
helper_stage_file="$launcher_stage/alexnet-collect-fs.py"
launcher_destination="$launcher_dir/alexnet-train.sh"
helper_destination="$launcher_dir/alexnet-collect-fs.py"
require_owned_directory() {
    path=$1
    test -d "$path"
    test ! -L "$path"
    test -O "$path"
}
require_owned_regular() {
    path=$1
    test -f "$path"
    test ! -L "$path"
    test -O "$path"
}
require_owner_file() {
    path=$1
    expected=$2
    value=""
    test -f "$path"
    test ! -L "$path"
    test -O "$path"
    IFS= read -r value < "$path"
    test "$value" = "$expected"
}
inode_of() {
    LC_ALL=C ls -di "$1" | awk 'NR == 1 { print $1 }'
}
require_inode() {
    path=$1
    expected=$2
    actual=$(inode_of "$path")
    test "$actual" = "$expected"
}
expected_stage_inode=${expected_stage_identity%%:*}
expected_owner_inode=${expected_stage_identity#*:}
require_owned_directory "$HOME"
require_owned_directory "$cache_dir"
require_owned_directory "$run_root"
require_owned_directory "$staging_dir"
require_owner_file "$owner_file" "$owner_token"
require_inode "$staging_dir" "$expected_stage_inode"
require_inode "$owner_file" "$expected_owner_inode"

if [ -n "$expected_launcher_identity" ]; then
    expected_main_launcher_inode=${expected_launcher_identity%%:*}
    remaining_identity=${expected_launcher_identity#*:}
    expected_main_helper_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_archive_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_stage_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_stage_owner_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_file_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_helper_file_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_destination_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_helper_destination_inode=${remaining_identity%%:*}
    expected_published_marker_inode=${remaining_identity#*:}

    require_owned_directory "$launcher_dir"
    require_owned_directory "$launcher_stage"
    require_owner_file "$launcher_stage_owner" "$owner_token"
    require_owned_regular "$launcher"
    require_owned_regular "$result_helper"
    require_owned_regular "$archive"
    require_owned_regular "$launcher_stage_file"
    require_owned_regular "$helper_stage_file"
    require_owned_regular "$launcher_destination"
    require_owned_regular "$helper_destination"
    require_owner_file "$published_marker" "$owner_token"
    require_inode "$launcher" "$expected_main_launcher_inode"
    require_inode "$result_helper" "$expected_main_helper_inode"
    require_inode "$archive" "$expected_archive_inode"
    require_inode "$launcher_stage" "$expected_launcher_stage_inode"
    require_inode "$launcher_stage_owner" "$expected_launcher_stage_owner_inode"
    require_inode "$launcher_stage_file" "$expected_launcher_file_inode"
    require_inode "$helper_stage_file" "$expected_helper_file_inode"
    require_inode "$launcher_destination" "$expected_launcher_destination_inode"
    require_inode "$helper_destination" "$expected_helper_destination_inode"
    require_inode "$published_marker" "$expected_published_marker_inode"
    cmp -s "$launcher_stage_file" "$launcher_destination"
    cmp -s "$helper_stage_file" "$helper_destination"
    unexpected_stage_entry=$(find "$launcher_stage" -mindepth 1 -maxdepth 1 \
        ! -name .odysseus-owner ! -name alexnet-train.sh \
        ! -name alexnet-collect-fs.py -print -quit)
    test -z "$unexpected_stage_entry"
    unexpected_run_entry=$(find "$staging_dir" -mindepth 1 -maxdepth 1 \
        ! -name .odysseus-owner ! -name alexnet-train.sh \
        ! -name alexnet-collect-fs.py ! -name image.tar \
        ! -name .launcher-published -print -quit)
    test -z "$unexpected_run_entry"
fi
require_inode "$staging_dir" "$expected_stage_inode"
require_inode "$owner_file" "$expected_owner_inode"
printf '%s\n' "retained:$run_dir"
REMOTE
}

distributed=0
if [[ "$SKIP_DISTRIBUTE" == 0 && ${#remote_indices[@]} -gt 0 ]]; then
    echo "=== Distribute and verify image ==="
    if ! run_parallel_phase prepare prepare_remote "${remote_indices[@]}"; then
        if ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
            echo "ERROR: remote invocation artifact retention verification also failed." >&2
        fi
        echo "ERROR: remote preparation failed." >&2
        exit 1
    fi
    distributed=1
    if ! run_parallel_phase transfer transfer_remote "${remote_indices[@]}"; then
        if ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
            echo "ERROR: remote invocation artifact retention verification also failed." >&2
        fi
        echo "ERROR: image transfer was not verified for every requested remote target." >&2
        exit 1
    fi
    if ! run_parallel_phase image-ready load_remote "${remote_indices[@]}"; then
        if ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
            echo "ERROR: remote invocation artifact retention verification also failed." >&2
        fi
        echo "ERROR: image load was not verified for every requested remote target." >&2
        exit 1
    fi
else
    echo "Distribution skipped: no remote distribution was requested."
fi

validate_launch_binding() {
    local binding=$1
    local expected_run=$2
    local expected_results=$3
    local expected_image=$4
    local actual_id actual_name actual_state actual_run actual_results actual_image extra
    IFS='|' read -r actual_id actual_name actual_state actual_run \
        actual_results actual_image extra <<< "$binding"
    if [[ "$binding" == *$'\n'* || -n "$extra" \
            || ! "$actual_id" =~ ^[A-Fa-f0-9]{64}$ \
            || ( "$actual_name" != alexnet-training \
                && "$actual_name" != /alexnet-training ) \
            || "$actual_state" != "running 0" \
            || "$actual_run" != "$expected_run" \
            || "$actual_results" != "$expected_results" \
            || "$actual_image" != "$expected_image" ]]; then
        echo "launch receipt does not match the exact container, run, result mount, and image" >&2
        return 1
    fi
    printf '%s\n' "$actual_id"
}

launch_target() {
    local index=$1
    local target=${resolved_targets[$index]}
    local result_host binding revalidated container_id expected_results
    local launcher stage_identity launcher_identity stage_receipt launcher_receipt
    local state_output_file
    result_host=${fleet_hosts[$index]}
    if [[ "$target" == localhost ]]; then
        result_host=$local_host
        coproc LOCAL_CONTAINER_RECEIPT { cat; }
        local_receipt_pid=$LOCAL_CONTAINER_RECEIPT_PID
        exec 11>&"${LOCAL_CONTAINER_RECEIPT[1]}"
        exec 12<&"${LOCAL_CONTAINER_RECEIPT[0]}"
        ALEXNET_RESULT_HELPER_SHA256="$helper_digest" \
            ALEXNET_CONTAINER_ID_FD=11 \
            ALEXNET_RUN_ID="$run_id" EPOCHS="$EPOCHS" \
            BATCH_SIZE="$BATCH_SIZE" MAX_BATCHES="$MAX_BATCHES" \
            IMAGE_NAME="$IMAGE_NAME" bash <&10
        container_id=$(python3 -I -E -c '
import os, sys
data = b""
while len(data) < 65:
    part = os.read(int(sys.argv[1]), 65 - len(data))
    if not part: break
    data += part
sys.stdout.write(data.decode("ascii").rstrip("\n"))
' 12)
        exec 11>&- 12<&-
        wait "$local_receipt_pid" 2>/dev/null || true
        [[ "$container_id" =~ ^[0-9a-f]{64}$ ]] || {
            echo "launch did not publish an exact container ID receipt" >&2
            return 1
        }
        expected_results="$HOME/alexnet-results/runs/$run_id/$result_host"
        if ! binding=$(podman inspect "$container_id" \
            --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}|{{.Image}}' \
            2>/dev/null); then
            echo "launch receipt is unavailable" >&2
            return 1
        fi
        if ! container_id=$(validate_launch_binding "$binding" "$run_id" \
            "$expected_results" "$local_image_id"); then
            return 1
        fi
        if ! revalidated=$(podman inspect "$container_id" \
            --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}|{{.Image}}' \
            2>/dev/null) || [[ "$revalidated" != "$binding" ]]; then
            echo "launch receipt changed during exact-ID revalidation" >&2
            return 1
        fi
    else
        launcher="alexnet-fleet-scripts/alexnet-train.sh"
        stage_identity=""
        launcher_identity=""
        if [[ "$distributed" == 1 ]]; then
            stage_receipt="$scratch_dir/remote-stage-$index.identity"
            launcher_receipt="$scratch_dir/remote-launcher-$index.identity"
            [[ -f "$stage_receipt" && -f "$launcher_receipt" ]] || return 1
            stage_identity=$(<"$stage_receipt")
            launcher_identity=$(<"$launcher_receipt")
            [[ "$stage_identity" =~ ^[0-9]+:[0-9]+$ ]] || return 1
            [[ "$launcher_identity" =~ ^[0-9]+(:[0-9]+){9}$ ]] || return 1
        fi
        state_output_file="$scratch_dir/remote-launch-$index.output"
        if ! "${SSH_BASE[@]}" "$target" \
            "bash -s -- '$launcher' '$run_id' '$EPOCHS' '$BATCH_SIZE' '$MAX_BATCHES' '$IMAGE_NAME' '$distributed' '$remote_run_dir' '$stage_identity' '$launcher_identity' '$result_host' '$local_image_id' '$helper_digest' '$launcher_digest'" \
            >"$state_output_file" <<'REMOTE'; then
set -eu
launcher=$1
run_id=$2
epochs=$3
batch_size=$4
max_batches=$5
image_name=$6
distributed=$7
run_dir=$8
expected_stage_identity=$9
expected_launcher_identity=${10}
result_host=${11}
expected_image_id=${12}
expected_helper_digest=${13}
expected_launcher_digest=${14}
test "$launcher" = alexnet-fleet-scripts/alexnet-train.sh
case "$expected_helper_digest" in
    ''|*[!0-9a-f]*) exit 2 ;;
esac
test "${#expected_helper_digest}" -eq 64
case "$expected_launcher_digest" in
    ''|*[!0-9a-f]*) exit 2 ;;
esac
test "${#expected_launcher_digest}" -eq 64
launcher_dir="$HOME/alexnet-fleet-scripts"
launcher_path="$HOME/$launcher"
helper_path="$launcher_dir/alexnet-collect-fs.py"
require_owned_directory() {
    path=$1
    test -d "$path"
    test ! -L "$path"
    test -O "$path"
}
require_owned_regular() {
    path=$1
    test -f "$path"
    test ! -L "$path"
    test -O "$path"
}
require_owner_file() {
    path=$1
    expected=$2
    value=""
    require_owned_regular "$path"
    IFS= read -r value < "$path"
    test "$value" = "$expected"
}
inode_of() {
    LC_ALL=C ls -di "$1" | awk 'NR == 1 { print $1 }'
}
bound_inode_of() {
    if value=$(stat -Lc '%i' "$1" 2>/dev/null); then
        :
    else
        value=$(stat -f '%i' "$1")
    fi
    case "$value" in
        ''|*[!0-9]*) exit 1 ;;
    esac
    printf '%s\n' "$value"
}
require_inode() {
    path=$1
    expected=$2
    actual=$(inode_of "$path")
    test "$actual" = "$expected"
}
require_owned_directory "$HOME"
require_owned_directory "$launcher_dir"
require_owned_regular "$launcher_path"
require_owned_regular "$helper_path"
test -x "$launcher_path"

if [ "$distributed" = 1 ]; then
    owner_token=${run_dir##*/}
    test "$run_dir" = ".cache/odysseus-alexnet/$owner_token"
    case "$owner_token" in
        odysseus-alexnet-deploy.*) ;;
        *) exit 2 ;;
    esac
    cache_dir="$HOME/.cache"
    run_root="$cache_dir/odysseus-alexnet"
    staging_dir="$HOME/$run_dir"
    owner_file="$staging_dir/.odysseus-owner"
    archive="$staging_dir/image.tar"
    main_launcher="$staging_dir/alexnet-train.sh"
    main_helper="$staging_dir/alexnet-collect-fs.py"
    published_marker="$staging_dir/.launcher-published"
    launcher_stage="$launcher_dir/.$owner_token"
    launcher_stage_owner="$launcher_stage/.odysseus-owner"
    launcher_stage_file="$launcher_stage/alexnet-train.sh"
    helper_stage_file="$launcher_stage/alexnet-collect-fs.py"
    expected_stage_inode=${expected_stage_identity%%:*}
    expected_owner_inode=${expected_stage_identity#*:}
    expected_main_launcher_inode=${expected_launcher_identity%%:*}
    remaining_identity=${expected_launcher_identity#*:}
    expected_main_helper_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_archive_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_stage_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_stage_owner_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_file_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_helper_file_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_launcher_destination_inode=${remaining_identity%%:*}
    remaining_identity=${remaining_identity#*:}
    expected_helper_destination_inode=${remaining_identity%%:*}
    expected_published_marker_inode=${remaining_identity#*:}

    require_owned_directory "$cache_dir"
    require_owned_directory "$run_root"
    require_owned_directory "$staging_dir"
    require_owner_file "$owner_file" "$owner_token"
    require_owned_regular "$archive"
    require_owned_regular "$main_launcher"
    require_owned_regular "$main_helper"
    require_owner_file "$published_marker" "$owner_token"
    require_owned_directory "$launcher_stage"
    require_owner_file "$launcher_stage_owner" "$owner_token"
    require_owned_regular "$launcher_stage_file"
    require_owned_regular "$helper_stage_file"
    require_inode "$staging_dir" "$expected_stage_inode"
    require_inode "$owner_file" "$expected_owner_inode"
    require_inode "$archive" "$expected_archive_inode"
    require_inode "$main_launcher" "$expected_main_launcher_inode"
    require_inode "$main_helper" "$expected_main_helper_inode"
    require_inode "$launcher_stage" "$expected_launcher_stage_inode"
    require_inode "$launcher_stage_owner" "$expected_launcher_stage_owner_inode"
    require_inode "$launcher_stage_file" "$expected_launcher_file_inode"
    require_inode "$helper_stage_file" "$expected_helper_file_inode"
    require_inode "$launcher_path" "$expected_launcher_destination_inode"
    require_inode "$helper_path" "$expected_helper_destination_inode"
    require_inode "$published_marker" "$expected_published_marker_inode"
else
    test "$distributed" = 0
    launcher_inode=$(inode_of "$launcher_path")
    helper_inode=$(inode_of "$helper_path")
fi

exec 3< "$launcher_path"
exec 4< "$helper_path"
require_owned_regular "$launcher_path"
require_owned_regular "$helper_path"
test -x "$launcher_path"
if [ "$distributed" = 1 ]; then
    require_inode "$launcher_path" "$expected_launcher_destination_inode"
    require_inode "$helper_path" "$expected_helper_destination_inode"
    test "$(bound_inode_of /dev/fd/3)" = "$expected_launcher_destination_inode"
    test "$(bound_inode_of /dev/fd/4)" = "$expected_helper_destination_inode"
else
    require_inode "$launcher_path" "$launcher_inode"
    require_inode "$helper_path" "$helper_inode"
    test "$(bound_inode_of /dev/fd/3)" = "$launcher_inode"
    test "$(bound_inode_of /dev/fd/4)" = "$helper_inode"
fi
digest_fd() {
    python3 -I -E -c '
import hashlib, os, sys
fd = int(sys.argv[1])
value = os.fstat(fd)
digest = hashlib.sha256()
offset = 0
while offset < value.st_size:
    part = os.pread(fd, min(65536, value.st_size - offset), offset)
    if not part:
        raise SystemExit(1)
    digest.update(part)
    offset += len(part)
after = os.fstat(fd)
if (value.st_dev, value.st_ino, value.st_size, value.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
    raise SystemExit(1)
print(digest.hexdigest())
' "$1"
}
test "$(digest_fd 3)" = "$expected_launcher_digest"
test "$(digest_fd 4)" = "$expected_helper_digest"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
coproc REMOTE_CONTAINER_RECEIPT { cat; }
receipt_channel_pid=$REMOTE_CONTAINER_RECEIPT_PID
exec 5>&"${REMOTE_CONTAINER_RECEIPT[1]}"
exec 6<&"${REMOTE_CONTAINER_RECEIPT[0]}"
ALEXNET_SUPPORT_DIR=$launcher_dir ALEXNET_RESULT_HELPER_FD=4 \
    ALEXNET_RESULT_HELPER_SHA256=$expected_helper_digest \
    ALEXNET_CONTAINER_ID_FD=5 \
    ALEXNET_RUN_ID=$run_id \
    EPOCHS=$epochs BATCH_SIZE=$batch_size \
    MAX_BATCHES=$max_batches IMAGE_NAME=$image_name bash <&3 >&2
container_id=$(python3 -I -E -c '
import os, sys
data = b""
while len(data) < 65:
    part = os.read(int(sys.argv[1]), 65 - len(data))
    if not part: break
    data += part
sys.stdout.write(data.decode("ascii").rstrip("\n"))
' 6)
exec 5>&- 6<&-
wait "$receipt_channel_pid" 2>/dev/null || true
exec 3<&-
exec 4<&-
case "$container_id" in
    *[!0-9a-f]*|'') exit 1 ;;
esac
test "${#container_id}" -eq 64
binding=$(podman inspect "$container_id" \
    --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}|{{.Image}}')
[[ "$binding" != *$'\n'* ]]
IFS='|' read -r actual_id actual_name actual_state actual_run actual_results actual_image extra <<EOF
$binding
EOF
expected_results="$HOME/alexnet-results/runs/$run_id/$result_host"
test -z "${extra:-}"
[[ "$actual_id" =~ ^[A-Fa-f0-9]{64}$ ]]
test "$actual_name" = alexnet-training || test "$actual_name" = /alexnet-training
test "$actual_state" = "running 0"
test "$actual_run" = "$run_id"
test "$actual_results" = "$expected_results"
test "$actual_image" = "$expected_image_id"
revalidated=$(podman inspect "$actual_id" \
    --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}|{{.Image}}')
test "$revalidated" = "$binding"
printf '%s\n' "$binding"
REMOTE
            echo "remote launch receipt verification failed" >&2
            return 1
        fi
        binding=$(<"$state_output_file")
        IFS='|' read -r _receipt_id _receipt_name _receipt_state \
            _receipt_run expected_results _receipt_image _receipt_extra \
            <<< "$binding"
        case "$expected_results" in
            */alexnet-results/runs/"$run_id"/"$result_host") ;;
            *)
                echo "remote launch receipt has the wrong result mount" >&2
                return 1
                ;;
        esac
        if ! container_id=$(validate_launch_binding "$binding" "$run_id" \
            "$expected_results" "$local_image_id" 2>/dev/null); then
            echo "remote launch receipt is malformed" >&2
            return 1
        fi
    fi
    printf '%s\n' "$binding" > "$scratch_dir/launch-$index.receipt"
}

verify_launch_receipt() {
    local index=$1
    local target=${resolved_targets[$index]}
    local result_host=${fleet_hosts[$index]}
    local receipt_file="$scratch_dir/launch-$index.receipt"
    local binding container_id expected_results revalidated
    [[ -f "$receipt_file" ]] || return 1
    binding=$(<"$receipt_file")
    if [[ "$target" == localhost ]]; then
        result_host=$local_host
        expected_results="$HOME/alexnet-results/runs/$run_id/$result_host"
        if ! container_id=$(validate_launch_binding "$binding" "$run_id" \
            "$expected_results" "$local_image_id"); then
            return 1
        fi
        revalidated=$(podman inspect "$container_id" \
            --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}|{{.Image}}') \
            || return 1
    else
        container_id=${binding%%|*}
        [[ "$container_id" =~ ^[A-Fa-f0-9]{64}$ ]] || return 1
        revalidated=$("${SSH_BASE[@]}" "$target" \
            "bash -s -- '$container_id' '$run_id' '$result_host' '$local_image_id'" <<'REMOTE'
set -eu
container_id=$1
run_id=$2
result_host=$3
expected_image_id=$4
probe=$(podman inspect "$container_id" \
    --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}|{{.Image}}')
[[ "$probe" != *$'\n'* ]]
IFS='|' read -r actual_id actual_name actual_state actual_run actual_results actual_image extra <<EOF
$probe
EOF
test -z "${extra:-}"
test "$actual_id" = "$container_id"
test "$actual_name" = alexnet-training || test "$actual_name" = /alexnet-training
test "$actual_state" = "running 0"
test "$actual_run" = "$run_id"
test "$actual_results" = "$HOME/alexnet-results/runs/$run_id/$result_host"
test "$actual_image" = "$expected_image_id"
printf '%s\n' "$probe"
REMOTE
        ) \
            || return 1
    fi
    if [[ "$revalidated" != "$binding" ]]; then
        echo "launch receipt changed before deployment publication" >&2
        return 1
    fi
}

if [[ "$SKIP_LAUNCH" == 0 ]]; then
    echo "=== Launch and verify training containers ==="
    write_run_state launching
    if ! run_parallel_phase running launch_target "${all_indices[@]}"; then
        if [[ "$distributed" == 1 ]]; then
            if ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
                echo "ERROR: remote invocation artifact retention verification also failed." >&2
            fi
        fi
        echo "ERROR: launch was not verified for every requested target." >&2
        exit 1
    fi
    if ! run_parallel_phase launch-receipt verify_launch_receipt "${all_indices[@]}"; then
        if [[ "$distributed" == 1 ]]; then
            if ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
                echo "ERROR: remote invocation artifact retention verification also failed." >&2
            fi
        fi
        echo "ERROR: launch receipt revalidation failed; launched state was withheld." >&2
        exit 1
    fi
    if [[ "$distributed" == 1 ]] \
            && ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
        echo "ERROR: remote invocation artifact retention verification failed." >&2
        exit 1
    fi
    write_run_state launched
else
    if [[ "$distributed" == 1 ]] \
            && ! run_parallel_phase retention verify_remote_retention "${remote_indices[@]}"; then
        echo "ERROR: remote invocation artifact retention verification failed." >&2
        exit 1
    fi
    write_run_state no-launch
    echo "Launch skipped by explicit request."
fi

cleanup_scratch
if [[ "$scratch_cleanup_pending" == 1 ]]; then
    exit 1
fi

echo "Fleet deployment verified for ${#fleet_hosts[@]} requested host(s)."
echo "Run ID: $run_id"
if [[ "$SKIP_LAUNCH" == 0 ]]; then
    echo "Wait for verified terminal results with: FLEET='$canonical_fleet' ALEXNET_RUN_ID='$run_id' just alexnet-fleet-wait"
fi
