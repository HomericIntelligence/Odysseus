#!/usr/bin/env bash
# Hermetic command-contract checks for the IPC test runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

info "NATS monitor reads have one deadline and a response ceiling"
if python3 - "$ROOT/e2e/lib/common.sh" "$ROOT/e2e/lib/nats.sh" <<'PY'
import os
import shlex
import signal
import socket
import subprocess
import sys
import threading
import time

common_path, nats_path = sys.argv[1:]
process_path = os.path.join(os.path.dirname(nats_path), "process.sh")


def serve(response: bytes | None, *, stall: bool = False):
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind(("127.0.0.1", 0))
    listener.listen(1)
    accepted = threading.Event()

    def worker():
        connection, _ = listener.accept()
        accepted.set()
        try:
            request = b""
            connection.settimeout(2)
            while b"\r\n\r\n" not in request and len(request) <= 8192:
                chunk = connection.recv(4096)
                if not chunk:
                    break
                request += chunk
            if stall:
                time.sleep(5)
            elif response is not None:
                connection.sendall(response)
        except (BrokenPipeError, ConnectionResetError, socket.timeout):
            pass
        finally:
            connection.close()
            listener.close()

    threading.Thread(target=worker, daemon=True).start()
    return listener.getsockname()[1], accepted


def invoke(function: str, port: int, timeout: float = 4.0):
    command = (
        f"source {shlex.quote(common_path)}; "
        f"source {shlex.quote(process_path)}; "
        f"source {shlex.quote(nats_path)}; "
        f"NATS_MONITOR_PORT={port}; {function}"
    )
    process = subprocess.Popen(
        ["/bin/bash", "-c", command],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    started = time.monotonic()
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        stdout, stderr = process.communicate()
        return None, stdout, stderr, time.monotonic() - started
    return process.returncode, stdout, stderr, time.monotonic() - started


failures = []

port, accepted = serve(None, stall=True)
status, stdout, _stderr, elapsed = invoke("nats_connz", port)
if not accepted.wait(timeout=1):
    failures.append("stalled-response server did not receive the request")
elif status is None or status == 0 or stdout or elapsed >= 3.5:
    failures.append(
        f"stalled connz escaped its deadline: status={status} "
        f"bytes={len(stdout)} elapsed={elapsed:.2f}"
    )

oversized_body = b'{"pad":"' + (b"a" * (1024 * 1024)) + b'"}'
oversized_response = (
    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: "
    + str(len(oversized_body)).encode("ascii")
    + b"\r\nConnection: close\r\n\r\n"
    + oversized_body
)
port, accepted = serve(oversized_response)
status, stdout, _stderr, _elapsed = invoke("nats_jsz", port)
if not accepted.wait(timeout=1):
    failures.append("oversized-response server did not receive the request")
elif status == 0 or len(stdout) > 1024 * 1024:
    failures.append(
        f"oversized jsz was accepted: status={status} bytes={len(stdout)}"
    )

malformed_body = b"not-json"
malformed_response = (
    b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 8\r\n"
    b"Connection: close\r\n\r\n" + malformed_body
)
port, accepted = serve(malformed_response)
status, stdout, _stderr, _elapsed = invoke("nats_subsz", port)
if not accepted.wait(timeout=1):
    failures.append("malformed-response server did not receive the request")
elif status == 0 or stdout:
    failures.append(
        f"malformed subsz was accepted: status={status} bytes={len(stdout)}"
    )

redirect_body = b'{"connections":[]}'
redirect_response = (
    b"HTTP/1.1 302 Found\r\nContent-Type: application/json\r\nContent-Length: "
    + str(len(redirect_body)).encode("ascii")
    + b"\r\nLocation: /other\r\nConnection: close\r\n\r\n"
    + redirect_body
)
port, accepted = serve(redirect_response)
status, stdout, _stderr, _elapsed = invoke("nats_connz", port)
if not accepted.wait(timeout=1):
    failures.append("redirect-response server did not receive the request")
elif status == 0 or stdout:
    failures.append(
        f"JSON redirect was accepted: status={status} bytes={len(stdout)}"
    )

if failures:
    print("; ".join(failures), file=sys.stderr)
    raise SystemExit(1)
PY
then
    pass "stalled, oversized, and malformed NATS monitor responses fail closed"
else
    fail "a NATS monitor response escaped its deadline or response contract"
fi

fixture_prefix="${TMPDIR:-/tmp}"
fixture_prefix="${fixture_prefix%/}/odysseus-run-ipc."
fixture_root=""
if ! fixture_root="$(mktemp -d "${fixture_prefix}XXXXXX")" \
   || [ ! -d "$fixture_root" ] || [ -L "$fixture_root" ]; then
    printf '%s\n' 'ERROR: could not create a safe IPC runner fixture' >&2
    exit 1
fi
cleanup_fixture() {
    local initial_status="$1" cleanup_status=0 suffix
    trap - EXIT
    suffix="${fixture_root#"$fixture_prefix"}"
    case "$suffix" in
        ''|*[!A-Za-z0-9]*) cleanup_status=1 ;;
        *)
            if ! rm -r -- "$fixture_root" \
               || [ -e "$fixture_root" ] || [ -L "$fixture_root" ]; then
                cleanup_status=1
            fi
            ;;
    esac
    if [ "$cleanup_status" -ne 0 ]; then
        printf 'ERROR: failed to remove IPC runner fixture: %s\n' \
            "$fixture_root" >&2
    fi
    if [ "$initial_status" -ne 0 ]; then
        exit "$initial_status"
    fi
    exit "$cleanup_status"
}
trap 'cleanup_fixture "$?"' EXIT

