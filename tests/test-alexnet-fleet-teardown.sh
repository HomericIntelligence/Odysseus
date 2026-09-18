#!/usr/bin/env bash
# Hermetic behavior checks for exact-target AlexNet fleet teardown.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/odysseus-alexnet-teardown.XXXXXX")"
fixture_bin="$fixture_root/bin"
mkdir -p "$fixture_bin"
cleanup_fixture() {
    if ! rm -r -- "$fixture_root"; then
        echo "ERROR: failed to remove AlexNet teardown fixture: $fixture_root" >&2
    fi
}
trap cleanup_fixture EXIT

cat > "$fixture_bin/hostname" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' hub
EOF

cat > "$fixture_bin/tailscale" <<'EOF'
#!/usr/bin/env bash
printf 'tailscale %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
printf '%s\n' '{"Peer":{}}'
EOF

cat > "$fixture_bin/jq" <<'EOF'
#!/usr/bin/env bash
host=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = "--arg" ] && [ "${2:-}" = h ]; then
        host="${3:-}"
        break
    fi
    shift
done
case "$host" in
    remote-ok) printf '%s\n' 192.0.2.11 ;;
    remote-alias) printf '%s\n' 192.0.2.11 ;;
    remote-fail) printf '%s\n' 192.0.2.12 ;;
    offline)
        case "$*" in
            *'.Online == true'*) exit 4 ;;
            *) printf '%s\n' 192.0.2.31 ;;
        esac
        ;;
esac
EOF

cat > "$fixture_bin/podman" <<'EOF'
#!/usr/bin/env bash
printf 'podman %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
container_id=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
case "${1:-} ${2:-}" in
    "container exists")
        case "${ODYSSEUS_TEST_PODMAN_MODE:-absent}" in
            absent) exit 1 ;;
            probe-error) exit 125 ;;
            remove-success|remove-fail|wrong-run|wrong-mount|replacement-before-remove)
                [ -e "${ODYSSEUS_TEST_REMOVED_MARKER:?}" ] && exit 1
                exit 0
                ;;
            postcondition-fail) exit 0 ;;
        esac
        ;;
    "inspect alexnet-training")
        actual_run=test-run
        actual_results="$HOME/alexnet-results/runs/test-run/hub"
        case "${ODYSSEUS_TEST_PODMAN_MODE:-}" in
            wrong-run) actual_run=other-run ;;
            wrong-mount) actual_results="$HOME/alexnet-results/runs/other-run/hub" ;;
        esac
        printf '%s|%s|%s|%s\n' \
            "$container_id" alexnet-training "$actual_run" "$actual_results"
        exit 0
        ;;
    "inspect $container_id")
        if [ "${ODYSSEUS_TEST_PODMAN_MODE:-}" = replacement-before-remove ]; then
            exit 125
        fi
        printf '%s|%s|%s|%s\n' \
            "$container_id" alexnet-training test-run \
            "$HOME/alexnet-results/runs/test-run/hub"
        exit 0
        ;;
    "rm -f")
        [ "${ODYSSEUS_TEST_PODMAN_MODE:-}" != remove-fail ] || exit 9
        : > "${ODYSSEUS_TEST_REMOVED_MARKER:?}"
        exit 0
        ;;
esac
exit 98
EOF

cat > "$fixture_bin/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
if [ "${ODYSSEUS_TEST_BLOCK_WORKERS:-0}" = 1 ]; then
    trap '' INT TERM HUP
    ODYSSEUS_TEST_WORKER_LEADER=$$ python3 -c '
import os, signal, time
os.setsid()
child = os.fork()
if child:
    os.waitpid(child, 0)
else:
    for value in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
        signal.signal(value, signal.SIG_IGN)
    with open(os.environ["ODYSSEUS_TEST_WORKER_REGISTRY"], "a", encoding="ascii") as stream:
        stream.write("%s %s\n" % (os.environ["ODYSSEUS_TEST_WORKER_LEADER"], os.getpid()))
    while True:
        time.sleep(30)
