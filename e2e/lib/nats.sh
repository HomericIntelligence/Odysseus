#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — NATS Helpers
# All interactions via curl against NATS monitoring HTTP API.

NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-8222}"
NATS_MONITOR_REQUEST_SECONDS=2
NATS_MONITOR_MAX_BYTES=1048576

# Compute URL lazily so port overrides take effect after source-time
_nats_monitor_url() { echo "http://localhost:${NATS_MONITOR_PORT}"; }

_nats_monitor_json() {
    local endpoint="$1"
    if ! command -v curl_bounded >/dev/null 2>&1; then
        echo "ERROR: bounded curl support is unavailable" >&2
        return 1
    fi
    (
        set -o pipefail
        curl_bounded "$NATS_MONITOR_REQUEST_SECONDS" --silent --show-error \
            --fail --write-out '\n%{http_code}' \
            "$(_nats_monitor_url)$endpoint" 2>/dev/null \
            | python3 -c '
import json
import sys

limit = int(sys.argv[1])
raw = sys.stdin.buffer.read(limit + 5)
if len(raw) > limit + 4 or len(raw) < 4 or raw[-4:] != b"\n200":
    raise SystemExit(1)
body = raw[:-4]
try:
    value = json.loads(body)
except (UnicodeDecodeError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(value, dict):
    raise SystemExit(1)
sys.stdout.buffer.write(body)
' "$NATS_MONITOR_MAX_BYTES"
    )
}

# ─── Health ──────────────────────────────────────────────────────────────────

nats_health() {
    curl -sf --connect-timeout 2 --max-time 2 \
        "$(_nats_monitor_url)/healthz" >/dev/null 2>&1
}

nats_wait_healthy() {
    local max="${1:-30}"
    wait_for "$(_nats_monitor_url)/healthz" "NATS" "$max"
}

# ─── Server Variables (/varz) ────────────────────────────────────────────────

nats_varz() {
    curl -sf --connect-timeout 2 --max-time 2 \
        "$(_nats_monitor_url)/varz" 2>/dev/null
}

nats_msg_count() {
    local varz
    varz=$(nats_varz) || return 1
    echo "$varz" | python3 -c "import sys,json; print(json.load(sys.stdin).get('in_msgs', 0))"
}

nats_connection_count() {
    local varz
    varz=$(nats_varz) || return 1
    echo "$varz" | python3 -c "import sys,json; print(json.load(sys.stdin).get('connections', 0))"
}

# ─── Connections (/connz) ────────────────────────────────────────────────────

nats_connz() {
    _nats_monitor_json "/connz"
}

# Returns list of distinct client IDs (one per line)
nats_client_ids() {
    local connz
    connz=$(nats_connz) || return 1
    echo "$connz" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for c in d.get('connections', []):
    print(c.get('cid', ''))
"
}

# Returns list of distinct client IPs (one per line)
nats_client_ips() {
    local connz
    connz=$(nats_connz) || return 1
    echo "$connz" | python3 -c "
import sys, json
d = json.load(sys.stdin)
ips = set()
for c in d.get('connections', []):
    ip = c.get('ip', '')
    if ip:
        ips.add(ip)
for ip in sorted(ips):
    print(ip)
"
}

# ─── JetStream (/jsz) ───────────────────────────────────────────────────────

nats_jsz() {
    _nats_monitor_json "/jsz?streams=true"
}

# Get message count for a specific JetStream stream
# Usage: nats_stream_msg_count "homeric-tasks"
nats_stream_msg_count() {
    local stream_name="$1"
    local jsz
    jsz=$(nats_jsz) || return 1
    echo "$jsz" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for acct in d.get('account_details', []):
    for s in acct.get('stream_detail', []):
        if s.get('name') == '${stream_name}':
            print(s.get('state', {}).get('messages', 0))
            sys.exit(0)
print(0)
"
}

# Check if a JetStream stream exists (verifies name appears in /jsz output)
nats_stream_exists() {
    local stream_name="$1"
    local jsz
    jsz=$(nats_jsz) || return 1
    echo "$jsz" | python3 -c "
import sys, json
d = json.load(sys.stdin)
for acct in d.get('account_details', []):
    for s in acct.get('stream_detail', []):
        if s.get('name') == '${stream_name}':
            sys.exit(0)
sys.exit(1)
" 2>/dev/null
}

# ─── Subscriptions (/subsz) ─────────────────────────────────────────────────

nats_subsz() {
    _nats_monitor_json "/subsz?subs=1"
}

nats_subscription_count() {
    local subsz
    subsz=$(nats_subsz) || return 1
    echo "$subsz" | python3 -c "import sys,json; print(json.load(sys.stdin).get('num_subscriptions', 0))"
}

# ─── Lifecycle (crash/restart) — T1 only ─────────────────────────────────────
# Only T1 (direct background process) can reliably stop/start NATS in-place.
# T4 is excluded: run-ipc-tests.sh has a documented monitor-port override bug
# (docs/e2e-walkthrough-report.md:601, finding #12).
nats_can_restart() { [ "${IPC_TOPOLOGY:-}" = "t1" ]; }

# Kill the NATS server (T1). Returns 0 once the monitor endpoint stops answering.
nats_kill() {
    local identity_status signal_status signal_owned_process=0
    [ "${IPC_TOPOLOGY:-}" = "t1" ] || return 1
    [ -n "${NATS_BG_PID:-}" ] || return 1
    [ -n "${NATS_BG_IDENTITY:-}" ] || return 1
    [ -n "${NATS_BG_OWNER:-}" ] || return 1
    if ! command -v _process_identity_status >/dev/null 2>&1 \
        || ! command -v _signal_bound_process >/dev/null 2>&1; then
        return 1
    fi
    if _process_identity_status "$NATS_BG_PID" "$NATS_BG_IDENTITY"; then
        signal_owned_process=1
    else
        identity_status=$?
        if [ "$identity_status" -ne 1 ]; then
            echo "ERROR: could not verify the registered NATS process identity" >&2
            return 1
        fi
    fi
    if [ "$signal_owned_process" -eq 1 ]; then
        if _signal_bound_process "$NATS_BG_PID" "$NATS_BG_IDENTITY" \
            "$NATS_BG_OWNER" -KILL; then
            :
        else
            signal_status=$?
            if [ "$signal_status" -eq 1 ]; then
                signal_owned_process=0
            else
                echo "ERROR: could not signal the registered NATS process" >&2
                return 1
            fi
        fi
        if [ "$signal_owned_process" -eq 1 ]; then
            if _process_identity_status "$NATS_BG_PID" \
                "$NATS_BG_IDENTITY" "$NATS_BG_OWNER"; then
                # SIGKILL delivery is asynchronous; monitor extinction below
                # is the externally observable completion proof.
                :
            else
                identity_status=$?
                if [ "$identity_status" -ne 1 ]; then
                    echo "ERROR: could not prove NATS process signal state" >&2
                    return 1
                fi
            fi
        fi
    fi
    for _ in $(seq 1 10); do
        nats_health || return 0      # monitor no longer answering => down
        if ! sleep 1; then
            echo "ERROR: interrupted while waiting for the NATS monitor to stop" >&2
            return 1
        fi
    done
    echo "ERROR: NATS monitor remains reachable after the kill attempt" >&2
    return 1
}

# Restart NATS (T1) reusing the EXACT params start_nats_bg used (no hardcoded
# fallbacks — avoids silent divergence from process.sh). Waits until healthy.
nats_restart() {
    local old_pid="${NATS_BG_PID:-}" old_identity="${NATS_BG_IDENTITY:-}"
    local wait_status identity_status
    [ "${IPC_TOPOLOGY:-}" = "t1" ] || return 1
    if ! command -v _resolve_bound_nats_data_dir >/dev/null 2>&1 \
        || ! command -v _start_nats_guarded >/dev/null 2>&1; then
        echo "ERROR: guarded NATS restart support is unavailable" >&2
        return 1
    fi
    if ! _resolve_bound_nats_data_dir >/dev/null; then
        echo "ERROR: refusing NATS restart with unbound storage" >&2
        return 1
    fi
    # Reap the old PID and wait for the port to be free before relaunching.
    # SIGKILL→immediate relaunch can race a JetStream store lock or TIME_WAIT.
    if [ -n "$old_pid" ] || [ -n "$old_identity" ]; then
        if [ -z "$old_pid" ] || [ -z "$old_identity" ]; then
            echo "ERROR: incomplete prior NATS process receipt" >&2
            return 1
        fi
        if wait "$old_pid" 2>/dev/null; then
            wait_status=0
        else
            wait_status=$?
        fi
        if [ "$wait_status" -eq 127 ]; then
            if _process_identity_status "$old_pid" "$old_identity"; then
                echo "ERROR: prior NATS process is still live and cannot be reaped" >&2
                return 1
            else
                identity_status=$?
                if [ "$identity_status" -ne 1 ]; then
                    echo "ERROR: could not prove prior NATS process extinction" >&2
                    return 1
                fi
            fi
        fi
        command -v unregister_pid >/dev/null 2>&1 || return 1
        if ! unregister_pid "$old_pid" "$old_identity"; then
            echo "ERROR: could not retire the prior NATS process receipt" >&2
            return 1
        fi
    fi
    _start_nats_guarded \
        "${NATS_BIN:?NATS_BIN unset — start_nats_bg must run first}" 30
}

# ─── Assertions ──────────────────────────────────────────────────────────────

assert_nats_connections_gte() {
    local min="$1" actual
    actual=$(nats_connection_count) || return 1
    [ "$actual" -ge "$min" ] 2>/dev/null
}

assert_nats_msgs_gt() {
    local min="$1" actual
    actual=$(nats_msg_count) || return 1
    [ "$actual" -gt "$min" ] 2>/dev/null
}
