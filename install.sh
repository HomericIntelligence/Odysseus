#!/usr/bin/env bash
# HomericIntelligence Odysseus — Production Installer
#
# Three-phase install:
#   Phase 1 (detect):       Probe every component; record what is missing.
#   Phase 2 (root):         Install missing root-required components (apt, Hephaestus)
#                           by re-invoking scripts/install/root-install.sh as sudo.
#   Phase 3 (user):         Install missing user-space components (submodules, pixi,
#                           C++ builds, Claude tooling) without privilege escalation.
#
# Usage:
#   bash install.sh                        # Check-only mode (default)
#   bash install.sh --install              # Run all three phases
#   bash install.sh --install --role all   # All roles (default)
#   bash install.sh --install --role worker
#   bash install.sh --install --role control
#   bash install.sh --only 30             # Run only phase 30 (user-install sub-script)
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

# ─── Phase filter helpers ─────────────────────────────────────────────────────
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

# ─── State file ──────────────────────────────────────────────────────────────
# Written by Phase 1 (detect), consumed by Phase 2 (root) and Phase 3 (user).
# Format: simple KEY=true/false shell assignments, safe to source.
STATE_FILE="${TMPDIR:-/tmp}/odysseus-install-state-$$.env"
trap 'rm -f "$STATE_FILE"' EXIT

# ─── Extend PATH for previously-installed tools ──────────────────────────────
# Tools installed by prior runs (pixi, just, brew, go) write to user-local dirs
# that are added to PATH via ~/.bashrc — but install.sh runs in a non-interactive
# bash that doesn't source .bashrc. Without this, Phase 1 detect falsely reports
# already-installed tools as missing on every re-run.
for _p in \
    "$HOME/.pixi/bin" \
    "$HOME/.local/bin" \
    "/home/linuxbrew/.linuxbrew/bin" \
    "/usr/local/go/bin"
