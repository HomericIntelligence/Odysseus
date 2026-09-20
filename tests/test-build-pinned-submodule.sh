#!/usr/bin/env bash
# Behavior tests for exact-gitlink C++ build inputs.
#
# These tests use fake build tools. They never compile component sources.
set -uo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
ROOT=$(dirname "$SCRIPT_DIR")
JUST_BIN=$(command -v just) || {
    printf '%s\n' 'ERROR: just is required' >&2
    exit 1
}
GIT_BIN=$(command -v git) || {
    printf '%s\n' 'ERROR: git is required' >&2
    exit 1
}

passes=0
failures=0
skips=0

pass() {
    passes=$((passes + 1))
    printf 'PASS: %s\n' "$1"
}

fail() {
    failures=$((failures + 1))
    printf 'FAIL: %s\n' "$1" >&2
}

skip() {
    skips=$((skips + 1))
    printf 'SKIP: %s\n' "$1"
}

file_mode() {
    if /usr/bin/stat -c '%a' -- "$1" 2>/dev/null; then
        return 0
    fi
    /usr/bin/stat -f '%Lp' -- "$1" 2>/dev/null
}

fixture_prefix="${TMPDIR:-/tmp}/odysseus-pinned-build."
fixture=$(mktemp -d "${fixture_prefix}XXXXXX") || exit 1
fixture_suffix=${fixture#"$fixture_prefix"}
case "$fixture_suffix" in
    ''|*[!A-Za-z0-9]*)
        printf 'ERROR: unsafe fixture path: %s\n' "$fixture" >&2
        exit 1
        ;;
esac

cleanup() {
    local suffix=${fixture#"$fixture_prefix"}
    case "$suffix" in
        ''|*[!A-Za-z0-9]*)
            printf 'ERROR: refusing unsafe fixture cleanup: %s\n' \
                "$fixture" >&2
            return
            ;;
    esac
    [[ -d "$fixture" && ! -L "$fixture" ]] || return
    if ! chmod -R u+w "$fixture" 2>/dev/null; then :; fi
    /bin/rm -rf -- "$fixture"
}
if [[ ${ODYSSEUS_TEST_PRESERVE_FIXTURE:-0} == 1 ]]; then
    printf 'PRESERVE_FIXTURE=%s\n' "$fixture"
else
    trap cleanup EXIT
fi
mkdir -p "$fixture/runtime-tmp"
export TMPDIR="$fixture/runtime-tmp"

fixture_git() {
    env -i \
        HOME="$fixture/home" \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        "$GIT_BIN" "$@"
}

component="$fixture/component"
superproject="$fixture/superproject"
mkdir -p "$fixture/home" "$component/conan/profiles" \
    "$component/src" "$component/hello-world/src" \
    "$superproject/scripts" "$fixture/tools"

printf '%s\n' 'cmake_minimum_required(VERSION 3.20)' \
    'project(Agamemnon)' > "$component/CMakeLists.txt"
printf '%s\n' 'APPROVED_PINNED_SOURCE' > "$component/src/input.cpp"
ln -s src/input.cpp "$component/source-link"
printf '%s\n' 'cmake_minimum_required(VERSION 3.20)' \
    'project(hello_myrmidon)' > "$component/hello-world/CMakeLists.txt"
printf '%s\n' 'APPROVED_PINNED_SOURCE' \
    > "$component/hello-world/src/input.cpp"
ln -s src/input.cpp "$component/hello-world/source-link"
printf '%s\n' '[settings]' 'build_type=Debug' \
    > "$component/conan/profiles/debug"
printf '%s\n' '[settings]' 'build_type=Debug' \
    > "$component/conan/profiles/nestor-debug"
printf '%s\n' '[requires]' > "$component/conanfile.txt"
printf '%s\n' '[project]' 'name = "fixture"' \
    > "$component/pixi.toml"

fixture_git -C "$component" init -q
fixture_git -C "$component" config user.email test@example.invalid
fixture_git -C "$component" config user.name 'Pinned Build Test'
fixture_git -C "$component" config commit.gpgsign false
fixture_git -C "$component" add -- .
fixture_git -C "$component" commit -q -m 'fixture component'
pinned_component_commit=$(fixture_git -C "$component" rev-parse HEAD)

cp "$ROOT/justfile" "$superproject/justfile"
if [[ -f "$ROOT/scripts/build-pinned-submodule.sh" ]]; then
    cp "$ROOT/scripts/build-pinned-submodule.sh" \
        "$superproject/scripts/build-pinned-submodule.sh"
    chmod +x "$superproject/scripts/build-pinned-submodule.sh"
fi

# A deterministic, non-cgroup fixture replaces the real containment helper.
# The production script must still bind and execute this exact file by an open
# descriptor; the fake merely keeps this test build-free and portable to macOS.
printf '#!/usr/bin/env bash\nset -euo pipefail\nfixture=%q\n' "$fixture" \
    > "$superproject/scripts/run-bounded.sh"
cat >> "$superproject/scripts/run-bounded.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

if [[ -e "$fixture/enable-tool-state-substitution" ]]; then
    tool_state=$GIT_CEILING_DIRECTORIES/tool-state
    mv "$tool_state" "$tool_state.bound-original"
    mv "$fixture/tool-state-substitution-victim" "$tool_state"
    printf '%s\n' "$tool_state" > "$fixture/tool-state-substitution-path"
    /bin/rm -f -- "$fixture/enable-tool-state-substitution"
    : > "$fixture/tool-state-substitution-active"
fi

if [[ -e "$fixture/enable-external-source-mutation" ]]; then
    source_path=${5:-}
    (
        for _ in $(seq 1 500); do
            [[ -e "$HOME/source-mutation-ready" ]] && break
            sleep 0.01
        done
        [[ -e "$HOME/source-mutation-ready" ]] || exit 97
        chmod u+w "$source_path" "$source_path/src" \
            "$source_path/src/input.cpp"
        printf '%s\n' EXTERNAL_NAMESPACE_MUTATION \
            > "$source_path/src/input.cpp"
    ) &
fi

if [[ -e "$fixture/enable-counterfeit-null" ]]; then
    exec /usr/bin/python3 -c '
