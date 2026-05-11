#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="${COMPOSE_FILE:-$ODYSSEUS_ROOT/docker-compose.e2e.yml}"

if command -v podman &>/dev/null && podman compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="podman compose"
else
  COMPOSE_CMD="docker compose"
fi

echo "Tearing down HomericIntelligence E2E stack..."
$COMPOSE_CMD -f "$COMPOSE_FILE" down -v --remove-orphans 2>&1
# Remove containers started outside compose (podman run --replace by start-stack.sh).
# `xargs -r` is a no-op when the list is empty, so the only way this fails is
# if a listed container is genuinely un-removable — surface that as a warning.
if names=$(podman ps -a --filter name=odysseus --format '{{.Names}}' 2>/dev/null) && [ -n "$names" ]; then
  if ! printf '%s\n' "$names" | xargs -r podman rm -f; then
    echo "warn: failed to remove some odysseus containers (idempotent teardown)" >&2
  fi
fi
# Removing a non-existent network exits non-zero — that's expected on a fresh
# host, so guard with `network exists` first.
if podman network exists odysseus_homeric-mesh 2>/dev/null; then
  if ! podman network rm odysseus_homeric-mesh; then
    echo "warn: failed to remove network odysseus_homeric-mesh" >&2
  fi
fi
echo "Done."
