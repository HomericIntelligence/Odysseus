#!/usr/bin/env bash
# Prove retired remote-topology entry points make no local or remote call.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

fixture_prefix="${TMPDIR:-/tmp}"
fixture_prefix="${fixture_prefix%/}/odysseus-hermes-hub-retired."
fixture_root=""

cleanup_fixture() {
    local initial_status="$1" suffix cleanup_status=0
    trap - EXIT
    suffix="${fixture_root#"$fixture_prefix"}"
    if [ -z "$fixture_root" ] || [ "$suffix" = "$fixture_root" ] \
        || [ -z "$suffix" ] || [ ! -d "$fixture_root" ] \
        || [ -L "$fixture_root" ]; then
        printf 'ERROR: refusing unsafe Hermes fixture cleanup: %s\n' \
            "$fixture_root" >&2
        cleanup_status=1
    else
        case "$suffix" in
            *[!A-Za-z0-9]*)
                printf 'ERROR: refusing unsafe Hermes fixture cleanup: %s\n' \
                    "$fixture_root" >&2
                cleanup_status=1
                ;;
            *)
                if ! rm -rf -- "$fixture_root" || \
                   [ -e "$fixture_root" ] || [ -L "$fixture_root" ]; then
                    printf 'ERROR: failed to remove Hermes fixture: %s\n' \
                        "$fixture_root" >&2
                    cleanup_status=1
                fi
                ;;
        esac
    fi
    if [ "${ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE:-false}" = true ]; then
        printf '%s\n' 'ERROR: injected Hermes fixture cleanup failure' >&2
        cleanup_status=1
    fi
    if [ "$initial_status" -ne 0 ]; then
        exit "$initial_status"
    fi
    exit "$cleanup_status"
}

if ! fixture_root="$(mktemp -d "${fixture_prefix}XXXXXX")" \
    || [ ! -d "$fixture_root" ] || [ -L "$fixture_root" ]; then
    printf '%s\n' 'ERROR: could not create a safe Hermes fixture' >&2
    exit 1
fi
trap 'cleanup_fixture "$?"' EXIT

if [ "${ODYSSEUS_TEST_CLEANUP_PROBE:-false}" = true ]; then
    exit 0
fi

fixture_bin="$fixture_root/bin"
mkdir -p "$fixture_bin"
for tool in curl podman sleep ssh tailscale; do
    cat > "$fixture_bin/$tool" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${0##*/}" >> "${ODYSSEUS_TEST_SIDE_EFFECT_LOG:?}"
exit 99
EOF
    chmod +x "$fixture_bin/$tool"
done

info "retired remote-topology entry points fail before external effects"
for script in \
    e2e/start-hermes-hub.sh \
    e2e/run-hermes-hub-e2e.sh \
    e2e/run-crosshost-e2e.sh; do
    effect_log="$fixture_root/$(basename "$script").effects"
    if ODYSSEUS_TEST_SIDE_EFFECT_LOG="$effect_log" \
       WORKER_HOST_IP=192.0.2.10 CONTROL_HOST_IP=192.0.2.11 \
       PATH="$fixture_bin:/usr/bin:/bin" \
       bash "$ROOT/$script" > "$fixture_root/$(basename "$script").out" 2>&1; then
        fail "$script reported success"
    elif [ -e "$effect_log" ]; then
        fail "$script invoked an external effect"
    elif grep -Eqi 'unavailable|retired' "$fixture_root/$(basename "$script").out"; then
        pass "$script fails closed without external effects"
    else
        fail "$script did not explain that the topology is unavailable"
    fi
done

info "fixture cleanup failures propagate after safe removal"
probe_parent="$fixture_root/cleanup-probe"
mkdir -p "$probe_parent"
set +e
TMPDIR="$probe_parent" \
ODYSSEUS_TEST_CLEANUP_PROBE=true \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=true \
    "$BASH" "$0" >"$fixture_root/cleanup-probe.out" 2>&1
probe_status=$?
set -e
if [ "$probe_status" -ne 0 ] \
    && ! find "$probe_parent" -mindepth 1 -maxdepth 1 \
        -name 'odysseus-hermes-hub-retired.*' -print -quit | grep -q .; then
    pass "a cleanup failure changes a successful test result to failure"
else
    fail "a fixture cleanup failure was hidden or left an unverified path"
fi

summary
exit_code
