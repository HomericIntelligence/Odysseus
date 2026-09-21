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
PRODUCTION_SERVICE_CONTAINMENT_OP=$(declare -f _service_containment_op)
PRODUCTION_PREPARE_SERVICE_CONTAINMENT=$(declare -f _prepare_service_containment)
PRODUCTION_JOIN_SERVICE_CONTAINMENT=$(declare -f _join_service_containment)
PRODUCTION_CONTAINMENT_CONTAINS=$(declare -f _service_containment_contains)
PRODUCTION_CONTAINMENT_STATE=$(declare -f _service_containment_state)
PRODUCTION_KILL_SERVICE_CONTAINMENT=$(declare -f _kill_service_containment)
PRODUCTION_REMOVE_SERVICE_CONTAINMENT=$(declare -f _remove_service_containment)
PRODUCTION_WAIT_CONTAINMENT_MEMBER=$(declare -f _wait_for_service_containment_member)
PRODUCTION_EXTINGUISH_CONTAINMENT=$(declare -f _extinguish_service_containment)
PRODUCTION_RETIRE_CONTAINMENT=$(declare -f _retire_service_containment)
PRODUCTION_PROCESS_RECEIPT_STORE_OP=$(declare -f _process_receipt_store_op)

if [ "$(uname -s)" = Linux ]; then
    info "a real exited and reaped Linux child is extinct, not unreadable"
    bash -c 'exit 0' &
    extinct_child=$!
    wait "$extinct_child"
    if _process_receipt "$extinct_child"; then
        fail "a reaped child still had a live receipt"
    else
        receipt_status=$?
        if [ "$receipt_status" -eq 1 ]; then
            pass "reaped Linux child is reported extinct"
        else
            fail "reaped Linux child was reported as an inspection failure"
        fi
    fi
fi

# Portable lifecycle cases use a deterministic containment seam. The real
# cgroup-v2 implementation is restored in the Linux-only extinction proof.
_prepare_service_containment() {
    PENDING_SERVICE_CONTAINMENT=cg1:portablefixture
}
_join_service_containment() { return 0; }
_service_containment_contains() { return 0; }
_service_containment_state() { return 1; }
_kill_service_containment() { return 0; }
_remove_service_containment() { return 0; }
_extinguish_service_containment() { return 0; }
_retire_service_containment() { return 0; }
_kill_registered_service_tree() { return 0; }

TMP="$(mktemp -d)"
TMP_CANONICAL="$(cd "$TMP" && pwd -P)"
trap 'rm -rf -- "$TMP"' EXIT
WAIT_LOG="$TMP/wait.log"
TEST_SHELL_PID="${BASHPID:-$$}"

reset_process_state() {
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    _BG_PROCESS_CONTAINMENTS=()
    discard_retained_process_receipt_fixture \
        "${PROCESS_RECEIPT_DIR:-}"
    discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
}

discard_retained_process_receipt_fixture() {
    local receipt_dir="${1:-}" parent name quarantine
    local receipt_version
    if [ -n "${PROCESS_RECEIPT_STORAGE_RECEIPT:-}" ]; then
        IFS='|' read -r receipt_version parent name _ \
            <<< "$PROCESS_RECEIPT_STORAGE_RECEIPT"
        if [ "$receipt_version" = v2 ] && [ -n "$parent" ] \
            && [ -n "$name" ]; then
            receipt_dir="$parent/$name"
        fi
    fi
    _close_process_receipt_fds
    [ -n "$receipt_dir" ] || return 0
    parent="${receipt_dir%/*}"
    name="${receipt_dir##*/}"
    case "$receipt_dir" in
        /tmp/hi-process-receipts.*|/private/tmp/hi-process-receipts.*)
            rm -rf -- "$receipt_dir"
            for quarantine in "$parent/.$name.cleanup-"*; do
                [ -e "$quarantine" ] || continue
                rm -rf -- "$quarantine"
            done
            ;;
    esac
    PROCESS_RECEIPT_DIR=""
    PROCESS_RECEIPT_FILE=""
    PROCESS_RECEIPT_STORAGE_RECEIPT=""
}

discard_retained_nats_fixture() {
    local data_dir="${1:-}" parent name quarantine
    local receipt_version
    if [ -n "${NATS_DATA_RECEIPT:-}" ]; then
        IFS='|' read -r receipt_version parent name _ \
            <<< "$NATS_DATA_RECEIPT"
        if [ "$receipt_version" = v2 ] && [ -n "$parent" ] \
            && [ -n "$name" ]; then
            data_dir="$parent/$name"
        fi
    fi
    _close_nats_data_fds
    [ -n "$data_dir" ] || return 0
    parent="${data_dir%/*}"
    name="${data_dir##*/}"
    case "$data_dir" in
        /tmp/hi-nats-*|/private/tmp/hi-nats-*|"$TMP"/hi-nats-*|\
        "$TMP_CANONICAL"/hi-nats-*)
            rm -rf -- "$data_dir"
            for quarantine in "$parent/.$name.cleanup-"*; do
                [ -e "$quarantine" ] || continue
                rm -rf -- "$quarantine"
            done
            ;;
    esac
    NATS_DATA_DIR=""
    NATS_DATA_RECEIPT=""
}

sleep() { return 0; }
wait() {
    printf '%s\n' "$*" >> "$WAIT_LOG"
    return 0
}

info "process receipt cleanup retains quarantined evidence without exact deletion"
_ensure_process_receipt_store
retained_receipt_dir="$PROCESS_RECEIPT_DIR"
retained_receipt_parent="${retained_receipt_dir%/*}"
retained_receipt_name="${retained_receipt_dir##*/}"
retained_receipt_error="$TMP/process-receipt-retained.error"
if _remove_process_receipt_store 2>"$retained_receipt_error"; then
    retained_receipt_status=0
else
    retained_receipt_status=$?
fi
if [ "$retained_receipt_status" -ne 0 ] \
    && [ ! -e "$retained_receipt_dir" ] \
    && compgen -G \
        "$retained_receipt_parent/.$retained_receipt_name.cleanup-*" \
        >/dev/null \
    && grep -Fq "exact inode-bound deletion is unavailable" \
        "$retained_receipt_error" \
    && grep -Fq "retained for operator recovery" \
        "$retained_receipt_error"; then
    pass "receipt evidence is retained when exact deletion cannot be proved"
else
    fail "receipt cleanup reported success without an exact deletion primitive"
fi
discard_retained_process_receipt_fixture "$retained_receipt_dir"

info "NATS cleanup retains quarantined storage without exact deletion"
retained_nats_dir="$TMP/hi-nats-RET000"
mkdir -m 700 "$retained_nats_dir"
NATS_DATA_DIR="$retained_nats_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
printf '%s\n' evidence > "$retained_nats_dir/operator-evidence"
retained_nats_parent="${retained_nats_dir%/*}"
retained_nats_name="${retained_nats_dir##*/}"
retained_nats_error="$TMP/nats-retained.error"
if _remove_bound_nats_data_dir 2>"$retained_nats_error"; then
    retained_nats_status=0
else
    retained_nats_status=$?
fi
if [ "$retained_nats_status" -ne 0 ] \
    && [ ! -e "$retained_nats_dir" ] \
    && compgen -G "$retained_nats_parent/.$retained_nats_name.cleanup-*" \
        >/dev/null \
    && grep -Fq "exact inode-bound deletion is unavailable" \
        "$retained_nats_error" \
    && grep -Fq "retained for operator recovery" \
        "$retained_nats_error"; then
    pass "NATS evidence is retained when exact deletion cannot be proved"
else
    fail "NATS cleanup reported success without an exact deletion primitive"
fi
discard_retained_nats_fixture "$retained_nats_dir"

info "empty process inventory permits storage cleanup"
NATS_DATA_DIR="$TMP/hi-nats-EMP001"
empty_data_dir="$NATS_DATA_DIR"
empty_data_parent="${empty_data_dir%/*}"
empty_data_name="${empty_data_dir##*/}"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
cleanup_all
cleanup_status=$?
if [ "$cleanup_status" -ne 0 ] \
    && [ "${#_BG_PIDS[@]}" -eq 0 ] \
    && [ ! -d "$empty_data_dir" ] \
    && compgen -G \
        "$empty_data_parent/.$empty_data_name.cleanup-*" >/dev/null; then
    pass "empty storage is quarantined and retained without exact deletion"
else
    fail "empty storage cleanup claimed unprovable deletion or lost evidence"
fi
discard_retained_nats_fixture "$empty_data_dir"

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
_close_nats_data_fds
rm -rf -- "$NATS_DATA_DIR"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state
eval "$PRODUCTION_SIGNAL_BOUND_PROCESS"

info "receipt descriptor collision retains bound evidence without path cleanup"
receipt_collision_path="$TMP/receipt-collision.path"
receipt_collision_anchor="$TMP/receipt-collision-anchor"
mkdir -m 700 "$receipt_collision_anchor"
if (
    exec 190< "$receipt_collision_anchor"
    PROCESS_RECEIPT_DIR=""
    PROCESS_RECEIPT_FILE=""
    PROCESS_RECEIPT_STORAGE_RECEIPT=""
    if _ensure_process_receipt_store >/dev/null 2>&1; then
        exit 10
    fi
    [ -n "$PROCESS_RECEIPT_STORAGE_RECEIPT" ] \
        && [ -d "$PROCESS_RECEIPT_DIR" ] \
        && [ -f "$PROCESS_RECEIPT_FILE" ] || exit 11
    printf '%s\n' "$PROCESS_RECEIPT_DIR" > "$receipt_collision_path"
); then
    retained_receipt_dir=$(cat "$receipt_collision_path")
    rm -f -- "$retained_receipt_dir/receipts"
    rmdir -- "$retained_receipt_dir"
    pass "failed capability binding retains its exact receipt evidence"
else
    fail "descriptor collision triggered mutable-path receipt cleanup"
fi

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
stopped_data_parent="${stopped_data_dir%/*}"
stopped_data_name="${stopped_data_dir##*/}"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
_BG_PIDS=(4343)
_BG_PID_IDENTITIES=("$MOCK_PROCESS_IDENTITY")
_BG_PID_OWNERS=("${BASHPID:-$$}")
: > "$WAIT_LOG"
cleanup_all
cleanup_status=$?
if [ "$cleanup_status" -ne 0 ] \
    && [ "${#_BG_PIDS[@]}" -eq 0 ] \
    && [ ! -d "$stopped_data_dir" ] \
    && compgen -G \
        "$stopped_data_parent/.$stopped_data_name.cleanup-*" >/dev/null \
    && grep -Fxq 4343 "$WAIT_LOG"; then
    pass "extinction is proved before storage is quarantined and retained"
