#!/usr/bin/env bash
# Performance: Latency Measurement (B04, B05)
# Measures: task round-trip P50/P95/P99, Hermes webhook latency
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/hermes.sh"

info "B04/B05: Latency measurement"

# Setup
AGENT_RESP=$(agamemnon_create_agent "latency-agent" "Latency Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null
TEAM_RESP=$(agamemnon_create_team "latency-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

# ─── B04: Task round-trip latency ────────────────────────────────────────────
info "B04: Task create → complete round-trip latency (20 samples)"

python3 -c "
import urllib.request, json, time

base = 'http://localhost:${AGAMEMNON_PORT}'
team_id = '${TEAM_ID}'
agent_id = '${AGENT_ID}'
latencies = []

for i in range(20):
    start = time.monotonic()

    # Create task
    body = json.dumps({'subject': f'latency-{i}', 'description': 'perf', 'type': 'hello', 'assigneeAgentId': agent_id}).encode()
    req = urllib.request.Request(f'{base}/v1/teams/{team_id}/tasks', data=body,
                                 headers={'Content-Type': 'application/json'})
    resp = json.loads(urllib.request.urlopen(req).read())
    task_id = resp.get('task', {}).get('id', '')

    # Poll for completion
    for _ in range(60):
        tasks = json.loads(urllib.request.urlopen(f'{base}/v1/tasks').read())
        match = [t for t in tasks.get('tasks', []) if t.get('id') == task_id]
        if match and match[0].get('status') == 'completed':
            break
        time.sleep(0.5)

    elapsed = (time.monotonic() - start) * 1000
    latencies.append(elapsed)

latencies.sort()
n = len(latencies)
p50 = latencies[n // 2]
p95 = latencies[int(n * 0.95)]
p99 = latencies[int(n * 0.99)]
avg = sum(latencies) / n

print(f'Samples: {n}')
print(f'P50: {p50:.0f}ms')
print(f'P95: {p95:.0f}ms')
print(f'P99: {p99:.0f}ms')
print(f'Avg: {avg:.0f}ms')
print(f'Min: {min(latencies):.0f}ms')
print(f'Max: {max(latencies):.0f}ms')
" 2>/dev/null && \
    pass "B04: Latency measurement complete (see output above)" || \
    fail "B04: Latency measurement failed"

# ─── B05: Hermes webhook latency ─────────────────────────────────────────────
info "B05: Hermes webhook → NATS publish latency"

hermes_health >/dev/null 2>&1 || {
    skip "B05: Hermes not running"
    summary; exit_code; exit $?
}

python3 -c "
import urllib.request, json, time

base = 'http://localhost:${HERMES_PORT}'
latencies = []

for i in range(10):
    ts = time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())
    body = json.dumps({'event': 'task.created', 'data': {'team_id': 'b05', 'task_id': f'b05-{i}'}, 'timestamp': ts}).encode()

    start = time.monotonic()
    req = urllib.request.Request(f'{base}/webhook', data=body,
                                 headers={'Content-Type': 'application/json'})
    resp = json.loads(urllib.request.urlopen(req).read())
    elapsed = (time.monotonic() - start) * 1000
    latencies.append(elapsed)

latencies.sort()
n = len(latencies)
print(f'Webhook samples: {n}')
print(f'P50: {latencies[n//2]:.0f}ms')
print(f'P95: {latencies[int(n*0.95)]:.0f}ms')
print(f'Avg: {sum(latencies)/n:.0f}ms')
" 2>/dev/null && \
    pass "B05: Hermes webhook latency measured" || \
    fail "B05: Hermes latency measurement failed"

summary
exit_code
