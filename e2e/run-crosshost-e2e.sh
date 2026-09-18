#!/usr/bin/env bash
# The former cross-host check made unauthenticated remote task writes and could
# report completion without observing a real worker. That topology is retired.
set -uo pipefail

printf '%s\n' \
  'Cross-host E2E testing is unavailable. Use CI/CD or a reviewed deployment-specific test with explicit transport identity and operator approval.' >&2
exit 2
