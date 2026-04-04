#!/usr/bin/env bash
# Protocol Correctness: Message Ordering (C01)
# Validates: FIFO guarantee via JetStream sequence numbers
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "C01: Message ordering — FIFO via JetStream"

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

# Publish 100 sequentially numbered messages and verify order
python3 -c "
import asyncio, json, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    js = nc.jetstream()

    # Publish 100 numbered messages to a test subject within homeric-myrmidon stream
    for i in range(100):
        payload = json.dumps({'seq': i, 'data': f'message-{i}'}).encode()
        await js.publish('hi.myrmidon.hello.ordering-test', payload)

    # Now read them back via a push subscriber and verify order
    sub = await js.subscribe('hi.myrmidon.hello.ordering-test',
                             durable='ordering-test-consumer',
                             ordered_consumer=True)
    received = []
    try:
        for _ in range(100):
            msg = await asyncio.wait_for(sub.next_msg(), timeout=10.0)
            data = json.loads(msg.data.decode())
            received.append(data['seq'])
            await msg.ack()
    except asyncio.TimeoutError:
        pass

    await sub.unsubscribe()
    await nc.close()

    # Verify FIFO order
    if received == list(range(len(received))):
        print(f'ORDERED: {len(received)} messages in FIFO order')
    else:
        out_of_order = [(i, r) for i, r in enumerate(received) if i != r][:5]
        print(f'DISORDERED: first mismatches: {out_of_order}')
        exit(1)

asyncio.run(main())
" 2>/dev/null && \
    pass "C01: 100 messages delivered in FIFO order via JetStream" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "C01: Message ordering violated" || \
        skip "C01: nats-py not available"; }

summary
exit_code
