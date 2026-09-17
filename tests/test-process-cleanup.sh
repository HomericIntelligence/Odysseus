#!/usr/bin/env bash
# Hermetic lifecycle tests for background-process cleanup.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
# shellcheck source=e2e/lib/process.sh
source "$ROOT/e2e/lib/process.sh"
# shellcheck source=e2e/lib/nats.sh
source "$ROOT/e2e/lib/nats.sh"
PRODUCTION_SIGNAL_BOUND_PROCESS=$(declare -f _signal_bound_process)
PRODUCTION_PROCESS_RECEIPT=$(declare -f _process_receipt)

TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
WAIT_LOG="$TMP/wait.log"
TEST_SHELL_PID="${BASHPID:-$$}"

reset_process_state() {
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    if [ -n "${PROCESS_RECEIPT_STORAGE_RECEIPT:-}" ]; then
        _persist_process_receipts >/dev/null 2>&1 || :
        _remove_process_receipt_store >/dev/null 2>&1 || :
    elif [ -n "${PROCESS_RECEIPT_DIR:-}" ]; then
        case "$PROCESS_RECEIPT_DIR" in
            /tmp/hi-process-receipts.*|/private/tmp/hi-process-receipts.*)
                rm -f -- "${PROCESS_RECEIPT_FILE:-}"
                rmdir -- "$PROCESS_RECEIPT_DIR" 2>/dev/null || :
                ;;
        esac
    fi
    PROCESS_RECEIPT_DIR=""
    PROCESS_RECEIPT_FILE=""
    PROCESS_RECEIPT_STORAGE_RECEIPT=""
}

sleep() { return 0; }
wait() {
    printf '%s\n' "$*" >> "$WAIT_LOG"
    return 0
}

info "empty process inventory permits storage cleanup"
NATS_DATA_DIR="$TMP/hi-nats-EMP001"
empty_data_dir="$NATS_DATA_DIR"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
cleanup_all
cleanup_status=$?
if [ "$cleanup_status" -eq 0 ] \
    && [ "${#_BG_PIDS[@]}" -eq 0 ] \
    && [ ! -d "$empty_data_dir" ]; then
    pass "an empty receipt set remains an idempotent cleanup"
else
    fail "empty process cleanup synthesized a live receipt or retained storage"
fi

info "failed signals preserve live-process and storage receipts"
MOCK_PROCESS_ALIVE=1
MOCK_PROCESS_IDENTITY=boot-a:101
_process_receipt() {
    [ "$MOCK_PROCESS_ALIVE" -eq 1 ] || return 1
    printf '%s|%s\n' "$MOCK_PROCESS_IDENTITY" "$TEST_SHELL_PID"
}
kill() {
    case "${1:-}" in
        -0) [ "$MOCK_PROCESS_ALIVE" -eq 1 ] ;;
        -TERM|-KILL) return 1 ;;
        *) return 2 ;;
    esac
}
_signal_bound_process() { return 2; }
NATS_DATA_DIR="$TMP/hi-nats-FAL001"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
_BG_PIDS=(4242)
_BG_PID_IDENTITIES=("$MOCK_PROCESS_IDENTITY")
_BG_PID_OWNERS=("${BASHPID:-$$}")
: > "$WAIT_LOG"
cleanup_all
cleanup_status=$?
if [ "$cleanup_status" -ne 0 ] \
    && [ "${_BG_PIDS[*]}" = 4242 ] \
    && [ -d "$NATS_DATA_DIR" ] \
    && [ ! -s "$WAIT_LOG" ]; then
    pass "a still-live process blocks receipt and storage cleanup"
else
    fail "cleanup concealed a live process or discarded its recovery state"
fi
rm -rf -- "$NATS_DATA_DIR"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state
eval "$PRODUCTION_SIGNAL_BOUND_PROCESS"

info "proven process extinction permits receipt and storage cleanup"
MOCK_PROCESS_ALIVE=1
MOCK_PROCESS_IDENTITY=boot-a:202
_process_receipt() {
    [ "$MOCK_PROCESS_ALIVE" -eq 1 ] || return 1
    printf '%s|%s\n' "$MOCK_PROCESS_IDENTITY" "$TEST_SHELL_PID"
}
kill() {
    case "${1:-}" in
        -0) [ "$MOCK_PROCESS_ALIVE" -eq 1 ] ;;
        -TERM)
            MOCK_PROCESS_ALIVE=0
            return 0
            ;;
        -KILL)
            MOCK_PROCESS_ALIVE=0
            return 0
            ;;
        *) return 2 ;;
    esac
}
_signal_bound_process() {
    MOCK_PROCESS_ALIVE=0
    return 0
}
NATS_DATA_DIR="$TMP/hi-nats-STP001"
stopped_data_dir="$NATS_DATA_DIR"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
_BG_PIDS=(4343)
_BG_PID_IDENTITIES=("$MOCK_PROCESS_IDENTITY")
_BG_PID_OWNERS=("${BASHPID:-$$}")
: > "$WAIT_LOG"
cleanup_all
cleanup_status=$?
if [ "$cleanup_status" -eq 0 ] \
    && [ "${#_BG_PIDS[@]}" -eq 0 ] \
    && [ ! -d "$stopped_data_dir" ] \
    && grep -Fxq 4343 "$WAIT_LOG"; then
    pass "extinction is proved before cleanup state is discarded"
else
    fail "successful termination did not complete its verified cleanup"
fi
reset_process_state
eval "$PRODUCTION_SIGNAL_BOUND_PROCESS"

