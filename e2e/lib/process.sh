#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Process Management (T1/T2)
# Manages background processes for non-container topologies.

# Track PIDs for cleanup
_BG_PIDS=()

# Register a PID for cleanup on exit
register_pid() {
    _BG_PIDS+=("$1")
}

# Kill all registered PIDs (SIGTERM first, SIGKILL after 5s).
# Each helper is explicit about "process not running" being expected, and
# escalates a real (unexpected) kill failure to stderr instead of swallowing it.
_kill_if_alive() {
    local pid="$1" sig="$2"
    if [[ -z "${pid:-}" ]] || ! kill -0 "$pid" 2>/dev/null; then
        return 0  # already gone — nothing to do
    fi
    if ! kill "$sig" "$pid" 2>/dev/null; then
        echo "warn: kill $sig $pid failed (pid still alive?)" >&2
    fi
}

cleanup_pids() {
    for pid in "${_BG_PIDS[@]:-}"; do
        _kill_if_alive "$pid" -TERM
    done
    sleep 5
    for pid in "${_BG_PIDS[@]:-}"; do
        _kill_if_alive "$pid" -KILL
    done
    # Reap children to suppress "Killed" messages from bash job control.
    # `wait` on a not-our-child or already-reaped pid returns 127 — that's
    # expected here, so we ignore wait's exit via an explicit if.
    for pid in "${_BG_PIDS[@]:-}"; do
        if [[ -n "${pid:-}" ]]; then
            if wait "$pid" 2>/dev/null; then
                :
            fi
        fi
    done
    _BG_PIDS=()
}

# Wait until a TCP port is accepting connections
wait_for_port() {
    local port="$1" max="${2:-30}" name="${3:-service}"
    for i in $(seq 1 "$max"); do
        (echo >/dev/tcp/localhost/"$port") 2>/dev/null && return 0
        sleep 1
    done
    echo "  TIMEOUT: $name did not listen on port $port after ${max}s" >&2
    return 1
}

# ─── NATS Server ─────────────────────────────────────────────────────────────

NATS_PORT="${NATS_PORT:-14222}"
NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-18222}"
NATS_DATA_DIR=""
_NATS_PID=""

# Port-keyed meta file so a CHILD test process (run as `bash "$script"`,
# run-ipc-tests.sh:64) can find the PARENT-started NATS server (topology.sh:21).
# _NATS_PID alone is empty across that fork — targeting it would no-op the kill
# and race the still-alive original server (the real #328 defect).
_nats_meta_file() { echo "/tmp/hi-nats-${NATS_MONITOR_PORT}.meta"; }
nats_meta_pid()       { [ -f "$(_nats_meta_file)" ] && sed -n '1p' "$(_nats_meta_file)" || true; }
nats_meta_store_dir() { [ -f "$(_nats_meta_file)" ] && sed -n '2p' "$(_nats_meta_file)" || true; }

start_nats_bg() {
    NATS_DATA_DIR=$(mktemp -d /tmp/hi-nats-XXXXXX)
    start_nats_bg_at "$NATS_DATA_DIR"
}

# Launch nats-server at an explicit store_dir; record PID + dir to the meta file.
start_nats_bg_at() {
    local store_dir="$1"
    NATS_DATA_DIR="$store_dir"
    local nats_bin
    nats_bin=$(command -v nats-server 2>/dev/null) || {
        echo "ERROR: nats-server not found in PATH" >&2
        return 1
    }
    "$nats_bin" -js \
        -p "$NATS_PORT" \
        -m "$NATS_MONITOR_PORT" \
        --store_dir "$store_dir" \
        >/dev/null 2>&1 &
    _NATS_PID=$!
    register_pid "$_NATS_PID"
    printf '%s\n%s\n' "$_NATS_PID" "$store_dir" > "$(_nats_meta_file)"
    echo "  Started nats-server (PID $_NATS_PID, port $NATS_PORT, monitor $NATS_MONITOR_PORT, store $store_dir)"
    wait_for "http://localhost:${NATS_MONITOR_PORT}/healthz" "NATS" 15
}

