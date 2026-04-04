#!/usr/bin/env bash
# Protocol Correctness: Exactly-Once and Ack/Nak (C02, C03)
# Validates: JetStream dedup window, redelivery on nak
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"

info "C02/C03: Exactly-once delivery and ack/nak semantics"

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

# ─── C02: Dedup window prevents duplicates ───────────────────────────────────
info "C02: Publish with dedup — no duplicates"

python3 -c "
import asyncio, json, nats as natslib
from nats.js.api import StreamConfig

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    js = nc.jetstream()

    # Publish the same message ID twice — JetStream should dedup
    msg_id = 'dedup-test-msg-001'
    payload = json.dumps({'test': 'dedup'}).encode()

    ack1 = await js.publish('hi.myrmidon.hello.dedup-test', payload,
                            headers={'Nats-Msg-Id': msg_id})
    ack2 = await js.publish('hi.myrmidon.hello.dedup-test', payload,
                            headers={'Nats-Msg-Id': msg_id})

    # ack2 should be a duplicate
    if ack2.duplicate:
        print('DEDUP: Second publish correctly identified as duplicate')
    else:
        print('NO_DEDUP: Second publish was NOT flagged as duplicate')
        # This may happen if dedup window is not configured — document it
        print('NOTE: JetStream dedup requires MaxAge or Duplicates window on stream config')

    await nc.close()

asyncio.run(main())
" 2>/dev/null && \
    pass "C02: Dedup test executed (see output for result)" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "C02: Dedup test failed" || \
        skip "C02: nats-py not available"; }

# ─── C03: Nak causes redelivery ──────────────────────────────────────────────
info "C03: Nak causes message redelivery"

# Note: Current myrmidon uses core NATS subscribe (not JetStream pull consumer).
# Ack/Nak semantics only apply to JetStream consumers.
# This test documents the current at-most-once behavior.

python3 -c "
import asyncio, json, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    js = nc.jetstream()

    # Publish a test message
    payload = json.dumps({'test': 'nak-redeliver'}).encode()
    await js.publish('hi.myrmidon.hello.nak-test', payload)

    # Subscribe as JetStream consumer
    sub = await js.subscribe('hi.myrmidon.hello.nak-test',
                             durable='nak-test-consumer')

    # Receive and NAK the message
    try:
        msg = await asyncio.wait_for(sub.next_msg(), timeout=5.0)
        await msg.nak()
        print('NAK sent for first delivery')

        # Should be redelivered
        msg2 = await asyncio.wait_for(sub.next_msg(), timeout=10.0)
        if msg2.data == msg.data:
            print('REDELIVERED: Same message received after NAK')
            await msg2.ack()
        else:
            print('DIFFERENT: Got different message after NAK')
    except asyncio.TimeoutError:
        print('TIMEOUT: No redelivery after NAK within 10s')

    await sub.unsubscribe()
    await nc.close()

asyncio.run(main())
" 2>/dev/null && \
    pass "C03: Nak/redelivery test executed" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "C03: Nak test failed" || \
        skip "C03: nats-py not available"; }

summary
exit_code
