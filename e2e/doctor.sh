#!/usr/bin/env bash
# HomericIntelligence Doctor — E2E Pipeline Prerequisite Checker
#
# Verifies dependencies for the selected local role. Cross-host topology,
# peer, and service checks run only after the explicit --cross-host selection.
# Checks follow the component hierarchy from docs/architecture.md.
#
# Usage:
#   just doctor                    # Check-only mode
#   just doctor --install          # Check + install missing dependencies
#   just doctor --role worker      # Only check worker-host dependencies
#   just doctor --role control     # Only check control-host dependencies
#   just doctor --cross-host --worker-ip IP
#   just doctor --cross-host --capability-only
#
# Exit codes:
#   0 — all checks passed
#   1 — one or more checks failed
set -uo pipefail

# ─── Colors ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

# ─── Counters ────────────────────────────────────────────────────────────────
_PASS=0; _FAIL=0; _WARN=0; _SKIP=0

check_pass()  { _PASS=$((_PASS + 1));  echo -e "  ${GREEN}✓${NC} $1"; }
check_fail()  { _FAIL=$((_FAIL + 1));  echo -e "  ${RED}✗${NC} $1"; }
check_warn()  { _WARN=$((_WARN + 1));  echo -e "  ${YELLOW}⚠${NC} $1"; }
check_skip()  { _SKIP=$((_SKIP + 1));  echo -e "  ${DIM}–${NC} $1 ${DIM}(skipped)${NC}"; }
section()     { echo -e "\n${BOLD}${CYAN}$1${NC}"; }

# Parse peer targets with the standard-library IP parser. The parser rejects
# hostnames, ports, zone identifiers, brackets, and address-shaped text that is
# not a complete IPv4 or IPv6 literal. Its compressed output is the one value
# passed to topology and service commands.
canonicalize_ip_literal() {
    if ! run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import ipaddress
import sys

candidate = sys.argv[1]
if "%" in candidate:
    raise SystemExit(1)
try:
    address = ipaddress.ip_address(candidate)
except ValueError:
    raise SystemExit(1)
print(address.compressed)
' "$1"; then
        return 1
    fi
    printf '%s\n' "$BOUNDED_OUTPUT"
}

http_host_for_ip() {
    case "$1" in
        *:*) printf '[%s]\n' "$1" ;;
        *) printf '%s\n' "$1" ;;
    esac
}

valid_tailscale_status() {
    run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import ipaddress
import json
import sys

try:
    value = json.load(sys.stdin)
except (json.JSONDecodeError, UnicodeError):
    raise SystemExit(1)
if not isinstance(value, dict):
    raise SystemExit(1)
self_node = value.get("Self")
peers = value.get("Peer")
if not isinstance(self_node, dict) or not isinstance(peers, dict):
    raise SystemExit(1)
nodes = [self_node, *peers.values()]
for node in nodes:
    if not isinstance(node, dict) or type(node.get("Online")) is not bool:
        raise SystemExit(1)
    addresses = node.get("TailscaleIPs")
    if not isinstance(addresses, list) or any(not isinstance(item, str) for item in addresses):
        raise SystemExit(1)
    try:
        if any(ipaddress.ip_address(item).compressed != item for item in addresses):
            raise SystemExit(1)
    except ValueError:
        raise SystemExit(1)
' >/dev/null
}

is_online_tailscale_peer() {
    local target=$1
    run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import ipaddress
import json
import sys

target = ipaddress.ip_address(sys.argv[1])
value = json.load(sys.stdin)
self_addresses = {
    ipaddress.ip_address(item) for item in value["Self"]["TailscaleIPs"]
}
if target in self_addresses:
    raise SystemExit(1)
matches = 0
for peer in value["Peer"].values():
    addresses = {ipaddress.ip_address(item) for item in peer["TailscaleIPs"]}
    if target in addresses and peer["Online"] is True:
        matches += 1
raise SystemExit(0 if matches == 1 else 1)
' "$target" >/dev/null
}

service_health_matches() (
    local kind=$1
    unset BASH_ENV ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT \
        PYTHONWARNINGS PYTHONSAFEPATH PYTHONUSERBASE
    python3() { "$PYTHON3_BIN" -I -S "$@"; }
    http_response_matches "$kind"
)

check_service_health() {
    local label=$1 url=$2 kind=$3
    if curl_http_response 15 --noproxy '*' "$url" \
        | service_health_matches "$kind"; then
        check_pass "$label"
    else
        check_fail "$label — response identity or health schema did not match"
    fi
}

# ─── Argument Parsing ────────────────────────────────────────────────────────
INSTALL=false
ROLE="all"              # all | worker | control
CHECK_SERVICES=false
CROSS_HOST=false
CONFIGURE_FIREWALL=false
CAPABILITY_ONLY=false
WORKER_IP=""
CONTROL_IP=""
PYTHON3_READY=false
PYTHON3_BIN=""
TAILSCALE_STATUS_JSON=""
TAILSCALE_STATUS_AVAILABLE=false
WORKER_PEER_VERIFIED=false
CONTROL_PEER_VERIFIED=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)         INSTALL=true; shift ;;
        --role)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --role requires all, worker, or control" >&2
                exit 1
            fi
            ROLE="$2"
            shift 2
            ;;
        --cross-host)      CROSS_HOST=true; shift ;;
        --capability-only) CAPABILITY_ONLY=true; shift ;;
        --configure-firewall) CONFIGURE_FIREWALL=true; shift ;;
        --check-services)  CHECK_SERVICES=true; shift ;;
        --worker-ip)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --worker-ip requires an address" >&2
                exit 1
            fi
            WORKER_IP="$2"
            shift 2
            ;;
        --control-ip)
            if [[ $# -lt 2 ]]; then
                echo "ERROR: --control-ip requires an address" >&2
                exit 1
            fi
            CONTROL_IP="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: just doctor [--install] [--role worker|control] [--cross-host (--worker-ip IP | --control-ip IP | --capability-only) [--check-services]]"
            exit 0
            ;;
        *) echo "Unknown argument: $1"; exit 1 ;;
    esac
done

case "$ROLE" in
    all|worker|control) ;;
    *)
        echo "ERROR: role must be one of: all, worker, control" >&2
        exit 1
        ;;
esac
if $CHECK_SERVICES && [[ -z "$WORKER_IP" && -z "$CONTROL_IP" ]]; then
    echo "ERROR: --check-services requires --worker-ip or --control-ip" >&2
    exit 1