info "registration requires an immutable receipt for a direct child"
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
_process_receipt() {
    printf '%s|%s\n' boot-a:303 99999
}
if register_pid 4444 >/dev/null 2>&1; then
    fail "a non-child process received cleanup authority"
elif [ "${#_BG_PIDS[@]}" -eq 0 ]; then
    pass "non-child process registration fails closed"
else
    fail "failed direct-child verification still left a cleanup receipt"
fi

info "registration sync failure still retires the validated child"
registration_pid_file="$TMP/registration-sync-child.pid"
registration_signal_log="$TMP/registration-sync-signal.log"
: > "$registration_signal_log"
if (
    eval "$PRODUCTION_PROCESS_RECEIPT"
    _sync_process_receipts() { return 1; }
    _wait_for_nats_ports_free() { return 0; }
    _resolve_bound_nats_data_dir() { return 0; }
    _exec_nats_with_bound_store() {
        printf '%s\n' "${BASHPID:-$$}" > "$registration_pid_file"
        trap '' TERM
        while :; do /bin/sleep 1; done
    }
    _signal_bound_process() {
        printf '%s\n' "$*" >> "$registration_signal_log"
        /bin/kill "$4" "$1"
    }
    NATS_PORT=42001
    NATS_MONITOR_PORT=42002
    if _start_nats_guarded /bin/true 1; then
        exit 10
    fi
    child_pid=$(cat "$registration_pid_file") || exit 11
    if /bin/kill -0 "$child_pid" 2>/dev/null; then
        exit 12
    fi
    grep -Eq -- '-TERM|-KILL' "$registration_signal_log" || exit 13
); then
    pass "validated identity is available for bounded registration rollback"
else
    if [ -s "$registration_pid_file" ]; then
        rollback_pid=$(cat "$registration_pid_file")
        /bin/kill -KILL "$rollback_pid" 2>/dev/null || :
    fi
    fail "receipt sync failure leaked or waited indefinitely on its child"
fi

info "process receipt publication ignores mutable storage variables"
_ensure_process_receipt_store
bound_receipt_dir="$PROCESS_RECEIPT_DIR"
bound_receipt_file="$PROCESS_RECEIPT_FILE"
protected_receipt_dir="$TMP/protected-process-receipts"
protected_receipt_file="$protected_receipt_dir/operator-data"
mkdir -m 700 "$protected_receipt_dir"
printf '%s\n' preserve > "$protected_receipt_file"
PROCESS_RECEIPT_DIR="$protected_receipt_dir"
PROCESS_RECEIPT_FILE="$protected_receipt_file"
_BG_PIDS=(4488)
_BG_PID_IDENTITIES=(boot-a:4488)
_BG_PID_OWNERS=("${BASHPID:-$$}")
if _persist_process_receipts \
    && grep -Fxq preserve "$protected_receipt_file"; then
    pass "receipt publication cannot overwrite a retargeted regular file"
else
    fail "mutable receipt storage redirected publication to operator data"
fi
PROCESS_RECEIPT_DIR="$bound_receipt_dir"
PROCESS_RECEIPT_FILE="$bound_receipt_file"
reset_process_state

info "process receipt cleanup ignores mutable storage variables"
printf '%s\n' preserve > "$protected_receipt_file"
_ensure_process_receipt_store
bound_receipt_dir="$PROCESS_RECEIPT_DIR"
bound_receipt_file="$PROCESS_RECEIPT_FILE"
PROCESS_RECEIPT_DIR="$protected_receipt_dir"
PROCESS_RECEIPT_FILE="$protected_receipt_file"
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
if cleanup_all \
    && [ ! -e "$bound_receipt_dir" ] \
    && grep -Fxq preserve "$protected_receipt_file"; then
    pass "receipt cleanup removes only its bound storage object"
else
    fail "mutable receipt storage blocked cleanup or touched operator data"
fi
if [ -e "$bound_receipt_dir" ]; then
    PROCESS_RECEIPT_DIR="$bound_receipt_dir"
    PROCESS_RECEIPT_FILE="$bound_receipt_file"
    reset_process_state
fi
PROCESS_RECEIPT_DIR=""
PROCESS_RECEIPT_FILE=""

info "same-name process receipt replacement is preserved and fails closed"
_ensure_process_receipt_store
bound_receipt_dir="$PROCESS_RECEIPT_DIR"
bound_receipt_file="$PROCESS_RECEIPT_FILE"
displaced_receipt_dir="$bound_receipt_dir.displaced"
mv -- "$bound_receipt_dir" "$displaced_receipt_dir"
mkdir -m 700 -- "$bound_receipt_dir"
(umask 077 && printf '%s\n' preserve > "$bound_receipt_file")
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
if cleanup_all >/dev/null 2>&1; then
    fail "same-name replacement process storage reported successful cleanup"
elif grep -Fxq preserve "$bound_receipt_file" \
    && [ -f "$displaced_receipt_dir/receipts" ]; then
    pass "receipt cleanup preserves an unbound same-name replacement"
else
    fail "receipt cleanup mutated replacement or discarded bound evidence"
fi
rm -f -- "$bound_receipt_file"
rmdir -- "$bound_receipt_dir"
mv -- "$displaced_receipt_dir" "$bound_receipt_dir"
_persist_process_receipts
_remove_process_receipt_store

