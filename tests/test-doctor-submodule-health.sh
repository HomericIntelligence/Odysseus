#!/usr/bin/env bash
# Behavior tests for fail-closed, read-only submodule doctor checks.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TEST_PLATFORM=$(uname -s)

FIXTURE_ROOT="$TMP/repo"
FAKE_BIN="$TMP/bin"
PYTHONLESS_BIN="$TMP/pythonless-bin"
DOCTOR_HOME="$TMP/home"
TEST_STATE_DIR="$DOCTOR_HOME/.doctor-state"
GIT_LOG="$TMP/git.log"
PYTHON_LOG="$TMP/python.log"
TAILSCALE_LOG="$TMP/tailscale.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"
BOUNDARY_ENV_LEAK_MARKER="$TMP/boundary-env.leaked"
PYTHON_REPLACEMENT_MARKER="$TMP/python-path.replaced"
SYSTEMCTL_CHILD_PID="$TMP/systemctl-child.pid"
SYSTEMCTL_HEARTBEAT_MARKER="$TMP/systemctl-child.heartbeat"
SYSTEMCTL_EFFECT_MARKER="$TMP/systemctl.effect"
PREFLIGHT_PROBE_PID="$TMP/preflight-probe.pid"
POST_LAUNCH_DIRECT_PID="$TMP/post-launch-direct.pid"
CONAN_CHILD_PID="$TMP/conan-child.pid"
CONAN_HEARTBEAT_MARKER="$TMP/conan-child.heartbeat"
CONAN_EFFECT_MARKER="$TMP/conan.effect"
CONAN_PROFILE_MARKER="$TMP/conan.profile"
SUDO_CHILD_PID="$TMP/sudo-child.pid"
SUDO_HEARTBEAT_MARKER="$TMP/sudo-child.heartbeat"
SUDO_EFFECT_MARKER="$TMP/sudo.effect"
RM_CHILD_PID="$TMP/rm-child.pid"
RM_HEARTBEAT_MARKER="$TMP/rm-child.heartbeat"
RM_EFFECT_MARKER="$TMP/rm.effect"
PING_LOG="$TMP/ping.log"
CURL_LOG="$TMP/curl.log"
CURL_BODY_COMPLETE_MARKER="$TMP/curl-body.complete"
CURL_REPLACEMENT_MARKER="$TMP/curl-path.replaced"
CURL_ATTACK_SENTINEL="$TMP/curl-attack.sentinel"
CURL_ENV_LEAK_MARKER="$TMP/curl-env.leaked"
CURL_ENV_LOG="$TMP/curl.env"
CURL_FD_LOG="$TMP/curl.fds"
APT_LOG="$TMP/apt.log"
PACKAGE_INSTALL_LOG="$TMP/package-install.log"
TAILSCALE_RUNNING_MARKER="$TMP/tailscale.running"
GIT_STATUS_READ_MARKER="$TMP/git-status.read"
LIBSSL_INSTALL_MARKER="$TMP/libssl.installed"
PYTHON_REPAIRED_MARKER="$TMP/python.repaired"
PROCESS_OUTPUT_MARKER="$TMP/process-output.complete"
PROCESS_CHILD_PID="$TMP/process-child.pid"
PROCESS_HEARTBEAT_MARKER="$TMP/process-child.heartbeat"
GIT_UPDATE_EFFECT_MARKER="$TMP/git-update.effect"
GIT_UPDATE_CHILD_PID="$TMP/git-update-child.pid"
GIT_UPDATE_HEARTBEAT_MARKER="$TMP/git-update-child.heartbeat"
GIT_ATTACK_SENTINEL="$TMP/git-attack.sentinel"
PYTHON_ATTACK_SENTINEL="$TMP/python-attack.sentinel"
DOCTOR_RUNTIME_DIR="$TMP/runtime"
mkdir -p "$FIXTURE_ROOT/e2e/lib" \
    "$FIXTURE_ROOT/provisioning/Myrmidons/scripts" "$FAKE_BIN" \
    "$FIXTURE_ROOT/.git" \
    "$TEST_STATE_DIR" \
    "$DOCTOR_HOME/.local/src/podman-fixture/contrib/systemd/user" \
    "$DOCTOR_RUNTIME_DIR"
cat > "$DOCTOR_HOME/.doctor-state-helper.sh" <<'SH'
state_value() {
    local state_name=$1 default_value=${2:-}
    if [ -f "$HOME/.doctor-state/$state_name" ]; then
        IFS= read -r state_result < "$HOME/.doctor-state/$state_name"
        printf '%s\n' "$state_result"
    else
        printf '%s\n' "$default_value"
    fi
}
load_state() {
    local state_name=$1 variable_name=$2 default_value=${3:-}
    if [ -f "$HOME/.doctor-state/$state_name" ]; then
        IFS= read -r "$variable_name" < "$HOME/.doctor-state/$state_name"
    else
        printf -v "$variable_name" '%s' "$default_value"
    fi
}
SH
printf '%s\n' '[Socket]' \
    > "$DOCTOR_HOME/.local/src/podman-fixture/contrib/systemd/user/podman.socket"
printf '%s\n' '[Service]' 'ExecStart=@@PODMAN@@ system service' \
    > "$DOCTOR_HOME/.local/src/podman-fixture/contrib/systemd/user/podman.service.in"
cp "$ROOT/e2e/doctor.sh" "$FIXTURE_ROOT/e2e/doctor.sh"
cp "$ROOT/e2e/lib/common.sh" "$FIXTURE_ROOT/e2e/lib/common.sh"
cat > "$FIXTURE_ROOT/.gitmodules" <<'EOF'
[submodule "provisioning/Myrmidons"]
    path = provisioning/Myrmidons
    url = https://github.com/HomericIntelligence/Myrmidons.git
EOF
printf '%s\n' '[core]' '    repositoryformatversion = 0' \
    > "$FIXTURE_ROOT/.git/config"
printf '%s\n' 'fixture index authority' > "$FIXTURE_ROOT/.git/index"
printf '%s\n' 'MAESTRO_URL=http://retired.invalid' \
    > "$FIXTURE_ROOT/provisioning/Myrmidons/scripts/stale.sh"

printf '#!/usr/bin/env bash\nTEST_STATE_DIR=%q\n' "$TMP" \
    > "$FAKE_BIN/git"
cat >> "$FAKE_BIN/git" <<'SH'
GIT_LOG="$TEST_STATE_DIR/git.log"
GIT_STATUS_READ_MARKER="$TEST_STATE_DIR/git-status.read"
GIT_UPDATE_EFFECT_MARKER="$TEST_STATE_DIR/git-update.effect"
GIT_UPDATE_CHILD_PID="$TEST_STATE_DIR/git-update-child.pid"
GIT_UPDATE_HEARTBEAT_MARKER="$TEST_STATE_DIR/git-update-child.heartbeat"
GIT_ATTACK_SENTINEL="$TEST_STATE_DIR/git-attack.sentinel"
BOUNDARY_ENV_LEAK_MARKER="$TEST_STATE_DIR/boundary-env.leaked"
load_test_state() {
    local state_name=$1 variable_name=$2 default_value=$3
    if [ -f "$TEST_STATE_DIR/$state_name" ]; then
        IFS= read -r "$variable_name" < "$TEST_STATE_DIR/$state_name"
    else
        printf -v "$variable_name" '%s' "$default_value"
    fi
}
load_test_state git-submodule.mode GIT_SUBMODULE_MODE ok
load_test_state git-security.mode GIT_SECURITY_MODE clean
load_test_state assert-clean-git-env ASSERT_CLEAN_GIT_ENV false
load_test_state assert-safe-git-update ASSERT_SAFE_GIT_UPDATE false
load_test_state broken-version.tool BROKEN_VERSION_TOOL ''
load_test_state broken-version.mode BROKEN_VERSION_MODE fail
original_args="$*"
git_root=""
safe_protocol=false
while [ "$#" -gt 0 ]; do
    case "$1" in
        -c)
            case "${2:-}" in
                protocol.allow=never) safe_protocol=true ;;
            esac
            shift 2
            ;;
        -C)
            git_root="${2:-}"
            shift 2
            ;;
        --git-dir=*|--work-tree=*)
            shift
            ;;
        *) break ;;
    esac
done
printf '%s\n' "$*" >> "$GIT_LOG"
if [ "${1:-}" = "--version" ]; then
    if [ "${BROKEN_VERSION_TOOL:-}" = "git" ]; then
        if [ "${BROKEN_VERSION_MODE:-fail}" = empty ]; then
            exit 0
        fi
        exit 64
    fi
    printf '%s\n' 'git version 2.50.0'
    exit 0
fi
if [ -n "${DOCTOR_UNRELATED_SECRET:-}" ]; then
    : > "${BOUNDARY_ENV_LEAK_MARKER:?}"
fi
if [ "${ASSERT_CLEAN_GIT_ENV:-false}" = true ]; then
    if [ -n "${GIT_DIR+x}" ] || [ -n "${GIT_WORK_TREE+x}" ] \
        || [ -n "${GIT_COMMON_DIR+x}" ] || [ -n "${GIT_CONFIG+x}" ] \
        || [ "${GIT_CONFIG_GLOBAL:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_SYSTEM:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_NOSYSTEM:-}" != 1 ] \
        || [ "${GIT_CONFIG_COUNT:-}" != 0 ] \
        || [ -n "${GIT_CONFIG_PARAMETERS+x}" ] \
        || [ -n "${GIT_SSH+x}" ] || [ -n "${GIT_SSH_COMMAND+x}" ] \
        || [ -n "${GIT_ALLOW_PROTOCOL+x}" ]; then
        : > "${GIT_ATTACK_SENTINEL:?}"
        exit 98
    fi
fi
if [ "${1:-}" = "submodule" ] && [ "${2:-}" = "status" ]; then
    if [ "${GIT_SUBMODULE_MODE:-ok}" = fail ]; then
        exit 42
    fi
    if [ "${GIT_SUBMODULE_MODE:-ok}" = uninit_then_empty ] \
        || [ "${GIT_SUBMODULE_MODE:-ok}" = uninit_then_ok ]; then
        if [ ! -e "$GIT_STATUS_READ_MARKER" ]; then
            : > "$GIT_STATUS_READ_MARKER"
            printf '%s\n' '-0123456789012345678901234567890123456789 provisioning/Myrmidons'
        elif [ "${GIT_SUBMODULE_MODE:-ok}" = uninit_then_ok ]; then
            printf '%s\n' ' 0123456789012345678901234567890123456789 provisioning/Myrmidons (heads/main)'
        fi
        exit 0
    fi
    printf '%s\n' ' 0123456789012345678901234567890123456789 provisioning/Myrmidons (heads/main)'
    exit 0
fi
if [ "${1:-}" = "config" ]; then
    case "$*" in
        *'^submodule\..*\.path$'*)
            printf '%s\n' 'submodule.provisioning/Myrmidons.path provisioning/Myrmidons'
            exit 0
            ;;
        *'^submodule\..*\.url$'*)
            printf '%s\n' 'submodule.provisioning/Myrmidons.url https://github.com/HomericIntelligence/Myrmidons.git'
            exit 0
            ;;
        *forbidden*|*'\.update'*|*insteadOf*|*'protocol\.'*)
            case "${GIT_SECURITY_MODE:-clean}" in
                custom-update)
                    printf '%s\n' 'submodule.provisioning/Myrmidons.update !touch attack'
                    exit 0
                    ;;
                url-rewrite)
                    printf '%s\n' 'url.https://evil.invalid/.insteadOf https://github.com/'
                    exit 0
                    ;;
                protocol-rewrite)
                    printf '%s\n' 'protocol.file.allow always'
                    exit 0
                    ;;
            esac
            exit 1
            ;;
        *'--get submodule.provisioning/Myrmidons.url'*)
            printf '%s\n' 'https://github.com/HomericIntelligence/Myrmidons.git'
            exit 0
            ;;
    esac
    exit 1
fi
if [ "${1:-}" = "submodule" ] && [ "${2:-}" = "update" ]; then
    if [ "${ASSERT_SAFE_GIT_UPDATE:-false}" = true ]; then
        if ! $safe_protocol \
            || [[ "$original_args" != *'protocol.https.allow=always'* ]] \
            || [[ "$original_args" != *'protocol.file.allow=never'* ]] \
            || [ "$*" != 'submodule update --init -- provisioning/Myrmidons' ]; then
            : > "${GIT_ATTACK_SENTINEL:?}"
            exit 97
        fi
    fi
    case "${GIT_SECURITY_MODE:-clean}" in
        custom-update|url-rewrite|protocol-rewrite)
            : > "${GIT_ATTACK_SENTINEL:?}"
            ;;
        update-replace|update-manifest-replace|update-authority-replace)
            mv "$git_root/.gitmodules" "$git_root/.gitmodules.displaced"
            printf '%s\n' '[submodule "attacker"]' \
                '    path = attacker/owned' \
                '    url = file:///tmp/attacker' \
                > "$git_root/.gitmodules"
            if [ "${GIT_SECURITY_MODE:-clean}" = update-authority-replace ]; then
                mv "$git_root/.git/config" "$git_root/.git/config.displaced"
                printf '%s\n' '[url "file:///tmp/attacker"]' \
                    '    insteadOf = https://github.com/' \
                    > "$git_root/.git/config"
                mv "$git_root/.git/index" "$git_root/.git/index.displaced"
                printf '%s\n' 'attacker index authority' \
                    > "$git_root/.git/index"
            fi
            : > "${GIT_UPDATE_EFFECT_MARKER:?}"
            ;;
        update-gitdir-replace)
            mv "$git_root/.git" "$git_root/.git.displaced"
            mkdir "$git_root/.git"
            : > "${GIT_UPDATE_EFFECT_MARKER:?}"
            ;;
        update-config-replace)
            mv "$git_root/.git/config" "$git_root/.git/config.displaced"
            printf '%s\n' '[url "file:///tmp/attacker"]' \
                '    insteadOf = https://github.com/' \
                > "$git_root/.git/config"
            : > "${GIT_UPDATE_EFFECT_MARKER:?}"
            ;;
        update-index-replace|update-gitlink-replace)
            mv "$git_root/.git/index" "$git_root/.git/index.displaced"
            printf '%s\n' 'attacker index authority' \
                > "$git_root/.git/index"
            : > "${GIT_UPDATE_EFFECT_MARKER:?}"
            ;;
        update-hang)
            sleep 8 || exit 70
            : > "${GIT_UPDATE_EFFECT_MARKER:?}"
            ;;
        update-escape)
            if [ "$(uname -s)" = Linux ]; then
                setsid bash -c 'trap "" TERM; printf "%s\n" "$$" > "${GIT_UPDATE_CHILD_PID:?}"; while :; do printf x >> "${GIT_UPDATE_HEARTBEAT_MARKER:?}"; sleep 0.05; done' \
                    </dev/null >/dev/null 2>&1 &
            fi
            ;;
    esac
    exit 0
