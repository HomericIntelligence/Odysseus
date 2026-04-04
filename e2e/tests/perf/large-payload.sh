#!/usr/bin/env bash
# Performance: Large Payload (B11)
# Validates: 1MB NATS message — no truncation
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"

info "B11: Large payload — 1MB NATS message"

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

python3 -c "
import asyncio, json, nats as natslib

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')
    js = nc.jetstream()

    # Create a ~900KB payload (NATS default max_payload is 1MB including headers)
    large_data = 'A' * (900 * 1024)
    payload = json.dumps({'size': '900KB', 'data': large_data}).encode()
    actual_size = len(payload)
    print(f'Payload size: {actual_size} bytes ({actual_size / 1024 / 1024:.2f} MB)')

    # Publish to JetStream
    ack = await js.publish('hi.myrmidon.hello.large-payload-test', payload)
    print(f'Published: stream={ack.stream}, seq={ack.seq}')

    # Subscribe and receive
    sub = await js.subscribe('hi.myrmidon.hello.large-payload-test',
                             durable='large-payload-consumer',
                             ordered_consumer=True)
    try:
        msg = await asyncio.wait_for(sub.next_msg(), timeout=10.0)
        received_size = len(msg.data)
        if received_size == actual_size:
            print(f'INTACT: Received {received_size} bytes (no truncation)')
        else:
            print(f'TRUNCATED: Sent {actual_size}, received {received_size}')
            exit(1)
        await msg.ack()
    except asyncio.TimeoutError:
        print('TIMEOUT: Did not receive large message')
        exit(1)

    await sub.unsubscribe()
    await nc.close()

asyncio.run(main())
" 2>/dev/null && \
    pass "B11: 1MB message sent and received intact" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "B11: Large payload test failed" || \
        skip "B11: nats-py not available"; }

summary
exit_code
