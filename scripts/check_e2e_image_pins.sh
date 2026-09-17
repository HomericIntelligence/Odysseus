#!/usr/bin/env bash
# Validate image digests through the descriptor-bound Compose parser.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
COMPOSE_FILE="${1:-docker-compose.e2e.yml}"
PYTHON_BIN="${PYTHON_BIN:-python3}"

exec "$PYTHON_BIN" "$SCRIPT_DIR/validate_compose.py" \
  --image-pins "$COMPOSE_FILE"
