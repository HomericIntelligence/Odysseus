#!/usr/bin/env bash
# Behavior tests for canonical, injection-safe resource-bound overrides.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FAKE_BIN="$TMP/bin"
RUN_MARKER="$TMP/command-ran"
INJECTION_MARKER="$TMP/injection-ran"
mkdir -p "$FAKE_BIN"

fixture_fingerprint() {
    python3 -I -S - "$1" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

root = Path(sys.argv[1])
digest = hashlib.sha256()
paths = [root, *root.rglob("*")]
for path in sorted(
    paths,
    key=lambda item: "." if item == root else str(item.relative_to(root)),
):
    relative = "." if path == root else str(path.relative_to(root))
    state = os.lstat(path)
    if stat.S_ISREG(state.st_mode):
        payload = path.read_bytes()
    elif stat.S_ISLNK(state.st_mode):
        payload = os.readlink(path).encode("utf-8", "surrogateescape")
    else:
        payload = b""
    record = (
        relative,
        str(state.st_mode),
        str(state.st_uid),
        str(state.st_gid),
        str(state.st_size),
        str(state.st_mtime_ns),
        str(state.st_ctime_ns),
        hashlib.sha256(payload).hexdigest(),
    )
    digest.update("\0".join(record).encode("utf-8", "surrogateescape"))
    digest.update(b"\0\0")
print(digest.hexdigest())
PY
}

cat > "$FAKE_BIN/bounded-command" <<'SH'
#!/usr/bin/env bash
: > "${RUN_MARKER:?}"
SH
chmod +x "$FAKE_BIN/bounded-command"

info "run-bounded rejects noncanonical and oversized limits before execution"
for value in -1 01 1+1 0x10 67108865 999999999999999999999 \
    "x[\$(touch $INJECTION_MARKER)]"; do
    rm -f "$RUN_MARKER" "$INJECTION_MARKER"
    set +e
    RUN_MARKER="$RUN_MARKER" RUN_BOUNDED_VMEM_KB="$value" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-command \
        > "$TMP/run-bounded.out" 2> "$TMP/run-bounded.err"
    status=$?
    set -e
    if [ "$status" -ne 0 ] && [ ! -e "$RUN_MARKER" ] \
        && [ ! -e "$INJECTION_MARKER" ]; then
        pass "RUN_BOUNDED_VMEM_KB=$value fails before command execution"
    else
        fail "unsafe RUN_BOUNDED_VMEM_KB=$value reached an effect boundary"
    fi
done

info "literal zero remains the explicit unbounded opt-out"
rm -f "$RUN_MARKER"
if RUN_MARKER="$RUN_MARKER" RUN_BOUNDED_VMEM_KB=0 \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-command \
    && [ -e "$RUN_MARKER" ]; then
    pass "literal zero executes without applying a virtual-memory cap"
else
    fail "literal zero no longer preserves the documented opt-out"
fi

info "C++ build bounds fail before filesystem or tool effects"
INSTALL_ROOT="$TMP/install-root"
mkdir -p "$INSTALL_ROOT/scripts/install"
cp "$ROOT/scripts/install/50-cpp-builds.sh" \
    "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh"
cp "$ROOT/scripts/install/lib.sh" "$INSTALL_ROOT/scripts/install/lib.sh"
for cpp_repo in \
    control/Agamemnon \
    control/Nestor \
    provisioning/Keystone \
    testing/Charybdis; do
    mkdir -p "$INSTALL_ROOT/$cpp_repo"
    : > "$INSTALL_ROOT/$cpp_repo/CMakeLists.txt"
done
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf 'pixi %s\n' "$*" >> "${CPP_TOOL_LOG:?}"
exit 0
SH
cat > "$FAKE_BIN/cmake" <<'SH'
#!/usr/bin/env bash
printf 'cmake %s\n' "$*" >> "${CPP_TOOL_LOG:?}"
exit 0
SH
cat > "$FAKE_BIN/conan" <<'SH'
#!/usr/bin/env bash
printf 'conan %s\n' "$*" >> "${CPP_TOOL_LOG:?}"
exit 0
SH
chmod +x "$FAKE_BIN/pixi" "$FAKE_BIN/cmake" "$FAKE_BIN/conan"

