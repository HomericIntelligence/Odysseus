#!/usr/bin/env bash
# Topology T2: Multiple shells via tmux
# Each service runs in its own tmux pane with a separate PTY.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ODYSSEUS_ROOT/e2e/lib/common.sh"

SESSION_NAME="hi-ipc-test"
NATS_PORT="${NATS_PORT:-14222}"
NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-18222}"
AGAMEMNON_PORT="${AGAMEMNON_PORT:-18080}"

ACTION="${1:-setup}"

case "$ACTION" in
    setup)
        command -v tmux &>/dev/null || { echo "ERROR: tmux not installed" >&2; exit 1; }

        if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
            echo "Session '$SESSION_NAME' already exists. Run: $0 teardown"
            exit 1
        fi

        info "Creating tmux session: $SESSION_NAME"

        # Pane 0: NATS server
        tmux new-session -d -s "$SESSION_NAME" -n "services" \
            "nats-server -js -p $NATS_PORT -m $NATS_MONITOR_PORT --store_dir /tmp/hi-ipc-nats 2>&1; read"

        wait_for "http://localhost:${NATS_MONITOR_PORT}/healthz" "NATS" 15 || {
            echo "NATS failed to start in tmux. Check: tmux attach -t $SESSION_NAME" >&2
            exit 1
        }
        echo "  NATS running (port $NATS_PORT, monitor $NATS_MONITOR_PORT)"

        # Pane 1: Agamemnon
        agamemnon_bin=""
        for candidate in \
            "${ODYSSEUS_ROOT}/build/ProjectAgamemnon/ProjectAgamemnon_server" \
            "${ODYSSEUS_ROOT}/control/ProjectAgamemnon/build/debug/ProjectAgamemnon_server"; do
            [ -x "$candidate" ] && agamemnon_bin="$candidate" && break
        done
        [ -z "$agamemnon_bin" ] && { echo "ERROR: ProjectAgamemnon_server not found" >&2; exit 1; }

        tmux split-window -t "$SESSION_NAME" -h \
            "NATS_URL=nats://localhost:$NATS_PORT PORT=$AGAMEMNON_PORT $agamemnon_bin 2>&1; read"

        wait_for "http://localhost:${AGAMEMNON_PORT}/v1/health" "Agamemnon" 20 || {
            echo "Agamemnon failed. Check: tmux attach -t $SESSION_NAME" >&2
            exit 1
        }
        echo "  Agamemnon running (port $AGAMEMNON_PORT)"

        # Pane 2: Hello myrmidon
        tmux split-window -t "$SESSION_NAME" -v \
            "NATS_URL=nats://localhost:$NATS_PORT python3 $ODYSSEUS_ROOT/provisioning/Myrmidons/hello-world/main.py 2>&1; read"

        sleep 2
        echo "  Hello-myrmidon running"

        echo ""
        echo "Services ready in tmux session '$SESSION_NAME'."
        echo "  Attach:   tmux attach -t $SESSION_NAME"
        echo "  Test:     just e2e-test-tmux-run"
        echo "  Teardown: just e2e-test-tmux-teardown"
        ;;

    teardown)
        tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
        rm -rf /tmp/hi-ipc-nats 2>/dev/null || true
        echo "Tmux session '$SESSION_NAME' terminated."
        ;;

    *)
        echo "Usage: $0 setup|teardown" >&2
        exit 1
        ;;
esac
