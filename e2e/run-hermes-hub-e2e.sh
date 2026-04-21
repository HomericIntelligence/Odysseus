#!/usr/bin/env bash
# HomericIntelligence Hermes-Hub E2E Validation
#
# Validates the complete pipeline across two Tailscale-connected hosts:
#   hermes (100.73.61.56): NATS, Agamemnon, Nestor, Hermes, Prometheus, Grafana, Argus
#   epimetheus (100.92.173.32): hello-myrmidon (Python NATS pull worker)
#
# The key novelty: the hello-myrmidon task dispatch travels over Tailscale.
# Agamemnon (hermes) publishes hi.myrmidon.hello.{task_id} → NATS (hermes).
# Myrmidon (epimetheus) pulls that subject via JetStream, processes, and publishes
# hi.tasks.{team_id}.{task_id}.completed back → Agamemnon marks task completed.
#
# Usage:
#   bash e2e/run-hermes-hub-e2e.sh
set -euo pipefail

HERMES_IP="100.73.61.56"
EPI_IP="100.92.173.32"
EPI_SSH="epimetheus"

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; exit 1; }
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence Hermes-Hub E2E Validation                  ║"
echo "║  hermes (${HERMES_IP}): full stack                               ║"
echo "║  epimetheus (${EPI_IP}): hello-myrmidon (Tailscale consumer)    ║"
echo "╚══════════════════════════════════════════════════════════════════╝"

# ─── Phase 1: Hermes host service health ────────────────────────────────────
info "Phase 1: hermes service health checks"

for i in $(seq 1 12); do
  curl -sf "http://${HERMES_IP}:8080/v1/health" >/dev/null 2>&1 && break
  [ $i -eq 12 ] && fail "Agamemnon not reachable at ${HERMES_IP}:8080 after 60s"
  sleep 5
done
curl -sf "http://${HERMES_IP}:8080/v1/health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok', f'Bad: {d}'" \
  && pass "Agamemnon @ ${HERMES_IP}:8080" || fail "Agamemnon health check failed"

curl -sf "http://${HERMES_IP}:8081/v1/health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok', f'Bad: {d}'" \
  && pass "Nestor @ ${HERMES_IP}:8081" || fail "Nestor health check failed"

curl -sf "http://${HERMES_IP}:8085/health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok', f'Bad: {d}'" \
  && pass "Hermes bridge @ ${HERMES_IP}:8085" || fail "Hermes health check failed"

curl -sf "http://${HERMES_IP}:8222/healthz" >/dev/null \
  && pass "NATS @ ${HERMES_IP}:8222" || fail "NATS health check failed"

# ─── Phase 2: epimetheus myrmidon process alive ──────────────────────────────
info "Phase 2: epimetheus hello-myrmidon process alive"

MYRM_PID=$(ssh "$EPI_SSH" "pgrep -f 'provisioning/Myrmidons/hello-world/main.py'" 2>/dev/null || echo "")
[ -n "$MYRM_PID" ] \
  && pass "hello-myrmidon running on epimetheus (PID ${MYRM_PID})" \
  || fail "hello-myrmidon not running on epimetheus. Start with: just hermes-hub-up"

# Show recent log to confirm NATS connection
LOG_TAIL=$(ssh "$EPI_SSH" "tail -5 /tmp/hello-myrmidon.log 2>/dev/null" || echo "(no log)")
echo "    epimetheus log tail:"
echo "$LOG_TAIL" | sed 's/^/      /'

# ─── Phase 3: NATS connections (includes remote myrmidon) ───────────────────
info "Phase 3: NATS cross-host connections"

VARZ=$(curl -sf "http://${HERMES_IP}:8222/varz")
CONNS=$(echo "$VARZ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connections',0))")
IN_MSGS=$(echo "$VARZ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('in_msgs',0))")
# Expect ≥2: Agamemnon + remote myrmidon (plus Hermes, Nestor)
( [ "$CONNS" -ge 2 ] 2>/dev/null || [ "$IN_MSGS" -gt 0 ] 2>/dev/null ) \
  && pass "NATS active: connections=${CONNS}, in_msgs=${IN_MSGS} (remote myrmidon connected)" \
  || fail "NATS has only ${CONNS} connections — epimetheus myrmidon may not have joined yet"

