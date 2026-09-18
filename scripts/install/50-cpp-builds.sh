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
# ADR-015 forward-compatibility: CPP_REPOS below is the canonical pre-rename
# list. `resolve_submodule_path` (from lib.sh) may flip an entry from
# `Project<X>` to `<X>` on disk after the upstream `gh repo rename` lands;
# when this happens we surface `↻ ADR-015 dual-path: …` in the install log
# so operators can see both the list name and the actual on-disk path used.
#
# shellcheck disable=SC2015,SC2317
set -uo pipefail

# shellcheck source=scripts/install/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

section "C++ Release Builds"

# All four C++ repos have CMakePresets.json with a "release" configurePreset
CPP_REPOS=(
    "control/Agamemnon"
    "control/Nestor"
    "provisioning/Keystone"
    "testing/Charybdis"
)

RUNTIME_PREFIX="${ODYSSEUS_RUNTIME_PREFIX:-$HOME/.local}"
ROLE="${ROLE:-all}"
CPP_PHASE_FAILED=false
CPP_SECURITY_FAILED=false

cpp_role_requires_builds() {
    [[ "$ROLE" == "control" || "$ROLE" == "all" ]]
}

cpp_role_issue() {
    if cpp_role_requires_builds; then
        check_fail "$1"
        CPP_PHASE_FAILED=true
    else
        check_warn "$1"
    fi
}

cpp_security_issue() {
    check_fail "$1"
    CPP_PHASE_FAILED=true
    CPP_SECURITY_FAILED=true
}

# Cap build parallelism. Using -j"$(nproc)" makes every concurrent build claim
# all cores; when several Myrmidon agents build at once on the 16 GB / 8-core
# `hermes` WSL host this oversubscribes CPU ~2x and (with parallel pixi solves)
# exhausts RAM + swap, hanging the VM. Default 2 cores/build; with the agent
# concurrency cap (HERMES_MAX_CONCURRENT_AGENTS=3) that is <=6 of 8 cores.
# Override with ODYSSEUS_BUILD_JOBS. See Odysseus AGENTS.md "Safe autonomy".
BUILD_JOBS="${ODYSSEUS_BUILD_JOBS:-2}"
BUILD_VMEM_KB="${ODYSSEUS_BUILD_VMEM_KB:-6291456}"
MAX_BUILD_JOBS=8
MAX_BUILD_VMEM_KB=67108864