fi
if $CONFIGURE_FIREWALL; then
    echo "ERROR: broad trusted-interface firewall mutation is unavailable in doctor; use an exact deployment-owned listener/peer policy after operator approval" >&2
    exit 1
fi
if ! $CROSS_HOST; then
    if [[ -n "$WORKER_IP" ]]; then
        echo "ERROR: --worker-ip requires --cross-host" >&2
        exit 1
    fi
    if [[ -n "$CONTROL_IP" ]]; then
        echo "ERROR: --control-ip requires --cross-host" >&2
        exit 1
    fi
    if $CHECK_SERVICES; then
        echo "ERROR: --check-services requires --cross-host" >&2
        exit 1
    fi
    if $CAPABILITY_ONLY; then
        echo "ERROR: --capability-only requires --cross-host" >&2
        exit 1
    fi
fi
if $CROSS_HOST && [[ -z "$WORKER_IP" && -z "$CONTROL_IP" ]] \
        && ! $CAPABILITY_ONLY; then
    echo "ERROR: --cross-host requires an exact peer target (--worker-ip or --control-ip) or explicit --capability-only mode" >&2
    exit 1
fi
if $CAPABILITY_ONLY && [[ -n "$WORKER_IP" || -n "$CONTROL_IP" || "$CHECK_SERVICES" == true ]]; then
    echo "ERROR: --capability-only cannot be combined with peer or service targets" >&2
    exit 1
fi
# ─── Helpers ─────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$SCRIPT_DIR/lib/common.sh"

# Check if a command exists
has_cmd() { command -v "$1" &>/dev/null; }

