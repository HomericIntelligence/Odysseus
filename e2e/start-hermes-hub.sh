#!/usr/bin/env bash
# The former Hermes-Hub launcher used unauthenticated NATS and fixed remote
# hosts. No current repository contract can authorize or secure that topology.
set -uo pipefail

printf '%s\n' \
  'Hermes-Hub activation is unavailable. Use a reviewed deployment path with explicit transport identity and operator approval.' >&2
exit 2
