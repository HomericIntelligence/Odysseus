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
# Hephaestus installs pixi while running as root (sudo -E). Pixi lazily
# creates ~/.cache/rattler/cache/{pkgs,repodata} on first use — which happens
# inside the root subprocess — making those dirs root-owned. Phase 3 then
# fails every pixi invocation with "Permission denied".
#
# Fix: pre-create the rattler cache tree as root, then immediately hand all
# relevant dirs to the invoking user. This way pixi finds the dirs already
# present and user-owned when it runs in Phase 3.
_real_user="${SUDO_USER:-}"
if [[ -n "$_real_user" ]]; then
    _chown_failed=0
    for _cache_dir in \
        "$HOME/.cache/rattler/cache/pkgs" \
        "$HOME/.cache/rattler/cache/repodata" \
        "$HOME/.cache/uv" \
        "$HOME/.pixi" \
        "$HOME/.local/bin"
    do
        if ! mkdir -p "$_cache_dir" 2>/dev/null; then
            check_warn "mkdir -p $_cache_dir failed (may already exist with different owner)"
            _chown_failed=1
            continue
        fi
        if ! chown -R "$_real_user" "$_cache_dir" 2>/dev/null; then
            check_warn "chown -R $_real_user $_cache_dir failed"
            _chown_failed=1
        fi
    done
    # Also fix the parent dirs — only if they exist
    for _parent in "$HOME/.cache/rattler" "$HOME/.cache/rattler/cache"; do
        if [[ -d "$_parent" ]]; then
            if ! chown "$_real_user" "$_parent" 2>/dev/null; then
                check_warn "chown $_real_user $_parent failed"
                _chown_failed=1
            fi
        fi
    done
    if [[ "$_chown_failed" -eq 0 ]]; then
        check_pass "Cache dirs pre-created and ownership set to $_real_user"
    else
        check_warn "Cache dir ownership setup completed with warnings (see above)"
    fi
    unset _chown_failed _parent
fi
unset _real_user _cache_dir

# ─── Propagate failure to the parent installer ───────────────────────────────
# The phase scripts are *sourced*, so a check_fail only increments _FAIL — it
# does not set this subprocess's exit status. Without an explicit gate the
# script exits with the last command's status (0), and install.sh's
# `if sudo -E ... bash root-install.sh; then` wrapper reports success on a
# failed phase (issue #372). Exit non-zero when any check failed.
[[ ${_FAIL:-0} -gt 0 ]] && exit 1
exit 0
