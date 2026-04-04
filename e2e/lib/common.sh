#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Common Utilities
# Sourced by all test scripts. Provides color output, assertions, and retry loops.

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
_PASS_COUNT=0
_FAIL_COUNT=0

pass() { _PASS_COUNT=$((_PASS_COUNT + 1)); echo -e "  ${GREEN}PASS${NC}: $1"; }
fail() { _FAIL_COUNT=$((_FAIL_COUNT + 1)); echo -e "  ${RED}FAIL${NC}: $1"; }
# skip_topology: exit the test script cleanly when not on required topology
# This is NOT a failure — the test is structurally inapplicable.
skip_topology() { echo -e "  ${BLUE}N/A${NC}: $1"; summary; exit 0; }

# skip_feature: a specific assertion can't be verified — this IS a failure
skip() { fail "$1"; }
info() { echo -e "\n${BLUE}==${NC} ${CYAN}$1${NC}"; }

# Fatal fail — print message and exit
fail_exit() { fail "$1"; summary; exit 1; }

# Print test summary
summary() {
    echo ""
    echo "╔══════════════════════════════════════════╗"
    local total=$((_PASS_COUNT + _FAIL_COUNT))
    if [ "$_FAIL_COUNT" -eq 0 ]; then
        echo -e "║  ${GREEN}PASSED${NC}: $_PASS_COUNT / $total tests"
    else
        echo -e "║  ${RED}FAILED${NC}: $_FAIL_COUNT / $total tests"
    fi
    echo "╚══════════════════════════════════════════╝"
    echo ""
}

# Return exit code based on failure count
exit_code() { [ "$_FAIL_COUNT" -eq 0 ] && return 0 || return 1; }

# ─── Retry / Wait ────────────────────────────────────────────────────────────

# wait_for URL NAME MAX_SECONDS
#   Polls URL until it returns HTTP 200. Returns 0 on success, 1 on timeout.
wait_for() {
    local url="$1" name="$2" max="${3:-30}"
    for i in $(seq 1 "$max"); do
        curl -sf "$url" >/dev/null 2>&1 && return 0
        sleep 1
    done
    echo -e "  ${RED}TIMEOUT${NC}: $name did not become healthy at $url after ${max}s" >&2
    return 1
}

# retry COMMAND MAX_ATTEMPTS SLEEP_BETWEEN
#   Retries a command up to MAX_ATTEMPTS times.
retry() {
    local cmd="$1" max="${2:-3}" sleep_s="${3:-2}"
    for i in $(seq 1 "$max"); do
        eval "$cmd" && return 0
        [ "$i" -lt "$max" ] && sleep "$sleep_s"
    done
    return 1
}

# ─── JSON Assertions ─────────────────────────────────────────────────────────

# assert_json_field JSON_STRING FIELD EXPECTED_VALUE
#   Uses python3 to extract and compare a JSON field.
assert_json_field() {
    local json="$1" field="$2" expected="$3"
    local actual
    actual=$(echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = '${field}'.split('.')
for k in keys:
    d = d[k] if isinstance(d, dict) else d[int(k)]
print(d)
" 2>/dev/null)
    if [ "$actual" = "$expected" ]; then
        return 0
    else
        echo "  JSON assertion failed: .$field expected '$expected', got '$actual'" >&2
        return 1
    fi
}

# assert_json_field_gte JSON_STRING FIELD MIN_VALUE
assert_json_field_gte() {
    local json="$1" field="$2" min="$3"
    local actual
    actual=$(echo "$json" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = '${field}'.split('.')
for k in keys:
    d = d[k] if isinstance(d, dict) else d[int(k)]
print(d)
" 2>/dev/null)
    if [ "$actual" -ge "$min" ] 2>/dev/null; then
        return 0
    else
        echo "  JSON assertion failed: .$field expected >= $min, got '$actual'" >&2
        return 1
    fi
}

# ─── Compose Detection ───────────────────────────────────────────────────────

detect_compose_cmd() {
    if command -v podman &>/dev/null && podman compose version &>/dev/null 2>&1; then
        echo "podman compose"
    elif command -v docker &>/dev/null; then
        echo "docker compose"
    else
        echo ""
    fi
}

# ─── Topology Detection ──────────────────────────────────────────────────────

# Check if a topology flag restricts this test
# Usage: topology_supports T4 || skip "Requires T4 (multi-container)"
topology_supports() {
    local required="$1"
    [ -z "$IPC_TOPOLOGY" ] && return 0  # No topology set, run everything
    [ "$IPC_TOPOLOGY" = "$required" ] && return 0
    return 1
}