resolve_python3() {
    local candidate
    candidate=$(type -P python3 2>/dev/null) || return 1
    [[ "$candidate" == /* && -f "$candidate" && -x "$candidate" ]] || return 1
    PYTHON3_BIN=$candidate
}

VERSION_TIMEOUT_SECONDS=3
VERSION_MAX_BYTES=65536
PYTHON_CHECK_TIMEOUT_SECONDS=3
PYTHON_CHECK_MAX_BYTES=1048576
TAILSCALE_TIMEOUT_SECONDS=3
TAILSCALE_MAX_BYTES=131072
BOUNDED_OUTPUT=""

# Run one argv vector behind a wall-clock and byte boundary. The helper creates
# a new process group, drains only the allowed output, and terminates the whole
# group on timeout, overflow, or interruption so descendants cannot outlive a
# failed probe. The interpreter used for the boundary is an already-resolved
# absolute path and is itself isolated from ambient Python startup state.
run_bounded_command() {
    local timeout_seconds=$1 maximum_bytes=$2 status
    shift 2
    BOUNDED_OUTPUT=""
    [[ -n "$PYTHON3_BIN" && "$timeout_seconds" =~ ^[1-9][0-9]*$ \
        && "$maximum_bytes" =~ ^[1-9][0-9]*$ && "$#" -gt 0 ]] || return 2

    BOUNDED_OUTPUT=$(
        unset BASH_ENV ENV PYTHONHOME PYTHONPATH PYTHONSTARTUP PYTHONINSPECT \
            PYTHONWARNINGS PYTHONSAFEPATH PYTHONUSERBASE
        "$PYTHON3_BIN" -I -S -c '
import os
import selectors
import signal
import subprocess
import sys
import time

timeout = int(sys.argv[1])
maximum = int(sys.argv[2])
argv = sys.argv[3:]
environment = os.environ.copy()
for name in (
    "BASH_ENV", "ENV", "PYTHONHOME", "PYTHONPATH", "PYTHONSTARTUP",
    "PYTHONINSPECT", "PYTHONWARNINGS", "PYTHONSAFEPATH", "PYTHONUSERBASE",
):
    environment.pop(name, None)

process = subprocess.Popen(
    argv,
    stdin=None,
    stdout=subprocess.PIPE,
    stderr=subprocess.STDOUT,
    start_new_session=True,
    close_fds=True,
    env=environment,
)
assert process.stdout is not None
selector = selectors.DefaultSelector()
selector.register(process.stdout, selectors.EVENT_READ)
deadline = time.monotonic() + timeout
output = bytearray()
failure = None
pipe_closed = False
interrupted = None


def catch_signal(signum, _frame):
    global interrupted
    interrupted = signum


for caught in (signal.SIGHUP, signal.SIGINT, signal.SIGTERM):
    signal.signal(caught, catch_signal)


def group_exists():
    try:
        os.killpg(process.pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def signal_group(signum):
    try:
        os.killpg(process.pid, signum)
    except ProcessLookupError:
        pass


while True:
    now = time.monotonic()
    if interrupted is not None:
        failure = "interrupted"
        break
    if now >= deadline:
        failure = "timeout"
        break
    for key, _mask in selector.select(min(0.05, deadline - now)):
        chunk = os.read(key.fd, min(65536, maximum - len(output) + 1))
        if chunk:
            output.extend(chunk)
            if len(output) > maximum:
                failure = "overflow"
                break
        else:
            pipe_closed = True
            selector.unregister(process.stdout)
    if failure is not None:
        break
    returncode = process.poll()
    if returncode is not None and pipe_closed:
        if group_exists():
            failure = "descendant"
        break

if failure is not None:
    signal_group(signal.SIGTERM)
    grace_deadline = time.monotonic() + 0.2
    while group_exists() and time.monotonic() < grace_deadline:
        time.sleep(0.01)
    if group_exists():
        signal_group(signal.SIGKILL)
    try:
        process.wait(timeout=0.5)
    except subprocess.TimeoutExpired:
        signal_group(signal.SIGKILL)
        process.wait(timeout=0.5)
    if interrupted is not None:
        signal.signal(interrupted, signal.SIG_DFL)
        os.kill(os.getpid(), interrupted)
    raise SystemExit(125 if failure == "overflow" else 124)

if output:
    os.write(sys.stdout.fileno(), output)
raise SystemExit(process.returncode)
' "$timeout_seconds" "$maximum_bytes" "$@"
    )
    status=$?
    return "$status"
}

# Run a version command and return a parseable version only when the command
# itself succeeds. Presence alone is not evidence that a tool is usable.
get_version() {
    local output first_line version
    if ! run_bounded_command "$VERSION_TIMEOUT_SECONDS" \
        "$VERSION_MAX_BYTES" "$@"; then
        return 1
    fi
    output=$BOUNDED_OUTPUT
    first_line=${output%%$'\n'*}
    if ! version=$(printf '%s\n' "$first_line" \
        | grep -Eo '[0-9]+(\.[0-9]+)+' | head -1); then
        return 1
    fi
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

check_tool_version() {
    local label="$1" version
    shift
    if version=$(get_version "$@"); then
        check_pass "$label $version"
        return 0
    fi
    check_fail "$label — version readback failed"
    return 1
}

python3_canonicalizes_ip_literals() {
    local canonical
    if ! canonical=$(canonicalize_ip_literal '2001:0DB8:0:0:0:0:0:1'); then
        return 1
    fi
    [[ "$canonical" == '2001:db8::1' ]]
}

# `dpkg -l` can exit successfully for packages in a removed or otherwise
# incomplete state. Accept only an exact `ii` state and a nonempty version from
# the requested package row.
get_dpkg_installed_version() {
    local package="$1" output version
    if ! output=$(dpkg -l "$package" 2>/dev/null); then
        return 1
    fi
    version=$(printf '%s\n' "$output" | awk -v package="$package" '
        $1 == "ii" && ($2 == package || index($2, package ":") == 1) \
            && NF >= 3 && $3 != "" { print $3; exit }
    ')
    [[ -n "$version" ]] || return 1
    printf '%s\n' "$version"
}

# Install a package via apt (requires --install flag)
apt_install() {
    local pkg="$1"
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing $pkg..."
        sudo apt-get install -y "$pkg" >/dev/null 2>&1
        return $?
    fi
    return 1
}

# Compare version: returns 0 if $1 >= $2
version_gte() {
    printf '%s\n%s\n' "$2" "$1" | sort -V | head -1 | grep -qF "$2"
}

should_check_worker()  { [[ "$ROLE" == "all" || "$ROLE" == "worker" ]]; }
should_check_control() { [[ "$ROLE" == "all" || "$ROLE" == "control" ]]; }

# Execute Git with repository/configuration routing detached from the caller.
# Per-command policy is inherited by Git subprocesses, including the transport
# launched by `submodule update`.
doctor_git() (
    local git_env_name
    unset BASH_ENV ENV CDPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
        GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES \
        GIT_NAMESPACE GIT_CEILING_DIRECTORIES GIT_DISCOVERY_ACROSS_FILESYSTEM \
        GIT_CONFIG GIT_CONFIG_PARAMETERS GIT_ATTR_SOURCE GIT_SSH \
        GIT_SSH_COMMAND GIT_ASKPASS SSH_ASKPASS GIT_PROXY_COMMAND \
        GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_SSL_NO_VERIFY \
        GIT_SSL_CAINFO GIT_REPLACE_REF_BASE GIT_EXEC_PATH
    for git_env_name in "${!GIT_CONFIG_KEY_@}" "${!GIT_CONFIG_VALUE_@}"; do
        [[ -n "$git_env_name" ]] && unset "$git_env_name"
    done
    export HOME=/dev/null
    export XDG_CONFIG_HOME=/dev/null
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null
    export GIT_CONFIG_NOSYSTEM=1
    export GIT_CONFIG_COUNT=0
    export GIT_NO_REPLACE_OBJECTS=1
    export GIT_TERMINAL_PROMPT=0
    export LC_ALL=C
    command git \
        -c core.attributesFile=/dev/null \
        -c core.fsmonitor=false \
        -c core.hooksPath=/dev/null \
        -c credential.helper= \
        -c credential.interactive=false \
        -c protocol.allow=never \
        -c protocol.https.allow=always \
        -c protocol.file.allow=never \
        -c protocol.ext.allow=never \
        -c protocol.git.allow=never \
        -c protocol.ssh.allow=never \
        "$@"
)

SUBMODULE_POLICY_ERROR=""
EXPECTED_SUBMODULES=""
EXPECTED_SUBMODULE_URLS=""
EXPECTED_TOTAL=0

load_submodule_declarations() {
    local key path extra name url expected_url url_count seen_paths=""
    SUBMODULE_POLICY_ERROR=""
    if ! EXPECTED_SUBMODULES=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.path$' 2>/dev/null); then
        SUBMODULE_POLICY_ERROR="cannot read .gitmodules paths"
        return 1
    fi
    if ! EXPECTED_SUBMODULE_URLS=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.url$' 2>/dev/null); then
        SUBMODULE_POLICY_ERROR="cannot read .gitmodules URLs"
        return 1
    fi

    EXPECTED_TOTAL=0
    while read -r key path extra; do
        [[ -n "$key" && -n "$path" && -z "$extra" \
            && "$key" == submodule.*.path \
            && "$path" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*/[A-Za-z0-9][A-Za-z0-9._-]*$ \
            && "$path" != *'/.' && "$path" != *'/..' ]] || {
            SUBMODULE_POLICY_ERROR="unsafe submodule path declaration"
            return 1
        }
        name=${key#submodule.}
        name=${name%.path}
        [[ "$name" == "$path" ]] || {
            SUBMODULE_POLICY_ERROR="submodule name/path binding mismatch"
            return 1
        }
        if printf '%s\n' "$seen_paths" | grep -qxF "$path"; then
            SUBMODULE_POLICY_ERROR="duplicate submodule path declaration"
            return 1
        fi
        seen_paths="${seen_paths}${path}"$'\n'

        url_count=$(printf '%s\n' "$EXPECTED_SUBMODULE_URLS" \
            | awk -v wanted="submodule.${name}.url" '$1 == wanted { count++ } END { print count+0 }')
        [[ "$url_count" -eq 1 ]] || {
            SUBMODULE_POLICY_ERROR="missing or duplicate submodule URL binding"
            return 1
        }
        url=$(printf '%s\n' "$EXPECTED_SUBMODULE_URLS" \
            | awk -v wanted="submodule.${name}.url" '$1 == wanted { print $2; exit }')
        expected_url="https://github.com/HomericIntelligence/${path##*/}.git"
        [[ "$url" == "$expected_url" ]] || {
            SUBMODULE_POLICY_ERROR="non-canonical submodule URL"
            return 1
        }
        EXPECTED_TOTAL=$((EXPECTED_TOTAL + 1))
    done <<< "$EXPECTED_SUBMODULES"

    [[ "$EXPECTED_TOTAL" -gt 0 ]] || {
        SUBMODULE_POLICY_ERROR="empty submodule declaration inventory"
        return 1
    }
    url_count=$(printf '%s\n' "$EXPECTED_SUBMODULE_URLS" \
        | awk 'NF { count++ } END { print count+0 }')
    [[ "$url_count" -eq "$EXPECTED_TOTAL" ]] || {
        SUBMODULE_POLICY_ERROR="submodule path/URL inventory mismatch"
        return 1
    }
}

submodule_config_has_forbidden_policy() {
    local output status scope=$1
    local forbidden='^(include(\..*)?\.path|submodule\..*\.update|url\..*\.(insteadOf|pushInsteadOf)|protocol\..*\.allow)$'
    if [[ "$scope" == modules ]]; then
        output=$(doctor_git -C "$ODYSSEUS_ROOT" config --no-includes \
            -f .gitmodules --get-regexp "$forbidden" 2>/dev/null)
    else
        output=$(doctor_git -C "$ODYSSEUS_ROOT" config --local --no-includes \
            --get-regexp "$forbidden" 2>/dev/null)
    fi
    status=$?
    if [[ "$status" -eq 0 ]]; then
        [[ -n "$output" ]] || return 2
        return 0
    fi
    [[ "$status" -eq 1 ]] && return 1
    return 2
}

validate_submodule_git_policy() {
    local current_paths current_urls key path extra name declared_url local_url status
    SUBMODULE_POLICY_ERROR=""
    if ! current_paths=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.path$' 2>/dev/null) \
        || [[ "$current_paths" != "$EXPECTED_SUBMODULES" ]]; then
        SUBMODULE_POLICY_ERROR="submodule path declarations changed during inspection"
        return 1
    fi
    if ! current_urls=$(doctor_git -C "$ODYSSEUS_ROOT" config \
        --no-includes -f .gitmodules --get-regexp \
        '^submodule\..*\.url$' 2>/dev/null) \
        || [[ "$current_urls" != "$EXPECTED_SUBMODULE_URLS" ]]; then
        SUBMODULE_POLICY_ERROR="submodule URL declarations changed during inspection"
        return 1
    fi
    if submodule_config_has_forbidden_policy modules; then
        SUBMODULE_POLICY_ERROR=".gitmodules contains a forbidden update or routing policy"
        return 1
    else
        status=$?
        [[ "$status" -eq 1 ]] || {
            SUBMODULE_POLICY_ERROR="cannot validate .gitmodules update/routing policy"
            return 1
        }
    fi
    if submodule_config_has_forbidden_policy local; then
        SUBMODULE_POLICY_ERROR="local Git config contains a forbidden update or routing policy"
        return 1
    else
        status=$?
        [[ "$status" -eq 1 ]] || {
            SUBMODULE_POLICY_ERROR="cannot validate local Git update/routing policy"
            return 1
        }
    fi

    while read -r key path extra; do
        name=${key#submodule.}
        name=${name%.path}
        declared_url="https://github.com/HomericIntelligence/${path##*/}.git"
        local_url=$(doctor_git -C "$ODYSSEUS_ROOT" config --local \
            --no-includes --get "submodule.${name}.url" 2>/dev/null)
        status=$?
        if [[ "$status" -eq 0 ]]; then
            [[ "$local_url" == "$declared_url" ]] || {
                SUBMODULE_POLICY_ERROR="local submodule URL override does not match its declaration"
                return 1
            }
        elif [[ "$status" -ne 1 ]]; then
            SUBMODULE_POLICY_ERROR="cannot validate local submodule URL override"
            return 1
        fi
    done <<< "$EXPECTED_SUBMODULES"
}

# ─── Banner ──────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}HomericIntelligence Doctor — E2E Pipeline Prerequisites${NC}"
echo "═══════════════════════════════════════════════════════"
echo -e "  Role: ${CYAN}${ROLE}${NC}    Install: ${CYAN}${INSTALL}${NC}    Cross-host: ${CYAN}${CROSS_HOST}${NC}"

# ═════════════════════════════════════════════════════════════════════════════
# Section 1: Core Tooling (all hosts)
# Required by: Odysseus meta-repo, E2E scripts, Myrmidons provisioning
# ═════════════════════════════════════════════════════════════════════════════
section "Core Tooling"

# python3 is the sole prerequisite for peer target canonicalization. Inspect or
# repair it before the target boundary, then keep every unrelated tool and
# network effect behind that boundary.
PYTHON3_VERSION=""
PYTHON3_FAILURE="missing"
if resolve_python3; then
    if ! PYTHON3_VERSION=$(get_version "$PYTHON3_BIN" -I -S --version); then
        PYTHON3_FAILURE="version"
    elif python3_canonicalizes_ip_literals; then
        check_pass "python3 $PYTHON3_VERSION"
        PYTHON3_READY=true
    else
        PYTHON3_FAILURE="canonicalization"
    fi
fi
if ! $PYTHON3_READY; then
    if $INSTALL; then
        if apt_install python3 && resolve_python3 \
            && PYTHON3_VERSION=$(get_version "$PYTHON3_BIN" -I -S --version) \
            && python3_canonicalizes_ip_literals; then
            check_pass "python3 $PYTHON3_VERSION"
            PYTHON3_READY=true
            check_pass "python3 installed and available"
        else
            check_fail "python3 — install or post-install canonicalization check failed"
        fi
    else
        case "$PYTHON3_FAILURE" in
            missing)
                check_fail "python3 — NOT FOUND (required prerequisite)"
                ;;
            version)
                check_fail "python3 — version readback failed"
                ;;
            canonicalization)
                check_fail "python3 — IP literal canonicalization unavailable"
                ;;
        esac
    fi
