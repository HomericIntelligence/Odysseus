#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Topology Management
# Dispatches start/stop/health to the correct topology handler.

_TOPOLOGY_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOPOLOGIES_DIR="$(dirname "$_TOPOLOGY_LIB_DIR")/topologies"

# Source dependencies
source "$_TOPOLOGY_LIB_DIR/common.sh"
source "$_TOPOLOGY_LIB_DIR/process.sh"

# ─── Start ───────────────────────────────────────────────────────────────────

topology_start() {
    local mode="${1:-t1}"
    export IPC_TOPOLOGY="$mode"

    case "$mode" in
        t1)
            info "Topology T1: Single shell, background processes"
            start_nats_bg || return 1
            start_agamemnon_bg || return 1
            start_myrmidon_bg || return 1
            ;;
        t2)
            info "Topology T2: Multiple shells (tmux)"
            bash "$TOPOLOGIES_DIR/t2-tmux.sh" setup || return 1
            ;;
        t3)
            info "Topology T3: Single Docker container"
            bash "$TOPOLOGIES_DIR/t3-single-container.sh" start || return 1
            ;;
        t4)
            info "Topology T4: Multiple Docker containers (compose)"
            bash "$TOPOLOGIES_DIR/t4-compose.sh" start || return 1
            ;;
        *)
            echo "ERROR: Unknown topology '$mode'. Use t1|t2|t3|t4." >&2
            return 1
            ;;
    esac
}

# ─── Stop ────────────────────────────────────────────────────────────────────

topology_stop() {
    local mode="${1:-$IPC_TOPOLOGY}"
    case "$mode" in
        t1)
            cleanup_all
            ;;
        t2)
            bash "$TOPOLOGIES_DIR/t2-tmux.sh" teardown 2>/dev/null
            ;;
        t3)
            bash "$TOPOLOGIES_DIR/t3-single-container.sh" stop 2>/dev/null
            ;;
        t4)
            bash "$TOPOLOGIES_DIR/t4-compose.sh" stop 2>/dev/null
            ;;
    esac
}

# ─── Health Check ────────────────────────────────────────────────────────────

topology_wait_healthy() {
    local mode="${1:-$IPC_TOPOLOGY}"

    # For T1/T2, ports are non-default
    if [ "$mode" = "t1" ] || [ "$mode" = "t2" ]; then
        export NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-18222}"
        export AGAMEMNON_PORT="${AGAMEMNON_PORT:-18080}"
    else
        export NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-8222}"
        export AGAMEMNON_PORT="${AGAMEMNON_PORT:-8080}"
    fi

    source "$_TOPOLOGY_LIB_DIR/nats.sh"
    source "$_TOPOLOGY_LIB_DIR/agamemnon.sh"

    nats_wait_healthy 15 || return 1
    agamemnon_wait_healthy 20 || return 1
}
