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

echo "=== retry(): args with shell metacharacters are passed literally, not re-evaluated (issue #190) ==="
_CANARY_DIR="$(mktemp -d)"
_CANARY="$_CANARY_DIR/not-created"
# Asserts the command's args are passed literally, not re-evaluated: with "$@",
# echo receives the literal string and the canary is never created. If retry
# expanded its args through the shell, command substitution would create it.
# Capture the status explicitly (retry's own rc is irrelevant; the canary is
# the assertion) so we stay fail-fast without suppressing errors via "|| true".
_inject_rc=0
retry 1 0 echo '$(touch '"$_CANARY"')' >/dev/null 2>&1 || _inject_rc=$?
: "retry exited ${_inject_rc}"
if [ -e "$_CANARY" ]; then
    bad "INJECTION: canary file was created — args were evaluated"
else
    ok "no injection: metacharacter args passed literally"
fi
rm -r "$_CANARY_DIR"

echo "=== is_positive_integer(): accepts only observable positive counts ==="
if ! declare -F is_positive_integer >/dev/null; then
    bad "is_positive_integer helper is missing"
else
    for positive_count in 1 2 42 999999999999999999999999; do
        if is_positive_integer "$positive_count"; then
            ok "accepts positive integer: $positive_count"
        else
            bad "rejected positive integer: $positive_count"
        fi
    done
    for invalid_count in '' 0 -1 1.0 01 1e3 unknown ' 1' '1 '; do
        if is_positive_integer "$invalid_count"; then
            bad "accepted invalid positive integer: <$invalid_count>"
        else
            ok "rejects invalid positive integer: <$invalid_count>"
        fi
    done
fi

echo "=== wait_for(): rejects values before signed shell arithmetic ==="
curl_bounded() {
    printf '200'
}
if wait_for "http://127.0.0.1/health" "bounded fixture" 86400 86400 \
    >/dev/null 2>&1; then
    ok "accepts the maximum wait and poll values"
else
    bad "rejected the maximum wait and poll values"
fi
for overflow_case in \
    '86401 1' \
    '1 86401' \
    '999999999999999999999999 1'; do
    read -r wait_max wait_poll <<<"$overflow_case"
    if wait_for "http://127.0.0.1/health" "overflow fixture" \
        "$wait_max" "$wait_poll" >/dev/null 2>&1; then
        bad "accepted unsafe wait_for bounds: $overflow_case"
    elif [ "$?" -eq 2 ]; then
        ok "rejects unsafe wait_for bounds: $overflow_case"
    else
        bad "returned the wrong status for wait_for bounds: $overflow_case"
    fi
done

echo "=== retry(): rejects unbounded count and delay values ==="
if retry 1000 0 true; then
    ok "accepts the maximum retry count"
else
    bad "rejected the maximum retry count"
fi
for overflow_case in '1001 0' '1 86401' '999999999999999999999999 0'; do
    read -r retry_count retry_delay <<<"$overflow_case"
    if retry "$retry_count" "$retry_delay" true >/dev/null 2>&1; then
        bad "accepted unsafe retry bounds: $overflow_case"
    elif [ "$?" -eq 2 ]; then
        ok "rejects unsafe retry bounds: $overflow_case"
    else
        bad "returned the wrong status for retry bounds: $overflow_case"
    fi
done
if retry 1 0 >/dev/null 2>&1; then
    bad "accepted a retry request with no command"
elif [ "$?" -eq 2 ]; then
    ok "rejects a retry request with no command"
else
    bad "returned the wrong status for a retry request with no command"
fi

echo "=== is_safe_identifier(): accepts URL-safe bounded resource IDs ==="
if ! declare -F is_safe_identifier >/dev/null; then
    bad "is_safe_identifier helper is missing"
else
    for safe_id in a agent-123 task_4 version.2 ns:value; do
        if is_safe_identifier "$safe_id"; then
            ok "accepts safe identifier: $safe_id"
        else
            bad "rejected safe identifier: $safe_id"
        fi
    done
    long_id="$(printf '%0257d' 0 | tr 0 a)"
    newline_id="$(printf 'agent\nother')"
    for unsafe_id in '' '/admin' 'a/b' 'a?x=1' 'a#fragment' 'two words' \
        '.leading-dot' '-leading-dash' "$long_id" "$newline_id"; do
        if is_safe_identifier "$unsafe_id"; then
            bad "accepted unsafe identifier"
        else
            ok "rejects unsafe identifier"
        fi
    done
fi

echo ""
if [ "$T_FAIL" -eq 0 ]; then
    echo "PASSED: $T_PASS / $((T_PASS + T_FAIL))"
    exit 0
else
    echo "FAILED: $T_FAIL / $((T_PASS + T_FAIL))"
    exit 1
fi
