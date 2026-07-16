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
#
# NOTE for future maintainers: every VALUE below MUST start with its
# corresponding KEY, byte-for-byte. The post-init re-verification loop
# performs `${SENTINEL_FILES[$mod]/"$mod"/"$resolved"}` to swap the prefix
# when `resolve_submodule_path` flips to the bare (post-rename) form on
# disk; the substitution silently no-ops if the value does not start with
# the key, producing a sentinel path that does not match the on-disk
# directory and falsely failing the install. Keep the invariant.
declare -A SENTINEL_FILES=(
    ["shared/Hephaestus"]="shared/Hephaestus/scripts/shell/install.sh"
    ["control/Agamemnon"]="control/Agamemnon/CMakeLists.txt"
    ["control/Nestor"]="control/Nestor/CMakeLists.txt"
    ["infrastructure/Hermes"]="infrastructure/Hermes/pixi.toml"
    ["infrastructure/Argus"]="infrastructure/Argus/pixi.toml"
    ["infrastructure/AchaeanFleet"]="infrastructure/AchaeanFleet/pixi.toml"
    ["provisioning/Keystone"]="provisioning/Keystone/CMakeLists.txt"
    ["provisioning/Telemachy"]="provisioning/Telemachy/pixi.toml"
    ["provisioning/Myrmidons"]="provisioning/Myrmidons/pixi.toml"
    ["research/Odyssey"]="research/Odyssey/pixi.toml"
    ["research/Scylla"]="research/Scylla/pixi.toml"
    ["shared/Mnemosyne"]="shared/Mnemosyne/scripts/validate_plugins.py"
    ["testing/Charybdis"]="testing/Charybdis/CMakeLists.txt"
    ["ci-cd/Proteus"]="ci-cd/Proteus/pixi.toml"
)

# Check current state.
#
# An uninitialized submodule is only a genuine FAILURE when we cannot fix it —
# i.e. in check-only mode, or if it is still missing after `git submodule
# update` runs below. During an --install run the pre-install "NOT initialized"
# is expected on a fresh clone and is retracted by the init step, so we record
# it as a warn (not a fail) and let the post-init re-verification cast the
# terminal verdict. This keeps a clean-image worker install at exit 0 (#393).
#
# Per ADR-015: SENTINEL_FILES keys may be either the prefixed `Project<X>`
# form (for repos whose upstream `gh repo rename` has not happened yet) or
# the bare `<X>` form (for repos that have been renamed upstream). Each
# sentinel VALUE mirrors the key path; we rewrite the value's prefix to
# match whatever `resolve_submodule_path` actually found on disk so the
# existence check is correct in either world.
UNINITIALIZED=()
for mod in "${!SENTINEL_FILES[@]}"; do
    resolved=$(resolve_submodule_path "$mod")
    sentinel="${SENTINEL_FILES[$mod]/"$mod"/"$resolved"}"
    if [[ -f "$ODYSSEUS_ROOT/$sentinel" ]]; then
        if [[ "$resolved" != "$mod" ]]; then
            check_pass "$resolved — initialized (dual-path resolve from $mod)"
        else
            check_pass "$resolved — initialized"
        fi
    elif [[ "${INSTALL:-false}" == "true" ]]; then
        # Deferred: the init step below will re-verify and pass/fail per module.
        UNINITIALIZED+=("$mod")
    else
        if [[ "$resolved" != "$mod" ]]; then
            check_warn "$resolved — not initialized (will run git submodule update; dual-path from $mod)"
        else
            check_warn "$resolved — not initialized (will run git submodule update)"
        fi
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
    # Re-verify sentinels after init. Resolve fresh (disk may have changed
    # during the init pass).
    STILL_MISSING=()
    for mod in "${UNINITIALIZED[@]}"; do
        resolved=$(resolve_submodule_path "$mod")
        sentinel="${SENTINEL_FILES[$mod]/"$mod"/"$resolved"}"
        if [[ -f "$ODYSSEUS_ROOT/$sentinel" ]]; then
            if [[ "$resolved" != "$mod" ]]; then
                check_pass "$resolved — initialized (dual-path resolve from $mod)"
            else
                check_pass "$resolved — initialized"
            fi
        else
            check_fail "$resolved — still empty after submodule update (check .gitmodules)"
            STILL_MISSING+=("$resolved")
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
