#!/usr/bin/env bash
# HomericIntelligence Odysseus — Development Installer
#
# Installs development tooling (phases 70–95): Python dev deps, pre-commit,
# C++ debug/asan toolchain, and docs tools.
#
# PREREQUISITE: run install.sh --install first.
#
# Usage:
#   bash install_dev.sh                    # Check-only mode
#   bash install_dev.sh --install          # Install dev tooling
#   bash install_dev.sh --only 80          # Run only phase 80
#   bash install_dev.sh --skip 95          # Skip phase 95
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
    exit 1
fi
export ODYSSEUS_ROOT

# ─── Extend PATH for tools installed by install.sh ───────────────────────────
# install.sh writes pixi/just/brew binaries to user-local dirs added to ~/.bashrc.
# This non-interactive shell doesn't source .bashrc, so add them explicitly.
for _p in \
    "$HOME/.pixi/bin" \
    "$HOME/.local/bin" \
    "/home/linuxbrew/.linuxbrew/bin" \
    "/usr/local/go/bin"
do
    [[ -d "$_p" ]] && [[ ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
done
unset _p

# ─── Prerequisite check ───────────────────────────────────────────────────────
PREREQ_ERRORS=()

# Check pixi binary is present (phase 40 should have installed it)
if ! command -v pixi >/dev/null 2>&1; then
    PREREQ_ERRORS+=("pixi not found — run: bash install.sh --install first")
fi

# Check at least one submodule is initialized (non-empty submodule dir)
if [[ ! -f "$ODYSSEUS_ROOT/shared/ProjectHephaestus/scripts/shell/install.sh" ]]; then
    PREREQ_ERRORS+=("Submodules not initialized — run: bash install.sh --install first (phase 30)")
fi

if [[ ${#PREREQ_ERRORS[@]} -gt 0 ]]; then
    echo "ERROR: Production install artifacts missing:" >&2
    for err in "${PREREQ_ERRORS[@]}"; do
        echo "  - $err" >&2
    done
    exit 1
fi

# ─── Source helpers ───────────────────────────────────────────────────────────
HELPERS_LIB="$ODYSSEUS_ROOT/shared/ProjectHephaestus/scripts/shell/lib/install_helpers.sh"
if [[ -f "$HELPERS_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$HELPERS_LIB"
else
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
echo -e "${BOLD}HomericIntelligence Odysseus Dev Installer${NC}"
echo "═══════════════════════════════════════════"
echo -e "  Root:    ${CYAN}${ODYSSEUS_ROOT}${NC}"
echo -e "  Role:    ${CYAN}${ROLE}${NC}"
echo -e "  Install: ${CYAN}${INSTALL}${NC}"

# ─── Phase runner ────────────────────────────────────────────────────────────
PHASE_RESULTS=()

_should_run_phase() {
    local phase="$1"
    if [[ -n "$ONLY_PHASE" ]]; then
        [[ "$phase" == "$ONLY_PHASE" ]] && return 0 || return 1
    fi
    for skip in "${SKIP_PHASES[@]:-}"; do
        [[ "$phase" == "$skip" ]] && return 1
    done
    return 0
}

run_phase() {
    local phase_num="$1"
    local phase_script
    phase_script="$(echo "$ODYSSEUS_ROOT/scripts/install/dev/${phase_num}-"*.sh 2>/dev/null | head -1)"

    if [[ ! -f "$phase_script" ]]; then
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
    echo -e "${BOLD}▶ Phase ${phase_num}${NC} — $(basename "$phase_script" .sh | sed 's/^[0-9]*-//')"

    local pre_fail=$_FAIL
    # shellcheck source=/dev/null
    source "$phase_script"
    local post_fail=$_FAIL

    if [[ $post_fail -gt $pre_fail ]]; then
        PHASE_RESULTS+=("FAIL:$phase_num")
    else
        PHASE_RESULTS+=("PASS:$phase_num")
    fi
}

# ─── Run dev phases ───────────────────────────────────────────────────────────
run_phase "70"
run_phase "80"
run_phase "90"
run_phase "95"

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
echo -e "${BOLD}═══════════════════════════════════════════${NC}"
echo -e "Install complete: ${GREEN}${PHASES_PASSED} passed${NC}, ${RED}${PHASES_FAILED} failed${NC}, ${YELLOW}${PHASES_WARNED} warnings${NC}"
echo -e "  ${GREEN}✓${NC} Passed checks:  ${_PASS}"
[[ $_FAIL -gt 0 ]]  && echo -e "  ${RED}✗${NC} Failed checks:  ${_FAIL}"
[[ $_WARN -gt 0 ]]  && echo -e "  ${YELLOW}⚠${NC} Warnings:       ${_WARN}"
[[ $_SKIP -gt 0 ]]  && echo -e "  ${DIM}–${NC} Skipped:        ${_SKIP}"

if [[ $PHASES_FAILED -gt 0 ]]; then
    if [[ "$INSTALL" != "true" ]]; then
        echo -e "${YELLOW}Run with --install to attempt automatic installation of missing dev dependencies.${NC}"
    fi
    exit 1
fi

echo -e "${GREEN}All dev phases passed.${NC}"