' &
    descendant=$!
    wait "$descendant"
    exit 99
fi
remote_host=""
while [ "$#" -gt 0 ]; do
    case "$1" in
        -o) shift 2 ;;
        *) remote_host="$1"; break ;;
    esac
done
case "$remote_host" in
    192.0.2.11) printf '%s\n' removed; exit 0 ;;
    192.0.2.12) printf '%s\n' 'transport failed' >&2; exit 55 ;;
    *) exit 56 ;;
esac
EOF

cat > "$fixture_bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF

cat > "$fixture_bin/rm" <<'EOF'
#!/usr/bin/env bash
printf 'rm %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
target=${*: -1}
if [ -n "${ODYSSEUS_TEST_WORKER_REGISTRY:-}" ] \
        && [ -s "$ODYSSEUS_TEST_WORKER_REGISTRY" ] \
        && [[ "$target" == *odysseus-alexnet-teardown.* ]]; then
    while read -r leader descendant; do
        for worker_pid in "$leader" "$descendant"; do
            if /bin/kill -0 "$worker_pid" 2>/dev/null; then
                printf '%s\n' "$worker_pid" \
                    >> "${ODYSSEUS_TEST_CLEANUP_RACE_LOG:?}"
            fi
        done
    done < "$ODYSSEUS_TEST_WORKER_REGISTRY"
fi
if [ "${ODYSSEUS_TEST_RM_MODE:-ok}" = fail ] && [ "${1:-}" = -r ]; then
    exit 77
fi
exec /bin/rm "$@"
EOF