fi
exit 0
SH

cat > "$FAKE_BIN/grep" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state grep-scan.mode GREP_SCAN_MODE ok
if [ "${1:-}" = "-rE" ] && [ "$GREP_SCAN_MODE" = fail ]; then
    exit 2
fi
if [ "${1:-}" = "-rE" ] && [ "$GREP_SCAN_MODE" = nomatch ]; then
    exit 1
fi
exec /usr/bin/grep "$@"
SH

for command_name in just pip3 jq ninja make pixi cargo; do
    printf '#!/usr/bin/env bash\nFIXTURE_COMMAND_NAME=%q\n' "$command_name" \
        > "$FAKE_BIN/$command_name"
    cat >> "$FAKE_BIN/$command_name" <<'SH'
source "$HOME/.doctor-state-helper.sh"
load_state package-install-log.path PACKAGE_INSTALL_LOG
load_state broken-version.tool BROKEN_VERSION_TOOL
load_state broken-version.mode BROKEN_VERSION_MODE fail
load_state process-output.path PROCESS_OUTPUT_MARKER
load_state process-child-pid.path PROCESS_CHILD_PID
load_state process-heartbeat.path PROCESS_HEARTBEAT_MARKER
load_state test-platform.name TEST_PLATFORM
command_name=$FIXTURE_COMMAND_NAME
case "$command_name" in
    pip3|cargo) printf '%s %s\n' "$command_name" "$*" >> "$PACKAGE_INSTALL_LOG" ;;
esac
if [ "$BROKEN_VERSION_TOOL" = "$command_name" ]; then
    case "$BROKEN_VERSION_MODE" in
        empty) exit 0 ;;
        flood)
            /usr/bin/python3 -I -S - "${PROCESS_OUTPUT_MARKER:?}" <<'PY'
import os
from pathlib import Path
import sys

for _ in range(4):
    os.write(sys.stdout.fileno(), b"x" * 65536)
Path(sys.argv[1]).write_text("complete\n", encoding="utf-8")
PY
            exit $?
            ;;
        slow-tree)
            if [ "$TEST_PLATFORM" = Linux ]; then
                PROCESS_CHILD_PID="$PROCESS_CHILD_PID" \
                PROCESS_HEARTBEAT_MARKER="$PROCESS_HEARTBEAT_MARKER" \
                bash -c 'trap "" TERM; printf "%s\n" "$$" > "${PROCESS_CHILD_PID:?}"; while :; do printf x >> "${PROCESS_HEARTBEAT_MARKER:?}"; sleep 0.05; done' \
                    >/dev/null 2>&1 &
            else
                trap '' TERM
                printf '%s\n' "$$" > "${PROCESS_CHILD_PID:?}"
                while :; do
                    printf x >> "${PROCESS_HEARTBEAT_MARKER:?}"
                    sleep 0.05
                done
            fi
            trap '' TERM
            sleep 6
            exit 64
            ;;
        success-escape)
            /usr/bin/python3 -I -S - \
                "${PROCESS_CHILD_PID:?}" \
                "${PROCESS_HEARTBEAT_MARKER:?}" \
                <<'PY' >/dev/null 2>&1 &
import os
import signal
import sys
import time

if os.fork() != 0:
    raise SystemExit(0)
os.setsid()
if os.fork() != 0:
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
while True:
    with open(sys.argv[2], "a", encoding="ascii") as stream:
        stream.write("x")
    time.sleep(0.05)
PY
            printf '%s\n' 'fixture 1.0.0'
            exit 0
            ;;
        *) exit 64 ;;
    esac
fi
printf '%s\n' 'fixture 1.0.0'
SH
done

printf '#!/usr/bin/env bash\nDOCTOR_STATE_HOME=%q\n' "$DOCTOR_HOME" \
    > "$FAKE_BIN/curl"
cat >> "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
HOME=$DOCTOR_STATE_HOME
source "$DOCTOR_STATE_HOME/.doctor-state-helper.sh"
load_state curl-log.path CURL_LOG
load_state curl-env-log.path CURL_ENV_LOG
load_state curl-fd-log.path CURL_FD_LOG
load_state broken-version.tool BROKEN_VERSION_TOOL
load_state broken-version.mode BROKEN_VERSION_MODE fail
load_state curl-health.mode CURL_HEALTH_MODE valid
load_state curl-body-complete.path CURL_BODY_COMPLETE_MARKER
load_state curl-bind.mode CURL_BIND_MODE clean
load_state curl-source.path CURL_SOURCE
load_state curl-replacement.path CURL_REPLACEMENT_MARKER
load_state curl-attack.path CURL_ATTACK_SENTINEL
load_state curl-env-leak.path CURL_ENV_LEAK_MARKER
load_state test-platform.name TEST_PLATFORM
unset HOME
printf '%s\n' "$*" >> "$CURL_LOG"
printf '%s\n' "${1-}" >> "$CURL_LOG.first-options"
export -p >> "$CURL_ENV_LOG"
printf '%s\n' -- >> "$CURL_ENV_LOG"
if [ -d /proc/$$/fd ]; then
    # Probe before redirecting output: Bash keeps backup descriptors open
    # while a compound command or builtin has temporary redirections.
    for number in 9 10 11 12 190 191 192 193 194 195 196 197 205; do
        if [ -L "/proc/$$/fd/$number" ]; then
            printf '%s\n' "$number" >> "$CURL_FD_LOG"
        fi
    done
    printf '%s\n' -- >> "$CURL_FD_LOG"
fi
if [ "$BROKEN_VERSION_TOOL" = "curl" ]; then
    if [ "$BROKEN_VERSION_MODE" = empty ]; then
        exit 0
    fi
    exit 64
fi
case " $* " in
*' --version '*)
    if [ "$TEST_PLATFORM" = Linux ] \
        && [ "$CURL_BIND_MODE" = replace-after-version ] \
        && [ ! -e "$CURL_REPLACEMENT_MARKER" ]; then
        chmod u+w "$CURL_SOURCE"
        mv "$CURL_SOURCE" "$CURL_SOURCE.bound"
        cat > "$CURL_SOURCE" <<'ATTACK'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state curl-attack.path CURL_ATTACK_SENTINEL
: > "$CURL_ATTACK_SENTINEL"
exit 97
ATTACK
        chmod 500 "$CURL_SOURCE"
        : > "$CURL_REPLACEMENT_MARKER"
    fi
    printf '%s\n' 'curl 8.0.0'
    exit 0
    ;;
esac
url=""
connect_timeout=""
max_time=""
write_out=""
output_target=""
previous=""
for argument in "$@"; do
    case "$argument" in http://*|https://*) url="$argument" ;; esac
    case "$previous" in
        --connect-timeout) connect_timeout="$argument" ;;
        --max-time) max_time="$argument" ;;
        --write-out|-w) write_out="$argument" ;;
        --output|-o) output_target="$argument" ;;
    esac
    previous="$argument"
done
if [ -n "$url" ]; then
    if [ -n "${DOCTOR_UNRELATED_SECRET:-}" ]; then
        : > "$CURL_ENV_LEAK_MARKER"
    fi
    case "$connect_timeout:$max_time" in
        *[!0-9:]*|0:*|*:0|:*) exit 98 ;;
    esac
    [ "$connect_timeout" -le "$max_time" ] || exit 98
    [ "$max_time" -le 60 ] || exit 98
fi

emit_response() {
    local body="$1" code="$2"
    if [ "$output_target" != /dev/null ] && [ -n "$body" ]; then
        printf '%s\n' "$body"
    fi
    if [ -n "$write_out" ]; then
        case "$write_out" in
            '%{http_code}') printf '%s' "$code" ;;
            *) printf '\n%s' "$code" ;;
        esac
    fi
}
if [ "$CURL_HEALTH_MODE" = oversized ] \
    && [[ "$url" == *:8222/healthz ]]; then
    /usr/bin/python3 - "$CURL_BODY_COMPLETE_MARKER" "$write_out" <<'PY'
import os
from pathlib import Path
import signal
import sys

signal.signal(signal.SIGPIPE, signal.SIG_DFL)
for _ in range(32):
    os.write(sys.stdout.fileno(), b"x" * 65536)
Path(sys.argv[1]).write_text("complete\n", encoding="utf-8")
if sys.argv[2]:
    os.write(sys.stdout.fileno(), b"\n200")
PY
    exit $?
fi
if [ "$CURL_HEALTH_MODE" = wrong ]; then
    emit_response '{"status":"some-other-service"}' 200
    exit 0
fi
case "$url" in
    *:8222/healthz) emit_response '{"status":"ok"}' 200 ;;
    *:8080/v1/health|*:8081/v1/health) emit_response '{"status":"ok"}' 200 ;;
    *:8085/health) emit_response '{"status":"ok","nats_connected":true}' 200 ;;
    *:3001/api/health) emit_response '{"database":"ok"}' 200 ;;
    *:9090/-/healthy) emit_response 'Prometheus Server is Healthy.' 200 ;;
    *:9100/metrics) emit_response 'hi_agamemnon_health{} 1' 200 ;;
    *) exit 66 ;;
esac
SH

cat > "$FAKE_BIN/ping" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state ping-log.path PING_LOG
printf '%s\n' "$*" >> "$PING_LOG"
exit 0
SH

cat > "$FAKE_BIN/podman" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state broken-version.tool BROKEN_VERSION_TOOL
load_state broken-version.mode BROKEN_VERSION_MODE fail
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    if [ "$BROKEN_VERSION_TOOL" = "podman-compose" ]; then
        if [ "$BROKEN_VERSION_MODE" = empty ]; then
            exit 0
        fi
        exit 64
    fi
    printf '%s\n' 'podman-compose version 1.2.3'
    exit 0
fi
if [ "$BROKEN_VERSION_TOOL" = "podman" ]; then
    if [ "$BROKEN_VERSION_MODE" = empty ]; then
        exit 0
    fi
    exit 64
fi
printf '%s\n' 'podman version 5.4.0'
SH

cat > "$FAKE_BIN/cmake" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state broken-version.tool BROKEN_VERSION_TOOL
if [ "$BROKEN_VERSION_TOOL" = "cmake" ]; then
    exit 64
fi
printf '%s\n' 'cmake version 3.30.0'
SH

cat > "$FAKE_BIN/g++" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state broken-version.tool BROKEN_VERSION_TOOL
if [ "$BROKEN_VERSION_TOOL" = "g++" ]; then
    exit 64
fi
printf '%s\n' 'g++ 14.0.0'
SH

cat > "$FAKE_BIN/conan" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state conan.mode CONAN_MODE clean
load_state conan-child-pid.path CONAN_CHILD_PID
load_state conan-heartbeat.path CONAN_HEARTBEAT_MARKER
load_state conan-effect.path CONAN_EFFECT_MARKER
load_state conan-profile.path CONAN_PROFILE_MARKER
load_state broken-version.tool BROKEN_VERSION_TOOL
spawn_conan_descendant() {
    /usr/bin/python3 -I -S - \
        "${CONAN_CHILD_PID:?}" \
        "${CONAN_HEARTBEAT_MARKER:?}" \
        <<'PY' >/dev/null 2>&1 &
import os
import signal
import sys
import time

if os.fork() != 0:
    raise SystemExit(0)
os.setsid()
if os.fork() != 0:
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
while True:
    with open(sys.argv[2], "a", encoding="ascii") as stream:
        stream.write("x")
    time.sleep(0.05)
PY
}
if [ "${1:-}" = "profile" ]; then
    if [ "$CONAN_MODE" = show-hang ] && [ "${2:-}" = show ]; then
        spawn_conan_descendant
        sleep 8 || exit 70
        : > "${CONAN_EFFECT_MARKER:?}"
    fi
    if [ "$CONAN_MODE" = post-show-hang ]; then
        if [ "${2:-}" = show ] && [ ! -e "$CONAN_PROFILE_MARKER" ]; then
            exit 1
        fi
        if [ "${2:-}" = detect ]; then
            : > "$CONAN_PROFILE_MARKER"
            exit 0
        fi
        if [ "${2:-}" = show ] && [ -e "$CONAN_PROFILE_MARKER" ]; then
            spawn_conan_descendant
            sleep 8 || exit 70
            : > "${CONAN_EFFECT_MARKER:?}"
        fi
    fi
    if [ "$CONAN_MODE" = repair-hang ]; then
        if [ "${2:-}" = show ]; then
            exit 1
        fi
        if [ "${2:-}" = detect ]; then
            spawn_conan_descendant
            sleep 8 || exit 70
            : > "${CONAN_EFFECT_MARKER:?}"
        fi
    fi
    exit 0
fi
if [ "$BROKEN_VERSION_TOOL" = "conan" ]; then
    exit 64
fi
printf '%s\n' 'Conan version 2.0.0'
SH

cat > "$FAKE_BIN/dpkg" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state dpkg.mode mode ii
load_state dpkg-post-install.mode DPKG_POST_INSTALL_MODE ii
load_state libssl-install.path LIBSSL_INSTALL_MARKER
if [ -e "$LIBSSL_INSTALL_MARKER" ]; then
    mode="$DPKG_POST_INSTALL_MODE"
fi
case "$mode" in
    ii) printf '%s\n' 'ii  libssl-dev 3.0 fixture' ;;
    ii-empty-version) printf '%s\n' 'ii  libssl-dev' ;;
    rc) printf '%s\n' 'rc  libssl-dev 3.0 fixture' ;;
    non-ii) printf '%s\n' 'iU  libssl-dev 3.0 fixture' ;;
    empty) : ;;
    fail) exit 1 ;;
    *) exit 65 ;;
esac
SH

cat > "$FAKE_BIN/apt-get" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state apt-log.path APT_LOG
load_state libssl-install.path LIBSSL_INSTALL_MARKER
load_state python3.mode PYTHON3_MODE present
load_state python3-source.path PYTHON3_FIXTURE_SOURCE
load_state doctor-active-bin.path DOCTOR_ACTIVE_BIN
load_state python-repaired.path PYTHON_REPAIRED_MARKER
load_state apt-install.status APT_INSTALL_STATUS 0
printf '%s\n' "$*" >> "$APT_LOG"
if [ "${1:-}" = "install" ] && [ "${3:-}" = "libssl-dev" ]; then
    : > "$LIBSSL_INSTALL_MARKER"
