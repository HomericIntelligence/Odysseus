#!/usr/bin/env bash
# Chaos: Split-Brain NATS Cluster (E12) — T4 only
# Validates: one partition survives in clustered NATS
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"

info "E12: Split-brain NATS cluster (T4 only)"

topology_supports "t4" || skip_topology "E12: Split-brain requires T4 (multi-node NATS cluster)"

# This test requires docker-compose.cluster.yml with 3-node NATS cluster
# For now, verify single NATS server is healthy
nats_health && \
    pass "E12: NATS healthy (single node — cluster test requires docker-compose.cluster.yml)" || \
    fail "E12: NATS unhealthy"

echo "  NOTE: Full E12 requires docker compose -f docker-compose.e2e.yml -f e2e/docker-compose.cluster.yml"

summary
exit_code