else
    fail "termination cleanup lost evidence or claimed unprovable deletion"
fi
reset_process_state
eval "$PRODUCTION_SIGNAL_BOUND_PROCESS"

info "containment receipts clear only after exact tree extinction"
containment_order_log="$TMP/containment-order.log"
if (
    _sync_process_receipts() { return 0; }
    _persist_process_receipts() {
        printf '%s\n' persist >> "$containment_order_log"
    }
    _process_identity_status() { return 1; }
    _retire_service_containment() {
        printf '%s\n' extinguish >> "$containment_order_log"
    }
    wait() { return 0; }
    _BG_PIDS=(4399)
    _BG_PID_IDENTITIES=(boot-a:4399)
    _BG_PID_OWNERS=("${BASHPID:-$$}")
    _BG_PROCESS_CONTAINMENTS=(cg1:orderingfixture)
    cleanup_pids \
        && [ "${#_BG_PIDS[@]}" -eq 0 ] \
        && [ "$(tr '\n' ',' < "$containment_order_log")" \
            = 'extinguish,persist,' ]
); then
    pass "kernel tree extinction precedes receipt clearance"
else
    fail "cleanup discarded containment authority before extinction proof"
fi

info "containment extinction failure is bounded and truthful"
if (
    eval "$PRODUCTION_EXTINGUISH_CONTAINMENT"
    _service_containment_state() { return 0; }
    _kill_service_containment() { return 0; }
    started=$SECONDS
    if _extinguish_service_containment cg1:timeoutfixture; then
        exit 10
    fi
    elapsed=$((SECONDS - started))
    [ "$elapsed" -ge 4 ] && [ "$elapsed" -le 7 ]
); then
    pass "a non-empty kernel tree times out without claiming extinction"
else
    fail "containment timeout was unbounded or converted into completion"
fi

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
    fixture_owner="${BASHPID:-$$}"
    _process_receipt() {
        /bin/kill -0 "$1" 2>/dev/null || return 1
        printf 'fixture:%s|%s\n' "$1" "$fixture_owner"
    }
    _sync_process_receipts() { return 1; }
    _wait_for_nats_ports_free() { return 0; }
    _resolve_bound_nats_data_dir() { return 0; }
    _exec_nats_with_bound_store() {
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
    if ! _nats_descriptor_exec_supported; then
        [ ! -s "$registration_signal_log" ] \
            && [ ! -e "$registration_pid_file" ]
        exit
    fi
    IFS=' ' read -r child_pid _ < "$registration_signal_log" || exit 11
    printf '%s\n' "$child_pid" > "$registration_pid_file"
    if /bin/kill -0 "$child_pid" 2>/dev/null; then
        exit 12
    fi
    grep -Eq -- '-TERM|-KILL' "$registration_signal_log" || exit 13
); then
    pass "validated identity is available for bounded registration rollback"
else
    if [ -s "$registration_pid_file" ]; then
        rollback_pid=$(cat "$registration_pid_file")
        if ! /bin/kill -KILL "$rollback_pid" 2>/dev/null; then :; fi
    fi
    fail "receipt sync failure leaked or waited indefinitely on its child"
fi

info "service registration rollback uses the validated child identity"
registration_root="$TMP/registration-services"
registration_retire_log="$TMP/registration-services.retired"
registration_raw_signal_log="$TMP/registration-services.raw-signal"
mkdir -p "$registration_root/build/Agamemnon" \
    "$registration_root/build/Myrmidons/hello-world"
cat > "$registration_root/build/Agamemnon/Agamemnon_server" <<'SH'
#!/usr/bin/env bash
exec /bin/sleep 30
SH
cp "$registration_root/build/Agamemnon/Agamemnon_server" \
    "$registration_root/build/Myrmidons/hello-world/hello_myrmidon"
chmod +x "$registration_root/build/Agamemnon/Agamemnon_server" \
    "$registration_root/build/Myrmidons/hello-world/hello_myrmidon"
: > "$registration_retire_log"
: > "$registration_raw_signal_log"
if (
    _bound_process_signaling_supported() { return 0; }
    register_pid() {
        # Consumed by the production rollback helper sourced above.
        # shellcheck disable=SC2034
        REGISTERED_PROCESS_IDENTITY="fixture:$1"
        # shellcheck disable=SC2034
        REGISTERED_PROCESS_OWNER="${BASHPID:-$$}"
        return 1
    }
    _retire_unregistered_child() {
        printf '%s\n' "$*" >> "$registration_retire_log"
        if ! /bin/kill -KILL "$1" 2>/dev/null; then :; fi
        if ! builtin wait "$1" 2>/dev/null; then :; fi
    }
    kill() {
        printf '%s\n' "$*" >> "$registration_raw_signal_log"
        /bin/kill "$@"
    }
    ODYSSEUS_ROOT="$registration_root"
    export ODYSSEUS_ROOT
    if start_agamemnon_bg >/dev/null 2>&1; then
        exit 10
    fi
    if start_myrmidon_bg >/dev/null 2>&1; then
        exit 11
    fi
    [ "$(wc -l < "$registration_retire_log")" -eq 2 ] \
        && [ ! -s "$registration_raw_signal_log" ]
); then
    pass "failed service registration retires only validated child identities"
else
    fail "service registration used an unbound numeric-PID signal fallback"
fi

info "services fail before launch without handle-bound process signaling"
preflight_root="$TMP/process-preflight-services"
preflight_effect="$TMP/process-preflight.effect"
mkdir -p "$preflight_root/build/Agamemnon" \
    "$preflight_root/build/Myrmidons/hello-world"
cat > "$preflight_root/build/Agamemnon/Agamemnon_server" <<'SH'
#!/usr/bin/env bash
printf '%s\n' Agamemnon >> "${PROCESS_PREFLIGHT_EFFECT:?}"
SH
cp "$preflight_root/build/Agamemnon/Agamemnon_server" \
    "$preflight_root/build/Myrmidons/hello-world/hello_myrmidon"
chmod +x "$preflight_root/build/Agamemnon/Agamemnon_server" \
    "$preflight_root/build/Myrmidons/hello-world/hello_myrmidon"
if (
    _bound_process_signaling_supported() { return 1; }
    register_pid() {
        for _ in $(seq 1 20); do
            [ -e "$PROCESS_PREFLIGHT_EFFECT" ] && break
            /bin/sleep 0.05
        done
        return 1
    }
    ODYSSEUS_ROOT="$preflight_root"
    PROCESS_PREFLIGHT_EFFECT="$preflight_effect"
    export ODYSSEUS_ROOT PROCESS_PREFLIGHT_EFFECT
    if ! start_agamemnon_bg >/dev/null 2>&1; then :; fi
    if ! start_myrmidon_bg >/dev/null 2>&1; then :; fi
    /bin/sleep 0.2
    [ ! -e "$preflight_effect" ]
); then
    pass "unsupported hosts create no unmanaged service children"
else
    fail "a service launched without an identity-bound cleanup primitive"
fi

info "services fail before launch without kernel-owned tree containment"
rm -f -- "$preflight_effect"
containment_preflight_seen="$TMP/process-containment-preflight.seen"
if (
    _bound_process_signaling_supported() { return 0; }
    _prepare_service_containment() {
        : > "$containment_preflight_seen"
        return 1
    }
    register_pid() { return 1; }
    ODYSSEUS_ROOT="$preflight_root"
    PROCESS_PREFLIGHT_EFFECT="$preflight_effect"
    export ODYSSEUS_ROOT PROCESS_PREFLIGHT_EFFECT
    if ! start_agamemnon_bg >/dev/null 2>&1; then :; fi
    if ! start_myrmidon_bg >/dev/null 2>&1; then :; fi
    /bin/sleep 0.2
    [ -e "$containment_preflight_seen" ] && [ ! -e "$preflight_effect" ]
); then
    pass "unavailable containment authority creates no service process"
else
    fail "a service launched without kernel-owned full-tree containment"
fi

