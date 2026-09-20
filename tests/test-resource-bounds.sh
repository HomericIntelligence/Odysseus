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

info "run-bounded rejects unbounded, noncanonical, and oversized limits before execution"
for value in 0 -1 01 1+1 0x10 67108865 999999999999999999999 \
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

if [[ "$(uname -s)" == Linux ]]; then
    delegated_parent=
    current_cgroup=
    while IFS=: read -r hierarchy controllers relative; do
        if [[ "$hierarchy" == 0 && -z "$controllers" ]]; then
            current_cgroup="/sys/fs/cgroup$relative"
            break
        fi
    done < /proc/self/cgroup
    candidate_parent=$current_cgroup
    while [[ "$candidate_parent" == /sys/fs/cgroup* \
        && "$candidate_parent" != /sys/fs ]]; do
        candidate="$candidate_parent/odysseus-cgroup-probe.$$"
        if /bin/mkdir "$candidate" 2>/dev/null; then
            if [[ -f "$candidate/memory.max" \
                && -f "$candidate/memory.swap.max" \
                && -f "$candidate/cgroup.kill" ]]; then
                delegated_parent=$candidate_parent
            fi
            if ! /bin/rmdir "$candidate"; then
                fail "the cgroup capability probe could not clean its exact object"
                delegated_parent=
            fi
            [[ -z "$delegated_parent" ]] || break
        fi
        candidate_parent=${candidate_parent%/*}
        [[ -n "$candidate_parent" ]] || break
    done

    if [[ -n "$delegated_parent" ]]; then
    info "run-bounded preserves argv and applies the limit to descendants"
    cat > "$FAKE_BIN/bounded-argv" <<'SH'
#!/usr/bin/env bash
if [[ "$#" -eq 4 \
    && "$1" == 'one two' \
    && "$2" == '' \
    && "$3" == '*' \
    && "$4" == '$(not-code)' ]]; then
    : > "${RUN_MARKER:?}"
else
    exit 64
fi
SH
    cat > "$FAKE_BIN/bounded-limits" <<'SH'
#!/usr/bin/env bash
ulimit -v > "${LIMIT_LOG:?}"
"${BASH:?}" -c 'ulimit -v' >> "${LIMIT_LOG:?}"
SH
    chmod +x "$FAKE_BIN/bounded-argv" "$FAKE_BIN/bounded-limits"
    rm -f "$RUN_MARKER"
    if RUN_MARKER="$RUN_MARKER" RUN_BOUNDED_VMEM_KB=262144 \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-argv \
        'one two' '' '*' '$(not-code)' \
        && [ -e "$RUN_MARKER" ]; then
        pass "bounded execution preserves the selected argv"
    else
        fail "bounded execution reconstructed or lost selected argv"
    fi
    limit_log="$TMP/descendant-limits.log"
    if LIMIT_LOG="$limit_log" RUN_BOUNDED_VMEM_KB=262144 \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-limits \
        && [[ "$(sed -n '1p' "$limit_log")" =~ ^[0-9]+$ ]] \
        && [ "$(sed -n '1p' "$limit_log")" -le 262144 ] \
        && [[ "$(sed -n '2p' "$limit_log")" =~ ^[0-9]+$ ]] \
        && [ "$(sed -n '2p' "$limit_log")" -le 262144 ]; then
        pass "the memory ceiling is inherited by a descendant shell"
    else
        fail "a descendant escaped the inherited memory ceiling"
    fi

    info "run-bounded uses an aggregate cgroup-v2 ceiling when delegated"
        cat > "$FAKE_BIN/bounded-cgroup-probe" <<'SH'
#!/usr/bin/env bash
relative=
while IFS=: read -r hierarchy controllers candidate; do
    if [[ "$hierarchy" == 0 && -z "$controllers" ]]; then
        relative=$candidate
        break
    fi
done < /proc/self/cgroup
printf '%s\n' "$relative" > "${CGROUP_LOG:?}"
cat "/sys/fs/cgroup$relative/memory.max" >> "${CGROUP_LOG:?}"
cat "/sys/fs/cgroup$relative/memory.swap.max" >> "${CGROUP_LOG:?}"
SH
        chmod +x "$FAKE_BIN/bounded-cgroup-probe"
        cgroup_log="$TMP/bounded-cgroup.log"
        if CGROUP_LOG="$cgroup_log" RUN_BOUNDED_VMEM_KB=262144 \
            PATH="$FAKE_BIN:/usr/bin:/bin" \
            "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-cgroup-probe \
            && grep -q '/odysseus-run-bounded\.' "$cgroup_log" \
            && [ "$(sed -n '2p' "$cgroup_log")" -eq 268435456 ] \
            && [ "$(sed -n '3p' "$cgroup_log")" -eq 0 ]; then
            pass "delegated cgroup-v2 enforces one aggregate memory ceiling"
        else
            fail "a delegated aggregate memory boundary was available but unused"
        fi

        cat > "$FAKE_BIN/bounded-aggregate" <<'SH'
#!/usr/bin/env bash
exec "${BOUNDED_PYTHON:?}" -I -S -c '
import subprocess
import sys

program = "import time; payload = bytearray(128 * 1024 * 1024); time.sleep(3)"
children = [subprocess.Popen([sys.executable, "-I", "-S", "-c", program]) for _ in range(2)]
for child in children:
    child.wait()
raise SystemExit(0)
'
SH
        chmod +x "$FAKE_BIN/bounded-aggregate"
        set +e
        BOUNDED_PYTHON="$(command -v python3)" \
            RUN_BOUNDED_VMEM_KB=196608 PATH="$FAKE_BIN:/usr/bin:/bin" \
            "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-aggregate \
            > "$TMP/bounded-aggregate.out" 2>&1
        aggregate_status=$?
        set -e
        if [ "$aggregate_status" -ne 0 ] \
            && grep -q 'exceeded its aggregate memory ceiling' \
                "$TMP/bounded-aggregate.out"; then
            pass "the aggregate ceiling terminates an over-budget descendant workload"
        else
            fail "separate descendants exceeded the aggregate ceiling without failure"
        fi
    info "run-bounded rejects and extinguishes a leaked cgroup member"
    cat > "$FAKE_BIN/bounded-leaker" <<'SH'
#!/usr/bin/env bash
/bin/sleep 30 &
printf '%s\n' "$!" > "${LEAK_PID_FILE:?}"
exit 0
SH
    chmod +x "$FAKE_BIN/bounded-leaker"
    leak_pid_file="$TMP/leaked-process.pid"
    set +e
    LEAK_PID_FILE="$leak_pid_file" RUN_BOUNDED_VMEM_KB=262144 \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-leaker \
        > "$TMP/run-bounded-leak.out" 2>&1
    leak_status=$?
    set -e
    leak_alive=false
    if [ -s "$leak_pid_file" ]; then
        leak_pid=$(cat "$leak_pid_file")
        if kill -0 "$leak_pid" 2>/dev/null; then
            leak_alive=true
            kill -KILL "$leak_pid" 2>/dev/null
        fi
    fi
    if [ "$leak_status" -ne 0 ] && ! $leak_alive \
        && grep -q 'descendants were still running' "$TMP/run-bounded-leak.out"; then
        pass "a leaked cgroup member is killed and cannot become success"
    else
        fail "a leaked cgroup member survived or became success"
    fi

    info "setsid and double-fork descendants remain inside aggregate containment"
    cat > "$FAKE_BIN/bounded-detached" <<'SH'
#!/usr/bin/env bash
exec "${BOUNDED_PYTHON:?}" -I -S - "${DETACHED_PID_FILE:?}" <<'PY'
import os
import sys
import time

first = os.fork()
if first:
    os.waitpid(first, 0)
    raise SystemExit(0)
os.setsid()
second = os.fork()
if second:
    os._exit(0)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(str(os.getpid()))
time.sleep(30)
PY
SH
    chmod +x "$FAKE_BIN/bounded-detached"
    detached_pid_file="$TMP/detached.pid"
    set +e
    BOUNDED_PYTHON="$(command -v python3)" \
        DETACHED_PID_FILE="$detached_pid_file" RUN_BOUNDED_VMEM_KB=262144 \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-detached \
        > "$TMP/run-bounded-detached.out" 2>&1
    detached_status=$?
    set -e
    detached_alive=false
    if [ -s "$detached_pid_file" ]; then
        detached_pid=$(cat "$detached_pid_file")
        if kill -0 "$detached_pid" 2>/dev/null; then
            detached_alive=true
            kill -KILL "$detached_pid" 2>/dev/null
        fi
    fi
    if [ "$detached_status" -ne 0 ] && ! $detached_alive \
        && grep -q 'descendants were still running' \
            "$TMP/run-bounded-detached.out"; then
        pass "detached descendants are extinct before the wrapper returns"
    else
        fail "a detached descendant escaped the aggregate cgroup"
    fi

    info "prelaunch cancellation cannot start the selected command"
    prelaunch_env="$TMP/prelaunch-cancel-env.sh"
cat > "$prelaunch_env" <<'SH'
trap 'if [[ "${BASH_COMMAND:-}" == run_bounded_checkpoint=prelaunch ]]; then \
    trap - DEBUG; kill -TERM "$$"; fi' DEBUG
SH
    rm -f "$RUN_MARKER"
    set +e
    BASH_ENV="$prelaunch_env" RUN_MARKER="$RUN_MARKER" \
        RUN_BOUNDED_VMEM_KB=262144 PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-command \
        > "$TMP/run-bounded-prelaunch.out" 2>&1
    prelaunch_status=$?
    set -e
    if [ "$prelaunch_status" -eq 143 ] && [ ! -e "$RUN_MARKER" ]; then
        pass "a signal observed before launch is terminal without command effects"
    else
        sed 's/^/    /' "$TMP/run-bounded-prelaunch.out" >&2
        fail "prelaunch cancellation still reached the selected command"
    fi

    info "run-bounded propagates cancellation after descendant extinction"
    cat > "$FAKE_BIN/bounded-waiter" <<'SH'
#!/usr/bin/env bash
/bin/sleep 30 &
printf '%s\n' "$!" > "${WAIT_CHILD_PID_FILE:?}"
: > "${WAIT_READY:?}"
wait
SH
    chmod +x "$FAKE_BIN/bounded-waiter"
    wait_child_pid_file="$TMP/wait-child.pid"
    wait_ready="$TMP/wait-ready"
    WAIT_CHILD_PID_FILE="$wait_child_pid_file" WAIT_READY="$wait_ready" \
        RUN_BOUNDED_VMEM_KB=262144 PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-waiter \
        > "$TMP/run-bounded-cancel.out" 2>&1 &
    bounded_pid=$!
    for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
        [ -e "$wait_ready" ] && break
        /bin/sleep 0.05
    done
    if [ -e "$wait_ready" ]; then
        kill -TERM "$bounded_pid"
    fi
    set +e
    wait "$bounded_pid"
    cancel_status=$?
    set -e
    wait_child_alive=false
    if [ -s "$wait_child_pid_file" ]; then
        wait_child_pid=$(cat "$wait_child_pid_file")
        for _attempt in 1 2 3 4 5 6 7 8 9 10; do
            kill -0 "$wait_child_pid" 2>/dev/null || break
            /bin/sleep 0.05
        done
        if kill -0 "$wait_child_pid" 2>/dev/null; then
            wait_child_alive=true
            kill -KILL "$wait_child_pid" 2>/dev/null
        fi
    fi
    if [ "$cancel_status" -eq 143 ] && ! $wait_child_alive; then
        pass "SIGTERM remains terminal after every cgroup member exits"
    else
        fail "cancellation status or cgroup extinction was lost"
    fi
    else
        info "run-bounded fails closed without delegated aggregate containment"
        rm -f "$RUN_MARKER"
        set +e
        RUN_MARKER="$RUN_MARKER" RUN_BOUNDED_VMEM_KB=262144 \
            PATH="$FAKE_BIN:/usr/bin:/bin" \
            "$BASH" "$ROOT/scripts/run-bounded.sh" bounded-command \
            > "$TMP/run-bounded-unavailable.out" 2>&1
        unavailable_status=$?
        set -e
        if [ "$unavailable_status" -ne 0 ] && [ ! -e "$RUN_MARKER" ] \
            && grep -q 'aggregate cgroup-v2 containment is unavailable' \
                "$TMP/run-bounded-unavailable.out"; then
            pass "no selected command starts without aggregate containment"
        else
            fail "an unavailable aggregate boundary fell back to partial containment"
        fi
    fi
fi

info "C++ build bounds fail before filesystem or tool effects"
INSTALL_ROOT="$TMP/install-root"
mkdir -p "$INSTALL_ROOT/scripts/install"
cp "$ROOT/scripts/install/50-cpp-builds.sh" \
    "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh"
cp "$ROOT/scripts/install/lib.sh" "$INSTALL_ROOT/scripts/install/lib.sh"
cat > "$INSTALL_ROOT/scripts/run-bounded.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s :: %s\n' "${RUN_BOUNDED_VMEM_KB:?}" "$*" \
    >> "${CPP_BOUND_LOG:-/dev/null}"
if [ "${CPP_FAIL_STAGE:-}" = boundary ] \
    && [[ "$*" == 'pixi run -- conan install '* ]]; then
    exit 59
fi
exec "$@"
SH
chmod +x "$INSTALL_ROOT/scripts/run-bounded.sh"
for cpp_repo in \
    control/Agamemnon \
    control/Nestor \
    provisioning/Keystone \
    testing/Charybdis; do
    mkdir -p \
        "$INSTALL_ROOT/$cpp_repo/src" \
        "$INSTALL_ROOT/$cpp_repo/cmake" \
        "$INSTALL_ROOT/$cpp_repo/conan/profiles"
    printf '%s\n' 'cmake_minimum_required(VERSION 3.20)' \
        > "$INSTALL_ROOT/$cpp_repo/CMakeLists.txt"
    printf '%s\n' '{"version": 3}' \
        > "$INSTALL_ROOT/$cpp_repo/CMakePresets.json"
    printf '%s\n' 'int main() { return 0; }' \
        > "$INSTALL_ROOT/$cpp_repo/src/main.cpp"
    printf '%s\n' '# approved toolchain' \
        > "$INSTALL_ROOT/$cpp_repo/cmake/toolchain.cmake"
    ln -s toolchain.cmake \
        "$INSTALL_ROOT/$cpp_repo/cmake/linked-toolchain.cmake"
    printf '%s\n' 'from conan import ConanFile' \
        > "$INSTALL_ROOT/$cpp_repo/conanfile.py"
    printf '%s\n' '[settings]' \
        > "$INSTALL_ROOT/$cpp_repo/conan/profiles/default"
    git -C "$INSTALL_ROOT/$cpp_repo" init -q
    git -C "$INSTALL_ROOT/$cpp_repo" add \
        CMakeLists.txt \
        CMakePresets.json \
        src/main.cpp \
        cmake/toolchain.cmake \
        cmake/linked-toolchain.cmake \
        conanfile.py \
        conan/profiles/default
    git -C "$INSTALL_ROOT/$cpp_repo" \
        -c user.name='Odysseus fixture' \
        -c user.email='fixture@example.invalid' \
        -c commit.gpgsign=false \
        commit -qm 'Create C++ input fixture'
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
    'ODYSSEUS_BUILD_VMEM_KB=0' \
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

info "C++ executes the selected resource-bound helper after pathname replacement"
cp "$INSTALL_ROOT/scripts/run-bounded.sh" \
    "$TMP/run-bounded-fixture-approved.sh"
cat > "$INSTALL_ROOT/scripts/run-bounded.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s :: %s\n' "${RUN_BOUNDED_VMEM_KB:?}" "$*" \
    >> "${CPP_BOUND_LOG:-/dev/null}"
if [ "${CPP_REPLACE_BOUND_HELPER:-}" = true ] \
    && [ ! -e "${CPP_HELPER_REPLACED_MARKER:?}" ]; then
    : > "$CPP_HELPER_REPLACED_MARKER"
    mv "${CPP_BOUND_HELPER_PATH:?}" "$CPP_BOUND_HELPER_PATH.approved"
    cat > "$CPP_BOUND_HELPER_PATH" <<'HOSTILE'
#!/usr/bin/env bash
: > "${CPP_HOSTILE_HELPER_SENTINEL:?}"
exit 86
HOSTILE
    chmod +x "$CPP_BOUND_HELPER_PATH"
fi
exec "$@"
SH
chmod +x "$INSTALL_ROOT/scripts/run-bounded.sh"
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD :: $*" >> "${PIXI_LOG:?}"
if [[ "$*" == 'run -- cmake --build --preset release '* ]]; then
    mkdir -p build/release
fi
if [[ "$*" == 'run -- cmake --install build/release --prefix '* ]]; then
    prefix=${*: -1}
    artifact="$prefix/bin/${PWD##*/}-helper-fixture"
    mkdir -p build/release "$prefix/bin"
    printf '%s\n' 'verified helper fixture' > "$artifact"
    printf '%s\n' "$artifact" > build/release/install_manifest.txt