is_canonical_bounded_decimal() {
    local value=$1 maximum=$2 allow_zero=$3
    if [[ "$allow_zero" == "true" && "$value" == "0" ]]; then
        return 0
    fi
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ ${#value} -lt ${#maximum} ]] && return 0
    [[ ${#value} -eq ${#maximum} ]] || return 1
    (( 10#$value <= maximum ))
}

if ! is_canonical_bounded_decimal "$BUILD_JOBS" "$MAX_BUILD_JOBS" false; then
    check_fail "ODYSSEUS_BUILD_JOBS must be a canonical decimal from 1 through $MAX_BUILD_JOBS"
    return 0 2>/dev/null || exit 1
fi
if ! is_canonical_bounded_decimal \
    "$BUILD_VMEM_KB" "$MAX_BUILD_VMEM_KB" true; then
    check_fail "ODYSSEUS_BUILD_VMEM_KB must be literal 0 or a canonical decimal from 1 through $MAX_BUILD_VMEM_KB"
    return 0 2>/dev/null || exit 1
fi

# Bind the repository and every build input before the first tool process.
# Keep the descriptors open, and compare each live path with the bound identity
# before every later tool process. This makes a rename-and-replace fail closed.
cpp_path_state() {
    if stat -L -c '%d:%i:%f:%u:%g' -- "$1" 2>/dev/null; then
        return 0
    fi
    stat -L -f '%d:%i:%p:%u:%g' -- "$1" 2>/dev/null
}

cpp_path_inode() {
    if stat -L -c '%i' -- "$1" 2>/dev/null; then
        return 0
    fi
    stat -L -f '%i' -- "$1" 2>/dev/null
}

cpp_direct_directory() {
    local candidate=$1
    [[ -d "$candidate" && ! -L "$candidate" ]]
}

CPP_ROOT_FD=""
CPP_ROOT_STATE=""
CPP_ROOT_FD_INODE=""
CPP_BOUND_REPOS=()
CPP_BOUND_DIRS=()
CPP_PROJECT_FDS=()
CPP_PROJECT_STATES=()
CPP_PROJECT_FD_INODES=()
CPP_CMAKE_FDS=()
CPP_CMAKE_STATES=()
CPP_CMAKE_FD_INODES=()

if ! cpp_direct_directory "$ODYSSEUS_ROOT"; then
    cpp_security_issue "C++ repository root is missing, symlinked, or reaches a symlinked directory"
else
    if ! exec {CPP_ROOT_FD}<"$ODYSSEUS_ROOT"; then
        cpp_security_issue "C++ repository root descriptor cannot be opened"
    else
        CPP_ROOT_STATE=$(cpp_path_state "$ODYSSEUS_ROOT") || \
            cpp_security_issue "C++ repository root identity cannot be read"
        CPP_ROOT_FD_INODE=$(cpp_path_inode "/dev/fd/$CPP_ROOT_FD") || \
            cpp_security_issue "C++ repository root descriptor identity cannot be read"
    fi
fi

for repo in "${CPP_REPOS[@]}"; do
    resolved=$(resolve_submodule_path "$repo")
    if [[ "$resolved" != "$repo" ]]; then
        echo -e "    ${DIM}↻ ADR-015 dual-path: $repo → $resolved${NC}"
    fi
    dir="$ODYSSEUS_ROOT/$resolved"
    cmake_file="$dir/CMakeLists.txt"
    if [[ ! -e "$dir" && ! -L "$dir" ]]; then
        cpp_role_issue "$resolved — directory not found (submodule not initialized?)"
        continue
    fi
    if ! cpp_direct_directory "$dir"; then
        cpp_security_issue "$resolved — project directory is symlinked or reaches a symlinked directory"
        continue
    fi
    if [[ ! -f "$cmake_file" && ! -L "$cmake_file" ]]; then
        cpp_role_issue "$resolved — CMakeLists.txt not found (skipped)"
        continue
    fi
    if [[ -L "$cmake_file" || ! -f "$cmake_file" ]]; then
        cpp_security_issue "$resolved — CMakeLists.txt must be a direct regular file"
        continue
    fi

    project_fd=""
    cmake_fd=""
    if ! exec {project_fd}<"$dir" || ! exec {cmake_fd}<"$cmake_file"; then
        cpp_security_issue "$resolved — build input descriptors cannot be opened"
        continue
    fi
    project_state=$(cpp_path_state "$dir") || {
        cpp_security_issue "$resolved — project identity cannot be read"
        continue
    }
    project_fd_inode=$(cpp_path_inode "/dev/fd/$project_fd") || {
        cpp_security_issue "$resolved — project descriptor identity cannot be read"
        continue
    }
    cmake_state=$(cpp_path_state "$cmake_file") || {
        cpp_security_issue "$resolved — CMakeLists.txt identity cannot be read"
        continue
    }
    cmake_fd_inode=$(cpp_path_inode "/dev/fd/$cmake_fd") || {
        cpp_security_issue "$resolved — CMakeLists.txt descriptor identity cannot be read"
        continue
    }
    CPP_BOUND_REPOS+=("$resolved")
    CPP_BOUND_DIRS+=("$dir")
    CPP_PROJECT_FDS+=("$project_fd")
    CPP_PROJECT_STATES+=("$project_state")
    CPP_PROJECT_FD_INODES+=("$project_fd_inode")
    CPP_CMAKE_FDS+=("$cmake_fd")
    CPP_CMAKE_STATES+=("$cmake_state")
    CPP_CMAKE_FD_INODES+=("$cmake_fd_inode")
done

cpp_binding_is_current() {
    local index=$1 dir cmake_file
    dir=${CPP_BOUND_DIRS[$index]}
    cmake_file="$dir/CMakeLists.txt"
    [[ -n "$CPP_ROOT_FD" && ! -L "$ODYSSEUS_ROOT" \
        && "$(cpp_path_state "$ODYSSEUS_ROOT")" == "$CPP_ROOT_STATE" \
        && "$(cpp_path_inode "/dev/fd/$CPP_ROOT_FD")" == \
            "$CPP_ROOT_FD_INODE" \
        && -d "$dir" && ! -L "$dir" \
        && "$(cpp_path_state "$dir")" == "${CPP_PROJECT_STATES[$index]}" \
        && "$(cpp_path_inode "/dev/fd/${CPP_PROJECT_FDS[$index]}")" == \
            "${CPP_PROJECT_FD_INODES[$index]}" \
        && -f "$cmake_file" && ! -L "$cmake_file" \
        && "$(cpp_path_state "$cmake_file")" == \
            "${CPP_CMAKE_STATES[$index]}" \
        && "$(cpp_path_inode "/dev/fd/${CPP_CMAKE_FDS[$index]}")" == \
            "${CPP_CMAKE_FD_INODES[$index]}" ]]
}

cpp_all_bindings_are_current() {
    local index
    for index in "${!CPP_BOUND_REPOS[@]}"; do
        cpp_binding_is_current "$index" || return 1
    done
}

if $CPP_SECURITY_FAILED || { $CPP_PHASE_FAILED && cpp_role_requires_builds; }; then
    return 0 2>/dev/null || exit 1
fi

# Check-only is observational. It must not create the runtime prefix, populate
# a tool environment, create a Conan profile, or execute any build tool.
if [[ "${INSTALL:-false}" != "true" ]]; then
    for index in "${!CPP_BOUND_REPOS[@]}"; do
        resolved=${CPP_BOUND_REPOS[$index]}
        dir=${CPP_BOUND_DIRS[$index]}
        if [[ -f "$dir/build/release/CMakeCache.txt" ]]; then
            check_pass "$resolved — release build present"
        else
            check_warn "$resolved — release build not found (run with --install to build)"
        fi
    done
    return 0 2>/dev/null || exit 0
fi

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
    cpp_role_issue "pixi not found — C++ builds skipped (provisioned by phase 20; non-fatal for a worker)"
    if cpp_role_requires_builds; then
        return 0 2>/dev/null || exit 1
    fi
    return 0 2>/dev/null || exit 0
fi

# cmake may live in the pixi conda env rather than system PATH; that's fine —
# all build commands below use `pixi run -- cmake` which resolves it correctly.
if ! cpp_all_bindings_are_current; then
    cpp_security_issue "C++ build inputs changed before toolchain inspection"
    return 0 2>/dev/null || exit 1
fi
if ! has_cmd cmake && ! pixi run -- cmake --version >/dev/null 2>&1; then
    # cmake comes from the pixi env; missing here means the env is not yet
    # populated (detect time) or the build toolchain is unavailable on this
    # host. The C++ services are control-plane components, so for a worker this
    # is a WARN (skip the builds), not a hard fail. See issue #393.
    cpp_role_issue "cmake not found (neither on PATH nor via pixi run) — C++ builds skipped"
    if cpp_role_requires_builds; then
        return 0 2>/dev/null || exit 1
    fi
    return 0 2>/dev/null || exit 0
fi

# Ensure a system-level conan default profile exists so conan doesn't error
# when neither a system default nor a repo-local profile is available.
# `--exist-ok` makes this a true no-op when the profile already exists; a
# non-zero exit then signals a real problem (e.g. broken pixi env), so we
# warn but continue — the per-repo build step will surface the real cause.
if ! cpp_all_bindings_are_current; then
    cpp_security_issue "C++ build inputs changed before Conan profile inspection"
    return 0 2>/dev/null || exit 1
fi
if ! pixi run -- conan profile detect --exist-ok >/dev/null 2>&1; then
    cpp_role_issue "conan profile detect failed (pixi env may be broken); C++ builds skipped"
    if cpp_role_requires_builds; then
        return 0 2>/dev/null || exit 1
    fi
    return 0 2>/dev/null || exit 0
fi
if ! cpp_all_bindings_are_current; then
    cpp_security_issue "C++ build inputs changed during Conan profile inspection"
    return 0 2>/dev/null || exit 1
fi

build_cpp_repo() {
    local index=$1 repo dir build_status
    repo=${CPP_BOUND_REPOS[$index]}
    dir=${CPP_BOUND_DIRS[$index]}

    echo -e "\n    ${BLUE}▶${NC} Building $repo (release preset)"

    (
        cpp_binding_is_current "$index" || exit 90
        cd "$dir" || exit 1

        # Memory-bound this repo's conan+cmake+build pipeline. ulimit -v converts
        # an over-budget allocation into a recoverable failure of THIS subshell
        # instead of letting the kernel OOM-killer thrash and hang the whole WSL
        # VM (the failure mode that took down `hermes`). Default ~6 GiB/build;
        # override with ODYSSEUS_BUILD_VMEM_KB (0 disables the cap).
        _vmem_kb="$BUILD_VMEM_KB"
        if [[ "$_vmem_kb" != "0" ]]; then
            # Bind and apply the limit as required steps. A shell can reject a
            # lower limit because of a platform policy or an unavailable
            # resource-limit implementation. Do not continue to a stale build
            # or install result after either operation fails.
            if ! _cur_vmem="$(ulimit -v)"; then
                echo "      cannot inspect the virtual-memory limit" >&2
                exit 1
            fi
            if [[ "$_cur_vmem" == "unlimited" || "$_cur_vmem" -gt "$_vmem_kb" ]]; then
                if ! ulimit -v "$_vmem_kb"; then
                    echo "      cannot apply the virtual-memory limit" >&2
                    exit 1
                fi
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
        cpp_binding_is_current "$index" || exit 90
        if ! pixi run -- conan install . --build=missing \
            -of build/release \
            -pr:h "$CONAN_PROFILE" -pr:b "$CONAN_PROFILE" \
            2>&1; then
            exit 1
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
        cpp_binding_is_current "$index" || exit 90
        if ! pixi run -- cmake --preset release \
            -DAgamemnon_ENABLE_CLANG_TIDY=OFF \
            -DNestor_ENABLE_CLANG_TIDY=OFF \
            -DKeystone_ENABLE_CLANG_TIDY=OFF \
            -DCharybdis_ENABLE_CLANG_TIDY=OFF \
            -DNATS_BUILD_LIBS_SHARED=OFF \
            2>&1; then
            exit 1
        fi

        # ── Step 3: Build ─────────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --build (-j$BUILD_JOBS)...${NC}"
        cpp_binding_is_current "$index" || exit 90
        if ! pixi run -- cmake --build --preset release \
            -j"$BUILD_JOBS" 2>&1; then
            exit 1
        fi

        # ── Step 4: Install ───────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --install to $RUNTIME_PREFIX...${NC}"
        cpp_binding_is_current "$index" || exit 90
        if ! pixi run -- cmake --install build/release \
            --prefix "$RUNTIME_PREFIX" 2>&1; then
            exit 1
        fi

    )
    build_status=$?
    if [[ "$build_status" -eq 0 ]]; then
        check_pass "$repo — built and installed to $RUNTIME_PREFIX"
    elif [[ "$build_status" -eq 90 ]]; then
        cpp_security_issue "$repo — build input identity changed before a tool launch"
    else
        cpp_role_issue "$repo — build failed (non-fatal only for a worker; requires C++ toolchain + conan deps)"
    fi
}

# Per ADR-015: CPP_REPOS may mix prefixed (`Project<X>`) entries with bare
# (`<X>`) entries, depending on whether each repo's upstream `gh repo rename`
# has happened. `resolve_submodule_path` (from lib.sh) prefers the input form
# and falls back to the bare name when the prefixed form is absent on disk.
# When the resolver swaps the form (forward-compatible behaviour), surface it
# in the install log so operators can see both the original list name and the
# actual on-disk path used for the build.
for index in "${!CPP_BOUND_REPOS[@]}"; do
    build_cpp_repo "$index"
done

# Remind about PATH if binaries landed in ~/.local/bin
if [[ ":$PATH:" != *":$RUNTIME_PREFIX/bin:"* ]]; then
    check_warn "Add $RUNTIME_PREFIX/bin to PATH: export PATH=\"$RUNTIME_PREFIX/bin:\$PATH\""
fi

if $CPP_PHASE_FAILED; then
    return 0 2>/dev/null || exit 1
fi