import ctypes
import os
import sys

libc = ctypes.CDLL(None, use_errno=True)
outer_uid = os.getuid()
outer_gid = os.getgid()
if libc.unshare(0x10000000 | 0x00020000) != 0:
    raise SystemExit(97)
try:
    with open("/proc/self/setgroups", "w", encoding="ascii") as stream:
        stream.write("deny\n")
except FileNotFoundError:
    pass
with open("/proc/self/uid_map", "w", encoding="ascii") as stream:
    stream.write(f"{outer_uid} {outer_uid} 1\n")
with open("/proc/self/gid_map", "w", encoding="ascii") as stream:
    stream.write(f"{outer_gid} {outer_gid} 1\n")
mount = libc.mount
mount.argtypes = [
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_ulong,
    ctypes.c_void_p,
]
mount.restype = ctypes.c_int
if mount(None, b"/", None, 16384 | (1 << 18), None) != 0:
    raise SystemExit(98)
if mount(os.fsencode(sys.argv[1]), b"/dev/null", None, 4096, None) != 0:
    raise SystemExit(99)
os.execv(sys.argv[2], sys.argv[2:])
' "$fixture/counterfeit-null" "$@"
fi

if [[ -e "$fixture/enable-pixi-in-place-rewrite" ]]; then
    printf '#!/bin/sh\n: > "%s"\nexit 96\n' \
        "$fixture/rewritten-pixi-executed" > "$fixture/tools/pixi"
    chmod +x "$fixture/tools/pixi"
    : > "$fixture/pixi-in-place-rewrite-fired"
    /bin/rm -f -- "$fixture/enable-pixi-in-place-rewrite"
fi

set +e
"$@"
status=$?
set -e
request=${HOME:-}/cleanup-substitution
if [[ -f "$request" && ! -L "$request" ]]; then
    IFS='|' read -r substitution_kind fixture_root < "$request"
    private_root=$GIT_CEILING_DIRECTORIES
    case "$substitution_kind" in
        root)
            mv "$private_root" "$private_root.bound-original"
            mv "$fixture_root/root-substitution-victim" "$private_root"
            printf '%s\n' "$private_root" \
                > "$fixture_root/root-substitution-path"
            ;;
        child)
            mv "$private_root/source" "$private_root/source.bound-original"
            mv "$fixture_root/child-substitution-victim" \
                "$private_root/source"
            printf '%s\n' "$private_root/source" \
                > "$fixture_root/child-substitution-path"
            ;;
        *) exit 96 ;;
    esac
fi
exit "$status"
EOF
chmod +x "$superproject/scripts/run-bounded.sh"

fixture_git -C "$superproject" init -q
fixture_git -C "$superproject" config user.email test@example.invalid
fixture_git -C "$superproject" config user.name 'Pinned Build Test'
fixture_git -C "$superproject" config commit.gpgsign false
component_paths=(
    control/Agamemnon
    control/Nestor
    testing/Charybdis
    provisioning/Keystone
    provisioning/Myrmidons
)
for component_path in "${component_paths[@]}"; do
    fixture_git -C "$superproject" -c protocol.file.allow=always \
        submodule add -q "$component" "$component_path"
done
fixture_git -C "$superproject" add -- .
fixture_git -C "$superproject" commit -q -m 'fixture superproject'
pinned_superproject_commit=$(fixture_git -C "$superproject" rev-parse HEAD)

# Leave the checkout on a later, hostile commit. The recorded superproject
# gitlink still selects the approved parent commit and must remain authoritative.
printf '%s\n' 'HOSTILE_UNPINNED_CHECKOUT' > "$component/src/input.cpp"
printf '%s\n' 'HOSTILE_UNPINNED_CHECKOUT' \
    > "$component/hello-world/src/input.cpp"
fixture_git -C "$component" add -- src/input.cpp hello-world/src/input.cpp
fixture_git -C "$component" commit -q -m 'unrecorded component commit'
unpinned_commit=$(fixture_git -C "$component" rev-parse HEAD)
printf '%s\n' 'HOSTILE_SUPERPROJECT_REPLACEMENT' \
    > "$component/src/input.cpp"
printf '%s\n' 'HOSTILE_SUPERPROJECT_REPLACEMENT' \
    > "$component/hello-world/src/input.cpp"
fixture_git -C "$component" add -- src/input.cpp hello-world/src/input.cpp
fixture_git -C "$component" commit -q -m 'replacement-ref component commit'
superproject_replacement_component=$(fixture_git -C "$component" rev-parse HEAD)
for component_path in "${component_paths[@]}"; do
    fixture_git -C "$superproject/$component_path" fetch -q origin
    fixture_git -C "$superproject/$component_path" checkout -q --detach \
        "$unpinned_commit"
done

# Install two independent replacement-ref attacks. The superproject replacement
# changes only Agamemnon's gitlink. The component replacement changes Nestor's
# pinned commit. Exact-gitlink resolution must ignore both replacement maps.
fixture_git -C "$superproject/control/Agamemnon" checkout -q --detach \
    "$superproject_replacement_component"
fixture_git -C "$superproject" add -- control/Agamemnon
fixture_git -C "$superproject" commit -q -m 'replacement superproject tree'
replacement_superproject_commit=$(fixture_git -C "$superproject" rev-parse HEAD)
fixture_git -C "$superproject" reset -q --hard "$pinned_superproject_commit"
fixture_git -C "$superproject/control/Agamemnon" checkout -q --detach \
    "$unpinned_commit"
fixture_git -C "$superproject" replace \
    "$pinned_superproject_commit" "$replacement_superproject_commit"
fixture_git -C "$superproject/control/Nestor" replace \
    "$pinned_component_commit" "$unpinned_commit"

printf '#!/usr/bin/env bash\nset -euo pipefail\nfixture=%q\n' "$fixture" \
    > "$fixture/tools/pixi"
cat >> "$fixture/tools/pixi" <<'EOF'
superproject=$fixture/superproject
mutable_source=$superproject/control/Agamemnon
mutation_marker=$fixture/mutated
observed_source=$fixture/observed-source
hostile_marker=$fixture/hostile-source-used
environment_log=$fixture/environment-log
command_log=$fixture/command-log
source_content_log=$fixture/source-content-log
git_environment_log=$fixture/git-environment-log