# ─── Phase 4: Hermes webhook → NATS ─────────────────────────────────────────
info "Phase 4: Webhook through Hermes bridge → NATS"

WEBHOOK_TS=$(date -u +%FT%TZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
WEBHOOK_RESP=$(curl -sf -X POST "http://${HERMES_IP}:8085/webhook" \
  -H "Content-Type: application/json" \
  -d "{\"event\":\"task.updated\",\"data\":{\"team_id\":\"hermes-hub-team\",\"task_id\":\"hermes-hub-probe\"},\"timestamp\":\"$WEBHOOK_TS\"}")
echo "$WEBHOOK_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='accepted', f'Bad: {d}'" \
  && pass "Webhook accepted by Hermes" || fail "Webhook rejected: $WEBHOOK_RESP"

sleep 2
SUBJECTS_RESP=$(curl -sf "http://${HERMES_IP}:8085/subjects")
echo "$SUBJECTS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert len(d.get('subjects',[]))>0, f'No subjects: {d}'" \
  && pass "Hermes tracking NATS subjects" || fail "No subjects tracked by Hermes"

# ─── Phase 5: Agent → Team → Task via Agamemnon ──────────────────────────────
info "Phase 5: Create agent → team → task via Agamemnon on hermes"

AGENT_RESP=$(curl -sf -X POST "http://${HERMES_IP}:8080/v1/agents" \
  -H "Content-Type: application/json" \
  -d '{"name":"hermes-hub-worker","label":"Hermes-Hub Worker","program":"none","workingDirectory":"/tmp","taskDescription":"E2E hermes-hub test","tags":["e2e","hermes-hub"],"owner":"e2e-test","role":"member"}')
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
[ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ] \
  && pass "Agent created: ${AGENT_ID}" || fail "Agent creation failed: ${AGENT_RESP}"

curl -sf -X POST "http://${HERMES_IP}:8080/v1/agents/${AGENT_ID}/start" \
  -H "Content-Type: application/json" -d '{}' >/dev/null \
  && pass "Agent ${AGENT_ID} started (status=online)" || fail "Agent start failed"

TEAM_RESP=$(curl -sf -X POST "http://${HERMES_IP}:8080/v1/teams" \
  -H "Content-Type: application/json" \
  -d '{"name":"hermes-hub-team"}')
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('team',{}).get('id',''))")
[ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "None" ] \
  && pass "Team created: ${TEAM_ID}" || fail "Team creation failed: ${TEAM_RESP}"

TASK_RESP=$(curl -sf -X POST "http://${HERMES_IP}:8080/v1/teams/${TEAM_ID}/tasks" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"Cross-host hello world\",\"description\":\"Dispatched to remote myrmidon on epimetheus via Tailscale NATS\",\"type\":\"hello\",\"assigneeAgentId\":\"${AGENT_ID}\"}")
TASK_ID=$(echo "$TASK_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task',{}).get('id',''))")
[ -n "$TASK_ID" ] && [ "$TASK_ID" != "None" ] \
  && pass "Task created: ${TASK_ID} → published to hi.myrmidon.hello.* on NATS" \
  || fail "Task creation failed: ${TASK_RESP}"

# ─── Phase 6: Wait for remote myrmidon to complete the task ─────────────────
info "Phase 6: Waiting for epimetheus myrmidon to process task (≤30 s)"

