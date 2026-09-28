#!/usr/bin/env bash
# Validate NATS authentication declarations at the correct configuration depth.
set -euo pipefail

SCRIPT_DIR="$(CDPATH='' cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname -- "$SCRIPT_DIR")"
LEAF="${1:-$ROOT/configs/nats/leaf.conf}"
SERVER="${2:-$ROOT/configs/nats/server.conf}"

exec python3 "$ROOT/scripts/validate_nats_config.py" --auth "$LEAF" "$SERVER"
