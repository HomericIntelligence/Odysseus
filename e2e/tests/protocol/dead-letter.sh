#!/usr/bin/env bash
# Protocol Correctness: Dead Letter Handling (C08)
# Validates: publishing to non-existent subjects doesn't cause panics
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "C08: Dead letter — publish to non-existent subject"

# Setup
AGENT_RESP=$(agamemnon_create_agent "dead-letter-agent" "Dead Letter Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null

TEAM_RESP=$(agamemnon_create_team "dead-letter-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

# Create a task with type=nonexistent — dispatches to hi.myrmidon.nonexistent.{task_id}
# No myrmidon subscribes to this subject, so the message has no consumer.
TASK_RESP=$(agamemnon_create_task "$TEAM_ID" "Dead letter test" "nonexistent" "$AGENT_ID")
TASK_ID=$(echo "$TASK_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))")

[ -n "$TASK_ID" ] && [ "$TASK_ID" != "None" ] && \
    pass "C08: Task created with nonexistent type (no subscriber)" || \
    fail_exit "C08: Task creation failed"

# Wait briefly — task should stay pending (no consumer to process it)
sleep 5

STATUS=$(agamemnon_get_task_status "$TASK_ID")
[ "$STATUS" = "pending" ] && \
    pass "C08: Task stays pending (dead letter — no subscriber panic)" || \
    fail "C08: Expected 'pending' for unroutable task, got '$STATUS'"

# Verify Agamemnon is still healthy (didn't crash from undeliverable message)
HEALTH=$(agamemnon_health)
echo "$HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok'" 2>/dev/null && \
    pass "C08: Agamemnon still healthy after dead letter dispatch" || \
    fail "C08: Agamemnon unhealthy after dead letter"

# Verify NATS is still healthy
nats_health && \
    pass "C08: NATS still healthy after dead letter message" || \
    fail "C08: NATS unhealthy after dead letter"

summary
exit_code