info "service launch uses an exact executable and a minimal environment"
service_binding_root="$TMP/service-binding"
service_binding_effect="$TMP/service-binding.effect"
service_binding_original="$service_binding_root/build/Myrmidons/hello-world/hello_myrmidon"
service_binding_displaced="$service_binding_original.displaced"
service_binding_replacement="$TMP/service-binding-replacement"
mkdir -p "${service_binding_original%/*}"
cat > "$service_binding_original" <<SH
#!/bin/sh
if [ "\${UNRELATED_SERVICE_SECRET+x}" != x ] \
    && [ "\${HOME+x}" != x ] \
    && [ "\${NATS_URL:-}" = nats://127.0.0.1:4222 ] \
    && [ "\${MYRMIDON_WORK_DELAY_MS:-}" = 17 ]; then
    printf '%s\n' original > "$service_binding_effect"
else
    printf '%s\n' ambient-environment > "$service_binding_effect"
fi
exec /bin/sleep 30
SH
cat > "$service_binding_replacement" <<SH
#!/bin/sh
printf '%s\n' replacement > "$service_binding_effect"
exec /bin/sleep 30
SH
chmod 700 "$service_binding_original" "$service_binding_replacement"
if (
    _bound_process_signaling_supported() { return 0; }
    _prepare_service_containment() {
        PENDING_SERVICE_CONTAINMENT=cg1:servicebindingfixture
    }
    _join_service_containment() {
        mv -- "$service_binding_original" "$service_binding_displaced" || return 1
        cp -- "$service_binding_replacement" "$service_binding_original" || return 1
        chmod 700 "$service_binding_original"
    }
    register_pid() {
        SERVICE_BINDING_PID="$1"
        REGISTERED_PROCESS_IDENTITY="fixture:$1"
        REGISTERED_PROCESS_OWNER="${BASHPID:-$$}"
    }
    _wait_for_registered_myrmidon() { return 0; }
    wait_for() { return 0; }
    ODYSSEUS_ROOT="$service_binding_root"
    NATS_PORT=4222
    MYRMIDON_WORK_DELAY_MS=17
    UNRELATED_SERVICE_SECRET=must-not-cross
    HOME=/operator/private
    export ODYSSEUS_ROOT NATS_PORT MYRMIDON_WORK_DELAY_MS \
        UNRELATED_SERVICE_SECRET HOME
    SERVICE_BINDING_PID=""
    service_binding_status=0
    start_myrmidon_bg >/dev/null 2>&1 || service_binding_status=$?
    if [ "$service_binding_status" -eq 0 ]; then
        for _ in $(seq 1 100); do
            [ -s "$service_binding_effect" ] && break
            /bin/sleep 0.01
        done
    fi
    service_binding_result=""
    if ! service_binding_result=$(cat "$service_binding_effect" 2>/dev/null); then :; fi
    if [ -n "$SERVICE_BINDING_PID" ]; then
        if ! /bin/kill -KILL "$SERVICE_BINDING_PID" 2>/dev/null; then :; fi
        if ! builtin wait "$SERVICE_BINDING_PID" 2>/dev/null; then :; fi
    fi
    if [ "$(uname -s)" = Linux ]; then
        [ "$service_binding_status" -eq 0 ] \
            && [ "$service_binding_result" = original ] \
            && [ -n "$SERVICE_BINDING_PID" ]
    else
        [ "$service_binding_result" != replacement ]
    fi
); then
    pass "service execution stays bound and receives only allowlisted variables"
else
    fail "service execution reopened its path or inherited ambient authority"
fi

info "service readiness revalidates exact socket ownership"
if (
    _process_identity_status() { return 0; }
    _registered_process_receipt_matches() { return 0; }
    _service_containment_contains() { return 0; }
    _run_bound_curl_bounded() { return 0; }
    agamemnon_owner_checks=0
    _nats_monitor_owned_by_process() {
        agamemnon_owner_checks=$((agamemnon_owner_checks + 1))
        [ "$agamemnon_owner_checks" -eq 1 ]
    }
    if _wait_for_registered_agamemnon \
        4242 fixture:4242 "${BASHPID:-$$}" cg1:readinessfixture \
        18080 1; then
        exit 30
    fi
    myrmidon_connection_checks=0
    _service_connected_to_port() {
        myrmidon_connection_checks=$((myrmidon_connection_checks + 1))
        [ "$myrmidon_connection_checks" -eq 1 ]
    }
    if _wait_for_registered_myrmidon \
        4343 fixture:4343 "${BASHPID:-$$}" cg1:readinessfixture \
        14222 1; then
        exit 31
    fi
); then
    pass "readiness revalidates exact socket ownership at success"
else
    fail "readiness accepted stale socket ownership evidence"
fi

info "failed owned-readiness checks roll back both registered services"
if (
    _bound_process_signaling_supported() { return 0; }
    _prepare_service_containment() {
        PENDING_SERVICE_CONTAINMENT=cg1:readinessfixture
    }
    _join_service_containment() { return 0; }
    register_pid() {
        REGISTERED_PROCESS_IDENTITY="fixture:$1"
        REGISTERED_PROCESS_OWNER="${BASHPID:-$$}"
        return 0
    }
    _wait_for_registered_agamemnon() { return 1; }
    _wait_for_registered_myrmidon() { return 1; }
    _rollback_registered_child() {
        printf '%s\n' "$2" >> "$TMP/readiness-rollbacks"
        if ! /bin/kill -KILL "$1" 2>/dev/null; then :; fi
        if ! builtin wait "$1" 2>/dev/null; then :; fi
        return 0
    }
    wait_for() { return 0; }
    readiness_root="$TMP/readiness-services"
    mkdir -p "$readiness_root/build/Agamemnon" \
        "$readiness_root/build/Myrmidons/hello-world"
    cp -- /bin/sleep "$readiness_root/build/Agamemnon/Agamemnon_server"
    cp -- /bin/sleep \
        "$readiness_root/build/Myrmidons/hello-world/hello_myrmidon"
    chmod 700 "$readiness_root/build/Agamemnon/Agamemnon_server" \
        "$readiness_root/build/Myrmidons/hello-world/hello_myrmidon"
    : > "$TMP/readiness-rollbacks"
    ODYSSEUS_ROOT="$readiness_root"
    export ODYSSEUS_ROOT
    if start_agamemnon_bg >/dev/null 2>&1; then
        exit 20
    fi
    if start_myrmidon_bg >/dev/null 2>&1; then
        exit 21
    fi
    [ "$(sort "$TMP/readiness-rollbacks" | tr '\n' ',')" \
        = 'Agamemnon,hello-myrmidon,' ]
); then
    pass "unowned readiness cannot leave a registered service running"
else
    fail "a service returned success without exact owned readiness or rollback"
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
_BG_PROCESS_CONTAINMENTS=("")
if _persist_process_receipts \
    && grep -Fxq preserve "$protected_receipt_file"; then
    pass "receipt publication cannot overwrite a retargeted regular file"
else
    fail "mutable receipt storage redirected publication to operator data"
fi
PROCESS_RECEIPT_DIR="$bound_receipt_dir"
PROCESS_RECEIPT_FILE="$bound_receipt_file"
reset_process_state

info "process receipt publication stays bound after a pre-operation rename"
_ensure_process_receipt_store
bound_receipt_dir="$PROCESS_RECEIPT_DIR"
bound_receipt_file="$PROCESS_RECEIPT_FILE"
displaced_receipt_dir="$bound_receipt_dir.displaced"
mv -- "$bound_receipt_dir" "$displaced_receipt_dir"
mkdir -m 700 -- "$bound_receipt_dir"
(umask 077 && printf '%s\n' preserve > "$bound_receipt_file")
_BG_PIDS=(4489)
_BG_PID_IDENTITIES=(boot-a:4489)
_BG_PID_OWNERS=("${BASHPID:-$$}")
_BG_PROCESS_CONTAINMENTS=("")
if _persist_process_receipts >/dev/null 2>&1 \
    && bound_publication=$(_process_receipt_store_op read) \
    && [[ "$bound_publication" =~ ^4489\|boot-a:4489\|[1-9][0-9]*\|$ ]] \
    && grep -Fxq preserve "$bound_receipt_file"; then
    pass "publication uses the already-bound receipt object"
else
    fail "publication reopened the mutable process receipt path"
fi
rm -f -- "$bound_receipt_file"
rmdir -- "$bound_receipt_dir"
mv -- "$displaced_receipt_dir" "$bound_receipt_dir"
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
_BG_PROCESS_CONTAINMENTS=()
unset bound_publication
if ! _persist_process_receipts >/dev/null 2>&1; then :; fi
discard_retained_process_receipt_fixture "$bound_receipt_dir"

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
receipt_parent="${bound_receipt_dir%/*}"
receipt_name="${bound_receipt_dir##*/}"
if ! cleanup_all \
    && [ ! -e "$bound_receipt_dir" ] \
    && compgen -G "$receipt_parent/.$receipt_name.cleanup-*" >/dev/null \
    && grep -Fxq preserve "$protected_receipt_file"; then
    pass "receipt cleanup quarantines only its bound storage object"
else
    fail "mutable receipt storage redirected cleanup or lost bound evidence"
fi
discard_retained_process_receipt_fixture "$bound_receipt_dir"

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
discard_retained_process_receipt_fixture "$bound_receipt_dir"

info "process receipt cleanup serializes removal behind its receipt lock"
_ensure_process_receipt_store
bound_receipt_dir="$PROCESS_RECEIPT_DIR"
bound_receipt_file="$PROCESS_RECEIPT_FILE"
receipt_parent="${bound_receipt_dir%/*}"
receipt_name="${bound_receipt_dir##*/}"
lock_ready="$TMP/receipt-lock.ready"
lock_release="$TMP/receipt-lock.release"
receipt_cleanup_status="$TMP/receipt-cleanup.status"
receipt_cleanup_error="$TMP/receipt-cleanup.error"
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
    if _remove_process_receipt_store >/dev/null \
        2>"$receipt_cleanup_error"; then
        printf '0\n' > "$receipt_cleanup_status"
    else
        printf '%s\n' "$?" > "$receipt_cleanup_status"
    fi
) &
receipt_cleaner_pid=$!
receipt_quarantine_seen=0
for _ in $(seq 1 20); do
    if compgen -G "$receipt_parent/.$receipt_name.cleanup-*" >/dev/null; then
        receipt_quarantine_seen=1
        break
    fi
    /bin/sleep 0.01
done
touch "$lock_release"
if ! builtin wait "$receipt_cleaner_pid" 2>/dev/null; then :; fi
if ! builtin wait "$receipt_locker_pid" 2>/dev/null; then :; fi
if [ "$receipt_quarantine_seen" -eq 0 ] \
    && [ "$(cat "$receipt_cleanup_status")" -ne 0 ] \
    && [ ! -e "$bound_receipt_dir" ] \
    && compgen -G "$receipt_parent/.$receipt_name.cleanup-*" >/dev/null \
    && grep -Fq "retained for operator recovery" \
        "$receipt_cleanup_error"; then
    pass "receipt quarantine waits for the exclusive receipt lock"
else
    fail "receipt quarantine bypassed its lock or discarded evidence"
fi
discard_retained_process_receipt_fixture "$bound_receipt_dir"

info "process receipt admission is atomic across concurrent publishers"
reset_process_state
_ensure_process_receipt_store
atomic_barrier="$TMP/receipt-atomic-barrier"
atomic_pid_one="$TMP/receipt-atomic-one.pid"
atomic_pid_two="$TMP/receipt-atomic-two.pid"
export PROCESS_RECEIPT_DIR PROCESS_RECEIPT_FILE PROCESS_RECEIPT_STORAGE_RECEIPT \
    PROCESS_RECEIPT_PARENT_FD PROCESS_RECEIPT_DIRECTORY_FD \
    PROCESS_RECEIPT_FILE_FD PRODUCTION_PROCESS_RECEIPT_STORE_OP atomic_barrier
atomic_worker='
renamed=${PRODUCTION_PROCESS_RECEIPT_STORE_OP/_process_receipt_store_op ()/_real_process_receipt_store_op ()}
eval "$renamed"
_process_receipt_store_op() {
    if [ "${1:-}" = read ]; then
        local output status count
        output=$(_real_process_receipt_store_op "$@")
        status=$?
        [ "$status" -eq 0 ] || return "$status"
        : > "$atomic_barrier.$ATOMIC_WORKER"
        for _ in $(seq 1 200); do
            set -- "$atomic_barrier".*
            [ "$#" -eq 2 ] && break
            /bin/sleep 0.01
        done
        printf "%s" "$output"
        return 0
    fi
    _real_process_receipt_store_op "$@"
}
atomic_owner=${BASHPID:-$$}
_process_receipt() {
    printf "fixture:%s|%s\n" "$1" "$atomic_owner"
}
/bin/sleep 30 &
child=$!
register_pid "$child" || exit 31
printf "%s\n" "$child" > "$ATOMIC_PID_FILE"
disown "$child"
'
ATOMIC_WORKER=one ATOMIC_PID_FILE="$atomic_pid_one" \
    /bin/bash -c "$atomic_worker" &
