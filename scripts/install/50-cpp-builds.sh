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

# Cap build parallelism. Using -j"$(nproc)" makes every concurrent build claim
# all cores; when several Myrmidon agents build at once on the 16 GB / 8-core
# `hermes` WSL host this oversubscribes CPU ~2x and (with parallel pixi solves)
# exhausts RAM + swap, hanging the VM. Default 2 cores/build; with the agent
# concurrency cap (HERMES_MAX_CONCURRENT_AGENTS=3) that is <=6 of 8 cores.
# Override with ODYSSEUS_BUILD_JOBS. See Odysseus CLAUDE.md "Resource limits".
BUILD_JOBS="${ODYSSEUS_BUILD_JOBS:-2}"

# Pre-create install tree so nats.c FetchContent install doesn't fail trying
# to mkdir lib/pkgconfig inside cmake --install.
if ! mkdir -p "$RUNTIME_PREFIX/bin" "$RUNTIME_PREFIX/lib/pkgconfig" "$RUNTIME_PREFIX/include"; then
    check_fail "Cannot create install tree under $RUNTIME_PREFIX (check write permissions)"
    return 0 2>/dev/null || exit 1
fi

if ! has_cmd pixi; then
    # pixi is provisioned by phase 20. Absent during Phase-1 detect (this script
    # is sourced before phase 20 runs) and, for a headless worker, the C++
    # control-plane builds below are non-fatal anyway (they already downgrade to
    # check_warn). So this is a WARN, not a hard fail — it must not trip the exit
    # gate on a clean worker image (#393).
    check_warn "pixi not found — C++ builds skipped (provisioned by phase 20; non-fatal for a worker)"
    return 0 2>/dev/null || exit 0
fi

# cmake may live in the pixi conda env rather than system PATH; that's fine —
# all build commands below use `pixi run -- cmake` which resolves it correctly.
if ! has_cmd cmake && ! pixi run -- cmake --version >/dev/null 2>&1; then
    # cmake comes from the pixi env; missing here means the env is not yet
    # populated (detect time) or the build toolchain is unavailable on this
    # host. The C++ services are control-plane components, so for a worker this
    # is a WARN (skip the builds), not a hard fail. See issue #393.
    check_warn "cmake not found (neither on PATH nor via pixi run) — C++ builds skipped"
    return 0 2>/dev/null || exit 0
fi

# Ensure a system-level conan default profile exists so conan doesn't error
# when neither a system default nor a repo-local profile is available.
# `--exist-ok` makes this a true no-op when the profile already exists; a
# non-zero exit then signals a real problem (e.g. broken pixi env), so we
# warn but continue — the per-repo build step will surface the real cause.
if ! pixi run -- conan profile detect --exist-ok >/dev/null 2>&1; then
    check_warn "conan profile detect failed (pixi env may be broken); continuing"
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

        # Memory-bound this repo's conan+cmake+build pipeline. ulimit -v converts
        # an over-budget allocation into a recoverable failure of THIS subshell
        # instead of letting the kernel OOM-killer thrash and hang the whole WSL
        # VM (the failure mode that took down `hermes`). Default ~6 GiB/build;
        # override with ODYSSEUS_BUILD_VMEM_KB (0 disables the cap).
        _vmem_kb="${ODYSSEUS_BUILD_VMEM_KB:-6291456}"
        if [[ "$_vmem_kb" != "0" ]]; then
            # `ulimit -v` fails only when RAISING a soft rlimit; we only ever
            # LOWER. Guard on the current limit so the call is always a genuine
            # lowering and cannot fail — removing the need for any suppression
            # (docs/runbooks/no-silent-failures.md).
            _cur_vmem="$(ulimit -v)"   # "unlimited" or a KiB integer
            if [[ "$_cur_vmem" == "unlimited" || "$_cur_vmem" -gt "$_vmem_kb" ]]; then
                ulimit -v "$_vmem_kb"
            fi
        fi

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
        # Non-fatal: cmake will report the real error if conan failed to
        # resolve deps. Wrap in `if` to make the suppression explicit.
        if ! pixi run -- conan install . --build=missing \
            -of build/release \
            -pr:h "$CONAN_PROFILE" -pr:b "$CONAN_PROFILE" \
            2>&1; then
            echo -e "      ${DIM}conan install failed (will retry implicitly via cmake)${NC}"
        fi

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
            -DAgamemnon_ENABLE_CLANG_TIDY=OFF \
            -DNestor_ENABLE_CLANG_TIDY=OFF \
            -DKeystone_ENABLE_CLANG_TIDY=OFF \
            -DCharybdis_ENABLE_CLANG_TIDY=OFF \
            -DNATS_BUILD_LIBS_SHARED=OFF \
            2>&1

        # ── Step 3: Build ─────────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --build (-j$BUILD_JOBS)...${NC}"
        pixi run -- cmake --build --preset release -j"$BUILD_JOBS" 2>&1

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
