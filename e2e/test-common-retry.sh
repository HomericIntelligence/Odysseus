#!/usr/bin/env bash
# e2e/test-common-retry.sh
# Regression test for retry() in e2e/lib/common.sh (issue #190).
# Verifies positional-arg execution semantics AND shell-injection safety.
#
# Usage: bash e2e/test-common-retry.sh
# Exit 0 = PASS, exit 1 = FAIL
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=e2e/lib/common.sh
source "${REPO_ROOT}/e2e/lib/common.sh"

T_PASS=0
T_FAIL=0
ok()  { echo "  [PASS] $1"; T_PASS=$((T_PASS + 1)); }
bad() { echo "  [FAIL] $1"; T_FAIL=$((T_FAIL + 1)); }

echo "=== retry(): succeeds on first attempt ==="
if retry 3 0 true; then ok "true returns 0"; else bad "true should return 0"; fi

echo "=== retry(): fails after max attempts ==="
if retry 2 0 false; then bad "false should return 1"; else ok "false returns 1 after retries"; fi

echo "=== retry(): succeeds on a later attempt ==="
_STATE_FILE="$(mktemp)"
echo 0 > "$_STATE_FILE"
_attempt_cmd() {
    local n
    n=$(cat "$_STATE_FILE")
    n=$((n + 1))
    echo "$n" > "$_STATE_FILE"
    [ "$n" -ge 3 ]
}
if retry 5 0 _attempt_cmd; then ok "eventual success returns 0"; else bad "should succeed by 3rd attempt"; fi
rm -f "$_STATE_FILE"

echo "=== retry(): arguments with shell metacharacters are NOT evaluated (issue #190) ==="
_CANARY="$(mktemp -u)"
# With "$@", echo receives the literal string and the canary is never created.
# If retry eval'd its args, command substitution would create the canary file.
# Capture the status explicitly (retry's own rc is irrelevant; the canary is
# the assertion) so we stay fail-fast without suppressing errors via "|| true".
_inject_rc=0
retry 1 0 echo '$(touch '"$_CANARY"')' >/dev/null 2>&1 || _inject_rc=$?
: "retry exited ${_inject_rc}"
if [ -e "$_CANARY" ]; then
    bad "INJECTION: canary file was created — args were evaluated"
    rm -f "$_CANARY"
else
    ok "no injection: metacharacter args passed literally"
fi

echo ""
if [ "$T_FAIL" -eq 0 ]; then
    echo "PASSED: $T_PASS / $((T_PASS + T_FAIL))"
    exit 0
else
    echo "FAILED: $T_FAIL / $((T_PASS + T_FAIL))"
    exit 1
fi
