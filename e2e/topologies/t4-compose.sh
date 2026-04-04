#!/usr/bin/env bash
# Topology T4: Multiple Docker containers via compose
# Thin wrapper around existing docker-compose.e2e.yml infrastructure.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"

ACTION="${1:-start}"

case "$ACTION" in
    start)
        bash "$ODYSSEUS_ROOT/e2e/start-stack.sh"
        ;;
    stop)
        bash "$ODYSSEUS_ROOT/e2e/teardown.sh"
        ;;
    *)
        echo "Usage: $0 start|stop" >&2
        exit 1
        ;;
esac
