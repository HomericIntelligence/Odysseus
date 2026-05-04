#!/usr/bin/env bash
# Phase 50 — C++ Release Builds
#
# Builds each C++ service (Agamemnon, Nestor, Keystone, Charybdis) in release
# mode using the CMakePresets.json "release" preset (confirmed present in all
# four repos). Installs binaries to $ODYSSEUS_RUNTIME_PREFIX (default: ~/.local).
#
# Conan deps are installed before cmake configure. The conan profile directory
# per repo is used when a conan/profiles/release profile exists, otherwise
# the "default" profile is used.
#
# Idempotent: cmake configure + build are safe to repeat.
#
# shellcheck disable=SC2015
set -uo pipefail

# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "C++ Release Builds"

# All four C++ repos have CMakePresets.json with a "release" configurePreset
CPP_REPOS=(
    "control/ProjectAgamemnon"
    "control/ProjectNestor"
    "provisioning/ProjectKeystone"
    "testing/ProjectCharybdis"
)

RUNTIME_PREFIX="${ODYSSEUS_RUNTIME_PREFIX:-$HOME/.local}"

if ! has_cmd pixi; then
    check_fail "pixi not found — install it first (phase 20/40)"
    return 0 2>/dev/null || exit 0
fi

# cmake may live in the pixi conda env rather than system PATH; that's fine —
# all build commands below use `pixi run -- cmake` which resolves it correctly.
if ! has_cmd cmake && ! pixi run -- cmake --version >/dev/null 2>&1; then
    check_fail "cmake not found (neither on PATH nor via pixi run) — install it first"
    return 0 2>/dev/null || exit 0
fi

# Ensure a conan default profile exists — required before conan install can run.
# `conan profile detect` is idempotent (no-op if profile already exists).
if pixi run -- conan --version >/dev/null 2>&1; then
    pixi run -- conan profile detect --exist-ok >/dev/null 2>&1 || true
fi

build_cpp_repo() {
    local repo="$1"
    local dir="$ODYSSEUS_ROOT/$repo"

    if [[ ! -d "$dir" ]]; then
        check_warn "$repo — directory not found (submodule not initialized?)"
        return 0
    fi

    if [[ ! -f "$dir/CMakeLists.txt" ]]; then
        check_warn "$repo — CMakeLists.txt not found (skipped)"
        return 0
    fi

    if [[ "${INSTALL:-false}" != "true" ]]; then
        # Check-only: look for build artifacts
        if [[ -f "$dir/build/release/CMakeCache.txt" ]]; then
            check_pass "$repo — release build present"
        else
            check_warn "$repo — release build not found (run with --install to build)"
        fi
        return 0
    fi

    echo -e "\n    ${BLUE}▶${NC} Building $repo (release preset)"

    (
        cd "$dir"

        # ── Step 1: Conan deps ────────────────────────────────────────────────
        if has_cmd conan; then
            CONAN_PROFILE_ARGS=(-pr:h default -pr:b default)
            # Use repo-local release profile if it exists
            if [[ -f "conan/profiles/release" ]]; then
                CONAN_PROFILE_ARGS=(-pr:h conan/profiles/release -pr:b conan/profiles/release)
            fi
            echo -e "      ${DIM}conan install...${NC}"
            conan install . --build=missing -of build/conan "${CONAN_PROFILE_ARGS[@]}" \
                >/dev/null 2>&1 || true  # non-fatal — cmake will fail if truly missing
        else
            # Try via pixi run
            pixi run -- conan install . --build=missing -of build/conan \
                -pr:h default -pr:b default >/dev/null 2>&1 || true
        fi

        # ── Step 2: CMake configure (release preset) ──────────────────────────
        echo -e "      ${DIM}cmake --preset release...${NC}"
        if pixi run -- cmake --preset release \
            -DProjectAgamemnon_ENABLE_CLANG_TIDY=OFF \
            -DProjectNestor_ENABLE_CLANG_TIDY=OFF \
            -DENABLE_CLANG_TIDY=OFF \
            2>&1; then
            : # success
        else
            # Fallback: plain cmake without preset (in case toolchain file path differs)
            echo -e "      ${YELLOW}Preset failed — trying plain cmake...${NC}"
            pixi run -- cmake -B build/release \
                -DCMAKE_BUILD_TYPE=Release \
                -DENABLE_CLANG_TIDY=OFF \
                2>&1
        fi

        # ── Step 3: Build ─────────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --build...${NC}"
        pixi run -- cmake --build build/release -j"$(nproc)" 2>&1

        # ── Step 4: Install ───────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --install to $RUNTIME_PREFIX...${NC}"
        pixi run -- cmake --install build/release --prefix "$RUNTIME_PREFIX" 2>&1

    ) && check_pass "$repo — built and installed to $RUNTIME_PREFIX" \
      || check_warn "$repo — build failed (non-fatal; requires C++ toolchain + conan deps)"
}

for repo in "${CPP_REPOS[@]}"; do
    build_cpp_repo "$repo"
done

# Remind about PATH if binaries landed in ~/.local/bin
if [[ "${INSTALL:-false}" == "true" ]]; then
    if [[ ":$PATH:" != *":$RUNTIME_PREFIX/bin:"* ]]; then
        check_warn "Add $RUNTIME_PREFIX/bin to PATH: export PATH=\"$RUNTIME_PREFIX/bin:\$PATH\""
    fi
fi
