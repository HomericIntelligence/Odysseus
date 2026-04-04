#!/usr/bin/env bash
# Topology T3: Single Docker container with NATS + Agamemnon + myrmidon
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
source "$ODYSSEUS_ROOT/e2e/lib/common.sh"

COMPOSE_CMD=$(detect_compose_cmd)
CONTAINER_CMD="${COMPOSE_CMD%% *}"  # podman or docker
IMAGE_NAME="hi-ipc-single-container"

ACTION="${1:-start}"

case "$ACTION" in
    start)
        [ -z "$CONTAINER_CMD" ] && { echo "ERROR: No container runtime found" >&2; exit 1; }

        info "Building single-container E2E image"
        "$CONTAINER_CMD" build \
            -t "$IMAGE_NAME" \
            -f "$ODYSSEUS_ROOT/e2e/single-container/Dockerfile" \
            "$ODYSSEUS_ROOT" 2>&1 | tail -5

        info "Running single-container E2E tests"
        "$CONTAINER_CMD" run --rm "$IMAGE_NAME"
        ;;

    stop)
        # Container is --rm, nothing to stop
        "$CONTAINER_CMD" rmi "$IMAGE_NAME" 2>/dev/null || true
        ;;

    *)
        echo "Usage: $0 start|stop" >&2
        exit 1
        ;;
esac