chmod +x "$fixture_bin"/*

run_teardown() {
    local case_name="$1"
    shift
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_REMOVED_MARKER="$fixture_root/$case_name.removed" \
    TMPDIR="$fixture_root" \
    HOME="$fixture_root/home" \
    ALEXNET_RUN_ID="${ODYSSEUS_TEST_RUN_ID_INPUT-test-run}" \
    PATH="$fixture_bin:/usr/bin:/bin" \
        "$@" bash "$ROOT/e2e/alexnet-fleet-teardown.sh" \
        > "$fixture_root/$case_name.out" 2>&1
}

signal_teardown() {
    local case_name=$1
    local signal_name=$2
    local registry="$fixture_root/$case_name.workers"
    local cleanup_race="$fixture_root/$case_name.cleanup-race"
    : > "$fixture_root/$case_name.effects"
    : > "$registry"
    : > "$cleanup_race"
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_REMOVED_MARKER="$fixture_root/$case_name.removed" \
    ODYSSEUS_TEST_WORKER_REGISTRY="$registry" \
    ODYSSEUS_TEST_CLEANUP_RACE_LOG="$cleanup_race" \
    TMPDIR="$fixture_root" \
    HOME="$fixture_root/home" \
    PATH="$fixture_bin:/usr/bin:/bin" \
        /usr/bin/python3 - "$ROOT/e2e/alexnet-fleet-teardown.sh" \
            "$signal_name" "$registry" "$fixture_root/$case_name.out" \
            "$fixture_root/odysseus-alexnet-teardown.*" <<'PY'
import glob
import os
import shutil
import signal
import subprocess
import sys
import time

script, signal_name, registry, output_path, cleanup_pattern = sys.argv[1:]
expect_retain = os.environ.get("ODYSSEUS_TEST_EXPECT_RETAIN") == "1"
existing_cleanup_paths = set(glob.glob(cleanup_pattern))
with open(output_path, "wb") as output:
    process = subprocess.Popen(
        ["/bin/bash", script],
        env=os.environ.copy(),
        stdout=output,
        stderr=subprocess.STDOUT,
        start_new_session=True,
    )
deadline = time.monotonic() + 8
while time.monotonic() < deadline:
    if os.path.exists(registry) and os.path.getsize(registry) > 0:
        break
    if process.poll() is not None:
        raise SystemExit(f"teardown exited before worker registration: {process.returncode}")
    time.sleep(0.05)
else:
    process.kill()
    process.wait()
    raise SystemExit("teardown did not register a worker")
os.kill(process.pid, getattr(signal, f"SIG{signal_name}"))
try:
    return_code = process.wait(timeout=30)
except subprocess.TimeoutExpired:
    os.killpg(process.pid, signal.SIGKILL)
    process.wait()
    raise SystemExit("teardown did not stop after the signal")
if return_code == 0:
    raise SystemExit("signalled teardown returned success")
worker_pids = []
leaders = []
with open(registry, encoding="utf-8") as workers:
    for line in workers:
        values = [int(value) for value in line.split()]
        if values:
            leaders.append(values[0])
            worker_pids.extend(values)
new_cleanup_paths = set(glob.glob(cleanup_pattern)) - existing_cleanup_paths
if expect_retain:
    if len(new_cleanup_paths) != 1:
        raise SystemExit(
            f"expected one retained receipt path, got {sorted(new_cleanup_paths)}"
        )
    for leader in leaders:
        try:
            os.killpg(leader, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for worker_pid in worker_pids:
        try:
            os.kill(worker_pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for cleanup_path in new_cleanup_paths:
        shutil.rmtree(cleanup_path)
    raise SystemExit(0)
for worker_pid in worker_pids:
    for _ in range(40):
        try:
            os.kill(worker_pid, 0)
        except ProcessLookupError:
            break
        time.sleep(0.05)
    else:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        for cleanup_pid in worker_pids:
            try:
                os.kill(cleanup_pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        raise SystemExit(f"teardown worker {worker_pid} survived shutdown")
if new_cleanup_paths:
    raise SystemExit(f"teardown left receipt paths: {sorted(new_cleanup_paths)}")
PY
}

kill_failure_env="$fixture_root/kill-failure.bash"
cat > "$kill_failure_env" <<'EOF'
kill() {
    if [ "${ODYSSEUS_TEST_FAIL_GROUP_KILL:-0}" = 1 ] \
            && [ "${1:-}" = -KILL ]; then
        return 77
    fi
    builtin kill "$@"
}
EOF

info "non-interactive teardown requires exact target approval"
if run_teardown unapproved env FLEET=localhost; then
    fail "unapproved teardown reported success"
elif [ -e "$fixture_root/unapproved.effects" ]; then
    fail "unapproved teardown reached a host or container command"
elif grep -Fq 'ALEXNET_TEARDOWN_APPROVED_FLEET' "$fixture_root/unapproved.out" \
     && ! grep -Fq 'FORCE=1' "$fixture_root/unapproved.out"; then
    pass "unapproved teardown stops before effects with an exact-approval route"
else
    fail "unapproved teardown recommends a broad bypass"
fi

if run_teardown approval-mismatch env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=remote-ok; then
    fail "mismatched target approval reported success"
elif [ -e "$fixture_root/approval-mismatch.effects" ]; then
    fail "mismatched target approval reached a host or container command"
else
    pass "approval must match the exact requested fleet"
fi

if ODYSSEUS_TEST_RUN_ID_INPUT='' run_teardown missing-run-approval env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=absent; then
    fail "teardown accepted mutation approval without an exact run ID"
elif [ -e "$fixture_root/missing-run-approval.effects" ]; then
    fail "missing run approval reached a target operation"
elif grep -Fq 'ALEXNET_RUN_ID' "$fixture_root/missing-run-approval.out"; then
    pass "teardown requires an exact run ID before target operations"
else
    fail "missing run approval omitted the exact ALEXNET_RUN_ID route"
fi

if ODYSSEUS_TEST_RUN_ID_INPUT=../other run_teardown invalid-run-approval env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=absent; then
    fail "teardown accepted an unsafe run ID"
elif [ -e "$fixture_root/invalid-run-approval.effects" ]; then
    fail "unsafe run approval reached a target operation"
else
    pass "teardown rejects an unsafe run ID before target operations"
fi

if run_teardown empty-workflow-fleet env \
    FLEET= FORCE=1 GITHUB_ACTIONS=true GITHUB_EVENT_NAME=workflow_dispatch; then
    fail "an explicitly empty protected-workflow fleet selected default targets"
elif [ -e "$fixture_root/empty-workflow-fleet.effects" ]; then
    fail "an explicitly empty protected-workflow fleet reached target discovery"
else
    pass "an explicitly empty fleet never expands to the default target set"
fi

if run_teardown spoofed-workflow env \
    FLEET=localhost FORCE=1 GITHUB_ACTIONS=true \
    GITHUB_EVENT_NAME=workflow_dispatch ODYSSEUS_TEST_PODMAN_MODE=absent; then
    fail "caller-controlled GitHub variables authorized teardown"
elif [ -e "$fixture_root/spoofed-workflow.effects" ]; then
    fail "spoofed workflow context reached a target operation"
elif grep -Fq 'ALEXNET_TEARDOWN_APPROVED_FLEET' \
    "$fixture_root/spoofed-workflow.out"; then
    pass "non-interactive teardown requires an exact-fleet approval value"
else
    fail "spoofed workflow context omitted the exact approval route"
fi

info "host resolution is complete before any container mutation"
if run_teardown unresolved env \
    FLEET="localhost unresolved" \
    ALEXNET_TEARDOWN_APPROVED_FLEET="localhost unresolved"; then
    fail "unresolved fleet reported successful teardown"
elif grep -q '^podman\|^ssh' "$fixture_root/unresolved.effects" 2>/dev/null; then
    fail "unresolved fleet performed a container mutation"
elif grep -Fq "cannot resolve" "$fixture_root/unresolved.out"; then
    pass "unresolved target stops the whole fleet before mutation"
else
    fail "unresolved target omitted its resolution failure"
fi

if run_teardown local-alias env \
    FLEET='hub localhost' \
    ALEXNET_TEARDOWN_APPROVED_FLEET='hub localhost'; then
    fail "two local aliases produced teardown success"
elif grep -q '^podman\|^ssh' "$fixture_root/local-alias.effects" 2>/dev/null; then
    fail "duplicate local aliases reached container mutation"
elif grep -Fq 'duplicate resolved target' "$fixture_root/local-alias.out"; then
    pass "duplicate local aliases stop before container mutation"
else
    fail "teardown did not identify the duplicate local target"
fi

if run_teardown peer-alias env \
    FLEET='remote-ok remote-alias' \
    ALEXNET_TEARDOWN_APPROVED_FLEET='remote-ok remote-alias'; then
    fail "two peer names for one address produced teardown success"
elif grep -q '^podman\|^ssh' "$fixture_root/peer-alias.effects" 2>/dev/null; then
    fail "duplicate peer addresses reached container mutation"
elif grep -Fq 'duplicate resolved target' "$fixture_root/peer-alias.out"; then
    pass "duplicate peer addresses stop before container mutation"
else
    fail "teardown did not identify the duplicate peer address"
fi

if run_teardown offline-peer env \
    FLEET=offline ALEXNET_TEARDOWN_APPROVED_FLEET=offline; then
    fail "offline peer produced teardown success"
elif grep -q '^podman\|^ssh' "$fixture_root/offline-peer.effects" 2>/dev/null; then
    fail "offline peer reached container mutation"
elif grep -Fq 'fleet resolution is incomplete' "$fixture_root/offline-peer.out"; then
    pass "offline peer stops complete teardown resolution before mutation"
else
    fail "teardown did not report the offline peer resolution failure"
fi

info "local container state and removal are verified"
if run_teardown absent env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=absent \
   && grep -Fq 'localhost: absent' "$fixture_root/absent.out" \
   && grep -Fq 'Teardown verified for 1 host' "$fixture_root/absent.out"; then
    pass "already-absent local container has a terminal receipt"
else
    fail "already-absent local container lacks verified completion"
fi

bound_container_id=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
if run_teardown remove-success env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=remove-success \
   && grep -Fxq "podman rm -f $bound_container_id" \
      "$fixture_root/remove-success.effects" \
   && ! grep -Fxq 'podman rm -f alexnet-training' \
      "$fixture_root/remove-success.effects"; then
    pass "teardown removes only the immutable container ID"
else
    fail "teardown did not bind removal to the immutable container ID"
fi

if run_teardown wrong-run env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=wrong-run; then
    fail "teardown removed a container from a different run"
elif grep -q '^podman rm ' "$fixture_root/wrong-run.effects"; then
    fail "wrong-run container reached the removal boundary"
elif grep -Fq 'run or result binding does not match' \
     "$fixture_root/wrong-run.out"; then
    pass "teardown preserves a container from a different run"
else
    fail "teardown did not identify the wrong-run container"
fi

if run_teardown wrong-mount env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=wrong-mount; then
    fail "teardown removed a container with a different result mount"
elif grep -q '^podman rm ' "$fixture_root/wrong-mount.effects"; then
    fail "wrong-mount container reached the removal boundary"
elif grep -Fq 'run or result binding does not match' \
     "$fixture_root/wrong-mount.out"; then
    pass "teardown preserves a container with a different result mount"
else
    fail "teardown did not identify the wrong result mount"
fi

if run_teardown replacement-before-remove env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=replacement-before-remove; then
    fail "teardown accepted a name replacement before removal"
elif grep -q '^podman rm ' \
     "$fixture_root/replacement-before-remove.effects"; then
    fail "teardown removed a replacement container"
elif grep -Fq 'container identity changed before removal' \
     "$fixture_root/replacement-before-remove.out"; then
    pass "teardown preserves a replacement container"
else
    fail "teardown did not identify the replacement race"
fi

if run_teardown probe-error env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=probe-error; then
    fail "container-state probe failure reported success"
elif grep -Fq 'Teardown verified' "$fixture_root/probe-error.out"; then
    fail "container-state probe failure emitted completion"
else
    pass "container-state probe failure remains a failure"
fi

if run_teardown remove-fail env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=remove-fail; then
    fail "failed local removal reported success"
elif grep -Fq 'Teardown verified' "$fixture_root/remove-fail.out"; then
    fail "failed local removal emitted completion"
else
    pass "failed local removal remains a failure"
fi

if run_teardown postcondition-fail env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=postcondition-fail; then
    fail "failed local postcondition reported success"
elif grep -Fq 'Teardown verified' "$fixture_root/postcondition-fail.out"; then
    fail "failed local postcondition emitted completion"
else
    pass "failed local postcondition remains a failure"
fi

cleanup_swap_env="$fixture_root/cleanup-swap.bash"
cat > "$cleanup_swap_env" <<'EOF'
set -T
swap_receipt_before_quarantine() {
    if [[ "${BASH_COMMAND:-}" == cleanup_receipts \
            && -n "${receipt_dir:-}" \
            && ! -e "${ODYSSEUS_TEST_CLEANUP_SWAP_DONE:?}" ]]; then
        trap - DEBUG
        /bin/mv -- "$receipt_dir" "${ODYSSEUS_TEST_CLEANUP_HELD:?}"
        /bin/mkdir -- "$receipt_dir"
        printf '%s\n' 'preserve cleanup replacement' > "$receipt_dir/sentinel.txt"
        : > "$ODYSSEUS_TEST_CLEANUP_SWAP_DONE"
    fi
}
trap swap_receipt_before_quarantine DEBUG
EOF
if run_teardown receipt-cleanup-fail env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    ODYSSEUS_TEST_PODMAN_MODE=absent BASH_ENV="$cleanup_swap_env" \
    ODYSSEUS_TEST_CLEANUP_SWAP_DONE="$fixture_root/cleanup-swap.done" \
    ODYSSEUS_TEST_CLEANUP_HELD="$fixture_root/cleanup-swap.held"; then
    fail "failed receipt cleanup reported success"
elif grep -Fq 'Teardown verified' "$fixture_root/receipt-cleanup-fail.out"; then
    fail "failed receipt cleanup emitted completion"
elif grep -Fq 'could not safely remove the bound local receipt directory' \
        "$fixture_root/receipt-cleanup-fail.out" \
     && grep -Fxq 'preserve cleanup replacement' \
        "$fixture_root"/odysseus-alexnet-teardown.*/sentinel.txt; then
    pass "final-syscall receipt replacement is preserved and withholds completion"