fi
exit 0
SH
chmod +x "$FAKE_BIN/pixi"
helper_log="$TMP/cpp-helper-replacement.log"
helper_replaced="$TMP/cpp-helper-replaced.marker"
helper_sentinel="$TMP/cpp-hostile-helper.sentinel"
: > "$helper_log"
set +e
ROLE=control INSTALL=true \
    ODYSSEUS_ROOT="$INSTALL_ROOT" \
    ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-helper-replacement" \
    ODYSSEUS_BUILD_VMEM_KB=262144 \
    CPP_REPLACE_BOUND_HELPER=true \
    CPP_BOUND_HELPER_PATH="$INSTALL_ROOT/scripts/run-bounded.sh" \
    CPP_HELPER_REPLACED_MARKER="$helper_replaced" \
    CPP_HOSTILE_HELPER_SENTINEL="$helper_sentinel" \
    PIXI_LOG="$helper_log" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
    > "$TMP/cpp-helper-replacement.out" 2>&1
helper_status=$?
set -e
if [ "$helper_status" -eq 0 ] \
    && [ -e "$helper_replaced" ] \
    && [ ! -e "$helper_sentinel" ] \
    && [ "$(grep -c 'built and installed' \
        "$TMP/cpp-helper-replacement.out")" -eq 4 ]; then
    pass "the selected helper bytes survive a same-UID pathname replacement"
