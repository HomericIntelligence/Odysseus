#!/usr/bin/env bash
# Security: Malformed NATS Messages (D11, D12)
# Validates: services ignore garbage NATS messages gracefully
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "D11/D12: Malformed NATS messages"

# These tests publish garbage to NATS subjects that Agamemnon and myrmidon subscribe to.
# We use python3 + nats-py to publish directly to NATS.

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

# ─── D11: Non-JSON on hi.tasks.*.*.completed ─────────────────────────────────
info "D11: Non-JSON on completion subject"

python3 -c "
import asyncio, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    # Publish garbage to the completion subject Agamemnon subscribes to
    for payload in [
        b'not json at all',
        b'{truncated',
        b'',
        b'\x00\x01\x02\xff',
        b'null',
    ]:
        await nc.publish('hi.tasks.fake-team.fake-task.completed', payload)
    await nc.flush()
    await nc.close()
    print('Published 5 malformed messages to hi.tasks.*.*.completed')

asyncio.run(main())
" 2>/dev/null && \
    pass "D11: Published 5 malformed messages to completion subject" || \
    skip "D11: Could not publish (nats-py not available or NATS not reachable)"

# Wait and verify Agamemnon didn't crash
sleep 3
HEALTH=$(agamemnon_health 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "D11: Agamemnon survived malformed NATS messages" || \
    fail "D11: Agamemnon unhealthy after malformed NATS messages"

# ─── D12: Non-JSON on hi.myrmidon.hello.> ───────────────────────────────────
info "D12: Non-JSON on myrmidon subject"

python3 -c "
import asyncio, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    for payload in [
        b'garbage payload',
        b'{\"no_task_id\": true}',
        b'12345',
        b'[]',
    ]:
        await nc.publish('hi.myrmidon.hello.malformed-test', payload)
    await nc.flush()
    await nc.close()
    print('Published 4 malformed messages to hi.myrmidon.hello.*')

asyncio.run(main())
" 2>/dev/null && \
    pass "D12: Published 4 malformed messages to myrmidon subject" || \
    skip "D12: Could not publish (nats-py not available or NATS not reachable)"

# Wait and verify the system is still healthy
sleep 3
nats_health && \
    pass "D12: NATS still healthy after malformed messages" || \
    fail "D12: NATS unhealthy"

HEALTH=$(agamemnon_health 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "D12: Full system healthy after malformed NATS messages" || \
    fail "D12: System unhealthy after malformed NATS messages"

summary
exit_code
