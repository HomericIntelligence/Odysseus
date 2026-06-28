#!/usr/bin/env bash
# Fault Tolerance: NATS Crash and Reconnection (A01, A02)
# Validates: Agamemnon survives NATS crash, clients reconnect after restart
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "A01/A02: NATS crash and reconnection"

# ─── A01: Verify Agamemnon survives NATS unavailability ──────────────────────
info "A01: NATS crash — Agamemnon graceful degradation"

# First, verify baseline works
run_task_lifecycle "hello" 30 && \
    pass "A01: Baseline task lifecycle works" || \
    fail_exit "A01: Baseline task lifecycle failed — cannot test crash recovery"

# Verify Agamemnon health before any disruption
HEALTH=$(agamemnon_health)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "A01: Agamemnon healthy before NATS disruption" || \
    fail "A01: Agamemnon not healthy before test"

# ─── Topology gate: real crash/restart only on T1 ────────────────────────────
# T4 excluded — run-ipc-tests.sh monitor-port override bug (walkthrough finding #12).
nats_can_restart || skip_topology "A01/A02: in-place NATS crash-restart requires T1 (current: ${IPC_TOPOLOGY:-unset})"

# ─── A01: Kill NATS, assert graceful degradation ─────────────────────────────
info "A01: Killing NATS server (PID ${NATS_BG_PID:-unknown})"
nats_kill && \
    pass "A01: NATS killed — monitor endpoint unreachable" || \
    fail_exit "A01: Could not kill NATS — cannot exercise crash path"

# REST plane must stay up while NATS is down (graceful degradation — now ACTUALLY exercised)
HEALTH=$(agamemnon_health 2>/dev/null || echo '{}')
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "A01: Agamemnon REST healthy while NATS down (graceful degradation)" || \
    fail "A01: Agamemnon REST unhealthy during NATS outage"

# ─── A02: Restart NATS, prove reconnection via a NEW end-to-end lifecycle ─────
info "A02: Restarting NATS — verify clients auto-reconnect and pub/sub resumes"
nats_restart && \
    pass "A02: NATS restarted — monitor healthy again" || \
    fail_exit "A02: NATS did not return healthy after restart"

# The ONLY proof of reconnect: a brand-new task completes end-to-end. This needs
# Agamemnon to re-publish (libnats auto-reconnect, nats_client.cpp:28) AND the
# myrmidon durable pull consumer to fetch post-restart (main.cpp:155). 90s covers
# libnats ReconnectWait(2s) + myrmidon Fetch poll(5s) + JetStream rebind.
run_task_lifecycle "hello" 90 && \
    pass "A02: Post-restart task lifecycle COMPLETED (clients reconnected, pub/sub resumed)" || \
    fail "A02: Post-restart task did NOT complete — reconnect path broken"

# Corroborate via monitoring: connections re-established
CONN_COUNT=$(nats_connection_count 2>/dev/null || echo "0")
[ "$CONN_COUNT" -ge 1 ] 2>/dev/null && \
    pass "A02: $CONN_COUNT active NATS connections after restart" || \
    fail "A02: No NATS connections after restart"

summary
exit_code