info "C++ check-only mode has no filesystem or toolchain effects"
check_only_effect_root="$TMP/check-only-effects"
check_only_cwd="$check_only_effect_root/cwd"
check_only_home="$check_only_effect_root/home"
check_only_xdg_cache="$check_only_effect_root/xdg/cache"
check_only_xdg_config="$check_only_effect_root/xdg/config"
check_only_xdg_data="$check_only_effect_root/xdg/data"
check_only_xdg_state="$check_only_effect_root/xdg/state"
check_only_xdg_runtime="$check_only_effect_root/xdg/runtime"
check_only_conan_home="$check_only_effect_root/conan/home"
check_only_conan_user_home="$check_only_effect_root/conan/user-home"
check_only_tmpdir="$check_only_effect_root/tmp"
check_only_prefix="$check_only_effect_root/runtime/prefix"
check_only_tool_log="$check_only_effect_root/tooling.log"
mkdir -p \
    "$check_only_cwd" \
    "$check_only_home" \
    "$check_only_xdg_cache" \
    "$check_only_xdg_config" \
    "$check_only_xdg_data" \
    "$check_only_xdg_state" \
    "$check_only_xdg_runtime" \
    "$check_only_conan_home" \
    "$check_only_conan_user_home" \
    "$check_only_tmpdir" \
    "$(dirname "$check_only_prefix")"
: > "$check_only_tool_log"
check_only_fixture_before="$(fixture_fingerprint "$INSTALL_ROOT")"
check_only_effects_before="$(fixture_fingerprint "$check_only_effect_root")"
set +e
(
    cd "$check_only_cwd" || exit 97
    env -i \
        HOME="$check_only_home" \
        XDG_CACHE_HOME="$check_only_xdg_cache" \
        XDG_CONFIG_HOME="$check_only_xdg_config" \
        XDG_DATA_HOME="$check_only_xdg_data" \
        XDG_STATE_HOME="$check_only_xdg_state" \
        XDG_RUNTIME_DIR="$check_only_xdg_runtime" \
        CONAN_HOME="$check_only_conan_home" \
        CONAN_USER_HOME="$check_only_conan_user_home" \
        TMPDIR="$check_only_tmpdir" \
        ODYSSEUS_ROOT="$INSTALL_ROOT" \
        ODYSSEUS_RUNTIME_PREFIX="$check_only_prefix" \
        CPP_TOOL_LOG="$check_only_tool_log" \
        INSTALL=false \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh"
) > "$TMP/cpp-check-only.out" 2>&1
check_only_status=$?
set -e
if [ "$check_only_status" -eq 0 ] \
    && [ ! -e "$check_only_prefix" ] \
    && [ ! -s "$check_only_tool_log" ] \
    && [ "$(fixture_fingerprint "$INSTALL_ROOT")" = \
        "$check_only_fixture_before" ] \
    && [ "$(fixture_fingerprint "$check_only_effect_root")" = \
        "$check_only_effects_before" ]; then
    pass "check-only leaves all isolated effect trees unchanged and invokes no build tool"
else
    fail "check-only crossed a persistent filesystem or toolchain boundary"
fi

