#!/usr/bin/env bash
# Security: Resource Exhaustion (D10)
# Validates: 10000 rapid tasks — Agamemnon doesn't OOM
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "D10: Resource exhaustion — 10000 rapid tasks"

AGENT_RESP=$(agamemnon_create_agent "exhaust-agent" "Exhaustion Test")
AGENT_ID=$(echo "$AGENT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('id') or d.get('agent',{}).get('id',''))")
agamemnon_start_agent "$AGENT_ID" >/dev/null
TEAM_RESP=$(agamemnon_create_team "exhaust-team")
TEAM_ID=$(echo "$TEAM_RESP" | python3 -c "import sys,json; print(json.load(sys.stdin).get('team',{}).get('id',''))")

python3 -c "
import urllib.request, json, time

base = 'http://localhost:${AGAMEMNON_PORT}'
team_id = '${TEAM_ID}'
agent_id = '${AGENT_ID}'
created = 0
errors = 0

start = time.monotonic()
for i in range(10000):
    body = json.dumps({'subject': f'exhaust-{i}', 'description': 'exhaust', 'type': 'hello',
                        'assigneeAgentId': agent_id}).encode()
    try:
        req = urllib.request.Request(f'{base}/v1/teams/{team_id}/tasks', data=body,
                                     headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req)
        created += 1
    except Exception as e:
        errors += 1

elapsed = time.monotonic() - start
print(f'Created: {created} tasks in {elapsed:.1f}s ({created/elapsed:.0f} tasks/sec)')
print(f'Errors: {errors}')

# Verify Agamemnon is still responsive
try:
    health = json.loads(urllib.request.urlopen(f'{base}/v1/health').read())
    print(f'Health: {health.get(\"status\", \"unknown\")}')
except:
    print('Health: UNREACHABLE')
    exit(1)
" 2>/dev/null && \
    pass "D10: Agamemnon survived 10000 rapid tasks" || \
    fail "D10: Agamemnon crashed under load"

summary
exit_code