fi
if [ "${1:-}" = "install" ] && [ "${3:-}" = "python3" ]; then
    case "$PYTHON3_MODE" in
        installable)
            cp "$PYTHON3_FIXTURE_SOURCE" "$DOCTOR_ACTIVE_BIN/python3"
            chmod +x "$DOCTOR_ACTIVE_BIN/python3"
            ;;
        parser-broken-installable)
            : > "$PYTHON_REPAIRED_MARKER"
            ;;
    esac
fi
exit "$APT_INSTALL_STATUS"
SH

cat > "$FAKE_BIN/python3" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state python-log.path PYTHON_LOG
load_state python3.mode PYTHON3_MODE present
load_state python-replacement.path PYTHON_REPLACEMENT_MARKER
load_state python3-source.path PYTHON3_FIXTURE_SOURCE
load_state python-attack.path PYTHON_ATTACK_SENTINEL
load_state python-repaired.path PYTHON_REPAIRED_MARKER
load_state broken-version.tool BROKEN_VERSION_TOOL
load_state broken-version.mode BROKEN_VERSION_MODE fail
load_state nats-py.mode NATS_PY_MODE present
load_state boundary-env-leak.path BOUNDARY_ENV_LEAK_MARKER
load_state preflight-probe-pid.path PREFLIGHT_PROBE_PID
load_state post-launch-direct-pid.path POST_LAUNCH_DIRECT_PID
load_state systemctl-child-pid.path SYSTEMCTL_CHILD_PID
if [ -n "${DOCTOR_UNRELATED_SECRET:-}" ]; then
    : > "$BOUNDARY_ENV_LEAK_MARKER"
fi
printf '%q ' "$@" >> "${PYTHON_LOG:?}"
printf '\n' >> "${PYTHON_LOG:?}"
original_args=("$@")
if [ "${1:-}" = "-I" ] && [ "${2:-}" = "-S" ]; then
    shift 2
fi
if [ "${1:-}" = "--version" ]; then
    if { [ "$PYTHON3_MODE" = replace-after-bind ] \
        || [ "$PYTHON3_MODE" = rewrite-after-bind ]; } \
        && [ ! -e "$PYTHON_REPLACEMENT_MARKER" ]; then
        exec /usr/bin/python3 -I -S -c '
import os
import sys

source, marker, attack, mode = sys.argv[1:]
if mode == "replace-after-bind":
    os.rename(source, source + ".bound")
else:
    os.chmod(source, 0o755)
with open(source, "w", encoding="utf-8") as stream:
    stream.write(
        "#!/usr/bin/env bash\n"
        f": > {attack!r}\n"
        "exec /usr/bin/python3 \"$@\"\n"
    )
os.chmod(source, 0o755)
with open(marker, "w", encoding="ascii"):
    pass
print("Python 3.13.0")
' "$PYTHON3_FIXTURE_SOURCE" "$PYTHON_REPLACEMENT_MARKER" \
            "$PYTHON_ATTACK_SENTINEL" "$PYTHON3_MODE"
    fi
    if [ "$BROKEN_VERSION_TOOL" = "python3" ]; then
        if [ "$BROKEN_VERSION_MODE" = empty ]; then
            exit 0
        fi
        exit 64
    fi
    printf '%s\n' 'Python 3.13.0'
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'start_new_session=True'* ]]; then
    if [ "$PYTHON3_MODE" = interrupt-preflight \
        ] || [ "$PYTHON3_MODE" = interrupt-post-launch ]; then
        supervisor_source=$2
        shift 2
        exec /usr/bin/python3 -I -S -c '
import os
import pathlib
import signal
import subprocess
import sys
import time

source, mode, preflight_marker, direct_marker, escaped_marker, *arguments = sys.argv[1:]
if mode == "interrupt-preflight":
    real_fork = os.fork
    fork_calls = 0

    def interrupting_fork():
        global fork_calls
        result = real_fork()
        fork_calls += 1
        if fork_calls == 2 and result == 0:
            pathlib.Path(preflight_marker).write_text(
                str(os.getpid()), encoding="ascii"
            )
        if fork_calls == 1 and result > 0:
            deadline = time.monotonic() + 1.0
            while not os.path.exists(preflight_marker):
                if time.monotonic() >= deadline:
                    raise RuntimeError("preflight probe did not publish")
                time.sleep(0.005)
            os.kill(os.getpid(), signal.SIGTERM)
        return result

    os.fork = interrupting_fork
else:
    real_popen = subprocess.Popen

    def interrupting_popen(*popen_args, **popen_kwargs):
        process = real_popen(*popen_args, **popen_kwargs)
        pathlib.Path(direct_marker).write_text(
            str(process.pid), encoding="ascii"
        )
        deadline = time.monotonic() + 1.0
        while not os.path.exists(escaped_marker):
            if process.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("effect descendant did not publish")
            time.sleep(0.005)
        os.kill(os.getpid(), signal.SIGTERM)
        return process

    subprocess.Popen = interrupting_popen
sys.argv = ["-c", *arguments]
exec(compile(source, "<doctor-boundary>", "exec"))
' "$supervisor_source" "$PYTHON3_MODE" "$PREFLIGHT_PROBE_PID" \
            "$POST_LAUNCH_DIRECT_PID" "$SYSTEMCTL_CHILD_PID" "$@"
    fi
    if [ "$PYTHON3_MODE" = deny-proc-scan ]; then
        supervisor_source=$2
        shift 2
        exec /usr/bin/python3 -I -S -c '
import os
import sys

source, *arguments = sys.argv[1:]
real_scandir = os.scandir


def deny_proc(path):
    if path == "/proc" or isinstance(path, int):
        raise PermissionError("fixture denied /proc enumeration")
    return real_scandir(path)


os.scandir = deny_proc
sys.argv = ["-c", *arguments]
exec(compile(source, "<doctor-boundary>", "exec"))
' "$supervisor_source" "$@"
    fi
    exec /usr/bin/python3 "${original_args[@]}"
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'ipaddress.ip_address'* ]]; then
    if [ "$PYTHON3_MODE" = parser-broken-installable ] \
        && [ ! -e "$PYTHON_REPAIRED_MARKER" ]; then
        exit 64
    fi
    exec /usr/bin/python3 "${original_args[@]}"
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'os.lstat(path)'* ]]; then
    exec /usr/bin/python3 "${original_args[@]}"
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'PathFinder.find_spec'* ]]; then
    if [ "$NATS_PY_MODE" = missing ]; then
        exit 1
    fi
    printf '%s\n' '1.0.0'
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'import nats'* ]]; then
    exit 0
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'metadata.version'* ]]; then
    printf '%s\n' '1.0.0'
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'hi_agamemnon_health'* ]]; then
    exec /usr/bin/python3 "${original_args[@]}"
elif [ "${1:-}" = "-c" ]; then
    exec /usr/bin/python3 "${original_args[@]}"
fi
exit 0
SH

cat > "$FAKE_BIN/tailscale" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state tailscale-log.path TAILSCALE_LOG
load_state tailscale-status.mode TAILSCALE_STATUS_MODE ok
load_state tailscale-running.path TAILSCALE_RUNNING_MARKER
load_state process-output.path PROCESS_OUTPUT_MARKER
load_state process-child-pid.path PROCESS_CHILD_PID
load_state process-heartbeat.path PROCESS_HEARTBEAT_MARKER
load_state test-platform.name TEST_PLATFORM
printf '%s\n' "$*" >> "$TAILSCALE_LOG"
if [ "${1:-}" = "status" ]; then
    if [ "$TAILSCALE_STATUS_MODE" = repairable ] \
        && [ ! -e "$TAILSCALE_RUNNING_MARKER" ]; then
        exit 1
    fi
    if [ "${2:-}" = "--json" ]; then
        if [ "$TAILSCALE_STATUS_MODE" = flood ]; then
            /usr/bin/python3 -I -S - "${PROCESS_OUTPUT_MARKER:?}" <<'PY'
import os
from pathlib import Path
import sys

for _ in range(4):
    os.write(sys.stdout.fileno(), b"x" * 65536)
Path(sys.argv[1]).write_text("complete\n", encoding="utf-8")
PY
            exit $?
        fi
        if [ "$TAILSCALE_STATUS_MODE" = slow-tree ]; then
            if [ "$TEST_PLATFORM" = Linux ]; then
                PROCESS_CHILD_PID="$PROCESS_CHILD_PID" \
                PROCESS_HEARTBEAT_MARKER="$PROCESS_HEARTBEAT_MARKER" \
                bash -c 'trap "" TERM; printf "%s\n" "$$" > "${PROCESS_CHILD_PID:?}"; while :; do printf x >> "${PROCESS_HEARTBEAT_MARKER:?}"; sleep 0.05; done' \
                    >/dev/null 2>&1 &
            else
                trap '' TERM
                printf '%s\n' "$$" > "${PROCESS_CHILD_PID:?}"
                while :; do
                    printf x >> "${PROCESS_HEARTBEAT_MARKER:?}"
                    sleep 0.05
                done
            fi
            trap '' TERM
            sleep 6
            exit 64
        fi
        printf '%s\n' '{"Self":{"Online":true,"TailscaleIPs":["100.64.0.1"]},"Peer":{"nodekey:worker":{"Online":true,"TailscaleIPs":["192.0.2.10","2001:db8::1"]},"nodekey:control":{"Online":true,"TailscaleIPs":["2001:db8::2"]}}}'
    fi
    exit 0
fi
printf '%s\n' '1.80.0'
SH

cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state systemctl-log.path SYSTEMCTL_LOG
load_state podman-unit.mode PODMAN_UNIT_MODE present
load_state systemctl.mode SYSTEMCTL_MODE clean
load_state systemctl-child-pid.path SYSTEMCTL_CHILD_PID
load_state systemctl-heartbeat.path SYSTEMCTL_HEARTBEAT_MARKER
load_state systemctl-effect.path SYSTEMCTL_EFFECT_MARKER
load_state tailscale-running.path TAILSCALE_RUNNING_MARKER
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "cat" ] \
    && [ "$PODMAN_UNIT_MODE" = missing ]; then
    exit 1
fi
spawn_systemctl_descendant() {
    /usr/bin/python3 -I -S - \
        "${SYSTEMCTL_CHILD_PID:?}" \
        "${SYSTEMCTL_HEARTBEAT_MARKER:?}" \
        <<'PY' >/dev/null 2>&1 &
import os
import signal
import sys
import time

if os.fork() != 0:
    raise SystemExit(0)
os.setsid()
if os.fork() != 0:
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
while True:
    with open(sys.argv[2], "a", encoding="ascii") as stream:
        stream.write("x")
    time.sleep(0.05)
PY
}
case "$SYSTEMCTL_MODE:$*" in
    effect-observe:'--user cat podman.socket')
        : > "${SYSTEMCTL_EFFECT_MARKER:?}"
        ;;
    repair-hang:'start tailscaled' \
        | cat-hang:'--user cat podman.socket' \
        | enable-hang:'--user enable --now podman.socket')
        spawn_systemctl_descendant
        sleep 8 || exit 70
        : > "${SYSTEMCTL_EFFECT_MARKER:?}"
        ;;
    success-escape:'start tailscaled' \
        | enable-success-escape:'--user enable --now podman.socket')
        spawn_systemctl_descendant
        ;;
esac
if [ "$*" = "start tailscaled" ]; then
    : > "$TAILSCALE_RUNNING_MARKER"
    exit 0
fi
if [ "${1:-}" = "is-active" ]; then
    exit 1
fi
exit 0
SH

cat > "$FAKE_BIN/sudo" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state sudo.mode SUDO_MODE clean
load_state sudo-child-pid.path SUDO_CHILD_PID
load_state sudo-heartbeat.path SUDO_HEARTBEAT_MARKER
load_state sudo-effect.path SUDO_EFFECT_MARKER
if [ "$SUDO_MODE" = repair-hang ]; then
    /usr/bin/python3 -I -S - "$SUDO_CHILD_PID" \
        "$SUDO_HEARTBEAT_MARKER" <<'PY' >/dev/null 2>&1 &
import os
import signal
import sys
import time

if os.fork() != 0:
    raise SystemExit(0)
os.setsid()
if os.fork() != 0:
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
while True:
    with open(sys.argv[2], "a", encoding="ascii") as stream:
        stream.write("x")
    time.sleep(0.05)
PY
    sleep 8 || exit 70
    : > "$SUDO_EFFECT_MARKER"
fi
while [ "${1:-}" = -n ] || [ "${1:-}" = -- ]; do
    shift
done
exec "$@"
SH

cat > "$FAKE_BIN/rm" <<'SH'
#!/usr/bin/env bash
source "$HOME/.doctor-state-helper.sh"
load_state rm.mode RM_MODE clean
load_state rm-child-pid.path RM_CHILD_PID
load_state rm-heartbeat.path RM_HEARTBEAT_MARKER
load_state rm-effect.path RM_EFFECT_MARKER
if [ "$RM_MODE" = repair-hang ] && [[ "$*" == *aardvark.pid* ]]; then
    /usr/bin/python3 -I -S - "$RM_CHILD_PID" \
        "$RM_HEARTBEAT_MARKER" <<'PY' >/dev/null 2>&1 &
import os
import signal
import sys
import time

if os.fork() != 0:
    raise SystemExit(0)
os.setsid()
if os.fork() != 0:
    raise SystemExit(0)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(f"{os.getpid()}\n")
while True:
    with open(sys.argv[2], "a", encoding="ascii") as stream:
        stream.write("x")
    time.sleep(0.05)
PY
    sleep 8 || exit 70
    : > "$RM_EFFECT_MARKER"
    exit 0
fi
exec /bin/rm "$@"
SH

chmod +x "$FAKE_BIN"/*
chmod a-w "$FAKE_BIN"/*

prepare_pythonless_path() {
    local executable command_name
    rm -rf "$PYTHONLESS_BIN"
    mkdir -p "$PYTHONLESS_BIN"

    for executable in /usr/bin/* /bin/*; do
        [ -f "$executable" ] && [ -x "$executable" ] || continue
        command_name=${executable##*/}
        case "$command_name" in
            python*) continue ;;
            git|just|pip3|jq)
                [ "${MISSING_CORE_TOOLS:-false}" = true ] && continue
                ;;
        esac
        if [ ! -e "$PYTHONLESS_BIN/$command_name" ]; then
            ln -s "$executable" "$PYTHONLESS_BIN/$command_name"
        fi
    done

    for executable in "$FAKE_BIN"/*; do
        command_name=${executable##*/}
        [ "$command_name" = python3 ] && continue
        case "$command_name" in
            git|just|pip3|jq)
                [ "${MISSING_CORE_TOOLS:-false}" = true ] && continue
                ;;
        esac
        ln -sf "$executable" "$PYTHONLESS_BIN/$command_name"
    done
}

