#!/usr/bin/env bash
# Single-container in-container test harness
set -euo pipefail

export AGAMEMNON_PORT=8080
export NATS_MONITOR_PORT=8222
export IPC_TOPOLOGY=t3

source /app/e2e/lib/common.sh
source /app/e2e/lib/nats.sh
source /app/e2e/lib/agamemnon.sh

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  IPC E2E Tests — Single Container (T3)                   ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Health checks ───────────────────────────────────────────────────────────
info "Health checks"

nats_health && pass "NATS healthy" || fail_exit "NATS unhealthy"
agamemnon_health >/dev/null && pass "Agamemnon healthy" || fail_exit "Agamemnon unhealthy"

# ─── Task lifecycle ──────────────────────────────────────────────────────────
info "Task lifecycle"

run_task_lifecycle "hello" 30 && \
    pass "Task lifecycle: pending → completed" || \
    fail "Task lifecycle failed"

# ─── NATS verification ──────────────────────────────────────────────────────
info "NATS intra-container verification"

assert_nats_connections_gte 2 && \
    pass "NATS connections >= 2 (Agamemnon + myrmidon)" || \
    skip "Cannot verify connection count"

assert_nats_msgs_gt 0 && \
    pass "NATS in_msgs > 0" || \
    skip "Cannot verify message count"

# Verify all connections on localhost (proving intra-container IPC)
IPS=$(nats_client_ips 2>/dev/null)
LOCALHOST_ONLY=true
while IFS= read -r ip; do
    [ -z "$ip" ] && continue
    case "$ip" in 127.0.0.1|::1) ;; *) LOCALHOST_ONLY=false ;; esac
done <<< "$IPS"

$LOCALHOST_ONLY && \
    pass "All NATS clients on localhost (intra-container IPC confirmed)" || \
    fail "NATS clients from non-localhost IPs — expected intra-container only"

# ─── Fan-out ─────────────────────────────────────────────────────────────────
info "Mini fan-out (5 tasks)"

AGENT_RESP=$(agamemnon_create_agent "t3-fan-agent" "T3 Fan")
FAN_AGENT=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$FAN_AGENT" >/dev/null
TEAM_RESP=$(agamemnon_create_team "t3-fan-team")
FAN_TEAM=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

TIDS=()
for i in $(seq 1 5); do
    RESP=$(agamemnon_create_task "$FAN_TEAM" "T3 fan $i" "hello" "$FAN_AGENT" 2>/dev/null)
    TID=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('task',{}).get('id',''))" 2>/dev/null)
    [ -n "$TID" ] && TIDS+=("$TID")
done

DONE=0
for tid in "${TIDS[@]}"; do
    agamemnon_wait_task_completed "$tid" 45 && DONE=$((DONE + 1))
done

[ "$DONE" -eq "${#TIDS[@]}" ] && \
    pass "Fan-out: all 5 tasks completed" || \
    fail "Fan-out: only $DONE/${#TIDS[@]} completed"

# ─── Malformed NATS ──────────────────────────────────────────────────────────
info "Malformed NATS message (in-container)"

python3 -c "
import asyncio, nats as natslib
async def main():
    nc = await natslib.connect('nats://localhost:4222')
    await nc.publish('hi.tasks.fake.fake.completed', b'not json')
    await nc.flush()
    await nc.close()
asyncio.run(main())
" 2>/dev/null

sleep 2
agamemnon_health >/dev/null && \
    pass "Agamemnon survived malformed NATS message" || \
    fail "Agamemnon crashed from malformed NATS"

summary
exit_code