fi

# Relationship errors were rejected before inspection. Literal validation now
# follows only the authorized Python prerequisite bootstrap and still precedes
# every unrelated inspection, install, topology, and network effect.
if [[ -n "$WORKER_IP" || -n "$CONTROL_IP" ]]; then
    if ! $PYTHON3_READY; then
        echo "ERROR: peer target validation requires a working python3 prerequisite" >&2
        exit 1
    fi
    if [[ -n "$WORKER_IP" ]] \
        && ! WORKER_IP=$(canonicalize_ip_literal "$WORKER_IP"); then
        echo "ERROR: peer targets must be literal IP addresses" >&2
        exit 1
    fi
    if [[ -n "$CONTROL_IP" ]] \
        && ! CONTROL_IP=$(canonicalize_ip_literal "$CONTROL_IP"); then
        echo "ERROR: peer targets must be literal IP addresses" >&2
        exit 1
    fi
fi

# git
if has_cmd git; then
    check_tool_version git git --version || :
else
    if apt_install git && has_cmd git && check_tool_version git git --version; then
        check_pass "git installed and available"
    else
        check_fail "git — NOT FOUND or post-install readback failed"
    fi
fi

# just
if has_cmd just; then
    check_tool_version just just --version || :
else
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing just..."
        JUST_INSTALL_SUCCEEDED=false
        if has_cmd cargo; then
            if cargo install just >/dev/null 2>&1; then
                JUST_INSTALL_SUCCEEDED=true
            fi
        else
            if curl_bounded 60 -sSf https://just.systems/install.sh \
                | bash -s -- --to /usr/local/bin >/dev/null 2>&1; then
                JUST_INSTALL_SUCCEEDED=true
            fi
        fi
        if $JUST_INSTALL_SUCCEEDED && has_cmd just \
            && check_tool_version just just --version; then
            check_pass "just installed and available"
        else
            check_fail "just — install or post-install readback failed"
        fi
    else
        check_fail "just — NOT FOUND"
    fi