run_doctor() {
    local -a doctor_args=()
    local doctor_bin="$FAKE_BIN"
    local doctor_path="$FAKE_BIN:/usr/bin:/bin"
    local doctor_cwd="${DOCTOR_CWD:-$TMP}"
    if [ "$#" -gt 0 ]; then
        doctor_args=("$@")
    fi
    case "${PYTHON3_MODE:-present}" in
        missing|installable)
            prepare_pythonless_path
            doctor_bin="$PYTHONLESS_BIN"
            doctor_path="$PYTHONLESS_BIN"
            ;;
    esac
    if [ -n "${DOCTOR_PATH_OVERRIDE:-}" ]; then
        doctor_path=$DOCTOR_PATH_OVERRIDE
    fi
    printf '%s\n' "${GIT_SUBMODULE_MODE:-ok}" > "$TMP/git-submodule.mode"
    printf '%s\n' "${GIT_SECURITY_MODE:-clean}" > "$TMP/git-security.mode"
    printf '%s\n' "${ASSERT_CLEAN_GIT_ENV:-false}" \
        > "$TMP/assert-clean-git-env"
    printf '%s\n' "${ASSERT_SAFE_GIT_UPDATE:-false}" \
        > "$TMP/assert-safe-git-update"
    printf '%s\n' "${BROKEN_VERSION_TOOL:-}" > "$TMP/broken-version.tool"
    printf '%s\n' "${BROKEN_VERSION_MODE:-fail}" > "$TMP/broken-version.mode"
    printf '%s\n' "${BROKEN_VERSION_TOOL:-}" \
        > "$TEST_STATE_DIR/broken-version.tool"
    printf '%s\n' "${BROKEN_VERSION_MODE:-fail}" \
        > "$TEST_STATE_DIR/broken-version.mode"
    printf '%s\n' "${GREP_SCAN_MODE:-ok}" > "$TEST_STATE_DIR/grep-scan.mode"
    printf '%s\n' "$PACKAGE_INSTALL_LOG" \
        > "$TEST_STATE_DIR/package-install-log.path"
    printf '%s\n' "$PROCESS_OUTPUT_MARKER" \
        > "$TEST_STATE_DIR/process-output.path"
    printf '%s\n' "$PROCESS_CHILD_PID" \
        > "$TEST_STATE_DIR/process-child-pid.path"
    printf '%s\n' "$PROCESS_HEARTBEAT_MARKER" \
        > "$TEST_STATE_DIR/process-heartbeat.path"
    printf '%s\n' "$CURL_LOG" > "$TEST_STATE_DIR/curl-log.path"
    printf '%s\n' "${CURL_HEALTH_MODE:-valid}" \
        > "$TEST_STATE_DIR/curl-health.mode"
    printf '%s\n' "$CURL_BODY_COMPLETE_MARKER" \
        > "$TEST_STATE_DIR/curl-body-complete.path"
    printf '%s\n' "${CURL_BIND_MODE:-clean}" \
        > "$TEST_STATE_DIR/curl-bind.mode"
    printf '%s\n' "$FAKE_BIN/curl" > "$TEST_STATE_DIR/curl-source.path"
    printf '%s\n' "$CURL_REPLACEMENT_MARKER" \
        > "$TEST_STATE_DIR/curl-replacement.path"
    printf '%s\n' "$CURL_ATTACK_SENTINEL" \
        > "$TEST_STATE_DIR/curl-attack.path"
    printf '%s\n' "$CURL_ENV_LEAK_MARKER" \
        > "$TEST_STATE_DIR/curl-env-leak.path"
    printf '%s\n' "$CURL_ENV_LOG" > "$TEST_STATE_DIR/curl-env-log.path"
    printf '%s\n' "$CURL_FD_LOG" > "$TEST_STATE_DIR/curl-fd-log.path"
    printf '%s\n' "$PING_LOG" > "$TEST_STATE_DIR/ping-log.path"
    printf '%s\n' "${CONAN_MODE:-clean}" > "$TEST_STATE_DIR/conan.mode"
    printf '%s\n' "$CONAN_CHILD_PID" \
        > "$TEST_STATE_DIR/conan-child-pid.path"
    printf '%s\n' "$CONAN_HEARTBEAT_MARKER" \
        > "$TEST_STATE_DIR/conan-heartbeat.path"
    printf '%s\n' "$CONAN_EFFECT_MARKER" \
        > "$TEST_STATE_DIR/conan-effect.path"
    printf '%s\n' "$CONAN_PROFILE_MARKER" \
        > "$TEST_STATE_DIR/conan-profile.path"
    printf '%s\n' "${DPKG_MODE:-ii}" > "$TEST_STATE_DIR/dpkg.mode"
    printf '%s\n' "${DPKG_POST_INSTALL_MODE:-ii}" \
        > "$TEST_STATE_DIR/dpkg-post-install.mode"
    printf '%s\n' "$LIBSSL_INSTALL_MARKER" \
        > "$TEST_STATE_DIR/libssl-install.path"
    printf '%s\n' "$APT_LOG" > "$TEST_STATE_DIR/apt-log.path"
    printf '%s\n' "${APT_INSTALL_STATUS:-0}" \
        > "$TEST_STATE_DIR/apt-install.status"
    printf '%s\n' "${PYTHON3_MODE:-present}" \
        > "$TEST_STATE_DIR/python3.mode"
    printf '%s\n' "$FAKE_BIN/python3" \
        > "$TEST_STATE_DIR/python3-source.path"
    printf '%s\n' "$doctor_bin" > "$TEST_STATE_DIR/doctor-active-bin.path"
    printf '%s\n' "$PYTHON_REPAIRED_MARKER" \
        > "$TEST_STATE_DIR/python-repaired.path"
    printf '%s\n' "$PYTHON_LOG" > "$TEST_STATE_DIR/python-log.path"
    printf '%s\n' "$PYTHON_REPLACEMENT_MARKER" \
        > "$TEST_STATE_DIR/python-replacement.path"
    printf '%s\n' "$PYTHON_ATTACK_SENTINEL" \
        > "$TEST_STATE_DIR/python-attack.path"
    printf '%s\n' "${NATS_PY_MODE:-present}" \
        > "$TEST_STATE_DIR/nats-py.mode"
    printf '%s\n' "$BOUNDARY_ENV_LEAK_MARKER" \
        > "$TEST_STATE_DIR/boundary-env-leak.path"
    printf '%s\n' "$TAILSCALE_LOG" > "$TEST_STATE_DIR/tailscale-log.path"
    printf '%s\n' "${TAILSCALE_STATUS_MODE:-ok}" \
        > "$TEST_STATE_DIR/tailscale-status.mode"
    printf '%s\n' "$TAILSCALE_RUNNING_MARKER" \
        > "$TEST_STATE_DIR/tailscale-running.path"
    printf '%s\n' "$TEST_PLATFORM" > "$TEST_STATE_DIR/test-platform.name"
    printf '%s\n' "$SYSTEMCTL_LOG" > "$TEST_STATE_DIR/systemctl-log.path"
    printf '%s\n' "${PODMAN_UNIT_MODE:-present}" \
        > "$TEST_STATE_DIR/podman-unit.mode"
    printf '%s\n' "${SYSTEMCTL_MODE:-clean}" \
        > "$TEST_STATE_DIR/systemctl.mode"
    printf '%s\n' "$SYSTEMCTL_CHILD_PID" \
        > "$TEST_STATE_DIR/systemctl-child-pid.path"
    printf '%s\n' "$SYSTEMCTL_HEARTBEAT_MARKER" \
        > "$TEST_STATE_DIR/systemctl-heartbeat.path"
    printf '%s\n' "$SYSTEMCTL_EFFECT_MARKER" \
        > "$TEST_STATE_DIR/systemctl-effect.path"
    printf '%s\n' "$PREFLIGHT_PROBE_PID" \
        > "$TEST_STATE_DIR/preflight-probe-pid.path"
    printf '%s\n' "$POST_LAUNCH_DIRECT_PID" \
        > "$TEST_STATE_DIR/post-launch-direct-pid.path"
    printf '%s\n' "${SUDO_MODE:-clean}" > "$TEST_STATE_DIR/sudo.mode"
    printf '%s\n' "$SUDO_CHILD_PID" > "$TEST_STATE_DIR/sudo-child-pid.path"
    printf '%s\n' "$SUDO_HEARTBEAT_MARKER" \
        > "$TEST_STATE_DIR/sudo-heartbeat.path"
    printf '%s\n' "$SUDO_EFFECT_MARKER" > "$TEST_STATE_DIR/sudo-effect.path"
    printf '%s\n' "${RM_MODE:-clean}" > "$TEST_STATE_DIR/rm.mode"
    printf '%s\n' "$RM_CHILD_PID" > "$TEST_STATE_DIR/rm-child-pid.path"
    printf '%s\n' "$RM_HEARTBEAT_MARKER" \
        > "$TEST_STATE_DIR/rm-heartbeat.path"
    printf '%s\n' "$RM_EFFECT_MARKER" > "$TEST_STATE_DIR/rm-effect.path"
    : > "$GIT_LOG"
    : > "$PYTHON_LOG"
    : > "$TAILSCALE_LOG"
    : > "$SYSTEMCTL_LOG"
    : > "$PING_LOG"
    : > "$CURL_LOG"
    : > "$CURL_LOG.first-options"
    : > "$CURL_ENV_LOG"
    : > "$CURL_FD_LOG"
    : > "$APT_LOG"
    : > "$PACKAGE_INSTALL_LOG"
    rm -f "$TAILSCALE_RUNNING_MARKER"
    rm -f "$GIT_STATUS_READ_MARKER"
    rm -f "$LIBSSL_INSTALL_MARKER"
    rm -f "$PYTHON_REPAIRED_MARKER"
    rm -f "$PROCESS_OUTPUT_MARKER"
    rm -f "$PROCESS_CHILD_PID"
    rm -f "$PROCESS_HEARTBEAT_MARKER"
    rm -f "$GIT_UPDATE_EFFECT_MARKER"
    rm -f "$GIT_UPDATE_CHILD_PID"
    rm -f "$GIT_UPDATE_HEARTBEAT_MARKER"
    rm -f "$GIT_ATTACK_SENTINEL"
    rm -f "$PYTHON_ATTACK_SENTINEL"
    rm -f "$BOUNDARY_ENV_LEAK_MARKER"
    rm -f "$PYTHON_REPLACEMENT_MARKER"
    rm -f "$SYSTEMCTL_CHILD_PID"
    rm -f "$SYSTEMCTL_HEARTBEAT_MARKER"
    rm -f "$SYSTEMCTL_EFFECT_MARKER"
    rm -f "$PREFLIGHT_PROBE_PID"
    rm -f "$POST_LAUNCH_DIRECT_PID"
    rm -f "$CONAN_CHILD_PID"
    rm -f "$CONAN_HEARTBEAT_MARKER"
    rm -f "$CONAN_EFFECT_MARKER"
    rm -f "$CONAN_PROFILE_MARKER"
    rm -f "$SUDO_CHILD_PID"
    rm -f "$SUDO_HEARTBEAT_MARKER"
    rm -f "$SUDO_EFFECT_MARKER"
    rm -f "$RM_CHILD_PID"
    rm -f "$RM_HEARTBEAT_MARKER"
    rm -f "$RM_EFFECT_MARKER"
    rm -f "$CURL_BODY_COMPLETE_MARKER"
    rm -f "$CURL_REPLACEMENT_MARKER"
    rm -f "$CURL_ATTACK_SENTINEL"
    rm -f "$CURL_ENV_LEAK_MARKER"
    set +e
    DOCTOR_OUTPUT="$(
        cd "$doctor_cwd" || exit 96
        GIT_LOG="$GIT_LOG" \
        PYTHON_LOG="$PYTHON_LOG" \
        TAILSCALE_LOG="$TAILSCALE_LOG" \
        SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        BOUNDARY_ENV_LEAK_MARKER="$BOUNDARY_ENV_LEAK_MARKER" \
        PYTHON_REPLACEMENT_MARKER="$PYTHON_REPLACEMENT_MARKER" \
        SYSTEMCTL_CHILD_PID="$SYSTEMCTL_CHILD_PID" \
        SYSTEMCTL_HEARTBEAT_MARKER="$SYSTEMCTL_HEARTBEAT_MARKER" \
        SYSTEMCTL_EFFECT_MARKER="$SYSTEMCTL_EFFECT_MARKER" \
        CONAN_CHILD_PID="$CONAN_CHILD_PID" \
        CONAN_HEARTBEAT_MARKER="$CONAN_HEARTBEAT_MARKER" \
        CONAN_EFFECT_MARKER="$CONAN_EFFECT_MARKER" \
        PING_LOG="$PING_LOG" \
        CURL_LOG="$CURL_LOG" \
        CURL_BODY_COMPLETE_MARKER="$CURL_BODY_COMPLETE_MARKER" \
        APT_LOG="$APT_LOG" \
        PACKAGE_INSTALL_LOG="$PACKAGE_INSTALL_LOG" \
        TAILSCALE_RUNNING_MARKER="$TAILSCALE_RUNNING_MARKER" \
        GIT_STATUS_READ_MARKER="$GIT_STATUS_READ_MARKER" \
        LIBSSL_INSTALL_MARKER="$LIBSSL_INSTALL_MARKER" \
        PYTHON_REPAIRED_MARKER="$PYTHON_REPAIRED_MARKER" \
        PROCESS_OUTPUT_MARKER="$PROCESS_OUTPUT_MARKER" \
        PROCESS_CHILD_PID="$PROCESS_CHILD_PID" \
        PROCESS_HEARTBEAT_MARKER="$PROCESS_HEARTBEAT_MARKER" \
        GIT_UPDATE_EFFECT_MARKER="$GIT_UPDATE_EFFECT_MARKER" \
        GIT_UPDATE_CHILD_PID="$GIT_UPDATE_CHILD_PID" \
        GIT_UPDATE_HEARTBEAT_MARKER="$GIT_UPDATE_HEARTBEAT_MARKER" \
        GIT_ATTACK_SENTINEL="$GIT_ATTACK_SENTINEL" \
        PYTHON_ATTACK_SENTINEL="$PYTHON_ATTACK_SENTINEL" \
        TAILSCALE_STATUS_MODE="${TAILSCALE_STATUS_MODE:-ok}" \
        CURL_HEALTH_MODE="${CURL_HEALTH_MODE:-valid}" \
        GIT_SUBMODULE_MODE="${GIT_SUBMODULE_MODE:-ok}" \
        GREP_SCAN_MODE="${GREP_SCAN_MODE:-ok}" \
        BROKEN_VERSION_TOOL="${BROKEN_VERSION_TOOL:-}" \
        BROKEN_VERSION_MODE="${BROKEN_VERSION_MODE:-fail}" \
        PODMAN_UNIT_MODE="${PODMAN_UNIT_MODE:-present}" \
        DPKG_MODE="${DPKG_MODE:-ii}" \
        DPKG_POST_INSTALL_MODE="${DPKG_POST_INSTALL_MODE:-ii}" \
        APT_INSTALL_STATUS="${APT_INSTALL_STATUS:-0}" \
        ASSERT_CLEAN_GIT_ENV="${ASSERT_CLEAN_GIT_ENV:-false}" \
        ASSERT_SAFE_GIT_UPDATE="${ASSERT_SAFE_GIT_UPDATE:-false}" \
        GIT_SECURITY_MODE="${GIT_SECURITY_MODE:-clean}" \
        SYSTEMCTL_MODE="${SYSTEMCTL_MODE:-clean}" \
        CONAN_MODE="${CONAN_MODE:-clean}" \
        DOCTOR_UNRELATED_SECRET="${DOCTOR_UNRELATED_SECRET:-}" \
        ODYSSEUS_DOCTOR_SUBMODULE_UPDATE_TIMEOUT_SECONDS="${ODYSSEUS_DOCTOR_SUBMODULE_UPDATE_TIMEOUT_SECONDS:-1}" \
        GIT_DIR="${DOCTOR_GIT_DIR:-}" \
        GIT_WORK_TREE="${DOCTOR_GIT_WORK_TREE:-}" \
        GIT_COMMON_DIR="${DOCTOR_GIT_COMMON_DIR:-}" \
        GIT_CONFIG="${DOCTOR_GIT_CONFIG:-}" \
        GIT_CONFIG_GLOBAL="${DOCTOR_GIT_CONFIG_GLOBAL:-}" \
        GIT_CONFIG_SYSTEM="${DOCTOR_GIT_CONFIG_SYSTEM:-}" \
        GIT_CONFIG_NOSYSTEM="${DOCTOR_GIT_CONFIG_NOSYSTEM:-0}" \
        GIT_CONFIG_COUNT="${DOCTOR_GIT_CONFIG_COUNT:-0}" \
        GIT_CONFIG_KEY_0="${DOCTOR_GIT_CONFIG_KEY_0:-}" \
        GIT_CONFIG_VALUE_0="${DOCTOR_GIT_CONFIG_VALUE_0:-}" \
        GIT_CONFIG_PARAMETERS="${DOCTOR_GIT_CONFIG_PARAMETERS:-}" \
        GIT_SSH="${DOCTOR_GIT_SSH:-}" \
        GIT_SSH_COMMAND="${DOCTOR_GIT_SSH_COMMAND:-}" \
        GIT_ALLOW_PROTOCOL="${DOCTOR_GIT_ALLOW_PROTOCOL:-}" \
        PYTHONPATH="${DOCTOR_PYTHONPATH:-}" \
        PYTHONHOME="${DOCTOR_PYTHONHOME:-}" \
        PYTHON3_MODE="${PYTHON3_MODE:-present}" \
        PYTHON3_FIXTURE_SOURCE="$FAKE_BIN/python3" \
        DOCTOR_ACTIVE_BIN="$doctor_bin" \
        HOME="$DOCTOR_HOME" \
        XDG_RUNTIME_DIR="$DOCTOR_RUNTIME_DIR" \
        PATH="$doctor_path" \
            bash "$FIXTURE_ROOT/e2e/doctor.sh" --role "${DOCTOR_ROLE:-control}" \
                ${doctor_args[@]+"${doctor_args[@]}"} 2>&1
    )"
    DOCTOR_STATUS=$?
    set -e
}

