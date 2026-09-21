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

cpp_build_issue() {
    check_fail "$1"
    CPP_PHASE_FAILED=true
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
    local value=$1 maximum=$2
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ ${#value} -lt ${#maximum} ]] && return 0
    [[ ${#value} -eq ${#maximum} ]] || return 1
    (( 10#$value <= maximum ))
}

if ! is_canonical_bounded_decimal "$BUILD_JOBS" "$MAX_BUILD_JOBS"; then
    check_fail "ODYSSEUS_BUILD_JOBS must be a canonical decimal from 1 through $MAX_BUILD_JOBS"
    return 0 2>/dev/null || exit 1
fi
if ! is_canonical_bounded_decimal "$BUILD_VMEM_KB" "$MAX_BUILD_VMEM_KB"; then
    check_fail "ODYSSEUS_BUILD_VMEM_KB must be a canonical decimal from 1 through $MAX_BUILD_VMEM_KB"
    return 0 2>/dev/null || exit 1
fi

# Bind each repository to one clean commit and tree before the first tool
# process. Install mode extracts that exact tree into a private snapshot. Build
# tools never read source or configuration bytes from the mutable checkout.
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

cpp_canonical_object_id() {
    [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

cpp_close_fd() {
    local descriptor=$1
    [[ "$descriptor" =~ ^[0-9]+$ ]] || return 1
    eval "exec ${descriptor}<&-"
}

if [[ -f /usr/bin/git && ! -L /usr/bin/git && -x /usr/bin/git ]]; then
    CPP_GIT=/usr/bin/git
else
    CPP_GIT=""
    if command -v git >/dev/null 2>&1; then
        CPP_GIT=$(command -v git)
    fi
fi
cpp_git() {
    env -i \
        HOME=/nonexistent \
        XDG_CONFIG_HOME=/nonexistent \
        GIT_CONFIG_NOSYSTEM=1 \
        PATH=/usr/bin:/bin \
        "$CPP_GIT" "$@"
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
CPP_GIT_DIRS=()
CPP_BOUND_COMMITS=()
CPP_BOUND_TREES=()

if [[ -z "$CPP_GIT" || "$CPP_GIT" != /* \
    || ! -f "$CPP_GIT" || -L "$CPP_GIT" || ! -x "$CPP_GIT" ]]; then
    cpp_security_issue "Git is unavailable through one direct executable"
fi

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
    project_root=$(cpp_git -C "$dir" rev-parse --show-toplevel 2>/dev/null) || {
        cpp_security_issue "$resolved — project Git root cannot be read"
        continue
    }
    physical_dir=$(cd "$dir" 2>/dev/null && pwd -P) || {
        cpp_security_issue "$resolved — physical project path cannot be read"
        continue
    }
    if [[ "$project_root" != "$physical_dir" ]]; then
        cpp_security_issue "$resolved — project is not an independent Git worktree"
        continue
    fi
    git_dir=$(cpp_git -C "$dir" rev-parse --absolute-git-dir 2>/dev/null) || {
        cpp_security_issue "$resolved — project Git directory cannot be read"
        continue
    }
    if [[ "$git_dir" != /* || ! -d "$git_dir" || -L "$git_dir" ]]; then
        cpp_security_issue "$resolved — project Git directory is not direct"
        continue
    fi
    bound_commit=$(cpp_git -C "$dir" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) || {
        cpp_security_issue "$resolved — project commit cannot be resolved"
        continue
    }
    bound_tree=$(cpp_git -C "$dir" rev-parse --verify "$bound_commit^{tree}" 2>/dev/null) || {
        cpp_security_issue "$resolved — project tree cannot be resolved"
        continue
    }
    if ! cpp_canonical_object_id "$bound_commit" \
        || ! cpp_canonical_object_id "$bound_tree"; then
        cpp_security_issue "$resolved — project object identity is malformed"
        continue
    fi
    if ! cpp_git -C "$dir" diff --quiet --no-ext-diff "$bound_commit" --; then
        cpp_security_issue "$resolved — tracked build inputs differ from the selected commit"
        continue
    fi
    if ! cpp_git -C "$dir" ls-files --error-unmatch -- \
        CMakeLists.txt CMakePresets.json >/dev/null 2>&1; then
        cpp_security_issue "$resolved — required CMake inputs are not tracked"
        continue
    fi
    tree_modes=$(cpp_git --git-dir="$git_dir" ls-tree -r \
        --format='%(objectmode)' "$bound_tree" 2>/dev/null) || {
        cpp_security_issue "$resolved — tracked input modes cannot be read"
        continue
    }
    if grep -q '^160000$' <<< "$tree_modes"; then
        cpp_security_issue "$resolved — nested Git links are outside the build snapshot"
        continue
    fi
    CPP_BOUND_REPOS+=("$resolved")
    CPP_BOUND_DIRS+=("$dir")
    CPP_PROJECT_FDS+=("$project_fd")
    CPP_PROJECT_STATES+=("$project_state")
    CPP_PROJECT_FD_INODES+=("$project_fd_inode")
    CPP_CMAKE_FDS+=("$cmake_fd")
    CPP_CMAKE_STATES+=("$cmake_state")
    CPP_CMAKE_FD_INODES+=("$cmake_fd_inode")
    CPP_GIT_DIRS+=("$git_dir")
    CPP_BOUND_COMMITS+=("$bound_commit")
    CPP_BOUND_TREES+=("$bound_tree")
done

cpp_binding_is_current() {
    local index=$1 dir cmake_file current_commit current_tree
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
            "${CPP_CMAKE_FD_INODES[$index]}" ]] || return 1
    current_commit=$(cpp_git -C "$dir" rev-parse --verify \
        'HEAD^{commit}' 2>/dev/null) || return 1
    current_tree=$(cpp_git -C "$dir" rev-parse --verify \
        "$current_commit^{tree}" 2>/dev/null) || return 1
    [[ "$current_commit" == "${CPP_BOUND_COMMITS[$index]}" \
        && "$current_tree" == "${CPP_BOUND_TREES[$index]}" ]] || return 1
    cpp_git -C "$dir" diff --quiet --no-ext-diff "$current_commit" --
}

cpp_all_bindings_are_current() {
    local index
    for index in "${!CPP_BOUND_REPOS[@]}"; do
        cpp_binding_is_current "$index" || return 1
    done
}

cpp_release_checkout_descriptors() {
    local descriptor close_failed=false
    if [[ -n "$CPP_ROOT_FD" ]]; then
        cpp_close_fd "$CPP_ROOT_FD" || close_failed=true
    fi
    for descriptor in "${CPP_PROJECT_FDS[@]}" "${CPP_CMAKE_FDS[@]}"; do
        cpp_close_fd "$descriptor" || close_failed=true
    done
    CPP_ROOT_FD=""
    CPP_PROJECT_FDS=()
    CPP_CMAKE_FDS=()
    ! $close_failed
}

if $CPP_SECURITY_FAILED || { $CPP_PHASE_FAILED && cpp_role_requires_builds; }; then
    cpp_release_checkout_descriptors || \
        cpp_security_issue "checkout descriptors could not be released"
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
    cpp_release_checkout_descriptors || \
        cpp_security_issue "checkout descriptors could not be released"
    if (return 0 2>/dev/null); then return 0; fi
    exit 0
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
    if (return 0 2>/dev/null); then return 0; fi
    exit 0
fi

RUN_BOUNDED="$ODYSSEUS_ROOT/scripts/run-bounded.sh"
CPP_BASH=/bin/bash
if [[ -f /usr/bin/bsdtar && ! -L /usr/bin/bsdtar \
    && -x /usr/bin/bsdtar ]]; then
    CPP_TAR=/usr/bin/bsdtar
else
    CPP_TAR=/usr/bin/tar
fi
CPP_PRIVATE_ROOT=""
CPP_PRIVATE_ROOT_FD=""
CPP_PRIVATE_ROOT_STATE=""
CPP_PRIVATE_ROOT_FD_INODE=""
RUN_BOUNDED_FD=""
RUN_BOUNDED_FD_INODE=""
CPP_SNAPSHOT_PATHS=()
CPP_SNAPSHOT_EXEC_ROOTS=()
CPP_SNAPSHOT_FDS=()
CPP_SNAPSHOT_STATES=()
CPP_SNAPSHOT_FD_INODES=()

cpp_private_root_is_current() {
    [[ -n "$CPP_PRIVATE_ROOT" && -n "$CPP_PRIVATE_ROOT_FD" \
        && -d "$CPP_PRIVATE_ROOT" && ! -L "$CPP_PRIVATE_ROOT" \
        && "$(cpp_path_state "$CPP_PRIVATE_ROOT")" == \
            "$CPP_PRIVATE_ROOT_STATE" \
        && "$(cpp_path_inode "/dev/fd/$CPP_PRIVATE_ROOT_FD")" == \
            "$CPP_PRIVATE_ROOT_FD_INODE" ]]
}

cpp_cleanup_private_root() {
    local descriptor path cleanup_failed=false
    if [[ -n "$CPP_PRIVATE_ROOT" ]]; then
        if cpp_private_root_is_current; then
            while IFS= read -r -d '' path; do
                chmod u+w "$path" || cleanup_failed=true
            done < <(find "$CPP_PRIVATE_ROOT" -type d -print0)
            while IFS= read -r -d '' path; do
                chmod u+w "$path" || cleanup_failed=true
            done < <(find "$CPP_PRIVATE_ROOT" -type f -print0)
            if ! $cleanup_failed; then
                /bin/rm -rf -- "$CPP_PRIVATE_ROOT" || cleanup_failed=true
            fi
        else
            cleanup_failed=true
        fi
    fi
    for descriptor in "${CPP_SNAPSHOT_FDS[@]}"; do
        cpp_close_fd "$descriptor" || cleanup_failed=true
    done
    if [[ -n "$RUN_BOUNDED_FD" ]]; then
        cpp_close_fd "$RUN_BOUNDED_FD" || cleanup_failed=true
    fi
    if [[ -n "$CPP_PRIVATE_ROOT_FD" ]]; then
        cpp_close_fd "$CPP_PRIVATE_ROOT_FD" || cleanup_failed=true
    fi
    if $cleanup_failed; then
        cpp_security_issue "private C++ build snapshots could not be cleaned safely"
        return 1
    fi
}

cpp_prepare_private_root() {
    local private_base=${TMPDIR:-/tmp}
    CPP_PRIVATE_ROOT=$(mktemp -d \
        "$private_base/odysseus-cpp-build.XXXXXXXX") || return 1
    chmod 0700 "$CPP_PRIVATE_ROOT" || return 1
    exec {CPP_PRIVATE_ROOT_FD}<"$CPP_PRIVATE_ROOT" || return 1
    CPP_PRIVATE_ROOT_STATE=$(cpp_path_state "$CPP_PRIVATE_ROOT") || return 1
    CPP_PRIVATE_ROOT_FD_INODE=$(cpp_path_inode \
        "/dev/fd/$CPP_PRIVATE_ROOT_FD") || return 1
}

cpp_bind_run_bounded() {
    local source_fd="" source_state source_inode helper_copy
    if ! exec {source_fd}<"$RUN_BOUNDED"; then
        return 1
    fi
    source_state=$(cpp_path_state "$RUN_BOUNDED") || return 1
    source_inode=$(cpp_path_inode "/dev/fd/$source_fd") || return 1
    helper_copy="$CPP_PRIVATE_ROOT/run-bounded.snapshot"
    if ! /bin/cp "/dev/fd/$source_fd" "$helper_copy" \
        || ! cmp -s -- "$RUN_BOUNDED" "$helper_copy" \
        || [[ "$(cpp_path_state "$RUN_BOUNDED")" != "$source_state" ]] \
        || [[ "$(cpp_path_inode "/dev/fd/$source_fd")" != \
            "$source_inode" ]]; then
        cpp_close_fd "$source_fd"
        return 1
    fi
    chmod 0400 "$helper_copy" || return 1
    exec {RUN_BOUNDED_FD}<"$helper_copy" || return 1
    RUN_BOUNDED_FD_INODE=$(cpp_path_inode \
        "/dev/fd/$RUN_BOUNDED_FD") || return 1
    /bin/rm -f -- "$helper_copy" || return 1
    cpp_close_fd "$source_fd"
}

cpp_relative_symlink_is_internal() {
    local relative=$1 target=$2 combined component remaining depth=0
    [[ -n "$target" && "$target" != /* ]] || return 1
    if [[ "$relative" == */* ]]; then
        combined="${relative%/*}/$target"
    else
        combined=$target
    fi
    remaining=$combined
    while [[ -n "$remaining" ]]; do
        if [[ "$remaining" == */* ]]; then
            component=${remaining%%/*}
            remaining=${remaining#*/}
        else
            component=$remaining
            remaining=""
        fi
        case "$component" in
            ''|.) ;;
            ..)
                (( depth > 0 )) || return 1
                depth=$((depth - 1))
                ;;
            *) depth=$((depth + 1)) ;;
        esac
    done
}

cpp_snapshot_is_current() {
    local index=$1 root
    root=${CPP_SNAPSHOT_EXEC_ROOTS[$index]}
    [[ -d "${CPP_SNAPSHOT_PATHS[$index]}" \
        && ! -L "${CPP_SNAPSHOT_PATHS[$index]}" \
        && "$(cpp_path_state "${CPP_SNAPSHOT_PATHS[$index]}")" == \
            "${CPP_SNAPSHOT_STATES[$index]}" \
        && "$(cpp_path_inode "/dev/fd/${CPP_SNAPSHOT_FDS[$index]}")" == \
            "${CPP_SNAPSHOT_FD_INODES[$index]}" ]] || return 1
    cpp_git --git-dir="${CPP_GIT_DIRS[$index]}" \
        --work-tree="$root" diff --quiet --no-ext-diff \
        "${CPP_BOUND_COMMITS[$index]}" --
}

cpp_all_snapshots_are_current() {
    local index
    for index in "${!CPP_BOUND_REPOS[@]}"; do
        cpp_snapshot_is_current "$index" || return 1
    done
}

cpp_prepare_snapshot() {
    local index=$1 snapshot snapshot_fd="" snapshot_state snapshot_inode
    local snapshot_exec symlink relative target unexpected
    local conan_manifest=false permission_failed=false
    cpp_binding_is_current "$index" || return 1
    snapshot="$CPP_PRIVATE_ROOT/sources/${CPP_BOUND_REPOS[$index]}"
    mkdir -p "$snapshot" || return 1
    if ! cpp_git --git-dir="${CPP_GIT_DIRS[$index]}" archive \
        --format=tar "${CPP_BOUND_TREES[$index]}" \
        | "$CPP_TAR" -xf - -C "$snapshot"; then
        return 1
    fi
    if [[ -f "$snapshot/conanfile.py" && ! -L "$snapshot/conanfile.py" ]] \
        || [[ -f "$snapshot/conanfile.txt" \
            && ! -L "$snapshot/conanfile.txt" ]]; then
        conan_manifest=true
    fi
    if ! $conan_manifest \
        || [[ ! -f "$snapshot/CMakeLists.txt" \
        || -L "$snapshot/CMakeLists.txt" \
        || ! -f "$snapshot/CMakePresets.json" \
        || -L "$snapshot/CMakePresets.json" \
        || ! -f "$snapshot/conan/profiles/default" \
        || -L "$snapshot/conan/profiles/default" \
        || -e "$snapshot/build" || -L "$snapshot/build" ]]; then
        return 1
    fi
    unexpected=$(find "$snapshot" ! -type d ! -type f ! -type l \
        -print -quit) || return 1
    [[ -z "$unexpected" ]] || return 1
    while IFS= read -r -d '' symlink; do
        relative=${symlink#"$snapshot"/}
        target=$(readlink "$symlink") || return 1
        cpp_relative_symlink_is_internal "$relative" "$target" || return 1
    done < <(find "$snapshot" -type l -print0)
    mkdir -p "$snapshot/build/release" || return 1
    while IFS= read -r -d '' relative; do
        chmod a-w "$relative" || permission_failed=true
    done < <(find "$snapshot" -type f -print0)
    while IFS= read -r -d '' relative; do
        chmod a-w "$relative" || permission_failed=true
    done < <(find "$snapshot" -type d -print0)
    if $permission_failed; then
        return 1
    fi
    chmod 0700 "$snapshot/build" "$snapshot/build/release" || return 1
    exec {snapshot_fd}<"$snapshot" || return 1
    snapshot_state=$(cpp_path_state "$snapshot") || return 1
    snapshot_inode=$(cpp_path_inode "/dev/fd/$snapshot_fd") || return 1
    snapshot_exec=$snapshot
    if [[ -d "/proc/self/fd/$snapshot_fd" ]] \
        && (cd "/proc/self/fd/$snapshot_fd" 2>/dev/null); then
        snapshot_exec="/proc/self/fd/$snapshot_fd"
    elif [[ -d "/dev/fd/$snapshot_fd" ]] \
        && (cd "/dev/fd/$snapshot_fd" 2>/dev/null); then
        snapshot_exec="/dev/fd/$snapshot_fd"
    fi
    CPP_SNAPSHOT_PATHS[index]=$snapshot
    CPP_SNAPSHOT_EXEC_ROOTS[index]=$snapshot_exec
    CPP_SNAPSHOT_FDS[index]=$snapshot_fd
    CPP_SNAPSHOT_STATES[index]=$snapshot_state
    CPP_SNAPSHOT_FD_INODES[index]=$snapshot_inode
    cpp_snapshot_is_current "$index"
}

if [[ ! -f "$RUN_BOUNDED" || -L "$RUN_BOUNDED" || ! -x "$RUN_BOUNDED" \
    || "$CPP_BASH" != /* || ! -f "$CPP_BASH" || -L "$CPP_BASH" \
    || ! -x "$CPP_BASH" || "$CPP_TAR" != /* || ! -f "$CPP_TAR" \
    || -L "$CPP_TAR" || ! -x "$CPP_TAR" ]]; then
    cpp_build_issue "aggregate build containment is unavailable"
    return 0 2>/dev/null || exit 1
fi
if ! cpp_prepare_private_root || ! cpp_bind_run_bounded; then
    cpp_build_issue "private build-tool binding is unavailable"
    cpp_cleanup_private_root
    return 0 2>/dev/null || exit 1
fi
for index in "${!CPP_BOUND_REPOS[@]}"; do
    if ! cpp_prepare_snapshot "$index"; then
        cpp_security_issue "${CPP_BOUND_REPOS[$index]} — tracked input snapshot failed"
        cpp_cleanup_private_root
        return 0 2>/dev/null || exit 1
    fi
done
if ! cpp_release_checkout_descriptors; then
    cpp_security_issue "checkout descriptors could not be released"
    cpp_cleanup_private_root
    return 0 2>/dev/null || exit 1
fi
bounded_pixi() {
    [[ "$(cpp_path_inode "/dev/fd/$RUN_BOUNDED_FD")" == \
        "$RUN_BOUNDED_FD_INODE" ]] || return 125
    RUN_BOUNDED_VMEM_KB="$BUILD_VMEM_KB" \
        "$CPP_BASH" "/dev/fd/$RUN_BOUNDED_FD" pixi "$@"
}

# cmake may live in the pixi conda env rather than system PATH; that's fine —
# all build commands below use `pixi run -- cmake` which resolves it correctly.
if ! cpp_all_snapshots_are_current; then
    cpp_security_issue "C++ build snapshots changed before toolchain inspection"
    cpp_cleanup_private_root
    return 0 2>/dev/null || exit 1
fi
if ! has_cmd cmake && ! bounded_pixi run -- cmake --version >/dev/null 2>&1; then
    # cmake comes from the pixi env; missing here means the env is not yet
    # populated (detect time) or the build toolchain is unavailable on this
    # host. The C++ services are control-plane components, so for a worker this
    # is a WARN (skip the builds), not a hard fail. See issue #393.
    cpp_role_issue "cmake not found (neither on PATH nor via pixi run) — C++ builds skipped"
    cpp_cleanup_private_root
    if cpp_role_requires_builds; then
        return 0 2>/dev/null || exit 1
    fi
    if (return 0 2>/dev/null); then return 0; fi
    exit 0
fi

# Ensure a system-level conan default profile exists so conan doesn't error
# when neither a system default nor a repo-local profile is available.
# `--exist-ok` makes this a true no-op when the profile already exists; a
# non-zero exit then signals a real problem (e.g. broken pixi env), so we
# warn but continue — the per-repo build step will surface the real cause.
if ! cpp_all_snapshots_are_current; then
    cpp_security_issue "C++ build snapshots changed before Conan profile inspection"
    cpp_cleanup_private_root
    return 0 2>/dev/null || exit 1
fi
if ! bounded_pixi run -- conan profile detect --exist-ok >/dev/null 2>&1; then
    cpp_role_issue "conan profile detect failed (pixi env may be broken); C++ builds skipped"
    cpp_cleanup_private_root
    if cpp_role_requires_builds; then
        return 0 2>/dev/null || exit 1
    fi
    if (return 0 2>/dev/null); then return 0; fi
    exit 0
fi
if ! cpp_all_snapshots_are_current; then
    cpp_security_issue "C++ build snapshots changed during Conan profile inspection"
    cpp_cleanup_private_root
    return 0 2>/dev/null || exit 1
fi

build_cpp_repo() {
    local index=$1 repo dir build_status install_manifest installed_object
    local verified_objects
    repo=${CPP_BOUND_REPOS[$index]}
    dir=${CPP_SNAPSHOT_EXEC_ROOTS[$index]}

    echo -e "\n    ${BLUE}▶${NC} Building $repo (release preset)"

    (
        cpp_snapshot_is_current "$index" || exit 90
        cd "$dir" || exit 1

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
        cpp_snapshot_is_current "$index" || exit 90
        if ! bounded_pixi run -- conan install . --build=missing \
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
        cpp_snapshot_is_current "$index" || exit 90
        if ! bounded_pixi run -- cmake --preset release \
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
        cpp_snapshot_is_current "$index" || exit 90
        if ! bounded_pixi run -- cmake --build --preset release \
            -j"$BUILD_JOBS" 2>&1; then
            exit 1
        fi

        # ── Step 4: Install ───────────────────────────────────────────────────
        echo -e "      ${DIM}cmake --install to $RUNTIME_PREFIX...${NC}"
        cpp_snapshot_is_current "$index" || exit 90
        install_manifest=build/release/install_manifest.txt
        if [[ -L "$install_manifest" ]] \
            || ! : > "$install_manifest"; then
            echo "      cannot prepare a direct install manifest" >&2
            exit 1
        fi
        if ! bounded_pixi run -- cmake --install build/release \
            --prefix "$RUNTIME_PREFIX" 2>&1; then
            exit 1
        fi

        # A successful process status alone does not prove that CMake
        # published anything. The freshly truncated manifest must name at
        # least one object under the requested prefix, and every named object
        # must exist before this repository is reported as installed.
        if [[ ! -s "$install_manifest" || -L "$install_manifest" ]]; then
            echo "      install produced no verifiable manifest" >&2
            exit 1
        fi
        verified_objects=0
        while IFS= read -r installed_object; do
            [[ -n "$installed_object" ]] || continue
            case "$installed_object" in
                "$RUNTIME_PREFIX"/*) ;;
                *)
                    echo "      install manifest escaped the requested prefix" >&2
                    exit 1
                    ;;
            esac
            if [[ ! -e "$installed_object" && ! -L "$installed_object" ]]; then
                echo "      installed object is missing: $installed_object" >&2
                exit 1
            fi
            verified_objects=$((verified_objects + 1))
        done < "$install_manifest"
        if [[ "$verified_objects" -eq 0 ]]; then
            echo "      install manifest contained no objects" >&2
            exit 1
        fi

    )
    build_status=$?
    if [[ "$build_status" -eq 0 ]]; then
        check_pass "$repo — built and installed to $RUNTIME_PREFIX"
    elif [[ "$build_status" -eq 90 ]]; then
        cpp_security_issue "$repo — private build snapshot changed before a tool launch"
    else
        cpp_build_issue "$repo — build failed (requires C++ toolchain + conan deps)"
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

cpp_cleanup_private_root

# Remind about PATH if binaries landed in ~/.local/bin
if [[ ":$PATH:" != *":$RUNTIME_PREFIX/bin:"* ]]; then
    check_warn "Add $RUNTIME_PREFIX/bin to PATH: export PATH=\"$RUNTIME_PREFIX/bin:\$PATH\""
fi

if $CPP_PHASE_FAILED; then
    return 0 2>/dev/null || exit 1
fi
