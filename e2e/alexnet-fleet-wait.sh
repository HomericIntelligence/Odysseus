#!/usr/bin/env bash
# e2e/alexnet-fleet-wait.sh — wait for exact AlexNet fleet completion
#
# Poll every requested container to a terminal state. A successful process exit
# is mandatory. Unless --no-gate is set, the container log marker and (for a
# full run) saved weights are also mandatory.

set -euo pipefail

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

RESULTS_DIR="${RESULTS_DIR:-alexnet-results}"
POLL_INTERVAL="${POLL_INTERVAL:-60}"
SETTLE_SECONDS="${SETTLE_SECONDS:-5}"
MARKER_RETRY_DELAY="${MARKER_RETRY_DELAY:-2}"
ALEXNET_LOG_MAX_BYTES="${ALEXNET_LOG_MAX_BYTES:-8388608}"
ALEXNET_LOG_MAX_LINES="${ALEXNET_LOG_MAX_LINES:-100000}"
ALEXNET_RUN_STATE_DIR="${ALEXNET_RUN_STATE_DIR:-$HOME/.cache/odysseus-alexnet}"
TIMEOUT_MINUTES=150
GATE=1
REQUIRE_WEIGHTS=1
MAX_POLL_INTERVAL=3600
MAX_GATE_DELAY=60

usage_error() {
    echo "ERROR: $*" >&2
    exit 2
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout-minutes)
            [[ $# -ge 2 ]] || usage_error "--timeout-minutes requires a value."
            TIMEOUT_MINUTES=$2
            shift 2
            ;;
        --no-gate)
            GATE=0
            shift
            ;;
        --smoke)
            REQUIRE_WEIGHTS=0
            shift
            ;;
        *)
            usage_error "unknown flag '$1' (supported: --timeout-minutes N, --no-gate, --smoke)."
            ;;
    esac
done