process_is_gone() {
    local process_id=$1 heartbeat_marker=${2:-$PROCESS_HEARTBEAT_MARKER}
    local attempt=0
    local before_size after_size
    while [ "$attempt" -lt 40 ]; do
        attempt=$((attempt + 1))
        if ! kill -0 "$process_id" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    if [ -e "$heartbeat_marker" ]; then
        before_size=$(wc -c < "$heartbeat_marker")
        sleep 0.2
        after_size=$(wc -c < "$heartbeat_marker")
        [ "$before_size" -eq "$after_size" ] && return 0
    fi
    return 1
}

info "an unchanged heartbeat cannot prove process extinction"
oracle_heartbeat="$TMP/extinction-oracle.heartbeat"
printf '%s\n' unchanged > "$oracle_heartbeat"
/bin/sleep 30 &
oracle_child=$!
oracle_reported_gone=false
if process_is_gone "$oracle_child" "$oracle_heartbeat"; then
    oracle_reported_gone=true
fi
oracle_child_alive=false
if kill -0 "$oracle_child" 2>/dev/null; then
    oracle_child_alive=true
    kill -TERM "$oracle_child"
fi
if ! wait "$oracle_child" 2>/dev/null; then :; fi
if [ "$oracle_child_alive" = true ] && [ "$oracle_reported_gone" = false ]; then
    pass "a live child remains live evidence despite an unchanged heartbeat"
else
    fail "extinction oracle accepted stalled progress or lacked a live control child"
fi
unset oracle_heartbeat oracle_child oracle_reported_gone oracle_child_alive

info "install help limits doctor to safe local-state repairs"
run_doctor --help
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && grep -q -- '--install applies safe local-state repairs' \
        <<<"$DOCTOR_OUTPUT" \
    && grep -q 'pre-provision verified packages and executables separately' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$PACKAGE_INSTALL_LOG" ]; then
    pass "help separates safe repair mode from verified package provisioning"
else
    fail "help still presents install mode as a package installer"
fi

info "Python checks ignore cwd, PYTHONPATH, and site initialization"
HOSTILE_PYTHON="$TMP/hostile-python"
mkdir -p "$HOSTILE_PYTHON"
for module_name in sitecustomize ipaddress json nats; do
    cat > "$HOSTILE_PYTHON/$module_name.py" <<'PY'
import os
from pathlib import Path

Path(os.environ["PYTHON_ATTACK_SENTINEL"]).write_text(
    "ambient module imported\n", encoding="utf-8"
)
raise RuntimeError("ambient module must not load")
PY
done
DOCTOR_CWD="$HOSTILE_PYTHON" \
DOCTOR_PYTHONPATH="$HOSTILE_PYTHON" \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --check-services --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && [ ! -e "$PYTHON_ATTACK_SENTINEL" ] \
    && [ -s "$PYTHON_LOG" ] \
    && ! awk '$0 !~ /^-I -S / { found=1 } END { exit found ? 0 : 1 }' \
        "$PYTHON_LOG"; then
    pass "all Python checks use one isolated interpreter boundary"
else
    fail "an ambient Python module loaded or a check omitted -I -S"
fi
unset DOCTOR_CWD DOCTOR_PYTHONPATH

info "Python execution stays bound after its discovered path is replaced"
PYTHON3_MODE=replace-after-bind \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
python_replacement_observed=false
[ -e "$PYTHON_REPLACEMENT_MARKER" ] && python_replacement_observed=true
python_replacement_executed=false
[ -e "$PYTHON_ATTACK_SENTINEL" ] && python_replacement_executed=true
if [ -e "$FAKE_BIN/python3.bound" ]; then
    rm -f "$FAKE_BIN/python3"
    mv "$FAKE_BIN/python3.bound" "$FAKE_BIN/python3"
fi
if [ "$python_replacement_observed" = true ] \
    && [ "$python_replacement_executed" = false ]; then
    pass "Python path replacement cannot change the bound interpreter"
else
    fail "doctor reopened a replaced Python executable path"
fi
unset PYTHON3_MODE python_replacement_observed python_replacement_executed

info "Python execution stays bound after its source bytes are rewritten"
cp "$FAKE_BIN/python3" "$FAKE_BIN/python3.pristine"
chmod a-w "$FAKE_BIN/python3.pristine"
PYTHON3_MODE=rewrite-after-bind \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
python_rewrite_observed=false
[ -e "$PYTHON_REPLACEMENT_MARKER" ] && python_rewrite_observed=true
python_rewrite_executed=false
[ -e "$PYTHON_ATTACK_SENTINEL" ] && python_rewrite_executed=true
rm -f "$FAKE_BIN/python3"
mv "$FAKE_BIN/python3.pristine" "$FAKE_BIN/python3"
if [ "$python_rewrite_observed" = true ] \
    && [ "$python_rewrite_executed" = false ]; then
    pass "Python in-place rewrite cannot change the bound interpreter"
else
    fail "doctor executed rewritten Python source bytes"
fi
unset PYTHON3_MODE python_rewrite_observed python_rewrite_executed

info "service health uses one sealed curl snapshot with no startup injection"
CURL_BIND_MODE=replace-after-version \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --worker-ip 192.0.2.10 --check-services
curl_replacement_observed=false
[ -e "$CURL_REPLACEMENT_MARKER" ] && curl_replacement_observed=true
curl_replacement_executed=false
[ -e "$CURL_ATTACK_SENTINEL" ] && curl_replacement_executed=true
curl_health_uses_q=false
if awk '
    { seen = 1; if ($0 != "-q") invalid = 1 }
    END { exit (!seen || invalid) ? 1 : 0 }
' "$CURL_LOG.first-options"; then
    curl_health_uses_q=true
fi
if [ -e "$FAKE_BIN/curl.bound" ]; then
    rm -f "$FAKE_BIN/curl"
    mv "$FAKE_BIN/curl.bound" "$FAKE_BIN/curl"
    chmod a-w "$FAKE_BIN/curl"
fi
curl_binding_proved=true
if [ "$TEST_PLATFORM" = Linux ] \
    && [ "$curl_replacement_observed" != true ]; then
    curl_binding_proved=false
fi
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && [ "$curl_binding_proved" = true ] \
    && [ "$curl_replacement_executed" = false ] \
    && [ "$curl_health_uses_q" = true ] \
    && grep -Eq 'PATH=.*/usr/bin:/bin' "$CURL_ENV_LOG" \
    && ! grep -Eq '(HOME|USER|LOGNAME|TMPDIR|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|DOCTOR_UNRELATED_SECRET|http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|ALL_PROXY)=' \
        "$CURL_ENV_LOG" \
    && ! grep -Eq '^(9|10|11|12|190|191|192|193|194|195|196|197|205)$' \
        "$CURL_FD_LOG"; then
    pass "every curl invocation is sealed, first-option -q, minimal-env, and descriptor-clean"
else
    curl_path_valid=false
    if grep -Eq 'PATH=.*/usr/bin:/bin' "$CURL_ENV_LOG"; then
        curl_path_valid=true
    fi
    curl_environment_clean=true
    if grep -Eq '(HOME|USER|LOGNAME|TMPDIR|XDG_RUNTIME_DIR|DBUS_SESSION_BUS_ADDRESS|DOCTOR_UNRELATED_SECRET|http_proxy|HTTP_PROXY|https_proxy|HTTPS_PROXY|ALL_PROXY)=' "$CURL_ENV_LOG"; then
        curl_environment_clean=false
    fi
    curl_descriptors_clean=true
    if grep -Eq '^(9|10|11|12|190|191|192|193|194|195|196|197|205)$' "$CURL_FD_LOG"; then
        curl_descriptors_clean=false
    fi
    printf 'curl boundary diagnostics: path=%s environment=%s descriptors=%s\n' \
        "$curl_path_valid" "$curl_environment_clean" "$curl_descriptors_clean" >&2
    printf 'curl fixture descriptor observations: %s\n' \
        "$(tr '\n' ';' < "$CURL_FD_LOG")" >&2
    fail "curl transport violated binding, -q, environment, or FD policy (status=$DOCTOR_STATUS replacement=$curl_replacement_observed attack=$curl_replacement_executed q=$curl_health_uses_q log=$(tr '\n' ';' < "$CURL_LOG"))"
fi
unset CURL_BIND_MODE curl_replacement_observed curl_replacement_executed \
    curl_health_uses_q curl_binding_proved

info "service health curl receives only the bounded environment"
DOCTOR_UNRELATED_SECRET='must-not-cross-curl-boundary' \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --worker-ip 192.0.2.10 --check-services
if [ "$DOCTOR_STATUS" -eq 0 ] && [ ! -e "$CURL_ENV_LEAK_MARKER" ]; then
    pass "unrelated caller environment does not reach health transport"
else
    fail "service health curl inherited unrelated caller environment"
fi
unset DOCTOR_UNRELATED_SECRET

info "bounded commands use an allowlisted environment"
DOCTOR_UNRELATED_SECRET='must-not-cross-command-boundary' \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && [ ! -e "$BOUNDARY_ENV_LEAK_MARKER" ]; then
    pass "unrelated caller environment does not reach Git commands"
else
    fail "an unrelated caller environment value crossed the Git boundary"
fi
unset DOCTOR_UNRELATED_SECRET

info "version probes enforce output and wall-time bounds"
BROKEN_VERSION_TOOL=just BROKEN_VERSION_MODE=flood \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -e "$PROCESS_OUTPUT_MARKER" ] \
    && grep -q 'just — version readback failed' <<<"$DOCTOR_OUTPUT"; then
    pass "version output flood stops before the producer completes"
else
    fail "version output flood completed or became a passing version"
fi

version_started=$(date +%s)
BROKEN_VERSION_TOOL=just BROKEN_VERSION_MODE=slow-tree \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
version_elapsed=$(($(date +%s) - version_started))
version_descendant=""
[ -s "$PROCESS_CHILD_PID" ] \
    && version_descendant=$(cat "$PROCESS_CHILD_PID")
version_descendant_gone=false
if [ -n "$version_descendant" ] \
    && process_is_gone "$version_descendant"; then
    version_descendant_gone=true
