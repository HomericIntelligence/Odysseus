#!/usr/bin/env bash
# HomericIntelligence Odysseus — Production Installer
#
# Orchestrates installation phases 10–60 for the HomericIntelligence ecosystem.
#
# Usage:
#   bash install.sh                        # Check-only mode (default)
#   bash install.sh --install              # Install missing dependencies
#   bash install.sh --install --role all   # All roles (default)
#   bash install.sh --install --role worker
#   bash install.sh --install --role control
#   bash install.sh --only 30             # Run only phase 30
#   bash install.sh --skip 50             # Skip phase 50
#   bash install.sh --no-claude-tooling   # Skip phase 60
#
# Exit codes:
#   0 — all phases passed
#   1 — one or more phases failed
#
# shellcheck disable=SC2015,SC2034
set -uo pipefail

# ─── Parse arguments ─────────────────────────────────────────────────────────
INSTALL=false
ROLE="all"
SKIP_PHASES=()
ONLY_PHASE=""
NO_CLAUDE_TOOLING=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --install)    INSTALL=true; shift ;;
        --check)      INSTALL=false; shift ;;
        --role)       ROLE="${2:?'--role requires a value'}"; shift 2 ;;
        --skip)       SKIP_PHASES+=("${2:?'--skip requires a value'}"); shift 2 ;;
        --only)       ONLY_PHASE="${2:?'--only requires a value'}"; shift 2 ;;
        --no-claude-tooling) NO_CLAUDE_TOOLING=true; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

export INSTALL ROLE NO_CLAUDE_TOOLING

# ─── Locate Odysseus root ─────────────────────────────────────────────────────
# Walk up from the directory of this script to find .gitmodules
_find_odysseus_root() {
    local dir
    dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    while [[ "$dir" != "/" ]]; do
        [[ -f "$dir/.gitmodules" ]] && { echo "$dir"; return 0; }
        dir="$(dirname "$dir")"
    done
    return 1
}

if ! ODYSSEUS_ROOT="$(_find_odysseus_root)"; then
    echo "ERROR: Cannot find Odysseus repo root (.gitmodules not found)." >&2
    echo "Run install.sh from inside the Odysseus repository." >&2
    exit 1
fi
export ODYSSEUS_ROOT

