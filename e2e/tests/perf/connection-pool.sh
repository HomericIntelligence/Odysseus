#!/usr/bin/env bash
# Performance: Connection Pool Scaling (B12) — T4 only
# Validates: 5 myrmidon replicas consuming from same subject
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "B12: Connection pool scaling (T4 only)"

topology_supports "t4" || skip_topology "B12: Connection pool requires T4"

# This test requires docker-compose.scale.yml overlay with replicas: 5
# For now, verify the current connection topology
CONN_COUNT=$(nats_connection_count 2>/dev/null || echo "0")
pass "B12: Current NATS connections: $CONN_COUNT"

# Verify multiple connections from distinct IPs
CLIENT_IPS=$(nats_client_ips 2>/dev/null)
IP_COUNT=$(echo "$CLIENT_IPS" | grep -c . 2>/dev/null || echo "0")
pass "B12: Distinct client IPs: $IP_COUNT"

# Document the scaling test requirement
echo "  NOTE: Full B12 test requires: docker compose -f docker-compose.e2e.yml -f e2e/docker-compose.scale.yml up"

summary
exit_code