atomic_worker_one=$!
ATOMIC_WORKER=two ATOMIC_PID_FILE="$atomic_pid_two" \
    /bin/bash -c "$atomic_worker" &
atomic_worker_two=$!
builtin wait "$atomic_worker_one" 2>/dev/null
atomic_status_one=$?
builtin wait "$atomic_worker_two" 2>/dev/null
atomic_status_two=$?
if _sync_process_receipts >/dev/null 2>&1; then
    atomic_receipt_count=${#_BG_PIDS[@]}
else
    atomic_receipt_count=-1
fi
for atomic_pid_file in "$atomic_pid_one" "$atomic_pid_two"; do
    if [ -s "$atomic_pid_file" ]; then
        atomic_pid=$(cat "$atomic_pid_file")
        if ! /bin/kill -KILL "$atomic_pid" 2>/dev/null; then :; fi
    fi
done
if [ "$atomic_status_one" -eq 0 ] && [ "$atomic_status_two" -eq 0 ] \
    && [ "$atomic_receipt_count" -eq 2 ]; then
    pass "exclusive receipt mutation preserves both concurrent registrations"
else
    fail "split receipt read/write lost a concurrent registration"
fi
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
_BG_PROCESS_CONTAINMENTS=()
if ! _persist_process_receipts >/dev/null 2>&1; then :; fi
discard_retained_process_receipt_fixture "${PROCESS_RECEIPT_DIR:-}"

info "interrupted receipt publication preserves the last durable generation"
reset_process_state
_ensure_process_receipt_store
interruption_receipt="61001|before-interruption:${TEST_SHELL_PID}|${TEST_SHELL_PID}|"
interruption_payload=""
for interruption_index in $(seq 1 200); do
    interruption_payload+="$((62000 + interruption_index))|replacement:$interruption_index|${TEST_SHELL_PID}|"$'\n'
done
_process_receipt_store_op write "$interruption_receipt"$'\n'
if ! (
    ulimit -f 1
    _process_receipt_store_op write "$interruption_payload" \
        >/dev/null 2>&1
) >/dev/null 2>&1; then :; fi
if interruption_readback=$(_process_receipt_store_op read 2>/dev/null) \
    && [ "$interruption_readback" = "$interruption_receipt" ]; then
    pass "an interrupted write cannot erase the prior receipt generation"
else
    fail "an interrupted receipt write exposed empty, partial, or replacement state"
fi
_close_process_receipt_fds
rm -f -- "$PROCESS_RECEIPT_FILE"
if ! rmdir -- "$PROCESS_RECEIPT_DIR" 2>/dev/null; then :; fi
PROCESS_RECEIPT_DIR=""
PROCESS_RECEIPT_FILE=""
PROCESS_RECEIPT_STORAGE_RECEIPT=""
unset interruption_receipt interruption_payload interruption_index \
    interruption_readback

info "the first interrupted receipt publication retains a durable empty generation"
reset_process_state
_ensure_process_receipt_store
first_publication_payload=""
for first_publication_index in $(seq 1 200); do
    first_publication_payload+="$((63000 + first_publication_index))|first:$first_publication_index|${TEST_SHELL_PID}|"$'\n'
done
if ! (
    ulimit -f 1
    _process_receipt_store_op write "$first_publication_payload" \
        >/dev/null 2>&1
) >/dev/null 2>&1; then :; fi
if first_publication_readback=$(_process_receipt_store_op read 2>/dev/null) \
    && [ -z "$first_publication_readback" ]; then
    pass "an interrupted first write falls back to the seeded empty generation"
else
    fail "an interrupted first write left no readable durable generation"
fi
discard_retained_process_receipt_fixture "${PROCESS_RECEIPT_DIR:-}"
unset first_publication_payload first_publication_index \
    first_publication_readback

info "a corrupt newest receipt slot falls back to the prior complete generation"
reset_process_state
_ensure_process_receipt_store
older_receipt="64001|older:${TEST_SHELL_PID}|${TEST_SHELL_PID}|"
newer_receipt="64002|newer:${TEST_SHELL_PID}|${TEST_SHELL_PID}|"
_process_receipt_store_op write "$older_receipt"$'\n'
_process_receipt_store_op write "$newer_receipt"$'\n'
# Creation seeds generation 1 in slot zero; these writes publish generations
# 2 and 3, so corrupting slot zero must reveal generation 2 from slot one.
/usr/bin/python3 -I -S -c \
    'import os; raise SystemExit(0 if os.pwrite(192, b"corrupt!", 0) == 8 else 1)'
if corrupt_slot_readback=$(_process_receipt_store_op read 2>/dev/null) \
    && [ "$corrupt_slot_readback" = "$older_receipt" ]; then
    pass "readers ignore a corrupt newest slot and recover the prior generation"
else
    fail "newest-slot corruption hid or replaced the prior durable generation"
fi
discard_retained_process_receipt_fixture "${PROCESS_RECEIPT_DIR:-}"
unset older_receipt newer_receipt corrupt_slot_readback

info "process receipt storage enforces byte and cardinality ceilings"
_ensure_process_receipt_store
oversized_receipt_payload=$(python3 - <<'PY'
print("x" * 65537, end="")
PY
)
cardinality_receipt_payload=""
for index in $(seq 1 257); do
    cardinality_receipt_payload+="$((50000 + index))|fixture:$index|${BASHPID:-$$}|"$'\n'
done
receipt_byte_limit_rejected=0
receipt_cardinality_rejected=0
if ! _process_receipt_store_op write "$oversized_receipt_payload" \
    >/dev/null 2>&1; then
    receipt_byte_limit_rejected=1
fi
if ! _process_receipt_store_op write "$cardinality_receipt_payload" \
    >/dev/null 2>&1; then
    receipt_cardinality_rejected=1
fi
if [ "$receipt_byte_limit_rejected" -eq 1 ] \
    && [ "$receipt_cardinality_rejected" -eq 1 ]; then
    pass "receipt state rejects oversized bytes and excess records"
else
    fail "receipt state admitted unbounded bytes or record cardinality"
fi
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
_BG_PROCESS_CONTAINMENTS=()
if ! _persist_process_receipts >/dev/null 2>&1; then :; fi
discard_retained_process_receipt_fixture "${PROCESS_RECEIPT_DIR:-}"

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
    if ! /bin/kill -KILL "$darwin_signal_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$darwin_signal_pid" 2>/dev/null; then :; fi
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

info "NATS kill requires extinction of the exact registered child"
if (
    _process_identity_status() { return 0; }
    _signal_bound_process() { return 0; }
    nats_health() { return 1; }
    IPC_TOPOLOGY=t1
    NATS_BG_PID=4596
    NATS_BG_IDENTITY=boot-a:live-nats
    NATS_BG_OWNER="$TEST_SHELL_PID"
    nats_kill
); then
    fail "monitor shutdown concealed a still-live registered NATS child"
else
    pass "monitor shutdown alone cannot certify NATS process extinction"
fi

info "NATS restart never waits on a still-live registered child"
live_restart_store="$TMP/hi-nats-LIV001"
live_restart_effect="$TMP/live-restart.effect"
mkdir -m 700 "$live_restart_store"
NATS_DATA_DIR="$live_restart_store"
_bind_nats_data_dir "$NATS_DATA_DIR"
: > "$WAIT_LOG"
if (
    _process_identity_status() { return 0; }
    _start_nats_guarded() {
        : > "$live_restart_effect"
        return 0
    }
    IPC_TOPOLOGY=t1
    NATS_BG_PID=4597
    NATS_BG_IDENTITY=boot-a:live-restart
    NATS_BG_OWNER="$TEST_SHELL_PID"
    NATS_BIN=/bin/true
    nats_restart
); then
    fail "restart accepted a still-live registered NATS child"
elif [ ! -s "$WAIT_LOG" ] && [ ! -e "$live_restart_effect" ]; then
    pass "live process identity stops restart before wait or launch"
else
    fail "restart waited on or launched past a still-live child"
fi
discard_retained_nats_fixture "${NATS_DATA_DIR:-}"

info "failed NATS replacement does not resurrect the retired identity"
if (
    _resolve_bound_nats_data_dir() { return 0; }
    _process_identity_status() { return 1; }
    unregister_pid() { return 0; }
    _start_nats_guarded() { return 1; }
    IPC_TOPOLOGY=t1
    NATS_BG_PID=4598
    NATS_BG_IDENTITY=boot-a:retired-nats
    NATS_BG_OWNER="$TEST_SHELL_PID"
    NATS_BG_SERVER_NAME=odysseus-e2e-00000000000000000000000000000000
    NATS_BIN=/bin/true
    if nats_restart; then
        exit 10
    fi
    [ -z "$NATS_BG_PID" ] \
        && [ -z "$NATS_BG_IDENTITY" ] \
        && [ -z "$NATS_BG_OWNER" ] \
        && [ -z "$NATS_BG_SERVER_NAME" ]
); then
    pass "replacement failure retains no stale retired-child state"
else
    fail "replacement failure restored a retired NATS identity"
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
    if ! builtin wait "$STALLED_MONITOR_PID" 2>/dev/null; then :; fi
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
    if ! builtin wait "$STALLED_MONITOR_PID" 2>/dev/null; then :; fi
    if [ "$stalled_varz_status" -ne 0 ] \
        && [ "$stalled_elapsed" -le 2 ]; then
        pass "stalled varz response cannot exceed its remaining deadline"
    else
        fail "varz probe waited past its caller deadline"
    fi
else
    fail "could not create the stalled varz fixture"
fi

info "NATS varz captures reject responses beyond the byte ceiling"
if (
    exact_varz_response() {
        printf '%s' \
            '{"server_name":"odysseus-e2e-00000000000000000000000000000000"}'
        case " $* " in
            *" --write-out "*) printf '\n200' ;;
        esac
    }
    curl() { exact_varz_response "$@"; }
    curl_bounded() { exact_varz_response "$@"; }
    _run_bound_curl_bounded() { exact_varz_response "$@"; }
    nats_varz | grep -Fq 'odysseus-e2e-00000000000000000000000000000000' \
        && [ "$(_nats_monitor_identity_for_port 8222 1)" \
            = odysseus-e2e-00000000000000000000000000000000 ]
); then
    pass "bounded varz parsers preserve exact valid monitor responses"
else
    fail "varz byte ceilings rejected the expected bounded response"
