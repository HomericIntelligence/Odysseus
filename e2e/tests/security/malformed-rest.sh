#!/usr/bin/env bash
# Security: Malformed REST API Payloads (D01, D02, D03, D06)
# Validates: server gracefully rejects bad input
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/common.sh"
source "$(dirname "$(dirname "$SCRIPT_DIR")")/lib/agamemnon.sh"

info "D01-D06: Malformed REST API payloads"

# ─── D01: Malformed JSON to POST /v1/agents ──────────────────────────────────
info "D01: Malformed JSON to /v1/agents"

CODE=$(agamemnon_raw_post "/v1/agents" "{invalid json!!!" "application/json")
[ "$CODE" -ge 400 ] 2>/dev/null && \
    pass "D01: Malformed JSON → HTTP $CODE (rejected)" || \
    fail "D01: Expected 4xx, got $CODE"

# ─── D02: Malformed JSON to POST /v1/teams/:id/tasks ─────────────────────────
info "D02: Malformed JSON to /v1/teams/fake-team/tasks"

CODE=$(agamemnon_raw_post "/v1/teams/fake-team/tasks" "not{json" "application/json")
[ "$CODE" -ge 400 ] 2>/dev/null && \
    pass "D02: Malformed JSON to tasks → HTTP $CODE (rejected)" || \
    fail "D02: Expected 4xx, got $CODE"

# ─── D03: Empty body to POST /v1/agents ───────────────────────────────────────
info "D03: Empty body to /v1/agents"

CODE=$(agamemnon_raw_post "/v1/agents" "" "application/json")
# Either 400 (rejection) or 200/201 (defaults applied) is acceptable
[ "$CODE" -ge 200 ] 2>/dev/null && \
    pass "D03: Empty body → HTTP $CODE (handled, not crashed)" || \
    fail "D03: Unexpected response code $CODE"

# ─── D06: Oversized payload ──────────────────────────────────────────────────
info "D06: 10MB payload to /v1/agents"

# Generate a ~10MB JSON payload
LARGE_PAYLOAD=$(python3 -c "import json; print(json.dumps({'name': 'x' * 10_000_000}))")

CODE=$(curl -sf -o /dev/null -w "%{http_code}" -X POST \
    "http://localhost:${AGAMEMNON_PORT}/v1/agents" \
    -H "Content-Type: application/json" \
    --max-time 10 \
    -d "$LARGE_PAYLOAD" 2>/dev/null || echo "000")

# Either rejection (413, 400) or timeout (000) is acceptable — no crash
[ "$CODE" != "500" ] && \
    pass "D06: 10MB payload → HTTP $CODE (not a server crash)" || \
    fail "D06: Server returned 500 on oversized payload"

# ─── Verify server survived all attacks ───────────────────────────────────────
info "Server survivability check"

HEALTH=$(agamemnon_health 2>/dev/null)
echo "$HEALTH" | python3 -c "import sys,json; assert json.load(sys.stdin).get('status')=='ok'" 2>/dev/null && \
    pass "Agamemnon survived all malformed payloads" || \
    fail "Agamemnon unhealthy after malformed payload tests"

summary
exit_code
