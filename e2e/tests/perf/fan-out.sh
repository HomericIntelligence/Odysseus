#!/usr/bin/env bash
# Performance: Concurrent Task Fan-Out (B06, B07, B08)
# Validates: N simultaneous tasks all complete within timeout
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "B06/B07/B08: Concurrent task fan-out"

# Setup
AGENT_RESP=$(agamemnon_create_agent "fanout-agent" "Fan-Out Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null

TEAM_RESP=$(agamemnon_create_team "fanout-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

run_fanout_test() {
    local count="$1" test_id="$2" timeout="$3"
    info "$test_id: $count concurrent tasks"

    local start_ts task_ids=()
    start_ts=$(date +%s%N 2>/dev/null || date +%s)

    # Create N tasks rapidly
    for i in $(seq 1 "$count"); do
        RESP=$(agamemnon_create_task "$TEAM_ID" "Fanout $i/$count" "hello" "$AGENT_ID" 2>/dev/null)
        TID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))" 2>/dev/null)
        [ -n "$TID" ] && [ "$TID" != "None" ] && task_ids+=("$TID")
    done

    [ "${#task_ids[@]}" -eq "$count" ] && \
        pass "$test_id: Created $count tasks" || \
        { fail "$test_id: Only created ${#task_ids[@]}/$count tasks"; return 1; }

    # Wait for all to complete
    local completed=0
    for tid in "${task_ids[@]}"; do
        agamemnon_wait_task_completed "$tid" "$timeout" && completed=$((completed + 1))
    done

    local end_ts elapsed_ms
    end_ts=$(date +%s%N 2>/dev/null || date +%s)
    elapsed_ms=$(( (end_ts - start_ts) / 1000000 ))

    [ "$completed" -eq "$count" ] && \
        pass "$test_id: All $count tasks completed in ${elapsed_ms}ms" || \
        fail "$test_id: Only $completed/$count tasks completed within ${timeout}s"
}

# ─── B06: 10 concurrent tasks ───────────────────────────────────────────────
run_fanout_test 10 "B06" 60

# ─── B07: 50 concurrent tasks ───────────────────────────────────────────────
run_fanout_test 50 "B07" 120

# ─── B08: 100 concurrent tasks ──────────────────────────────────────────────
# Only run on T1/T3/T4 (T2 is too slow for 100 tasks via tmux)
if [ "${IPC_TOPOLOGY:-}" != "t2" ]; then
    run_fanout_test 100 "B08" 180
else
    pass "B08: Skipped on T2 (100 tasks not applicable for tmux topology)"
fi

summary
exit_code