else
    sed 's/^/    /' "$TMP/cpp-helper-replacement.out" >&2
    fail "a replacement helper executed or stopped the selected helper bytes"
fi
rm -f "$INSTALL_ROOT/scripts/run-bounded.sh"
rm -f "$INSTALL_ROOT/scripts/run-bounded.sh.approved"
cp "$TMP/run-bounded-fixture-approved.sh" \
    "$INSTALL_ROOT/scripts/run-bounded.sh"
chmod +x "$INSTALL_ROOT/scripts/run-bounded.sh"

info "C++ build stages use one private snapshot of every tracked input"
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD :: $*" >> "${PIXI_LOG:?}"
if [[ "$PWD" == */control/Agamemnon ]] \
    && [[ "$*" == 'run -- conan install '* ]] \
    && [ ! -e "${CPP_INPUT_REPLACED_MARKER:?}" ]; then
    : > "$CPP_INPUT_REPLACED_MARKER"
    mv "${CPP_SWAP_INPUT:?}" "$CPP_SWAP_INPUT.approved"
    printf '%s\n' 'hostile replacement' > "$CPP_SWAP_INPUT"
fi
if [[ "$PWD" == */control/Agamemnon ]] \
    && [[ "$*" == 'run -- cmake --preset release'* ]]; then
    case "${CPP_SWAP_EXPECTED_TYPE:?}" in
        regular)
            if grep -q 'hostile replacement' "${CPP_SWAP_RELATIVE:?}"; then
                : > "${CPP_SWAP_SENTINEL:?}"
            fi
            ;;
        symlink)
            if [[ ! -L "${CPP_SWAP_RELATIVE:?}" ]]; then
                : > "${CPP_SWAP_SENTINEL:?}"
            fi
            ;;
    esac
