#!/usr/bin/env bash
# HomericIntelligence E2E Hello World — Comprehensive Pipeline Validation
# Tests: Hermes → NATS → Agamemnon (all endpoints) → Myrmidon → Nestor → Observability
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"

# ── Counters & helpers ────────────────────────────────────────────────────
PASS=0; FAIL=0; TOTAL=0
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
p() { PASS=$((PASS+1)); TOTAL=$((TOTAL+1)); echo -e "  ${GREEN}✓${NC} $1"; }
f() { FAIL=$((FAIL+1)); TOTAL=$((TOTAL+1)); echo -e "  ${RED}✗${NC} $1"; }
info() { echo -e "\n${BLUE}══${NC} ${YELLOW}$1${NC}"; }

# ── Ports (remapped for podman zombie port avoidance) ─────────────────────
AGAMEMNON=http://localhost:8080
NESTOR=http://localhost:8081
HERMES=http://localhost:8085
NATS_MON=http://localhost:8222
PROMETHEUS=http://localhost:19090
GRAFANA=http://localhost:13001
LOKI=http://localhost:13100
EXPORTER=http://localhost:19100

echo ""
echo "╔═══════════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence E2E — Comprehensive Pipeline Validation ║"
echo "╚═══════════════════════════════════════════════════════════════╝"

# ── Phase 1: Health ───────────────────────────────────────────────────────
info "Phase 1: Service Health"

for svc in "$AGAMEMNON/v1/health" "$NESTOR/v1/health"; do
  for i in $(seq 1 15); do
    curl -sf "$svc" >/dev/null 2>&1 && break
    sleep 4
  done
done

curl -sf "$AGAMEMNON/v1/health" | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='ok'" 2>/dev/null \
  && p "Agamemnon /v1/health" || f "Agamemnon /v1/health"
curl -sf "$NESTOR/v1/health" | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='ok'" 2>/dev/null \
  && p "Nestor /v1/health" || f "Nestor /v1/health"
curl -sf "$HERMES/health" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d['nats_connected']==True" 2>/dev/null \
  && p "Hermes /health (nats_connected=true)" || f "Hermes /health"
curl -sf "$NATS_MON/healthz" >/dev/null 2>&1 && p "NATS /healthz" || f "NATS /healthz"

# ── Phase 2: Webhook → Hermes → NATS ─────────────────────────────────────
info "Phase 2: Webhook → Hermes → NATS"

