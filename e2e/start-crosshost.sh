#!/usr/bin/env bash
# Retained compatibility entry point for the retired cross-host E2E launcher.
set -euo pipefail

cat >&2 <<'EOF'
ERROR: the cross-host launcher is unavailable at the current repository pins.
The retired Compose topology exposed unauthenticated services and could not
satisfy the canonical least-privilege NATS policy. It also lacks an approved,
verified host bind and remote desired-state boundary.

Do not start or replace containers through this script. First land and
integrate compatible client authentication and an isolated topology with
explicit operator-approved targets, then add a new behavior-tested launcher.
See docs/deployment.md for the current deployment boundary.
EOF
exit 2
