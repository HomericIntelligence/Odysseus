#!/usr/bin/env bash
# Single-container entrypoint: starts NATS, Agamemnon, myrmidon, runs tests
set -euo pipefail

cleanup() {
    kill "$MYRMIDON_PID" "$AGAMEMNON_PID" "$NATS_PID" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== HomericIntelligence IPC E2E — Single Container ==="

# Start NATS
nats-server -js -m 8222 --store_dir /var/lib/nats/jetstream >/dev/null 2>&1 &
NATS_PID=$!
echo "  NATS started (PID $NATS_PID)"

for i in $(seq 1 20); do
    wget -q --spider http://localhost:8222/healthz 2>/dev/null && break
    [ $i -eq 20 ] && { echo "NATS failed to start"; exit 1; }
    sleep 1
done
echo "  NATS healthy"

# Start Agamemnon
NATS_URL=nats://localhost:4222 PORT=8080 ProjectAgamemnon_server >/dev/null 2>&1 &
AGAMEMNON_PID=$!
echo "  Agamemnon started (PID $AGAMEMNON_PID)"

for i in $(seq 1 30); do
    wget -qO- http://localhost:8080/v1/health >/dev/null 2>&1 && break
    [ $i -eq 30 ] && { echo "Agamemnon failed to start"; exit 1; }
    sleep 1
done
echo "  Agamemnon healthy"

# Start hello-myrmidon
NATS_URL=nats://localhost:4222 python3 /app/myrmidon/main.py >/dev/null 2>&1 &
MYRMIDON_PID=$!
echo "  Myrmidon started (PID $MYRMIDON_PID)"
sleep 2

# Run tests
echo ""
/run-test.sh
TEST_EXIT=$?

exit $TEST_EXIT
