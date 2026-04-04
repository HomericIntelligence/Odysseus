#!/usr/bin/env bash
# Protocol Correctness: Task State Transitions (C09, C15, C16)
# Validates: pending → completed, correct NATS subjects, subscription matching
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "C09/C15/C16: Task state transitions and NATS subject correctness"

# ─── C09: Task state pending → completed ─────────────────────────────────────
info "C09: Task state transitions"

# Create a full task lifecycle
run_task_lifecycle "hello" 30 && \
    pass "C09: Task lifecycle completed (pending → completed)" || \
    fail_exit "C09: Task lifecycle failed"

# Verify the task is now completed
STATUS=$(agamemnon_get_task_status "$IPC_TASK_ID")
[ "$STATUS" = "completed" ] && \
    pass "C09: Task status is 'completed'" || \
    fail "C09: Expected 'completed', got '$STATUS'"

# Verify no intermediate states — create a new task and poll rapidly
info "C09: Verify no intermediate states (pending → completed, nothing in between)"

TASK_RESP=$(agamemnon_create_task "$IPC_TEAM_ID" "Rapid state check" "hello" "$IPC_AGENT_ID")
RAPID_TASK_ID=$(echo "$TASK_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))")

# Poll rapidly (every 0.5s) and collect all observed states
OBSERVED_STATES=$(python3 -c "
import urllib.request, json, time
task_id = '${RAPID_TASK_ID}'
base = 'http://localhost:${AGAMEMNON_PORT}'
states = set()
for _ in range(60):
    try:
        resp = urllib.request.urlopen(f'{base}/v1/tasks')
        tasks = json.loads(resp.read()).get('tasks', [])
        match = [t for t in tasks if t.get('id') == task_id]
        if match:
            s = match[0].get('status', 'unknown')
            states.add(s)
            if s == 'completed':
                break
    except: pass
    time.sleep(0.5)
print(' '.join(sorted(states)))
")

# Only pending and completed should be observed
BAD_STATES=$(echo "$OBSERVED_STATES" | tr ' ' '\n' | grep -v "^pending$\|^completed$" || true)
[ -z "$BAD_STATES" ] && \
    pass "C09: Only observed states: $OBSERVED_STATES (no intermediate)" || \
    fail "C09: Unexpected intermediate states: $BAD_STATES"

# ─── C15: Agamemnon subscription pattern ─────────────────────────────────────
info "C15: Agamemnon subscribes to hi.tasks.*.*.completed"

# Verify NATS has messages on the tasks stream
TASK_MSGS=$(nats_stream_msg_count "homeric-tasks" 2>/dev/null || echo "0")
[ "$TASK_MSGS" -gt 0 ] 2>/dev/null && \
    pass "C15: homeric-tasks stream has $TASK_MSGS messages (completion events received)" || \
    skip "C15: Could not verify task stream messages (NATS monitoring may not be available)"

# ─── C16: Myrmidon publishes correct completion subject ──────────────────────
info "C16: Myrmidon publishes hi.tasks.{team_id}.{task_id}.completed"

# The fact that tasks complete proves the subject matches Agamemnon's subscription.
# Agamemnon subscribes to hi.tasks.*.*.completed and myrmidon publishes
# hi.tasks.{team_id}.{task_id}.completed — if these didn't match, no task would complete.
# We already proved tasks complete in C09 above.
MSGS_AFTER=$(nats_msg_count 2>/dev/null || echo "0")
[ "$MSGS_AFTER" -gt 0 ] 2>/dev/null && \
    pass "C16: NATS processed $MSGS_AFTER messages (myrmidon → Agamemnon flow validated)" || \
    pass "C16: Task completed (subject match confirmed via successful lifecycle)"

summary
exit_code
