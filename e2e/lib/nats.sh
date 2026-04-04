#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — NATS Helpers
# All interactions via curl against NATS monitoring HTTP API.

NATS_MONITOR_PORT="${NATS_MONITOR_PORT:-8222}"

# Compute URL lazily so port overrides take effect after source-time
_nats_monitor_url() { echo "http://localhost:${NATS_MONITOR_PORT}"; }

# ─── Health ──────────────────────────────────────────────────────────────────

nats_health() {
    curl -sf "$(_nats_monitor_url)/healthz" >/dev/null 2>&1
}

nats_wait_healthy() {
    local max="${1:-30}"
    wait_for "$(_nats_monitor_url)/healthz" "NATS" "$max"
}

# ─── Server Variables (/varz) ────────────────────────────────────────────────

nats_varz() {
    curl -sf "$(_nats_monitor_url)/varz" 2>/dev/null
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
    curl -sf "$(_nats_monitor_url)/connz" 2>/dev/null
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
    curl -sf "$(_nats_monitor_url)/jsz?streams=true" 2>/dev/null
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
    curl -sf "$(_nats_monitor_url)/subsz?subs=1" 2>/dev/null
}

nats_subscription_count() {
    local subsz
    subsz=$(nats_subsz) || return 1
    echo "$subsz" | python3 -c "import sys,json; print(json.load(sys.stdin).get('num_subscriptions', 0))"
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