prepare_runner() {
    local case_name="$1"
    case_root="$fixture_root/$case_name"
    mkdir -p "$case_root/e2e/lib" "$case_root/e2e/tests/protocol"
    cp "$ROOT/e2e/run-ipc-tests.sh" "$case_root/e2e/run-ipc-tests.sh"
    cat > "$case_root/e2e/lib/topology.sh" <<'EOF'
#!/usr/bin/env bash
RED= GREEN= BLUE= CYAN= NC=
info() { :; }
topology_start() {
    printf 'start %s\n' "$1" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
}
topology_stop() {
    printf 'stop %s\n' "$1" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
    if [ "${ODYSSEUS_TEST_STOP_MODE:-ok}" = fail ]; then
        printf 'forced stop failure\n' >&2
        return 23
    fi
}
topology_wait_healthy() {
    printf 'health %s\n' "$1" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
    AGAMEMNON_PORT=18080
    NATS_PORT=14222
    NATS_MONITOR_PORT=18222
    HERMES_PORT=18081
    export AGAMEMNON_PORT NATS_PORT NATS_MONITOR_PORT HERMES_PORT
}
EOF
}

run_runner() {
    local case_name="$1"
    shift
    ODYSSEUS_TEST_EFFECT_LOG="$case_root/effects" \
    ODYSSEUS_TEST_STOP_MODE="${ODYSSEUS_TEST_STOP_MODE:-ok}" \
        "$BASH" "$case_root/e2e/run-ipc-tests.sh" "$@" \
        > "$case_root/output" 2>&1
}

assert_rejected_before_topology() {
    local case_name="$1" expected="$2"
    if run_runner "$case_name" "${runner_args[@]}"; then
        fail "$case_name reported success"
    elif [ -s "$case_root/effects" ]; then
        fail "$case_name reached topology operations"
    elif grep -Fqi "$expected" "$case_root/output"; then
        pass "$case_name rejects the request before topology operations"
    else
        fail "$case_name did not report the rejected input"
    fi
}

info "required option values are validated before topology operations"
prepare_runner missing-category-value
runner_args=(--topology t4 --category)
assert_rejected_before_topology missing-category-value "category requires a value"

prepare_runner missing-test-value
runner_args=(--topology t4 --category protocol --test)
assert_rejected_before_topology missing-test-value "test requires a value"

info "unknown selections are rejected before topology operations"
prepare_runner unknown-category
runner_args=(--topology t4 --category typo)
assert_rejected_before_topology unknown-category "unknown category"

prepare_runner unknown-test
cat > "$case_root/e2e/tests/protocol/known.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
runner_args=(--topology t4 --category protocol --test missing)
assert_rejected_before_topology unknown-test "unknown test"

prepare_runner path-shaped-test
cat > "$case_root/e2e/tests/outside.sh" <<'EOF'
#!/usr/bin/env bash
printf 'outside test ran\n' >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
EOF
runner_args=(--topology t4 --category protocol --test ../outside)
assert_rejected_before_topology path-shaped-test "unknown test"

info "an empty selected inventory is a failure"
prepare_runner empty-inventory
runner_args=(--topology t4 --category protocol)
assert_rejected_before_topology empty-inventory "no test scripts"

info "a valid selected test runs and reports a non-empty total"
prepare_runner valid-selection
cat > "$case_root/e2e/tests/protocol/known.sh" <<'EOF'
#!/usr/bin/env bash
printf 'test known\n' >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
EOF
if run_runner valid-selection \
    --topology t4 --category protocol --test known; then
    if grep -Fq 'health t4' "$case_root/effects" \
       && grep -Fq 'test known' "$case_root/effects" \
       && grep -Fq '1 / 1 test scripts' "$case_root/output"; then
        pass "a valid single-test selection runs exactly one test"
    else
        fail "a valid single-test selection omitted its observable result"
    fi
else
    fail "a valid single-test selection reported failure"
fi

info "T1 cleanup status is part of the runner exit contract"
prepare_runner valid-t1-cleanup
cat > "$case_root/e2e/tests/protocol/known.sh" <<'EOF'
#!/usr/bin/env bash
printf 'test known\n' >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
EOF
if run_runner valid-t1-cleanup \
    --topology t1 --category protocol --test known \
    && grep -Fq 'start t1' "$case_root/effects" \
    && grep -Fq 'stop t1' "$case_root/effects"; then
    pass "a passing T1 run remains successful after successful cleanup"
else
    fail "successful T1 cleanup changed a passing run result"
fi

prepare_runner failed-t1-cleanup
cat > "$case_root/e2e/tests/protocol/known.sh" <<'EOF'
#!/usr/bin/env bash
printf 'test known\n' >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
EOF
if ODYSSEUS_TEST_STOP_MODE=fail run_runner failed-t1-cleanup \
    --topology t1 --category protocol --test known; then
    fail "a failed topology_stop was masked by a passing test result"
elif grep -Fq 'stop t1' "$case_root/effects" \
    && grep -Fq 'ERROR: topology cleanup failed for t1' \
        "$case_root/output"; then
    pass "topology_stop failure forces a diagnostic nonzero result"
else
    fail "failed T1 cleanup did not retain its effect and diagnostic"
fi

summary
exit_code
