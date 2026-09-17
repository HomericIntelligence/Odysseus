#!/usr/bin/env bash
# Behavior tests for fail-closed, read-only submodule doctor checks.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

FIXTURE_ROOT="$TMP/repo"
FAKE_BIN="$TMP/bin"
PYTHONLESS_BIN="$TMP/pythonless-bin"
GIT_LOG="$TMP/git.log"
PYTHON_LOG="$TMP/python.log"
TAILSCALE_LOG="$TMP/tailscale.log"
SYSTEMCTL_LOG="$TMP/systemctl.log"
PING_LOG="$TMP/ping.log"
CURL_LOG="$TMP/curl.log"
CURL_BODY_COMPLETE_MARKER="$TMP/curl-body.complete"
APT_LOG="$TMP/apt.log"
TAILSCALE_RUNNING_MARKER="$TMP/tailscale.running"
GIT_STATUS_READ_MARKER="$TMP/git-status.read"
LIBSSL_INSTALL_MARKER="$TMP/libssl.installed"
PYTHON_REPAIRED_MARKER="$TMP/python.repaired"
PROCESS_OUTPUT_MARKER="$TMP/process-output.complete"
PROCESS_CHILD_PID="$TMP/process-child.pid"
GIT_ATTACK_SENTINEL="$TMP/git-attack.sentinel"
PYTHON_ATTACK_SENTINEL="$TMP/python-attack.sentinel"
DOCTOR_HOME="$TMP/home"
DOCTOR_RUNTIME_DIR="$TMP/runtime"
mkdir -p "$FIXTURE_ROOT/e2e/lib" \
    "$FIXTURE_ROOT/provisioning/Myrmidons/scripts" "$FAKE_BIN" \
    "$DOCTOR_HOME/.local/src/podman-fixture/contrib/systemd/user" \
    "$DOCTOR_RUNTIME_DIR"
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
printf '%s\n' 'MAESTRO_URL=http://retired.invalid' \
    > "$FIXTURE_ROOT/provisioning/Myrmidons/scripts/stale.sh"

cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
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
    esac
    exit 0
fi
exit 0
SH

cat > "$FAKE_BIN/grep" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "-rE" ] && [ "${GREP_SCAN_MODE:-ok}" = fail ]; then
    exit 2
fi
if [ "${1:-}" = "-rE" ] && [ "${GREP_SCAN_MODE:-ok}" = nomatch ]; then
    exit 1
fi
exec /usr/bin/grep "$@"
SH

for command_name in just pip3 jq ninja make pixi; do
    cat > "$FAKE_BIN/$command_name" <<'SH'
#!/usr/bin/env bash
if [ "${BROKEN_VERSION_TOOL:-}" = "$(basename "$0")" ]; then
    case "${BROKEN_VERSION_MODE:-fail}" in
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
            bash -c 'trap "" TERM; printf "%s\n" "$$" > "${PROCESS_CHILD_PID:?}"; while :; do sleep 1; done' \
                >/dev/null 2>&1 &
            trap '' TERM
            sleep 6
            exit 64
            ;;
        *) exit 64 ;;
    esac
fi
printf '%s\n' 'fixture 1.0.0'
SH
done

cat > "$FAKE_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$CURL_LOG"
if [ "${BROKEN_VERSION_TOOL:-}" = "curl" ]; then
    if [ "${BROKEN_VERSION_MODE:-fail}" = empty ]; then
        exit 0
    fi
    exit 64
fi
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' 'curl 8.0.0'
    exit 0
fi
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
if [ "${CURL_HEALTH_MODE:-valid}" = oversized ] \
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
if [ "${CURL_HEALTH_MODE:-valid}" = wrong ]; then
    emit_response '{"status":"some-other-service"}' 200
    exit 0
fi
case "$url" in
    *:8222/healthz) emit_response ok 200 ;;
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
printf '%s\n' "$*" >> "$PING_LOG"
exit 0
SH

cat > "$FAKE_BIN/podman" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "compose" ] && [ "${2:-}" = "version" ]; then
    if [ "${BROKEN_VERSION_TOOL:-}" = "podman-compose" ]; then
        if [ "${BROKEN_VERSION_MODE:-fail}" = empty ]; then
            exit 0
        fi
        exit 64
    fi
    printf '%s\n' 'podman-compose version 1.2.3'
    exit 0
fi
if [ "${BROKEN_VERSION_TOOL:-}" = "podman" ]; then
    if [ "${BROKEN_VERSION_MODE:-fail}" = empty ]; then
        exit 0
    fi
    exit 64
fi
printf '%s\n' 'podman version 5.4.0'
SH

