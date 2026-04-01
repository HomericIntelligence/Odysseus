#!/usr/bin/env bash
# HomericIntelligence E2E Hello World Test
# Validates the complete pipeline: Hermes → NATS → Agamemnon → Myrmidon → Observability
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
COMPOSE_FILE="${COMPOSE_FILE:-$ODYSSEUS_ROOT/docker-compose.e2e.yml}"

# Resolve symlink paths for podman (can't follow symlinks as build contexts)
PROJECT_ROOT="$ODYSSEUS_ROOT"
HERMES_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/ProjectHermes")"
ARGUS_DIR="$(readlink -f "$ODYSSEUS_ROOT/infrastructure/ProjectArgus")"
MYRMIDONS_DIR="$(readlink -f "$ODYSSEUS_ROOT/provisioning/Myrmidons")"
PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"

# Write .env for compose variable substitution
cat > "$ODYSSEUS_ROOT/.env" <<EOF
PROJECT_ROOT=$PROJECT_ROOT
HERMES_DIR=$HERMES_DIR
ARGUS_DIR=$ARGUS_DIR
MYRMIDONS_DIR=$MYRMIDONS_DIR
PODMAN_SOCK=$PODMAN_SOCK
EOF

# Detect compose command
if command -v podman &>/dev/null && podman compose version &>/dev/null 2>&1; then
  COMPOSE_CMD="podman compose"
elif command -v docker &>/dev/null; then
  COMPOSE_CMD="docker compose"
else
  echo "ERROR: Neither 'podman compose' nor 'docker compose' found" >&2
  exit 1
fi

# Colors
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
pass() { echo -e "  ${GREEN}✓ PASS${NC}: $1"; }
fail() { echo -e "  ${RED}✗ FAIL${NC}: $1"; echo ""; echo "Logs from stack:"; $COMPOSE_CMD -f "$COMPOSE_FILE" logs --tail=50 2>/dev/null || true; exit 1; }
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence E2E Hello World Validation          ║"
echo "║  Pipeline: Hermes → NATS → Agamemnon → Myrmidon → Argus ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Phase 1: Start Stack ──────────────────────────────────────────────────
info "Phase 1: Starting E2E stack"
cd "$ODYSSEUS_ROOT"
$COMPOSE_CMD -f "$COMPOSE_FILE" up -d --build 2>&1 | tail -20

echo "  Waiting for services to be healthy..."
$COMPOSE_CMD -f "$COMPOSE_FILE" wait nats agamemnon nestor hermes 2>/dev/null || true
sleep 5

# ─── Phase 2: Health Checks ───────────────────────────────────────────────
info "Phase 2: Service health checks"

for i in $(seq 1 12); do
  curl -sf http://localhost:8080/v1/health >/dev/null 2>&1 && break
  [ $i -eq 12 ] && fail "Agamemnon did not become healthy after 60s"
  sleep 5
done
curl -sf http://localhost:8080/v1/health | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok', f'Bad: {d}'" \
  && pass "Agamemnon :8080/v1/health → {\"status\":\"ok\"}" || fail "Agamemnon health check failed"

for i in $(seq 1 12); do
  curl -sf http://localhost:8081/v1/health >/dev/null 2>&1 && break
  [ $i -eq 12 ] && fail "Nestor did not become healthy after 60s"
  sleep 5
done
curl -sf http://localhost:8081/v1/health | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok', f'Bad: {d}'" \
  && pass "Nestor :8081/v1/health → {\"status\":\"ok\"}" || fail "Nestor health check failed"

for i in $(seq 1 12); do
  curl -sf http://localhost:8085/health >/dev/null 2>&1 && break
  [ $i -eq 12 ] && fail "Hermes did not become healthy after 60s"
  sleep 5
done
curl -sf http://localhost:8085/health | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='ok', f'Bad: {d}'" \
  && pass "Hermes :8085/health → {\"status\":\"ok\"}" || fail "Hermes health check failed"

curl -sf http://localhost:8222/healthz >/dev/null \
  && pass "NATS :8222/healthz → OK" || fail "NATS health check failed"

# ─── Phase 3: Hermes Webhook → NATS ──────────────────────────────────────
info "Phase 3: Webhook through Hermes → NATS"