fi

# pip3
if has_cmd pip3; then
    check_tool_version pip3 pip3 --version || :
else
    if apt_install python3-pip && has_cmd pip3 \
        && check_tool_version pip3 pip3 --version; then
        check_pass "pip3 installed and available"
    else
        check_fail "pip3 — NOT FOUND or post-install readback failed"
    fi
fi

# curl
if has_cmd curl; then
    check_tool_version curl curl --version || :
else
    if apt_install curl && has_cmd curl \
        && check_tool_version curl curl --version; then
        check_pass "curl installed and available"
    else
        check_fail "curl — NOT FOUND or post-install readback failed"
    fi
fi

# jq
if has_cmd jq; then
    check_tool_version jq jq --version || :
else
    if apt_install jq && has_cmd jq && check_tool_version jq jq --version; then
        check_pass "jq installed and available"
    else
        check_fail "jq — NOT FOUND or post-install readback failed"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 2: Tailscale (Network Topology — all hosts)
# Required by: Cross-host NATS, Agamemnon/Nestor communication over mesh
# ═════════════════════════════════════════════════════════════════════════════
if $CROSS_HOST; then
section "Tailscale (Network Topology)"

if has_cmd tailscale; then
    check_tool_version tailscale tailscale --version || :
else
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing tailscale..."
        if curl_bounded 60 -fsSL https://tailscale.com/install.sh \
            | sh >/dev/null 2>&1 \
            && has_cmd tailscale \
            && check_tool_version tailscale tailscale --version; then
            check_pass "tailscale installed and available"
        else
            check_fail "tailscale — install or post-install readback failed (see https://tailscale.com/download)"
        fi
    else
        check_fail "tailscale — NOT FOUND"
    fi
fi

# Capture one parseable live topology snapshot. A successful status exit alone
# is not peer identity or topology evidence.
if has_cmd tailscale; then
    if run_bounded_command "$TAILSCALE_TIMEOUT_SECONDS" \
        "$TAILSCALE_MAX_BYTES" tailscale status --json; then
        TAILSCALE_STATUS_JSON=$BOUNDED_OUTPUT
    else
        TAILSCALE_STATUS_JSON=""
    fi
    if [[ -n "$TAILSCALE_STATUS_JSON" ]] \
        && printf '%s\n' "$TAILSCALE_STATUS_JSON" | valid_tailscale_status; then
        TAILSCALE_STATUS_AVAILABLE=true
        check_pass "tailscaled running"
    else
        if $INSTALL; then
            if sudo systemctl start tailscaled 2>/dev/null \
                && run_bounded_command "$TAILSCALE_TIMEOUT_SECONDS" \
                    "$TAILSCALE_MAX_BYTES" tailscale status --json; then
                TAILSCALE_STATUS_JSON=$BOUNDED_OUTPUT
            else
                TAILSCALE_STATUS_JSON=""
            fi
            if [[ -n "$TAILSCALE_STATUS_JSON" ]] \
                && printf '%s\n' "$TAILSCALE_STATUS_JSON" \
                    | valid_tailscale_status; then
                TAILSCALE_STATUS_AVAILABLE=true
                check_pass "tailscaled running after start"
            else
                check_fail "tailscaled — start or post-start readback failed"
            fi
        else
            check_fail "tailscaled not running"
        fi
    fi
fi

# Firewall readiness is deployment-specific. Whole-interface trust is neither
# inspected as proof nor mutated here; bind exact listeners, peers, and current
# policy in an operator-owned deployment procedure.
if should_check_worker; then
    check_skip "firewall readiness requires an exact deployment-owned listener/peer policy"
fi

# Check peer reachability (if IPs provided)
if [[ -n "$WORKER_IP" ]]; then
    if $TAILSCALE_STATUS_AVAILABLE \
        && printf '%s\n' "$TAILSCALE_STATUS_JSON" \
            | is_online_tailscale_peer "$WORKER_IP"; then
        WORKER_PEER_VERIFIED=true
        check_pass "Worker host ($WORKER_IP) is an online Tailscale peer"
    else
        check_fail "Worker host ($WORKER_IP) is not an online Tailscale peer"
    fi
    if $WORKER_PEER_VERIFIED; then
        if ping -c1 -W3 "$WORKER_IP" >/dev/null 2>&1; then
            check_pass "Worker host ($WORKER_IP) reachable"
        else
            check_fail "Worker host ($WORKER_IP) NOT reachable"
        fi
    fi
fi
if [[ -n "$CONTROL_IP" ]]; then
    if $TAILSCALE_STATUS_AVAILABLE \
        && printf '%s\n' "$TAILSCALE_STATUS_JSON" \
            | is_online_tailscale_peer "$CONTROL_IP"; then
        CONTROL_PEER_VERIFIED=true
        check_pass "Control host ($CONTROL_IP) is an online Tailscale peer"
    else
        check_fail "Control host ($CONTROL_IP) is not an online Tailscale peer"
    fi
    if $CONTROL_PEER_VERIFIED; then
        if ping -c1 -W3 "$CONTROL_IP" >/dev/null 2>&1; then
            check_pass "Control host ($CONTROL_IP) reachable"
        else
            check_fail "Control host ($CONTROL_IP) NOT reachable"
        fi
    fi
fi
else
    section "Tailscale (Network Topology)"
    check_skip "cross-host checks not selected"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 3: Container Runtime (Worker host — AchaeanFleet / supported Compose paths)
