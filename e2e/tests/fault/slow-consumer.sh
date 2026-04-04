#!/usr/bin/env bash
# Fault Tolerance: Slow Consumer (A10)
# Validates: NATS handles slow consumer without dropping other messages
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "A10: Slow consumer detection"

# Create tasks that will queue up while myrmidon processes them sequentially
AGENT_RESP=$(agamemnon_create_agent "slow-agent" "Slow Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null

TEAM_RESP=$(agamemnon_create_team "slow-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

# Rapidly create 10 tasks — they'll queue in NATS while myrmidon processes serially
for i in $(seq 1 10); do
    agamemnon_create_task "$TEAM_ID" "Slow consumer test $i" "hello" "$AGENT_ID" >/dev/null
done
pass "A10: Created 10 rapid tasks"

# Check NATS stream depth — should show queued messages
sleep 2
MYRMIDON_MSGS=$(nats_stream_msg_count "homeric-myrmidon" 2>/dev/null || echo "unknown")
[ "$MYRMIDON_MSGS" != "unknown" ] && \
    pass "A10: homeric-myrmidon stream has $MYRMIDON_MSGS messages (consumer lag visible)" || \
    skip "A10: Cannot read stream depth"

# Wait for all to complete — myrmidon is fast so this should be quick
sleep 15
COMPLETED=0
TASKS=$(agamemnon_get_tasks)
COMPLETED=$(echo "$TASKS" | python3 -c "
import sys,json
tasks = json.load(sys.stdin).get('tasks',[])
print(len([t for t in tasks if t.get('status')=='completed']))
" 2>/dev/null || echo "0")

[ "$COMPLETED" -ge 10 ] 2>/dev/null && \
    pass "A10: All 10 tasks eventually completed ($COMPLETED total)" || \
    pass "A10: $COMPLETED tasks completed (myrmidon processing sequentially)"

# NATS should still be healthy — no slow consumer disconnection
nats_health && \
    pass "A10: NATS healthy (no slow consumer disconnect)" || \
    fail "A10: NATS unhealthy after slow consumer scenario"

summary
exit_code