cat > "$FAKE_BIN/cmake" <<'SH'
#!/usr/bin/env bash
if [ "${BROKEN_VERSION_TOOL:-}" = "cmake" ]; then
    exit 64
fi
printf '%s\n' 'cmake version 3.30.0'
SH

cat > "$FAKE_BIN/g++" <<'SH'
#!/usr/bin/env bash
if [ "${BROKEN_VERSION_TOOL:-}" = "g++" ]; then
    exit 64
fi
printf '%s\n' 'g++ 14.0.0'
SH

cat > "$FAKE_BIN/conan" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = "profile" ]; then
    exit 0
fi
if [ "${BROKEN_VERSION_TOOL:-}" = "conan" ]; then
    exit 64
fi
printf '%s\n' 'Conan version 2.0.0'
SH

cat > "$FAKE_BIN/dpkg" <<'SH'
#!/usr/bin/env bash
mode="${DPKG_MODE:-ii}"
if [ -e "$LIBSSL_INSTALL_MARKER" ]; then
    mode="${DPKG_POST_INSTALL_MODE:-ii}"
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
printf '%s\n' "$*" >> "$APT_LOG"
if [ "${1:-}" = "install" ] && [ "${3:-}" = "libssl-dev" ]; then
    : > "$LIBSSL_INSTALL_MARKER"
fi
if [ "${1:-}" = "install" ] && [ "${3:-}" = "python3" ]; then
    case "${PYTHON3_MODE:-present}" in
        installable)
            cp "$PYTHON3_FIXTURE_SOURCE" "$DOCTOR_ACTIVE_BIN/python3"
            chmod +x "$DOCTOR_ACTIVE_BIN/python3"
            ;;
        parser-broken-installable)
            : > "$PYTHON_REPAIRED_MARKER"
            ;;
    esac
fi
exit "${APT_INSTALL_STATUS:-0}"
SH

cat > "$FAKE_BIN/python3" <<'SH'
#!/usr/bin/env bash
printf '%q ' "$@" >> "${PYTHON_LOG:?}"
printf '\n' >> "${PYTHON_LOG:?}"
original_args=("$@")
if [ "${1:-}" = "-I" ] && [ "${2:-}" = "-S" ]; then
    shift 2
fi
if [ "${1:-}" = "--version" ]; then
    if [ "${BROKEN_VERSION_TOOL:-}" = "python3" ]; then
        if [ "${BROKEN_VERSION_MODE:-fail}" = empty ]; then
            exit 0
        fi
        exit 64
    fi
    printf '%s\n' 'Python 3.13.0'
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'start_new_session=True'* ]]; then
    exec /usr/bin/python3 "${original_args[@]}"
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'ipaddress.ip_address'* ]]; then
    if [ "${PYTHON3_MODE:-present}" = parser-broken-installable ] \
        && [ ! -e "$PYTHON_REPAIRED_MARKER" ]; then
        exit 64
    fi
    exec /usr/bin/python3 "${original_args[@]}"
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'PathFinder.find_spec'* ]]; then
    printf '%s\n' '1.0.0'
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'import nats'* ]]; then
    exit 0
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'metadata.version'* ]]; then
    printf '%s\n' '1.0.0'
elif [ "${1:-}" = "-c" ] && [[ "${2:-}" == *'hi_agamemnon_health'* ]]; then
    exec /usr/bin/python3 "${original_args[@]}"
fi
exit 0
SH

cat > "$FAKE_BIN/tailscale" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$TAILSCALE_LOG"
if [ "${1:-}" = "status" ]; then
    if [ "${TAILSCALE_STATUS_MODE:-ok}" = repairable ] \
        && [ ! -e "$TAILSCALE_RUNNING_MARKER" ]; then
        exit 1
    fi
    if [ "${2:-}" = "--json" ]; then
        if [ "${TAILSCALE_STATUS_MODE:-ok}" = flood ]; then
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
        if [ "${TAILSCALE_STATUS_MODE:-ok}" = slow-tree ]; then
            bash -c 'trap "" TERM; printf "%s\n" "$$" > "${PROCESS_CHILD_PID:?}"; while :; do sleep 1; done' \
                >/dev/null 2>&1 &
            trap '' TERM
            sleep 6
            exit 64
        fi
        cat <<'JSON'
{"Self":{"Online":true,"TailscaleIPs":["100.64.0.1"]},"Peer":{"nodekey:worker":{"Online":true,"TailscaleIPs":["192.0.2.10","2001:db8::1"]},"nodekey:control":{"Online":true,"TailscaleIPs":["2001:db8::2"]}}}
JSON
    fi
    exit 0