fi
public_varz_rejected=0
if (
    flood_varz_response() {
        python3 - <<'PY'
import sys

sys.stdout.buffer.write(
    b'{"server_name":"odysseus-e2e-'
    + b'0' * 32
    + b'","padding":"'
    + b'x' * (1024 * 1024)
    + b'"}'
)
PY
        case " $* " in
            *" --write-out "*) printf '\n200' ;;
        esac
    }
    curl() { flood_varz_response "$@"; }
    curl_bounded() { flood_varz_response "$@"; }
    _run_bound_curl_bounded() { flood_varz_response "$@"; }
    nats_varz >/dev/null 2>&1
); then
    public_varz_rejected=1
fi
launch_varz_rejected=0
if (
    flood_varz_response() {
        python3 - <<'PY'
import sys

sys.stdout.buffer.write(
    b'{"server_name":"odysseus-e2e-'
    + b'0' * 32
    + b'","padding":"'
    + b'x' * (1024 * 1024)
    + b'"}'
)
PY
        case " $* " in
            *" --write-out "*) printf '\n200' ;;
        esac
    }
    curl() { flood_varz_response "$@"; }
    curl_bounded() { flood_varz_response "$@"; }
    _run_bound_curl_bounded() { flood_varz_response "$@"; }
    _nats_monitor_identity_for_port 8222 1 >/dev/null 2>&1
); then
    launch_varz_rejected=1
fi
if [ "$public_varz_rejected" -eq 0 ] \
    && [ "$launch_varz_rejected" -eq 0 ]; then
    pass "both varz capture paths enforce the strict response-byte ceiling"
elif [ "$public_varz_rejected" -ne 0 ] \
    && [ "$launch_varz_rejected" -ne 0 ]; then
    fail "both varz helpers buffered oversized monitor responses"
elif [ "$public_varz_rejected" -ne 0 ]; then
    fail "the public varz helper buffered an oversized monitor response"
else
    fail "the launch-time varz identity probe buffered an oversized response"
fi

info "JetStream names cross the parser boundary only as data arguments"
if (
    hostile_stream="stream-with-'quote-and-\\backslash"
    nats_jsz() {
        printf '%s\n' \
            "{\"account_details\":[{\"stream_detail\":[{\"name\":\"stream-with-'quote-and-\\\\backslash\",\"state\":{\"messages\":7}}]}]}"
    }
    [ "$(nats_stream_msg_count "$hostile_stream")" = 7 ] \
        && nats_stream_exists "$hostile_stream"
); then
    pass "stream names are passed to Python as argv data"
else
    fail "stream names were interpolated into executable Python source"
fi

info "NATS probes use bound tools, numeric loopback, and no proxy routing"
bound_tool_effect="$TMP/ambient-tool.effect"
hostile_python_home="$TMP/hostile-python-home"
hostile_curl_home="$TMP/hostile-curl-home"
mkdir -p "$hostile_python_home" "$hostile_curl_home"
cat > "$hostile_python_home/sitecustomize.py" <<'PY'
import os

with open(os.environ["BOUND_TOOL_EFFECT"], "w", encoding="utf-8") as stream:
    stream.write("ambient-python-config\n")
PY
printf '%s\n' '--definitely-not-a-real-curl-option' \
    > "$hostile_curl_home/.curlrc"
if (
    _close_bound_runtime_tool_fds
    PYTHONPATH="$hostile_python_home"
    CURL_HOME="$hostile_curl_home"
    HOME="$hostile_curl_home"
    BOUND_TOOL_EFFECT="$bound_tool_effect"
    export PYTHONPATH CURL_HOME HOME BOUND_TOOL_EFFECT
    _ensure_bound_runtime_tools || exit 40
    curl() {
        : > "$bound_tool_effect"
        return 1
    }
    python3() {
        : > "$bound_tool_effect"
        return 1
    }
    [ "$(_nats_monitor_url)" = "http://127.0.0.1:${NATS_MONITOR_PORT}" ] \
        || exit 41
    declare -f wait_for_port \
        | grep -Fq '/dev/tcp/127.0.0.1/' || exit 48
    declare -f _run_bound_curl_bounded \
        | grep -Fq -- '"--noproxy"' || exit 42
    declare -f _run_bound_curl_bounded \
        | grep -Fq -- '"-q"' || exit 46
    declare -f _run_bound_python | grep -Fq -- "-I -S" || exit 47
    _run_bound_python -c 'print("bound-python")' \
        | grep -Fxq bound-python || exit 43
    _run_bound_curl --version 2>/dev/null | grep -Fq curl || exit 44
    [ ! -e "$bound_tool_effect" ] || exit 45
); then
    pass "monitor helpers cannot be redirected through ambient tools or proxies"
else
    fail "monitor helpers still trust localhost, PATH functions, or proxy state"
fi

info "bound curl has one outer deadline, byte ceiling, minimal environment, and FD boundary"
bound_curl_fixture="$TMP/bound-curl-fixture.sh"
bound_curl_argv="$TMP/bound-curl.argv"
bound_curl_env="$TMP/bound-curl.env"
bound_curl_fds="$TMP/bound-curl.fds"
bound_curl_complete="$TMP/bound-curl.complete"
bound_curl_descendant="$TMP/bound-curl-descendant.pid"
bound_curl_heartbeat="$TMP/bound-curl-descendant.heartbeat"
cat > "$bound_curl_fixture" <<SH
#!/bin/sh
printf '%s\n' "\$@" > "$bound_curl_argv"
export -p > "$bound_curl_env"
if [ -d /proc/\$\$/fd ]; then
    for number in 3 190 191 192 193 194 195 196 197 205; do
        if (eval ": <&\$number") 2>/dev/null; then
            printf '%s\n' "\$number"
        fi
    done > "$bound_curl_fds"
fi
case " \$* " in
    *' /flood '*)
        flood_index=0
        while [ "\$flood_index" -lt 32 ]; do
            printf '%65536s' x
            flood_index=\$((flood_index + 1))
        done
        : > "$bound_curl_complete"
        ;;
    *' /slow-tree '*)
        /usr/bin/python3 - "$bound_curl_descendant" \
            "$bound_curl_heartbeat" <<'PY' &
import os
import pathlib
import signal
import sys
import time

if os.fork() != 0:
    raise SystemExit(0)
os.setsid()
if os.fork() != 0:
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()), encoding="ascii")
while True:
    with open(sys.argv[2], "a", encoding="ascii") as stream:
        stream.write("x")
    time.sleep(0.05)
PY
        # The current direct-curl implementation must eventually return so the
        # RED fixture cannot hang the suite indefinitely.
        /bin/sleep 3
        ;;
    *) printf 'curl fixture\n' ;;
esac
SH
chmod 500 "$bound_curl_fixture"
if (
    _close_bound_runtime_tool_fds
    exec 195< /usr/bin/python3
    exec 196< "$bound_curl_fixture"
    exec 205<> "$TMP/bound-curl-unrelated"
    BOUND_PYTHON_EXEC=/usr/bin/python3
    BOUND_CURL_EXEC="$bound_curl_fixture"
    BOUND_RUNTIME_TOOLS_READY=1
    export BOUND_PYTHON_EXEC BOUND_CURL_EXEC BOUND_RUNTIME_TOOLS_READY
    export DOCTOR_UNRELATED_SECRET=must-not-cross
    if _run_bound_curl_bounded 2 --version \
        >"$TMP/bound-curl-startup.out" 2>&1; then
        :
    else
        startup_status=$?
        printf 'bound curl startup failed with status %s\n' "$startup_status" >&2
        cat "$TMP/bound-curl-startup.out" >&2
        exit 31
    fi
    [ "$(head -n 1 "$bound_curl_argv")" = -q ] || exit 32
    ! grep -Eq '(DOCTOR_UNRELATED_SECRET|HOME|CURL_HOME|http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|ALL_PROXY)=' \
        "$bound_curl_env" || exit 33
    if [ -s "$bound_curl_fds" ]; then
        ! grep -Eq '^(190|191|192|193|194|195|197|205)$' \
            "$bound_curl_fds" || exit 34
    fi
    rm -f "$bound_curl_complete"
    if _run_bound_curl_bounded 2 /flood >/dev/null 2>&1; then
        exit 35
    fi
    [ ! -e "$bound_curl_complete" ] || exit 36
    if [ "$(uname -s)" = Linux ]; then
        rm -f "$bound_curl_descendant" "$bound_curl_heartbeat"
        started=$SECONDS
        if _run_bound_curl_bounded 1 /slow-tree >/dev/null 2>&1; then
            exit 37
        fi
        [ "$((SECONDS - started))" -le 2 ] || exit 38
        [ -s "$bound_curl_descendant" ] || exit 39
        escaped_pid=$(cat "$bound_curl_descendant")
        process_is_gone "$escaped_pid" "$bound_curl_heartbeat" || exit 40
    fi
); then
    pass "curl transport is sealed, minimal, bounded, and descendant-extinguishing"
else
    bound_curl_status=$?
    if [ -s "$bound_curl_descendant" ]; then
        bound_curl_escaped=$(cat "$bound_curl_descendant")
        if ! /bin/kill -KILL "$bound_curl_escaped" 2>/dev/null; then :; fi
    fi
    fail "curl transport lacks its complete outer boundary (status=$bound_curl_status)"
fi
unset bound_curl_fixture bound_curl_argv bound_curl_env bound_curl_fds \
    bound_curl_complete bound_curl_descendant bound_curl_heartbeat \
    bound_curl_status bound_curl_escaped

info "NATS descriptor collision retains bound storage evidence"
nats_collision_path="$TMP/nats-collision.path"
nats_collision_anchor="$TMP/nats-collision-anchor"
mkdir -m 700 "$nats_collision_anchor"
if (
    exec 193< "$nats_collision_anchor"
    NATS_DATA_DIR=""
    NATS_DATA_RECEIPT=""
    if _create_nats_data_dir >/dev/null 2>&1; then
        exit 10
    fi
    [ -n "$NATS_DATA_RECEIPT" ] && [ -d "$NATS_DATA_DIR" ] || exit 11
    printf '%s\n' "$NATS_DATA_DIR" > "$nats_collision_path"
); then
    retained_nats_dir=$(cat "$nats_collision_path")
    rmdir -- "$retained_nats_dir"
    pass "failed NATS capability binding retains its exact storage evidence"
