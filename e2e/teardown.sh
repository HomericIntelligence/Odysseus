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
# Remove containers started outside compose (podman run --replace by start-stack.sh)
podman ps -a --filter name=odysseus --format '{{.Names}}' 2>/dev/null \
  | xargs -r podman rm -f 2>/dev/null || true
podman network rm odysseus_homeric-mesh 2>/dev/null || true
echo "Done."
