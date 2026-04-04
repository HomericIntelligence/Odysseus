#!/usr/bin/env bash
# Chaos: Fault Injection API (E01, E02, E03, E04)
# Validates: Agamemnon /v1/chaos/* CRUD lifecycle
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/nats.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "E01-E04: Chaos fault injection API"

# Clean up any lingering faults from previous test runs
EXISTING=$(agamemnon_list_faults 2>/dev/null)
echo "$EXISTING" | python3 -c "
import sys, json
faults = json.load(sys.stdin).get('faults', [])
for f in faults:
    print(f.get('id',''))
" 2>/dev/null | while read -r fid; do
    [ -n "$fid" ] && agamemnon_remove_fault "$fid" >/dev/null 2>&1
done

# ─── E01: Inject network-partition fault ──────────────────────────────────────
info "E01: POST /v1/chaos/network-partition"

FAULT_RESP=$(agamemnon_inject_fault "network-partition")
FAULT_ID=$(echo "$FAULT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)

[ -n "$FAULT_ID" ] && [ "$FAULT_ID" != "None" ] && \
    pass "E01: Fault injected: network-partition (ID: $FAULT_ID)" || \
    fail "E01: Failed to inject network-partition fault"

# Verify it appears in list
FAULTS=$(agamemnon_list_faults)
echo "$FAULTS" | python3 -c "
import sys, json
faults = json.load(sys.stdin).get('faults', [])
match = [f for f in faults if f.get('id') == '${FAULT_ID}']
assert len(match) == 1, f'Fault not found: {faults}'
assert match[0].get('type') == 'network-partition'
assert match[0].get('active') == True
" 2>/dev/null && \
    pass "E01: Fault appears in GET /v1/chaos (active=true, type=network-partition)" || \
    fail "E01: Fault not found in list"

# ─── E02: Inject latency fault ───────────────────────────────────────────────
info "E02: POST /v1/chaos/latency"

LAT_RESP=$(agamemnon_inject_fault "latency")
LAT_ID=$(echo "$LAT_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)

[ -n "$LAT_ID" ] && [ "$LAT_ID" != "None" ] && \
    pass "E02: Fault injected: latency (ID: $LAT_ID)" || \
    fail "E02: Failed to inject latency fault"

# ─── E03: Inject kill fault ──────────────────────────────────────────────────
info "E03: POST /v1/chaos/kill"

KILL_RESP=$(agamemnon_inject_fault "kill")
KILL_ID=$(echo "$KILL_RESP" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('fault',{}).get('id','') or d.get('id',''))" 2>/dev/null)

[ -n "$KILL_ID" ] && [ "$KILL_ID" != "None" ] && \
    pass "E03: Fault injected: kill (ID: $KILL_ID)" || \
    fail "E03: Failed to inject kill fault"

# Verify all 3 faults now in list
FAULTS=$(agamemnon_list_faults)
FAULT_COUNT=$(echo "$FAULTS" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('faults',[])))" 2>/dev/null)
[ "$FAULT_COUNT" -ge 3 ] 2>/dev/null && \
    pass "E03: $FAULT_COUNT faults active (all 3 injected)" || \
    fail "E03: Expected >= 3 faults, got $FAULT_COUNT"

# ─── E04: Remove faults ─────────────────────────────────────────────────────
info "E04: DELETE /v1/chaos/:id"

for fid in "$FAULT_ID" "$LAT_ID" "$KILL_ID"; do
    [ -z "$fid" ] && continue
    agamemnon_remove_fault "$fid" >/dev/null 2>&1
done

# Verify all removed
FAULTS_AFTER=$(agamemnon_list_faults)
AFTER_COUNT=$(echo "$FAULTS_AFTER" | python3 -c "import sys,json; print(len(json.load(sys.stdin).get('faults',[])))" 2>/dev/null)
[ "$AFTER_COUNT" -eq 0 ] 2>/dev/null && \
    pass "E04: All faults removed ($AFTER_COUNT remaining)" || \
    fail "E04: Expected 0 faults after removal, got $AFTER_COUNT"

# Verify server still healthy
HEALTH=$(agamemnon_health 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "E04: Agamemnon healthy after fault injection/removal cycle" || \
    fail "E04: Agamemnon unhealthy after chaos"

summary
exit_code