info "process receipt cleanup quarantines its exact object before removal"
_ensure_process_receipt_store
bound_receipt_dir="$PROCESS_RECEIPT_DIR"
bound_receipt_file="$PROCESS_RECEIPT_FILE"
receipt_parent="${bound_receipt_dir%/*}"
receipt_name="${bound_receipt_dir##*/}"
lock_ready="$TMP/receipt-lock.ready"
lock_release="$TMP/receipt-lock.release"
receipt_cleanup_status="$TMP/receipt-cleanup.status"
python3 - "$bound_receipt_file" "$lock_ready" "$lock_release" <<'PY' &
import fcntl
import pathlib
import sys
import time

with open(sys.argv[1], "r+b") as stream:
    fcntl.flock(stream, fcntl.LOCK_EX)
    pathlib.Path(sys.argv[2]).touch()
    while not pathlib.Path(sys.argv[3]).exists():
        time.sleep(0.01)
PY
receipt_locker_pid=$!
for _ in $(seq 1 100); do
    [ -e "$lock_ready" ] && break
    /bin/sleep 0.01
done
(
    if _remove_process_receipt_store >/dev/null 2>&1; then
        printf '0\n' > "$receipt_cleanup_status"
    else
        printf '%s\n' "$?" > "$receipt_cleanup_status"
    fi
) &
receipt_cleaner_pid=$!
receipt_quarantine_seen=0
for _ in $(seq 1 100); do
    if compgen -G "$receipt_parent/.$receipt_name.cleanup-*" >/dev/null; then
        receipt_quarantine_seen=1
        break
    fi
    /bin/sleep 0.01
done
if [ "$receipt_quarantine_seen" -eq 1 ]; then
    mkdir -m 700 -- "$bound_receipt_dir"
    (umask 077 && printf '%s\n' preserve > "$bound_receipt_file")
fi
touch "$lock_release"
builtin wait "$receipt_cleaner_pid" 2>/dev/null || :
builtin wait "$receipt_locker_pid" 2>/dev/null || :
if [ "$receipt_quarantine_seen" -eq 1 ] \
    && [ "$(cat "$receipt_cleanup_status")" -ne 0 ] \
    && grep -Fxq preserve "$bound_receipt_file" \
    && compgen -G "$receipt_parent/.$receipt_name.cleanup-*" >/dev/null; then
    pass "receipt replacement and quarantined evidence survive the removal race"
else
    fail "receipt final removal raced through an unbound same-name object"
fi
rm -f -- "$bound_receipt_file"
rmdir -- "$bound_receipt_dir" 2>/dev/null || :
for receipt_quarantine in "$receipt_parent/.$receipt_name.cleanup-"*; do
    [ -e "$receipt_quarantine" ] || continue
    rm -rf -- "$receipt_quarantine"
done
PROCESS_RECEIPT_DIR=""
PROCESS_RECEIPT_FILE=""
PROCESS_RECEIPT_STORAGE_RECEIPT=""

if [ "$(uname -s)" = Darwin ]; then
    info "Darwin receipts use a high-resolution kernel start token"
    eval "$PRODUCTION_PROCESS_RECEIPT"
    darwin_receipt=$(_process_receipt "${BASHPID:-$$}")
    darwin_identity="${darwin_receipt%%|*}"
    if [[ "$darwin_identity" =~ ^darwin:[0-9]+:[0-9]+$ ]]; then
        pass "Darwin identity includes kernel seconds and microseconds"
    else
        fail "Darwin identity still depends on collision-prone ps lstart"
    fi

    info "Darwin signalling fails closed without an OS-bound process handle"
    /bin/sleep 30 &
    darwin_signal_pid=$!
    darwin_signal_receipt=$(_process_receipt "$darwin_signal_pid")
    darwin_signal_identity="${darwin_signal_receipt%%|*}"
    darwin_signal_owner="${darwin_signal_receipt#*|}"
    if _signal_bound_process "$darwin_signal_pid" "$darwin_signal_identity" \
        "$darwin_signal_owner" -TERM; then
        darwin_signal_status=0
    else
        darwin_signal_status=$?
    fi
    if [ "$darwin_signal_status" -ne 0 ] \
        && /bin/kill -0 "$darwin_signal_pid" 2>/dev/null; then
        pass "Darwin never signals through a check-then-kill PID race"
    else
        fail "Darwin signalled without an identity-bound kernel handle"
    fi
    /bin/kill -KILL "$darwin_signal_pid" 2>/dev/null || :
    builtin wait "$darwin_signal_pid" 2>/dev/null || :
fi

info "a reused PID never redirects cleanup to the replacement process"
SIGNAL_LOG="$TMP/signal.log"
: > "$SIGNAL_LOG"
MOCK_PROCESS_ALIVE=1
MOCK_PROCESS_IDENTITY=boot-a:replacement
_process_receipt() {
    [ "$MOCK_PROCESS_ALIVE" -eq 1 ] || return 1
    printf '%s|%s\n' "$MOCK_PROCESS_IDENTITY" "$TEST_SHELL_PID"
}
kill() {
    printf '%s\n' "$*" >> "$SIGNAL_LOG"
    return 0
}
_BG_PIDS=(4545)
_BG_PID_IDENTITIES=(boot-a:original)
_BG_PID_OWNERS=("${BASHPID:-$$}")
cleanup_pids
cleanup_status=$?
if [ "$cleanup_status" -eq 0 ] \
    && [ "${#_BG_PIDS[@]}" -eq 0 ] \
    && [ ! -s "$SIGNAL_LOG" ]; then
    pass "identity mismatch retires only the stale receipt"
else
    fail "cleanup signalled a different process that reused a registered PID"
fi
reset_process_state