else
    fail "descriptor collision triggered mutable-path NATS cleanup"
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
    [ "$1" != 4646 ] || return 1
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
NATS_BG_OWNER="$TEST_SHELL_PID"
NATS_BIN="$fake_nats"
NATS_PORT=1
NATS_MONITOR_PORT=2
# Consumed by nats_restart from the sourced lifecycle library.
# shellcheck disable=SC2034
IPC_TOPOLOGY=t1
NATS_DATA_DIR="$TMP/hi-nats-RST001"
mkdir -m 700 "$NATS_DATA_DIR"
_bind_nats_data_dir "$NATS_DATA_DIR"
if nats_restart; then
    restart_status=0
    replacement_pid="$NATS_BG_PID"
else
    restart_status=$?
    replacement_pid=""
fi
if _nats_descriptor_exec_supported; then
    if [ "$restart_status" -eq 0 ] \
        && [ "${#_BG_PIDS[@]}" -eq 1 ] \
        && [ "${_BG_PIDS[0]}" = "$replacement_pid" ] \
        && [ "${_BG_PID_IDENTITIES[0]}" = "boot-a:$replacement_pid" ] \
        && [ "$NATS_BG_IDENTITY" = "boot-a:$replacement_pid" ] \
        && [ "$(cat "$NATS_EXEC_PID_FILE")" = "$replacement_pid" ]; then
        pass "restart replaces rather than accumulates its process receipt"
    else
        fail "restart retained a wrapper or stale NATS PID receipt"
    fi
    if [ -n "$replacement_pid" ]; then
        if ! /bin/kill -KILL "$replacement_pid" 2>/dev/null; then :; fi
        if ! builtin wait "$replacement_pid" 2>/dev/null; then :; fi
    fi
elif [ "$restart_status" -ne 0 ] && [ ! -e "$NATS_EXEC_PID_FILE" ]; then
    pass "unsupported hosts fail before launching a NATS replacement"
else
    fail "unsupported host reached a NATS replacement launch"
fi
unset NATS_EXEC_PID_FILE
discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
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
        if ! /bin/kill -KILL "$NATS_BG_PID" 2>/dev/null; then :; fi
        if ! builtin wait "$NATS_BG_PID" 2>/dev/null; then :; fi
    fi
    if ! cleanup_all >/dev/null 2>&1; then :; fi
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
        if ! /bin/kill -KILL "$NATS_BG_PID" 2>/dev/null; then :; fi
        if ! builtin wait "$NATS_BG_PID" 2>/dev/null; then :; fi
    fi
    if ! cleanup_all >/dev/null 2>&1; then :; fi
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
NATS_BG_OWNER=""
# Consumed by nats_restart from the sourced lifecycle library.
# shellcheck disable=SC2034
NATS_BIN="$fake_effect_nats"
NATS_RESTART_EFFECT="$restart_effect"
export NATS_RESTART_EFFECT
if nats_restart; then
    replacement_pid="$NATS_BG_PID"
    /bin/sleep 0.05
    if ! /bin/kill -KILL "$replacement_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$replacement_pid" 2>/dev/null; then :; fi
    fail "restart launched after its receipt-bound storage path was retargeted"
elif [ ! -e "$restart_effect" ]; then
    pass "storage retargeting reaches no NATS launch effect"
else
    fail "restart detected retargeting only after launching NATS"
fi
discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
rm -rf -- "$foreign_nats_dir"
reset_process_state

info "NATS launch uses the already-bound storage after a pre-launch rename"
fake_prebound_nats="$TMP/fake-prebound-nats"
cat > "$fake_prebound_nats" <<'SH'
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
printf '%s\n' bound-write > "${store_dir:?}/runtime-effect"
SH
chmod +x "$fake_prebound_nats"
prebound_store="$TMP/hi-nats-PRE001"
prebound_displaced="$prebound_store.displaced"
mkdir -m 700 "$prebound_store"
NATS_DATA_DIR="$prebound_store"
_bind_nats_data_dir "$NATS_DATA_DIR"
mv -- "$prebound_store" "$prebound_displaced"
mkdir -m 700 "$prebound_store"
printf '%s\n' preserve > "$prebound_store/operator-data"
if ( _exec_nats_with_bound_store "$fake_prebound_nats" 41011 41012 \
    odysseus-e2e-00000000000000000000000000000001 ) \
    >/dev/null 2>&1; then
    prebound_status=0
else
    prebound_status=$?
fi
if _nats_descriptor_exec_supported; then
    if [ "$prebound_status" -eq 0 ] \
        && grep -Fxq bound-write "$prebound_displaced/runtime-effect" \
        && grep -Fxq preserve "$prebound_store/operator-data"; then
        pass "pre-launch replacement cannot redirect runtime storage"
    else
        fail "NATS launch reopened its mutable storage path"
    fi
elif [ "$prebound_status" -ne 0 ] \
    && [ ! -e "$prebound_displaced/runtime-effect" ] \
    && grep -Fxq preserve "$prebound_store/operator-data"; then
    pass "unsupported hosts fail before using any NATS storage path"
else
    fail "unsupported host reached mutable NATS storage"
fi
rm -rf -- "$prebound_store" "$prebound_displaced"
if command -v _close_nats_data_fds >/dev/null 2>&1; then
    _close_nats_data_fds
fi
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""

info "NATS launch rejects a symlinked executable before any effect"
symlink_target_nats="$TMP/symlink-target-nats"
symlink_nats="$TMP/symlink-nats"
symlink_effect="$TMP/symlink-nats.effect"
cat > "$symlink_target_nats" <<'SH'
#!/usr/bin/env bash
: > "${NATS_SYMLINK_EFFECT:?}"
SH
chmod +x "$symlink_target_nats"
ln -s "$symlink_target_nats" "$symlink_nats"
symlink_store="$TMP/hi-nats-LNK001"
mkdir -m 700 "$symlink_store"
NATS_DATA_DIR="$symlink_store"
_bind_nats_data_dir "$NATS_DATA_DIR"
NATS_SYMLINK_EFFECT="$symlink_effect"
export NATS_SYMLINK_EFFECT
if ( _exec_nats_with_bound_store "$symlink_nats" 41013 41014 \
    odysseus-e2e-00000000000000000000000000000002 ) \
    >/dev/null 2>&1; then
    symlink_status=0
else
    symlink_status=$?
fi
if [ "$symlink_status" -ne 0 ] && [ ! -e "$symlink_effect" ]; then
    pass "NATS executable authority is bound without following a symlink"
else
    fail "NATS launch followed a mutable executable symlink"
fi
discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
unset NATS_SYMLINK_EFFECT

info "NATS restart keeps the receipt-bound directory authoritative after exec"
fake_swap_nats="$TMP/fake-swap-nats"
swap_store="$TMP/hi-nats-SWP001"
{
    printf '%s\n' '#!/usr/bin/env bash'
    printf 'ORIGINAL_NATS_STORE=%q\n' "$swap_store"
    cat <<'SH'
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
} > "$fake_swap_nats"
chmod +x "$fake_swap_nats"
mkdir -m 700 "$swap_store"
NATS_DATA_DIR="$swap_store"
_bind_nats_data_dir "$NATS_DATA_DIR"
ORIGINAL_NATS_STORE="$NATS_DATA_DIR"
export ORIGINAL_NATS_STORE
NATS_BG_PID=""
NATS_BG_IDENTITY=""
NATS_BG_OWNER=""
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
    if ! /bin/kill -KILL "$swap_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$swap_pid" 2>/dev/null; then :; fi
fi
if _nats_descriptor_exec_supported; then
    if [ "$swap_status" -eq 0 ] \
        && [ -f "$ORIGINAL_NATS_STORE.displaced/runtime-effect" ] \
        && [ ! -e "$ORIGINAL_NATS_STORE/runtime-effect" ]; then
        pass "runtime storage writes stay on the receipt-bound directory object"
    else
        fail "post-validation name swap redirected NATS runtime storage"
    fi
elif [ "$swap_status" -ne 0 ] \
    && [ ! -e "$ORIGINAL_NATS_STORE/runtime-effect" ] \
    && [ ! -e "$ORIGINAL_NATS_STORE.displaced" ]; then
    pass "unsupported hosts fail before NATS runtime storage access"
else
    fail "unsupported host reached NATS runtime storage"
fi
_close_nats_data_fds
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
    NATS_BG_OWNER=""
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
        if ! /bin/kill -KILL "$replacement_pid" 2>/dev/null; then :; fi
        if ! builtin wait "$replacement_pid" 2>/dev/null; then :; fi
    fi
    if [ ! -e "$effect_file" ]; then
        pass "$case_name blocks launch while the $occupied_kind port is occupied"
    else
        fail "$case_name launched NATS while the $occupied_kind port was occupied"
    fi
    MOCK_OCCUPIED_PORT=""
    discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
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
NATS_BG_OWNER=""
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
    if ! /bin/kill -KILL "$correlated_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$correlated_pid" 2>/dev/null; then :; fi
fi
if [ "$correlated_status" -ne 0 ]; then
    pass "foreign health cannot certify a changed replacement identity"
else
    fail "restart accepted health after its registered process identity changed"
fi
discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
reset_process_state

info "NATS restart rejects a concurrent foreign monitor that replays identity"
foreign_health_dir="$TMP/hi-nats-FGN001"
mkdir -m 700 "$foreign_health_dir"
NATS_DATA_DIR="$foreign_health_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
NATS_BG_PID=""
NATS_BG_IDENTITY=""
NATS_BG_OWNER=""
# Consumed by nats_restart from the sourced lifecycle library.
# shellcheck disable=SC2034
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
    if ! /bin/kill -KILL "$foreign_health_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$foreign_health_pid" 2>/dev/null; then :; fi
fi
if [ "$foreign_health_status" -ne 0 ]; then
    pass "foreign monitor ownership cannot certify the registered replacement"
else
    fail "restart accepted a concurrent foreign health endpoint"
fi
discard_retained_nats_fixture "${NATS_DATA_DIR:-}"
reset_process_state

info "NATS storage cleanup ignores mutable path retargeting"
bound_nats_dir=$(mktemp -d /tmp/hi-nats-XXXXXX)
foreign_nats_dir=$(mktemp -d /tmp/operator-nats-data.XXXXXX)
printf '%s\n' keep > "$foreign_nats_dir/operator-data"
NATS_DATA_DIR="$bound_nats_dir"
if command -v _bind_nats_data_dir >/dev/null 2>&1 \
    && _bind_nats_data_dir "$bound_nats_dir"; then
    bound_nats_parent="${NATS_DATA_DIR%/*}"
    bound_nats_name="${NATS_DATA_DIR##*/}"
    NATS_DATA_DIR="$foreign_nats_dir"
    _BG_PIDS=()
    _BG_PID_IDENTITIES=()
    _BG_PID_OWNERS=()
    if ! cleanup_all \
        && [ ! -e "$bound_nats_dir" ] \
        && compgen -G \
            "$bound_nats_parent/.$bound_nats_name.cleanup-*" >/dev/null \
        && [ -f "$foreign_nats_dir/operator-data" ]; then
        pass "cleanup quarantines only the bound NATS storage directory"
    else
        fail "mutable NATS_DATA_DIR redirected cleanup or lost evidence"
    fi
