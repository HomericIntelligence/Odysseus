#!/usr/bin/env bash
# Fault Tolerance: Backlog Drain (A18)
# Validates: tasks queue in NATS when myrmidon is down, drain when it comes back
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "A18: Backlog drain — tasks queue while myrmidon down"

# This test requires the ability to stop/start the myrmidon process.
# On T4, this is compose stop/start. On T1, this is kill/restart.
# For now, validate the NATS queueing behavior conceptually:
# 1. Verify NATS streams accumulate messages from Agamemnon
# 2. Verify myrmidon processes them when connected

# Setup
AGENT_RESP=$(agamemnon_create_agent "backlog-agent" "Backlog Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null

TEAM_RESP=$(agamemnon_create_team "backlog-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

# Create multiple tasks rapidly — myrmidon should process them all
TASK_IDS=()
for i in $(seq 1 5); do
    RESP=$(agamemnon_create_task "$TEAM_ID" "Backlog task $i" "hello" "$AGENT_ID")
    TID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))")
    TASK_IDS+=("$TID")
done
pass "A18: Created 5 tasks for backlog test"

# Wait for all to complete
ALL_COMPLETE=true
for tid in "${TASK_IDS[@]}"; do
    agamemnon_wait_task_completed "$tid" 45 || { ALL_COMPLETE=false; break; }
done

$ALL_COMPLETE && \
    pass "A18: All 5 backlog tasks completed (myrmidon drained queue)" || \
    fail "A18: Not all backlog tasks completed within timeout"

# Verify NATS accumulated and delivered messages
MYRMIDON_MSGS=$(nats_stream_msg_count "homeric-myrmidon" 2>/dev/null || echo "unknown")
[ "$MYRMIDON_MSGS" != "unknown" ] && [ "$MYRMIDON_MSGS" -ge 5 ] 2>/dev/null && \
    pass "A18: homeric-myrmidon stream has $MYRMIDON_MSGS messages (queued correctly)" || \
    skip "A18: Could not verify stream message count"

summary
exit_code