info "identity change between validation and signal cannot reach a reused PID"
RACE_SIGNAL_LOG="$TMP/race-signal.log"
: > "$RACE_SIGNAL_LOG"
if (
    _process_identity_status() { return 0; }
    _signal_bound_process() { return 1; }
    kill() {
        printf '%s\n' "$*" >> "$RACE_SIGNAL_LOG"
        return 0
    }
    _kill_if_alive 4575 boot-a:original -TERM
) \
    && [ ! -s "$RACE_SIGNAL_LOG" ]; then
    pass "a bound signal helper closes the identity-check race"
else
    fail "cleanup signalled after the bound identity changed"
fi

info "NATS kill still requires monitor extinction for a stale process identity"
STALE_KILL_LOG="$TMP/stale-nats-kill.log"
: > "$STALE_KILL_LOG"
if (
    _process_identity_status() { return 1; }
    nats_health() { return 0; }
    kill() {
        printf '%s\n' "$*" >> "$STALE_KILL_LOG"
        return 0
    }
    IPC_TOPOLOGY=t1
    NATS_BG_PID=4595
    NATS_BG_IDENTITY=boot-a:stale-nats
    NATS_BG_OWNER="$TEST_SHELL_PID"
    nats_kill
); then
    fail "a stale PID receipt concealed a still-live NATS monitor"
elif [ ! -s "$STALE_KILL_LOG" ]; then
    pass "stale PID identity is not signalled and cannot prove monitor extinction"
else
    fail "NATS kill signalled a process after its identity changed"
fi

start_stalled_monitor() {
    local port_file="$1"
    python3 - "$port_file" <<'PY' &
import pathlib
import socket
import sys
import time

listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind(("127.0.0.1", 0))
listener.listen(1)
pathlib.Path(sys.argv[1]).write_text(
    str(listener.getsockname()[1]), encoding="ascii"
)
connection, _ = listener.accept()
time.sleep(3)
connection.close()
listener.close()
PY
    STALLED_MONITOR_PID=$!
    for _ in $(seq 1 100); do
        [ -s "$port_file" ] && return 0
        /bin/sleep 0.01
    done
    return 1
}

info "NATS health probes honor their bounded request deadline"
stalled_health_port_file="$TMP/stalled-health.port"
if start_stalled_monitor "$stalled_health_port_file"; then
    stalled_health_port=$(cat "$stalled_health_port_file")
    stalled_started=$SECONDS
    if _nats_health_for_port "$stalled_health_port" 1; then
        stalled_health_status=0
    else
        stalled_health_status=$?
    fi
    stalled_elapsed=$((SECONDS - stalled_started))
    builtin wait "$STALLED_MONITOR_PID" 2>/dev/null || :
    if [ "$stalled_health_status" -ne 0 ] \
        && [ "$stalled_elapsed" -le 2 ]; then
        pass "stalled health response cannot exceed its remaining deadline"
    else
        fail "health probe waited past its caller deadline"
    fi
else
    fail "could not create the stalled health fixture"
fi

info "NATS varz probes honor their bounded request deadline"
stalled_varz_port_file="$TMP/stalled-varz.port"
if start_stalled_monitor "$stalled_varz_port_file"; then
    stalled_varz_port=$(cat "$stalled_varz_port_file")
    stalled_started=$SECONDS
    if _nats_monitor_identity_for_port "$stalled_varz_port" 1; then
        stalled_varz_status=0
    else
        stalled_varz_status=$?
    fi
    stalled_elapsed=$((SECONDS - stalled_started))
    builtin wait "$STALLED_MONITOR_PID" 2>/dev/null || :
    if [ "$stalled_varz_status" -ne 0 ] \
        && [ "$stalled_elapsed" -le 2 ]; then
        pass "stalled varz response cannot exceed its remaining deadline"
    else
        fail "varz probe waited past its caller deadline"
    fi
else
    fail "could not create the stalled varz fixture"
fi

info "NATS restart unregisters the old identity before registering replacement"
fake_nats="$TMP/fake-nats"
cat > "$fake_nats" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${BASHPID:-$$}" > "${NATS_EXEC_PID_FILE:?}"
exec /bin/sleep 30
SH
chmod +x "$fake_nats"
NATS_EXEC_PID_FILE="$TMP/nats-exec.pid"
export NATS_EXEC_PID_FILE
_BG_PIDS=(4646)
_BG_PID_IDENTITIES=(boot-a:old-nats)
_BG_PID_OWNERS=("${BASHPID:-$$}")
_process_receipt() {
    printf 'boot-a:%s|%s\n' "$1" "$TEST_SHELL_PID"
}
nats_wait_healthy() { return 0; }
_nats_health_for_port() {
    local _
    for _ in $(seq 1 100); do
        [ -s "$NATS_EXEC_PID_FILE" ] && return 0
        /bin/sleep 0.01
    done
    return 1
}
_nats_monitor_identity_for_port() {
    printf '%s\n' "$NATS_BG_SERVER_NAME"
}
_nats_monitor_owned_by_process() { return 0; }
NATS_BG_PID=4646
NATS_BG_IDENTITY=boot-a:old-nats
NATS_BIN="$fake_nats"
NATS_PORT=1
NATS_MONITOR_PORT=2
IPC_TOPOLOGY=t1
NATS_DATA_DIR="$TMP/hi-nats-RST001"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
if nats_restart; then
    replacement_pid="$NATS_BG_PID"
    if [ "${#_BG_PIDS[@]}" -eq 1 ] \
        && [ "${_BG_PIDS[0]}" = "$replacement_pid" ] \
        && [ "${_BG_PID_IDENTITIES[0]}" = "boot-a:$replacement_pid" ] \
        && [ "$NATS_BG_IDENTITY" = "boot-a:$replacement_pid" ] \
        && [ "$(cat "$NATS_EXEC_PID_FILE")" = "$replacement_pid" ]; then
        pass "restart replaces rather than accumulates its process receipt"
    else
        fail "restart retained a wrapper or stale NATS PID receipt"
    fi
    /bin/kill -KILL "$replacement_pid" 2>/dev/null || :
    builtin wait "$replacement_pid" 2>/dev/null || :
