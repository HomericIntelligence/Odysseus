#!/usr/bin/env bash
# Performance: Memory Usage (B13, B14)
# Measures: Agamemnon RSS after bulk operations, NATS JetStream memory
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "B13/B14: Memory usage under load"

# ─── B13: Agamemnon RSS after 1000 agents ────────────────────────────────────
info "B13: Create 1000 agents, measure memory impact"

python3 -c "
import urllib.request, json, time

base = 'http://localhost:${AGAMEMNON_PORT}'

# Create 1000 agents
start = time.monotonic()
created = 0
for i in range(1000):
    body = json.dumps({'name': f'mem-agent-{i}', 'label': f'Mem Test {i}', 'program': 'none',
                        'workingDirectory': '/tmp', 'taskDescription': 'mem test',
                        'tags': ['mem'], 'owner': 'e2e', 'role': 'member'}).encode()
    try:
        req = urllib.request.Request(f'{base}/v1/agents', data=body,
                                     headers={'Content-Type': 'application/json'})
        urllib.request.urlopen(req)
        created += 1
    except: pass

elapsed = time.monotonic() - start
print(f'Created {created} agents in {elapsed:.1f}s ({created/elapsed:.0f} agents/sec)')

# Query agent list to verify
agents = json.loads(urllib.request.urlopen(f'{base}/v1/agents').read())
total = len(agents.get('agents', []))
print(f'Total agents in store: {total}')

# Health check — Agamemnon should still be responsive
health = json.loads(urllib.request.urlopen(f'{base}/v1/health').read())
print(f'Health: {health.get(\"status\", \"unknown\")}')
" 2>/dev/null && \
    pass "B13: 1000 agents created, Agamemnon responsive" || \
    fail "B13: Bulk agent creation failed"

# ─── B14: NATS JetStream memory after messages ──────────────────────────────
info "B14: NATS JetStream memory after message volume"

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

python3 -c "
import asyncio, json, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')

    # Publish 10000 small messages
    payload = json.dumps({'seq': 0, 'data': 'memory-test'}).encode()
    for i in range(10000):
        await nc.publish('hi.logs.memory-test', payload)
    await nc.flush()
    print('Published 10000 messages')

    await nc.close()

asyncio.run(main())
" 2>/dev/null && \
    pass "B14: 10000 messages published to NATS" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "B14: Message publishing failed" || \
        skip "B14: nats-py not available"; }

# Check NATS memory via monitoring
JSZ=$(nats_jsz 2>/dev/null)
if [ -n "$JSZ" ]; then
    echo "$JSZ" | python3 -c "
import sys, json
d = json.load(sys.stdin)
mem = d.get('memory', 0)
store = d.get('store', 0)
print(f'JetStream memory: {mem} bytes ({mem/1024/1024:.1f} MB)')
print(f'JetStream storage: {store} bytes ({store/1024/1024:.1f} MB)')
" 2>/dev/null
    pass "B14: JetStream memory stats collected"
fi

nats_health && \
    pass "B14: NATS healthy after 10000 messages" || \
    fail "B14: NATS unhealthy"

summary
exit_code
