#!/usr/bin/env bash
# Hermetic failure and idempotency checks for the local stack teardown.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

fixture_prefix="${TMPDIR:-/tmp}"
fixture_prefix="${fixture_prefix%/}/odysseus-teardown."
fixture_root=""
if ! fixture_root="$(mktemp -d "${fixture_prefix}XXXXXX")" \
   || [ ! -d "$fixture_root" ] || [ -L "$fixture_root" ]; then
    printf '%s\n' 'ERROR: could not create a safe teardown fixture' >&2
    exit 1
fi
fixture_bin="$fixture_root/bin"
mkdir -p "$fixture_bin"
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
        printf 'ERROR: failed to remove teardown fixture: %s\n' \
            "$fixture_root" >&2
    fi
    if [ "$initial_status" -ne 0 ]; then
        exit "$initial_status"
    fi
    exit "$cleanup_status"
}
trap 'cleanup_fixture "$?"' EXIT

cat > "$fixture_bin/podman" <<'EOF'
#!/bin/bash
printf 'podman %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
case "${1:-} ${2:-}" in
    "compose version")
        [ "${ODYSSEUS_TEST_COMPOSE_PROBE:-ok}" = ok ] && exit 0
        exit 125
        ;;
    "compose -f")
        [ "${ODYSSEUS_TEST_COMPOSE_DOWN:-ok}" = ok ] && exit 0
        exit 17
        ;;
    "compose --project-name")
        if [ "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" = unbound-project ]; then
            : > "${ODYSSEUS_TEST_UNBOUND_MARKER:?}"
        fi
        [ "${ODYSSEUS_TEST_COMPOSE_DOWN:-ok}" = ok ] && exit 0
        exit 17
        ;;
    "ps -a")
        case "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" in
            absent) exit 0 ;;
            probe-error) exit 125 ;;
            removable)
                [ -e "${ODYSSEUS_TEST_CONTAINER_MARKER:?}" ] || \
                    printf '%s\n' odysseus-agamemnon-1
                exit 0
                ;;
            remove-error|remains)
                printf '%s\n' odysseus-agamemnon-1
                exit 0
                ;;
            partial-match)
                printf '%s\n' customer-odysseus-backup
                exit 0
                ;;
        esac
        ;;
    "container exists")
        case "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" in
            probe-error)
                [ "${3:-}" = odysseus-agamemnon-1 ] && exit 125
                exit 1
                ;;
            removable|foreign)
                [ "${3:-}" = odysseus-agamemnon-1 ] \
                    || [ "${3:-}" = "$(printf '%064d' 0)" ] \
                    || exit 1
                [ -e "${ODYSSEUS_TEST_CONTAINER_MARKER:?}" ] && exit 1
                exit 0
                ;;
            remove-error|remains)
                if [ "${3:-}" = odysseus-agamemnon-1 ] \
                    || [ "${3:-}" = "$(printf '%064d' 0)" ]; then
                    exit 0
                fi
                exit 1
                ;;
            absent-then-present|absent-then-error)
                [ "${3:-}" = odysseus-agamemnon-1 ] || exit 1
                if [ ! -e "${ODYSSEUS_TEST_CONTAINER_PROBE_MARKER:?}" ]; then
                    : > "$ODYSSEUS_TEST_CONTAINER_PROBE_MARKER"
                    exit 1
                fi
                [ "$ODYSSEUS_TEST_CONTAINER_MODE" = absent-then-present ] \
                    && exit 0
                exit 125
                ;;
            absent|partial-match|unbound-project) exit 1 ;;
        esac
        ;;
    "inspect --format")
        case "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" in
            removable|remove-error|remains|foreign)
                target=${4:-}
                [ "$target" = odysseus-agamemnon-1 ] \
                    || [ "$target" = "$(printf '%064d' 0)" ] \
                    || exit 125
                if [[ "${3:-}" == *Config.Labels* ]]; then
                    if [ "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" = foreign ]; then
                        printf '%064d|/odysseus-agamemnon-1|foreign|agamemnon||\n' 0
                    else
                        printf '%064d|/odysseus-agamemnon-1|odysseus|agamemnon||\n' 0
                    fi
                else
                    printf '%064d\n' 0
                fi
                exit 0
                ;;
        esac
        exit 125
        ;;
    "rm -f")
        case "${ODYSSEUS_TEST_CONTAINER_MODE:-absent}" in
            remove-error) exit 18 ;;
            removable|foreign) : > "${ODYSSEUS_TEST_CONTAINER_MARKER:?}" ;;
        esac
        exit 0
        ;;
    "network exists")
        case "${ODYSSEUS_TEST_NETWORK_MODE:-absent}" in
            absent) exit 1 ;;
            probe-error) exit 125 ;;
            removable)
                [ "${3:-}" = odysseus_homeric-mesh ] \
                    || [ "${3:-}" = "$(printf '1%.0s' {1..64})" ] \
                    || exit 1
                [ -e "${ODYSSEUS_TEST_NETWORK_MARKER:?}" ] && exit 1
                exit 0
                ;;
            remove-error|remains)
                [ "${3:-}" = odysseus_homeric-mesh ] \
                    || [ "${3:-}" = "$(printf '1%.0s' {1..64})" ] \
                    || exit 1
                exit 0
                ;;
            absent-then-present|absent-then-error)
                [ "${3:-}" = odysseus_homeric-mesh ] || exit 1
                if [ ! -e "${ODYSSEUS_TEST_NETWORK_PROBE_MARKER:?}" ]; then
                    : > "$ODYSSEUS_TEST_NETWORK_PROBE_MARKER"
                    exit 1
                fi
                [ "$ODYSSEUS_TEST_NETWORK_MODE" = absent-then-present ] \
                    && exit 0
                exit 125
                ;;
        esac
        ;;
    "network inspect")
        case "${ODYSSEUS_TEST_NETWORK_MODE:-absent}" in
            removable|remove-error|remains)
                [ "${5:-}" = odysseus_homeric-mesh ] \
                    || [ "${5:-}" = "$(printf '1%.0s' {1..64})" ] \
                    || exit 125
                printf '%s|odysseus_homeric-mesh|odysseus|homeric-mesh||\n' \
                    "$(printf '1%.0s' {1..64})"
                exit 0
                ;;
        esac
        exit 125
        ;;
    "network rm")
        case "${ODYSSEUS_TEST_NETWORK_MODE:-absent}" in
            remove-error) exit 19 ;;
            removable) : > "${ODYSSEUS_TEST_NETWORK_MARKER:?}" ;;
        esac
        exit 0
        ;;
