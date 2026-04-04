#!/usr/bin/env bash
# Performance: Message Throughput (B01, B02, B03)
# Measures: msgs/sec at various payload sizes, saturating rate
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"

info "B01/B02/B03: NATS message throughput"

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

python3 -c "
import asyncio, json, time, nats as natslib

async def throughput_test(nc, payload_size, count, label):
    payload = b'x' * payload_size
    subject = 'hi.myrmidon.hello.throughput-test'

    start = time.monotonic()
    for _ in range(count):
        await nc.publish(subject, payload)
    await nc.flush()
    elapsed = time.monotonic() - start

    rate = count / elapsed if elapsed > 0 else 0
    print(f'{label}: {count} msgs in {elapsed:.2f}s = {rate:.0f} msgs/sec ({payload_size} bytes/msg)')
    return rate

async def main():
    nc = await natslib.connect('nats://localhost:${NATS_PORT}')

    # B01: 1KB payloads
    await throughput_test(nc, 1024, 1000, 'B01 (1KB)')

    # B02: 100KB payloads
    await throughput_test(nc, 102400, 100, 'B02 (100KB)')

    # B03: Saturating rate (small payloads, max speed)
    rate = await throughput_test(nc, 64, 10000, 'B03 (64B saturating)')
    print(f'B03 ceiling: {rate:.0f} msgs/sec')

    await nc.close()

asyncio.run(main())
" 2>/dev/null && \
    pass "B01/B02/B03: Throughput measurements complete" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "B01/B02/B03: Throughput test failed" || \
        skip "B01/B02/B03: nats-py not available"; }

summary
exit_code
