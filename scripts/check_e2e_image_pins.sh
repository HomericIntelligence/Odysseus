#!/usr/bin/env bash
# Fail if any image: in docker-compose.e2e.yml is not pinned to a @sha256 digest.
# Wired into CI (.github/workflows/ci.yml, validate job) so a regression to a
# floating tag (:latest / :alpine) is caught on every PR, not just locally.
set -euo pipefail

COMPOSE_FILE="${1:-docker-compose.e2e.yml}"

if [ ! -f "$COMPOSE_FILE" ]; then
  echo "ERROR: $COMPOSE_FILE not found (run from repo root)." >&2
  exit 2
fi

# Any 'image:' line that does NOT contain a 64-hex sha256 digest is unpinned.
unpinned="$(grep -nE '^[[:space:]]*image:' "$COMPOSE_FILE" \
  | grep -vE '@sha256:[0-9a-f]{64}([[:space:]]|$)' || true)"

if [ -n "$unpinned" ]; then
  echo "ERROR: unpinned (non-digest) image references in $COMPOSE_FILE:" >&2
  echo "$unpinned" >&2
  echo "Pin each to name:<version>@sha256:<manifest-list-digest> for reproducible e2e runs (#188)." >&2
  exit 1
fi

echo "OK: all image: references in $COMPOSE_FILE are digest-pinned."
