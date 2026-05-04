#!/usr/bin/env bash
# Phase 20 — Base Tooling
#
# Delegates to ProjectHephaestus/scripts/shell/install.sh which handles:
#   Homebrew, git, curl, jq, just, gh CLI, Node/npm, Tailscale, Python/pixi,
#   Go, NATS server, container runtime, C++ build chain, Claude Code, etc.
#
# Passes through the current --role and --install flags.
# Non-zero exit from ProjectHephaestus is recorded as a failure but execution
# continues so subsequent phases can still run.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Base Tooling (ProjectHephaestus)"

HEPHAESTUS="$ODYSSEUS_ROOT/shared/ProjectHephaestus"
HEPHAESTUS_INSTALLER="$HEPHAESTUS/scripts/shell/install.sh"

if [[ ! -f "$HEPHAESTUS_INSTALLER" ]]; then
    check_fail "ProjectHephaestus installer not found at $HEPHAESTUS_INSTALLER"
    check_warn "Run phase 30 (submodule init) first, then re-run phase 20."
    return 0 2>/dev/null || exit 0
fi

# Build argument list to forward
ARGS=(--role "$ROLE")
[[ "${INSTALL:-false}" == "true" ]] && ARGS+=(--install)

echo -e "    ${BLUE}→${NC} Running: bash $HEPHAESTUS_INSTALLER ${ARGS[*]}"
if bash "$HEPHAESTUS_INSTALLER" "${ARGS[@]}"; then
    check_pass "ProjectHephaestus base tooling: all checks passed"
else
    check_fail "ProjectHephaestus base tooling: one or more checks failed (see output above)"
fi