else
    fail "NATS restart could not register its direct replacement child"
fi
unset NATS_EXEC_PID_FILE
_remove_bound_nats_data_dir
reset_process_state

info "NATS restart refuses a mutable storage-path retarget before launch"
restart_effect="$TMP/nats-restart.effect"
fake_effect_nats="$TMP/fake-effect-nats"
cat > "$fake_effect_nats" <<'SH'
#!/usr/bin/env bash
: > "${NATS_RESTART_EFFECT:?}"
exec /bin/sleep 30
SH
chmod +x "$fake_effect_nats"
nats_wait_healthy() {
    local _
    for _ in $(seq 1 100); do
        [ -e "${NATS_RESTART_EFFECT:?}" ] && return 0
        /bin/sleep 0.01
    done
    return 1
}

info "initial NATS start rejects an occupied monitor port before launch"
initial_bin_dir="$TMP/initial-bin"
mkdir -p "$initial_bin_dir"
cp "$fake_effect_nats" "$initial_bin_dir/nats-server"
initial_occupied_effect="$TMP/initial-occupied.effect"
if (
    PATH="$initial_bin_dir:$PATH"
    NATS_PORT=41101
    NATS_MONITOR_PORT=41102
    NATS_RESTART_EFFECT="$initial_occupied_effect"
    export PATH NATS_RESTART_EFFECT
    initial_shell_pid="${BASHPID:-$$}"
    _nats_port_is_open() { [ "$1" = "$NATS_MONITOR_PORT" ]; }
    wait_for() { return 0; }
    _process_receipt() {
        /bin/kill -0 "$1" 2>/dev/null || return 1
        printf 'boot-a:%s|%s\n' "$1" "$initial_shell_pid"
    }
    if start_nats_bg; then
        start_status=0
    else
        start_status=$?
    fi
    if [ -n "${NATS_BG_PID:-}" ]; then
        /bin/kill -KILL "$NATS_BG_PID" 2>/dev/null || :
        builtin wait "$NATS_BG_PID" 2>/dev/null || :
    fi
    cleanup_all >/dev/null 2>&1 || :
    exit "$start_status"
); then
    fail "initial start accepted an occupied monitor port"
elif [ ! -e "$initial_occupied_effect" ]; then
    pass "initial start reaches no launch while either port is occupied"
else
    fail "initial port rejection happened only after launching NATS"
fi

info "initial NATS health must belong to the exact registered child"
initial_foreign_effect="$TMP/initial-foreign.effect"
if (
    PATH="$initial_bin_dir:$PATH"
    NATS_PORT=41103
    NATS_MONITOR_PORT=41104
    NATS_RESTART_EFFECT="$initial_foreign_effect"
    export PATH NATS_RESTART_EFFECT
    initial_shell_pid="${BASHPID:-$$}"
    _nats_port_is_open() { return 1; }
    wait_for() { return 0; }
    _nats_health_for_port() { return 0; }
    _nats_monitor_identity_for_port() {
        printf '%s\n' "$NATS_BG_SERVER_NAME"
    }
    _nats_monitor_owned_by_process() { return 1; }
    _process_receipt() {
        /bin/kill -0 "$1" 2>/dev/null || return 1
        printf 'boot-a:%s|%s\n' "$1" "$initial_shell_pid"
    }
    if start_nats_bg; then
        start_status=0
    else
        start_status=$?
    fi
    if [ -n "${NATS_BG_PID:-}" ]; then
        /bin/kill -KILL "$NATS_BG_PID" 2>/dev/null || :
        builtin wait "$NATS_BG_PID" 2>/dev/null || :
    fi
    cleanup_all >/dev/null 2>&1 || :
    exit "$start_status"
); then
    fail "initial start accepted a replayed identity from a foreign monitor"
else
    pass "foreign monitor ownership cannot certify initial NATS startup"
fi

bound_nats_dir="$TMP/hi-nats-RET001"
foreign_nats_dir="$TMP/operator-restart-data"
mkdir -m 700 "$bound_nats_dir" "$foreign_nats_dir"
NATS_DATA_DIR="$bound_nats_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
NATS_DATA_DIR="$foreign_nats_dir"
NATS_BG_PID=""
NATS_BG_IDENTITY=""
NATS_BIN="$fake_effect_nats"
NATS_RESTART_EFFECT="$restart_effect"
export NATS_RESTART_EFFECT
if nats_restart; then
    replacement_pid="$NATS_BG_PID"
    /bin/sleep 0.05
    /bin/kill -KILL "$replacement_pid" 2>/dev/null || :
    builtin wait "$replacement_pid" 2>/dev/null || :
    fail "restart launched after its receipt-bound storage path was retargeted"
elif [ ! -e "$restart_effect" ]; then
    pass "storage retargeting reaches no NATS launch effect"
else
    fail "restart detected retargeting only after launching NATS"
fi
_remove_bound_nats_data_dir
rm -rf -- "$foreign_nats_dir"
reset_process_state

info "NATS restart keeps the receipt-bound directory authoritative after exec"
fake_swap_nats="$TMP/fake-swap-nats"
cat > "$fake_swap_nats" <<'SH'
#!/usr/bin/env bash
store_dir=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --store_dir ]; then
        store_dir="$2"
        shift 2
    else
        shift
    fi
