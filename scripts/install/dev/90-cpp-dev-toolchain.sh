#!/usr/bin/env bash
# Phase 90 — C++ Dev Toolchain
#
# Installs clang-tools and gcovr (via apt if available), then configures
# debug CMake presets for each C++ repo so developers get compile_commands.json
# and ASAN/sanitizer builds available immediately.
#
# Failures are warnings — production builds are unaffected.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=../lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib.sh"

section "C++ Dev Toolchain"

# ─── Install clang-tools and gcovr ───────────────────────────────────────────
DEV_APT_PKGS=(clang-tools gcovr)

if has_cmd apt-get; then
    MISSING_DEV_PKGS=()
    for pkg in "${DEV_APT_PKGS[@]}"; do
        if dpkg -l "$pkg" 2>/dev/null | grep -q "^ii" || has_cmd "$pkg"; then
            check_pass "$pkg — installed"
        else
            check_warn "$pkg — NOT FOUND"
            MISSING_DEV_PKGS+=("$pkg")
        fi
    done

    if [[ ${#MISSING_DEV_PKGS[@]} -gt 0 && "${INSTALL:-false}" == "true" ]]; then
        echo -e "    ${BLUE}→${NC} Installing: ${MISSING_DEV_PKGS[*]}"
        if sudo apt-get install -y "${MISSING_DEV_PKGS[@]}" >/dev/null 2>&1; then
            check_pass "Dev packages installed: ${MISSING_DEV_PKGS[*]}"
        else
            check_warn "apt-get install failed for: ${MISSING_DEV_PKGS[*]} (non-fatal)"
        fi
    fi
else
    check_warn "apt-get not available — skipping clang-tools/gcovr install (non-Debian host)"
fi

# ─── Configure debug presets for each C++ repo ───────────────────────────────
# All four repos have CMakePresets.json with a "debug" configurePreset.
CPP_REPOS=(
    "control/ProjectAgamemnon"
    "control/ProjectNestor"
    "provisioning/ProjectKeystone"
    "testing/ProjectCharybdis"
)

if ! has_cmd cmake; then
    check_warn "cmake not found — skipping debug preset configuration"
    return 0 2>/dev/null || exit 0
fi

for repo in "${CPP_REPOS[@]}"; do
    dir="$ODYSSEUS_ROOT/$repo"

    if [[ ! -f "$dir/CMakePresets.json" ]]; then
        check_skip "$repo — no CMakePresets.json (skipped)"
        continue
    fi

    if [[ "${INSTALL:-false}" != "true" ]]; then
        if [[ -f "$dir/build/debug/CMakeCache.txt" ]]; then
            check_pass "$repo — debug preset configured"
        else
            check_warn "$repo — debug preset not configured (run with --install)"
        fi
        continue
    fi

    echo -e "    ${BLUE}→${NC} cmake --preset debug (with clang-tidy): $repo"
    if (
        cd "$dir"
        pixi run -- cmake --preset debug \
            -DENABLE_CLANG_TIDY=ON \
            -DProjectAgamemnon_ENABLE_CLANG_TIDY=ON \
            -DProjectNestor_ENABLE_CLANG_TIDY=ON \
            2>&1
    ); then
        check_pass "$repo — debug preset configured"
    else
        check_warn "$repo — debug preset failed (non-fatal; check conan deps)"
    fi
done