printf 'FIXTURE_ENV vmem=%s jobs=%s bash_env=%s git_config=%s git_system=%s git_replace=%s git_ceiling=%s home=%s pixi_home=%s pixi_cache=%s pixi_config=%s\n' \
    "${RUN_BOUNDED_VMEM_KB:-missing}" \
    "${CMAKE_BUILD_PARALLEL_LEVEL:-missing}" \
    "${BASH_ENV:-missing}" "${GIT_CONFIG_GLOBAL:-missing}" \
    "${GIT_CONFIG_NOSYSTEM:-missing}" "${GIT_NO_REPLACE_OBJECTS:-missing}" \
    "${GIT_CEILING_DIRECTORIES:-missing}" \
    "${HOME:-missing}" "${PIXI_HOME:-missing}" \
    "${PIXI_CACHE_DIR:-missing}" "${PIXI_CONFIG_FILE:-missing}"
printf 'FIXTURE_LAZY_FETCH %s\n' "${GIT_NO_LAZY_FETCH:-missing}"
printf 'FIXTURE_GIT global=%s replacements=%s\n' \
    "$(/usr/bin/git config --global --get test.poison 2>/dev/null || printf missing)" \
    "${GIT_NO_REPLACE_OBJECTS:-missing}"

if [[ -e "$fixture/enable-inherited-fd-probe" ]]; then
    if printf '%s\n' INHERITED_FD_WRITE >&12 2>/dev/null; then
        printf '%s\n' FIXTURE_INHERITED_FD_OPEN
    else
        printf '%s\n' FIXTURE_INHERITED_FD_CLOSED
    fi
fi

if [[ -e "$fixture/tool-state-substitution-active" ]]; then
    printf '%s\n' TOOL_STATE_CHILD_WRITE > "$HOME/escaped-write"
fi

if [[ -e "$fixture/enable-external-source-mutation" ]]; then
    : > "$HOME/source-mutation-ready"
    for _ in $(seq 1 500); do
        source_content=$(sed -n '1p' "$PWD/src/input.cpp")
        [[ "$source_content" == EXTERNAL_NAMESPACE_MUTATION ]] && break
        sleep 0.01
    done
    if [[ "$source_content" == EXTERNAL_NAMESPACE_MUTATION ]]; then
        printf '%s\n' FIXTURE_EXTERNAL_MUTATION_VISIBLE
    else
        printf '%s\n' FIXTURE_EXTERNAL_MUTATION_NOT_VISIBLE
    fi
fi

[[ ${1:-} == run ]] || exit 64
shift
if [[ ${1:-} == --frozen ]]; then
    shift
fi
if [[ ${1:-} == -- ]]; then
    shift
fi
command_name=${1:-}
if [[ $# -gt 0 ]]; then shift; fi
printf 'FIXTURE_COMMAND %s %s\n' "$command_name" "$*"

case "$command_name" in
    conan)
        if [[ -e "$fixture/fail-conan" ]]; then
            printf '%s\n' 'injected Conan failure' >&2
            exit 71
        fi
        ;;
    cmake)
        if [[ ${1:-} == --build && -e "$fixture/fail-build" ]]; then
            printf '%s\n' 'injected CMake build failure' >&2
            exit 73
        fi
        if [[ ${1:-} != --build && -e "$fixture/fail-configure" ]]; then
            printf '%s\n' 'injected CMake configure failure' >&2
            exit 72
        fi
        ;;
esac

if [[ "$command_name" == conan \
    && -e "$fixture/enable-checkout-mutation" ]]; then
    mutable_gitdir=$(
        env -i HOME="$fixture/home" GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 PATH=/usr/bin:/bin \
            /usr/bin/git -C "$mutable_source" rev-parse --absolute-git-dir
    )
    mv "$mutable_source" "$mutable_source.bound-original"
    mkdir -p "$mutable_source/src" "$mutable_source/conan/profiles"
    printf '%s\n' 'cmake_minimum_required(VERSION 3.20)' \
        'project(HostileReplacement)' > "$mutable_source/CMakeLists.txt"
    printf '%s\n' 'HOSTILE_REPLACEMENT_SOURCE' \
        > "$mutable_source/src/input.cpp"
    printf '%s\n' '[settings]' 'build_type=Release' \
        > "$mutable_source/conan/profiles/debug"
    printf '%s\n' '[requires]' > "$mutable_source/conanfile.txt"
    printf '%s\n' '[project]' 'name = "hostile"' \
        > "$mutable_source/pixi.toml"

    mv "$mutable_gitdir" "$mutable_gitdir.bound-original"
    mkdir -p "$mutable_gitdir"
    mv "$superproject/scripts/run-bounded.sh" \
        "$superproject/scripts/run-bounded.sh.bound-original"
    printf '#!/bin/sh\n: > "%s"\nexit 97\n' \
        "$fixture/hostile-bound-helper-used" \
        > "$superproject/scripts/run-bounded.sh"
    chmod +x "$superproject/scripts/run-bounded.sh"
    : > "$fixture/run-bounded-replaced"
    : > "$mutation_marker"
fi