done
mv -- "${ORIGINAL_NATS_STORE:?}" "${ORIGINAL_NATS_STORE}.displaced"
mkdir -m 700 -- "$ORIGINAL_NATS_STORE"
printf '%s\n' bound-write > "${store_dir:?}/runtime-effect"
exec /bin/sleep 30
SH
chmod +x "$fake_swap_nats"
swap_store="$TMP/hi-nats-SWP001"
mkdir -m 700 "$swap_store"
NATS_DATA_DIR="$swap_store"
_bind_nats_data_dir "$NATS_DATA_DIR"
ORIGINAL_NATS_STORE="$NATS_DATA_DIR"
export ORIGINAL_NATS_STORE
NATS_BG_PID=""
NATS_BG_IDENTITY=""
NATS_BIN="$fake_swap_nats"
NATS_PORT=41005
NATS_MONITOR_PORT=41006
MOCK_OCCUPIED_PORT=""
_process_receipt() {
    /bin/kill -0 "$1" 2>/dev/null || return 1
    printf 'boot-a:%s|%s\n' "$1" "$TEST_SHELL_PID"
}
nats_wait_healthy() {
    local _
    for _ in $(seq 1 100); do
        [ -e "$ORIGINAL_NATS_STORE/runtime-effect" ] \
            || [ -e "$ORIGINAL_NATS_STORE.displaced/runtime-effect" ] \
            && return 0
        /bin/sleep 0.01
    done
    return 1
}
_nats_health_for_port() { nats_wait_healthy; }
_nats_monitor_identity_for_port() {
    printf '%s\n' "$NATS_BG_SERVER_NAME"
}
if nats_restart; then
    swap_status=0
else
    swap_status=$?
fi
swap_pid="${NATS_BG_PID:-}"
if [ -n "$swap_pid" ]; then
    /bin/kill -KILL "$swap_pid" 2>/dev/null || :
    builtin wait "$swap_pid" 2>/dev/null || :
fi
if [ "$swap_status" -eq 0 ] \
    && [ -f "$ORIGINAL_NATS_STORE.displaced/runtime-effect" ] \
    && [ ! -e "$ORIGINAL_NATS_STORE/runtime-effect" ]; then
    pass "runtime storage writes stay on the receipt-bound directory object"
else
    fail "post-validation name swap redirected NATS runtime storage"
fi
rm -rf -- "$ORIGINAL_NATS_STORE" "$ORIGINAL_NATS_STORE.displaced"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state

info "NATS restart requires both configured ports to be unoccupied"
MOCK_OCCUPIED_PORT=""
_nats_port_is_open() {
    [ -n "$MOCK_OCCUPIED_PORT" ] && [ "$1" = "$MOCK_OCCUPIED_PORT" ]
}
assert_restart_rejects_occupied_port() {
    local case_name="$1" occupied_kind="$2" suffix="$3"
    local bound_dir="$TMP/hi-nats-$suffix"
    local effect_file="$TMP/$case_name.effect"
    local replacement_pid=""
    mkdir -m 700 "$bound_dir"
    NATS_DATA_DIR="$bound_dir"
    _bind_nats_data_dir "$NATS_DATA_DIR"
    NATS_BG_PID=""
    NATS_BG_IDENTITY=""
    NATS_BIN="$fake_effect_nats"
    NATS_PORT=41001
    NATS_MONITOR_PORT=41002
    if [ "$occupied_kind" = client ]; then
        MOCK_OCCUPIED_PORT="$NATS_PORT"
    else
        MOCK_OCCUPIED_PORT="$NATS_MONITOR_PORT"
    fi
    NATS_RESTART_EFFECT="$effect_file"
    export NATS_RESTART_EFFECT
    if nats_restart; then
        replacement_pid="$NATS_BG_PID"
    fi
    /bin/sleep 0.05
    if [ -n "$replacement_pid" ]; then
        /bin/kill -KILL "$replacement_pid" 2>/dev/null || :
        builtin wait "$replacement_pid" 2>/dev/null || :
    fi
    if [ ! -e "$effect_file" ]; then
        pass "$case_name blocks launch while the $occupied_kind port is occupied"
    else
        fail "$case_name launched NATS while the $occupied_kind port was occupied"
    fi
    MOCK_OCCUPIED_PORT=""
    _remove_bound_nats_data_dir
    reset_process_state
}
assert_restart_rejects_occupied_port occupied-client-port client PRT001
assert_restart_rejects_occupied_port occupied-monitor-port monitor PRT002

info "NATS restart health must belong to the registered replacement identity"
correlated_effect="$TMP/correlated-health.effect"
correlated_dir="$TMP/hi-nats-HLT001"
mkdir -m 700 "$correlated_dir"
NATS_DATA_DIR="$correlated_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
NATS_BG_PID=""
NATS_BG_IDENTITY=""
NATS_BIN="$fake_effect_nats"
NATS_PORT=41003
NATS_MONITOR_PORT=41004
MOCK_OCCUPIED_PORT=""
MOCK_REPLACEMENT_IDENTITY=""
_process_receipt() {
    printf '%s|%s\n' \
        "${MOCK_REPLACEMENT_IDENTITY:-boot-a:$1}" "$TEST_SHELL_PID"
}
nats_wait_healthy() {
    MOCK_REPLACEMENT_IDENTITY=boot-a:foreign-health
    return 0
}
_nats_health_for_port() {
    MOCK_REPLACEMENT_IDENTITY=boot-a:foreign-health
    return 0
}
_nats_monitor_identity_for_port() {
    printf '%s\n' "$NATS_BG_SERVER_NAME"
}
NATS_RESTART_EFFECT="$correlated_effect"
export NATS_RESTART_EFFECT
if nats_restart; then
    correlated_status=0