fi
if [[ "$*" == 'run -- cmake --build --preset release '* ]]; then
    mkdir -p build/release
fi
if [[ "$*" == 'run -- cmake --install build/release --prefix '* ]]; then
    prefix=${*: -1}
    artifact="$prefix/bin/${PWD##*/}-input-fixture"
    mkdir -p build/release "$prefix/bin"
    printf '%s\n' 'verified input fixture' > "$artifact"
    printf '%s\n' "$artifact" > build/release/install_manifest.txt
fi
exit 0
SH
chmod +x "$FAKE_BIN/pixi"
for input_case in \
    'cmake-root|CMakeLists.txt|regular' \
    'source|src/main.cpp|regular' \
    'preset|CMakePresets.json|regular' \
    'toolchain|cmake/toolchain.cmake|regular' \
    'toolchain-symlink|cmake/linked-toolchain.cmake|symlink' \
    'conan-recipe|conanfile.py|regular' \
    'conan-profile|conan/profiles/default|regular'; do
    input_label=${input_case%%|*}
    input_tail=${input_case#*|}
    input_relative=${input_tail%%|*}
    input_type=${input_tail##*|}
    input_path="$INSTALL_ROOT/control/Agamemnon/$input_relative"
    input_log="$TMP/cpp-input-$input_label.log"
    input_replaced="$TMP/cpp-input-$input_label.marker"
    input_sentinel="$TMP/cpp-input-$input_label.sentinel"
    : > "$input_log"
    set +e
    ROLE=control INSTALL=true \
        ODYSSEUS_ROOT="$INSTALL_ROOT" \
        ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-input-$input_label" \
        ODYSSEUS_BUILD_VMEM_KB=262144 \
        CPP_SWAP_INPUT="$input_path" \
        CPP_SWAP_RELATIVE="$input_relative" \
        CPP_SWAP_EXPECTED_TYPE="$input_type" \
        CPP_INPUT_REPLACED_MARKER="$input_replaced" \
        CPP_SWAP_SENTINEL="$input_sentinel" \
        PIXI_LOG="$input_log" PATH="$FAKE_BIN:/usr/bin:/bin" \
        "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
        > "$TMP/cpp-input-$input_label.out" 2>&1
    input_status=$?
    set -e
    if [ "$input_status" -eq 0 ] \
        && [ -e "$input_replaced" ] \
        && [ ! -e "$input_sentinel" ] \
        && [ "$(grep -c 'built and installed' \
            "$TMP/cpp-input-$input_label.out")" -eq 4 ]; then
        pass "$input_label replacement cannot change selected build input bytes"
    else
        sed 's/^/    /' "$TMP/cpp-input-$input_label.out" >&2
        fail "$input_label replacement reached a later build stage"
    fi
    if [ -e "$input_path.approved" ] || [ -L "$input_path.approved" ]; then
        rm -f "$input_path"
        mv "$input_path.approved" "$input_path"
    fi
done

info "C++ build stages stop at the first failed required operation"
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "${PIXI_LOG:?}"
case "${CPP_FAIL_STAGE:-}:$*" in
    conan:'run -- conan install '*) exit 60 ;;
    configure:'run -- cmake --preset release'*) exit 61 ;;
    build:'run -- cmake --build --preset release'*) exit 62 ;;
    install:'run -- cmake --install '*) exit 63 ;;