case_number=0
for assignment in \
    'ODYSSEUS_BUILD_JOBS=-1' \
    'ODYSSEUS_BUILD_JOBS=01' \
    'ODYSSEUS_BUILD_JOBS=9' \
    'ODYSSEUS_BUILD_JOBS=1+1' \
    "ODYSSEUS_BUILD_JOBS=x[\$(touch $INJECTION_MARKER)]" \
    'ODYSSEUS_BUILD_VMEM_KB=-1' \
    'ODYSSEUS_BUILD_VMEM_KB=01' \
    'ODYSSEUS_BUILD_VMEM_KB=67108865' \
    'ODYSSEUS_BUILD_VMEM_KB=1+1' \
    "ODYSSEUS_BUILD_VMEM_KB=x[\$(touch $INJECTION_MARKER)]"; do
    case_number=$((case_number + 1))
    effect_root="$TMP/effect-$case_number"
    pixi_marker="$TMP/pixi-$case_number"
    rm -rf "$effect_root"
    rm -f "$pixi_marker" "$INJECTION_MARKER"
    variable=${assignment%%=*}
    value=${assignment#*=}
    set +e
    env "$variable=$value" \
        ODYSSEUS_ROOT="$INSTALL_ROOT" \
        ODYSSEUS_RUNTIME_PREFIX="$effect_root" \
        CPP_TOOL_LOG="$pixi_marker" \
        INSTALL=true PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
        > "$TMP/cpp-$case_number.out" 2> "$TMP/cpp-$case_number.err"
    status=$?
    set -e
    if [ "$status" -ne 0 ] && [ ! -e "$effect_root" ] \
        && [ ! -e "$pixi_marker" ] && [ ! -e "$INJECTION_MARKER" ]; then
        pass "$assignment fails before build effects"
    else
        fail "$assignment reached a filesystem, tool, or injection effect"
    fi
done

info "C++ repository prerequisites use the selected role's failure policy"
mv "$INSTALL_ROOT/testing/Charybdis" \
    "$INSTALL_ROOT/testing/Charybdis.missing"
for cpp_role in control all worker; do
    role_output="$TMP/cpp-missing-repo-$cpp_role.out"
    set +e
    ROLE="$cpp_role" INSTALL=false \
        ODYSSEUS_ROOT="$INSTALL_ROOT" \
        CPP_TOOL_LOG="$TMP/cpp-missing-repo-$cpp_role.log" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
        > "$role_output" 2>&1
    role_status=$?
    set -e
    if { [ "$cpp_role" = worker ] && [ "$role_status" -eq 0 ] \
            && grep -q 'directory not found' "$role_output" \
            && grep -q '⚠' "$role_output"; } \
        || { [ "$cpp_role" != worker ] && [ "$role_status" -ne 0 ] \
            && grep -q 'directory not found' "$role_output" \
            && grep -q '✗' "$role_output"; }; then
        pass "$cpp_role role applies its missing-repository policy"
    else
        fail "$cpp_role role used the wrong missing-repository policy"
    fi
done
mv "$INSTALL_ROOT/testing/Charybdis.missing" \
    "$INSTALL_ROOT/testing/Charybdis"

info "C++ tool prerequisites fail closed for control-capable roles"
mv "$FAKE_BIN/pixi" "$FAKE_BIN/pixi.hidden"
for cpp_role in control all worker; do
    role_output="$TMP/cpp-missing-pixi-$cpp_role.out"
    set +e
    ROLE="$cpp_role" INSTALL=true \
        ODYSSEUS_ROOT="$INSTALL_ROOT" \
        ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-missing-pixi-$cpp_role" \
        CPP_TOOL_LOG="$TMP/cpp-missing-pixi-$cpp_role.log" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
        > "$role_output" 2>&1
    role_status=$?
    set -e
    if { [ "$cpp_role" = worker ] && [ "$role_status" -eq 0 ] \
            && grep -q 'pixi not found' "$role_output" \
            && grep -q '⚠' "$role_output"; } \
        || { [ "$cpp_role" != worker ] && [ "$role_status" -ne 0 ] \
            && grep -q 'pixi not found' "$role_output" \
            && grep -q '✗' "$role_output"; }; then
        pass "$cpp_role role applies its missing-tool policy"
    else
        fail "$cpp_role role used the wrong missing-tool policy"
    fi
done
mv "$FAKE_BIN/pixi.hidden" "$FAKE_BIN/pixi"

info "C++ roots, projects, and build descriptors must be direct entries"
root_link="$TMP/install-root-link"
ln -s "$INSTALL_ROOT" "$root_link"
project_real="$TMP/charybdis-real"
mv "$INSTALL_ROOT/testing/Charybdis" "$project_real"
ln -s "$project_real" "$INSTALL_ROOT/testing/Charybdis"
cmake_real="$TMP/nestor-CMakeLists.txt"
mv "$INSTALL_ROOT/control/Nestor/CMakeLists.txt" "$cmake_real"
ln -s "$cmake_real" "$INSTALL_ROOT/control/Nestor/CMakeLists.txt"
for boundary_case in root project cmake; do
    case "$boundary_case" in
        root) boundary_root="$root_link" ;;
        project|cmake) boundary_root="$INSTALL_ROOT" ;;
    esac
    boundary_log="$TMP/cpp-boundary-$boundary_case.log"
    : > "$boundary_log"
    set +e
    ROLE=control INSTALL=true \
        ODYSSEUS_ROOT="$boundary_root" \
        ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-boundary-$boundary_case" \
        CPP_TOOL_LOG="$boundary_log" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
        > "$TMP/cpp-boundary-$boundary_case.out" 2>&1
    boundary_status=$?
    set -e
    if [ "$boundary_status" -ne 0 ] && [ ! -s "$boundary_log" ]; then
        pass "$boundary_case symlink is rejected before a build tool"
    else
        fail "$boundary_case symlink reached a build tool or passed"
    fi
    if [ "$boundary_case" = root ]; then
        rm "$root_link"
    elif [ "$boundary_case" = project ]; then
        rm "$INSTALL_ROOT/testing/Charybdis"
        mv "$project_real" "$INSTALL_ROOT/testing/Charybdis"
    else
        rm "$INSTALL_ROOT/control/Nestor/CMakeLists.txt"
        mv "$cmake_real" "$INSTALL_ROOT/control/Nestor/CMakeLists.txt"
    fi
