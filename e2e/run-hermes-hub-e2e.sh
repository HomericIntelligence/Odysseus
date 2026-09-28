#!/usr/bin/env bash
# The former Hermes-Hub test made remote writes through a fixed Tailscale
# topology. No current repository contract can authorize or secure that run.
set -uo pipefail

printf '%s\n' \
  'Hermes-Hub remote testing is unavailable. Use CI/CD or a reviewed deployment-specific test path.' >&2
exit 2