esac
if [[ "$*" == 'run -- cmake --build --preset release '* ]]; then
    mkdir -p build/release
fi
exit 0
SH
chmod +x "$FAKE_BIN/pixi"
CD_ENV="$TMP/cd-env.sh"
cat > "$CD_ENV" <<'SH'
if [ "${CPP_FAIL_STAGE:-}" = cd ]; then
    cd() {
        case "$1" in
            */odysseus-cpp-build.*/sources/control/Agamemnon|\
            */odysseus-cpp-build.*/sources/control/Nestor|\
            */odysseus-cpp-build.*/sources/provisioning/Keystone|\
            */odysseus-cpp-build.*/sources/testing/Charybdis)
                printf '%s\n' cd-target >> "${CPP_SEAM_LOG:?}"
                return 64
                ;;
        esac
        builtin cd "$@"
    }
fi
SH

for failure_stage in boundary cd conan configure build install verify; do
    pixi_log="$TMP/pixi-$failure_stage.log"
    seam_log="$TMP/seam-$failure_stage.log"
    output="$TMP/cpp-$failure_stage.out"
    : > "$pixi_log"
    : > "$seam_log"
    failure_vmem=262144
    for cpp_role in control all worker; do
        : > "$pixi_log"
        : > "$seam_log"
        set +e
        BASH_ENV="$CD_ENV" CPP_FAIL_STAGE="$failure_stage" \
            CPP_SEAM_LOG="$seam_log" \
            CPP_BOUND_LOG="$seam_log" \
            PIXI_LOG="$pixi_log" ODYSSEUS_ROOT="$INSTALL_ROOT" \
            ODYSSEUS_RUNTIME_PREFIX="$TMP/runtime-$failure_stage-$cpp_role" \
            ODYSSEUS_BUILD_VMEM_KB="$failure_vmem" INSTALL=true \
            ROLE="$cpp_role" PATH="$FAKE_BIN:/usr/bin:/bin" \
            "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
            > "$output" 2>&1
        status=$?
        set -e

    case "$failure_stage" in
        boundary)
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
        install|verify)
            later_effect='a^'
            ;;
    esac
    target_reached=0
    case "$failure_stage" in
        boundary)
            if grep -q '^262144 :: pixi run -- conan install ' \
                "$seam_log"; then
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
        install|verify)
            if grep -q '^run -- conan install \. --build=missing ' "$pixi_log" \
                && grep -q '^run -- cmake --preset release ' "$pixi_log" \
                && grep -q '^run -- cmake --build --preset release ' "$pixi_log" \
                && grep -q '^run -- cmake --install build/release --prefix ' "$pixi_log"; then
                target_reached=1
            fi
            ;;
    esac
        if [ "$status" -ne 0 ] \
            && grep -q '✗.*build failed' "$output" \
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