fi
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ "$version_elapsed" -le 15 ] \
    && [ -n "$version_descendant" ] \
    && [ "$version_descendant_gone" = true ]; then
    pass "version timeout extinguishes a TERM-resistant descendant"
else
    if [ -n "$version_descendant" ] \
        && kill -0 "$version_descendant" 2>/dev/null; then
        kill -KILL "$version_descendant" 2>/dev/null
    fi
    fail "version timeout was absent or left a descendant alive (status=$DOCTOR_STATUS elapsed=${version_elapsed}s pid=${version_descendant:-absent} gone=$version_descendant_gone)"
fi
unset BROKEN_VERSION_TOOL BROKEN_VERSION_MODE version_descendant_gone

if [ "$(uname -s)" = Linux ]; then
    BROKEN_VERSION_TOOL=just BROKEN_VERSION_MODE=success-escape \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
    version_descendant=""
    [ -s "$PROCESS_CHILD_PID" ] \
        && version_descendant=$(cat "$PROCESS_CHILD_PID")
    version_descendant_gone=false
    if [ -n "$version_descendant" ] \
        && process_is_gone "$version_descendant"; then
        version_descendant_gone=true
    fi
    if [ "$DOCTOR_STATUS" -eq 0 ] \
        && [ -n "$version_descendant" ] \
        && [ "$version_descendant_gone" = true ]; then
        pass "successful version probes extinguish escaped descendants"
    else
        if [ -n "$version_descendant" ] \
            && kill -0 "$version_descendant" 2>/dev/null; then
            kill -KILL "$version_descendant" 2>/dev/null
        fi
        fail "successful version probe did not prove descendant cleanup (status=$DOCTOR_STATUS pid=${version_descendant:-absent} gone=$version_descendant_gone)"
    fi
    unset BROKEN_VERSION_TOOL BROKEN_VERSION_MODE version_descendant_gone
else
    BROKEN_VERSION_TOOL=just BROKEN_VERSION_MODE=success-escape \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
    if [ ! -s "$PROCESS_CHILD_PID" ] \
        && { [ "$DOCTOR_STATUS" -eq 0 ] \
            || grep -q 'just — version readback failed' \
                <<<"$DOCTOR_OUTPUT"; }; then
        pass "non-Linux read probes prevent descendants or degrade safely"
    else
        fail "non-Linux read probe created an unprovable descendant"
    fi
    unset BROKEN_VERSION_TOOL BROKEN_VERSION_MODE
fi

info "Tailscale inventory enforces output and wall-time bounds"
TAILSCALE_STATUS_MODE=flood GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -e "$PROCESS_OUTPUT_MARKER" ] \
    && grep -q 'tailscaled not running' <<<"$DOCTOR_OUTPUT"; then
    pass "Tailscale output flood stops before the producer completes"
else
    fail "Tailscale output flood completed or became topology evidence"
fi

tailscale_started=$(date +%s)
TAILSCALE_STATUS_MODE=slow-tree GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --worker-ip 192.0.2.10
tailscale_elapsed=$(($(date +%s) - tailscale_started))
tailscale_descendant=""
[ -s "$PROCESS_CHILD_PID" ] \
    && tailscale_descendant=$(cat "$PROCESS_CHILD_PID")
tailscale_descendant_gone=false
if [ -n "$tailscale_descendant" ] \
    && process_is_gone "$tailscale_descendant"; then
    tailscale_descendant_gone=true
fi
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ "$tailscale_elapsed" -le 15 ] \
    && [ -n "$tailscale_descendant" ] \
    && [ "$tailscale_descendant_gone" = true ]; then
    pass "Tailscale timeout extinguishes a TERM-resistant descendant"
else
    if [ -n "$tailscale_descendant" ] \
        && kill -0 "$tailscale_descendant" 2>/dev/null; then
        kill -KILL "$tailscale_descendant" 2>/dev/null
    fi
    fail "Tailscale timeout was absent or left a descendant alive (status=$DOCTOR_STATUS elapsed=${tailscale_elapsed}s pid=${tailscale_descendant:-absent} gone=$tailscale_descendant_gone)"
fi
unset TAILSCALE_STATUS_MODE tailscale_descendant_gone

info "present tools require successful, parseable version readback"
while IFS='|' read -r tool_name role expected_failure; do
    for failure_mode in fail empty; do
        BROKEN_VERSION_TOOL="$tool_name" \
        BROKEN_VERSION_MODE="$failure_mode" \
        DOCTOR_ROLE="$role" \
        GIT_SUBMODULE_MODE=ok \
        GREP_SCAN_MODE=nomatch \
            run_doctor
        if [ "$DOCTOR_STATUS" -ne 0 ] \
            && grep -qF "$expected_failure" <<<"$DOCTOR_OUTPUT"; then
            pass "$tool_name $failure_mode version output is not accepted"
        else
            fail "$tool_name $failure_mode version output became a passing check"
        fi
    done
done <<'EOF'
git|control|git — version readback failed
just|control|just — version readback failed
python3|control|python3 — version readback failed
pip3|control|pip3 — version readback failed
curl|control|curl — version readback failed
jq|control|jq — version readback failed
podman|worker|podman — version readback failed
podman-compose|worker|podman compose — version readback failed
ninja|control|ninja — version readback failed
make|control|make — version readback failed
pixi|control|pixi — version readback failed
EOF
unset BROKEN_VERSION_TOOL BROKEN_VERSION_MODE DOCTOR_ROLE

info "doctor does not synthesize missing packaged Podman units"
rm -rf "$DOCTOR_HOME/.config"
PODMAN_UNIT_MODE=missing \
DOCTOR_ROLE=worker \
GIT_SUBMODULE_MODE=ok \
GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -e "$DOCTOR_HOME/.config/systemd/user/podman.socket" ] \
    && grep -Eq 'packaged podman.socket unit is unavailable|podman socket — repair unavailable' \
        <<<"$DOCTOR_OUTPUT"; then
    pass "missing Podman units stop for an operator-owned package repair"
else
    fail "doctor copied or synthesized an unverified Podman unit"
fi
unset PODMAN_UNIT_MODE DOCTOR_ROLE

info "install-side systemctl repair is bounded and descendant-contained"
if [ "$TEST_PLATFORM" = Linux ]; then
    PYTHON3_MODE=deny-proc-scan SYSTEMCTL_MODE=effect-observe \
    DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ ! -e "$SYSTEMCTL_EFFECT_MARKER" ]; then
        pass "unavailable proc containment stops mutation before launch"
    else
        fail "a mutation launched before full-tree containment was available"
    fi
    unset PYTHON3_MODE SYSTEMCTL_MODE DOCTOR_ROLE
else
    pass "proc-containment launch proof is Linux-only"
fi

info "effect-boundary interruption covers preflight and post-launch ownership"
if [ "$TEST_PLATFORM" = Linux ]; then
    PYTHON3_MODE=interrupt-preflight SYSTEMCTL_MODE=effect-observe \
    DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install
    preflight_probe=""
    [ -s "$PREFLIGHT_PROBE_PID" ] \
        && preflight_probe=$(cat "$PREFLIGHT_PROBE_PID")
    preflight_gone=false
    if [ -n "$preflight_probe" ] \
        && process_is_gone "$preflight_probe"; then
        preflight_gone=true
    fi
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ -n "$preflight_probe" ] \
        && [ "$preflight_gone" = true ] \
        && [ ! -e "$SYSTEMCTL_EFFECT_MARKER" ]; then
        pass "preflight interruption cleans its complete probe family before effects"
    else
        if [ -n "$preflight_probe" ]; then
            if ! /bin/kill -KILL "$preflight_probe" 2>/dev/null; then :; fi
        fi
        fail "preflight interruption leaked a probe or launched an effect"
    fi

    PYTHON3_MODE=interrupt-post-launch SYSTEMCTL_MODE=cat-hang \
    DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install
    post_launch_direct=""
    post_launch_escaped=""
    [ -s "$POST_LAUNCH_DIRECT_PID" ] \
        && post_launch_direct=$(cat "$POST_LAUNCH_DIRECT_PID")
    [ -s "$SYSTEMCTL_CHILD_PID" ] \
        && post_launch_escaped=$(cat "$SYSTEMCTL_CHILD_PID")
    post_launch_direct_gone=false
    post_launch_escaped_gone=false
    if [ -n "$post_launch_direct" ] \
        && process_is_gone "$post_launch_direct"; then
        post_launch_direct_gone=true
    fi
    if [ -n "$post_launch_escaped" ] \
        && process_is_gone "$post_launch_escaped" \
            "$SYSTEMCTL_HEARTBEAT_MARKER"; then
        post_launch_escaped_gone=true
    fi
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ -n "$post_launch_direct" ] \
        && [ -n "$post_launch_escaped" ] \
        && [ "$post_launch_direct_gone" = true ] \
        && [ "$post_launch_escaped_gone" = true ] \
        && [ ! -e "$SYSTEMCTL_EFFECT_MARKER" ]; then
        pass "post-launch interruption extinguishes the assigned session and escapee"
    else
        if [ -n "$post_launch_direct" ]; then
            if ! /bin/kill -KILL "$post_launch_direct" 2>/dev/null; then :; fi
        fi
        if [ -n "$post_launch_escaped" ]; then
            if ! /bin/kill -KILL "$post_launch_escaped" 2>/dev/null; then :; fi
        fi
        fail "post-launch interruption leaked an assigned process tree"
    fi
    unset PYTHON3_MODE SYSTEMCTL_MODE DOCTOR_ROLE preflight_probe \
        preflight_gone post_launch_direct post_launch_escaped \
        post_launch_direct_gone post_launch_escaped_gone
else
    pass "effect-boundary interruption proof is Linux-only"
fi

systemctl_started=$(date +%s)
SYSTEMCTL_MODE=repair-hang \
TAILSCALE_STATUS_MODE=repairable \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --cross-host --capability-only
systemctl_elapsed=$(($(date +%s) - systemctl_started))
systemctl_descendant=""
[ -s "$SYSTEMCTL_CHILD_PID" ] \
    && systemctl_descendant=$(cat "$SYSTEMCTL_CHILD_PID")
systemctl_descendant_gone=true
if [ -n "$systemctl_descendant" ] \
    && ! process_is_gone "$systemctl_descendant" \
        "$SYSTEMCTL_HEARTBEAT_MARKER"; then
    systemctl_descendant_gone=false
fi
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ "$systemctl_elapsed" -le 20 ] \
    && [ ! -e "$SYSTEMCTL_EFFECT_MARKER" ] \
    && [ "$systemctl_descendant_gone" = true ]; then
    pass "systemctl repair obeys one deadline and leaves no descendant"
else
    if [ -n "$systemctl_descendant" ] \
        && kill -0 "$systemctl_descendant" 2>/dev/null; then
        kill -KILL "$systemctl_descendant" 2>/dev/null
    fi
    fail "systemctl repair escaped its bounded effect boundary (status=$DOCTOR_STATUS elapsed=${systemctl_elapsed}s)"
fi
unset SYSTEMCTL_MODE TAILSCALE_STATUS_MODE systemctl_descendant \
    systemctl_descendant_gone

info "Podman systemctl inspection and enable share the repair boundary"
for systemctl_mode in cat-hang enable-hang enable-success-escape; do
    systemctl_started=$(date +%s)
    SYSTEMCTL_MODE="$systemctl_mode" \
    DOCTOR_ROLE=worker \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install
    systemctl_elapsed=$(($(date +%s) - systemctl_started))
    systemctl_descendant=""
    [ -s "$SYSTEMCTL_CHILD_PID" ] \
        && systemctl_descendant=$(cat "$SYSTEMCTL_CHILD_PID")
    systemctl_descendant_gone=true
    if [ -n "$systemctl_descendant" ] \
        && ! process_is_gone "$systemctl_descendant" \
            "$SYSTEMCTL_HEARTBEAT_MARKER"; then
        systemctl_descendant_gone=false
    fi
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ "$systemctl_elapsed" -le 20 ] \
        && [ ! -e "$SYSTEMCTL_EFFECT_MARKER" ] \
        && [ "$systemctl_descendant_gone" = true ]; then
        pass "$systemctl_mode stays inside the Podman repair deadline"
    else
        if [ -n "$systemctl_descendant" ] \
            && kill -0 "$systemctl_descendant" 2>/dev/null; then
            kill -KILL "$systemctl_descendant" 2>/dev/null
        fi
        fail "$systemctl_mode escaped the Podman repair boundary"
    fi
done
unset SYSTEMCTL_MODE DOCTOR_ROLE systemctl_mode systemctl_descendant \
    systemctl_descendant_gone

info "aardvark PID metadata and live foreign identities fail closed"
mkdir -p "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns"
printf '%s\n' 'not-a-pid' \
    > "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
chmod 600 "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && ! grep -q 'aardvark-dns OK' <<<"$DOCTOR_OUTPUT"; then
    pass "malformed aardvark PID metadata cannot become a passing check"
else
    fail "malformed aardvark PID metadata was reported healthy"
fi
printf '%s\n' "${BASHPID:-$$}" \
    > "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
chmod 600 "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && ! grep -q 'aardvark-dns OK' <<<"$DOCTOR_OUTPUT"; then
    pass "a live foreign process cannot satisfy aardvark identity"
else
    fail "PID liveness alone was accepted as aardvark identity"
fi
rm -f "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
unset DOCTOR_ROLE

info "aardvark PID acceptance requires a live exact executable identity"
if [ "$TEST_PLATFORM" = Linux ]; then
    aardvark_fixture="$FAKE_BIN/aardvark-dns"
    aardvark_renamed_dir="$TMP/renamed-aardvark"
    mkdir -p "$aardvark_renamed_dir"
    cp /bin/sleep "$aardvark_fixture"
    cp /bin/sleep "$aardvark_renamed_dir/aardvark-dns"
    chmod 500 "$aardvark_fixture" "$aardvark_renamed_dir/aardvark-dns"
    "$aardvark_fixture" 30 &
    aardvark_fixture_pid=$!
    printf '%s\n' "$aardvark_fixture_pid" \
        > "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
    chmod 600 \
        "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
    DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor
    if grep -q 'aardvark-dns OK' <<<"$DOCTOR_OUTPUT"; then
        pass "pidfd, owner, start token, and the trusted executable prove aardvark"
    else
        fail "the live trusted aardvark executable identity was not recognized"
    fi
    if ! kill -KILL "$aardvark_fixture_pid" 2>/dev/null; then :; fi
    if ! wait "$aardvark_fixture_pid" 2>/dev/null; then :; fi

    "$aardvark_renamed_dir/aardvark-dns" 30 &
    aardvark_renamed_pid=$!
    printf '%s\n' "$aardvark_renamed_pid" \
        > "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
    chmod 600 \
        "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
    DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && ! grep -q 'aardvark-dns OK' <<<"$DOCTOR_OUTPUT"; then
        pass "a renamed same-basename process cannot replace the trusted aardvark identity"
    else
        fail "aardvark validation trusted a same-basename foreign executable"
    fi
    if ! kill -KILL "$aardvark_renamed_pid" 2>/dev/null; then :; fi
    if ! wait "$aardvark_renamed_pid" 2>/dev/null; then :; fi
    rm -f "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns/aardvark.pid"
    rm -f "$aardvark_fixture" "$aardvark_renamed_dir/aardvark-dns"
    rmdir "$aardvark_renamed_dir"
    unset DOCTOR_ROLE aardvark_fixture aardvark_fixture_pid \
        aardvark_renamed_dir aardvark_renamed_pid
