#!/usr/bin/env bash
# Phase 30 — Submodule Initialization
#
# Runs `git submodule update --init --recursive` and verifies that key
# submodule paths are non-empty after the operation.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "Submodule Initialization"

# Key sentinel files — if these exist the submodule is properly initialized
declare -A SENTINEL_FILES=(
    ["shared/ProjectHephaestus"]="shared/ProjectHephaestus/scripts/shell/install.sh"
    ["control/ProjectAgamemnon"]="control/ProjectAgamemnon/CMakeLists.txt"
    ["control/ProjectNestor"]="control/ProjectNestor/CMakeLists.txt"
    ["infrastructure/ProjectHermes"]="infrastructure/ProjectHermes/pixi.toml"
    ["infrastructure/ProjectArgus"]="infrastructure/ProjectArgus/pixi.toml"
    ["infrastructure/AchaeanFleet"]="infrastructure/AchaeanFleet/pixi.toml"
    ["provisioning/ProjectKeystone"]="provisioning/ProjectKeystone/CMakeLists.txt"
    ["provisioning/ProjectTelemachy"]="provisioning/ProjectTelemachy/pixi.toml"
    ["provisioning/Myrmidons"]="provisioning/Myrmidons/pixi.toml"
    ["research/ProjectOdyssey"]="research/ProjectOdyssey/pixi.toml"
    ["research/ProjectScylla"]="research/ProjectScylla/pixi.toml"
    ["shared/ProjectMnemosyne"]="shared/ProjectMnemosyne/scripts/validate_plugins.py"
    ["testing/ProjectCharybdis"]="testing/ProjectCharybdis/CMakeLists.txt"
    ["ci-cd/ProjectProteus"]="ci-cd/ProjectProteus/pixi.toml"
)

# Check current state
UNINITIALIZED=()
for mod in "${!SENTINEL_FILES[@]}"; do
    sentinel="${SENTINEL_FILES[$mod]}"
    if [[ -f "$ODYSSEUS_ROOT/$sentinel" ]]; then
        check_pass "$mod — initialized"
    else
        check_fail "$mod — NOT initialized (sentinel missing: $sentinel)"
        UNINITIALIZED+=("$mod")
    fi
done

if [[ ${#UNINITIALIZED[@]} -eq 0 ]]; then
    return 0 2>/dev/null || exit 0
fi

if [[ "${INSTALL:-false}" != "true" ]]; then
    check_warn "Run with --install to initialize submodules (git submodule update --init --recursive)"
    return 0 2>/dev/null || exit 0
fi

# Use --depth 1 --recommend-shallow so submodule fetches work correctly
# when the parent Odysseus repo was itself cloned with --depth 1.
echo -e "    ${BLUE}→${NC} Running: git submodule update --init --recursive --depth 1 --recommend-shallow"
if git -C "$ODYSSEUS_ROOT" submodule update --init --recursive --depth 1 --recommend-shallow; then
    # Re-verify sentinels after init
    STILL_MISSING=()
    for mod in "${UNINITIALIZED[@]}"; do
        sentinel="${SENTINEL_FILES[$mod]}"
        if [[ -f "$ODYSSEUS_ROOT/$sentinel" ]]; then
            check_pass "$mod — initialized"
        else
            check_fail "$mod — still empty after submodule update (check .gitmodules)"
            STILL_MISSING+=("$mod")
        fi
    done

    if [[ ${#STILL_MISSING[@]} -eq 0 ]]; then
        check_pass "All submodules initialized successfully"
    else
        check_fail "${#STILL_MISSING[@]} submodule(s) failed to initialize"
    fi
else
    check_fail "git submodule update --init --recursive failed"
fi
