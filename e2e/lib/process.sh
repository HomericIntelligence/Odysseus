#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Process Management (T1/T2)
# Manages background processes for non-container topologies.

# Track PIDs for cleanup
_BG_PIDS=()

# Register a PID for cleanup on exit
register_pid() {
    _BG_PIDS+=("$1")
}

# Kill all registered PIDs (SIGTERM first, SIGKILL after 5s)
cleanup_pids() {
    for pid in "${_BG_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill "$pid" 2>/dev/null || true
    done
    sleep 5
    for pid in "${_BG_PIDS[@]}"; do
        kill -0 "$pid" 2>/dev/null && kill -9 "$pid" 2>/dev/null || true
    done
    # Wait to suppress "Killed" messages from bash job control
    for pid in "${_BG_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
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
    register_pid $!
    echo "  Started nats-server (PID $!, port $NATS_PORT, monitor $NATS_MONITOR_PORT)"
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
}
