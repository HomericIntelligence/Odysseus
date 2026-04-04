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
ODYSSEUS_ROOT="$(dirname "$SCRIPT_DIR")"

# ─── Parse arguments ─────────────────────────────────────────────────────────
TOPOLOGY="t1"
CATEGORY="all"
SINGLE_TEST=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --topology) TOPOLOGY="$2"; shift 2 ;;
        --category) CATEGORY="$2"; shift 2 ;;
        --test)     SINGLE_TEST="$2"; shift 2 ;;
        *) echo "Unknown arg: $1" >&2; exit 1 ;;
    esac
done

export IPC_TOPOLOGY="$TOPOLOGY"

# ─── Source shared libraries ──────────────────────────────────────────────────
source "$SCRIPT_DIR/lib/topology.sh"

echo ""
echo "╔══════════════════════════════════════════════════════════╗"
echo "║  HomericIntelligence IPC E2E Tests                       ║"
echo "║  Topology: $TOPOLOGY   Category: $CATEGORY                          ║"
echo "╚══════════════════════════════════════════════════════════╝"

# ─── Start topology ───────────────────────────────────────────────────────────

# T4 expects the stack to already be running (via just e2e-up)
if [ "$TOPOLOGY" != "t4" ]; then
    trap 'topology_stop "$TOPOLOGY"' EXIT
    topology_start "$TOPOLOGY" || { echo "Failed to start topology $TOPOLOGY" >&2; exit 1; }
fi

topology_wait_healthy "$TOPOLOGY" || { echo "Topology not healthy" >&2; exit 1; }

# Export port variables so test subprocesses (bash "$script") inherit them
export AGAMEMNON_PORT NATS_PORT NATS_MONITOR_PORT HERMES_PORT IPC_TOPOLOGY

# ─── Discover and run tests ──────────────────────────────────────────────────
TESTS_DIR="$SCRIPT_DIR/tests"
TOTAL_PASS=0
TOTAL_FAIL=0
TOTAL_SKIP=0

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

# Collect test scripts
CATEGORIES=()
if [ "$CATEGORY" = "all" ]; then
    CATEGORIES=(fault perf protocol security chaos)
else
    CATEGORIES=("$CATEGORY")
fi

for cat in "${CATEGORIES[@]}"; do
    cat_dir="$TESTS_DIR/$cat"
    [ -d "$cat_dir" ] || continue

    info "Category: $cat"

    if [ -n "$SINGLE_TEST" ]; then
        script="$cat_dir/${SINGLE_TEST}.sh"
        [ -f "$script" ] && run_test_script "$script"
    else
        for script in "$cat_dir"/*.sh; do
            [ -f "$script" ] || continue
            run_test_script "$script"
        done
    fi
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