# Thin margin only. MEASURED: SIGKILLing a process that holds a LISTENING socket
# frees the port immediately — TIME_WAIT does NOT apply (it afflicts the peer that
# actively closes an ESTABLISHED connection, not the server's listen sockets;
# verified 8/8 immediate rebinds). Returning 0 still does not *prove* bind() will
# succeed, so nats_restart also retries the bind.
wait_port_free() {
    local port="$1" max="${2:-5}" name="${3:-port}"
    local _poll
    for _poll in $(seq 1 "$max"); do
        # Use timeout to guard against /dev/tcp blocking on a closed port (WSL2/some kernels).
        timeout 1 bash -c "(echo >/dev/tcp/localhost/$port) 2>/dev/null" 2>/dev/null || return 0
        sleep 1
    done
    return 1
}

# SIGKILL the meta-file-recorded server (works cross-process) AND wait for it to
# fully exit so its socket FD is released before any relaunch — this WAIT, not a
# port poll, is the real fix for the stale-process race.
nats_kill() {
    local pid
    pid="$(nats_meta_pid)"
    [ -z "$pid" ] && pid="${_NATS_PID:-}"
    _kill_if_alive "${pid:-}" -KILL
    # Block until the PID is reaped (FD released). `wait` on a non-child returns
    # 127, so fall back to a bounded kill -0 poll for the cross-process case.
    if [ -n "${pid:-}" ]; then
        wait "$pid" 2>/dev/null || {
            local _poll
            for _poll in $(seq 1 20); do
                kill -0 "$pid" 2>/dev/null || break
                sleep 0.1
            done
        }
    fi
}

# Restart at the ORIGINAL store_dir (JetStream preserved). nats_kill already
# waited for full exit; the short bind-retry only absorbs a residual sub-second
# teardown gap (measured: usually zero). NOT a 2MSL wait — server ports do not
# enter TIME_WAIT.
nats_restart() {
    local store_dir
    store_dir="$(nats_meta_store_dir)"
    [ -z "$store_dir" ] && store_dir="${NATS_DATA_DIR:-$(mktemp -d /tmp/hi-nats-XXXXXX)}"
    nats_kill
    local attempt
    for attempt in 1 2 3; do
        if start_nats_bg_at "$store_dir"; then
            return 0
        fi
        echo "  warn: NATS relaunch attempt $attempt failed (residual FD teardown?); retrying" >&2
        nats_kill
        sleep 1
    done
    echo "  ERROR: NATS did not return healthy after restart (all attempts exhausted)" >&2
    return 1
}

# ─── Agamemnon Server ────────────────────────────────────────────────────────

AGAMEMNON_PORT="${AGAMEMNON_PORT:-18080}"

start_agamemnon_bg() {
    local bin=""
    local odysseus_root="${ODYSSEUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"

    # Search for the binary in known locations
    for candidate in \
        "${odysseus_root}/build/ProjectAgamemnon/ProjectAgamemnon_server" \
        "${odysseus_root}/control/ProjectAgamemnon/build/debug/ProjectAgamemnon_server" \
        "$(command -v ProjectAgamemnon_server 2>/dev/null)"; do
        [ -x "$candidate" ] && bin="$candidate" && break
    done
    [ -z "$bin" ] && { echo "ERROR: ProjectAgamemnon_server not found. Run 'just build' first." >&2; return 1; }

    NATS_URL="nats://localhost:${NATS_PORT}" PORT="$AGAMEMNON_PORT" "$bin" >/dev/null 2>&1 &
    register_pid $!
    echo "  Started Agamemnon (PID $!, port $AGAMEMNON_PORT)"
    wait_for "http://localhost:${AGAMEMNON_PORT}/v1/health" "Agamemnon" 20
}

# ─── Hello Myrmidon ──────────────────────────────────────────────────────────

start_myrmidon_bg() {
    local odysseus_root="${ODYSSEUS_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
    local myrmidon_script="${odysseus_root}/provisioning/Myrmidons/hello-world/main.py"

    [ -f "$myrmidon_script" ] || { echo "ERROR: $myrmidon_script not found" >&2; return 1; }

    NATS_URL="nats://localhost:${NATS_PORT}" python3 "$myrmidon_script" >/dev/null 2>&1 &
    register_pid $!
    echo "  Started hello-myrmidon (PID $!)"
    sleep 2  # Allow subscription to establish
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup_all() {
    cleanup_pids
    [ -n "$NATS_DATA_DIR" ] && rm -rf "$NATS_DATA_DIR"
    rm -f "$(_nats_meta_file)" 2>/dev/null || true
}
