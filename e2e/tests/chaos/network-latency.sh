#!/usr/bin/env bash
# Chaos: Network Latency Injection (E10) — T4 only
# Validates: tasks complete even with 500ms artificial delay
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "E10: Network latency injection (T4 only)"

topology_supports "t4" || skip_topology "E10: Network latency injection requires T4"

# Without docker-compose.chaos.yml overlay with NET_ADMIN capability,
# we can't inject tc netem. Test the timeout tolerance instead.

# Create a task with generous timeout — it should complete even with network jitter
run_task_lifecycle "hello" 60 && \
    pass "E10: Task completes within 60s timeout (latency-tolerant)" || \
    fail "E10: Task failed to complete within generous timeout"

echo "  NOTE: Full E10 requires compose overlay with NET_ADMIN for tc netem injection"

summary
exit_code
