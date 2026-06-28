#!/usr/bin/env bash
# Unit test: nats_kill / nats_restart correctness (issue #328)
# Sources common.sh + process.sh + nats.sh; gated integration loop when nats-server present.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")/lib"
source "$LIB_DIR/common.sh"
source "$LIB_DIR/process.sh"
source "$LIB_DIR/nats.sh"

info "Unit: nats_kill / nats_restart (issue #328)"

# ─── Port-free poll: returns 0 for a closed port ─────────────────────────────

info "T1: wait_port_free — port already free"
UNUSED_PORT=19877
# Confirm nothing is listening on the test port before we begin (use timeout to
# guard against /dev/tcp blocking on a closed port in WSL2/some kernels).
if timeout 1 bash -c "(echo >/dev/tcp/localhost/$UNUSED_PORT) 2>/dev/null" 2>/dev/null; then
    skip "T1: port $UNUSED_PORT is in use — cannot run port-free poll test"
else
    wait_port_free "$UNUSED_PORT" 3 "unused-port" && \
        pass "T1: wait_port_free returns 0 for a closed port" || \
        fail "T1: wait_port_free should return 0 for a closed port"
fi

# ─── Port-free poll: returns non-zero while port is held ─────────────────────

info "T2: wait_port_free — port occupied"
python3 -c "
import socket, time
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(('localhost', 19878))
s.listen(1)
time.sleep(4)
" &
HELD_PORT_PID=$!
sleep 0.3  # let python bind

wait_port_free 19878 2 "held-port" && {
    kill "$HELD_PORT_PID" 2>/dev/null; wait "$HELD_PORT_PID" 2>/dev/null || true
    fail "T2: wait_port_free should return non-zero while port is occupied"
} || {
    kill "$HELD_PORT_PID" 2>/dev/null; wait "$HELD_PORT_PID" 2>/dev/null || true
    pass "T2: wait_port_free returns non-zero while port is occupied"
}

# ─── Integration loop (requires nats-server) ─────────────────────────────────

if ! command -v nats-server >/dev/null 2>&1; then
    info "SKIP: nats-server not in PATH — skipping meta-file + kill-then-wait + restart loop"
    summary
    exit_code
    exit $?
fi

# ─── Meta-file round-trip ────────────────────────────────────────────────────

info "T3: meta-file round-trip after start_nats_bg"
# Use non-default ports to avoid colliding with a real NATS instance
export NATS_PORT=14299
export NATS_MONITOR_PORT=18299

trap 'cleanup_all' EXIT

start_nats_bg

META_PID="$(nats_meta_pid)"
META_DIR="$(nats_meta_store_dir)"

[ -n "$META_PID" ] && \
    pass "T3: meta-file PID is non-empty ($META_PID)" || \
    fail "T3: meta-file PID is empty"

[ -n "$META_DIR" ] && \
    pass "T3: meta-file store_dir is non-empty ($META_DIR)" || \
    fail "T3: meta-file store_dir is empty"

kill -0 "$META_PID" 2>/dev/null && \
    pass "T3: meta-file PID matches a live process" || \
    fail "T3: meta-file PID does not match a live process"

# ─── kill-then-wait: process actually gone before relaunch ───────────────────

info "T4: nats_kill — process fully exits before returning"
nats_kill
kill -0 "$META_PID" 2>/dev/null && \
    fail "T4: nats_kill returned but process $META_PID is still alive" || \
    pass "T4: nats_kill waited for process $META_PID to fully exit"

# ─── Restart loop: 8x kill→restart→healthy, store_dir unchanged ──────────────

info "T5: 8× nats_kill → nats_restart → nats_wait_healthy (mirrors 8/8 manual repro)"
# Restart once first to get the server back up before the loop
nats_restart
INITIAL_DIR="$(nats_meta_store_dir)"

LOOP_FAILURES=0
LOOP_ITER=0
for _t5 in $(seq 1 8); do
    LOOP_ITER=$(( LOOP_ITER + 1 ))
    nats_kill
    if ! nats_restart; then
        fail "T5 iteration $LOOP_ITER: nats_restart failed"
        LOOP_FAILURES=$((LOOP_FAILURES + 1))
        continue
    fi
    if ! nats_health; then
        fail "T5 iteration $LOOP_ITER: NATS unhealthy after restart"
        LOOP_FAILURES=$((LOOP_FAILURES + 1))
        continue
    fi
    CURRENT_DIR="$(nats_meta_store_dir)"
    if [ "$CURRENT_DIR" != "$INITIAL_DIR" ]; then
        fail "T5 iteration $LOOP_ITER: store_dir changed ($INITIAL_DIR → $CURRENT_DIR)"
        LOOP_FAILURES=$((LOOP_FAILURES + 1))
        continue
    fi
    pass "T5 iteration $LOOP_ITER/8: healthy, store_dir preserved"
done

[ "$LOOP_FAILURES" -eq 0 ] && \
    pass "T5: all 8 kill→restart iterations healthy with store_dir preserved" || \
    fail "T5: $LOOP_FAILURES of 8 iterations failed"

summary
exit_code