if [[ "$command_name" == conan ]]; then
    if [[ -e "$fixture/enable-cleanup-root-substitution" ]]; then
        printf 'root|%s\n' "$fixture" > "$HOME/cleanup-substitution"
    fi
    if [[ -e "$fixture/enable-cleanup-child-substitution" ]]; then
        printf 'child|%s\n' "$fixture" > "$HOME/cleanup-substitution"
    fi
    if [[ -e "$fixture/enable-source-drift" ]]; then
        chmod u+w "$PWD" "$PWD/src"
        printf '%s\n' UNTRACKED_BUILD_INPUT > "$PWD/src/injected.cpp"
        chmod 0755 "$PWD/src"
        printf '%s\n' FIXTURE_SOURCE_DRIFT_SUCCEEDED
    fi
    if [[ -e "$fixture/enable-cleanup-hardlink" ]]; then
        ln "$fixture/cleanup-hardlink-target" "$PWD/.pixi/cleanup-hardlink"
        printf '%s\n' FIXTURE_CLEANUP_HARDLINK_CREATED
    fi
    output_folder=
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --output-folder=*) output_folder=${1#*=} ;;
            --output-folder|-of)
                shift
                output_folder=${1:-}
                ;;
            -of=*) output_folder=${1#*=} ;;
        esac
        if [[ $# -gt 0 ]]; then shift; fi
    done
    [[ -n "$output_folder" ]] || exit 65
    mkdir -p "$output_folder"
    printf '%s\n' '# fixture toolchain' \
        > "$output_folder/conan_toolchain.cmake"
    exit 0
fi

[[ "$command_name" == cmake ]] || exit 66
if [[ ${1:-} == --version ]]; then
    printf '%s\n' 'cmake version fixture'
    exit 0
fi
if [[ ${1:-} == --build ]]; then
    exit 0
fi

source_root=
build_root=
while [[ $# -gt 0 ]]; do
    case "$1" in
        -S)
            shift
            source_root=${1:-}
            ;;
        -B)
            shift
            build_root=${1:-}
            ;;
    esac
    if [[ $# -gt 0 ]]; then shift; fi
done
[[ -n "$source_root" && -n "$build_root" ]] || exit 67
mkdir -p "$build_root"
if [[ -L "$source_root/source-link" \
    && -f "$source_root/src/input.cpp" ]]; then
    source_content=$(sed -n '1p' "$source_root/src/input.cpp")
    printf 'FIXTURE_SOURCE %s|%s\n' "$source_root" "$source_content"
    if [[ "$source_content" == APPROVED_PINNED_SOURCE ]] \
        && grep -q '^APPROVED_PINNED_SOURCE$' "$source_root/source-link"; then
        printf 'FIXTURE_APPROVED_SOURCE %s\n' "$source_root"
    else
        printf '%s\n' FIXTURE_HOSTILE_SOURCE
    fi
    exit 0
fi
printf '%s\n' FIXTURE_HOSTILE_SOURCE
exit 91
EOF
chmod +x "$fixture/tools/pixi"
/bin/cp -- "$fixture/tools/pixi" "$fixture/original-pixi"

cat > "$fixture/hostile-bash-env" <<EOF
printf '%s\n' sourced > '$fixture/bash-env-sourced'
EOF
mkdir -p "$fixture/hostile-home"
printf '%s\n' '[test]' 'poison = visible' > "$fixture/hostile-home/.gitconfig"

if [[ $(uname -s) != Linux ]]; then
    set +e
    HOME="$fixture/hostile-home" BASH_ENV="$fixture/hostile-bash-env" \
    GIT_CONFIG_GLOBAL="$fixture/hostile-gitconfig" \
    ODYSSEUS_BUILD_JOBS=2 ODYSSEUS_BUILD_VMEM_KB=6291456 \
    PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" _build-keystone \
        > "$fixture/non-linux-boundary-output" 2>&1
    boundary_status=$?
    set -e
    if [[ "$boundary_status" -ne 0 \
        && $(grep -Fc \
            'ERROR: OS-enforced read-only source boundary requires Linux Landlock ABI 3 or newer' \
            "$fixture/non-linux-boundary-output") -eq 1 \
        && $(grep -Fc 'ERROR: Conan install failed with status 78' \
            "$fixture/non-linux-boundary-output") -eq 1 \
        && ! -e "$superproject/build/Keystone" ]]; then
        pass 'unsupported host fails closed without publishing a build output'
    else
        fail 'unsupported host bypassed or obscured the read-only boundary'
        sed -n '1,100p' "$fixture/non-linux-boundary-output" >&2
    fi

    fixture_git -C "$component" checkout -q --detach "$pinned_component_commit"
    nul_blob=$(printf 'src/\000input.cpp' | fixture_git -C "$component" \
        hash-object -w --stdin)
    fixture_git -C "$component" update-index --add --cacheinfo \
        "120000,$nul_blob,nul-link"
    fixture_git -C "$component" commit -q -m 'NUL symlink blob'
    nul_commit=$(fixture_git -C "$component" rev-parse HEAD)
    fixture_git -C "$superproject/provisioning/Keystone" fetch -q origin \
        "$nul_commit"
    fixture_git -C "$superproject" update-index --cacheinfo \
        "160000,$nul_commit,provisioning/Keystone"
    fixture_git -C "$superproject" commit -q -m 'pin NUL symlink fixture'
    set +e
    HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" _build-keystone \
        > "$fixture/nul-symlink-output" 2>&1
    nul_status=$?
    set -e
    if [[ "$nul_status" -ne 0 \
        && $(grep -Fc 'ERROR: component symlink target contains NUL' \
            "$fixture/nul-symlink-output") -eq 1 ]] \
        && ! grep -q 'OS-enforced read-only source boundary' \
            "$fixture/nul-symlink-output"; then
        pass 'NUL-bearing symlink blob is rejected byte-for-byte before tools'
    else
        fail 'NUL-bearing symlink blob was transformed or reached build tools'
        sed -n '1,100p' "$fixture/nul-symlink-output" >&2
    fi
    skip 'Linux Landlock build-stage behavior (CI-only on this macOS host)'
    printf '\n%d passed, %d failed, %d skipped\n' \
        "$passes" "$failures" "$skips"
    [[ "$failures" -eq 0 ]]
    exit
fi

# The public recipes must start the helper in privileged Bash mode. Exported
# functions are ambient code and must not run before the helper establishes its
# own executable and environment boundaries.
/bin/rm -rf -- "$superproject/build"
set +e
(
    # This function is exported for the recipe's Bash process.
    # shellcheck disable=SC2329
    env() {
        : > "$fixture/exported-env-function-ran"
        /usr/bin/env "$@"
    }
    export -f env
    HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
        /bin/bash -p "$superproject/scripts/build-pinned-submodule.sh" keystone
) > "$fixture/exported-function-output" 2>&1
exported_function_status=$?
set -e
if [[ "$exported_function_status" -eq 0 \
    && ! -e "$fixture/exported-env-function-ran" ]]; then
    pass 'public pinned-build recipes ignore exported shell functions'
else
    fail 'an exported shell function executed before the trusted boundary'
fi

# Rewriting the selected Pixi pathname in place after binding must not change
# the executable bytes used by any build stage.
/bin/rm -rf -- "$superproject/build"
: > "$fixture/enable-pixi-in-place-rewrite"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/pixi-in-place-rewrite-output" 2>&1
pixi_in_place_rewrite_status=$?
set -e
/bin/rm -f -- "$fixture/enable-pixi-in-place-rewrite"
if [[ "$pixi_in_place_rewrite_status" -eq 0 \
    && -e "$fixture/pixi-in-place-rewrite-fired" \
    && ! -e "$fixture/rewritten-pixi-executed" ]] \
    && grep -q '^FIXTURE_COMMAND conan ' \
        "$fixture/pixi-in-place-rewrite-output"; then
    pass 'in-place Pixi rewrites cannot alter the sealed executable snapshot'
else
    fail 'an in-place Pixi rewrite changed the selected build executable'
    sed -n '1,100p' "$fixture/pixi-in-place-rewrite-output" >&2
fi
/bin/cp -- "$fixture/original-pixi" "$fixture/tools/pixi"
chmod +x "$fixture/tools/pixi"

# A caller-owned descriptor that was opened before Landlock must not remain a
# write capability in the selected build tool.
/bin/rm -rf -- "$superproject/build"
: > "$fixture/enable-inherited-fd-probe"
: > "$fixture/inherited-fd-sentinel"
set +e
(
    exec 12>> "$fixture/inherited-fd-sentinel"
    HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" _build-keystone
) > "$fixture/inherited-fd-output" 2>&1
inherited_fd_status=$?
set -e
/bin/rm -f -- "$fixture/enable-inherited-fd-probe"
if [[ "$inherited_fd_status" -eq 0 \
    && ! -s "$fixture/inherited-fd-sentinel" ]] \
    && grep -q '^FIXTURE_INHERITED_FD_CLOSED$' \
        "$fixture/inherited-fd-output"; then
    pass 'build tools inherit no caller-owned writable descriptors'
else
    fail 'a caller-owned writable descriptor bypassed the source boundary'
fi

# Pixi state is selected through a retained directory object, not through a
# pathname that a same-UID actor can replace between validation and Landlock.
/bin/rm -rf -- "$superproject/build"
mkdir -p "$fixture/tool-state-substitution-victim"/{home,cache,config,tmp,pixi-home,pixi-cache,pixi-environments}
: > "$fixture/enable-tool-state-substitution"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/tool-state-substitution-output" 2>&1
tool_state_substitution_status=$?
set -e
/bin/rm -f -- "$fixture/enable-tool-state-substitution" \
    "$fixture/tool-state-substitution-active"
tool_state_substitution_path=
if [[ -f "$fixture/tool-state-substitution-path" ]]; then
    tool_state_substitution_path=$(sed -n '1p' \
        "$fixture/tool-state-substitution-path")
fi
if [[ "$tool_state_substitution_status" -ne 0 \
    && "$tool_state_substitution_path" == \
        "$fixture/runtime-tmp/odysseus-pinned-build."* \
    && ! -e "$tool_state_substitution_path/home/escaped-write" ]] \
    && grep -q '^FIXTURE_COMMAND conan ' \
        "$fixture/tool-state-substitution-output"; then
    pass 'late Pixi-state pathname substitution gains no write capability'
else
    fail 'late Pixi-state pathname substitution redirected a child write'
fi

# A process outside the selected tool's private mount namespace may retain a
# writable alias to the parent snapshot. Its mutation must never become visible
# through the exact read-only source object used by the tool.
/bin/rm -rf -- "$superproject/build"
: > "$fixture/enable-external-source-mutation"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/external-source-mutation-output" 2>&1
external_source_mutation_status=$?
set -e
/bin/rm -f -- "$fixture/enable-external-source-mutation"
if [[ "$external_source_mutation_status" -ne 0 ]] \
    && grep -q '^FIXTURE_EXTERNAL_MUTATION_NOT_VISIBLE$' \
        "$fixture/external-source-mutation-output" \
    && ! grep -q '^FIXTURE_EXTERNAL_MUTATION_VISIBLE$' \
        "$fixture/external-source-mutation-output"; then
    pass 'external namespace writes never alter child-visible source bytes'
else
    fail 'an external namespace write altered child-visible source bytes'
fi

# The only writable device exception is the kernel null character device. A
# regular file mounted at that pathname must fail before Pixi starts.
/bin/rm -rf -- "$superproject/build"
printf '%s\n' COUNTERFEIT_NULL > "$fixture/counterfeit-null"
: > "$fixture/enable-counterfeit-null"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/counterfeit-null-output" 2>&1
counterfeit_null_status=$?
set -e
/bin/rm -f -- "$fixture/enable-counterfeit-null"
if [[ "$counterfeit_null_status" -ne 0 \
    && $(grep -c '^FIXTURE_COMMAND ' "$fixture/counterfeit-null-output") -eq 0 ]] \
    && grep -q 'ERROR: /dev/null is not the kernel null character device' \
        "$fixture/counterfeit-null-output"; then
    pass 'a counterfeit null device is rejected before build tools'
else
    fail 'a counterfeit null device received a writable exception'
    sed -n '1,100p' "$fixture/counterfeit-null-output" >&2
fi

set +e
BASH_ENV="$fixture/hostile-bash-env" \
GIT_CONFIG_GLOBAL="$fixture/hostile-gitconfig" \
HOME="$fixture/hostile-home" \
ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 \
PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" build \
    > "$fixture/build-output" 2>&1
build_status=$?
set -e

if [[ "$build_status" -eq 0 ]]; then
    pass 'pinned build completes from exact gitlink objects'
else
    fail 'pinned build did not complete from exact gitlink objects'
    sed -n '1,120p' "$fixture/build-output" >&2
fi
if grep -q '^FIXTURE_APPROVED_SOURCE ' "$fixture/build-output"; then
    pass 'recorded gitlink bytes win over later checkout commits'
else
    fail 'recorded gitlink bytes win over later checkout commits'
fi
if [[ $(grep -c '^FIXTURE_APPROVED_SOURCE ' "$fixture/build-output") -eq 5 ]] \
    && ! grep -Fq "FIXTURE_APPROVED_SOURCE $superproject/" \
        "$fixture/build-output"; then
    pass 'all five CMake sources avoid mutable submodule checkout paths'
else
    fail 'all five CMake sources avoid mutable submodule checkout paths'
fi
if [[ $(grep -c '^FIXTURE_APPROVED_SOURCE /proc/self/fd/' \
    "$fixture/build-output") -eq 5 ]]; then
    pass 'Linux executes the snapshot through its open directory descriptor'
else
    fail 'Linux executes the snapshot through its open directory descriptor'
fi
if ! grep -q '^FIXTURE_HOSTILE_SOURCE$' "$fixture/build-output"; then
    pass 'replacement source bytes never reach CMake'
else
    fail 'replacement source bytes never reach CMake'
fi
for replacement_case in \
    'superproject:HOSTILE_SUPERPROJECT_REPLACEMENT' \
    'component:HOSTILE_UNPINNED_CHECKOUT'; do
    replacement_name=${replacement_case%%:*}
    replacement_value=${replacement_case#*:}
    if ! grep -Fq "|$replacement_value" "$fixture/build-output"; then
        pass "$replacement_name replacement refs cannot redirect pinned build input"
    else
        fail "$replacement_name replacement refs redirected pinned build input"
    fi
done
if [[ ! -e "$fixture/bash-env-sourced" ]]; then
    pass 'ambient BASH_ENV is excluded from bound build tools'
else
    fail 'ambient BASH_ENV is excluded from bound build tools'
fi
if grep -q 'FIXTURE_ENV vmem=6291456 jobs=2 bash_env=missing git_config=/dev/null git_system=1 git_replace=1 git_ceiling=.*odysseus-pinned-build.* home=' \
        "$fixture/build-output" \
    && ! grep -Fq "home=$fixture/hostile-home" "$fixture/build-output" \
    && grep -q 'pixi_home=.*pixi-home pixi_cache=.*pixi-cache pixi_config=.*pixi-config.toml' \
        "$fixture/build-output" \
    && [[ $(grep -c '^FIXTURE_LAZY_FETCH 1$' \
        "$fixture/build-output") -eq 14 ]] \
    && ! grep -q 'FIXTURE_GIT global=visible' "$fixture/build-output"; then
    pass 'every build stage scrubs ambient Git and Pixi configuration'
else
    fail 'build stages inherited ambient Git or Pixi configuration'
fi
if grep -Fq 'FIXTURE_COMMAND conan install . --output-folder=' \
        "$fixture/build-output" \
    && grep -Fq -- '--profile=conan/profiles/nestor-debug' \
        "$fixture/build-output" \
    && grep -Fq -- '-DCMAKE_BUILD_TYPE=Release' "$fixture/build-output" \
    && [[ $(grep -c '^FIXTURE_COMMAND cmake -S ' \
        "$fixture/build-output") -eq 5 ]] \
    && [[ $(grep -c '^FIXTURE_COMMAND cmake --build ' \
        "$fixture/build-output") -eq 5 ]]; then
    pass 'all component mappings preserve Conan and CMake stage arguments'
else
    fail 'all component mappings preserve Conan and CMake stage arguments'
fi
if [[ $(grep -Ec \
        '^FIXTURE_COMMAND conan .*--output-folder=/proc/self/fd/[0-9]+' \
        "$fixture/build-output") -eq 4 \
    && $(grep -Ec \
        '^FIXTURE_COMMAND cmake -S .* -B /proc/self/fd/[0-9]+' \
        "$fixture/build-output") -eq 5 \
    && $(grep -Ec \
        '^FIXTURE_COMMAND cmake --build /proc/self/fd/[0-9]+$' \
        "$fixture/build-output") -eq 5 ]]; then
    pass 'Linux build tools consume only the bound output descriptor path'
else
    fail 'Linux build tools consumed a mutable lexical output path'
fi
if [[ -d "$superproject/build/Agamemnon" \
    && -d "$superproject/build/Nestor" \
    && -d "$superproject/build/Charybdis" \
    && -d "$superproject/build/Keystone" \
    && -d "$superproject/build/Myrmidons/hello-world" ]]; then
    pass 'all component mappings preserve their root build outputs'
else
    fail 'all component mappings preserve their root build outputs'
fi

printf '%s\n' PREVIOUS_OUTPUT_SENTINEL \
    > "$superproject/build/Nestor/previous-output-sentinel"
: > "$fixture/fail-configure"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-nestor \
    > "$fixture/publication-failure-output" 2>&1
publication_failure_status=$?
set -e
/bin/rm -f -- "$fixture/fail-configure"
remaining_stages=$(/usr/bin/find "$superproject/build" -type d \
    -name '.*.odysseus-stage.*' -print | wc -l | tr -d ' ')
if [[ "$publication_failure_status" -ne 0 \
    && -f "$superproject/build/Nestor/previous-output-sentinel" \
    && $(sed -n '1p' \
        "$superproject/build/Nestor/previous-output-sentinel") == \
        PREVIOUS_OUTPUT_SENTINEL \
    && "$remaining_stages" -eq 0 ]]; then
    pass 'failed private build preserves prior output and removes its exact stage'
else
    fail 'failed private build replaced prior output or leaked a stage'
fi

output_case_names=(root-build-parent nested-myrmidons-parent)
output_case_components=(keystone myrmidon)
output_case_links=(
    "$superproject/build"
    "$superproject/build/Myrmidons"
)
output_case_targets=(
    "$fixture/outside-root-build"
    "$fixture/outside-myrmidons-build"
)
output_case_sentinels=(
    "$fixture/outside-root-build/Keystone/CMakeCache.txt"
    "$fixture/outside-myrmidons-build/hello-world/CMakeCache.txt"
)
for output_index in "${!output_case_names[@]}"; do
    output_case_name=${output_case_names[$output_index]}
    output_component=${output_case_components[$output_index]}
    output_link=${output_case_links[$output_index]}
    output_target=${output_case_targets[$output_index]}
    output_sentinel=${output_case_sentinels[$output_index]}
    /bin/rm -rf -- "$superproject/build"
    mkdir -p "$(dirname "$output_link")" "$(dirname "$output_sentinel")"
    printf '%s\n' OUTSIDE_BUILD_SENTINEL > "$output_sentinel"
    ln -s "$output_target" "$output_link"

    set +e
    BASH_ENV="$fixture/hostile-bash-env" \
    GIT_CONFIG_GLOBAL="$fixture/hostile-gitconfig" \
    ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 \
    PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" "_build-$output_component" \
        > "$fixture/$output_case_name-output" 2>&1
    output_status=$?
    set -e
    if [[ "$output_status" -ne 0 \
        && -f "$output_sentinel" \
        && $(sed -n '1p' "$output_sentinel") == OUTSIDE_BUILD_SENTINEL \
        && $(grep -c '^FIXTURE_COMMAND ' \
            "$fixture/$output_case_name-output") -eq 0 ]]; then
        pass "$output_case_name is rejected before external writes or cleanup"
    else
        fail "$output_case_name reached external writes or cleanup"
        sed -n '1,80p' "$fixture/$output_case_name-output" >&2
    fi
    /bin/rm -f -- "$output_link"
done
/bin/rm -rf -- "$superproject/build"

# A pre-existing descendant symlink must never redirect a stage write. The
# component output itself is a direct directory so this exercises descendants,
# not the already-covered ancestor checks.
mkdir -p "$superproject/build/Keystone" "$fixture/outside-descendant"
printf '%s\n' OUTSIDE_DESCENDANT_SENTINEL \
    > "$fixture/outside-descendant/toolchain"
ln -s "$fixture/outside-descendant/toolchain" \
    "$superproject/build/Keystone/conan_toolchain.cmake"
set +e
HOME="$fixture/hostile-home" BASH_ENV="$fixture/hostile-bash-env" \
GIT_CONFIG_GLOBAL="$fixture/hostile-gitconfig" \
ODYSSEUS_BUILD_JOBS=2 ODYSSEUS_BUILD_VMEM_KB=6291456 \
PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/descendant-output" 2>&1
descendant_status=$?
set -e
if [[ "$descendant_status" -eq 0 \
    && $(sed -n '1p' "$fixture/outside-descendant/toolchain") == \
        OUTSIDE_DESCENDANT_SENTINEL \
    && -f "$superproject/build/Keystone/conan_toolchain.cmake" \
    && ! -L "$superproject/build/Keystone/conan_toolchain.cmake" ]]; then
    pass 'fresh private output prevents descendant symlink redirection'
else
    fail 'pre-existing descendant symlink redirected or blocked publication'
fi

# Cleanup must unlink its own hard-link name without changing the linked
# external inode. The old chmod/find cleanup changes this external mode.
/bin/rm -rf -- "$superproject/build"
printf '%s\n' CLEANUP_SENTINEL > "$fixture/cleanup-hardlink-target"
chmod 0400 "$fixture/cleanup-hardlink-target"
: > "$fixture/enable-cleanup-hardlink"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/cleanup-hardlink-output" 2>&1
cleanup_hardlink_status=$?
set -e
/bin/rm -f -- "$fixture/enable-cleanup-hardlink"
cleanup_target_mode=$(file_mode "$fixture/cleanup-hardlink-target")
if [[ "$cleanup_hardlink_status" -ne 0 \
    && "$cleanup_target_mode" == 400 ]] \
    && ! grep -q '^FIXTURE_CLEANUP_HARDLINK_CREATED$' \
        "$fixture/cleanup-hardlink-output" \
    && grep -q 'ERROR: Conan install failed with status ' \
        "$fixture/cleanup-hardlink-output"; then
    pass 'source boundary prevents cleanup aliases to external inodes'
else
    fail 'cleanup alias creation mutated an external inode or escaped failure'
fi

cleanup_substitution_markers=(
    enable-cleanup-root-substitution
    enable-cleanup-child-substitution
)
cleanup_substitution_labels=(root child)
for cleanup_index in "${!cleanup_substitution_markers[@]}"; do
    marker=${cleanup_substitution_markers[$cleanup_index]}
    label=${cleanup_substitution_labels[$cleanup_index]}
    /bin/rm -rf -- "$superproject/build"
    victim="$fixture/$label-substitution-victim"
    mkdir -p "$victim"
    printf '%s\n' "${label}_SUBSTITUTION_SENTINEL" \
        > "$victim/sentinel"
    : > "$fixture/$marker"
    set +e
    HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" _build-keystone \
        > "$fixture/$marker-output" 2>&1
    substitution_status=$?
    set -e
    /bin/rm -f -- "$fixture/$marker"
    substitution_path=
    if [[ -f "$fixture/$label-substitution-path" ]]; then
        substitution_path=$(sed -n '1p' \
            "$fixture/$label-substitution-path")
    fi
    if [[ "$substitution_status" -ne 0 \
        && "$substitution_path" == \
            "$fixture/runtime-tmp/odysseus-pinned-build."* \
        && -f "$substitution_path/sentinel" \
        && $(sed -n '1p' \
            "$substitution_path/sentinel") == \
            "${label}_SUBSTITUTION_SENTINEL" ]] \
        && grep -q \
            'ERROR: exact-object build workspace cleanup failed; replacements were preserved' \
            "$fixture/$marker-output"; then
        pass "$label workspace replacement is preserved by exact cleanup"
    else
        fail "$label workspace replacement was deleted or treated as completion"
        sed -n '1,120p' "$fixture/$marker-output" >&2
    fi
done

# Addition and directory-mode drift in the immutable source inventory must be
# denied by the OS boundary and must never reach configure.
/bin/rm -rf -- "$superproject/build"
: > "$fixture/enable-source-drift"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-charybdis \
    > "$fixture/source-drift-output" 2>&1
source_drift_status=$?
set -e
/bin/rm -f -- "$fixture/enable-source-drift"
if [[ "$source_drift_status" -ne 0 ]] \
    && ! grep -q '^FIXTURE_COMMAND cmake -S ' "$fixture/source-drift-output" \
    && ! grep -q '^FIXTURE_SOURCE_DRIFT_SUCCEEDED$' \
        "$fixture/source-drift-output" \
    && grep -Eq 'read-only source boundary|source snapshot|Conan install failed' \
        "$fixture/source-drift-output"; then
    pass 'source additions and directory-mode drift fail before configure'
else
    fail 'source inventory or directory-mode drift escaped detection'
fi

# Every external stage failure must propagate with a truthful stage-specific
# diagnostic rather than being converted into completion.
failure_markers=(fail-conan fail-configure fail-build)
failure_labels=('Conan install' 'CMake configure' 'CMake build')
failure_codes=(71 72 73)
for failure_index in "${!failure_markers[@]}"; do
    marker=${failure_markers[$failure_index]}
    label=${failure_labels[$failure_index]}
    code=${failure_codes[$failure_index]}
    /bin/rm -rf -- "$superproject/build"
    : > "$fixture/$marker"
    set +e
    HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" _build-nestor \
        > "$fixture/$marker-output" 2>&1
    failure_status=$?
    set -e
    /bin/rm -f -- "$fixture/$marker"
    if [[ "$failure_status" -ne 0 \
        && $(grep -Fc "ERROR: $label failed with status $code" \
            "$fixture/$marker-output") -eq 1 ]]; then
        pass "$label failure propagates with one exact diagnostic"
    else
        fail "$label failure lacked an exact propagated diagnostic"
    fi
done

# A missing component object database is a Git-boundary failure, not permission
# to fall back to checkout bytes or to report completion.
charybdis_git_dir=$(fixture_git -C "$superproject/testing/Charybdis" \
    rev-parse --absolute-git-dir)
mv "$charybdis_git_dir" "$charybdis_git_dir.unavailable"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-charybdis \
    > "$fixture/git-boundary-output" 2>&1
git_boundary_status=$?
set -e
mv "$charybdis_git_dir.unavailable" "$charybdis_git_dir"
if [[ "$git_boundary_status" -ne 0 \
    && $(grep -Fc \
        'ERROR: cannot resolve the testing/Charybdis checkout' \
        "$fixture/git-boundary-output") -eq 1 ]] \
    && ! grep -q '^FIXTURE_COMMAND ' "$fixture/git-boundary-output"; then
    pass 'Git object-database failure is explicit and reaches no build tool'
else
    fail 'Git object-database failure fell back or lacked its diagnostic'
fi

# Missing objects in a promisor repository must remain an explicit local
# failure. Git must not start its lazy-fetch subprocess while resolving the
# immutable gitlink tree.
lazy_checkout="$superproject/control/Agamemnon"
lazy_git_dir=$(fixture_git -C "$lazy_checkout" rev-parse --absolute-git-dir)
lazy_blob=$(fixture_git -C "$component" rev-parse \
    "$pinned_component_commit:src/input.cpp")
lazy_object="$lazy_git_dir/objects/${lazy_blob:0:2}/${lazy_blob:2}"
lazy_backup="$fixture/lazy-fetch-object"
if [[ -f "$lazy_object" && ! -L "$lazy_object" ]]; then
    fixture_git -C "$lazy_checkout" config core.repositoryformatversion 1
    fixture_git -C "$lazy_checkout" config extensions.partialClone origin
    fixture_git -C "$lazy_checkout" config remote.origin.promisor true
    fixture_git -C "$lazy_checkout" config \
        remote.origin.partialclonefilter blob:none
    mv "$lazy_object" "$lazy_backup"
    /bin/rm -rf -- "$superproject/build"
    set +e
    HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
    ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
        "$JUST_BIN" --justfile "$superproject/justfile" \
        --working-directory "$superproject" _build-agamemnon \
        > "$fixture/lazy-fetch-output" 2>&1
    lazy_fetch_status=$?
    set -e
    /bin/rm -f -- "$lazy_object"
    mkdir -p "${lazy_object%/*}"
    mv "$lazy_backup" "$lazy_object"
    if [[ "$lazy_fetch_status" -ne 0 \
        && $(grep -c '^FIXTURE_COMMAND ' \
            "$fixture/lazy-fetch-output") -eq 0 ]]; then
        pass 'missing promisor objects fail without lazy fetch'
    else
        fail 'Git lazy-fetched a missing exact-pin object'
    fi
else
    fail 'lazy-fetch fixture did not expose one removable loose object'
fi

# A mode-120000 Git blob is binary data. NUL cannot be represented by an OS
# symlink and must be rejected before command substitution can transform it.
fixture_git -C "$component" checkout -q --detach "$pinned_component_commit"
nul_blob=$(printf 'src/\000input.cpp' | fixture_git -C "$component" \
    hash-object -w --stdin)
fixture_git -C "$component" update-index --add --cacheinfo \
    "120000,$nul_blob,nul-link"
fixture_git -C "$component" commit -q -m 'NUL symlink blob'
nul_commit=$(fixture_git -C "$component" rev-parse HEAD)
fixture_git -C "$superproject/provisioning/Keystone" fetch -q origin \
    "$nul_commit"
fixture_git -C "$superproject" update-index --cacheinfo \
    "160000,$nul_commit,provisioning/Keystone"
fixture_git -C "$superproject" commit -q -m 'pin NUL symlink fixture'
/bin/rm -rf -- "$superproject/build"
set +e
HOME="$fixture/hostile-home" ODYSSEUS_BUILD_JOBS=2 \
ODYSSEUS_BUILD_VMEM_KB=6291456 PATH="$fixture/tools:/usr/bin:/bin" \
    "$JUST_BIN" --justfile "$superproject/justfile" \
    --working-directory "$superproject" _build-keystone \
    > "$fixture/nul-symlink-output" 2>&1
nul_status=$?
set -e
if [[ "$nul_status" -ne 0 \
    && $(grep -Fc 'ERROR: component symlink target contains NUL' \
        "$fixture/nul-symlink-output") -eq 1 ]] \
    && ! grep -q '^conan ' "$fixture/nul-symlink-output"; then
    pass 'NUL-bearing symlink blob is rejected byte-for-byte before tools'
else
    fail 'NUL-bearing symlink blob was transformed or reached build tools'
fi

printf '\n%d passed, %d failed, %d skipped\n' \
    "$passes" "$failures" "$skips"
[[ "$failures" -eq 0 ]]