done

info "C++ descriptor replacement is revalidated before the next tool launch"
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD :: $*" >> "${PIXI_LOG:?}"
if [[ "$PWD" == */control/Agamemnon ]] \
    && [[ "$*" == 'run -- conan install '* ]]; then
    mv CMakeLists.txt CMakeLists.txt.approved
    printf '%s\n' 'hostile replacement' > CMakeLists.txt
    exit 0
fi
if [[ "$PWD" == */control/Agamemnon ]] \
    && [[ "$*" == 'run -- cmake --preset release'* ]] \
    && grep -q 'hostile replacement' CMakeLists.txt; then
    : > "${CPP_SWAP_SENTINEL:?}"
fi
exit 0
SH
chmod +x "$FAKE_BIN/pixi"
swap_log="$TMP/cpp-swap.log"
swap_sentinel="$TMP/cpp-swap.sentinel"
: > "$swap_log"
set +e
ROLE=control INSTALL=true \
    ODYSSEUS_ROOT="$INSTALL_ROOT" \
    ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-swap" \
    ODYSSEUS_BUILD_VMEM_KB=0 \
    PIXI_LOG="$swap_log" CPP_SWAP_SENTINEL="$swap_sentinel" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
    > "$TMP/cpp-swap.out" 2>&1
swap_status=$?
set -e
if [ "$swap_status" -ne 0 ] \
    && [ ! -e "$swap_sentinel" ] \
    && ! grep -q 'control/Agamemnon :: run -- cmake --preset release' \
        "$swap_log"; then
    pass "descriptor replacement stops before CMake observes hostile bytes"
else
    fail "descriptor replacement reached CMake or became install success"
fi
mv "$INSTALL_ROOT/control/Agamemnon/CMakeLists.txt.approved" \
    "$INSTALL_ROOT/control/Agamemnon/CMakeLists.txt"

info "C++ build stages stop at the first failed required operation"
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PIXI_LOG:?}"
case "${CPP_FAIL_STAGE:-}:$*" in
    conan:'run -- conan install '*) exit 60 ;;
    configure:'run -- cmake --preset release'*) exit 61 ;;
    build:'run -- cmake --build --preset release'*) exit 62 ;;
esac
exit 0
SH
chmod +x "$FAKE_BIN/pixi"
ULIMIT_ENV="$TMP/ulimit-env.sh"
cat > "$ULIMIT_ENV" <<'SH'
if [ "${CPP_FAIL_STAGE:-}" = ulimit ]; then
    ulimit() {
        if [ "$#" -eq 1 ] && [ "$1" = -v ]; then
            printf '%s\n' ulimit-inspect >> "${CPP_SEAM_LOG:?}"
            printf '%s\n' unlimited
            return 0
        fi
        if [ "$#" -eq 2 ] && [ "$1" = -v ]; then
            printf '%s\n' ulimit-apply >> "${CPP_SEAM_LOG:?}"
        fi
        return 63
    }
