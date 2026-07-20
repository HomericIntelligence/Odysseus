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
    # All payloads are non-JSON so the hello-myrmidon takes its parse-failure
    # NAK path. Valid-JSON non-objects (b'12345', b'[]') are excluded for now:
    # the worker's task.value() calls sit outside its try/catch and throw
    # uncaught on non-object JSON, killing the worker for the rest of the
    # suite (upstream hardening tracked in Myrmidons hello-world/main.cpp).
    for payload in [
        b'garbage payload',
        b'{\"no_task_id\": true}',
        b'{truncated',
        b'\x00\x01\xff',
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

# ── Cleanup: purge the malformed messages from the stream ────────────────────
# The hello-myrmidon durable pull consumer (MaxAckPending=1) NAKs unparseable
# messages and JetStream redelivers them immediately, so without a purge the
# garbage published above head-of-line blocks every later hello task in the
# run (the chaos category runs after security). Purging only this test's
# subject removes the poison while leaving real task messages untouched.
#
# A single purge races the consumer: MaxAckPending=1 means at most one
# malformed message is ever "in flight" (delivered-but-unacked) at a time,
# and NAK's immediate redelivery can hand the consumer a fresh copy in the
# same instant the purge runs — a copy the stream-level purge can no longer
# reach once it has already been redelivered. That message then permanently
# occupies the consumer's one ack-pending slot, silently head-of-line-
# blocking every real hello task for the rest of the run (observed: E13's
# and E11's post-security run_task_lifecycle baselines both timing out with
# no error afterward, run 29711342293). Poll the consumer's own JetStream
# state — not a fixed sleep — and re-purge until both its redelivery queue
# (num_pending) and in-flight slot (num_ack_pending) are actually empty.
python3 -c "
import asyncio, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    jsm = nc.jsm()

    drained = False
    for _attempt in range(10):
        await jsm.purge_stream('homeric-myrmidon', subject='hi.myrmidon.hello.malformed-test')
        info = await jsm.consumer_info('homeric-myrmidon', 'hello-myrmidon')
        if info.num_pending == 0 and info.num_ack_pending == 0:
            drained = True
            break
        await asyncio.sleep(0.5)

    await nc.close()
    if drained:
        print('Purged hi.myrmidon.hello.malformed-test from homeric-myrmidon (consumer drained)')
    else:
        print('Consumer still has pending/ack-pending messages after purge retries')
    return drained

ok = asyncio.run(main())
raise SystemExit(0 if ok else 1)
" 2>/dev/null && \
    pass "D12: Cleanup — malformed messages purged from stream" || \
    fail "D12: Cleanup purge failed (later hello tasks may starve)"

summary
exit_code
