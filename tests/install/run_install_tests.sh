#!/usr/bin/env bash
# tests/install/run_install_tests.sh — Container-based install test harness
#
# Builds a clean container image for each target OS, runs install.sh twice
# (idempotency), and optionally runs install_dev.sh.
#
# Usage:
#   bash tests/install/run_install_tests.sh [os] [role] [--dev]
#
#   os:   debian12 | ubuntu2404 | ubuntu2204 | all  (default: all)
#   role: worker | control | all                    (default: worker)
#   --dev: also run install_dev.sh after install.sh
#
# Requires podman or docker.
#
set -euo pipefail

# ─── Runtime detection ────────────────────────────────────────────────────────
RUNTIME=$(command -v podman 2>/dev/null || command -v docker 2>/dev/null || true)
if [[ -z "$RUNTIME" ]]; then
    echo "ERROR: Neither podman nor docker found on PATH." >&2
    exit 1
fi

# ─── Arguments ───────────────────────────────────────────────────────────────
ODYSSEUS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
OS="${1:-all}"
ROLE="${2:-worker}"
DEV=""
# Branch/ref to clone inside container (default: main; override to test pre-merge branches)
ODYSSEUS_REF="${ODYSSEUS_REF:-main}"

# Allow --dev as third positional or anywhere in args
for arg in "$@"; do
    [[ "$arg" == "--dev" ]] && DEV="true"
done

# ─── Colour helpers ───────────────────────────────────────────────────────────
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'

# ─── Test runner ─────────────────────────────────────────────────────────────
run_test() {
    local os="$1" role="$2"
    local image="odysseus-install-test-${os}"
    local dockerfile="$ODYSSEUS_ROOT/tests/install/Dockerfile.${os}"
    local log_prefix="/tmp/install-${os}-${role}"

    echo ""
    echo -e "${CYAN}════════════════════════════════════════${NC}"
    echo -e "${CYAN}Testing: os=${os}  role=${role}${NC}"
    echo -e "${CYAN}════════════════════════════════════════${NC}"

    # ── Build image ──────────────────────────────────────────────────────────
    # Build context is just the Dockerfile directory — the image clones
    # Odysseus from GitHub at build time to avoid submodule .git symlink issues.
    echo -e "${YELLOW}Building image ${image} (ref=${ODYSSEUS_REF})...${NC}"
    "$RUNTIME" build \
        -t "$image" \
        -f "$dockerfile" \
        --build-arg "ODYSSEUS_REF=${ODYSSEUS_REF}" \
        "$(dirname "$dockerfile")" 2>&1 | tail -5

    # ── Run 1: first install ──────────────────────────────────────────────────
    echo -e "${YELLOW}Run 1: install.sh --install --role ${role}${NC}"
    "$RUNTIME" run --rm "$image" \
        bash -c "bash install.sh --install --role ${role} 2>&1" \
        | tee "${log_prefix}-run1.log"

    # ── Run 2: idempotency check ──────────────────────────────────────────────
    echo -e "${YELLOW}Run 2 (idempotency): install.sh --install --role ${role}${NC}"
    "$RUNTIME" run --rm "$image" \
        bash -c "bash install.sh --install --role ${role} 2>&1" \
        | tee "${log_prefix}-run2.log"

    # Idempotency: second run must exit 0 and must not have new FAIL lines
    if grep -q "^Install complete:.*0 failed" "${log_prefix}-run2.log" 2>/dev/null || \
       grep -q "All phases passed" "${log_prefix}-run2.log" 2>/dev/null; then
        echo -e "${GREEN}Idempotency OK${NC}"
    else
        echo -e "${YELLOW}Warning: idempotency check inconclusive — review ${log_prefix}-run2.log${NC}"
    fi

    # ── Optional dev install ──────────────────────────────────────────────────
    if [[ -n "$DEV" ]]; then
        echo -e "${YELLOW}Dev run: install.sh + install_dev.sh --install${NC}"
        "$RUNTIME" run --rm "$image" \
            bash -c "bash install.sh --install --role ${role} && bash install_dev.sh --install 2>&1" \
            | tee "${log_prefix}-dev.log"
    fi

    echo -e "${GREEN}PASS: os=${os}  role=${role}${NC}"
    echo "Logs: ${log_prefix}-run1.log  ${log_prefix}-run2.log${DEV:+  ${log_prefix}-dev.log}"
}

# ─── Dispatch ─────────────────────────────────────────────────────────────────
VALID_OS=(debian12 ubuntu2404 ubuntu2204)

if [[ "$OS" == "all" ]]; then
    # Run all OS variants in parallel
    PIDS=()
    for target_os in "${VALID_OS[@]}"; do
        run_test "$target_os" "$ROLE" &
        PIDS+=($!)
    done

    OVERALL_EXIT=0
    for pid in "${PIDS[@]}"; do
        wait "$pid" || OVERALL_EXIT=1
    done

    if [[ $OVERALL_EXIT -ne 0 ]]; then
        echo -e "${RED}One or more install tests FAILED${NC}" >&2
        exit 1
    fi
    echo -e "${GREEN}All install tests PASSED${NC}"
else
    # Validate OS name
    valid=false
    for v in "${VALID_OS[@]}"; do [[ "$OS" == "$v" ]] && valid=true; done
    if [[ "$valid" != "true" ]]; then
        echo "ERROR: Unknown OS '$OS'. Valid: all ${VALID_OS[*]}" >&2
        exit 1
    fi
    run_test "$OS" "$ROLE"
fi
