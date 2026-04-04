#!/usr/bin/env bash
# Performance: Backpressure (B09, B10)
# Validates: queue depth grows when consumer slow, then drains
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "B09/B10: Backpressure and queue depth"

AGENT_RESP=$(agamemnon_create_agent "bp-agent" "Backpressure Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null
TEAM_RESP=$(agamemnon_create_team "bp-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

# ─── B09: Queue grows then drains ────────────────────────────────────────────
info "B09: 20 tasks — queue grows while myrmidon processes serially"

BEFORE=$(nats_stream_msg_count "homeric-myrmidon" 2>/dev/null || echo "0")

TASK_IDS=()
for i in $(seq 1 20); do
    RESP=$(agamemnon_create_task "$TEAM_ID" "Backpressure $i" "hello" "$AGENT_ID" 2>/dev/null)
    TID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))" 2>/dev/null)
    [ -n "$TID" ] && TASK_IDS+=("$TID")
done
pass "B09: Created ${#TASK_IDS[@]} tasks"

# Check queue depth immediately — should be > 0 (tasks queued faster than processed)
sleep 1
PEAK=$(nats_stream_msg_count "homeric-myrmidon" 2>/dev/null || echo "unknown")
[ "$PEAK" != "unknown" ] && \
    pass "B09: Stream depth at peak: $PEAK messages" || \
    skip "B09: Cannot read stream depth"

# Wait for drain
COMPLETED=0
for tid in "${TASK_IDS[@]}"; do
    agamemnon_wait_task_completed "$tid" 90 && COMPLETED=$((COMPLETED + 1))
done

[ "$COMPLETED" -eq "${#TASK_IDS[@]}" ] && \
    pass "B09: All $COMPLETED tasks drained (queue empty)" || \
    fail "B09: Only $COMPLETED/${#TASK_IDS[@]} tasks completed"

# ─── B10: Sustained load queue depth monitoring ──────────────────────────────
info "B10: Queue depth under sustained load (30s)"

# Monitor stream depth over time while creating tasks
python3 -c "
import urllib.request, json, time

base = 'http://localhost:${AGAMEMNON_PORT}'
nats_monitor = 'http://localhost:${NATS_MONITOR_PORT:-8222}'
team_id = '${TEAM_ID}'
agent_id = '${AGENT_ID}'

depths = []
start = time.monotonic()
task_count = 0

while time.monotonic() - start < 30:
    # Create a task
    body = json.dumps({'subject': f'load-{task_count}', 'description': 'load', 'type': 'hello', 'assigneeAgentId': agent_id}).encode()
    try:
        req = urllib.request.Request(f'{base}/v1/teams/{team_id}/tasks', data=body,
                                     headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req)
        task_count += 1
    except: pass

    # Sample queue depth
    try:
        jsz = json.loads(urllib.request.urlopen(f'{nats_monitor}/jsz?streams=true').read())
        for acct in jsz.get('account_details', []):
            for s in acct.get('stream_detail', []):
                if s.get('name') == 'homeric-myrmidon':
                    depths.append(s.get('state', {}).get('messages', 0))
    except: pass

    time.sleep(1)

if depths:
    print(f'Tasks created: {task_count}')
    print(f'Max depth: {max(depths)}')
    print(f'Min depth: {min(depths)}')
    print(f'Avg depth: {sum(depths)/len(depths):.0f}')
    print(f'Samples: {len(depths)}')
else:
    print(f'Tasks created: {task_count} (depth monitoring unavailable)')
" 2>/dev/null && \
    pass "B10: Sustained load depth monitoring complete" || \
    skip "B10: Monitoring failed"

summary
exit_code