fi
if [ "${CPP_FAIL_STAGE:-}" = cd ]; then
    cd() {
        case "$1" in
            "${CPP_FAIL_CD_ROOT:?}"/control/Agamemnon|\
            "${CPP_FAIL_CD_ROOT:?}"/control/Nestor|\
            "${CPP_FAIL_CD_ROOT:?}"/provisioning/Keystone|\
            "${CPP_FAIL_CD_ROOT:?}"/testing/Charybdis)
                printf '%s\n' cd-target >> "${CPP_SEAM_LOG:?}"
                return 64
                ;;
        esac
        builtin cd "$@"
    }
fi
SH

for failure_stage in ulimit cd conan configure build; do
    pixi_log="$TMP/pixi-$failure_stage.log"
    seam_log="$TMP/seam-$failure_stage.log"
    output="$TMP/cpp-$failure_stage.out"
    : > "$pixi_log"
    : > "$seam_log"
    failure_vmem=0
    [ "$failure_stage" = ulimit ] && failure_vmem=1024
    for cpp_role in control all worker; do
        : > "$pixi_log"
        : > "$seam_log"
        set +e
        BASH_ENV="$ULIMIT_ENV" CPP_FAIL_STAGE="$failure_stage" \
            CPP_SEAM_LOG="$seam_log" \
            CPP_FAIL_CD_ROOT="$INSTALL_ROOT" \
            PIXI_LOG="$pixi_log" ODYSSEUS_ROOT="$INSTALL_ROOT" \
            ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-$failure_stage-$cpp_role" \
            ODYSSEUS_BUILD_VMEM_KB="$failure_vmem" INSTALL=true \
            ROLE="$cpp_role" PATH="$FAKE_BIN:/usr/bin:/bin" \
            "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
            > "$output" 2>&1
        status=$?
        set -e

    case "$failure_stage" in
        ulimit)
            later_effect='run -- conan install|run -- cmake --preset|run -- cmake --build|run -- cmake --install'
            ;;
        cd)
            later_effect='run -- conan install|run -- cmake --preset|run -- cmake --build|run -- cmake --install'
            ;;
        conan)
            later_effect='run -- cmake --preset|run -- cmake --build|run -- cmake --install'
            ;;
        configure)
            later_effect='run -- cmake --build|run -- cmake --install'
            ;;
        build)
            later_effect='run -- cmake --install'
            ;;
    esac
    target_reached=0
    case "$failure_stage" in
        ulimit)
            if [ "$(grep -c '^ulimit-inspect$' "$seam_log")" -ge 1 ] \
                && [ "$(grep -c '^ulimit-apply$' "$seam_log")" -ge 1 ]; then
                target_reached=1
            fi
            ;;
        cd)
            if [ "$(grep -c '^cd-target$' "$seam_log")" -ge 1 ]; then
                target_reached=1
            fi
            ;;
        conan)
            if grep -q '^run -- conan install \. --build=missing ' "$pixi_log"; then
                target_reached=1
            fi
            ;;
        configure)
            if grep -q '^run -- conan install \. --build=missing ' "$pixi_log" \
                && grep -q '^run -- cmake --preset release ' "$pixi_log"; then
                target_reached=1
            fi
            ;;
        build)
            if grep -q '^run -- conan install \. --build=missing ' "$pixi_log" \
                && grep -q '^run -- cmake --preset release ' "$pixi_log" \
                && grep -q '^run -- cmake --build --preset release ' "$pixi_log"; then
                target_reached=1
            fi
            ;;
    esac
        role_policy_ok=false
        if [ "$cpp_role" = worker ]; then
            [ "$status" -eq 0 ] && grep -q '⚠.*build failed' "$output" \
                && role_policy_ok=true
        else
            [ "$status" -ne 0 ] && grep -q '✗.*build failed' "$output" \
                && role_policy_ok=true
        fi
        if $role_policy_ok \
            && [ "$target_reached" -eq 1 ] \
            && grep -qx 'run -- conan profile detect --exist-ok' "$pixi_log" \
            && grep -q 'build failed' "$output" \
            && ! grep -q 'built and installed' "$output" \
            && ! grep -Eq "$later_effect" "$pixi_log"; then
            pass "$cpp_role $failure_stage failure stops before stale install success"
        else
            fail "$cpp_role $failure_stage failure used the wrong policy or stage order"
        fi
    done
done

summary
exit_code