else
    correlated_status=$?
fi
correlated_pid="${NATS_BG_PID:-}"
if [ -n "$correlated_pid" ]; then
    /bin/kill -KILL "$correlated_pid" 2>/dev/null || :
    builtin wait "$correlated_pid" 2>/dev/null || :
fi
if [ "$correlated_status" -ne 0 ]; then
    pass "foreign health cannot certify a changed replacement identity"
else
    fail "restart accepted health after its registered process identity changed"
fi
_remove_bound_nats_data_dir
reset_process_state

info "NATS restart rejects a concurrent foreign monitor that replays identity"
foreign_health_dir="$TMP/hi-nats-FGN001"
mkdir -m 700 "$foreign_health_dir"
NATS_DATA_DIR="$foreign_health_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
NATS_BG_PID=""
NATS_BG_IDENTITY=""
NATS_BIN="$fake_effect_nats"
NATS_PORT=41007
NATS_MONITOR_PORT=41008
MOCK_OCCUPIED_PORT=""
_process_receipt() {
    /bin/kill -0 "$1" 2>/dev/null || return 1
    printf 'boot-a:%s|%s\n' "$1" "$TEST_SHELL_PID"
}
nats_wait_healthy() { return 0; }
_nats_health_for_port() { return 0; }
_nats_monitor_identity_for_port() {
    printf '%s\n' "$NATS_BG_SERVER_NAME"
}
_nats_monitor_owned_by_process() { return 1; }
NATS_RESTART_EFFECT="$TMP/foreign-monitor.effect"
export NATS_RESTART_EFFECT
if nats_restart; then
    foreign_health_status=0
else
    foreign_health_status=$?
fi
foreign_health_pid="${NATS_BG_PID:-}"
if [ -n "$foreign_health_pid" ]; then
    /bin/kill -KILL "$foreign_health_pid" 2>/dev/null || :
    builtin wait "$foreign_health_pid" 2>/dev/null || :
fi
if [ "$foreign_health_status" -ne 0 ]; then
    pass "foreign monitor ownership cannot certify the registered replacement"
else
    fail "restart accepted a concurrent foreign health endpoint"
fi
_remove_bound_nats_data_dir
reset_process_state

info "NATS storage cleanup ignores mutable path retargeting"
bound_nats_dir=$(mktemp -d /tmp/hi-nats-XXXXXX)
foreign_nats_dir=$(mktemp -d /tmp/operator-nats-data.XXXXXX)
printf '%s\n' keep > "$foreign_nats_dir/operator-data"
NATS_DATA_DIR="$bound_nats_dir"
if command -v _bind_nats_data_dir >/dev/null 2>&1 \
    && _bind_nats_data_dir "$bound_nats_dir"; then
    NATS_DATA_DIR="$foreign_nats_dir"
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    if cleanup_all \
        && [ ! -e "$bound_nats_dir" ] \
        && [ -f "$foreign_nats_dir/operator-data" ]; then
        pass "cleanup deletes only the bound NATS storage directory"
    else
        fail "mutable NATS_DATA_DIR retargeted or blocked bound cleanup"
    fi
else
    fail "NATS storage creation produced no immutable directory receipt"
fi
rm -rf -- "$bound_nats_dir" "$foreign_nats_dir"
reset_process_state

info "same-name NATS storage replacement is preserved and fails closed"
bound_nats_dir=$(mktemp -d /tmp/hi-nats-XXXXXX)
displaced_nats_dir="$bound_nats_dir.displaced"
NATS_DATA_DIR="$bound_nats_dir"
if command -v _bind_nats_data_dir >/dev/null 2>&1 \
    && _bind_nats_data_dir "$bound_nats_dir"; then
    mv -- "$bound_nats_dir" "$displaced_nats_dir"
    mkdir -m 700 -- "$bound_nats_dir"
    printf '%s\n' replacement > "$bound_nats_dir/replacement-data"
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    if cleanup_all; then
        fail "same-name replacement NATS storage reported successful cleanup"
    elif [ -f "$bound_nats_dir/replacement-data" ] \
        && [ -d "$displaced_nats_dir" ]; then
        pass "same-name replacement is retained when its inode is not bound"
    else
        fail "cleanup mutated a same-name replacement directory"
    fi
else
    fail "NATS storage creation produced no immutable replacement receipt"
fi
rm -rf -- "$bound_nats_dir" "$displaced_nats_dir"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state

info "NATS cleanup quarantines its exact directory before recursive removal"
bound_nats_dir=$(mktemp -d /tmp/hi-nats-XXXXXX)
nats_parent="${bound_nats_dir%/*}"
nats_name="${bound_nats_dir##*/}"
NATS_DATA_DIR="$bound_nats_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
python3 - "$bound_nats_dir" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
for index in range(2000):
    (root / f"entry-{index:04d}").write_text("bound", encoding="ascii")
PY
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
nats_race_seen="$TMP/nats-race.seen"
nats_cleanup_status="$TMP/nats-cleanup.status"
python3 - "$nats_parent" "$nats_name" "$nats_race_seen" <<'PY' &
import pathlib
import sys
import time