# Required by: docker-compose.e2e.yml and component-owned container workflows
# ═════════════════════════════════════════════════════════════════════════════
if should_check_worker; then
    section "Container Runtime (AchaeanFleet)"

    # podman
    if has_cmd podman; then
        check_tool_version podman podman --version || :
    else
        if apt_install podman && has_cmd podman \
            && check_tool_version podman podman --version; then
            check_pass "podman installed and available"
        else
            check_fail "podman — NOT FOUND or post-install readback failed"
        fi
    fi

    # podman compose
    if has_cmd podman; then
        if COMPOSE_VER=$(get_version podman compose version); then
            check_pass "podman compose ${COMPOSE_VER}"
        else
            check_fail "podman compose — version readback failed"
        fi
    else
        if apt_install podman-compose \
            && has_cmd podman \
            && check_tool_version "podman compose" podman compose version; then
            check_pass "podman compose installed and available"
        else
            check_fail "podman compose — NOT FOUND or post-install readback failed"
        fi
    fi

    # podman socket
    PODMAN_SOCK="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/podman/podman.sock"
    if [[ -S "$PODMAN_SOCK" ]]; then
        check_pass "podman socket active ($PODMAN_SOCK)"
    else
        if $INSTALL; then
            # Ensure XDG_RUNTIME_DIR and DBUS_SESSION_BUS_ADDRESS are set —
            # SSH sessions and sudo strip these, breaking systemctl --user.
            export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
            export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-unix:path=${XDG_RUNTIME_DIR}/bus}"

            # Enabling a service is safe only when the selected Podman package
            # already owns a verifiable unit. Doctor does not synthesize host
            # service definitions from guessed source-tree paths.
            if ! systemctl --user cat podman.socket &>/dev/null; then
                check_fail "packaged podman.socket unit is unavailable; stop for an operator-owned package repair"
            elif systemctl --user enable --now podman.socket 2>/dev/null \
                && [[ -S "$PODMAN_SOCK" ]]; then
                check_pass "podman socket enabled and active"
            else
                check_fail "podman socket — enable or post-enable readback failed"
                echo -e "    ${DIM}This usually means no systemd user session is running (common over SSH).${NC}"
                echo -e "    ${DIM}Fix: run 'sudo loginctl enable-linger $USER' then reconnect,${NC}"
                echo -e "    ${DIM}or run 'systemctl --user enable --now podman.socket' from a desktop session.${NC}"
            fi
        else
            check_fail "podman socket not found"
        fi
    fi

    # aardvark-dns stale check (WSL2 specific)
    AARDVARK_PID_DIR="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/networks/aardvark-dns"
    if [[ -f "$AARDVARK_PID_DIR/aardvark.pid" ]]; then
        AARDVARK_PID=$(cat "$AARDVARK_PID_DIR/aardvark.pid" 2>/dev/null || echo "")
        if [[ -n "$AARDVARK_PID" ]] && ! kill -0 "$AARDVARK_PID" 2>/dev/null; then
            check_warn "aardvark-dns PID stale (PID $AARDVARK_PID not running)"
            if $INSTALL; then
                if rm -f "$AARDVARK_PID_DIR/aardvark.pid"; then
                    check_pass "stale aardvark-dns PID cleared"
                else
                    check_warn "could not clear stale aardvark-dns PID file"
                fi
            fi
        else
            check_pass "aardvark-dns OK"
        fi
    else
        check_pass "aardvark-dns no stale PID"
    fi
else
    section "Container Runtime (AchaeanFleet)"
    check_skip "Container runtime checks (role=$ROLE)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 4: C++ Build Chain (Control host — builds Nestor, Charybdis)
# Required by: just _build-nestor, just _build-agamemnon, just _build-charybdis
# ═════════════════════════════════════════════════════════════════════════════
if should_check_control; then
    section "C++ Build Chain"

    # cmake >= 3.20
    if has_cmd cmake; then
        CMAKE_VER=$(get_version cmake --version)
        if version_gte "$CMAKE_VER" "3.20"; then
            check_pass "cmake $CMAKE_VER (>= 3.20)"
        else
            check_fail "cmake $CMAKE_VER — need >= 3.20"
        fi
    else
        if apt_install cmake \
            && has_cmd cmake \
            && version_gte "$(get_version cmake --version)" "3.20"; then
            check_pass "cmake installed and version requirement verified"
        else
            check_fail "cmake — NOT FOUND or post-install version check failed"
        fi
    fi

    # ninja
    if has_cmd ninja; then
        check_tool_version ninja ninja --version || :
    else
        if apt_install ninja-build && has_cmd ninja \
            && check_tool_version ninja ninja --version; then
            check_pass "ninja installed and available"
        else
            check_fail "ninja — NOT FOUND or post-install readback failed"
        fi
    fi

    # g++ >= 11
    if has_cmd g++; then
        GPP_VER=$(get_version g++ --version)
        if version_gte "$GPP_VER" "11"; then
            check_pass "g++ $GPP_VER (>= 11)"
        else
            check_fail "g++ $GPP_VER — need >= 11 for C++20"
        fi
    else
        if apt_install g++ \
            && has_cmd g++ \
            && version_gte "$(get_version g++ --version)" "11"; then
            check_pass "g++ installed and version requirement verified"
        else
            check_fail "g++ — NOT FOUND or post-install version check failed"
        fi
    fi

    # libssl-dev
    if LIBSSL_VER=$(get_dpkg_installed_version libssl-dev); then
        check_pass "libssl-dev $LIBSSL_VER"
    else
        if apt_install libssl-dev \
            && LIBSSL_VER=$(get_dpkg_installed_version libssl-dev); then
            check_pass "libssl-dev $LIBSSL_VER installed and package state verified"
        else
            if $INSTALL; then
                check_fail "libssl-dev — install or post-install package state/version check failed"
            else
                check_fail "libssl-dev — NOT FOUND or package state/version check failed"
            fi
        fi
    fi

    # make (needed for gtest CMake recipe)
    if has_cmd make; then
        check_tool_version make make --version || :
    else
        if apt_install make && has_cmd make \
            && check_tool_version make make --version; then
            check_pass "make installed and available"
        else
            check_fail "make — NOT FOUND or post-install readback failed"
        fi
    fi

    # conan >= 2.0
    if has_cmd conan; then
        CONAN_VER=$(get_version conan --version)
        if version_gte "$CONAN_VER" "2.0"; then
            check_pass "conan $CONAN_VER (>= 2.0)"
        else
            check_fail "conan $CONAN_VER — need >= 2.0"
        fi
    else
        if $INSTALL; then
            echo -e "    ${BLUE}→${NC} Installing conan..."
            if pip3 install --break-system-packages conan >/dev/null 2>&1 \
                && has_cmd conan \
                && version_gte "$(get_version conan --version)" "2.0"; then
                check_pass "conan installed and version requirement verified"
            else
                check_fail "conan — install or post-install version check failed"
            fi
        else
            check_fail "conan — NOT FOUND"
        fi
    fi

    # Conan default profile
    if has_cmd conan; then
        if conan profile show >/dev/null 2>&1; then
            check_pass "Conan default profile exists"
        else
            if $INSTALL; then
                if conan profile detect --force >/dev/null 2>&1 \
                    && conan profile show >/dev/null 2>&1; then
                    check_pass "Conan default profile created and verified"
                else
                    check_fail "Conan profile creation or readback failed"
                fi
            else
                check_fail "Conan default profile missing"
            fi
        fi
    fi

    # pixi
    if has_cmd pixi; then
        check_tool_version pixi pixi --version || :
    else
        if $INSTALL; then
            echo -e "    ${BLUE}→${NC} Installing pixi..."
            if curl_bounded 60 -fsSL https://pixi.sh/install.sh \
                | bash >/dev/null 2>&1 \
                && has_cmd pixi \
                && check_tool_version pixi pixi --version; then
                check_pass "pixi installed and available"
            else
                check_fail "pixi — install or post-install readback failed (see https://pixi.sh)"
            fi
        else
            check_fail "pixi — NOT FOUND"
        fi
    fi