else
    fail "NATS storage creation produced no immutable directory receipt"
fi
discard_retained_nats_fixture "$bound_nats_dir"
rm -rf -- "$foreign_nats_dir"
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
_close_nats_data_fds
rm -rf -- "$bound_nats_dir" "$displaced_nats_dir"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state

info "NATS cleanup quarantines its exact directory before returning failure"
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
nats_cleanup_error="$TMP/nats-cleanup.error"
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
    if cleanup_all >/dev/null 2>"$nats_cleanup_error"; then
        printf '0\n' > "$nats_cleanup_status"
    else
        printf '%s\n' "$?" > "$nats_cleanup_status"
    fi
) &
nats_cleaner_pid=$!
if ! builtin wait "$nats_cleaner_pid" 2>/dev/null; then :; fi
if ! builtin wait "$nats_racer_pid" 2>/dev/null; then :; fi
nats_recovery_path=""
for candidate in "$nats_parent/.$nats_name.cleanup-"*; do
    [ -d "$candidate" ] || continue
    nats_recovery_path=$candidate
    break
done
if [ -e "$nats_race_seen" ] \
    && [ "$(cat "$nats_cleanup_status")" -ne 0 ] \
    && grep -Fxq preserve "$bound_nats_dir/replacement-data" \
    && [ -n "$nats_recovery_path" ] \
    && grep -Fq 'operator recovery' "$nats_cleanup_error" \
    && grep -Fq "$nats_recovery_path" "$nats_cleanup_error"; then
    pass "NATS replacement and quarantined evidence survive the removal race"
else
    fail "NATS final removal raced through an unbound same-name directory"
fi
rm -rf -- "$bound_nats_dir"
for nats_quarantine in "$nats_parent/.$nats_name.cleanup-"*; do
    [ -e "$nats_quarantine" ] || continue
    rm -rf -- "$nats_quarantine"
done
unset nats_cleanup_error nats_recovery_path candidate
_close_nats_data_fds
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state

info "retained NATS cleanup does not traverse or partially delete descendants"
deep_nats_dir=$(mktemp -d /tmp/hi-nats-XXXXXX)
NATS_DATA_DIR="$deep_nats_dir"
_bind_nats_data_dir "$NATS_DATA_DIR"
deep_cursor="$deep_nats_dir"
deep_relative=""
for depth in $(seq 1 65); do
    deep_cursor="$deep_cursor/d$depth"
    deep_relative="${deep_relative:+$deep_relative/}d$depth"
    mkdir "$deep_cursor"
done
printf '%s\n' retain > "$deep_cursor/evidence"
_BG_PIDS=()
_BG_PID_IDENTITIES=()
_BG_PID_OWNERS=()
if cleanup_all >/dev/null 2>&1; then
    deep_bound_rejected=0
else
    deep_bound_rejected=1
fi
deep_parent="${deep_nats_dir%/*}"
deep_name="${deep_nats_dir##*/}"
deep_quarantine=""
for candidate in "$deep_parent/.$deep_name.cleanup-"*; do
    [ -d "$candidate" ] || continue
    deep_quarantine="$candidate"
    break
done
if [ "$deep_bound_rejected" -eq 1 ] \
    && [ ! -e "$deep_nats_dir" ] \
    && [ -f "$deep_quarantine/$deep_relative/evidence" ] \
    && [ -n "$NATS_DATA_RECEIPT" ]; then
    pass "quarantined cleanup retains the complete descendant tree"
else
    fail "cleanup traversed or partially deleted retained NATS evidence"
fi
discard_retained_nats_fixture "$deep_nats_dir"
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
            else
                parent=${store%/*}
                name=${store##*/}
                quarantine=
                for candidate in "$parent/.$name.cleanup-"*; do
                    [ -d "$candidate" ] || continue
                    quarantine=$candidate
                    break
                done
                if [ -n "$quarantine" ] \
                    && [ -f "$quarantine/bind-mount/evidence" ] \
                    && [ -n "$NATS_DATA_RECEIPT" ]; then
                    result=0
                else
                    result=18
                fi
            fi
            [ -n "${quarantine:-}" ] || exit 19
            umount "$quarantine/bind-mount" || exit 20
            rm -rf -- "$quarantine" "$store" "$fixture"
            exit "$result"
        ' bash "$ROOT"; then
        pass "same-device bind mount is retained through fd-bound mount identity"
    else
        fail "isolated same-device bind-mount cleanup fixture failed"
    fi
elif [ "$(uname -s)" = Linux ]; then
    fail "Linux CI lacks the isolated mount authority required for cleanup proof"
else
    pass "isolated bind-mount proof is Linux-only"
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
            if ! /bin/kill -KILL "$shared_pid" 2>/dev/null; then :; fi
            pass "Darwin retains an unsignallable subprocess receipt"
        else
            if ! /bin/kill -KILL "$shared_pid" 2>/dev/null; then :; fi
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
        if ! /bin/kill -KILL "$shared_pid" 2>/dev/null; then :; fi
        fail "subprocess process receipts did not converge in the parent"
    fi
else
    fail "a subprocess could not publish its direct-child receipt"
fi
reset_process_state

if [ "$(uname -s)" = Linux ]; then
    info "cgroup containment extinguishes a successful leader's detached tree"
    if (
        unset -f sleep wait kill
        eval "$PRODUCTION_SERVICE_CONTAINMENT_OP"
        eval "$PRODUCTION_PREPARE_SERVICE_CONTAINMENT"
        eval "$PRODUCTION_JOIN_SERVICE_CONTAINMENT"
        eval "$PRODUCTION_CONTAINMENT_CONTAINS"
        eval "$PRODUCTION_CONTAINMENT_STATE"
        eval "$PRODUCTION_KILL_SERVICE_CONTAINMENT"
        eval "$PRODUCTION_REMOVE_SERVICE_CONTAINMENT"
        eval "$PRODUCTION_WAIT_CONTAINMENT_MEMBER"
        eval "$PRODUCTION_EXTINGUISH_CONTAINMENT"
        eval "$PRODUCTION_RETIRE_CONTAINMENT"
        eval "$PRODUCTION_PROCESS_RECEIPT"
        eval "$PRODUCTION_SIGNAL_BOUND_PROCESS"
        reset_process_state
        _ensure_process_receipt_store || exit 20
        if ! _prepare_service_containment >/dev/null 2>&1; then
            exit 77
        fi
        proof_containment="$PENDING_SERVICE_CONTAINMENT"
        containment_path=$(_run_bound_python - "$proof_containment" <<'PY'
import base64
import json
import os
import sys

encoded = sys.argv[1][4:]
value = json.loads(
    base64.b64decode(encoded + "=" * (-len(encoded) % 4), altchars=b"-_")
)
print(os.path.join(value["parent"], value["name"]))
PY
        ) || exit 78
        containment_parent=${containment_path%/*}
        containment_name=${containment_path##*/}
        proof_descendant="$TMP/contained-double-fork.pid"
        proof_release="$TMP/contained-leader.release"
        proof_leader=""
        cleanup_containment_proof() {
            if [ -n "$proof_containment" ]; then
                if ! _retire_service_containment "$proof_containment" \
                    >/dev/null 2>&1; then :; fi
            fi
            if [ -n "$proof_leader" ]; then
                if ! /bin/kill -KILL "$proof_leader" 2>/dev/null; then :; fi
                if ! builtin wait "$proof_leader" 2>/dev/null; then :; fi
            fi
            reset_process_state
        }
        trap cleanup_containment_proof EXIT
        (
            _join_service_containment \
                "$proof_containment" "${BASHPID:-$$}" || exit 21
            python3 - "$proof_descendant" <<'PY' &
import os
import pathlib
import sys
import time


if os.fork() != 0:
    os._exit(0)
os.setsid()
if os.fork() != 0:
    os._exit(0)
pathlib.Path(sys.argv[1]).write_text(str(os.getpid()), encoding="ascii")
while True:
    time.sleep(10)
PY
            for _ in $(seq 1 100); do
                [ -s "$proof_descendant" ] && break
                /bin/sleep 0.01
            done
            [ -s "$proof_descendant" ] || exit 22
            while [ ! -e "$proof_release" ]; do
                /bin/sleep 0.01
            done
            exit 0
        ) &
        proof_leader=$!
        register_pid "$proof_leader" "$proof_containment" || exit 23
        for _ in $(seq 1 100); do
            [ -s "$proof_descendant" ] && break
            /bin/sleep 0.01
        done
        [ -s "$proof_descendant" ] || exit 24
        detached_pid=$(cat "$proof_descendant")
        [[ "$detached_pid" =~ ^[1-9][0-9]*$ ]] || exit 25
        /bin/kill -0 "$detached_pid" 2>/dev/null || exit 26
        : > "$proof_release"
        for _ in $(seq 1 100); do
            _process_identity_status "$proof_leader" \
                "$REGISTERED_PROCESS_IDENTITY" "$REGISTERED_PROCESS_OWNER" \
                || break
            /bin/sleep 0.01
        done
        if _process_identity_status "$proof_leader" \
            "$REGISTERED_PROCESS_IDENTITY" "$REGISTERED_PROCESS_OWNER"; then
            exit 27
        fi
        containment_cleanup_error="$TMP/containment-cleanup.error"
        if cleanup_pids 2>"$containment_cleanup_error"; then
            exit 28
        fi
        for _ in $(seq 1 100); do
            /bin/kill -0 "$detached_pid" 2>/dev/null || break
            /bin/sleep 0.01
        done
        containment_quarantine=""
        for candidate in \
            "$containment_parent/.${containment_name}.cleanup-"*; do
            [ -d "$candidate" ] || continue
            containment_quarantine=$candidate
            break
        done
        if /bin/kill -0 "$detached_pid" 2>/dev/null \
            || [ "${#_BG_PIDS[@]}" -ne 1 ] \
            || [ "${_BG_PROCESS_CONTAINMENTS[0]:-}" != "$proof_containment" ] \
            || [ -e "$containment_path" ] \
            || [ -z "$containment_quarantine" ] \
            || ! grep -q 'retained for operator recovery' \
                "$containment_cleanup_error"; then
            exit 29
        fi
        # This is an isolated proof fixture. Production deliberately retains
        # the empty cgroup quarantine for an operator; the fixture removes its
        # exact observed quarantine after the assertion.
        rmdir "$containment_quarantine" || exit 30
        proof_containment=""
        proof_leader=""
        trap - EXIT
        reset_process_state
    ); then
        pass "cgroup.kill proves extinction while mutable-name cleanup retains recovery evidence"
    else
        containment_proof_status=$?
        if [ "$containment_proof_status" -eq 77 ]; then
            fail "Linux CI lacks delegated cgroup authority for the required tree-extinction proof"
        else
            fail "Linux cgroup containment did not extinguish the detached process tree"
        fi
    fi