if [[ ! "$TIMEOUT_MINUTES" =~ ^[0-9]+$ ]] || ((10#$TIMEOUT_MINUTES == 0)); then
    usage_error "timeout minutes must be a positive integer."
fi
if [[ ! "$POLL_INTERVAL" =~ ^[0-9]+$ ]] || ((10#$POLL_INTERVAL == 0)); then
    usage_error "POLL_INTERVAL must be a positive integer."
fi
if ((10#$POLL_INTERVAL > MAX_POLL_INTERVAL)); then
    usage_error "POLL_INTERVAL must not exceed $MAX_POLL_INTERVAL seconds."
fi
[[ "$SETTLE_SECONDS" =~ ^[0-9]+$ ]] \
    || usage_error "SETTLE_SECONDS must be a non-negative integer."
[[ "$MARKER_RETRY_DELAY" =~ ^[0-9]+$ ]] \
    || usage_error "MARKER_RETRY_DELAY must be a non-negative integer."
if [[ ! "$ALEXNET_LOG_MAX_BYTES" =~ ^[0-9]+$ ]] \
        || ((10#$ALEXNET_LOG_MAX_BYTES == 0 \
            || 10#$ALEXNET_LOG_MAX_BYTES > 1073741824)); then
    usage_error "ALEXNET_LOG_MAX_BYTES must be from 1 through 1073741824."
fi
if [[ ! "$ALEXNET_LOG_MAX_LINES" =~ ^[0-9]+$ ]] \
        || ((10#$ALEXNET_LOG_MAX_LINES == 0 \
            || 10#$ALEXNET_LOG_MAX_LINES > 10000000)); then
    usage_error "ALEXNET_LOG_MAX_LINES must be from 1 through 10000000."
fi
if ((10#$SETTLE_SECONDS > MAX_GATE_DELAY)); then
    usage_error "SETTLE_SECONDS must not exceed $MAX_GATE_DELAY seconds."
fi
if ((10#$MARKER_RETRY_DELAY > MAX_GATE_DELAY)); then
    usage_error "MARKER_RETRY_DELAY must not exceed $MAX_GATE_DELAY seconds."
fi
[[ "$RESULTS_DIR" =~ ^[A-Za-z0-9._/-]+$ \
        && "$RESULTS_DIR" != /* \
        && "/$RESULTS_DIR/" != *"/../"* \
        && "/$RESULTS_DIR/" != *"/./"* ]] \
    || usage_error "RESULTS_DIR must be a safe relative path."

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
            && "$state_status" == launched \
            && "$state_fleet" == "$canonical_fleet" ]] \
        || usage_error "current run state does not identify a launched run for the exact fleet."
    ALEXNET_RUN_ID=$state_run_id
fi
run_id=$ALEXNET_RUN_ID

local_targets=0
remote_targets=0
for host in "${fleet_hosts[@]}"; do
    if [[ "$host" == "$local_host" || "$host" == localhost ]]; then
        local_targets=$((local_targets + 1))
    else
        remote_targets=$((remote_targets + 1))
    fi
done
if [[ "$local_targets" -gt 0 ]] && ! command -v podman >/dev/null 2>&1; then
    usage_error "podman is required to inspect a local fleet target."
fi
if [[ "$GATE" == 1 ]]; then
    for dependency in timeout python3; do
        command -v "$dependency" >/dev/null 2>&1 \
            || usage_error "$dependency is required for bounded completion-log reads."
    done
fi

tailscale_json=""
if [[ "$remote_targets" -gt 0 ]]; then
    for dependency in tailscale jq ssh timeout; do
        command -v "$dependency" >/dev/null 2>&1 \
            || usage_error "$dependency is required to inspect remote targets."
    done
    if ! tailscale_json=$(tailscale status --json); then
        usage_error "tailscale inventory readback failed."
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
    echo "ERROR: fleet resolution is incomplete; no container probes were attempted." >&2
    exit 2
fi
for ((host_index = 0; host_index < ${#resolved_targets[@]}; host_index++)); do
    for ((prior_index = 0; prior_index < host_index; prior_index++)); do
        if [[ "${resolved_targets[$prior_index]}" == "${resolved_targets[$host_index]}" ]]; then
            usage_error "hosts '${fleet_hosts[$prior_index]}' and '${fleet_hosts[$host_index]}' resolve to duplicate resolved target '${resolved_targets[$host_index]}'; no container probes were attempted."
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

container_binding() {
    local index=$1
    local target=${resolved_targets[$index]}
    local result_host=${result_hosts[$index]}
    local binding_output actual_id actual_name actual_run actual_results extra
    local expected_results="$HOME/$RESULTS_DIR/runs/$run_id/$result_host"
    if [[ "$target" == localhost ]]; then
        if ! binding_output=$(podman inspect alexnet-training \
            --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null); then
            echo binding-failed
            return 0
        fi
    else
        if ! binding_output=$("${SSH_BASE[@]}" "$target" \
            "bash -s -- '$RESULTS_DIR' '$run_id' '$result_host'" <<'REMOTE'
set -eu
results_dir=$1
run_id=$2
result_host=$3
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
binding=$(podman inspect alexnet-training \
    --format '{{.Id}}|{{.Name}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}')
[[ "$binding" != *$'\n'* ]]
IFS='|' read -r actual_id actual_name actual_run actual_results extra <<EOF
$binding
EOF
expected_results="$HOME/$results_dir/runs/$run_id/$result_host"
test -z "${extra:-}"
[[ "$actual_id" =~ ^[A-Fa-f0-9]{64}$ ]]
test "$actual_name" = alexnet-training || test "$actual_name" = /alexnet-training
test "$actual_run" = "$run_id"
test "$actual_results" = "$expected_results"
printf '%s\n' "$actual_id"
REMOTE
        ); then
            echo binding-failed
            return 0
        fi
        if [[ "$binding_output" =~ ^[A-Fa-f0-9]{64}$ ]]; then
            echo "$binding_output"
        else
            echo binding-failed
        fi
        return 0
    fi
    IFS='|' read -r actual_id actual_name actual_run actual_results extra \
        <<< "$binding_output"
    if [[ "$binding_output" == *$'\n'* || -n "$extra" \
            || ! "$actual_id" =~ ^[A-Fa-f0-9]{64}$ \
            || ( "$actual_name" != alexnet-training \
                && "$actual_name" != /alexnet-training ) \
            || "$actual_run" != "$run_id" \
            || "$actual_results" != "$expected_results" ]]; then
        echo binding-failed
    else
        echo "$actual_id"
    fi
}

container_state() {
    local index=$1
    local target=${resolved_targets[$index]}
    local result_host=${result_hosts[$index]}
    local container_id=${container_ids[$index]}
    local state_output actual_id actual_name state_value actual_run actual_results extra
    local expected_results="$HOME/$RESULTS_DIR/runs/$run_id/$result_host"
    if [[ "$target" == localhost ]]; then
        if ! state_output=$(podman inspect "$container_id" \
            --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}' \
            2>/dev/null); then
            echo identity-failed
            return 0
        fi
        IFS='|' read -r actual_id actual_name state_value actual_run \
            actual_results extra <<< "$state_output"
        if [[ "$state_output" == *$'\n'* || -n "$extra" \
                || "$actual_id" != "$container_id" \
                || ( "$actual_name" != alexnet-training \
                    && "$actual_name" != /alexnet-training ) \
                || "$actual_run" != "$run_id" \
                || "$actual_results" != "$expected_results" ]]; then
            echo identity-failed
            return 0
        fi
        state_output=$state_value
    else
        if ! state_output=$("${SSH_BASE[@]}" "$target" \
            "bash -s -- '$container_id' '$RESULTS_DIR' '$run_id' '$result_host'" <<'REMOTE'
set -eu
container_id=$1
results_dir=$2
run_id=$3
result_host=$4
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
probe=$(podman inspect "$container_id" \
    --format '{{.Id}}|{{.Name}}|{{.State.Status}} {{.State.ExitCode}}|{{index .Config.Labels "io.homeric.alexnet.run-id"}}|{{range .Mounts}}{{if eq .Destination "/results"}}{{.Source}}{{end}}{{end}}')
[[ "$probe" != *$'\n'* ]]
IFS='|' read -r actual_id actual_name state_value actual_run actual_results extra <<EOF
$probe
EOF
expected_results="$HOME/$results_dir/runs/$run_id/$result_host"
test -z "${extra:-}"
test "$actual_id" = "$container_id"
test "$actual_name" = alexnet-training || test "$actual_name" = /alexnet-training
test "$actual_run" = "$run_id"
test "$actual_results" = "$expected_results"
printf '%s\n' "$state_value"
REMOTE
        ); then
            echo identity-failed
            return 0
        fi
    fi
    case "$state_output" in
        running\ [0-9]*|created\ [0-9]*|configured\ [0-9]*|paused\ [0-9]*|\
        restarting\ [0-9]*|stopping\ [0-9]*|removing\ [0-9]*|exited\ [0-9]*)
            if [[ "$state_output" =~ ^[a-z-]+\ [0-9]+$ ]]; then
                echo "$state_output"
            else
                echo probe-failed
            fi
            ;;
        *) echo probe-failed ;;
    esac
}

container_ids=()
binding_failed=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    container_id=$(container_binding "$host_index")
    if [[ "$container_id" == binding-failed ]]; then
        echo "ERROR: ${fleet_hosts[$host_index]} container identity binding failed." >&2
        binding_failed=1
    else
        container_ids+=("$container_id")
    fi
done
if [[ "$binding_failed" != 0 ]]; then
    echo "ERROR: container identity binding failed for one or more requested hosts." >&2
    exit 1
fi

echo "=== AlexNet fleet wait ==="
echo "Exact fleet: $canonical_fleet"
echo "Timeout: ${TIMEOUT_MINUTES} minute(s); poll interval: ${POLL_INTERVAL} second(s)"

deadline=$(($(date +%s) + 10#$TIMEOUT_MINUTES * 60))
terminal_states=()
while :; do
    current_states=()
    all_exited=1
    probe_failed=0
    status_line="[$(date -u +%H:%M:%SZ)]"
    for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
        state_value=$(container_state "$host_index")
        current_states+=("$state_value")
        status_line="$status_line ${fleet_hosts[$host_index]}=$state_value"
        case "$state_value" in
            exited\ [0-9]*) ;;
            identity-failed|probe-failed)
                all_exited=0
                probe_failed=1
                ;;
            *) all_exited=0 ;;
        esac
    done
    echo "$status_line"

    if [[ "$probe_failed" == 1 ]]; then
        echo "ERROR: one or more container-state probes failed:" >&2
        for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
            echo "  ${fleet_hosts[$host_index]}: ${current_states[$host_index]}" >&2
        done
        exit 1
    fi
    if [[ "$all_exited" == 1 ]]; then
        terminal_states=("${current_states[@]}")
        break
    fi
    now=$(date +%s)
    if ((now >= deadline)); then
        echo "ERROR: deadline passed before every requested container exited:" >&2
        for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
            echo "  ${fleet_hosts[$host_index]}: ${current_states[$host_index]}" >&2
        done
        exit 1
    fi
    remaining=$((deadline - now))
    poll_sleep=$((10#$POLL_INTERVAL))
    if ((poll_sleep > remaining)); then
        poll_sleep=$remaining
    fi
    sleep "$poll_sleep"
done

exit_failures=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    state_value=${terminal_states[$host_index]}
    echo "$host: $state_value"
    exit_code=${state_value#exited }
    if [[ "$exit_code" != 0 ]]; then
        exit_failures=$((exit_failures + 1))
    fi
done
if [[ "$exit_failures" -gt 0 ]]; then
    echo "ERROR: $exit_failures requested container(s) exited non-zero; completion evidence cannot override process failure." >&2
    exit 1
fi

if [[ "$GATE" == 0 ]]; then
    echo "WAIT PASSED: every requested container exited successfully."
    exit 0
fi

if [[ "$SETTLE_SECONDS" -gt 0 ]]; then
    now=$(date +%s)
    if ((10#$SETTLE_SECONDS > deadline - now)); then
        echo "ERROR: deadline leaves insufficient time for the completion-evidence settle delay." >&2
        exit 1
    fi
    sleep "$SETTLE_SECONDS"
fi

stream_container_logs() {
    local index=$1
    local remaining_seconds=$2
    local target=${resolved_targets[$index]}
    local container_id=${container_ids[$index]}
    if [[ "$target" == localhost ]]; then
        timeout "$remaining_seconds" podman logs "$container_id" 2>/dev/null
    else
        timeout "$remaining_seconds" "${SSH_BASE[@]}" "$target" \
            "bash -s -- '$container_id'" <<'REMOTE'
set -eu
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"
podman logs "$1"
REMOTE
    fi
}

consume_marker_stream() {
    python3 -I -E -c '
import sys

maximum_bytes = int(sys.argv[1])
maximum_lines = int(sys.argv[2])
marker = b"Training complete!"
total_bytes = 0
total_lines = 0
tail = b""
found = False
ends_with_newline = True
while True:
    chunk = sys.stdin.buffer.read(65536)
    if not chunk:
        break
    total_bytes += len(chunk)
    total_lines += chunk.count(b"\n")
    ends_with_newline = chunk.endswith(b"\n")
    if marker in tail + chunk:
        found = True
    tail = (tail + chunk)[-(len(marker) - 1):]
    if total_bytes > maximum_bytes or total_lines > maximum_lines:
        print("over-budget")
        raise SystemExit(3)
if total_bytes and not ends_with_newline:
    total_lines += 1
if total_lines > maximum_lines:
    print("over-budget")
    raise SystemExit(3)
print("marker" if found else "missing")
raise SystemExit(0 if found else 1)
' "$ALEXNET_LOG_MAX_BYTES" "$ALEXNET_LOG_MAX_LINES"
}

has_marker() {
    local index=$1
    local expected_state=${terminal_states[$index]}
    local state_value attempt=0 marker_result marker_rc now remaining
    while [[ "$attempt" -lt 3 ]]; do
        state_value=$(container_state "$index")
        if [[ "$state_value" != "$expected_state" ]]; then
            echo "ERROR: ${fleet_hosts[$index]}: $state_value while revalidating the bound container before marker read." >&2
            return 1
        fi
        now=$(date +%s)
        remaining=$((deadline - now))
        if ((remaining <= 0)); then
            echo "ERROR: ${fleet_hosts[$index]}: fleet deadline expired before completion-log read." >&2
            return 1
        fi
        marker_rc=0
        marker_result=$(stream_container_logs "$index" "$remaining" \
            | consume_marker_stream) || marker_rc=$?
        if [[ "$marker_rc" == 0 && "$marker_result" == marker ]]; then
            return 0
        fi
        if [[ "$marker_result" == over-budget ]]; then
            echo "ERROR: ${fleet_hosts[$index]}: completion log exceeded the configured byte or line budget." >&2
            return 1
        fi
        now=$(date +%s)
        if ((now >= deadline)); then
            echo "ERROR: ${fleet_hosts[$index]}: completion-log read exhausted the fleet deadline." >&2
            return 1
        fi
        attempt=$((attempt + 1))
        if [[ "$attempt" -lt 3 && "$MARKER_RETRY_DELAY" -gt 0 ]]; then
            now=$(date +%s)
            if ((10#$MARKER_RETRY_DELAY > deadline - now)); then
                return 1
            fi
            sleep "$MARKER_RETRY_DELAY"
        fi
    done
    return 1
}

weights_count() {
    local index=$1
    local host=${result_hosts[$index]}
    local target=${resolved_targets[$index]}
    local count results_path launch_log weights_path
    if [[ "$target" == localhost ]]; then
        results_path="$HOME/$RESULTS_DIR/runs/$run_id/$host"
        launch_log="$results_path/training.log"
        weights_path="$results_path/alexnet_weights"
        if [[ ! -f "$launch_log" || ! -d "$weights_path" ]]; then
            echo 0
            return 0
        fi
        if ! count=$(find "$weights_path" -type f -newer "$launch_log" \
            -print | wc -l); then
            echo probe-failed
            return 0
        fi
    else
        if ! count=$("${SSH_BASE[@]}" "$target" \
            "bash -s -- '$RESULTS_DIR' '$run_id' '$host'" <<'REMOTE'
set -euo pipefail
results_dir=$1
run_id=$2
host=$3
results_path="$HOME/$results_dir/runs/$run_id/$host"
launch_log="$results_path/training.log"
weights="$results_path/alexnet_weights"
if [ ! -f "$launch_log" ] || [ ! -d "$weights" ]; then
    echo 0
else
    find "$weights" -type f -newer "$launch_log" -print | wc -l
fi
REMOTE
        ); then
            echo probe-failed
            return 0
        fi
    fi
    count=${count//[[:space:]]/}
    if [[ "$count" =~ ^[0-9]+$ ]]; then
        echo "$count"
    else
        echo probe-failed
    fi
}

gate_failures=0
for ((host_index = 0; host_index < ${#fleet_hosts[@]}; host_index++)); do
    host=${fleet_hosts[$host_index]}
    marker_state=missing
    if has_marker "$host_index"; then
        marker_state=present
    fi
    weight_total=$(weights_count "$host_index")
    echo "$host: marker=$marker_state weights=$weight_total"
    if [[ "$marker_state" != present || "$weight_total" == probe-failed ]]; then
        gate_failures=$((gate_failures + 1))
    elif [[ "$REQUIRE_WEIGHTS" == 1 && "$weight_total" == 0 ]]; then
        gate_failures=$((gate_failures + 1))
    fi
done

if [[ "$gate_failures" -gt 0 ]]; then
    echo "GATE FAILED: $gate_failures requested host(s) lack required completion evidence." >&2
    exit 1
fi
if [[ "$REQUIRE_WEIGHTS" == 1 ]]; then
    echo "GATE PASSED: every requested container exited successfully with marker and weights evidence."
else
echo "GATE PASSED: every requested container exited successfully with smoke marker evidence."
fi