else
    pass "exact aardvark process identity proof is Linux-only"
fi

info "stale PID cleanup uses the bounded mutation boundary, never ambient rm"
mkdir -p "$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns"
aardvark_pid_parent="$DOCTOR_RUNTIME_DIR/containers/networks/aardvark-dns"
printf '%s\n' '99999999' \
    > "$aardvark_pid_parent/aardvark.pid"
chmod 600 "$aardvark_pid_parent/aardvark.pid"
RM_MODE=repair-hang DOCTOR_ROLE=worker \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$(uname -s)" = Linux ]; then
    aardvark_quarantine=""
    for candidate in "$aardvark_pid_parent"/.aardvark.pid.cleanup-*; do
        [ -f "$candidate" ] || continue
        aardvark_quarantine=$candidate
        break
    done
    # A same-UID actor may immediately recreate the mutable operational name;
    # retained quarantine must keep the bound evidence distinct and recoverable.
    printf '%s\n' replacement > "$aardvark_pid_parent/aardvark.pid"
    chmod 600 "$aardvark_pid_parent/aardvark.pid"
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ -n "$aardvark_quarantine" ] \
        && grep -Fxq 99999999 "$aardvark_quarantine" \
        && grep -Fxq replacement "$aardvark_pid_parent/aardvark.pid" \
        && [ ! -e "$RM_EFFECT_MARKER" ] \
        && [ ! -s "$RM_CHILD_PID" ] \
        && grep -q 'retained for operator recovery' <<<"$DOCTOR_OUTPUT"; then
        pass "stale PID cleanup preserves replacements and reports retained recovery evidence"
    else
        fail "stale PID cleanup deleted by mutable name or concealed retained evidence"
    fi
elif [ -e "$aardvark_pid_parent/aardvark.pid" ] \
    && [ ! -e "$RM_EFFECT_MARKER" ] \
    && [ ! -s "$RM_CHILD_PID" ] \
    && grep -q 'stale aardvark-dns PID repair unavailable' \
        <<<"$DOCTOR_OUTPUT"; then
    pass "non-Linux stale PID cleanup fails before mutation"
else
    fail "stale PID cleanup bypassed its platform boundary"
fi
/bin/rm -f "$aardvark_pid_parent/aardvark.pid" \
    "$aardvark_pid_parent"/.aardvark.pid.cleanup-*
unset DOCTOR_ROLE RM_MODE aardvark_pid_parent aardvark_quarantine candidate

if [ "$(uname -s)" != Linux ]; then
    SYSTEMCTL_MODE=success-escape \
    TAILSCALE_STATUS_MODE=repairable \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install --cross-host --capability-only
    nonlinux_effect_descendant=""
    [ -s "$SYSTEMCTL_CHILD_PID" ] \
        && nonlinux_effect_descendant=$(cat "$SYSTEMCTL_CHILD_PID")
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ -z "$nonlinux_effect_descendant" ]; then
        pass "non-Linux install effects fail before an unprovable launch"
    else
        if [ -n "$nonlinux_effect_descendant" ] \
            && kill -0 "$nonlinux_effect_descendant" 2>/dev/null; then
            kill -KILL "$nonlinux_effect_descendant" 2>/dev/null
        fi
        fail "non-Linux install effect claimed success without descendant proof"
    fi
    OSTYPE=linux-gnu \
    SYSTEMCTL_MODE=success-escape \
    TAILSCALE_STATUS_MODE=repairable \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install --cross-host --capability-only
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ ! -s "$SYSTEMCTL_LOG" ] \
        && [ ! -s "$SYSTEMCTL_CHILD_PID" ]; then
        pass "ambient OSTYPE cannot authorize a non-Linux mutation"
    else
        fail "ambient OSTYPE bypassed the platform effect boundary"
    fi
    unset nonlinux_effect_descendant
else
    pass "non-Linux install-effect fail-closed behavior is exercised on non-Linux CI"
fi
unset SYSTEMCTL_MODE TAILSCALE_STATUS_MODE

info "all Conan profile calls share one bounded repair deadline"
for conan_mode in show-hang repair-hang post-show-hang; do
    conan_started=$(date +%s)
    CONAN_MODE="$conan_mode" \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --install --role control
    conan_elapsed=$(($(date +%s) - conan_started))
    conan_descendant=""
    [ -s "$CONAN_CHILD_PID" ] && conan_descendant=$(cat "$CONAN_CHILD_PID")
    conan_descendant_gone=true
    if [ -n "$conan_descendant" ] \
        && ! process_is_gone "$conan_descendant" \
            "$CONAN_HEARTBEAT_MARKER"; then
        conan_descendant_gone=false
    fi
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ "$conan_elapsed" -le 20 ] \
        && [ ! -e "$CONAN_EFFECT_MARKER" ] \
        && [ "$conan_descendant_gone" = true ]; then
        pass "$conan_mode stays inside the Conan repair deadline"
    else
        if [ -n "$conan_descendant" ] \
            && kill -0 "$conan_descendant" 2>/dev/null; then
            kill -KILL "$conan_descendant" 2>/dev/null
        fi
        fail "$conan_mode escaped its bounded Conan boundary"
    fi
done
unset CONAN_MODE conan_mode conan_descendant conan_descendant_gone

info "local doctor mode never requires or invokes Tailscale"
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ ! -s "$TAILSCALE_LOG" ]; then
    pass "local doctor mode performs no Tailscale command"
else
    fail "local doctor mode invoked Tailscale"
fi
if grep -q 'cross-host checks not selected' <<<"$DOCTOR_OUTPUT"; then
    pass "local doctor mode discloses the skipped topology"
else
    fail "local doctor mode did not disclose its topology scope"
fi

info "install mode never executes ambient package installers"
prepare_pythonless_path
ln -sf "$FAKE_BIN/python3" "$PYTHONLESS_BIN/python3"
rm -f "$PYTHONLESS_BIN/python3-pip" "$PYTHONLESS_BIN/git" \
    "$PYTHONLESS_BIN/just" "$PYTHONLESS_BIN/pip3" \
    "$PYTHONLESS_BIN/curl" "$PYTHONLESS_BIN/jq" \
    "$PYTHONLESS_BIN/tailscale" "$PYTHONLESS_BIN/cmake" \
    "$PYTHONLESS_BIN/ninja" "$PYTHONLESS_BIN/ninja-build" \
    "$PYTHONLESS_BIN/g++" "$PYTHONLESS_BIN/libssl-dev" \
    "$PYTHONLESS_BIN/make" "$PYTHONLESS_BIN/conan" \
    "$PYTHONLESS_BIN/pixi" "$PYTHONLESS_BIN/podman" \
    "$PYTHONLESS_BIN/podman-compose"
DOCTOR_PATH_OVERRIDE="$PYTHONLESS_BIN" \
NATS_PY_MODE=missing \
DPKG_MODE=rc \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --cross-host --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -s "$APT_LOG" ] \
    && ! grep -Eq 'https://(just[.]systems|tailscale[.]com|pixi[.]sh)/.*install[.]sh' \
        "$CURL_LOG" \
    && ! grep -Eq '^(cargo install|pip3 install)( |$)' "$PACKAGE_INSTALL_LOG" \
    && grep -q 'pre-provision' <<<"$DOCTOR_OUTPUT"; then
    pass "missing control tools stop for verified pre-provisioning without package installers"
else
    fail "install mode executed an ambient control-host package installer"
fi

DOCTOR_ROLE=worker \
DOCTOR_PATH_OVERRIDE="$PYTHONLESS_BIN" \
NATS_PY_MODE=missing \
DPKG_MODE=rc \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$PACKAGE_INSTALL_LOG" ] \
    && grep -q 'pre-provision' <<<"$DOCTOR_OUTPUT"; then
    pass "missing worker tools stop for verified pre-provisioning without package installers"
else
    fail "install mode executed an ambient worker-host package installer"
fi

if ! grep -Eq 'apt-get[[:space:]]+install|pip3[[:space:]]+install|cargo[[:space:]]+install|https://(just[.]systems|tailscale[.]com|pixi[.]sh)/.*install[.]sh' \
    "$FIXTURE_ROOT/e2e/doctor.sh"; then
    pass "doctor contains no ambient package-installer path"
else
    fail "doctor retains an ambient package-installer path"
fi
unset DOCTOR_PATH_OVERRIDE NATS_PY_MODE DPKG_MODE DOCTOR_ROLE

PYTHON3_MODE=installable GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q -- '--worker-ip requires --cross-host' <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$TAILSCALE_LOG" ]; then
    pass "argument relationships fail before prerequisite inspection or repair"
else
    fail "an invalid argument relationship reached prerequisite inspection or repair"
fi
unset PYTHON3_MODE

info "peer validation distinguishes a missing Python prerequisite"
PYTHON3_MODE=missing GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'python3 — NOT FOUND (required prerequisite)' \
        <<<"$DOCTOR_OUTPUT" \
    && grep -q 'peer target validation requires a working python3 prerequisite' \
        <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'peer targets must be literal IP addresses' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$TAILSCALE_LOG" ] \
    && [ ! -s "$PING_LOG" ] \
    && ! grep -qE 'https?://' "$CURL_LOG"; then
    pass "check-only mode reports missing Python before network effects"
else
    fail "check-only mode misclassified missing Python or reached an effect"
fi

PYTHON3_MODE=installable GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --cross-host --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'python3.*pre-provision a verified' <<<"$DOCTOR_OUTPUT" \
    && grep -q 'peer target validation requires a working python3 prerequisite' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$PACKAGE_INSTALL_LOG" ] \
    && [ ! -s "$TAILSCALE_LOG" ] \
    && [ ! -s "$PING_LOG" ]; then
    pass "install mode requires verified Python provisioning before peer checks"
else
    fail "install mode installed Python or continued without a verified interpreter"
fi
unset PYTHON3_MODE

info "peer validation requires executable Python canonicalization"
PYTHON3_MODE=parser-broken-installable \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'python3 — IP literal canonicalization unavailable' \
        <<<"$DOCTOR_OUTPUT" \
    && grep -q 'peer target validation requires a working python3 prerequisite' \
        <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'peer targets must be literal IP addresses' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$TAILSCALE_LOG" ] \
    && [ ! -s "$PING_LOG" ] \
    && ! grep -qE 'https?://' "$CURL_LOG"; then
    pass "check-only mode diagnoses a broken Python canonicalizer"
else
    fail "broken Python canonicalizer was misclassified as an invalid peer"
fi

PYTHON3_MODE=parser-broken-installable \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --cross-host --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'python3.*pre-provision a verified' <<<"$DOCTOR_OUTPUT" \
    && grep -q 'peer target validation requires a working python3 prerequisite' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$PACKAGE_INSTALL_LOG" ] \
    && [ ! -s "$TAILSCALE_LOG" ] \
    && [ ! -s "$PING_LOG" ]; then
    pass "install mode requires verified repair of Python canonicalization"
else
    fail "install mode mutated Python or continued with a broken canonicalizer"
fi
unset PYTHON3_MODE

info "missing Python blocks invalid peers without prerequisite installation"
PYTHON3_MODE=installable MISSING_CORE_TOOLS=true \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --cross-host --worker-ip 999.0.0.1
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'python3.*pre-provision a verified' \
        <<<"$DOCTOR_OUTPUT" \
    && grep -q 'peer target validation requires a working python3 prerequisite' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$PACKAGE_INSTALL_LOG" ] \
    && ! grep -qE 'https?://' "$CURL_LOG" \
    && [ ! -s "$TAILSCALE_LOG" ] \
    && [ ! -s "$PING_LOG" ]; then
    pass "missing Python stops every effect before peer validation"
else
    fail "missing Python reached an install, download, or network check"
fi
unset PYTHON3_MODE MISSING_CORE_TOOLS

info "peer targets are parsed as literal IPv4 or IPv6 before network effects"
while IFS='|' read -r case_name invalid_ip; do
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --cross-host --worker-ip "$invalid_ip"
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && grep -q 'peer targets must be literal IP addresses' \
            <<<"$DOCTOR_OUTPUT" \
        && [ ! -s "$TAILSCALE_LOG" ] \
        && [ ! -s "$PING_LOG" ] \
        && ! grep -qE 'https?://' "$CURL_LOG"; then
        pass "$case_name is rejected before Tailscale, ping, or network curl"
    else
        fail "$case_name reached an external command or was accepted"
    fi
done <<'EOF'
oversized IPv4 octet|999.0.0.1
short IPv4 address|192.0.2
IPv4 address with a port|192.0.2.1:8080
IPv4 address with a leading-zero octet|192.0.002.1
malformed IPv6 compression|2001:db8:::1
bracketed IPv6 URL host|[2001:db8::1]
scoped IPv6 address|fe80::1%en0
non-address hexadecimal text|deadbeef
EOF

GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --check-services \
        --worker-ip 2001:0DB8:0:0:0:0:0:1 \
        --control-ip 2001:0DB8:0:0:0:0:0:2
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && grep -q -- '-c1 -W3 2001:db8::1$' "$PING_LOG" \
    && grep -q -- '-c1 -W3 2001:db8::2$' "$PING_LOG" \
    && grep -qF -- '--connect-timeout 5 --max-time 15 --silent --write-out \n%{http_code} --noproxy * http://[2001:db8::1]:8222/healthz' "$CURL_LOG" \
    && grep -qF -- '--connect-timeout 5 --max-time 15 --silent --write-out \n%{http_code} --noproxy * http://[2001:db8::2]:8081/v1/health' "$CURL_LOG" \
    && ! grep -qF 'http://2001:0DB8:0:0:0:0:0:1:' "$CURL_LOG"; then
    pass "canonical IPv6 service checks use bounded HTTP requests"