else
    fail "failed receipt cleanup was not reported"
fi

info "all background host results are collected before failure"
if run_teardown mixed-remote env \
    FLEET="localhost remote-ok remote-fail" \
    ALEXNET_TEARDOWN_APPROVED_FLEET="localhost remote-ok remote-fail" \
    ODYSSEUS_TEST_PODMAN_MODE=absent; then
    fail "one failed remote teardown produced fleet success"
elif [ ! -f "$fixture_root/mixed-remote.effects" ]; then
    fail "teardown launched no remote target jobs"
elif [ "$(grep -c '^ssh ' "$fixture_root/mixed-remote.effects")" -ne 2 ]; then
    fail "teardown did not wait for and inspect every remote target"
elif ! grep -Fq 'localhost: absent' "$fixture_root/mixed-remote.out" \
     || ! grep -Fq 'remote-ok: removed' "$fixture_root/mixed-remote.out" \
     || ! grep -Fq 'remote-fail: failed' "$fixture_root/mixed-remote.out"; then
    fail "teardown omitted one or more per-host receipts"
elif grep -Fq 'Teardown verified' "$fixture_root/mixed-remote.out"; then
    fail "partial remote failure emitted completion"
else
    pass "partial remote failure reports every host and withholds completion"
fi

info "teardown signals stop and reap workers before receipt cleanup"
for worker_signal in INT TERM HUP; do
    signal_case="teardown-signal-${worker_signal,,}"
    if FLEET=remote-ok ALEXNET_TEARDOWN_APPROVED_FLEET=remote-ok \
        ALEXNET_RUN_ID=test-run ODYSSEUS_TEST_BLOCK_WORKERS=1 \
        signal_teardown "$signal_case" "$worker_signal"; then
        if [ -s "$fixture_root/$signal_case.cleanup-race" ]; then
            fail "teardown $worker_signal cleanup ran before workers were reaped"
        else
            pass "teardown $worker_signal reaps workers before receipt cleanup"
        fi
    else
        fail "teardown $worker_signal left an owned worker or receipt directory"
    fi
