#!/usr/bin/env bash
# Security: Connection Flooding (D07)
# Validates: NATS survives 100 rapid connections
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"

info "D07: Connection flooding — 100 rapid NATS connections"

if [ "${IPC_TOPOLOGY:-}" = "t1" ] || [ "${IPC_TOPOLOGY:-}" = "t2" ]; then
    NATS_PORT="${NATS_PORT:-14222}"
else
    NATS_PORT="${NATS_PORT:-4222}"
fi

python3 -c "
import asyncio, nats as natslib

async def main():
    connections = []
    failed = 0

    # Open 100 connections rapidly
    for i in range(100):
        try:
            nc = await natslib.connect('nats://localhost:${NATS_PORT}')
            connections.append(nc)
        except Exception as e:
            failed += 1

    print(f'Opened: {len(connections)} connections')
    print(f'Failed: {failed}')

    # Close all
    for nc in connections:
        try:
            await nc.close()
        except: pass

    print('All connections closed')

asyncio.run(main())
" 2>/dev/null && \
    pass "D07: 100 rapid connections handled" || \
    { python3 -c "import nats" 2>/dev/null && \
        fail "D07: Connection flood test failed" || \
        skip "D07: nats-py not available"; }

# Verify NATS still healthy after flood
sleep 2
nats_health && \
    pass "D07: NATS healthy after connection flood" || \
    fail "D07: NATS unhealthy after flood"

summary
exit_code