else
    fail "IPv6 targets were unbounded or not canonicalized at the HTTP boundary"
fi

info "reachable self and non-peer addresses cannot become topology proof"
for target in 127.0.0.1 100.64.0.1 192.0.2.99; do
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
        run_doctor --cross-host --worker-ip "$target"
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && grep -q 'not an online Tailscale peer' <<<"$DOCTOR_OUTPUT" \
        && [ ! -s "$PING_LOG" ] \
        && ! grep -q -- '-sf http' "$CURL_LOG"; then
        pass "$target is rejected before reachability or service probes"
    else
        fail "$target was accepted without exact peer identity"
    fi
done

info "HTTP 2xx responses require each service's exact health schema"
CURL_HEALTH_MODE=wrong GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --check-services \
        --worker-ip 2001:db8::1 --control-ip 2001:db8::2
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'response identity or health schema did not match' \
        <<<"$DOCTOR_OUTPUT" \
    && ! grep '✓' <<<"$DOCTOR_OUTPUT" \
        | grep -qE 'NATS @|Agamemnon @|Hermes @|Grafana @|Prometheus @|Argus Exporter @|Nestor @'; then
    pass "wrong-body 2xx responders cannot satisfy service health"
else
    fail "an arbitrary 2xx body became cross-host service proof"
fi
unset CURL_HEALTH_MODE

info "oversized service bodies stop in the parser before full transport output"
CURL_HEALTH_MODE=oversized GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --check-services --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -e "$CURL_BODY_COMPLETE_MARKER" ] \
    && grep -q 'response identity or health schema did not match' \
        <<<"$DOCTOR_OUTPUT"; then
    pass "oversized peer response is rejected before Bash can buffer the full body"
else
    fail "oversized peer response was fully buffered or accepted"
fi
unset CURL_HEALTH_MODE

GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor --cross-host
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q -- '--cross-host requires an exact peer target' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$TAILSCALE_LOG" ]; then
    pass "targetless cross-host mode cannot become topology proof"
else
    fail "targetless cross-host mode did not fail before Tailscale inspection"
fi

TAILSCALE_STATUS_MODE=repairable GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --capability-only --install
if [ "$(uname -s)" = Linux ]; then
    if [ "$DOCTOR_STATUS" -eq 0 ] \
        && grep -q '^start tailscaled$' "$SYSTEMCTL_LOG" \
        && grep -q 'tailscaled running after start' <<<"$DOCTOR_OUTPUT"; then
        pass "explicit capability-only install verifies repaired Tailscale state"
    else
        fail "Linux capability-only install retained or missed a repaired failure"
    fi
elif [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -s "$SYSTEMCTL_LOG" ] \
    && grep -q 'start or post-start readback failed' <<<"$DOCTOR_OUTPUT"; then
    pass "non-Linux capability-only repair fails before mutation"
else
    fail "non-Linux capability-only install launched an unprovable repair"
fi

DOCTOR_ROLE=control GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --install --configure-firewall
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'broad trusted-interface firewall mutation is unavailable' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$TAILSCALE_LOG" ]; then
    pass "control-only doctor rejects broad firewall mutation before effects"
else
    fail "control-only doctor reached inspection for a broad firewall mutation"
fi

DOCTOR_ROLE=worker GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --cross-host --install --configure-firewall
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'broad trusted-interface firewall mutation is unavailable' \
        <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$TAILSCALE_LOG" ]; then
    pass "broad firewall mutation is unavailable before host effects"
else
    fail "broad firewall mutation reached host inspection or effects"
fi
if ! grep -q -- '--zone=trusted --add-interface=tailscale0' \
    "$FIXTURE_ROOT/e2e/doctor.sh"; then
    pass "doctor contains no whole-interface trusted-zone mutation"
else
    fail "doctor still contains a broad trusted-interface mutation"
fi

info "libssl-dev passes only for exact installed state with a version"
while IFS='|' read -r dpkg_mode case_name; do
    DPKG_MODE="$dpkg_mode" \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && grep -q 'libssl-dev — NOT FOUND or package state/version check failed' \
            <<<"$DOCTOR_OUTPUT" \
        && ! grep -q 'libssl-dev [0-9]' <<<"$DOCTOR_OUTPUT"; then
        pass "$case_name cannot become an installed-package pass"
    else
        fail "$case_name became an installed-package pass"
    fi
done <<'EOF'
empty|empty dpkg output
rc|removed package with residual configuration
non-ii|non-installed dpkg state
ii-empty-version|installed state without a version
EOF
unset DPKG_MODE

while IFS='|' read -r dpkg_mode case_name; do
    DPKG_MODE="$dpkg_mode" \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor --install
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ ! -s "$APT_LOG" ] \
        && ! grep -Eq '^(cargo|pip3) install( |$)' \
            "$PACKAGE_INSTALL_LOG" \
        && grep -q 'libssl-dev.*pre-provision a verified' \
            <<<"$DOCTOR_OUTPUT" \
        && ! grep -q 'libssl-dev installed' <<<"$DOCTOR_OUTPUT"; then
        pass "$case_name stops for verified provisioning without package installation"
    else
        fail "$case_name reached package installation or false completion"
    fi
done <<'EOF'
empty|empty dpkg output in install mode
rc|residual-config state in install mode
non-ii|non-installed state in install mode
ii-empty-version|installed state without a version in install mode
EOF
unset DPKG_MODE

info "submodule Git calls scrub ambient routing and configuration"
ASSERT_CLEAN_GIT_ENV=true \
DOCTOR_GIT_DIR="$TMP/hostile.git" \
DOCTOR_GIT_WORK_TREE="$TMP/hostile-worktree" \
DOCTOR_GIT_COMMON_DIR="$TMP/hostile-common" \
DOCTOR_GIT_CONFIG="$TMP/hostile-config" \
DOCTOR_GIT_CONFIG_GLOBAL="$TMP/hostile-global" \
DOCTOR_GIT_CONFIG_SYSTEM="$TMP/hostile-system" \
DOCTOR_GIT_CONFIG_NOSYSTEM=0 \
DOCTOR_GIT_CONFIG_COUNT=1 \
DOCTOR_GIT_CONFIG_KEY_0='protocol.file.allow' \
DOCTOR_GIT_CONFIG_VALUE_0=always \
DOCTOR_GIT_CONFIG_PARAMETERS="'url.https://evil.invalid/.insteadOf'='https://github.com/'" \
DOCTOR_GIT_SSH="$TMP/hostile-ssh" \
DOCTOR_GIT_SSH_COMMAND="$TMP/hostile-ssh-command" \
DOCTOR_GIT_ALLOW_PROTOCOL='file:https' \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ "$DOCTOR_STATUS" -eq 0 ] && [ ! -e "$GIT_ATTACK_SENTINEL" ]; then
    pass "submodule inspection ignores ambient Git routing"
else
    fail "ambient Git routing reached submodule inspection"
fi
unset ASSERT_CLEAN_GIT_ENV DOCTOR_GIT_DIR DOCTOR_GIT_WORK_TREE \
    DOCTOR_GIT_COMMON_DIR DOCTOR_GIT_CONFIG DOCTOR_GIT_CONFIG_GLOBAL \
    DOCTOR_GIT_CONFIG_SYSTEM DOCTOR_GIT_CONFIG_NOSYSTEM \
    DOCTOR_GIT_CONFIG_COUNT DOCTOR_GIT_CONFIG_KEY_0 \
    DOCTOR_GIT_CONFIG_VALUE_0 DOCTOR_GIT_CONFIG_PARAMETERS \
    DOCTOR_GIT_SSH DOCTOR_GIT_SSH_COMMAND DOCTOR_GIT_ALLOW_PROTOCOL

info "submodule updates reject custom update commands and routing rewrites"
for git_security_case in custom-update url-rewrite protocol-rewrite; do
    GIT_SECURITY_MODE="$git_security_case" \
    GIT_SUBMODULE_MODE=uninit_then_ok GREP_SCAN_MODE=nomatch \
        run_doctor --install
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ ! -e "$GIT_ATTACK_SENTINEL" ] \
        && ! grep -q '^submodule update ' "$GIT_LOG"; then
        pass "$git_security_case is rejected before submodule update"
    else
        fail "$git_security_case reached a submodule update effect"
    fi
done
unset GIT_SECURITY_MODE

info "submodule initialization fails before mutable repository authority"
for git_security_case in \
    update-manifest-replace \
    update-gitdir-replace \
    update-config-replace \
    update-index-replace \
    update-gitlink-replace \
    update-hang \
    update-escape; do
    update_started=$(date +%s)
    GIT_SECURITY_MODE="$git_security_case" \
    GIT_SUBMODULE_MODE=uninit_then_ok GREP_SCAN_MODE=nomatch \
        run_doctor --install
    update_elapsed=$(($(date +%s) - update_started))
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && [ "$update_elapsed" -le 20 ] \
        && [ ! -e "$GIT_UPDATE_EFFECT_MARKER" ] \
        && [ ! -s "$GIT_UPDATE_CHILD_PID" ] \
        && ! grep -q '^submodule update ' "$GIT_LOG" \
        && grep -q 'unavailable pending a trusted exact-pin updater' \
            <<<"$DOCTOR_OUTPUT"; then
        pass "$git_security_case cannot reach a Git update effect"
    else
        fail "$git_security_case reached mutable Git authority (status=$DOCTOR_STATUS elapsed=${update_elapsed}s)"
    fi
done
unset GIT_SECURITY_MODE update_started update_elapsed

ASSERT_CLEAN_GIT_ENV=true ASSERT_SAFE_GIT_UPDATE=true \
GIT_SUBMODULE_MODE=uninit_then_ok GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ ! -e "$GIT_ATTACK_SENTINEL" ] \
    && ! grep -q '^submodule update ' "$GIT_LOG" \
    && grep -q 'unavailable pending a trusted exact-pin updater' \
        <<<"$DOCTOR_OUTPUT"; then
    pass "doctor never grants stock Git submodule update authority"
else
    fail "doctor attempted a stock Git submodule update"
fi
unset ASSERT_CLEAN_GIT_ENV ASSERT_SAFE_GIT_UPDATE

GIT_SUBMODULE_MODE=uninit_then_empty GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'unavailable pending a trusted exact-pin updater' \
        <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'All 1 submodules initialized' <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'All submodule paths are direct directories' <<<"$DOCTOR_OUTPUT"; then
    pass "uninitialized inventory cannot become completion"
else
    fail "uninitialized inventory produced a false success"
fi

info "failed submodule inventory cannot become an empty passing inventory"
GIT_SUBMODULE_MODE=fail GREP_SCAN_MODE=ok run_doctor
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'submodule inventory unavailable' <<<"$DOCTOR_OUTPUT"; then
    pass "failed submodule inventory is unavailable"
else
    fail "failed submodule inventory returned $DOCTOR_STATUS without an unavailable result"
fi
if ! grep -q 'All 0 submodules initialized' <<<"$DOCTOR_OUTPUT"; then
    pass "failed inventory emits no zero-submodule success"
else
    fail "failed inventory emitted a zero-submodule success"
fi

mv "$FIXTURE_ROOT/.gitmodules" "$FIXTURE_ROOT/.gitmodules.hidden"
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
mv "$FIXTURE_ROOT/.gitmodules.hidden" "$FIXTURE_ROOT/.gitmodules"
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'submodule metadata unavailable' <<<"$DOCTOR_OUTPUT"; then
    pass "missing .gitmodules is unavailable"
else
    fail "missing .gitmodules returned $DOCTOR_STATUS without an unavailable result"
fi

mv "$FIXTURE_ROOT/.gitmodules" "$FIXTURE_ROOT/.gitmodules.direct"
ln -s .gitmodules.direct "$FIXTURE_ROOT/.gitmodules"
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
rm "$FIXTURE_ROOT/.gitmodules"
mv "$FIXTURE_ROOT/.gitmodules.direct" "$FIXTURE_ROOT/.gitmodules"
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'must be a direct owner-bound regular file' \
        <<<"$DOCTOR_OUTPUT" \
    && ! grep -q -- '-f .gitmodules' "$GIT_LOG"; then
    pass "symlinked .gitmodules is rejected before Git parses it"
else
    fail "symlinked .gitmodules reached Git configuration parsing"
fi

info "role typos and targetless service checks stop before partial validation"
DOCTOR_ROLE=fixture GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'role must be one of' <<<"$DOCTOR_OUTPUT"; then
    pass "invalid role is rejected"
else
    fail "invalid role did not produce the required rejection"
fi
DOCTOR_ROLE=control GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --check-services
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q -- '--check-services requires' <<<"$DOCTOR_OUTPUT"; then
    pass "targetless service check is rejected"
else
    fail "targetless service check did not produce the required rejection"
fi

info "install mode never updates a pinned component checkout"
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=ok run_doctor --install
UNEXPECTED_GIT_COMMAND=""
while IFS= read -r git_command; do
    case "$git_command" in
        '--version' \
        | 'config --no-includes -f .gitmodules --get-regexp ^submodule\..*\.path$' \
        | 'config --no-includes -f .gitmodules --get-regexp ^submodule\..*\.url$' \
        | 'config --no-includes -f .gitmodules --get-regexp '* \
        | 'config --local --no-includes --get-regexp '* \
        | 'config --local --no-includes --get submodule.provisioning/Myrmidons.url' \
        | 'submodule status')
            ;;
        *)
            UNEXPECTED_GIT_COMMAND="$git_command"
            break
            ;;
    esac
done < "$GIT_LOG"
if [ -z "$UNEXPECTED_GIT_COMMAND" ]; then
    pass "doctor uses only its explicit read/install Git allowlist"
else
    fail "doctor issued an unapproved Git command: $UNEXPECTED_GIT_COMMAND"
fi

info "an unreadable stale-reference scan cannot pass as zero findings"
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=fail run_doctor
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'Myrmidons reference scan unavailable' <<<"$DOCTOR_OUTPUT"; then
    pass "failed Myrmidons scan is unavailable"
else
    fail "failed Myrmidons scan returned $DOCTOR_STATUS without an unavailable result"
fi
if ! grep -q 'Myrmidons targets Agamemnon' <<<"$DOCTOR_OUTPUT"; then
    pass "failed Myrmidons scan emits no passing claim"
else
    fail "failed Myrmidons scan emitted a passing claim"
fi

summary
exit_code