done

post_reap_hook="$fixture_root/teardown-post-reap-signal.bash"
cat > "$post_reap_hook" <<'EOF'
set -T
kill() {
    if [[ " $* " == *' -- -'* ]]; then
        printf 'group-kill %s\n' "$*" \
            >> "${ODYSSEUS_TEST_POST_REAP_KILL_LOG:?}"
    fi
    builtin kill "$@"
}
post_reap_signal() {
    if [[ "${BASH_COMMAND:-}" == forget_worker_pid* \
            && ! -e "${ODYSSEUS_TEST_POST_REAP_SEEN:?}" ]]; then
        : > "$ODYSSEUS_TEST_POST_REAP_SEEN"
        trap - DEBUG
        handle_worker_signal TERM 143
    fi
}
trap post_reap_signal DEBUG
EOF
post_reap_seen="$fixture_root/teardown-post-reap-signal.seen"
post_reap_kills="$fixture_root/teardown-post-reap-signal.kills"
: > "$post_reap_kills"
if run_teardown teardown-post-reap-signal env \
    FLEET=remote-ok ALEXNET_TEARDOWN_APPROVED_FLEET=remote-ok \
    BASH_ENV="$post_reap_hook" \
    ODYSSEUS_TEST_POST_REAP_SEEN="$post_reap_seen" \
    ODYSSEUS_TEST_POST_REAP_KILL_LOG="$post_reap_kills"; then
    fail "post-reap teardown signal fixture unexpectedly completed"
