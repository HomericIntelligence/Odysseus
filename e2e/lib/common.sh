#!/usr/bin/env bash
# HomericIntelligence E2E Test Library — Common Utilities
# Sourced by all test scripts. Provides color output, assertions, and retry loops.

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'
# shellcheck disable=SC2034  # Public color for scripts that source this library.
YELLOW='\033[1;33m'
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

# Return success only for a canonical decimal integer greater than zero.
# This validates syntax only; arithmetic callers must also impose a bound.
is_positive_integer() {
    [[ "${1:-}" =~ ^[1-9][0-9]*$ ]]
}

# Compare canonical decimal strings without first evaluating them as shell
# arithmetic. This keeps oversized untrusted values out of $((...)).
is_decimal_at_most() {
    local value="${1:-}" limit="${2:-}" LC_ALL=C
    [[ "$value" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    [[ "$limit" =~ ^(0|[1-9][0-9]*)$ ]] || return 1
    if [ "${#value}" -lt "${#limit}" ]; then
        return 0
    fi
    if [ "${#value}" -gt "${#limit}" ]; then
        return 1
    fi
    [[ "$value" == "$limit" || "$value" < "$limit" ]]
}

is_bounded_positive_integer() {
    is_positive_integer "${1:-}" && is_decimal_at_most "$1" "${2:-}"
}

# Return success only for a bounded identifier safe to embed as one URL path
# segment or compare as data. Callers still quote the value at every boundary.
is_safe_identifier() {
    local value="${1:-}"
    [[ "${#value}" -le 256 \
        && "$value" =~ ^[A-Za-z0-9][A-Za-z0-9._:-]*$ ]]
}

# ─── Retry / Wait ────────────────────────────────────────────────────────────

# curl_bounded MAX_SECONDS [CURL_ARGUMENTS...]
#   Run curl with one connect limit and one total limit.
curl_bounded() {
    local total="${1:-}" connect=5
    if ! is_bounded_positive_integer "$total" 86400; then
        echo "curl_bounded requires a positive integer limit of at most 86400s" >&2
        return 2
    fi
    shift
    case "$total" in
        1|2|3|4) connect="$total" ;;
    esac
    curl --connect-timeout "$connect" --max-time "$total" "$@"
}

# curl_http_response MAX_SECONDS [CURL_ARGUMENTS...]
#   Stream the response body and an exact status trailer to a parser.
curl_http_response() {
    local total="${1:-}"
    shift || return 2
    curl_bounded "$total" --silent --write-out '\n%{http_code}' "$@"
}

# http_response_matches KIND
#   Read at most 1 MiB of response body plus the status trailer. Require HTTP
#   200 and the endpoint-specific body contract selected by KIND.
http_response_matches() {
    local kind="$1"
    python3 -c '
import json
import math
import re
import sys

kind = sys.argv[1]
maximum_body = 1024 * 1024
raw = sys.stdin.buffer.read(maximum_body + 5)
if len(raw) > maximum_body + 4:
    raise SystemExit(1)
if len(raw) < 4 or raw[-4:-3] != b"\n" or raw[-3:] != b"200":
    raise SystemExit(1)
body = raw[:-4]


def exact_line(expected):
    encoded = expected.encode("utf-8")
    return body in (encoded, encoded + b"\n", encoded + b"\r\n")


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError("duplicate key")
        result[key] = value
    return result


def json_object():
    try:
        text = body.decode("utf-8")
        value = json.loads(
            text,
            object_pairs_hook=unique_object,
            parse_constant=lambda value: (_ for _ in ()).throw(ValueError(value)),
        )
    except (json.JSONDecodeError, UnicodeError, ValueError):
        raise SystemExit(1)
    if not isinstance(value, dict):
        raise SystemExit(1)
    return value


if kind == "nats":
    raise SystemExit(0 if exact_line("ok") else 1)
if kind == "prometheus":
    raise SystemExit(0 if exact_line("Prometheus Server is Healthy.") else 1)
if kind == "nonempty":
    raise SystemExit(0 if body.strip() else 1)
if kind == "status":
    raise SystemExit(0 if json_object().get("status") == "ok" else 1)
if kind == "hermes":
    value = json_object()
    raise SystemExit(
        0 if value.get("status") == "ok" and value.get("nats_connected") is True else 1
    )
if kind == "grafana":
    raise SystemExit(0 if json_object().get("database") == "ok" else 1)
if kind == "argus":
    sample = re.compile(
        r"^hi_agamemnon_health(?:\{\})?[ \t]+"
        r"([+-]?(?:[0-9]+(?:\.[0-9]*)?|\.[0-9]+)(?:[eE][+-]?[0-9]+)?)"
        r"(?:[ \t]+[+-]?[0-9]+)?[ \t]*$"
    )
    values = []
    try:
        lines = body.decode("utf-8").splitlines()
    except UnicodeError:
        raise SystemExit(1)
    for line in lines:
        match = sample.fullmatch(line)
        if match:
            value = float(match.group(1))
            if math.isfinite(value):
                values.append(value)
    raise SystemExit(0 if values == [1.0] else 1)
if kind in ("varz", "varz-print"):
    value = json_object()
    connections = value.get("connections")
    messages = value.get("in_msgs")
    if (
        type(connections) is not int
        or connections < 0
        or type(messages) is not int
        or messages < 0
    ):
        raise SystemExit(1)
    if kind == "varz-print":
        print(f"  Connections: {connections}, Messages in: {messages}")
    raise SystemExit(0)
raise SystemExit(2)
' "$kind"
}

# wait_for URL NAME MAX_SECONDS [POLL_SECONDS]
#   Poll URL until it returns HTTP 200. The full loop stays in MAX_SECONDS.
#   Returns 0 on success, 1 on timeout, and 2 for an invalid time limit.
wait_for() {
    local url="$1" name="$2" max="${3:-30}" poll="${4:-1}"
    local deadline remaining attempt_budget slot_start slot_elapsed sleep_time
    local http_status
    local attempt=0 max_attempts
    if ! is_bounded_positive_integer "$max" 86400 \
        || ! is_bounded_positive_integer "$poll" 86400; then
        echo "wait_for requires positive integer limits of at most 86400s" >&2
        return 2
    fi
    deadline=$((SECONDS + max))
    max_attempts=$(((max + poll - 1) / poll))
    while [ "$attempt" -lt "$max_attempts" ] && [ "$SECONDS" -lt "$deadline" ]; do
        attempt=$((attempt + 1))
        slot_start=$SECONDS
        remaining=$((deadline - SECONDS))
        attempt_budget="$poll"
        if [ "$attempt_budget" -gt "$remaining" ]; then
            attempt_budget="$remaining"
        fi
        if http_status=$(curl_bounded "$attempt_budget" --silent \
            --output /dev/null --write-out '%{http_code}' "$url") \
            && [ "$http_status" = 200 ]; then
            return 0
        fi
        remaining=$((deadline - SECONDS))
        [ "$remaining" -gt 0 ] || break
        slot_elapsed=$((SECONDS - slot_start))
        sleep_time=$((poll - slot_elapsed))
        [ "$sleep_time" -gt 0 ] || continue
        if [ "$sleep_time" -gt "$remaining" ]; then
            sleep_time="$remaining"
        fi
        sleep "$sleep_time"
    done
    echo -e "  ${RED}TIMEOUT${NC}: $name did not become healthy at $url after ${max}s" >&2
    return 1
}

# retry MAX_ATTEMPTS SLEEP_BETWEEN COMMAND [ARGS...]
#   Retries COMMAND (given as separate arguments) up to MAX_ATTEMPTS times,
#   sleeping SLEEP_BETWEEN seconds between attempts. The command is executed
#   directly via "$@" — it is NOT passed through eval, so arguments are not
#   re-parsed for word-splitting, globbing, or command substitution (issue #190).
retry() {
    local max="${1:-3}" sleep_s="${2:-2}"
    if ! is_bounded_positive_integer "$max" 1000 \
        || ! is_decimal_at_most "$sleep_s" 86400; then
        echo "retry requires at most 1000 attempts and an 86400s delay" >&2
        return 2
    fi
    shift 2 || return 2
    if [ "$#" -eq 0 ]; then
        echo "retry requires a command" >&2
        return 2
    fi
    local i=1
    while [ "$i" -le "$max" ]; do
        "$@" && return 0
        [ "$i" -lt "$max" ] && sleep "$sleep_s"
        i=$((i + 1))
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