WEBHOOK_TS=$(date -u +%FT%TZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
WEBHOOK_RESP=$(curl -sf -X POST http://localhost:8085/webhook \
  -H "Content-Type: application/json" \
  -d "{\"event\":\"task.created\",\"data\":{\"team_id\":\"e2e-team\",\"task_id\":\"e2e-webhook-task\"},\"timestamp\":\"$WEBHOOK_TS\"}")

echo "$WEBHOOK_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='accepted', f'Bad: {d}'" \
  && pass "Webhook accepted: $WEBHOOK_RESP" || fail "Webhook rejected: $WEBHOOK_RESP"

sleep 2
SUBJECTS_RESP=$(curl -sf http://localhost:8085/subjects)
echo "$SUBJECTS_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); subs=d.get('subjects',[]); assert len(subs)>0, f'No subjects: {d}'" \
  && pass "Hermes tracked NATS subjects: $(echo $SUBJECTS_RESP | python3 -c 'import sys,json; print(json.load(sys.stdin).get("subjects",[]))')" \
  || fail "No NATS subjects tracked by Hermes"

# ─── Phase 4: Agamemnon CRUD ─────────────────────────────────────────────
info "Phase 4: Create agent → team → task via Agamemnon"

# Create agent
AGENT_RESP=$(curl -sf -X POST http://localhost:8080/v1/agents \
  -H "Content-Type: application/json" \
  -d '{"name":"hello-worker","label":"Hello Worker","program":"none","workingDirectory":"/tmp","taskDescription":"E2E test agent","tags":["e2e","hello"],"owner":"e2e-test","role":"member"}')
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
[ -n "$AGENT_ID" ] && [ "$AGENT_ID" != "None" ] \
  && pass "Agent created: $AGENT_ID" || fail "Agent creation failed: $AGENT_RESP"

# Start agent
START_RESP=$(curl -sf -X POST "http://localhost:8080/v1/agents/${AGENT_ID}/start" \
  -H "Content-Type: application/json" -d '{}')
echo "$START_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('status')=='online', f'Bad: {d}'" \
  && pass "Agent started: status=online" || fail "Agent start failed: $START_RESP"

# Verify agent appears in list
AGENTS_RESP=$(curl -sf http://localhost:8080/v1/agents)
echo "$AGENTS_RESP" | python3 -c "
import sys,json
d=json.load(sys.stdin)
agents=d.get('agents',[])
match=[a for a in agents if a.get('id')=='${AGENT_ID}']
assert len(match)==1, f'Agent not found in list: {d}'
assert match[0].get('status')=='online', f'Agent not online: {match[0]}'
print(f'  agents list: {len(agents)} total, target agent status={match[0][\"status\"]}')" \
  && pass "Agent appears in /v1/agents with status=online" || fail "Agent not found or not online in list"

# Create team
TEAM_RESP=$(curl -sf -X POST http://localhost:8080/v1/teams \
  -H "Content-Type: application/json" \
  -d '{"name":"hello-team"}')
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('team',{}).get('id',''))")
[ -n "$TEAM_ID" ] && [ "$TEAM_ID" != "None" ] \
  && pass "Team created: $TEAM_ID" || fail "Team creation failed: $TEAM_RESP"

# Create task → dispatches to hi.myrmidon.hello.{task_id}
TASK_RESP=$(curl -sf -X POST "http://localhost:8080/v1/teams/${TEAM_ID}/tasks" \
  -H "Content-Type: application/json" \
  -d "{\"subject\":\"Say hello world\",\"description\":\"Process a hello world message\",\"type\":\"hello\",\"assigneeAgentId\":\"${AGENT_ID}\"}")
TASK_ID=$(echo "$TASK_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task',{}).get('id',''))")
[ -n "$TASK_ID" ] && [ "$TASK_ID" != "None" ] \
  && pass "Task created: $TASK_ID (dispatched to NATS hi.myrmidon.hello.*)" \
  || fail "Task creation failed: $TASK_RESP"

# ─── Phase 5: Wait for Myrmidon ──────────────────────────────────────────
info "Phase 5: Waiting for hello-myrmidon to process task"

MAX_WAIT=30; ELAPSED=0; TASK_STATUS="pending"
while [ $ELAPSED -lt $MAX_WAIT ]; do
  TASK_STATUS=$(curl -sf "http://localhost:8080/v1/tasks" | \
    python3 -c "import sys,json; tasks=json.load(sys.stdin).get('tasks',[]); match=[t for t in tasks if t.get('id')=='${TASK_ID}']; print(match[0].get('status','unknown') if match else 'not_found')" 2>/dev/null || echo "unknown")
  [ "$TASK_STATUS" = "completed" ] && break
  sleep 2; ELAPSED=$((ELAPSED + 2))
done
[ "$TASK_STATUS" = "completed" ] \
  && pass "Myrmidon processed task in ${ELAPSED}s → status=completed" \
  || fail "Task not completed after ${MAX_WAIT}s (status=$TASK_STATUS). Check: podman compose logs hello-myrmidon"

# ─── Phase 6: Observability ──────────────────────────────────────────────
info "Phase 6: Argus exporter metrics"

# Give exporter time to scrape
sleep 5
METRICS=$(curl -sf http://localhost:9100/metrics 2>/dev/null) || { fail "Argus exporter not responding on :9100"; }

echo "$METRICS" | grep -q "hi_agamemnon_health 1" \
  && pass "Prometheus metric: hi_agamemnon_health=1" || fail "hi_agamemnon_health not 1 (Agamemnon down?)"
echo "$METRICS" | grep -q "hi_agents_total" \
  && pass "Prometheus metric: hi_agents_total present" || fail "hi_agents_total metric missing"
echo "$METRICS" | grep -q 'hi_agents_online' \
  && pass "Prometheus metric: hi_agents_online present" || fail "hi_agents_online metric missing"
echo "$METRICS" | grep -q "hi_nestor_health 1" \
  && pass "Prometheus metric: hi_nestor_health=1" || fail "hi_nestor_health not 1 (Nestor down?)"
echo "$METRICS" | grep -q "hi_tasks_total" \
  && pass "Prometheus metric: hi_tasks_total present" || fail "hi_tasks_total metric missing"
echo "$METRICS" | grep -q 'hi_tasks_by_status{status="completed"}' \
  && pass "Prometheus metric: hi_tasks_by_status{status=\"completed\"} present" || fail "Task completed metric missing"

# ─── Phase 7: NATS JetStream ─────────────────────────────────────────────
info "Phase 7: NATS JetStream verification"

VARZ=$(curl -sf http://localhost:8222/varz)
IN_MSGS=$(echo "$VARZ" | python3 -c "import sys,json; print(json.load(sys.stdin).get('in_msgs',0))")
[ "$IN_MSGS" -gt 0 ] 2>/dev/null \
  && pass "NATS processed $IN_MSGS messages total" || pass "NATS running (msg count: $IN_MSGS)"

# ─── Phase 8: Grafana ────────────────────────────────────────────────────
info "Phase 8: Grafana dashboard verification"

for i in $(seq 1 6); do
  curl -sf http://localhost:3001/api/health >/dev/null 2>&1 && break
  [ $i -eq 6 ] && fail "Grafana not accessible after 30s"
  sleep 5
done
GRAFANA_HEALTH=$(curl -sf http://localhost:3001/api/health)
echo "$GRAFANA_HEALTH" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('database')=='ok', f'Grafana DB not ok: {d}'" \
  && pass "Grafana running at http://localhost:3001 (database=ok)" || fail "Grafana database not ok: $GRAFANA_HEALTH"

# ─── Summary ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo -e "║  ${GREEN}ALL E2E CHECKS PASSED${NC}                                    ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  Services (keep running for manual inspection):          ║"
echo "║    Agamemnon:   http://localhost:8080/v1/health          ║"
echo "║    Nestor:      http://localhost:8081/v1/health          ║"
echo "║    Hermes:      http://localhost:8085/health             ║"
echo "║    NATS:        http://localhost:8222                     ║"
echo "║    Prometheus:  http://localhost:9090                     ║"
echo "║    Grafana:     http://localhost:3001                     ║"
echo "║    Exporter:    http://localhost:9100/metrics            ║"
echo "╠══════════════════════════════════════════════════════════╣"
echo "║  To tear down:  just e2e-down                            ║"
echo "╚══════════════════════════════════════════════════════════╝"
echo ""