esac
exit 98
EOF

cat > "$fixture_bin/docker" <<'EOF'
#!/bin/bash
printf 'docker %s\n' "$*" >> "${ODYSSEUS_TEST_EFFECT_LOG:?}"
case "${1:-} ${2:-}" in
    "compose version"|"compose --project-name") exit 0 ;;
    "container inspect"|"network inspect") exit 1 ;;
    "ps -a"|"network ls") exit 0 ;;
esac
exit 98
EOF
chmod +x "$fixture_bin/podman" "$fixture_bin/docker"

run_teardown() {
    local case_name="$1"
    shift
    ODYSSEUS_TEST_EFFECT_LOG="$fixture_root/$case_name.effects" \
    ODYSSEUS_TEST_CONTAINER_MARKER="$fixture_root/$case_name.container-removed" \
    ODYSSEUS_TEST_NETWORK_MARKER="$fixture_root/$case_name.network-removed" \
    ODYSSEUS_TEST_CONTAINER_PROBE_MARKER="$fixture_root/$case_name.container-probed" \
    ODYSSEUS_TEST_NETWORK_PROBE_MARKER="$fixture_root/$case_name.network-probed" \
    ODYSSEUS_TEST_UNBOUND_MARKER="$fixture_root/$case_name.unbound-removed" \
    COMPOSE_FILE="$fixture_root/compose.yml" \
    PATH="$fixture_bin:/usr/bin:/bin" \
        "$@" "$BASH" "$ROOT/e2e/teardown.sh" \
        > "$fixture_root/$case_name.out" 2>&1
}