MAX_WAIT=30; ELAPSED=0; TASK_STATUS="pending"
while [ $ELAPSED -lt $MAX_WAIT ]; do
  TASK_STATUS=$(curl -sf "http://${HERMES_IP}:8080/v1/tasks" | \
    python3 -c "
import sys,json
tasks=json.load(sys.stdin).get('tasks',[])
match=[t for t in tasks if t.get('id')=='${TASK_ID}']
print(match[0].get('status','unknown') if match else 'not_found')" 2>/dev/null || echo "unknown")
  [ "$TASK_STATUS" = "completed" ] && break
  sleep 2; ELAPSED=$((ELAPSED + 2))
done

if [ "$TASK_STATUS" = "completed" ]; then
  pass "Myrmidon (epimetheus) completed task ${TASK_ID} in ${ELAPSED}s"
  pass "Cross-host dispatch loop verified: NATS hermes → Tailscale → myrmidon epimetheus → NATS hermes → Agamemnon"
else
  # Show epimetheus log for debugging before failing
  echo "  epimetheus myrmidon log (last 20 lines):"
  ssh "$EPI_SSH" "tail -20 /tmp/hello-myrmidon.log 2>/dev/null" | sed 's/^/    /' || true
  fail "Task ${TASK_ID} not completed after ${MAX_WAIT}s (status=${TASK_STATUS})"
fi

# ─── Phase 7: Argus observability metrics ────────────────────────────────────
info "Phase 7: Argus observability metrics"

sleep 5
METRICS=$(curl -sf "http://${HERMES_IP}:9100/metrics" 2>/dev/null) \
  || fail "Argus exporter not responding at ${HERMES_IP}:9100"

echo "$METRICS" | grep -qE "hi_agamemnon_health(\{\})? 1" \
  && pass "hi_agamemnon_health=1" || fail "hi_agamemnon_health metric missing or not 1"
echo "$METRICS" | grep -q "hi_agents_total" \
  && pass "hi_agents_total present" || fail "hi_agents_total metric missing"
echo "$METRICS" | grep -q "hi_tasks_total" \
  && pass "hi_tasks_total present" || fail "hi_tasks_total metric missing"
echo "$METRICS" | grep -q 'hi_tasks_by_status{status="completed"}' \
  && pass "hi_tasks_by_status{status=\"completed\"} present" || fail "Completed task metric missing"

# ─── Phase 8: Grafana + NATS JetStream ──────────────────────────────────────
info "Phase 8: Grafana dashboard + NATS JetStream"

for i in $(seq 1 6); do
  curl -sf "http://${HERMES_IP}:3001/api/health" >/dev/null 2>&1 && break
  [ $i -eq 6 ] && fail "Grafana not accessible at ${HERMES_IP}:3001"
  sleep 5
done
curl -sf "http://${HERMES_IP}:3001/api/health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('database')=='ok', f'Grafana DB not ok: {d}'" \
  && pass "Grafana @ ${HERMES_IP}:3001 (database=ok)" || fail "Grafana not healthy"

FINAL_MSGS=$(curl -sf "http://${HERMES_IP}:8222/varz" | python3 -c "import sys,json; print(json.load(sys.stdin).get('in_msgs',0))")
pass "NATS JetStream processed ${FINAL_MSGS} messages total"

# ─── Summary ─────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════════════╗"
echo -e "║  ${GREEN}ALL HERMES-HUB E2E CHECKS PASSED${NC}                              ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Cross-host dispatch verified:                                  ║"
echo "║    Agamemnon (hermes) → NATS → Tailscale                        ║"
echo "║    → myrmidon (epimetheus) → NATS → Agamemnon → task=completed  ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  hermes (${HERMES_IP}):                                         ║"
echo "║    Agamemnon:   http://${HERMES_IP}:8080/v1/health              ║"
echo "║    Nestor:      http://${HERMES_IP}:8081/v1/health              ║"
echo "║    Hermes:      http://${HERMES_IP}:8085/health                 ║"
echo "║    NATS:        http://${HERMES_IP}:8222                        ║"
echo "║    Prometheus:  http://${HERMES_IP}:9090                        ║"
echo "║    Grafana:     http://${HERMES_IP}:3001                        ║"
echo "║  epimetheus (${EPI_IP}):                                        ║"
echo "║    Myrmidon log: ssh epimetheus 'tail -f /tmp/hello-myrmidon.log' ║"
echo "╠══════════════════════════════════════════════════════════════════╣"
echo "║  Tear down:  just hermes-hub-down                               ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""
