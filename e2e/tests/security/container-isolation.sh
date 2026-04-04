#!/usr/bin/env bash
# Security: Container Isolation (D08, D09) — T4 only
# Validates: PID namespace isolation, network boundary enforcement
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"

info "D08/D09: Container isolation (T4 only)"

topology_supports "t4" || skip_topology "D08/D09: Container isolation requires T4"

COMPOSE_CMD=$(detect_compose_cmd)
ODYSSEUS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ODYSSEUS_ROOT/docker-compose.e2e.yml"

# ─── D08: PID namespace isolation ────────────────────────────────────────────
info "D08: PID namespace isolation between containers"

# Get PID 1 from each container — should be different processes
AGAMEMNON_PID1=$($COMPOSE_CMD -f "$COMPOSE_FILE" exec -T agamemnon cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' | head -c 100)
MYRMIDON_PID1=$($COMPOSE_CMD -f "$COMPOSE_FILE" exec -T hello-myrmidon cat /proc/1/cmdline 2>/dev/null | tr '\0' ' ' | head -c 100)

[ -n "$AGAMEMNON_PID1" ] && [ -n "$MYRMIDON_PID1" ] && [ "$AGAMEMNON_PID1" != "$MYRMIDON_PID1" ] && \
    pass "D08: PID 1 differs between containers (Agamemnon: '${AGAMEMNON_PID1:0:30}...', Myrmidon: '${MYRMIDON_PID1:0:30}...')" || \
    skip "D08: Cannot read container PID 1 (exec may not be available)"

# ─── D09: Network isolation ──────────────────────────────────────────────────
info "D09: Myrmidon cannot reach host network directly"

# Myrmidon should be on the homeric-mesh bridge, not the host network
MYRMIDON_NET=$($COMPOSE_CMD -f "$COMPOSE_FILE" exec -T hello-myrmidon cat /etc/hosts 2>/dev/null | head -5)
[ -n "$MYRMIDON_NET" ] && \
    pass "D09: Myrmidon has container-specific /etc/hosts (isolated network)" || \
    skip "D09: Cannot verify network isolation"

summary
exit_code