info "absent direct resources keep teardown idempotent"
if run_teardown absent env \
    ODYSSEUS_TEST_CONTAINER_MODE=absent \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    if grep -Fq 'Done.' "$fixture_root/absent.out"; then
        pass "absent containers and network produce successful teardown"
    else
        fail "successful absent-resource teardown omitted completion"
    fi
else
    fail "absent containers or network produced a teardown failure"
fi

info "initially absent reserved names are unconditionally final-probed"
if run_teardown late-container env \
    ODYSSEUS_TEST_CONTAINER_MODE=absent-then-present \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    fail "an absent-to-present reserved container reported successful teardown"
elif grep -Eqi 'replacement|appeared|reserved name' \
        "$fixture_root/late-container.out" \
     && ! grep -q '^podman rm -f ' "$fixture_root/late-container.effects" \
     && ! grep -Fq 'Done.' "$fixture_root/late-container.out"; then
    pass "a late reserved-name container is preserved and prevents completion"
else
    fail "teardown missed or mutated an absent-to-present reserved container"
fi

if run_teardown late-network env \
    ODYSSEUS_TEST_CONTAINER_MODE=absent \
    ODYSSEUS_TEST_NETWORK_MODE=absent-then-present; then
    fail "an absent-to-present reserved network reported successful teardown"
elif grep -Eqi 'replacement|appeared|reserved network' \
        "$fixture_root/late-network.out" \
     && ! grep -q '^podman network rm ' "$fixture_root/late-network.effects" \
     && ! grep -Fq 'Done.' "$fixture_root/late-network.out"; then
    pass "a late reserved-name network is preserved and prevents completion"
else
    fail "teardown missed or mutated an absent-to-present reserved network"
fi

if run_teardown late-probe-errors env \
    ODYSSEUS_TEST_CONTAINER_MODE=absent-then-error \
    ODYSSEUS_TEST_NETWORK_MODE=absent-then-error; then
    fail "final reserved-name probe errors reported successful teardown"
elif grep -Fqi 'reserved name' "$fixture_root/late-probe-errors.out" \
     && grep -Fqi 'reserved network' "$fixture_root/late-probe-errors.out" \
     && ! grep -q '^podman rm -f ' "$fixture_root/late-probe-errors.effects" \
     && ! grep -q '^podman network rm ' "$fixture_root/late-probe-errors.effects" \
     && ! grep -Fq 'Done.' "$fixture_root/late-probe-errors.out"; then
    pass "final container and network probe errors fail closed without mutation"
else
    fail "teardown swallowed a final reserved-name probe error"
fi

if run_teardown removable env \
    ODYSSEUS_TEST_CONTAINER_MODE=removable \
    ODYSSEUS_TEST_NETWORK_MODE=removable; then
    if [ -e "$fixture_root/removable.container-removed" ] \
       && [ -e "$fixture_root/removable.network-removed" ] \
       && grep -Fq 'Done.' "$fixture_root/removable.out"; then
        pass "successful direct-resource cleanup remains successful"
    else
        fail "successful direct-resource cleanup omitted a removal result"
    fi
else
    fail "successful direct-resource cleanup reported failure"
fi

info "cleanup is limited to the exact stack-owned container names"
if run_teardown unrelated-name env \
    ODYSSEUS_TEST_CONTAINER_MODE=partial-match \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    if grep -Fq 'podman rm -f customer-odysseus-backup' \
        "$fixture_root/unrelated-name.effects"; then
        fail "teardown removed an unrelated partial-name container"
    else
        pass "an unrelated partial-name container is not a cleanup target"
    fi
else
    fail "an unrelated partial-name container made owned cleanup fail"
fi

info "ambient Compose scope cannot broaden exact cleanup"
if COMPOSE_PROJECT_NAME=foreign-project \
    run_teardown canonical-scope env \
        COMPOSE_FILE="$fixture_root/foreign-compose.yml" \
        ODYSSEUS_TEST_CONTAINER_MODE=absent \
        ODYSSEUS_TEST_NETWORK_MODE=absent; then
    if ! grep -q '^podman compose ' "$fixture_root/canonical-scope.effects" \
       && ! grep -q '^docker compose ' "$fixture_root/canonical-scope.effects"; then
        pass "caller-controlled Compose inputs reach no teardown effect"
    else
        fail "teardown delegated destructive scope to ambient Compose inputs"
    fi