TS=$(date -u +%FT%TZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
curl -sf -X POST "$HERMES/webhook" -H "Content-Type: application/json" \
  -d "{\"event\":\"agent.created\",\"data\":{\"host\":\"e2e\",\"name\":\"wh-test\"},\"timestamp\":\"$TS\"}" \
  | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='accepted'" 2>/dev/null \
  && p "Webhook accepted" || f "Webhook rejected"

# ── Phase 3: Agent CRUD ──────────────────────────────────────────────────
info "Phase 3: Agent CRUD"

AR=$(curl -sf -X POST "$AGAMEMNON/v1/agents" -H "Content-Type: application/json" \
  -d '{"name":"hello-worker","label":"Hello Worker","program":"none","workingDirectory":"/tmp","host":"e2e-host"}')
AID=$(echo "$AR" | python3 -c "import sys,json; print(json.load(sys.stdin).get('id',''))" 2>/dev/null)
[ -n "$AID" ] && [ "$AID" != "None" ] && p "POST /v1/agents → $AID" || f "POST /v1/agents"

curl -sf "$AGAMEMNON/v1/agents/by-name/hello-worker" \
  | python3 -c "import sys,json; assert json.load(sys.stdin).get('agent',{}).get('name')=='hello-worker'" 2>/dev/null \
  && p "GET /v1/agents/by-name/hello-worker" || f "GET /v1/agents/by-name"

DA=$(curl -sf -X POST "$AGAMEMNON/v1/agents/docker" -H "Content-Type: application/json" \
  -d '{"name":"docker-agent","hostId":"docker-host","image":"achaean-claude:latest"}' 2>/dev/null)
echo "$DA" | python3 -c "import sys,json; assert json.load(sys.stdin).get('id')" 2>/dev/null \
  && p "POST /v1/agents/docker" || f "POST /v1/agents/docker"

curl -sf -X POST "$AGAMEMNON/v1/agents/$AID/start" \
  | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='online'" 2>/dev/null \
  && p "POST /v1/agents/{id}/start → online" || f "Agent start"

curl -sf "$AGAMEMNON/v1/agents" \
  | python3 -c "import sys,json; assert len(json.load(sys.stdin)['agents'])>=2" 2>/dev/null \
  && p "GET /v1/agents (2+ agents)" || f "GET /v1/agents"

# ── Phase 4: Team + Task + Myrmidon ─────────────────────────────────────
info "Phase 4: Team → Task → Myrmidon dispatch"

TR=$(curl -sf -X POST "$AGAMEMNON/v1/teams" -H "Content-Type: application/json" -d '{"name":"hello-team"}')
TID=$(echo "$TR" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('team',{}).get('id','') or d.get('id',''))" 2>/dev/null)
[ -n "$TID" ] && [ "$TID" != "None" ] && p "POST /v1/teams" || f "POST /v1/teams"

TASKR=$(curl -sf -X POST "$AGAMEMNON/v1/teams/$TID/tasks" -H "Content-Type: application/json" \
  -d "{\"subject\":\"Say hello world\",\"description\":\"E2E test\",\"type\":\"hello\",\"assigneeAgentId\":\"$AID\"}")
TASKID=$(echo "$TASKR" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('task',{}).get('id','') or d.get('id',''))" 2>/dev/null)
[ -n "$TASKID" ] && [ "$TASKID" != "None" ] && p "POST /v1/teams/{id}/tasks → dispatched" || f "Task create"

curl -sf -X PUT "$AGAMEMNON/v1/teams/$TID/tasks/$TASKID" -H "Content-Type: application/json" \
  -d '{"status":"running"}' \
  | python3 -c "import sys,json; assert json.load(sys.stdin).get('task',{}).get('status')=='running'" 2>/dev/null \
  && p "PUT /v1/teams/{id}/tasks/{id} → running" || f "PUT task"

curl -sf "$AGAMEMNON/v1/workflows" \
  | python3 -c "import sys,json; assert 'workflows' in json.load(sys.stdin)" 2>/dev/null \
  && p "GET /v1/workflows" || f "GET /v1/workflows"

# ── Phase 5: Myrmidon completion ─────────────────────────────────────────
info "Phase 5: Myrmidon processing"

ST="running"
for i in $(seq 1 15); do
  ST=$(curl -sf "$AGAMEMNON/v1/tasks" | python3 -c "
import sys,json; ts=json.load(sys.stdin).get('tasks',[])
m=[t for t in ts if t.get('id')=='$TASKID']
print(m[0]['status'] if m else 'missing')" 2>/dev/null || echo "err")
  [ "$ST" = "completed" ] && break
  sleep 2
done
[ "$ST" = "completed" ] && p "Task completed by myrmidon" || f "Task status: $ST"

# ── Phase 6: Nestor research ────────────────────────────────────────────
info "Phase 6: Nestor research flow"

curl -sf -X POST "$NESTOR/v1/research" -H "Content-Type: application/json" \
  -d '{"idea":"hello world","context":"E2E"}' \
  | python3 -c "import sys,json; assert json.load(sys.stdin).get('id')" 2>/dev/null \
  && p "POST /v1/research → accepted" || f "POST /v1/research"

curl -sf "$NESTOR/v1/research/stats" \
  | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'pending' in d" 2>/dev/null \
  && p "GET /v1/research/stats" || f "GET /v1/research/stats"

# ── Phase 7: Observability ──────────────────────────────────────────────
info "Phase 7: Prometheus metrics"

sleep 5
M=$(curl -sf "$EXPORTER/metrics" 2>/dev/null || echo "")
if [ -n "$M" ]; then
  echo "$M" | grep -q "hi_agamemnon_health.*1" && p "hi_agamemnon_health=1" || f "hi_agamemnon_health"
  echo "$M" | grep -q "hi_nestor_health.*1" && p "hi_nestor_health=1" || f "hi_nestor_health"
  echo "$M" | grep -q "hi_agents_total" && p "hi_agents_total" || f "hi_agents_total"
  echo "$M" | grep -q "hi_tasks_total" && p "hi_tasks_total" || f "hi_tasks_total"
  echo "$M" | grep -q "hi_tasks_by_status" && p "hi_tasks_by_status" || f "hi_tasks_by_status"
else
  f "Exporter not responding at $EXPORTER"
fi

# ── Phase 8: NATS JetStream ────────────────────────────────────────────
info "Phase 8: NATS JetStream"

V=$(curl -sf "$NATS_MON/varz" 2>/dev/null)
C=$(echo "$V" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connections',0))" 2>/dev/null || echo "0")
I=$(echo "$V" | python3 -c "import sys,json; print(json.load(sys.stdin).get('in_msgs',0))" 2>/dev/null || echo "0")
[ "$C" -gt 0 ] 2>/dev/null && p "NATS: $C connections, $I messages" || f "No NATS connections"

# ── Phase 9: Grafana + Loki ─────────────────────────────────────────────
info "Phase 9: Grafana + Loki"

curl -sf "$GRAFANA/api/health" | python3 -c "import sys,json; assert json.load(sys.stdin)['database']=='ok'" 2>/dev/null \
  && p "Grafana at $GRAFANA" || f "Grafana"
curl -sf "$LOKI/loki/api/v1/labels" | python3 -c "import sys,json; assert json.load(sys.stdin)['status']=='success'" 2>/dev/null \
  && p "Loki API at $LOKI" || f "Loki"

# ── Phase 10: Chaos endpoints ───────────────────────────────────────────
info "Phase 10: Chaos injection (ProjectCharybdis)"

CF=$(curl -sf -X POST "$AGAMEMNON/v1/chaos/latency" -H "Content-Type: application/json" \
  -d '{"target":"test","delay_ms":100}' 2>/dev/null)
echo "$CF" | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('fault',{}).get('id') or d.get('id')" 2>/dev/null \
  && p "POST /v1/chaos/latency → fault injected" || f "Chaos inject"

curl -sf "$AGAMEMNON/v1/chaos" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'faults' in d" 2>/dev/null \
  && p "GET /v1/chaos → faults listed" || f "Chaos list"

FAULT_ID=$(echo "$CF" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)
if [ -n "$FAULT_ID" ] && [ "$FAULT_ID" != "None" ]; then
  curl -sf -X DELETE "$AGAMEMNON/v1/chaos/$FAULT_ID" \
    | python3 -c "import sys,json; d=json.load(sys.stdin); assert d.get('deleted')" 2>/dev/null \
    && p "DELETE /v1/chaos/{id} → removed" || f "Chaos remove"
fi

# ── Summary ──────────────────────────────────────────────────────────────
echo ""
echo "═══════════════════════════════════════════════════════════════"
if [ $FAIL -eq 0 ]; then
  echo -e "  ${GREEN}ALL $TOTAL CHECKS PASSED${NC}"
else
  echo -e "  ${GREEN}$PASS passed${NC}, ${RED}$FAIL failed${NC} out of $TOTAL checks"
fi
echo "═══════════════════════════════════════════════════════════════"
echo ""
echo "Services:"
echo "  Agamemnon:  $AGAMEMNON/v1/health"
echo "  Nestor:     $NESTOR/v1/health"
echo "  Hermes:     $HERMES/health"
echo "  NATS:       $NATS_MON"
echo "  Prometheus: $PROMETHEUS"
echo "  Grafana:    $GRAFANA"
echo "  Loki:       $LOKI"
echo "  Exporter:   $EXPORTER/metrics"
echo ""
echo "Tear down: just e2e-down"
echo ""

exit $FAIL
