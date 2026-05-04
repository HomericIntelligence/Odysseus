#!/usr/bin/env bash
# scripts/install/lib.sh — Shared helpers for Odysseus install phase scripts
#
# Sources ProjectHephaestus install_helpers.sh if available, otherwise defines
# a minimal inline set of the same helpers.
#
# Usage: source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# After sourcing, ODYSSEUS_ROOT is exported.
# shellcheck disable=SC2034

# ─── Resolve ODYSSEUS_ROOT if not already set ─────────────────────────────────
if [[ -z "${ODYSSEUS_ROOT:-}" ]]; then
    _lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    # scripts/install/lib.sh → scripts/install → scripts → repo root
    ODYSSEUS_ROOT="$(cd "$_lib_dir/../.." && pwd)"
    export ODYSSEUS_ROOT
fi

# ─── Source or inline helpers ─────────────────────────────────────────────────
_HELPERS_LIB="$ODYSSEUS_ROOT/shared/ProjectHephaestus/scripts/shell/lib/install_helpers.sh"

if [[ -f "$_HELPERS_LIB" ]]; then
    # shellcheck source=/dev/null
    source "$_HELPERS_LIB"
else
    # Minimal inline helpers — identical contract to install_helpers.sh
    RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
    BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; NC='\033[0m'

    # Counters (initialize only if not already set by a parent script)
    : "${_PASS:=0}" "${_FAIL:=0}" "${_WARN:=0}" "${_SKIP:=0}"
    export _PASS _FAIL _WARN _SKIP

    has_cmd() { command -v "$1" >/dev/null 2>&1; }

    get_version() {
        # get_version <cmd> [args…] — extract first version string from output
        "$@" 2>&1 | grep -oP '\d+\.\d+[\.\d]*' | head -1 || true
    }

    version_gte() {
        # version_gte <have> <need> — true if have >= need
        local have="$1" need="$2"
        [[ "$(printf '%s\n' "$have" "$need" | sort -V | head -1)" == "$need" ]]
    }

    section() {
        echo -e "\n${BOLD}${CYAN}══ $* ══${NC}"
    }

    check_pass() { (( _PASS++ )); echo -e "  ${GREEN}✓${NC} $*"; }
    check_fail() { (( _FAIL++ )); echo -e "  ${RED}✗${NC} $*"; }
    check_warn() { (( _WARN++ )); echo -e "  ${YELLOW}⚠${NC} $*"; }
    check_skip() { (( _SKIP++ )); echo -e "  ${DIM}–${NC} $*"; }

    apt_install() {
        local pkg="$1"
        if [[ "${INSTALL:-false}" == "true" ]]; then
            echo -e "    ${BLUE}→${NC} Installing $pkg via apt..."
            sudo apt-get install -y "$pkg" >/dev/null 2>&1
            return $?
        fi
        return 1
    }
fi

# Re-export for child scripts
export INSTALL ROLE
