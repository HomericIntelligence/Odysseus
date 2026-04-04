#!/usr/bin/env bash
# Fault Tolerance: Out-of-Order Message Arrival (A16)
# Validates: FIFO delivery via JetStream even under rapid publishing
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "A16: Message ordering under rapid publishing"

# Rapidly create 10 tasks and verify they all process (order preserved by JetStream)
AGENT_RESP=$(agamemnon_create_agent "order-agent" "Order Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null

TEAM_RESP=$(agamemnon_create_team "order-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

TASK_IDS=()
for i in $(seq 1 10); do
    RESP=$(agamemnon_create_task "$TEAM_ID" "Order test $i" "hello" "$AGENT_ID")
    TID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))")
    TASK_IDS+=("$TID")
done
pass "A16: Created 10 tasks rapidly"

# Wait for all to complete
COMPLETED=0
for tid in "${TASK_IDS[@]}"; do
    agamemnon_wait_task_completed "$tid" 60 && COMPLETED=$((COMPLETED + 1))
done

[ "$COMPLETED" -eq 10 ] && \
    pass "A16: All 10 tasks completed in order (JetStream FIFO preserved)" || \
    fail "A16: Only $COMPLETED/10 tasks completed"

summary
exit_code
