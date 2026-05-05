#!/usr/bin/env bash
# scripts/install/root-install.sh — Phase 2: Root-privileged installs
#
# Invoked by install.sh as: sudo -E ... bash root-install.sh [skip-phases...]
#
# Runs only the phases that require root:
#   Phase 10 — apt system packages
#   Phase 20 — ProjectHephaestus base tooling (installs system-level tools)
#
# Reads STATE_FILE (written by Phase 1) to skip phases already satisfied.
# Positional args: phase numbers to skip (forwarded from --skip flags).
#
# shellcheck disable=SC2015,SC2034
set -uo pipefail

# ─── Env expectations (set by parent install.sh via sudo -E) ─────────────────
: "${ODYSSEUS_ROOT:?ODYSSEUS_ROOT must be set}"
: "${INSTALL:=true}"
: "${ROLE:=all}"
: "${STATE_FILE:=}"

export INSTALL ROLE ODYSSEUS_ROOT

# ─── Parse skip list from positional args ─────────────────────────────────────
SKIP_PHASES=("$@")

_should_skip() {
    local phase="$1"
    for skip in "${SKIP_PHASES[@]:-}"; do
        [[ "$phase" == "$skip" ]] && return 0
    done
    return 1
}

# ─── Source helpers ───────────────────────────────────────────────────────────
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ─── Load state from Phase 1 ─────────────────────────────────────────────────
if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
fi

# ─── Phase 10: System dependencies ───────────────────────────────────────────
if _should_skip "10"; then
    check_skip "Phase 10: skipped (--skip)"
elif [[ "${PHASE_10_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 10: system-deps — all packages already present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 10${NC} — system-deps"
    # shellcheck source=10-system-deps.sh
    source "$(dirname "${BASH_SOURCE[0]}")/10-system-deps.sh"
fi

# ─── Phase 20: Base tooling (ProjectHephaestus) ───────────────────────────────
if _should_skip "20"; then
    check_skip "Phase 20: skipped (--skip)"
elif [[ "${PHASE_20_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 20: base-tooling — all tools already present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 20${NC} — base-tooling"
    # shellcheck source=20-base-tooling.sh
    source "$(dirname "${BASH_SOURCE[0]}")/20-base-tooling.sh"
fi

# ─── Fix cache ownership ──────────────────────────────────────────────────────
# Hephaestus installs pixi (and pixi creates ~/.cache/rattler/) while running
# as root under sudo -E. The cache directories are then root-owned, causing
# permission errors when Phase 3 runs pixi as the regular user.
# Fix: hand ownership back to the invoking user for all relevant caches.
_real_user="${SUDO_USER:-}"
if [[ -n "$_real_user" ]]; then
    for _cache_dir in \
        "$HOME/.cache/rattler" \
        "$HOME/.pixi" \
        "$HOME/.local/bin" \
        "$HOME/.cache/uv"
    do
        if [[ -e "$_cache_dir" ]]; then
            chown -R "$_real_user" "$_cache_dir" 2>/dev/null || true
        fi
    done
    check_pass "Cache ownership restored to $_real_user"
fi
unset _real_user _cache_dir