fi

info "service exec closes every unrelated inherited descriptor"
unrelated_fd_output="$TMP/unrelated-fd.out"
cat > "$TMP/unrelated-fd-service.sh" <<SH
#!/bin/sh
printf 'ready\n' > "$unrelated_fd_output"
if eval ': <&205' 2>/dev/null; then
    printf '205\n' >> "$unrelated_fd_output"
fi
SH
chmod 700 "$TMP/unrelated-fd-service.sh"
exec 205<> "$TMP/unrelated-fd-source"
if _bind_service_executable "$TMP/unrelated-fd-service.sh"; then
    (
        _exec_service_without_harness_capabilities \
            "$TMP/unrelated-fd-service.sh" "$SERVICE_EXECUTABLE_RECEIPT"
    ) >/dev/null 2>&1 &
    unrelated_fd_child=$!
    _close_service_executable_fd
    if ! builtin wait "$unrelated_fd_child" 2>/dev/null; then :; fi
else
    : > "$unrelated_fd_output"
fi
exec 205<&-
if [ "$(cat "$unrelated_fd_output" 2>/dev/null)" = ready ]; then
    pass "service exec inherits only stdio and its exact executable"
else
    fail "service exec leaked an unrelated caller descriptor"
fi
unset unrelated_fd_output unrelated_fd_child

info "service children cannot inherit harness receipt capabilities"
fd_leak_bin="$TMP/fd-leak-bin"
fd_leak_output="$TMP/fd-leak.out"
fd_leak_nats="$TMP/hi-nats-FDLEAK"
mkdir -m 700 "$fd_leak_bin" "$fd_leak_nats"
cat > "$TMP/fd-leak-service.sh" <<SH
#!/bin/sh
printf 'ready\n' > "$fd_leak_output"
for descriptor in 190 191 192 193 194 205; do
    if eval ": <&\$descriptor" 2>/dev/null; then
        printf '%s\n' "\$descriptor" >> "$fd_leak_output"
    fi
done
exec /bin/sleep 30
SH
chmod 700 "$TMP/fd-leak-service.sh"
for fd_leak_name in Agamemnon_server hello_myrmidon; do
    cp "$TMP/fd-leak-service.sh" "$fd_leak_bin/$fd_leak_name"
    chmod 700 "$fd_leak_bin/$fd_leak_name"
done
_ensure_process_receipt_store
NATS_DATA_DIR="$fd_leak_nats"
_bind_nats_data_dir "$NATS_DATA_DIR"
exec 205<> "$TMP/fd-leak-unrelated"
register_pid() {
    FD_LEAK_CHILD_PID="$1"
    FD_LEAK_CONTAINMENT="${2:-}"
    REGISTERED_PROCESS_IDENTITY="fixture:$1"
    REGISTERED_PROCESS_OWNER="${BASHPID:-$$}"
    return 0
}
wait_for() { return 0; }
_wait_for_registered_myrmidon() { return 0; }
_bound_process_signaling_supported() { return 0; }
_prepare_service_containment() {
    PENDING_SERVICE_CONTAINMENT=fixture:kernel-tree
}
_join_service_containment() {
    printf '%s|%s\n' "$1" "$2" > "$FD_LEAK_CONTAINMENT_LOG"
}
PATH="$fd_leak_bin:/usr/bin:/bin"
ODYSSEUS_ROOT="$TMP/absent-service-root"
FD_LEAK_OUTPUT="$fd_leak_output"
FD_LEAK_CONTAINMENT_LOG="$TMP/fd-leak-containment.log"
FD_LEAK_CONTAINMENT=""
export PATH FD_LEAK_OUTPUT ODYSSEUS_ROOT FD_LEAK_CONTAINMENT_LOG
fd_leak_failed=0
fd_leak_reason=""
: > "$fd_leak_output"
FD_LEAK_CHILD_PID=""
if ! start_myrmidon_bg; then
    fd_leak_failed=1
    fd_leak_reason="$fd_leak_reason start_myrmidon_bg failed"
fi
fd_leak_waits=0
while [ "$fd_leak_waits" -lt 50 ]; do
    [ -s "$fd_leak_output" ] && break
    /bin/sleep 0.1
    fd_leak_waits=$((fd_leak_waits + 1))
done
if [ "$(cat "$fd_leak_output" 2>/dev/null)" != ready ]; then
    fd_leak_failed=1
    fd_leak_reason="$fd_leak_reason start_myrmidon_bg output=$(tr '\n' ',' < "$fd_leak_output")"
fi
if [ "$FD_LEAK_CONTAINMENT" != fixture:kernel-tree ] \
    || ! grep -Eq '^fixture:kernel-tree\|[1-9][0-9]*$' \
        "$FD_LEAK_CONTAINMENT_LOG" 2>/dev/null; then
    fd_leak_failed=1
    fd_leak_reason="$fd_leak_reason service launch was not containment-bound"
fi
if ! declare -f start_agamemnon_bg \
    | grep -Fq '_exec_service_without_harness_capabilities'; then
    fd_leak_failed=1
    fd_leak_reason="$fd_leak_reason Agamemnon launch omits the capability boundary"
fi
if [ -n "$FD_LEAK_CHILD_PID" ]; then
    if ! /bin/kill -KILL "$FD_LEAK_CHILD_PID" 2>/dev/null; then :; fi
    if ! builtin wait "$FD_LEAK_CHILD_PID" 2>/dev/null; then :; fi
fi
exec 205<&-
if [ "$fd_leak_failed" -eq 0 ]; then
    pass "contained service children receive no harness receipt or storage descriptors"
else
    fail "a service child inherited harness receipt or storage authority: $fd_leak_reason"
fi
_close_nats_data_fds
rm -rf -- "$fd_leak_nats"
NATS_DATA_DIR=""
NATS_DATA_RECEIPT=""
reset_process_state

if [ "$(uname -s)" = Linux ]; then
    info "Agamemnon readiness accepts only an exact loopback peer endpoint"
    socket_fixture="$TMP/service-socket-fixture.py"
    socket_ready="$TMP/service-socket.ready"
    cat > "$socket_fixture" <<'PY'
import fcntl
import socket
import struct
import sys
import time


mode, ready_path = sys.argv[1:]
if mode == "loopback":
    address = "127.0.0.1"
else:
    address = None
    for _, name in socket.if_nameindex():
        candidate = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            packed = fcntl.ioctl(
                candidate.fileno(),
                0x8915,  # SIOCGIFADDR
                struct.pack("256s", name.encode("ascii")[:15]),
            )
        except OSError:
            continue
        finally:
            candidate.close()
        value = socket.inet_ntoa(packed[20:24])
        if not value.startswith("127."):
            address = value
            break
    if address is None:
        raise SystemExit(77)
listener = socket.socket()
listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
listener.bind((address, 0))
listener.listen(1)
client = socket.socket()
client.connect(listener.getsockname())
accepted, _ = listener.accept()
with open(ready_path, "w", encoding="ascii") as stream:
    stream.write(f"{listener.getsockname()[1]}\n")
while True:
    time.sleep(10)
PY
    rm -f "$socket_ready"
    /usr/bin/python3 -I -S "$socket_fixture" loopback "$socket_ready" &
    loopback_socket_pid=$!
    for _ in $(seq 1 100); do
        [ -s "$socket_ready" ] && break
        /bin/sleep 0.01
    done
    loopback_socket_port=""
    if ! loopback_socket_port=$(cat "$socket_ready" 2>/dev/null); then :; fi
    loopback_ready=0
    if [[ "$loopback_socket_port" =~ ^[1-9][0-9]*$ ]] \
        && _service_connected_to_port \
            "$loopback_socket_port" "$loopback_socket_pid" 2; then
        loopback_ready=1
    fi
    if ! /bin/kill -KILL "$loopback_socket_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$loopback_socket_pid" 2>/dev/null; then :; fi

    rm -f "$socket_ready"
    /usr/bin/python3 -I -S "$socket_fixture" nonloopback "$socket_ready" &
    nonloopback_socket_pid=$!
    for _ in $(seq 1 100); do
        [ -s "$socket_ready" ] && break
        ! /bin/kill -0 "$nonloopback_socket_pid" 2>/dev/null && break
        /bin/sleep 0.01
    done
    nonloopback_socket_status=2
    nonloopback_socket_port=""
    if ! nonloopback_socket_port=$(cat "$socket_ready" 2>/dev/null); then :; fi
    if ! /bin/kill -0 "$nonloopback_socket_pid" 2>/dev/null; then
        builtin wait "$nonloopback_socket_pid" 2>/dev/null
        nonloopback_socket_status=$?
    elif [[ "$nonloopback_socket_port" =~ ^[1-9][0-9]*$ ]]; then
        if _service_connected_to_port \
            "$nonloopback_socket_port" "$nonloopback_socket_pid" 2; then
            nonloopback_socket_status=1
        else
            nonloopback_socket_status=$?
            [ "$nonloopback_socket_status" -eq 1 ] \
                && nonloopback_socket_status=0
        fi
    fi
    if ! /bin/kill -KILL "$nonloopback_socket_pid" 2>/dev/null; then :; fi
    if ! builtin wait "$nonloopback_socket_pid" 2>/dev/null; then :; fi
    if [ "$loopback_ready" -eq 1 ] \
        && [ "$nonloopback_socket_status" -eq 0 ]; then
        pass "same-port non-loopback sockets cannot satisfy readiness"
    elif [ "$nonloopback_socket_status" -eq 77 ]; then
        fail "Linux fixture has no non-loopback interface for readiness proof"
    else
        fail "readiness ignored the remote endpoint address"
    fi
    unset socket_fixture socket_ready loopback_socket_pid \
        loopback_socket_port loopback_ready nonloopback_socket_pid \
        nonloopback_socket_port nonloopback_socket_status
else
    pass "same-port non-loopback readiness proof is Linux-only"
fi

summary
exit_code