else
    fail "ambient Compose inputs made exact idempotent cleanup fail"
fi

info "a foreign container at a reserved name stops every destructive effect"
if run_teardown foreign-name env \
    ODYSSEUS_TEST_CONTAINER_MODE=foreign \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    fail "a foreign same-name container reported successful teardown"
elif grep -Eqi 'foreign|ownership' "$fixture_root/foreign-name.out" \
     && ! grep -q '^podman rm -f ' "$fixture_root/foreign-name.effects" \
     && ! grep -q '^podman compose .* down ' \
        "$fixture_root/foreign-name.effects"; then
    pass "foreign same-name state is preserved before teardown"
else
    fail "teardown mutated foreign same-name state or lost its diagnostic"
fi

info "an unbound same-project resource is outside teardown authority"
if run_teardown unbound-project env \
    ODYSSEUS_TEST_CONTAINER_MODE=unbound-project \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    if [ ! -e "$fixture_root/unbound-project.unbound-removed" ] \
       && ! grep -q '^podman compose .* down ' \
            "$fixture_root/unbound-project.effects"; then
        pass "cleanup leaves project-labeled resources outside exact receipts untouched"
    else
        fail "teardown deleted an unbound same-project resource"
    fi
else
    fail "an unbound same-project resource made exact cleanup fail"
fi

info "Compose capability is outside exact cleanup authority"
if run_teardown compose-probe env \
    ODYSSEUS_TEST_COMPOSE_PROBE=error \
    ODYSSEUS_TEST_CONTAINER_MODE=absent \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    if ! grep -q ' compose ' "$fixture_root/compose-probe.effects"; then
        pass "exact cleanup does not depend on or invoke Compose"
    else
        fail "exact cleanup still invoked Compose"
    fi
else
    fail "an unused Compose provider blocked exact cleanup"
fi

if run_teardown container-probe env \
    ODYSSEUS_TEST_CONTAINER_MODE=probe-error \
    ODYSSEUS_TEST_NETWORK_MODE=absent; then
    fail "a container inventory probe error reported success"
elif grep -Fqi 'container' "$fixture_root/container-probe.out"; then
    pass "a container inventory probe error remains a failure"
else
    fail "a container inventory probe error omitted its diagnostic"
fi

if run_teardown network-probe env \
    ODYSSEUS_TEST_CONTAINER_MODE=absent \
    ODYSSEUS_TEST_NETWORK_MODE=probe-error; then
    fail "a network existence probe error reported success"
elif grep -Fqi 'network' "$fixture_root/network-probe.out"; then
    pass "a network existence probe error remains a failure"
else
    fail "a network existence probe error omitted its diagnostic"
fi

info "independent cleanup failures accumulate"
if run_teardown aggregate env \
    ODYSSEUS_TEST_COMPOSE_DOWN=error \
    ODYSSEUS_TEST_CONTAINER_MODE=remove-error \
    ODYSSEUS_TEST_NETWORK_MODE=remove-error; then
    fail "multiple cleanup errors reported success"
elif grep -q '^podman rm -f ' "$fixture_root/aggregate.effects" \
     && grep -q '^podman network rm ' "$fixture_root/aggregate.effects" \
     && grep -Fqi 'container' "$fixture_root/aggregate.out" \
     && grep -Fqi 'network' "$fixture_root/aggregate.out"; then
    pass "teardown reports failures from all independent cleanup steps"
else
    fail "teardown stopped early or omitted an independent failure"
fi

info "successful removal commands require absent postconditions"
if run_teardown remains env \
    ODYSSEUS_TEST_CONTAINER_MODE=remains \
    ODYSSEUS_TEST_NETWORK_MODE=remains; then
    fail "remaining resources reported successful teardown"
elif grep -Fqi 'remain' "$fixture_root/remains.out"; then
    pass "resources that remain after removal make teardown fail"
else
    fail "remaining cleanup resources omitted the postcondition failure"
fi

summary
exit_code
