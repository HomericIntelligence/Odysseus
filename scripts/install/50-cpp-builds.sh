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

# Pre-create install tree so nats.c FetchContent install doesn't fail trying
# to mkdir lib/pkgconfig inside cmake --install.
mkdir -p "$RUNTIME_PREFIX/bin" "$RUNTIME_PREFIX/lib/pkgconfig" "$RUNTIME_PREFIX/include" 2>/dev/null || true

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

# Ensure a system-level conan default profile exists so conan doesn't error
# when neither a system default nor a repo-local profile is available.
# This is a no-op if the system default profile already exists.
pixi run -- conan profile detect --exist-ok >/dev/null 2>&1 || true

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
        # Output folder must match CMakePresets.json toolchainFile path:
        #   build/${presetName}/conan_toolchain.cmake → -of build/release
        # Prefer the repo-local conan/profiles/default (has correct compiler
        # settings) over the system default which may not exist in the container.
        local CONAN_PROFILE="default"
        if [[ -f "conan/profiles/default" ]]; then
            CONAN_PROFILE="conan/profiles/default"
        fi
        echo -e "      ${DIM}conan install (profile: $CONAN_PROFILE)...${NC}"
        pixi run -- conan install . --build=missing \
            -of build/release \
            -pr:h "$CONAN_PROFILE" -pr:b "$CONAN_PROFILE" \
            2>&1 || true  # non-fatal — cmake will report the real error

        # ── Step 2: CMake configure (release preset) ──────────────────────────
        # The preset sets generator=Ninja and toolchainFile=build/release/conan_toolchain.cmake.
        # Both are satisfied: pixi env has Ninja on PATH and conan install wrote the toolchain.
        #
        # Clang-tidy: each repo uses ${PROJECT_NAME}_ENABLE_CLANG_TIDY. Pass all four to cover
        # every repo; cmake silently ignores unknown cache vars. The conda cross-compiler sysroot
        # causes 'stddef.h not found' when clang-tidy runs during build (it uses clang's headers
        # but the sysroot wchar.h tries to find stddef.h via a path clang doesn't know).
        #
        # NATS_BUILD_LIBS_SHARED=OFF: nats.c FetchContent cmake_install unconditionally
        # references libnats.so even when BUILD_SHARED_LIBS=OFF (set by conan toolchain),
        # causing cmake --install to fail.
        echo -e "      ${DIM}cmake --preset release...${NC}"
        pixi run -- cmake --preset release \
            -DProjectAgamemnon_ENABLE_CLANG_TIDY=OFF \
            -DProjectNestor_ENABLE_CLANG_TIDY=OFF \
            -DProjectKeystone_ENABLE_CLANG_TIDY=OFF \
            -DProjectCharybdis_ENABLE_CLANG_TIDY=OFF \
            -DNATS_BUILD_LIBS_SHARED=OFF \
            2>&1

        # ── Step 3: Build ─────────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --build...${NC}"
        pixi run -- cmake --build --preset release -j"$(nproc)" 2>&1

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