info "C++ success is reported only after installed objects are verified"
cat > "$FAKE_BIN/pixi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$PWD :: $*" >> "${PIXI_LOG:?}"
if [[ "$*" == 'run -- cmake --build --preset release '* ]]; then
    mkdir -p build/release
fi
if [[ "$*" == 'run -- cmake --install build/release --prefix '* ]]; then
    prefix=${*: -1}
    artifact="$prefix/bin/${PWD##*/}-fixture"
    mkdir -p build/release "$prefix/bin"
    printf '%s\n' "verified fixture" > "$artifact"
    printf '%s\n' "$artifact" > build/release/install_manifest.txt
fi
exit 0
SH
chmod +x "$FAKE_BIN/pixi"
verified_prefix="$TMP/runtime-verified"
verified_log="$TMP/pixi-verified.log"
: > "$verified_log"
set +e
ROLE=control INSTALL=true \
    ODYSSEUS_ROOT="$INSTALL_ROOT" \
    ODYSSEUS_RUNTIME_PREFIX="$verified_prefix" \
    ODYSSEUS_BUILD_VMEM_KB=262144 \
    PIXI_LOG="$verified_log" PATH="$FAKE_BIN:/usr/bin:/bin" \
    "$BASH" "$INSTALL_ROOT/scripts/install/50-cpp-builds.sh" \
    > "$TMP/cpp-verified.out" 2>&1
verified_status=$?
set -e
verified_count=$(find "$verified_prefix/bin" -type f -name '*-fixture' 2>/dev/null | wc -l | tr -d ' ')
if [ "$verified_status" -eq 0 ] \
    && [ "$verified_count" -eq 4 ] \
    && [ "$(grep -c 'built and installed' "$TMP/cpp-verified.out")" -eq 4 ]; then
    pass "successful installs verify every selected repository artifact"
else
    fail "a selected repository became success without a verified installed artifact"
fi

summary
exit_code
