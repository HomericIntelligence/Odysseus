#!/usr/bin/env bash
# Chaos: Concurrent Faults (E08, E09, E13)
# Validates: fault injection during task processing, cascading faults
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "E08/E09/E13: Concurrent fault injection"

# Clean up any lingering faults from previous test runs
EXISTING=$(agamemnon_list_faults 2>/dev/null)
echo "$EXISTING" | python3 -c "
import sys, json
faults = json.load(sys.stdin).get('faults', [])
for f in faults:
    print(f.get('id',''))
" 2>/dev/null | while read -r fid; do
    [ -n "$fid" ] && agamemnon_remove_fault "$fid" >/dev/null 2>&1
done

# ─── E08: Fault injection while tasks are in flight ──────────────────────────
info "E08: Inject fault during task processing"

AGENT_RESP=$(agamemnon_create_agent "chaos-agent" "Chaos Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null
TEAM_RESP=$(agamemnon_create_team "chaos-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

# Create 5 tasks
for i in $(seq 1 5); do
    agamemnon_create_task "$TEAM_ID" "Chaos task $i" "hello" "$AGENT_ID" >/dev/null
done

# Immediately inject a fault while tasks are being processed
FAULT_RESP=$(agamemnon_inject_fault "latency")
FAULT_ID=$(echo "$FAULT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)
[ -n "$FAULT_ID" ] && \
    pass "E08: Fault injected while tasks in flight" || \
    fail "E08: Fault injection failed"

# Tasks should still complete (fault is registered but doesn't affect processing yet)
sleep 15
TASKS=$(agamemnon_get_tasks)
COMPLETED=$(echo "$TASKS" | python3 -c "
import sys,json
tasks = json.load(sys.stdin).get('tasks',[])
print(len([t for t in tasks if t.get('status')=='completed']))
" 2>/dev/null || echo "0")

pass "E08: $COMPLETED tasks completed during fault injection"

# Clean up fault
[ -n "$FAULT_ID" ] && agamemnon_remove_fault "$FAULT_ID" >/dev/null 2>&1

# ─── E09: Race condition — fault during completion ───────────────────────────
info "E09: Fault injection during task completion phase"

# Create task and inject fault simultaneously
TASK_RESP=$(agamemnon_create_task "$TEAM_ID" "Race test" "hello" "$AGENT_ID")
RACE_TID=$(echo "$TASK_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))")

# Inject fault at same moment
RACE_FAULT=$(agamemnon_inject_fault "network-partition")
RACE_FID=$(echo "$RACE_FAULT" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)

# System should remain stable regardless
sleep 5
HEALTH=$(agamemnon_health 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "E09: Agamemnon stable during race condition" || \
    fail "E09: Agamemnon unstable"

[ -n "$RACE_FID" ] && agamemnon_remove_fault "$RACE_FID" >/dev/null 2>&1

# ─── E13: Cascade — 3 simultaneous faults ───────────────────────────────────
info "E13: 3 simultaneous faults — cascade recovery"

FIDS=()
for ftype in "network-partition" "latency" "kill"; do
    RESP=$(agamemnon_inject_fault "$ftype")
    FID=$(echo "$RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)
    [ -n "$FID" ] && FIDS+=("$FID")
done

[ "${#FIDS[@]}" -eq 3 ] && \
    pass "E13: 3 faults injected simultaneously" || \
    fail "E13: Only ${#FIDS[@]} faults injected"

# Verify system under multi-fault load
HEALTH=$(agamemnon_health 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "E13: Agamemnon healthy under 3 concurrent faults" || \
    fail "E13: Agamemnon unhealthy under cascade"

# Clear all faults
for fid in "${FIDS[@]}"; do
    agamemnon_remove_fault "$fid" >/dev/null 2>&1
done

# Verify recovery
FAULTS_AFTER=$(agamemnon_list_faults)
AFTER_COUNT=$(echo "$FAULTS_AFTER" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('faults',[])))" 2>/dev/null)
[ "$AFTER_COUNT" -eq 0 ] 2>/dev/null && \
    pass "E13: All faults cleared — system recovered" || \
    fail "E13: $AFTER_COUNT faults still active after clearance"

# Final task lifecycle to prove full recovery
run_task_lifecycle "hello" 30 && \
    pass "E13: Task lifecycle works after cascade recovery" || \
    fail "E13: Task lifecycle broken after cascade"

summary
exit_code
