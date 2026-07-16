#!/usr/bin/env bash
# scripts/install/lib.sh — Shared helpers for Odysseus install phase scripts
#
# Sources Hephaestus install_helpers.sh if available, otherwise defines
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
_HELPERS_LIB="$ODYSSEUS_ROOT/shared/Hephaestus/scripts/shell/lib/install_helpers.sh"

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
        # get_version <cmd> [args…] — extract first version string from output.
        # Captures output once to avoid `cmd | grep | head || true` swallowing
        # the real exit code of cmd; empty result means "no version found".
        local _out
        _out="$("$@" 2>&1)" || _out=''
        printf '%s\n' "$_out" | grep -oP '\d+\.\d+[\.\d]*' | head -1 || printf ''
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

# ─── ADR-015 dual-path submodule resolver ─────────────────────────────────────
# resolve_submodule_path <relative-path>
#
# Resolves a submodule path to whichever form currently exists on disk under
# $ODYSSEUS_ROOT. Prefers the input form; falls back to the bare post-rename
# name (drops the "Project" prefix from the basename) when the input form is
# absent. Bidirectional: works whether the on-disk rename has happened yet
# (input still prefixed, disk bare) OR not (input already bare, disk still
# prefixed).
#
# This keeps the install pipeline forward-compatible with ADR-015/016: each
# upstream `gh repo rename` is picked up automatically without an
# install-script edit, so contributors do not have to synchronize script
# updates with the per-repo renames. The 9 not-yet-renamed-upstream repos
# (Argus, Mnemosyne, Telemachy, Keystone, Proteus, Odyssey, Scylla,
# Agamemnon, Nestor, Charybdis) continue to resolve through their original
# `Project<X>` paths; the moment each `gh repo rename` lands, that repo's
# install-script references resolve through the bare-name fallback instead.
#
# Outputs the resolved relative path. Returns 0 when at least one form exists
# on disk (input preferred, bare fallback otherwise); returns 1 when neither
# form is present. Callers SHOULD compare the printed path against the input
# (`[[ $resolved != $mod ]]`) rather than rely on the exit code, because bash
# command substitution (`resolved=$(fn ...)`) overwrites $? before the caller's
# check; tests on exit code after command substitution are unreliable.
#
# Edge cases handled:
#   - No "/" in input → treated as a bare basename (parent empty).
#   - Input lacks the "Project" prefix → no transformation, plain existence
#     check (still resolves correctly post-rename).
#   - Bare fallback resolves to a basename with empty remainder (e.g.
#     `Project` alone strips to "") → guarded, returns original.
resolve_submodule_path() {
    # Defensive against empty input under `set -u` (none of today's call
    # sites pass empty values, but the helper is sourced from scripts that
    # do enable nounset, so we self-defend cheaply).
    local rel="${1:-}"
    if [[ -z "$rel" ]]; then
        printf '\n' >&2
        return 1
    fi
    local abs="$ODYSSEUS_ROOT/$rel"

    if [[ -d "$abs" ]]; then
        printf '%s\n' "$rel"
        return 0
    fi

    # Decompose into parent + basename. `${rel%/*}` returns the input
    # unchanged when there is no slash, so guard the parent-empty case.
    local parent="${rel%/*}"
    local base="${rel##*/}"
    [[ "$parent" == "$rel" ]] && parent=""

    # Drop the "Project" prefix from the basename to produce the bare form.
    # Require a non-empty bare result so `Project` alone does not silently
    # collapse to a directory that does not exist (or worse, is `/` itself).
    if [[ "$base" == Project* ]]; then
        local bare="${base#Project}"
        if [[ -n "$bare" ]]; then
            local bare_rel
            if [[ -n "$parent" ]]; then
                bare_rel="$parent/$bare"
            else
                bare_rel="$bare"
            fi
            if [[ -d "$ODYSSEUS_ROOT/$bare_rel" ]]; then
                printf '%s\n' "$bare_rel"
                return 0
            fi
        fi
    fi

    # Neither form is present on disk — caller decides how to handle the
    # miss (install scripts downgrade this to a WARN rather than a FAIL, per
    # the Phase-1 detect policy in 30-submodules.sh and the per-repo
    # WARN-on-miss policy in 50-cpp-builds.sh).
    printf '%s\n' "$rel"
    return 1
}

# Re-export for child scripts
export INSTALL ROLE