do
    [[ -d "$_p" ]] && [[ ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
done
unset _p

# ─── Phase 1: Detect ─────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}━━━ Phase 1: Detect ━━━${NC}"
echo -e "${DIM}Probing every component — no changes made${NC}"

# Run each phase script in check-only mode and record _FAIL deltas.
# We temporarily force INSTALL=false regardless of CLI flags so probing is
# always read-only.
_saved_INSTALL="$INSTALL"
INSTALL=false

_detect_phase() {
    local phase_num="$1"
    local script
    script="$(echo "$ODYSSEUS_ROOT"/scripts/install/"${phase_num}"-*.sh 2>/dev/null | head -1)"
    [[ ! -f "$script" ]] && return 0

    echo ""
    echo -e "${BOLD}▶ Phase ${phase_num}${NC} — $(basename "$script" .sh | sed 's/^[0-9]*-//')"
    local pre_fail=$_FAIL
    # shellcheck source=/dev/null
    source "$script"
    local post_fail=$_FAIL
    [[ $post_fail -gt $pre_fail ]] && echo "PHASE_${phase_num}_MISSING=true" >> "$STATE_FILE" \
                                   || echo "PHASE_${phase_num}_MISSING=false" >> "$STATE_FILE"
}

# Root-required phases
_detect_phase "10"
_detect_phase "20"

# Phase 20 delegates to Hephaestus as a subprocess (not sourced), so its
# failures never increment _FAIL — _detect_phase records it as MISSING=false
# even when pixi/just/nats-server are absent.  Override: check directly.
_p20_ok=true
for _t in pixi just nats-server; do
    command -v "$_t" >/dev/null 2>&1 && continue
    # Also check install locations not yet on PATH
    [[ -x "$HOME/.pixi/bin/$_t" || -x "$HOME/.local/bin/$_t" ]] && continue
    _p20_ok=false; break
done
if [[ "$_p20_ok" == "false" ]]; then
    # Replace the entry written by _detect_phase or append if absent
    if grep -q "^PHASE_20_MISSING=" "$STATE_FILE" 2>/dev/null; then
        sed -i 's/^PHASE_20_MISSING=.*/PHASE_20_MISSING=true/' "$STATE_FILE"
    else
        echo "PHASE_20_MISSING=true" >> "$STATE_FILE"
    fi
fi
unset _p20_ok _t

# User-space phases
_detect_phase "30"
_detect_phase "40"
_detect_phase "50"
if [[ "$NO_CLAUDE_TOOLING" != "true" ]]; then
    _detect_phase "60"
else
    echo "PHASE_60_MISSING=false" >> "$STATE_FILE"
fi

INSTALL="$_saved_INSTALL"

# Derive aggregate flags consumed by sub-scripts
# shellcheck source=/dev/null
source "$STATE_FILE"

NEEDS_ROOT=false
NEEDS_USER=false
for _v in PHASE_10_MISSING PHASE_20_MISSING; do
    [[ "${!_v:-false}" == "true" ]] && NEEDS_ROOT=true
done
for _v in PHASE_30_MISSING PHASE_40_MISSING PHASE_50_MISSING PHASE_60_MISSING; do
    [[ "${!_v:-false}" == "true" ]] && NEEDS_USER=true
done
{
    echo "NEEDS_ROOT=$NEEDS_ROOT"
    echo "NEEDS_USER=$NEEDS_USER"
} >> "$STATE_FILE"

echo ""
echo -e "${BOLD}Detection summary:${NC}"
echo -e "  Root install needed:  $( [[ "$NEEDS_ROOT" == "true" ]] && echo -e "${YELLOW}yes${NC}" || echo -e "${GREEN}no${NC}" )"
echo -e "  User install needed:  $( [[ "$NEEDS_USER" == "true" ]] && echo -e "${YELLOW}yes${NC}" || echo -e "${GREEN}no${NC}" )"

if [[ "$INSTALL" != "true" ]]; then
    echo ""
    echo -e "${YELLOW}Check-only mode — run with --install to apply changes.${NC}"
    if [[ "$NEEDS_ROOT" == "true" || "$NEEDS_USER" == "true" ]]; then
        exit 1
    fi
    echo -e "${GREEN}All components present.${NC}"
    exit 0
fi

# ─── Phase 2: Root install ────────────────────────────────────────────────────
ROOT_SCRIPT="$ODYSSEUS_ROOT/scripts/install/root-install.sh"

if [[ "$NEEDS_ROOT" == "true" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Phase 2: Root install ━━━${NC}"
    echo -e "${DIM}Running as sudo — apt packages and base tooling${NC}"

    if [[ ! -f "$ROOT_SCRIPT" ]]; then
        echo -e "  ${RED}✗${NC} scripts/install/root-install.sh not found" >&2
        exit 1
    fi

    # Pass state file path and all relevant env vars via -E + positional args.
    # We use sudo -E so HOME/USER remain the real user's (needed by Hephaestus).
    if sudo -E \
        ODYSSEUS_ROOT="$ODYSSEUS_ROOT" \
        INSTALL=true \
        ROLE="$ROLE" \
        STATE_FILE="$STATE_FILE" \
        bash "$ROOT_SCRIPT" "${SKIP_PHASES[@]+"${SKIP_PHASES[@]}"}"; then
        echo -e "  ${GREEN}✓${NC} Root install complete"
    else
        echo -e "  ${RED}✗${NC} Root install failed — check output above" >&2
        exit 1
    fi
else
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Phase 2: Root install ━━━${NC}"
    echo -e "  ${DIM}–${NC} All root-managed components already present — skipped"
fi

# ─── Extend PATH after root install ──────────────────────────────────────────
# The Hephaestus installer writes to ~/.bashrc but won't propagate to this
# running shell; extend PATH explicitly so Phase 3 can find pixi/just/etc.
for _p in \
    "$HOME/.pixi/bin" \
    "$HOME/.local/bin" \
    "/home/linuxbrew/.linuxbrew/bin" \
    "/usr/local/go/bin"
do
    [[ -d "$_p" ]] && [[ ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
done
unset _p

# ─── Phase 3: User install ────────────────────────────────────────────────────
USER_SCRIPT="$ODYSSEUS_ROOT/scripts/install/user-install.sh"

if [[ "$NEEDS_USER" == "true" ]]; then
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Phase 3: User install ━━━${NC}"
    echo -e "${DIM}Running as current user — submodules, pixi, builds, Claude tooling${NC}"

    if [[ ! -f "$USER_SCRIPT" ]]; then
        echo -e "  ${RED}✗${NC} scripts/install/user-install.sh not found" >&2
        exit 1
    fi

    SKIP_PHASES_ARG=""
    [[ ${#SKIP_PHASES[@]} -gt 0 ]] && SKIP_PHASES_ARG="${SKIP_PHASES[*]}"

    if ODYSSEUS_ROOT="$ODYSSEUS_ROOT" \
       INSTALL=true \
       ROLE="$ROLE" \
       NO_CLAUDE_TOOLING="$NO_CLAUDE_TOOLING" \
       STATE_FILE="$STATE_FILE" \
       bash "$USER_SCRIPT" "${SKIP_PHASES[@]+"${SKIP_PHASES[@]}"}"; then
        echo -e "  ${GREEN}✓${NC} User install complete"
    else
        echo -e "  ${RED}✗${NC} User install failed — check output above" >&2
        exit 1
    fi
else
    echo ""
    echo -e "${BOLD}${CYAN}━━━ Phase 3: User install ━━━${NC}"
    echo -e "  ${DIM}–${NC} All user-space components already present — skipped"
fi

# ─── Final summary ────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}═══════════════════════════════════════${NC}"
echo -e "Install complete"
echo -e "  ${GREEN}✓${NC} Passed checks:  ${_PASS}"
[[ $_FAIL -gt 0 ]] && echo -e "  ${RED}✗${NC} Failed checks:  ${_FAIL}"
[[ $_WARN -gt 0 ]] && echo -e "  ${YELLOW}⚠${NC} Warnings:       ${_WARN}"
[[ $_SKIP -gt 0 ]] && echo -e "  ${DIM}–${NC} Skipped:        ${_SKIP}"
echo -e "${GREEN}All phases passed.${NC}"