else
    section "C++ Build Chain"
    check_skip "C++ build chain checks (role=$ROLE)"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 5: Python Dependencies (NATS observability bridge)
# Required by: e2e/nats-loki-bridge/; also needed by the planned console watch path
# ═════════════════════════════════════════════════════════════════════════════
section "Python Dependencies"

# nats-py (required by the NATS-to-Loki bridge)
read_nats_py_version() {
    run_bounded_command "$PYTHON_CHECK_TIMEOUT_SECONDS" \
        "$PYTHON_CHECK_MAX_BYTES" "$PYTHON3_BIN" -I -S -c '
import importlib.machinery
import importlib.metadata
import sysconfig

paths = []
for key in ("purelib", "platlib"):
    candidate = sysconfig.get_path(key)
    if candidate and candidate not in paths:
        paths.append(candidate)
if importlib.machinery.PathFinder.find_spec("nats", paths) is None:
    raise SystemExit(1)
for distribution in importlib.metadata.distributions(path=paths):
    name = distribution.metadata.get("Name", "").lower().replace("_", "-")
    if name == "nats-py":
        print(distribution.version)
        raise SystemExit(0)
print("installed")
'
}

if $PYTHON3_READY && read_nats_py_version; then
    NATS_PY_VER=$BOUNDED_OUTPUT
    check_pass "nats-py $NATS_PY_VER"
else
    if $INSTALL; then
        echo -e "    ${BLUE}→${NC} Installing nats-py..."
        if pip3 install --break-system-packages nats-py >/dev/null 2>&1 \
            && $PYTHON3_READY && read_nats_py_version; then
            check_pass "nats-py installed and import verified"
        else
            check_fail "nats-py — install or post-install import failed"
        fi
    else
        check_fail "nats-py — NOT FOUND (required by e2e/nats-loki-bridge)"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 6: Submodule Health (Odysseus meta-repo)
# Required by: All submodule builds, Myrmidons provisioning
# ═════════════════════════════════════════════════════════════════════════════
section "Submodule Health"

# Check if we're in the Odysseus repo
if [[ -f "$ODYSSEUS_ROOT/.gitmodules" ]]; then
    SUBMODULE_INVENTORY_AVAILABLE=true
    SUBMODULE_PATH_INVENTORY_COMPLETE=false
    if ! load_submodule_declarations; then
        check_fail "submodule inventory unavailable: $SUBMODULE_POLICY_ERROR"
        SUBMODULE_INVENTORY_AVAILABLE=false
    elif ! validate_submodule_git_policy; then
        check_fail "submodule Git policy rejected: $SUBMODULE_POLICY_ERROR"
        SUBMODULE_INVENTORY_AVAILABLE=false
    elif ! SUBMODULE_STATUS=$(doctor_git -C "$ODYSSEUS_ROOT" \
        submodule status 2>/dev/null); then
        check_fail "submodule inventory unavailable: git submodule status failed"
        SUBMODULE_INVENTORY_AVAILABLE=false
    fi

    if $SUBMODULE_INVENTORY_AVAILABLE; then
        TOTAL_SUBS=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF{n++} END{print n+0}')
        UNINIT_COUNT=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF && /^-/{n++} END{print n+0}')
        DRIFT_COUNT=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF && /^[+U]/{n++} END{print n+0}')
        EXPECTED_PATHS=$(printf '%s\n' "$EXPECTED_SUBMODULES" | awk 'NF{print $2}' | sort)
        STATUS_PATHS=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF{print $2}' | sort)
        SUBMODULE_PATH_INVENTORY_COMPLETE=true

        if [[ "$TOTAL_SUBS" -ne "$EXPECTED_TOTAL" \
            || "$STATUS_PATHS" != "$EXPECTED_PATHS" ]]; then
            check_fail "submodule inventory incomplete or mismatched: expected $EXPECTED_TOTAL exact paths, read $TOTAL_SUBS"
            SUBMODULE_PATH_INVENTORY_COMPLETE=false
        elif [[ "$DRIFT_COUNT" -ne 0 ]]; then
            check_fail "$DRIFT_COUNT / $TOTAL_SUBS submodules differ from their pinned gitlinks"
        elif [[ "$UNINIT_COUNT" -eq 0 ]]; then
            check_pass "All $TOTAL_SUBS submodules initialized at their pins"
        elif $INSTALL; then
            echo -e "    ${BLUE}→${NC} Initializing missing submodules at pinned commits..."
            UNINIT_PATHS=()
            while read -r status_entry subpath _rest; do
                if [[ "$status_entry" == -* ]]; then
                    UNINIT_PATHS+=("$subpath")
                fi
            done <<< "$SUBMODULE_STATUS"
            if ! validate_submodule_git_policy; then
                SUBMODULE_PATH_INVENTORY_COMPLETE=false
                check_fail "submodule Git policy rejected before initialization: $SUBMODULE_POLICY_ERROR"
            elif [[ "${#UNINIT_PATHS[@]}" -ne "$UNINIT_COUNT" ]]; then
                SUBMODULE_PATH_INVENTORY_COMPLETE=false
                check_fail "submodule initialization path inventory was not exact"
            elif doctor_git -C "$ODYSSEUS_ROOT" submodule update --init -- \
                "${UNINIT_PATHS[@]}" >/dev/null 2>&1 \
                && validate_submodule_git_policy \
                && SUBMODULE_STATUS=$(doctor_git -C "$ODYSSEUS_ROOT" \
                    submodule status 2>/dev/null); then
                TOTAL_SUBS=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF{n++} END{print n+0}')
                STATUS_PATHS=$(printf '%s\n' "$SUBMODULE_STATUS" | awk 'NF{print $2}' | sort)
                POST_UPDATE_UNSAFE=$(printf '%s\n' "$SUBMODULE_STATUS" | \
                    awk 'NF && /^[-+U]/{n++} END{print n+0}')
                if [[ "$TOTAL_SUBS" -eq "$EXPECTED_TOTAL" \
                    && "$STATUS_PATHS" == "$EXPECTED_PATHS" \
                    && "$POST_UPDATE_UNSAFE" -eq 0 ]]; then
                    check_pass "All $TOTAL_SUBS submodules initialized at their pins"
                else
                    SUBMODULE_PATH_INVENTORY_COMPLETE=false
                    check_fail "post-initialization submodule inventory did not match all expected pinned paths"
                fi
            else
                SUBMODULE_PATH_INVENTORY_COMPLETE=false
                check_fail "Submodule initialization or pin readback failed"
            fi
        else
            check_fail "$UNINIT_COUNT / $TOTAL_SUBS submodules NOT initialized"
        fi

        # Check Myrmidons not targeting ai-maestro (#77). A pinned component is
        # diagnostic-only here; repairs belong in its repository and integration PR.
        MYRMIDONS_DIR="$ODYSSEUS_ROOT/provisioning/Myrmidons"
        if [[ -d "$MYRMIDONS_DIR/scripts" ]]; then
            if STALE_OUTPUT=$(grep -rE \
                '(ai[-_]maestro|MAESTRO_URL|\baim_[a-z]+\()' \
                "$MYRMIDONS_DIR/scripts/" 2>/dev/null); then
                STALE_REFS=$(printf '%s\n' "$STALE_OUTPUT" | awk 'NF{n++} END{print n+0}')
                check_fail "Myrmidons has $STALE_REFS stale ai-maestro references (aim_*)"
                if $INSTALL; then
                    check_warn "Pinned Myrmidons is not auto-updated; repair its owner repo, then integrate an approved gitlink"
                fi
            else
                GREP_STATUS=$?
                if [[ "$GREP_STATUS" -eq 1 ]]; then
                    check_pass "Myrmidons targets Agamemnon (not ai-maestro)"
                else
                    check_fail "Myrmidons reference scan unavailable"
                fi
            fi
        else
            check_warn "Myrmidons scripts directory not found — submodule may not be initialized"
        fi

        if $SUBMODULE_PATH_INVENTORY_COMPLETE; then
            BROKEN_PATHS=0
            while IFS= read -r line; do
                subpath=$(printf '%s\n' "$line" | awk '{print $2}')
                if [[ -z "$subpath" || -L "$ODYSSEUS_ROOT/$subpath" \
                    || ! -d "$ODYSSEUS_ROOT/$subpath" ]]; then
                    BROKEN_PATHS=$((BROKEN_PATHS + 1))
                fi
            done <<< "$SUBMODULE_STATUS"
            if [[ "$BROKEN_PATHS" -eq 0 ]]; then
                check_pass "All submodule paths are direct directories"
            else
                check_fail "$BROKEN_PATHS submodule paths are missing or symlinked"
            fi
        else
            check_skip "submodule path checks unavailable from an incomplete inventory"
        fi
    fi