elif [ ! -e "$post_reap_seen" ]; then
    fail "post-reap teardown signal fixture missed the wait/forget window"
elif [ -s "$post_reap_kills" ]; then
    fail "post-reap teardown signal targeted a stale worker process group"
elif grep -Fq 'received SIGTERM' \
       "$fixture_root/teardown-post-reap-signal.out"; then
    pass "post-reap teardown signal cannot target a stale worker PID or PGID"
else
    fail "post-reap teardown signal was not handled deterministically"
fi

if FLEET=remote-ok ALEXNET_TEARDOWN_APPROVED_FLEET=remote-ok \
    ALEXNET_RUN_ID=test-run ODYSSEUS_TEST_BLOCK_WORKERS=1 \
    ODYSSEUS_TEST_FAIL_GROUP_KILL=1 ODYSSEUS_TEST_EXPECT_RETAIN=1 \
    BASH_ENV="$kill_failure_env" \
    signal_teardown teardown-extinction-failure TERM; then
    if grep -Fq 'retained receipt directory' \
            "$fixture_root/teardown-extinction-failure.out" \
       && [ ! -s "$fixture_root/teardown-extinction-failure.cleanup-race" ]; then
        pass "teardown retains receipts when worker extinction cannot be verified"
    else
        fail "teardown omitted its retained-receipt evidence after failed extinction"
    fi