# ─── Source helpers ───────────────────────────────────────────────────────────
HELPERS_LIB="$ODYSSEUS_ROOT/shared/ProjectHephaestus/scripts/shell/lib/install_helpers.sh"
if [[ -f "$HELPERS_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$HELPERS_LIB"
else
    # Inline minimal helpers — used only until phase 20 delegates to ProjectHephaestus
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'
    _PASS=0; _FAIL=0; _WARN=0; _SKIP=0

    has_cmd() { command -v "$1" >/dev/null 2>&1; }
    get_version() { "$@" 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1 || true; }
    version_gte() {
        local a="$1" b="$2"
        [[ "$(printf '%s\n' "$a" "$b" | sort -V | head -1)" == "$b" ]]
    }
    section() { echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"; }
    check_pass() { (( _PASS++ )); echo -e "  ${GREEN}✓${NC} $*"; }
    check_fail() { (( _FAIL++ )); echo -e "  ${RED}✗${NC} $*"; }
    check_warn() { (( _WARN++ )); echo -e "  ${YELLOW}⚠${NC} $*"; }
    check_skip() { (( _SKIP++ )); echo -e "  ${DIM}–${NC} $*"; }
fi

# ─── Banner ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}HomericIntelligence Odysseus Installer${NC}"
echo "═══════════════════════════════════════"
echo -e "  Root:    ${CYAN}${ODYSSEUS_ROOT}${NC}"
echo -e "  Role:    ${CYAN}${ROLE}${NC}"
echo -e "  Install: ${CYAN}${INSTALL}${NC}"
[[ -n "$ONLY_PHASE" ]] && echo -e "  Only:    ${CYAN}phase ${ONLY_PHASE}${NC}"
[[ ${#SKIP_PHASES[@]} -gt 0 ]] && echo -e "  Skip:    ${CYAN}${SKIP_PHASES[*]}${NC}"

# ─── Phase runner ────────────────────────────────────────────────────────────
PHASE_RESULTS=()

_should_run_phase() {
    local phase="$1"
    # If --only is set, only run that phase
    if [[ -n "$ONLY_PHASE" ]]; then
        [[ "$phase" == "$ONLY_PHASE" ]] && return 0 || return 1
    fi
    # Check skip list
    for skip in "${SKIP_PHASES[@]:-}"; do
        [[ "$phase" == "$skip" ]] && return 1
    done
    return 0
}

run_phase() {
    local phase_num="$1"
    # Glob expansion to find the phase script
    local script
    script="$(echo "$ODYSSEUS_ROOT"/scripts/install/"${phase_num}"-*.sh 2>/dev/null | head -1)"

    if [[ ! -f "$script" ]]; then
        check_warn "Phase $phase_num: script not found (skipped)"
        PHASE_RESULTS+=("WARN:$phase_num")
        return 0
    fi

    if ! _should_run_phase "$phase_num"; then
        check_skip "Phase $phase_num: skipped"
        PHASE_RESULTS+=("SKIP:$phase_num")
        return 0
    fi

    echo ""
    echo -e "${BOLD}▶ Phase ${phase_num}${NC} — $(basename "$script" .sh | sed 's/^[0-9]*-//')"

    # Reset counters before each phase (we track per-phase failures via subshell exit)
    local pre_fail=$_FAIL
    # shellcheck source=/dev/null
    source "$script"
    local post_fail=$_FAIL

    if [[ $post_fail -gt $pre_fail ]]; then
        PHASE_RESULTS+=("FAIL:$phase_num")
    else
        PHASE_RESULTS+=("PASS:$phase_num")
    fi
}

# ─── Run production phases ────────────────────────────────────────────────────
# Phase 10 first (system apt deps), then 30 (submodules — makes ProjectHephaestus
# available), then 20 (base tooling delegates to ProjectHephaestus installer).
run_phase "10"
run_phase "30"
run_phase "20"
run_phase "40"
run_phase "50"

if [[ "$NO_CLAUDE_TOOLING" != "true" ]]; then
    run_phase "60"
else
    check_skip "Phase 60: claude-tooling skipped (--no-claude-tooling)"
    PHASE_RESULTS+=("SKIP:60")
fi

# ─── Summary ─────────────────────────────────────────────────────────────────
PHASES_PASSED=0; PHASES_FAILED=0; PHASES_WARNED=0
for r in "${PHASE_RESULTS[@]}"; do
    case "$r" in
        PASS:*)  (( PHASES_PASSED++ )) ;;
        FAIL:*)  (( PHASES_FAILED++ )) ;;
        WARN:*|SKIP:*)  (( PHASES_WARNED++ )) ;;
    esac
done

echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "Install complete: ${GREEN}${PHASES_PASSED} passed${NC}, ${RED}${PHASES_FAILED} failed${NC}, ${YELLOW}${PHASES_WARNED} warnings${NC}"
echo -e "  ${GREEN}✓${NC} Passed checks:  ${_PASS}"
[[ $_FAIL -gt 0 ]]  && echo -e "  ${RED}✗${NC} Failed checks:  ${_FAIL}"
[[ $_WARN -gt 0 ]]  && echo -e "  ${YELLOW}⚠${NC} Warnings:       ${_WARN}"
[[ $_SKIP -gt 0 ]]  && echo -e "  ${DIM}–${NC} Skipped:        ${_SKIP}"

if [[ $PHASES_FAILED -gt 0 ]]; then
    if [[ "$INSTALL" != "true" ]]; then
        echo -e "${YELLOW}Run with --install to attempt automatic installation of missing dependencies.${NC}"
    else
        echo -e "${YELLOW}Some installs may require opening a new shell to take effect (PATH changes).${NC}"
    fi
    exit 1
fi

echo -e "${GREEN}All phases passed.${NC}"
