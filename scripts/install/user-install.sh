#!/usr/bin/env bash
# scripts/install/user-install.sh — Phase 3: User-space installs
#
# Invoked by install.sh as: bash user-install.sh [skip-phases...]
# Runs WITHOUT sudo — all installs go into the user's home directory.
#
# Runs only the phases that do NOT require root:
#   Phase 30 — git submodule initialization
#   Phase 40 — pixi environment setup
#   Phase 50 — C++ release builds (cmake/conan via pixi)
#   Phase 60 — Claude Code CLI + settings + Mnemosyne seed
#
# Reads STATE_FILE (written by Phase 1) to skip phases already satisfied.
# Positional args: phase numbers to skip (forwarded from --skip flags).
#
# shellcheck disable=SC2015,SC2034
set -uo pipefail

# ─── Env expectations (set by parent install.sh) ─────────────────────────────
: "${ODYSSEUS_ROOT:?ODYSSEUS_ROOT must be set}"
: "${INSTALL:=true}"
: "${ROLE:=all}"
: "${NO_CLAUDE_TOOLING:=false}"
: "${STATE_FILE:=}"

export INSTALL ROLE NO_CLAUDE_TOOLING ODYSSEUS_ROOT

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

# ─── Extend PATH so tools installed by Phase 2 are visible ───────────────────
for _p in \
    "$HOME/.pixi/bin" \
    "$HOME/.local/bin" \
    "/home/linuxbrew/.linuxbrew/bin" \
    "/usr/local/go/bin"
do
    [[ -d "$_p" ]] && [[ ":$PATH:" != *":$_p:"* ]] && export PATH="$_p:$PATH"
done
unset _p

# ─── Phase 30: Submodule initialization ──────────────────────────────────────
if _should_skip "30"; then
    check_skip "Phase 30: skipped (--skip)"
elif [[ "${PHASE_30_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 30: submodules — all initialized"
else
    echo ""
    echo -e "${BOLD}▶ Phase 30${NC} — submodules"
    # shellcheck source=30-submodules.sh
    source "$(dirname "${BASH_SOURCE[0]}")/30-submodules.sh"
fi

# ─── Phase 40: Pixi environments ─────────────────────────────────────────────
if _should_skip "40"; then
    check_skip "Phase 40: skipped (--skip)"
elif [[ "${PHASE_40_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 40: pixi-envs — all environments present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 40${NC} — pixi-envs"
    # shellcheck source=40-pixi-envs.sh
    source "$(dirname "${BASH_SOURCE[0]}")/40-pixi-envs.sh"
fi

# ─── Phase 50: C++ release builds ────────────────────────────────────────────
if _should_skip "50"; then
    check_skip "Phase 50: skipped (--skip)"
elif [[ "${PHASE_50_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 50: cpp-builds — all release artifacts present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 50${NC} — cpp-builds"
    # shellcheck source=50-cpp-builds.sh
    source "$(dirname "${BASH_SOURCE[0]}")/50-cpp-builds.sh"
fi

# ─── Phase 60: Claude Code tooling ───────────────────────────────────────────
if [[ "$NO_CLAUDE_TOOLING" == "true" ]]; then
    check_skip "Phase 60: claude-tooling skipped (--no-claude-tooling)"
elif _should_skip "60"; then
    check_skip "Phase 60: skipped (--skip)"
elif [[ "${PHASE_60_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 60: claude-tooling — all components present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 60${NC} — claude-tooling"
    # shellcheck source=60-claude-tooling.sh
    source "$(dirname "${BASH_SOURCE[0]}")/60-claude-tooling.sh"
fi