else
    fail "teardown deleted receipts after failed worker extinction"
fi

info "optional broad script deletion is unavailable"
if run_teardown clean-scripts env \
    FLEET=localhost ALEXNET_TEARDOWN_APPROVED_FLEET=localhost \
    CLEAN_SCRIPTS=1; then
    fail "unscoped helper-script deletion reported success"
elif [ -e "$fixture_root/clean-scripts.effects" ]; then
    fail "unscoped helper-script deletion reached a host command"
else
    pass "unscoped helper-script deletion stops before effects"
fi

info "protected workflow and script defaults select the same hosts"
workflow_fleet=$(awk '
    /^      fleet:$/ { in_fleet=1; next }
    in_fleet && /^        default:/ {
        value=$0
        sub(/^        default: *"?/, "", value)
        sub(/"?$/, "", value)
        print value
        exit
    }
' "$ROOT/.github/workflows/alexnet-mesh-smoke.yml")
default_mismatch=0
for script in \
    e2e/alexnet-deploy-fleet.sh \
    e2e/alexnet-fleet-wait.sh \
    e2e/alexnet-collect-results.sh \
    e2e/alexnet-fleet-teardown.sh \
    e2e/alexnet-mesh-chaos.sh; do
    if ! grep -Fq "FLEET=\"\${FLEET:-$workflow_fleet}\"" "$ROOT/$script"; then
        fail "$script default diverges from the protected workflow"
        default_mismatch=1
    fi
done
if [ "$default_mismatch" -eq 0 ] && [ -n "$workflow_fleet" ]; then
    pass "all executable defaults match the protected workflow host set"
fi

info "teardown cleanup and workers retain exact OS identities"
# shellcheck disable=SC2016
if ! grep -Fq 'quarantine_bound_tree' "$ROOT/e2e/alexnet-fleet-teardown.sh" \
   || grep -Fq 'rm -r -- "$receipt_dir"' "$ROOT/e2e/alexnet-fleet-teardown.sh"; then
    fail "teardown receipt cleanup is not exact-object quarantined"
else
    pass "teardown receipt cleanup quarantines its bound directory"
fi
# shellcheck disable=SC2016
if ! grep -Fq 'extinguish_worker_sentinel' \
        "$ROOT/e2e/alexnet-fleet-teardown.sh" \
   || grep -Fq 'kill -TERM -- "-$worker_pid"' \
        "$ROOT/e2e/alexnet-fleet-teardown.sh"; then
    fail "teardown workers are not descriptor-bound through full extinction"
else
    pass "teardown worker extinction is descriptor-bound"
fi

summary
exit_code