parent = pathlib.Path(sys.argv[1])
name = sys.argv[2]
seen = pathlib.Path(sys.argv[3])
prefix = f".{name}.cleanup-"
for _ in range(2000):
    if any(entry.name.startswith(prefix) for entry in parent.iterdir()):
        replacement = parent / name
        replacement.mkdir(mode=0o700)
        (replacement / "replacement-data").write_text(
            "preserve", encoding="ascii"
        )
        seen.touch()
        break
    time.sleep(0.001)
PY
nats_racer_pid=$!
(
    if cleanup_all >/dev/null 2>&1; then
        printf '0\n' > "$nats_cleanup_status"
    else
        printf '%s\n' "$?" > "$nats_cleanup_status"
    fi
) &
nats_cleaner_pid=$!
builtin wait "$nats_cleaner_pid" 2>/dev/null || :
builtin wait "$nats_racer_pid" 2>/dev/null || :
if [ -e "$nats_race_seen" ] \
    && [ "$(cat "$nats_cleanup_status")" -ne 0 ] \
    && grep -Fxq preserve "$bound_nats_dir/replacement-data" \
    && compgen -G "$nats_parent/.$nats_name.cleanup-*" >/dev/null; then
    pass "NATS replacement and quarantined evidence survive the removal race"
else
    fail "NATS final removal raced through an unbound same-name directory"
fi
rm -rf -- "$bound_nats_dir"
for nats_quarantine in "$nats_parent/.$nats_name.cleanup-"*; do
    [ -e "$nats_quarantine" ] || continue
    rm -rf -- "$nats_quarantine"
done
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state

info "same-device descendant mount identity cannot be traversed"
if grep -Fq ODYSSEUS_TEST_NATS_MOUNT_MISMATCH_NAME \
    "$ROOT/e2e/lib/process.sh"; then
    fail "production cleanup still contains a forced mount-mismatch switch"
else
    pass "mount-boundary fixtures do not alter production identity results"
fi
if [ "$(uname -s)" = Linux ] && command -v unshare >/dev/null 2>&1 \
    && command -v mount >/dev/null 2>&1 \
    && command -v umount >/dev/null 2>&1 \
    && unshare --user --map-root-user --mount true >/dev/null 2>&1; then
    if unshare --user --map-root-user --mount --propagation private \
        /bin/bash -c '
            set -uo pipefail
            root=$1
            source "$root/e2e/lib/common.sh"
            source "$root/e2e/lib/process.sh"
            fixture=$(mktemp -d /tmp/hi-mount-fixture.XXXXXX) || exit 10
            store=$(mktemp -d /tmp/hi-nats-XXXXXX) || exit 11
            mkdir -m 700 "$fixture/source" "$store/bind-mount" || exit 12
            printf "%s\n" preserve > "$fixture/source/evidence"
            NATS_DATA_DIR=$store
            _bind_nats_data_dir "$NATS_DATA_DIR" || exit 13
            mount --bind "$fixture/source" "$store/bind-mount" || exit 14
            root_device=$(stat -c %d "$store") || exit 15
            child_device=$(stat -c %d "$store/bind-mount") || exit 16
            if [ "$root_device" != "$child_device" ] || cleanup_all; then
                result=17
            elif [ -f "$store/bind-mount/evidence" ] \
                && [ -n "$NATS_DATA_RECEIPT" ]; then
                result=0
            else
                result=18
            fi
            umount "$store/bind-mount" || exit 19
            rm -rf -- "$store" "$fixture"
            exit "$result"
        ' bash "$ROOT"; then
        pass "same-device bind mount is retained through fd-bound mount identity"
    else
        fail "isolated same-device bind-mount cleanup fixture failed"
    fi
else
    pass "isolated bind mounts unavailable; production mount identity stays unmodified"
fi

info "subprocess registration updates the parent cleanup inventory"
unset -f kill
eval "$PRODUCTION_PROCESS_RECEIPT"
eval "$PRODUCTION_SIGNAL_BOUND_PROCESS"
export -f _process_receipt _signal_bound_process
_ensure_process_receipt_store
shared_pid_file="$TMP/shared-process.pid"
if /bin/bash -c '
    /bin/sleep 30 &
    child_pid=$!
    register_pid "$child_pid" || exit 1
    printf "%s\n" "$child_pid" > "$1"
    disown "$child_pid"
' bash "$shared_pid_file"; then
    shared_pid=$(cat "$shared_pid_file")
    if [ "$(uname -s)" = Darwin ]; then
        if _sync_process_receipts \
            && [ "${#_BG_PIDS[@]}" -eq 1 ] \
            && ! cleanup_pids \
            && [ "${_BG_PIDS[0]}" = "$shared_pid" ] \
            && /bin/kill -0 "$shared_pid" 2>/dev/null; then
            /bin/kill -KILL "$shared_pid" 2>/dev/null || :
            pass "Darwin retains an unsignallable subprocess receipt"
        else
            /bin/kill -KILL "$shared_pid" 2>/dev/null || :
            fail "Darwin cleanup did not fail closed with its receipt"
        fi
    elif _sync_process_receipts \
        && [ "${#_BG_PIDS[@]}" -eq 1 ] \
        && [ "${_BG_PIDS[0]}" = "$shared_pid" ] \
        && cleanup_pids \
        && [ "${#_BG_PIDS[@]}" -eq 0 ] \
        && ! /bin/kill -0 "$shared_pid" 2>/dev/null; then
        pass "a subprocess replacement remains visible to parent cleanup"
    else
        /bin/kill -KILL "$shared_pid" 2>/dev/null || :
        fail "subprocess process receipts did not converge in the parent"
    fi
else
    fail "a subprocess could not publish its direct-child receipt"
fi
reset_process_state

summary
exit_code
