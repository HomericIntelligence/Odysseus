#!/usr/bin/env bash
# HomericIntelligence IPC E2E Test Runner
# Runs test scripts against a selected topology and category.
#
# Usage:
#   bash e2e/run-ipc-tests.sh --topology t1 --category protocol
#   bash e2e/run-ipc-tests.sh --topology t4 --category all
#   bash e2e/run-ipc-tests.sh --topology t1 --category fault --test nats-crash-reconnect
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Parse arguments ─────────────────────────────────────────────────────────
TOPOLOGY="t1"
CATEGORY="all"
SINGLE_TEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topology)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" = --* ]]; then
                echo "ERROR: --topology requires a value" >&2
                exit 2
            fi
            TOPOLOGY="$2"
            shift 2
            ;;
        --category)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" = --* ]]; then
                echo "ERROR: --category requires a value" >&2
                exit 2
            fi
            CATEGORY="$2"
            shift 2
            ;;
        --test)
            if [ "$#" -lt 2 ] || [ -z "${2:-}" ] || [[ "${2:-}" = --* ]]; then
                echo "ERROR: --test requires a value" >&2
                exit 2
            fi
            SINGLE_TEST="$2"
            shift 2
            ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

# Discover a non-empty test inventory before any topology effect.
TESTS_DIR="$SCRIPT_DIR/tests"
CATEGORIES=()
case "$CATEGORY" in
    all) CATEGORIES=(fault perf protocol security chaos) ;;
    fault|perf|protocol|security|chaos) CATEGORIES=("$CATEGORY") ;;
    *)
        echo "ERROR: unknown category '$CATEGORY'" >&2
        exit 2
        ;;
esac

if [ -n "$SINGLE_TEST" ] \
   && ! [[ "$SINGLE_TEST" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "ERROR: unknown test '$SINGLE_TEST' for category '$CATEGORY'" >&2
    exit 2
fi

TEST_SCRIPTS=()
for category in "${CATEGORIES[@]}"; do
    cat_dir="$TESTS_DIR/$category"
    [ -d "$cat_dir" ] || continue
    if [ -n "$SINGLE_TEST" ]; then
        script="$cat_dir/${SINGLE_TEST}.sh"
        [ -f "$script" ] && TEST_SCRIPTS+=("$script")
    else
        for script in "$cat_dir"/*.sh; do
            [ -f "$script" ] || continue
            TEST_SCRIPTS+=("$script")
        done
    fi
done

if [ "${#TEST_SCRIPTS[@]}" -eq 0 ]; then
    if [ -n "$SINGLE_TEST" ]; then
        echo "ERROR: unknown test '$SINGLE_TEST' for category '$CATEGORY'" >&2
    else
        echo "ERROR: no test scripts found for category '$CATEGORY'" >&2
    fi
    exit 1
fi

export IPC_TOPOLOGY="$TOPOLOGY"

# ─── Source shared libraries ──────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/topology.sh"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence IPC E2E Tests                       ║"
echo "║  Topology: $TOPOLOGY   Category: $CATEGORY                          ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Start topology ───────────────────────────────────────────────────────────

cleanup_topology_on_exit() {
    local prior_status="$1" cleanup_status=0
    trap - EXIT
    if topology_stop "$TOPOLOGY"; then
        cleanup_status=0
    else
        cleanup_status=$?
        printf 'ERROR: topology cleanup failed for %s (status %d)\n' \
            "$TOPOLOGY" "$cleanup_status" >&2
    fi
    if [ "$prior_status" -ne 0 ]; then
        exit "$prior_status"
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        exit "$cleanup_status"
    fi
    exit 0
}

# T4 expects the stack to already be running (via just e2e-up)
if [ "$TOPOLOGY" != "t4" ]; then
    trap 'cleanup_topology_on_exit "$?"' EXIT
    topology_start "$TOPOLOGY" || { echo "Failed to start topology $TOPOLOGY" >&2; exit 1; }
fi

topology_wait_healthy "$TOPOLOGY" || { echo "Topology not healthy" >&2; exit 1; }

# Export port variables so test subprocesses (bash "$script") inherit them
export AGAMEMNON_PORT NATS_PORT NATS_MONITOR_PORT HERMES_PORT IPC_TOPOLOGY

# ─── Discover and run tests ──────────────────────────────────────────────────
TOTAL_PASS=0
TOTAL_FAIL=0

run_test_script() {
    local script="$1"
    local test_name
    test_name="$(basename "$script" .sh)"
    echo -e "\n${BLUE}──${NC} Running: ${CYAN}${test_name}${NC}"

    if bash "$script"; then
        TOTAL_PASS=$((TOTAL_PASS + 1))
    else
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        echo -e "  ${RED}Script failed: $test_name${NC}"
    fi
}

# Run only the inventory that was validated before topology startup.
current_category=""
for script in "${TEST_SCRIPTS[@]}"; do
    category_path="${script%/*}"
    script_category="${category_path##*/}"
    if [ "$script_category" != "$current_category" ]; then
        info "Category: $script_category"
        current_category="$script_category"
    fi
    run_test_script "$script"
done

# ─── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════════════════════╗"
TOTAL=$((TOTAL_PASS + TOTAL_FAIL))
if [ "$TOTAL_FAIL" -eq 0 ]; then
    echo -e "║  ${GREEN}ALL PASSED${NC}: $TOTAL_PASS / $TOTAL test scripts                 ║"
else
    echo -e "║  ${RED}FAILURES${NC}: $TOTAL_FAIL / $TOTAL test scripts                  ║"
fi
echo "╚══════════════════════════════════════════════════════════╝"
echo ""

[ "$TOTAL_FAIL" -eq 0 ]
