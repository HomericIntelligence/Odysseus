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

start_nats_bg() {
    NATS_DATA_DIR=$(mktemp -d /tmp/hi-nats-XXXXXX)
    local nats_bin
    nats_bin=$(command -v nats-server 2>/dev/null) || {
        echo "ERROR: nats-server not found in PATH" >&2
        return 1
    }
    "$nats_bin" -js \
        -p "$NATS_PORT" \
        -m "$NATS_MONITOR_PORT" \
        --store_dir "$NATS_DATA_DIR" \
        >/dev/null 2>&1 &
    NATS_BG_PID=$!                       # explicit handle for kill/restart (issue #184)
    export NATS_BG_PID NATS_BIN="$nats_bin" NATS_PORT NATS_MONITOR_PORT NATS_DATA_DIR
    register_pid "$NATS_BG_PID"
    echo "  Started nats-server (PID $NATS_BG_PID, port $NATS_PORT, monitor $NATS_MONITOR_PORT)"
    wait_for "http://localhost:${NATS_MONITOR_PORT}/healthz" "NATS" 15
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
    local bin=""
    # Binary name from: provisioning/Myrmidons/hello-world/CMakeLists.txt:34
    #   add_executable(hello_myrmidon main.cpp)
    for candidate in \
        "${odysseus_root}/build/Myrmidons/hello-world/hello_myrmidon" \
        "${odysseus_root}/provisioning/Myrmidons/hello-world/build/hello_myrmidon" \
        "$(command -v hello_myrmidon 2>/dev/null)"; do
        [ -x "$candidate" ] && bin="$candidate" && break
    done
    [ -z "$bin" ] && { echo "ERROR: hello_myrmidon binary not found. Run 'just build' first." >&2; return 1; }

    NATS_URL="nats://localhost:${NATS_PORT}" "$bin" >/dev/null 2>&1 &
    register_pid $!
    echo "  Started hello-myrmidon (PID $!, bin $bin)"
    sleep 2  # Allow subscription to establish
}

# ─── Cleanup ─────────────────────────────────────────────────────────────────

cleanup_all() {
    cleanup_pids
    [ -n "$NATS_DATA_DIR" ] && rm -rf "$NATS_DATA_DIR"
}