fi
printf '%s\n' '1.80.0'
SH

cat > "$FAKE_BIN/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SYSTEMCTL_LOG"
if [ "${1:-}" = "--user" ] && [ "${2:-}" = "cat" ] \
    && [ "${PODMAN_UNIT_MODE:-present}" = missing ]; then
    exit 1
fi
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
exec "$@"
SH

chmod +x "$FAKE_BIN"/*

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
    : > "$GIT_LOG"
    : > "$PYTHON_LOG"
    : > "$TAILSCALE_LOG"
    : > "$SYSTEMCTL_LOG"
    : > "$PING_LOG"
    : > "$CURL_LOG"
    : > "$APT_LOG"
    rm -f "$TAILSCALE_RUNNING_MARKER"
    rm -f "$GIT_STATUS_READ_MARKER"
    rm -f "$LIBSSL_INSTALL_MARKER"
    rm -f "$PYTHON_REPAIRED_MARKER"
    rm -f "$PROCESS_OUTPUT_MARKER"
    rm -f "$PROCESS_CHILD_PID"
    rm -f "$GIT_ATTACK_SENTINEL"
    rm -f "$PYTHON_ATTACK_SENTINEL"
    rm -f "$CURL_BODY_COMPLETE_MARKER"
    set +e
    DOCTOR_OUTPUT="$(
        cd "$doctor_cwd" || exit 96
        GIT_LOG="$GIT_LOG" \
        PYTHON_LOG="$PYTHON_LOG" \
        TAILSCALE_LOG="$TAILSCALE_LOG" \
        SYSTEMCTL_LOG="$SYSTEMCTL_LOG" \
        PING_LOG="$PING_LOG" \
        CURL_LOG="$CURL_LOG" \
        CURL_BODY_COMPLETE_MARKER="$CURL_BODY_COMPLETE_MARKER" \
        APT_LOG="$APT_LOG" \
        TAILSCALE_RUNNING_MARKER="$TAILSCALE_RUNNING_MARKER" \
        GIT_STATUS_READ_MARKER="$GIT_STATUS_READ_MARKER" \
        LIBSSL_INSTALL_MARKER="$LIBSSL_INSTALL_MARKER" \
        PYTHON_REPAIRED_MARKER="$PYTHON_REPAIRED_MARKER" \
        PROCESS_OUTPUT_MARKER="$PROCESS_OUTPUT_MARKER" \
        PROCESS_CHILD_PID="$PROCESS_CHILD_PID" \
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
    local process_id=$1 attempt=0
    while [ "$attempt" -lt 40 ]; do
        attempt=$((attempt + 1))
        if ! kill -0 "$process_id" 2>/dev/null; then
            return 0
        fi
        sleep 0.05
    done
    return 1
}

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
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ "$version_elapsed" -lt 6 ] \
    && [ -n "$version_descendant" ] \
    && process_is_gone "$version_descendant"; then
    pass "version timeout extinguishes a TERM-resistant descendant"
else
    if [ -n "$version_descendant" ] \
        && kill -0 "$version_descendant" 2>/dev/null; then
        kill -KILL "$version_descendant" 2>/dev/null || true
    fi
    fail "version timeout was absent or left a descendant alive"
fi
unset BROKEN_VERSION_TOOL BROKEN_VERSION_MODE

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
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && [ "$tailscale_elapsed" -lt 6 ] \
    && [ -n "$tailscale_descendant" ] \
    && process_is_gone "$tailscale_descendant"; then
    pass "Tailscale timeout extinguishes a TERM-resistant descendant"
else
    if [ -n "$tailscale_descendant" ] \
        && kill -0 "$tailscale_descendant" 2>/dev/null; then
        kill -KILL "$tailscale_descendant" 2>/dev/null || true
    fi
    fail "Tailscale timeout was absent or left a descendant alive"
fi
unset TAILSCALE_STATUS_MODE

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
    && grep -q 'packaged podman.socket unit is unavailable' <<<"$DOCTOR_OUTPUT"; then
    pass "missing Podman units stop for an operator-owned package repair"
else
    fail "doctor copied or synthesized an unverified Podman unit"
fi
unset PODMAN_UNIT_MODE DOCTOR_ROLE

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

PYTHON3_MODE=installable GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --worker-ip 192.0.2.10
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q -- '--worker-ip requires --cross-host' <<<"$DOCTOR_OUTPUT" \
    && [ ! -s "$APT_LOG" ] \
    && [ ! -s "$TAILSCALE_LOG" ]; then
    pass "argument relationships fail before prerequisite installation"
else
    fail "an invalid argument relationship reached prerequisite installation"
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
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && grep -q '^install -y python3$' "$APT_LOG" \
    && grep -q 'python3 installed and available' <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'peer targets must be literal IP addresses' \
        <<<"$DOCTOR_OUTPUT" \
    && grep -q '^status --json$' "$TAILSCALE_LOG" \
    && grep -q -- '-c1 -W3 192.0.2.10$' "$PING_LOG"; then
    pass "install mode verifies Python before peer and network checks"
else
    fail "install mode did not bootstrap Python before peer validation"
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
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && [ "$(cat "$APT_LOG")" = 'install -y python3' ] \
    && grep -q 'python3 installed and available' <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'peer targets must be literal IP addresses' \
        <<<"$DOCTOR_OUTPUT" \
    && grep -q '^status --json$' "$TAILSCALE_LOG" \
    && grep -q -- '-c1 -W3 192.0.2.10$' "$PING_LOG"; then
    pass "install mode repairs and verifies Python canonicalization"
else
    fail "install mode did not repair the broken Python canonicalizer"
fi
unset PYTHON3_MODE

info "invalid peers permit only the Python prerequisite bootstrap"
PYTHON3_MODE=installable MISSING_CORE_TOOLS=true \
GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch \
    run_doctor --install --cross-host --worker-ip 999.0.0.1
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'peer targets must be literal IP addresses' \
        <<<"$DOCTOR_OUTPUT" \
    && [ "$(cat "$APT_LOG")" = 'install -y python3' ] \
    && ! grep -qE 'https?://' "$CURL_LOG" \
    && [ ! -s "$TAILSCALE_LOG" ] \
    && [ ! -s "$PING_LOG" ]; then
    pass "invalid peer stops every effect after Python bootstrap"
else
    fail "invalid peer reached an unrelated install, download, or network check"
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
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && grep -q '^start tailscaled$' "$SYSTEMCTL_LOG" \
    && grep -q 'tailscaled running after start' <<<"$DOCTOR_OUTPUT"; then
    pass "explicit capability-only install verifies repaired Tailscale state"
else
    fail "explicit capability-only install retained or missed a repaired failure"
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

while IFS='|' read -r post_install_mode case_name; do
    DPKG_MODE=rc \
    DPKG_POST_INSTALL_MODE="$post_install_mode" \
    GIT_SUBMODULE_MODE=ok GREP_SCAN_MODE=nomatch run_doctor --install
    if [ "$DOCTOR_STATUS" -ne 0 ] \
        && grep -q '^install -y libssl-dev$' "$APT_LOG" \
        && grep -q 'libssl-dev — install or post-install package state/version check failed' \
            <<<"$DOCTOR_OUTPUT" \
        && ! grep -q 'libssl-dev installed' <<<"$DOCTOR_OUTPUT"; then
        pass "$case_name is rejected after a successful installer exit"
    else
        fail "$case_name became post-install completion"
    fi
done <<'EOF'
empty|empty post-install dpkg output
rc|residual-config post-install state
non-ii|non-installed post-install state
ii-empty-version|post-install state without a version
EOF
unset DPKG_MODE DPKG_POST_INSTALL_MODE

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

info "submodule initialization updates only prevalidated exact paths"
ASSERT_CLEAN_GIT_ENV=true ASSERT_SAFE_GIT_UPDATE=true \
GIT_SUBMODULE_MODE=uninit_then_ok GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$DOCTOR_STATUS" -eq 0 ] \
    && [ ! -e "$GIT_ATTACK_SENTINEL" ] \
    && grep -qx 'submodule update --init -- provisioning/Myrmidons' \
        "$GIT_LOG" \
    && ! grep -q -- '--recursive' "$GIT_LOG"; then
    pass "submodule update receives only the exact missing path"
else
    fail "submodule update was unbounded or retained hostile Git state"
fi
unset ASSERT_CLEAN_GIT_ENV ASSERT_SAFE_GIT_UPDATE

GIT_SUBMODULE_MODE=uninit_then_empty GREP_SCAN_MODE=nomatch \
    run_doctor --install
if [ "$DOCTOR_STATUS" -ne 0 ] \
    && grep -q 'post-initialization submodule inventory' <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'All 1 submodules initialized' <<<"$DOCTOR_OUTPUT" \
    && ! grep -q 'All submodule paths are direct directories' <<<"$DOCTOR_OUTPUT"; then
    pass "post-initialization empty inventory cannot become completion"
else
    fail "post-initialization empty inventory produced a false success"
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
        | 'submodule status' \
        | 'submodule update --init -- provisioning/Myrmidons')
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