else
    check_fail "submodule metadata unavailable: .gitmodules is missing"
fi

# ═════════════════════════════════════════════════════════════════════════════
# Section 7: Network Connectivity (cross-host service health)
# Only checked with --check-services --worker-ip IP --control-ip IP
# ═════════════════════════════════════════════════════════════════════════════
if $CHECK_SERVICES; then
    section "Service Health (Cross-Host)"

    if [[ -n "$WORKER_IP" ]]; then
        WORKER_HTTP_HOST=$(http_host_for_ip "$WORKER_IP")
        if $WORKER_PEER_VERIFIED; then
            check_service_health "NATS @ ${WORKER_IP}:8222" \
                "http://${WORKER_HTTP_HOST}:8222/healthz" nats
            check_service_health "Agamemnon @ ${WORKER_IP}:8080" \
                "http://${WORKER_HTTP_HOST}:8080/v1/health" status
            check_service_health "Hermes @ ${WORKER_IP}:8085" \
                "http://${WORKER_HTTP_HOST}:8085/health" hermes
            check_service_health "Grafana @ ${WORKER_IP}:3001" \
                "http://${WORKER_HTTP_HOST}:3001/api/health" grafana
            check_service_health "Prometheus @ ${WORKER_IP}:9090" \
                "http://${WORKER_HTTP_HOST}:9090/-/healthy" prometheus
            check_service_health "Argus Exporter @ ${WORKER_IP}:9100" \
                "http://${WORKER_HTTP_HOST}:9100/metrics" argus
        else
            check_skip "worker service checks require an exact online Tailscale peer"
        fi
    else
        check_warn "No --worker-ip provided — skipping worker service checks"
    fi

    if [[ -n "$CONTROL_IP" ]]; then
        CONTROL_HTTP_HOST=$(http_host_for_ip "$CONTROL_IP")
        if $CONTROL_PEER_VERIFIED; then
            check_service_health "Nestor @ ${CONTROL_IP}:8081" \
                "http://${CONTROL_HTTP_HOST}:8081/v1/health" status
        else
            check_skip "control service checks require an exact online Tailscale peer"
        fi
    else
        check_warn "No --control-ip provided — skipping control service checks"
    fi
fi

# ═════════════════════════════════════════════════════════════════════════════
# Summary
# ═════════════════════════════════════════════════════════════════════════════
echo ""
echo "═══════════════════════════════════════════════════════"
TOTAL=$((_PASS + _FAIL + _WARN))
if [[ "$_FAIL" -eq 0 && "$_WARN" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}All $TOTAL checks passed.${NC}"
elif [[ "$_FAIL" -eq 0 ]]; then
    echo -e "${GREEN}${BOLD}$_PASS passed${NC}, ${YELLOW}$_WARN warnings${NC}"
else
    echo -e "${RED}${BOLD}$_FAIL failed${NC}, ${GREEN}$_PASS passed${NC}, ${YELLOW}$_WARN warnings${NC}"
    if ! $INSTALL; then
        echo -e "Run ${CYAN}just doctor --install${NC} to fix installable issues."
    fi
fi
echo ""

# Exit with failure if any checks failed
[[ "$_FAIL" -eq 0 ]]
