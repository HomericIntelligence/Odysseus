#!/usr/bin/env bash
# Behavior tests for the agent-tooling installation surface.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
if [ "${ODYSSEUS_KEEP_TEST_TMP:-false}" = true ]; then
    trap 'printf "retained test directory: %s\n" "$TMP"' EXIT
else
    trap 'rm -rf "$TMP"' EXIT
fi

TEST_HOME="$TMP/home"
FAKE_ROOT="$TMP/odysseus"
FAKE_BIN="$TMP/bin"
SETTINGS="$TEST_HOME/.claude/settings.json"
GIT_LOG="$TMP/git.log"
SKILL_MARKER="$TMP/hephaestus-skill-installer-ran"
SETTINGS_BYTE_LIMIT=1048576

run_with_wall_deadline() {
    local seconds="$1"
    shift
    python3 -I -S - "$seconds" "$@" <<'PY'
import os
import signal
import subprocess
import sys

seconds = float(sys.argv[1])
process = subprocess.Popen(sys.argv[2:], start_new_session=True)
try:
    raise SystemExit(process.wait(timeout=seconds))
except subprocess.TimeoutExpired:
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    try:
        process.wait(timeout=0.25)
    except subprocess.TimeoutExpired:
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.wait(timeout=1.0)
    raise SystemExit(124)
PY
}

process_is_live() {
    local process_id="$1" state process_record
    kill -0 "$process_id" 2>/dev/null || return 1
    if [ -r "/proc/$process_id/stat" ]; then
        IFS= read -r process_record < "/proc/$process_id/stat" || return 0
        process_record=${process_record##*) }
        state=${process_record%% *}
        [[ "$state" != Z ]]
        return
    fi
    # A sandbox may deny process-table inspection even though signalling the
    # exact PID is permitted. Treat that uncertainty as live; otherwise a
    # denied `ps` creates a false-green descendant-extinction assertion.
    state=$(ps -o stat= -p "$process_id" 2>/dev/null) || return 0
    [[ "$state" != Z* ]]
}

wait_for_test_process_exit() {
    local process_id="$1" attempt=0
    while [ "$attempt" -lt 60 ]; do
        process_is_live "$process_id" || return 0
        sleep 0.02
        attempt=$((attempt + 1))
    done
    return 1
}

settings_write_fingerprint() {
    python3 - "$1" <<'PY'
import hashlib
import os
import sys

path = sys.argv[1]
with open(path, "rb") as stream:
    content = stream.read()
metadata = os.stat(path, follow_symlinks=False)
print(
    ":".join(
        str(value)
        for value in (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            hashlib.sha256(content).hexdigest(),
        )
    )
)
PY
}

settings_link_fingerprint() {
    python3 - "$1" <<'PY'
import os
import sys

path = sys.argv[1]
metadata = os.lstat(path)
print(
    ":".join(
        str(value)
        for value in (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
            os.readlink(path),
        )
    )
)
PY
}

settings_node_fingerprint() {
    python3 - "$1" <<'PY'
import os
import sys

metadata = os.lstat(sys.argv[1])
print(
    ":".join(
        str(value)
        for value in (
            metadata.st_dev,
            metadata.st_ino,
            metadata.st_mode,
            metadata.st_size,
            metadata.st_mtime_ns,
            metadata.st_ctime_ns,
        )
    )
)
PY
}

settings_directory_receipt() {
    python3 -I -S - "$1" <<'PY'
import os
import stat
import sys

metadata = os.lstat(sys.argv[1])
print(
    ":".join(
        (
            str(metadata.st_dev),
            str(metadata.st_ino),
            str(metadata.st_uid),
            format(stat.S_IMODE(metadata.st_mode), "o"),
        )
    )
)
PY
}

tree_fingerprint() {
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

settings_backup_inventory() {
    python3 - "$1" <<'PY'
import hashlib
import os
from pathlib import Path
import sys

settings_directory = Path(sys.argv[1])
for path in sorted(settings_directory.glob("settings.json.bak.*")):
    with path.open("rb") as stream:
        content = stream.read()
    metadata = os.stat(path, follow_symlinks=False)
    print(
        ":".join(
            (
                path.name,
                str(metadata.st_dev),
                str(metadata.st_ino),
                str(metadata.st_size),
                str(metadata.st_mtime_ns),
                str(metadata.st_ctime_ns),
                hashlib.sha256(content).hexdigest(),
            )
        )
    )
PY
}

tool_snapshot_inventory() {
    python3 -I -S - <<'PY'
import os
from pathlib import Path

root = Path(os.path.realpath("/tmp"))
for path in sorted(root.glob(".odysseus-tooling-*")):
    state = os.lstat(path)
    print(f"{path.name}:{state.st_dev}:{state.st_ino}:{state.st_mode}")
PY
}

write_canonical_settings() {
    local path="$1"
    mkdir -p "$(dirname "$path")"
    cat > "$path" <<'JSON'
{
  "extraKnownMarketplaces": {
    "Athena": {
      "source": {
        "source": "git",
        "url": "https://github.com/HomericIntelligence/Athena.git"
      }
    }
  },
  "enabledPlugins": {
    "athena@Athena": true
  }
}
JSON
}

write_sized_canonical_settings() {
    local path="$1" target_size="$2"
    mkdir -p "$(dirname "$path")"
    python3 -I -S - "$path" "$target_size" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
target_size = int(sys.argv[2])
settings = {
    "padding": "",
    "extraKnownMarketplaces": {
        "Athena": {
            "source": {
                "source": "git",
                "url": "https://github.com/HomericIntelligence/Athena.git",
            }
        }
    },
    "enabledPlugins": {"athena@Athena": True},
}

def serialize():
    return json.dumps(settings, indent=2, ensure_ascii=True).encode("utf-8") + b"\n"

padding_size = target_size - len(serialize())
if padding_size < 0:
    raise SystemExit("target is too small for canonical settings")
settings["padding"] = "x" * padding_size
payload = serialize()
if len(payload) != target_size:
    raise SystemExit("canonical settings fixture has the wrong byte size")
path.write_bytes(payload)
PY
}

write_settings_for_reconciled_size() {
    local path="$1" target_size="$2"
    mkdir -p "$(dirname "$path")"
    python3 -I -S - "$path" "$target_size" <<'PY'
import json
from pathlib import Path
import sys

path = Path(sys.argv[1])
target_size = int(sys.argv[2])
source = {
    "padding": "",
    "extraKnownMarketplaces": {},
    "enabledPlugins": {},
}

def reconciled_payload():
    output = {
        "padding": source["padding"],
        "extraKnownMarketplaces": {
            "Athena": {
                "source": {
                    "source": "git",
                    "url": "https://github.com/HomericIntelligence/Athena.git",
                }
            }
        },
        "enabledPlugins": {"athena@Athena": True},
    }
    return json.dumps(output, indent=2, ensure_ascii=True).encode("utf-8") + b"\n"

padding_size = target_size - len(reconciled_payload())
if padding_size < 0:
    raise SystemExit("target is too small for reconciled settings")
source["padding"] = "x" * padding_size
if len(reconciled_payload()) != target_size:
    raise SystemExit("reconciled settings fixture has the wrong byte size")
path.write_bytes(
    json.dumps(source, separators=(",", ":"), ensure_ascii=True).encode("utf-8")
    + b"\n"
)
PY
}

write_fake_mnemosyne_checkout() {
    local checkout="$1"
    mkdir -p "$checkout/.git"
    printf '%s\n' \
        '[remote "origin"]' \
        '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
        > "$checkout/.git/config"
}

write_security_probe_git() {
    local path="$1" environment_marker="$2" escaped_pid="$3"
    python3 -I -S - "$path" "$environment_marker" "$escaped_pid" <<'PY'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
environment_marker = sys.argv[2]
escaped_pid = sys.argv[3]
python = str(Path(sys.executable).resolve())
path.write_text(
    """#!/bin/bash
set -eu
environment_marker={environment_marker}
escaped_pid={escaped_pid}
if [ -n \"$environment_marker\" ] \\
    && {{ [ -n \"${{AWS_ACCESS_KEY_ID:-}}\" ] \\
        || [ -n \"${{KRB5CCNAME:-}}\" ] \\
        || [ -n \"${{NETRC:-}}\" ] \\
        || [ -n \"${{GIT_LOG:-}}\" ] \\
        || [ \"${{HOME:-}}\" != /nonexistent ]; }}; then
    : > \"$environment_marker\"
fi
if [ -n \"$escaped_pid\" ] && [ ! -e \"$escaped_pid\" ]; then
    {python} -I -S -c '
import os
from pathlib import Path
import signal
import sys
import time
os.setsid()
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()), encoding="ascii")
time.sleep(5)
' \"$escaped_pid\" </dev/null >/dev/null 2>&1 &
fi
if [ -n \"$escaped_pid\" ]; then
    attempt=0
    while [ ! -s \"$escaped_pid\" ] && [ \"$attempt\" -lt 100 ]; do
        /bin/sleep 0.01
        attempt=$((attempt + 1))
    done
    /bin/sleep 0.1
fi
while :; do
    case \"${{1:-}}\" in
        -c) shift 2 ;;
        --git-dir=*|--work-tree=*) shift ;;
        *) break ;;
    esac
done
case \"${{1:-}} ${{2:-}}\" in
    'rev-parse --show-toplevel')
        if [ \"$(basename \"$PWD\")\" = .git ]; then
            (cd .. && pwd -P)
        else
            pwd -P
        fi
        ;;
    'config --file')
        case \"${{5:-}}\" in
            --get-all)
                printf '%s\\n' \\
                    https://github.com/HomericIntelligence/Mnemosyne.git
                ;;
            --get-regexp) exit 1 ;;
            *) exit 96 ;;
        esac
        ;;
    'symbolic-ref --quiet') printf '%s\\n' main ;;
    *) exit 93 ;;
esac
""".format(
    environment_marker=shlex.quote(environment_marker),
    escaped_pid=shlex.quote(escaped_pid),
    python=shlex.quote(python),
    ),
    encoding="utf-8",
)
path.chmod(0o700)
PY
}

mkdir -p "$TEST_HOME/.claude" "$FAKE_BIN" \
    "$FAKE_ROOT/shared/Hephaestus/skills/.system/skill-installer/scripts"

cat > "$SETTINGS" <<'JSON'
{
  "customSetting": true,
  "extraKnownMarketplaces": {
    "Athena": {
      "source": {
        "source": "git",
        "url": "https://example.invalid/stale-athena"
      }
    },
    "Hephaestus": {
      "source": {
        "source": "git",
        "url": "https://github.com/HomericIntelligence/Hephaestus.git"
      }
    },
    "Other": {
      "source": {
        "source": "git",
        "url": "https://example.invalid/other"
      }
    }
  },
  "enabledPlugins": {
    "athena@Athena": false,
    "hephaestus@Hephaestus": true,
    "other@Other": true
  }
}
JSON

cat > "$FAKE_BIN/claude" <<'SH'
#!/bin/bash
printf 'claude 1.2.3\n'
SH

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/git" <<'SH'
#!/bin/bash
set -eu
if [ -r '__ODYSSEUS_TEST_GIT_CONTROL__' ]; then
    # Test-only fixture state. Production must not forward these variables.
    # The absolute path is baked into this disposable fake, not read from the
    # supervised Git environment.
    . '__ODYSSEUS_TEST_GIT_CONTROL__'
fi
test_python='__ODYSSEUS_TEST_PYTHON__'
printf '%s\n' "$*" >> "$GIT_LOG"
if [ -n "${MNEMOSYNE_GIT_ENV_MARKER:-}" ]; then
    unsafe_environment=false
    for variable_name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_NAMESPACE GIT_TEMPLATE_DIR \
        GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND \
        GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_SSL_NO_VERIFY \
        GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_ATTR_SOURCE GIT_REPLACE_REF_BASE \
        HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY \
        http_proxy https_proxy all_proxy no_proxy \
        SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE \
        AWS_CA_BUNDLE NODE_EXTRA_CA_CERTS SSLKEYLOGFILE \
        GIT_CURL_VERBOSE GIT_TRACE_CURL GIT_TRACE_CURL_NO_DATA \
        GIT_HTTP_PROXY_AUTHMETHOD GIT_HTTP_LOW_SPEED_LIMIT \
        GIT_HTTP_LOW_SPEED_TIME GIT_HTTP_MAX_REQUESTS GIT_HTTP_USER_AGENT \
        GIT_SSL_CIPHER GIT_SSL_VERSION GIT_SSL_BACKEND; do
        eval 'variable_value=${'"$variable_name"':-}'
        if [ "$variable_name" = GIT_CONFIG ] \
            && [ "$variable_value" = /dev/null ]; then
            continue
        fi
        if [ -n "$variable_value" ]; then
            printf '%s=%s\n' "$variable_name" "$variable_value" \
                >> "$MNEMOSYNE_GIT_ENV_MARKER"
            unsafe_environment=true
        fi
    done
    if [ "${GIT_CONFIG_COUNT:-0}" != 0 ]; then
        printf 'GIT_CONFIG_COUNT=%s\n' "$GIT_CONFIG_COUNT" \
            >> "$MNEMOSYNE_GIT_ENV_MARKER"
        unsafe_environment=true
    fi
    $unsafe_environment || :
fi

checkout=""
bound_git_dir=""
bound_work_tree=""
canonical_url_source=""
attributes_file_disabled=false
credential_helper_disabled=false
credential_interactive_disabled=false
fsmonitor_disabled=false
hooks_disabled=false
protocol_default_disabled=false
protocol_file_disabled=false
protocol_https_enabled=false
http_ssl_verify_enabled=false
http_canonical_ssl_verify_enabled=false
http_ssl_ca_info_cleared=false
http_ssl_ca_path_cleared=false
http_proxy_cleared=false
http_canonical_proxy_cleared=false
http_curl_resolve_cleared=false
while :; do
    case "${1:-}" in
        -C)
            checkout="$2"
            shift 2
            ;;
        -c)
            case "${2:-}" in
                core.attributesFile=/dev/null)
                    attributes_file_disabled=true
                    ;;
                core.fsmonitor=false)
                    fsmonitor_disabled=true
                    ;;
                core.hooksPath=/dev/null)
                    hooks_disabled=true
                    ;;
                credential.helper=)
                    credential_helper_disabled=true
                    ;;
                credential.interactive=false)
                    credential_interactive_disabled=true
                    ;;
                protocol.allow=never)
                    protocol_default_disabled=true
                    ;;
                protocol.file.allow=never)
                    protocol_file_disabled=true
                    ;;
                protocol.https.allow=always)
                    protocol_https_enabled=true
                    ;;
                http.sslVerify=true)
                    http_ssl_verify_enabled=true
                    ;;
                http.https://github.com/HomericIntelligence/Mnemosyne.git.sslVerify=true)
                    http_canonical_ssl_verify_enabled=true
                    ;;
                http.sslCAInfo=)
                    http_ssl_ca_info_cleared=true
                    ;;
                http.sslCAPath=)
                    http_ssl_ca_path_cleared=true
                    ;;
                http.proxy=)
                    http_proxy_cleared=true
                    ;;
                http.https://github.com/HomericIntelligence/Mnemosyne.git.proxy=)
                    http_canonical_proxy_cleared=true
                    ;;
                http.curloptResolve=)
                    http_curl_resolve_cleared=true
                    ;;
            esac
            url_guard_prefix='url.https://github.com/HomericIntelligence/Mnemosyne.git.insteadOf='
            if [ "${2:-}" != "${2#"$url_guard_prefix"}" ]; then
                candidate=${2#"$url_guard_prefix"}
                suffix=${candidate#https://github.com/HomericIntelligence/Mnemosyne.git/.homeric-bound-}
                if [ "$candidate" != "$suffix" ] \
                    && [ "${#suffix}" -eq 32 ] \
                    && [[ "$suffix" =~ ^[0-9a-f]+$ ]]; then
                    canonical_url_source=$candidate
                fi
            fi
            shift 2
            ;;
        --git-dir=*)
            bound_git_dir=${1#--git-dir=}
            shift
            ;;
        --work-tree=*)
            bound_work_tree=${1#--work-tree=}
            shift
            ;;
        *) break ;;
    esac
done
if [ "${1:-}" = "clone" ]; then
    destination="${!#}"
    if [ -n "${MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER:-}" ] \
        && [ ! -e "$MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER" ]; then
        : > "$MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER"
        mkdir -p "$destination/.git"
        printf 'incomplete clone\n' > "$destination/.git/config"
        exit 81
    fi
    mkdir -p "$destination/.git"
    printf '%s\n' \
        '[remote "origin"]' \
        '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
        > "$destination/.git/config"
    exit 0
fi
[ -n "$checkout" ] || checkout="$PWD"
case "${1:-} ${2:-}" in
    'rev-parse --show-toplevel')
        if [ -n "${MNEMOSYNE_FAKE_ROOT:-}" ]; then
            printf '%s\n' "$MNEMOSYNE_FAKE_ROOT"
        elif [ "$bound_git_dir" = . ] && [ "$bound_work_tree" = .. ]; then
            (cd .. && pwd -P)
        else
            printf '%s\n' "$checkout"
        fi
        ;;
    'remote get-url')
        [ "${3:-}" = origin ] || exit 91
        printf '%s\n' "${MNEMOSYNE_FAKE_REMOTE:-https://github.com/HomericIntelligence/Mnemosyne.git}"
        ;;
    'symbolic-ref --quiet')
        [ "${3:-}" = --short ] && [ "${4:-}" = HEAD ] || exit 94
        printf '%s\n' "${MNEMOSYNE_FAKE_BRANCH:-main}"
        ;;
    'config --local')
        if [ -n "${MNEMOSYNE_CONFIG_READ_EFFECT:-}" ]; then
            printf 'repository-discovered config read\n' \
                > "$MNEMOSYNE_CONFIG_READ_EFFECT"
        fi
        [ "${3:-}" = --no-includes ] || exit 95
        case "${4:-} ${5:-}" in
            '--get-all remote.origin.url')
                printf '%s\n' "${MNEMOSYNE_FAKE_REMOTE:-https://github.com/HomericIntelligence/Mnemosyne.git}"
                if [ "${MNEMOSYNE_SWAP_CONFIG:-false}" = true ] \
                    && [ ! -e "${MNEMOSYNE_CONFIG_SWAP_MARKER:?}" ]; then
                    : > "$MNEMOSYNE_CONFIG_SWAP_MARKER"
                    mv "${MNEMOSYNE_CONFIG_PATH:?}" \
                        "${MNEMOSYNE_CONFIG_ORIGINAL:?}"
                    cp "${MNEMOSYNE_CONFIG_VICTIM:?}" \
                        "$MNEMOSYNE_CONFIG_PATH"
                fi
                ;;
            '--get-regexp ^(url\..*\.insteadOf|include\.path|includeIf\..*\.path|core\.worktree|extensions\.worktreeConfig)$')
                if [ "${MNEMOSYNE_FAKE_REWRITE:-false}" = true ]; then
                    printf '%s\n' \
                        'url.https://example.invalid/.insteadOf https://github.com/'
                    exit 0
                fi
                exit 1
                ;;
            *) exit 96 ;;
        esac
        ;;
    'config --file')
        [ "${3:-}" = ./config ] && [ "${4:-}" = --no-includes ] \
            || exit 95
        case "${5:-}" in
            --get-all)
                [ "${6:-}" = remote.origin.url ] || exit 96
                printf '%s\n' "${MNEMOSYNE_FAKE_REMOTE:-https://github.com/HomericIntelligence/Mnemosyne.git}"
                if [ "${MNEMOSYNE_SWAP_CONFIG:-false}" = true ] \
                    && [ ! -e "${MNEMOSYNE_CONFIG_SWAP_MARKER:?}" ]; then
                    : > "$MNEMOSYNE_CONFIG_SWAP_MARKER"
                    mv "${MNEMOSYNE_CONFIG_PATH:?}" \
                        "${MNEMOSYNE_CONFIG_ORIGINAL:?}"
                    cp "${MNEMOSYNE_CONFIG_VICTIM:?}" \
                        "$MNEMOSYNE_CONFIG_PATH"
                fi
                ;;
            --get-regexp)
                "$test_python" -I -S - "${3:-}" "${6:-}" <<'PY'
import re
import sys

path, pattern = sys.argv[1:]
section = ""
matched = False
with open(path, encoding="utf-8") as stream:
    for raw_line in stream:
        line = raw_line.strip()
        if not line or line.startswith(("#", ";")):
            continue
        if line.startswith("[") and line.endswith("]"):
            heading = line[1:-1].strip()
            if " " in heading:
                name, subsection = heading.split(None, 1)
                subsection = subsection.strip().strip('"')
                section = f"{name}.{subsection}".lower()
            else:
                section = heading.lower()
            continue
        if "=" not in line:
            continue
        key, value = (item.strip() for item in line.split("=", 1))
        full_key = f"{section}.{key}".lower()
        if re.fullmatch(pattern, full_key):
            print(f"{full_key} {value}")
            matched = True
raise SystemExit(0 if matched else 1)
PY
                ;;
            *) exit 96 ;;
        esac
        ;;
    'pull --ff-only')
        if [ "${3:-}" = origin ]; then
            [ "${4:-}" = main ] || exit 92
        else
            expected_source=https://github.com/HomericIntelligence/Mnemosyne.git
            if [ -n "$canonical_url_source" ]; then
                expected_source=$canonical_url_source
            fi
            [ "${3:-}" = --no-recurse-submodules ] \
                && [ "${4:-}" = "$expected_source" ] \
                && [ "${5:-}" = main ] || exit 92
        fi
        if [ -n "${MNEMOSYNE_PULL_CONTROL_EFFECT:-}" ] \
            && { [ "${GIT_CONFIG:-}" != /dev/null ] \
                || [ "${GIT_ATTR_NOSYSTEM:-}" != 1 ] \
                || [ "${GIT_TERMINAL_PROMPT:-}" != 0 ] \
                || ! $attributes_file_disabled \
                || ! $credential_helper_disabled \
                || ! $credential_interactive_disabled \
                || ! $fsmonitor_disabled \
                || ! $hooks_disabled \
                || ! $protocol_default_disabled \
                || ! $protocol_file_disabled \
                || ! $protocol_https_enabled \
                || ! $http_ssl_verify_enabled \
                || ! $http_canonical_ssl_verify_enabled \
                || ! $http_ssl_ca_info_cleared \
                || ! $http_ssl_ca_path_cleared \
                || ! $http_proxy_cleared \
                || ! $http_canonical_proxy_cleared \
                || ! $http_curl_resolve_cleared; }; then
            printf 'pull command controls incomplete\n' \
                > "$MNEMOSYNE_PULL_CONTROL_EFFECT"
        fi
        if [ -n "${MNEMOSYNE_LOCAL_CONFIG_EFFECT:-}" ]; then
            printf 'execution-capable local config reached pull\n' \
                > "$MNEMOSYNE_LOCAL_CONFIG_EFFECT"
        fi
        if [ -n "${GIT_CONFIG_PARAMETERS:-}" ] \
            && [ -n "${MNEMOSYNE_PARAMETERS_EFFECT:-}" ]; then
            printf 'GIT_CONFIG_PARAMETERS rewrite reached pull\n' \
                > "$MNEMOSYNE_PARAMETERS_EFFECT"
        fi
        if [ -n "${MNEMOSYNE_REMOTE_EFFECT:-}" ] \
            && /usr/bin/git config --file ./config --no-includes \
                --get-regexp '^url\..*\.insteadof$' >/dev/null; then
            printf 'rewritten remote used\n' > "$MNEMOSYNE_REMOTE_EFFECT"
        fi
        if [ "${MNEMOSYNE_PULL_SWAP_CONFIG:-false}" = true ] \
            && [ ! -e "${MNEMOSYNE_PULL_CONFIG_SWAP_MARKER:?}" ]; then
            : > "$MNEMOSYNE_PULL_CONFIG_SWAP_MARKER"
            mv "${MNEMOSYNE_PULL_CONFIG_PATH:?}" \
                "${MNEMOSYNE_PULL_CONFIG_ORIGINAL:?}"
            cp "${MNEMOSYNE_PULL_CONFIG_VICTIM:?}" \
                "$MNEMOSYNE_PULL_CONFIG_PATH"
            if [ "$(basename "$PWD")" != .git ] \
                || [ "$bound_git_dir" != . ] \
                || [ "$bound_work_tree" != .. ]; then
                printf 'unbound Git effect\n' \
                    > "${MNEMOSYNE_PULL_DECOY_EFFECT:?}"
            fi
            if [ -z "$canonical_url_source" ] \
                || [ "$canonical_url_source" != "${4:-}" ]; then
                printf 'replacement config redirected the remote\n' \
                    > "${MNEMOSYNE_PULL_REMOTE_EFFECT:?}"
            fi
        fi
        if [ "${MNEMOSYNE_PULL_SWAP_GITDIR:-false}" = true ] \
            && [ ! -e "${MNEMOSYNE_PULL_GITDIR_SWAP_MARKER:?}" ]; then
            : > "$MNEMOSYNE_PULL_GITDIR_SWAP_MARKER"
            mv "${MNEMOSYNE_PULL_GITDIR_PATH:?}" \
                "${MNEMOSYNE_PULL_GITDIR_ORIGINAL:?}"
            mv "${MNEMOSYNE_PULL_GITDIR_VICTIM:?}" \
                "$MNEMOSYNE_PULL_GITDIR_PATH"
            if [ "$(basename "$PWD")" != .git ] \
                || [ "$bound_git_dir" != . ] \
                || [ "$bound_work_tree" != .. ]; then
                printf 'unbound Git effect\n' \
                    > "${MNEMOSYNE_PULL_GITDIR_DECOY_EFFECT:?}"
            fi
        fi
        if [ "${MNEMOSYNE_SWAP_PATH:-false}" = true ] \
            && [ ! -e "${MNEMOSYNE_SWAP_MARKER:?}" ]; then
            : > "$MNEMOSYNE_SWAP_MARKER"
            mv "${MNEMOSYNE_NAMED_PATH:?}" "${MNEMOSYNE_ORIGINAL_PATH:?}"
            mv "${MNEMOSYNE_VICTIM_PATH:?}" "$MNEMOSYNE_NAMED_PATH"
            if [ -n "$checkout" ] && [ "$checkout" != "$PWD" ]; then
                printf 'git effect\n' > "$checkout/git-effect"
            else
                printf 'git effect\n' > ./git-effect
            fi
        fi
        if [ "${MNEMOSYNE_PULL_FAIL:-false}" = true ]; then
            exit 42
        fi
        ;;
    *) exit 93 ;;
esac
exit 0
SH

cat > "$FAKE_ROOT/shared/Hephaestus/skills/.system/skill-installer/scripts/install-skill-from-github.py" <<'PY'
import os
from pathlib import Path

Path(os.environ["SKILL_MARKER"]).write_text("invoked", encoding="utf-8")
PY

chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git"

TEST_GIT_CONTROL="$TMP/fake-git-control"
TOOLING_RUNNER="$TMP/run-claude-tooling"
python3 -I -S - \
    "$FAKE_BIN/git" "$TEST_GIT_CONTROL" "$TOOLING_RUNNER" \
    "$ROOT/scripts/install/60-claude-tooling.sh" <<'PY'
from pathlib import Path
import shlex
import sys

git_path = Path(sys.argv[1])
control_path = sys.argv[2]
runner_path = Path(sys.argv[3])
installer_path = sys.argv[4]
source = git_path.read_text(encoding="utf-8")
placeholder = "'__ODYSSEUS_TEST_GIT_CONTROL__'"
if source.count(placeholder) != 2:
    raise SystemExit("fake Git control placeholder count changed")
python_placeholder = "'__ODYSSEUS_TEST_PYTHON__'"
if source.count(python_placeholder) != 1:
    raise SystemExit("fake Git Python placeholder count changed")
git_path.write_text(
    source.replace(placeholder, shlex.quote(control_path)).replace(
        python_placeholder, shlex.quote(str(Path(sys.executable).resolve()))
    ),
    encoding="utf-8",
)
runner_path.write_text(
    """#!/bin/bash
set -uo pipefail
control={control}
: > "$control"
while IFS= read -r variable; do
    case "$variable" in
        GIT_LOG|MNEMOSYNE_*|BOUNDED_GIT_BACKING|ESCAPED_GIT_*|TOOL_GIT_BIND_*)
            declare -p "$variable" >> "$control"
            ;;
    esac
done < <(compgen -e)
chmod 600 "$control"
exec /bin/bash {installer} "$@"
""".format(
        control=shlex.quote(control_path),
        installer=shlex.quote(installer_path),
    ),
    encoding="utf-8",
)
runner_path.chmod(0o700)
PY

prepare_test_git_control() {
    local variable value
    : > "$TEST_GIT_CONTROL"
    for variable in "$@"; do
        value=${!variable-}
        printf 'declare -x %s=%q\n' "$variable" "$value" \
            >> "$TEST_GIT_CONTROL"
    done
    chmod 600 "$TEST_GIT_CONTROL"
}

info "security regressions fail before unsafe tooling effects"

SECURITY_BIND_FAILURE_HOME="$TMP/security-bind-failure-home"
SECURITY_BIND_FAILURE_BIN="$TMP/security-bind-failure-bin"
mkdir -p "$SECURITY_BIND_FAILURE_BIN"
write_canonical_settings \
    "$SECURITY_BIND_FAILURE_HOME/.claude/settings.json"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$SECURITY_BIND_FAILURE_BIN/"
cat > "$SECURITY_BIND_FAILURE_BIN/git" <<'SH'
#!/bin/sh
exit 0
SH
chmod 700 "$SECURITY_BIND_FAILURE_BIN/git"
tool_snapshot_inventory > "$TMP/tool-snapshots-before-bind-failure"
HOME="$SECURITY_BIND_FAILURE_HOME" \
PATH="$SECURITY_BIND_FAILURE_BIN:/usr/bin:/bin" \
INSTALL=false \
    /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/security-bind-failure-output" 2>&1
security_bind_failure_status=$?
tool_snapshot_inventory > "$TMP/tool-snapshots-after-bind-failure"
if [ "$security_bind_failure_status" -ne 0 ] \
    && cmp -s "$TMP/tool-snapshots-before-bind-failure" \
        "$TMP/tool-snapshots-after-bind-failure"; then
    pass "failed tool binding retires its private snapshots"
else
    fail "failed tool binding leaked a private executable snapshot"
fi

SECURITY_BIND_REPLACEMENT_HOME="$TMP/security-bind-replacement-home"
SECURITY_BIND_REPLACEMENT_BIN="$TMP/security-bind-replacement-bin"
SECURITY_BIND_REPLACEMENT_ROOT="$TMP/security-bind-replacement-installer"
SECURITY_BIND_REPLACEMENT_RECOVERY="/tmp/.odysseus-tooling-recovery-${TMP##*/}"
SECURITY_BIND_REPLACEMENT_PAYLOAD='preserve failed-bootstrap replacement'
mkdir -p "$SECURITY_BIND_REPLACEMENT_BIN" \
    "$SECURITY_BIND_REPLACEMENT_ROOT"
write_canonical_settings \
    "$SECURITY_BIND_REPLACEMENT_HOME/.claude/settings.json"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" \
    "$SECURITY_BIND_REPLACEMENT_BIN/"
cat > "$SECURITY_BIND_REPLACEMENT_BIN/git" <<'SH'
#!/bin/sh
exit 0
SH
chmod 700 "$SECURITY_BIND_REPLACEMENT_BIN/git"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SECURITY_BIND_REPLACEMENT_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" \
    "$SECURITY_BIND_REPLACEMENT_ROOT/lib.sh"
python3 -I -S - \
    "$SECURITY_BIND_REPLACEMENT_ROOT/60-claude-tooling.sh" \
    "$SECURITY_BIND_REPLACEMENT_RECOVERY" \
    "$SECURITY_BIND_REPLACEMENT_PAYLOAD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
recovery = sys.argv[2]
payload = (sys.argv[3] + "\n").encode("utf-8")
source = path.read_text(encoding="utf-8")
failure_needle = '''except BaseException:
    cleanup_error = None
    try:
'''
failure_replacement = '''except BaseException:
    os.rename(
        "git",
        "git-original",
        src_dir_fd=directory_descriptor,
        dst_dir_fd=directory_descriptor,
    )
    replacement_descriptor = os.open(
        "git",
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
        0o500,
        dir_fd=directory_descriptor,
    )
    os.write(replacement_descriptor, {payload!r})
    os.fsync(replacement_descriptor)
    os.close(replacement_descriptor)
    cleanup_error = None
    try:
'''.format(payload=payload)
raise_needle = '''    if cleanup_error is not None:
        raise ToolBindingError(
            "failed tool snapshot could not be retired exactly"
        ) from cleanup_error
    raise
finally:
'''
raise_replacement = raise_needle.replace(
    "    raise\nfinally:\n",
    "    os.rename(snapshot_directory, {recovery!r})\n"
    "    raise\n"
    "finally:\n".format(recovery=recovery),
)
if source.count(failure_needle) != 1:
    raise SystemExit("tool cleanup replacement injection point is unavailable")
if source.count(raise_needle) != 1:
    raise SystemExit("tool cleanup recovery injection point is unavailable")
source = source.replace(failure_needle, failure_replacement, 1)
source = source.replace(raise_needle, raise_replacement, 1)
path.write_text(source, encoding="utf-8")
PY
HOME="$SECURITY_BIND_REPLACEMENT_HOME" \
PATH="$SECURITY_BIND_REPLACEMENT_BIN:/usr/bin:/bin" \
INSTALL=false \
    /bin/bash "$SECURITY_BIND_REPLACEMENT_ROOT/60-claude-tooling.sh" \
    >"$TMP/security-bind-replacement-output" 2>&1
security_bind_replacement_status=$?
if [ "$security_bind_replacement_status" -ne 0 ] \
    && grep -qx "$SECURITY_BIND_REPLACEMENT_PAYLOAD" \
        "$SECURITY_BIND_REPLACEMENT_RECOVERY/git" \
    && [ -s "$SECURITY_BIND_REPLACEMENT_RECOVERY/git-original" ]; then
    pass "failed tool binding preserves a replacement entry"
else
    fail "failed tool binding deleted or changed a replacement entry"
fi
python3 -I -S - "$SECURITY_BIND_REPLACEMENT_RECOVERY" <<'PY'
import os
import stat
import sys

directory = sys.argv[1]
descriptor = os.open(
    directory,
    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_NOFOLLOW", 0),
)
try:
    for name in ("git", "git-original"):
        state = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
        if not stat.S_ISREG(state.st_mode) or state.st_uid != os.geteuid():
            raise SystemExit("unexpected tool snapshot recovery object")
        os.unlink(name, dir_fd=descriptor)
finally:
    os.close(descriptor)
os.rmdir(directory)
PY

SECURITY_BOOTSTRAP_HOME="$TMP/security-bootstrap-home"
SECURITY_BOOTSTRAP_BIN="$TMP/security-bootstrap-bin"
SECURITY_BOOTSTRAP_PYTHON_MARKER="$TMP/security-bootstrap-python"
SECURITY_BOOTSTRAP_BASH_MARKER="$TMP/security-bootstrap-bash"
SECURITY_BOOTSTRAP_GIT="$SECURITY_BOOTSTRAP_BIN/git"
SYSTEM_PYTHON3="$(command -v python3)"
mkdir -p "$SECURITY_BOOTSTRAP_BIN"
write_canonical_settings \
    "$SECURITY_BOOTSTRAP_HOME/.claude/settings.json"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$SECURITY_BOOTSTRAP_BIN/"
write_security_probe_git "$SECURITY_BOOTSTRAP_GIT" "" ""
cat > "$SECURITY_BOOTSTRAP_BIN/bash" <<'SH'
#!/bin/bash
: > "$SECURITY_BOOTSTRAP_BASH_MARKER"
exec /bin/bash "$@"
SH
cat > "$SECURITY_BOOTSTRAP_BIN/python3" <<'SH'
#!/usr/bin/env bash
: > "$SECURITY_BOOTSTRAP_PYTHON_MARKER"
exec "$SYSTEM_PYTHON3" "$@"
SH
chmod 700 "$SECURITY_BOOTSTRAP_BIN/bash" \
    "$SECURITY_BOOTSTRAP_BIN/python3"
HOME="$SECURITY_BOOTSTRAP_HOME" \
PATH="$SECURITY_BOOTSTRAP_BIN:/usr/bin:/bin" \
INSTALL=false \
SECURITY_BOOTSTRAP_BASH_MARKER="$SECURITY_BOOTSTRAP_BASH_MARKER" \
SECURITY_BOOTSTRAP_PYTHON_MARKER="$SECURITY_BOOTSTRAP_PYTHON_MARKER" \
SYSTEM_PYTHON3="$SYSTEM_PYTHON3" \
    /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/security-bootstrap-output" 2>&1
security_bootstrap_status=$?
if [ ! -e "$SECURITY_BOOTSTRAP_PYTHON_MARKER" ] \
    && [ ! -e "$SECURITY_BOOTSTRAP_BASH_MARKER" ] \
    && ! grep -q 'executable identities could not be bound' \
        "$TMP/security-bootstrap-output" \
    && { [ "$security_bootstrap_status" -eq 0 ] \
        || grep -q 'exact Git process containment is unavailable on Darwin' \
            "$TMP/security-bootstrap-output"; }; then
    pass "tool bootstrap ignores ambient Python and shebang interpreters"
else
    fail "ambient PATH code ran before the tooling trust root was established"
fi

SECURITY_INTERPRETER_HOME="$TMP/security-interpreter-home"
SECURITY_INTERPRETER_BIN="$TMP/security-interpreter-bin"
SECURITY_INTERPRETER="$SECURITY_INTERPRETER_BIN/git-interpreter"
SECURITY_INTERPRETER_MARKER="$TMP/security-interpreter-swapped"
SECURITY_INTERPRETER_POISON="$TMP/security-interpreter-poison"
mkdir -p "$SECURITY_INTERPRETER_BIN"
write_canonical_settings \
    "$SECURITY_INTERPRETER_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$SECURITY_INTERPRETER_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" \
    "$SECURITY_INTERPRETER_BIN/"
cp /bin/bash "$SECURITY_INTERPRETER"
python3 -I -S - \
    "$SECURITY_INTERPRETER_BIN/git" \
    "$SECURITY_INTERPRETER" \
    "$SECURITY_INTERPRETER_MARKER" \
    "$SECURITY_INTERPRETER_POISON" \
    "$FAKE_BIN/git" <<'PY'
from pathlib import Path
import shlex
import sys

path, interpreter, marker, poison, backing = map(Path, sys.argv[1:])
path.write_text(
    "#!{interpreter}\n"
    "set -eu\n"
    "if [ ! -e {marker} ]; then\n"
    "    : > {marker}\n"
    "    mv {interpreter} {interpreter_original}\n"
    "    cat > {interpreter} <<'POISON'\n"
    "#!/bin/bash\n"
    ": > {poison}\n"
    "exec /bin/bash \"$@\"\n"
    "POISON\n"
    "    chmod 700 {interpreter}\n"
    "fi\n"
    "exec {backing} \"$@\"\n".format(
        interpreter=shlex.quote(str(interpreter)),
        interpreter_original=shlex.quote(str(interpreter) + ".original"),
        marker=shlex.quote(str(marker)),
        poison=shlex.quote(str(poison)),
        backing=shlex.quote(str(backing)),
    ),
    encoding="utf-8",
)
path.chmod(0o700)
PY
HOME="$SECURITY_INTERPRETER_HOME" \
PATH="$SECURITY_INTERPRETER_BIN:/usr/bin:/bin" \
INSTALL=false \
GIT_LOG="$TMP/security-interpreter-git.log" \
    /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/security-interpreter-output" 2>&1
security_interpreter_status=$?
if [ ! -e "$SECURITY_INTERPRETER_POISON" ] \
    && { [ "$security_interpreter_status" -eq 0 ] \
        || grep -q 'identit\|interpreter\|containment\|bound' \
            "$TMP/security-interpreter-output"; }; then
    pass "Git execution binds or rejects every shebang interpreter"
else
    fail "a late shebang-interpreter replacement redirected Git"
fi

SECURITY_ENV_HOME="$TMP/security-env-home"
SECURITY_ENV_BIN="$TMP/security-env-bin"
SECURITY_ENV_MARKER="$TMP/security-env-leak"
mkdir -p "$SECURITY_ENV_BIN"
write_canonical_settings "$SECURITY_ENV_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$SECURITY_ENV_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$SECURITY_ENV_BIN/"
write_security_probe_git \
    "$SECURITY_ENV_BIN/git" "$SECURITY_ENV_MARKER" ""
HOME="$SECURITY_ENV_HOME" \
PATH="$SECURITY_ENV_BIN:/usr/bin:/bin" \
INSTALL=false \
AWS_ACCESS_KEY_ID=must-not-reach-git \
KRB5CCNAME="$TMP/host-krb-cache" \
NETRC="$TMP/host-netrc" \
GIT_LOG="$TMP/host-git-log" \
    /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/security-env-output" 2>&1
security_env_status=$?
if [ ! -e "$SECURITY_ENV_MARKER" ] \
    && ! grep -q 'executable identities could not be bound' \
        "$TMP/security-env-output" \
    && { [ "$security_env_status" -eq 0 ] \
        || grep -q \
            'containment is unavailable\|canonical Mnemosyne.*unavailable' \
            "$TMP/security-env-output"; }; then
    pass "Mnemosyne Git receives only its from-empty allowlisted environment"
else
    fail "ambient credentials, home, or test logging reached Mnemosyne Git"
fi

SECURITY_READONLY_HOME="$TMP/security-readonly-home"
SECURITY_READONLY_BIN="$TMP/security-readonly-bin"
SECURITY_READONLY_ROOT="$TMP/security-readonly-installer"
SECURITY_READONLY_MARKER="$TMP/security-readonly-environment"
mkdir -p "$SECURITY_READONLY_BIN" "$SECURITY_READONLY_ROOT"
write_canonical_settings \
    "$SECURITY_READONLY_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$SECURITY_READONLY_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$SECURITY_READONLY_BIN/"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SECURITY_READONLY_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$SECURITY_READONLY_ROOT/lib.sh"
python3 -I -S - \
    "$SECURITY_READONLY_ROOT/60-claude-tooling.sh" \
    "$SECURITY_READONLY_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
source = path.read_text(encoding="utf-8")
needle = '''class GitSupervisorError(RuntimeError):
    pass


git_path = sys.argv[1]
'''
replacement = '''class GitSupervisorError(RuntimeError):
    pass


if "AWS_ACCESS_KEY_ID" in os.environ:
    with open({marker!r}, "w", encoding="ascii") as stream:
        stream.write("leaked\\n")

git_path = sys.argv[1]
'''.format(marker=marker)
if source.count(needle) != 1:
    raise SystemExit("Git supervisor environment injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
HOME="$SECURITY_READONLY_HOME" \
PATH="$SECURITY_READONLY_BIN:/usr/bin:/bin" \
INSTALL=false \
    /bin/bash -c \
    'export AWS_ACCESS_KEY_ID=must-not-reach-supervisor; readonly AWS_ACCESS_KEY_ID; source "$1"' \
    _ "$SECURITY_READONLY_ROOT/60-claude-tooling.sh" \
    >"$TMP/security-readonly-output" 2>&1
security_readonly_status=$?
if [ ! -e "$SECURITY_READONLY_MARKER" ] \
    && ! grep -q 'executable identities could not be bound' \
        "$TMP/security-readonly-output" \
    && { [ "$security_readonly_status" -eq 0 ] \
        || grep -q 'exact Git process containment is unavailable on Darwin' \
            "$TMP/security-readonly-output"; }; then
    pass "trusted Python starts from an empty environment"
else
    fail "a readonly exported credential reached trusted Python"
fi

SECURITY_ESCAPE_HOME="$TMP/security-escape-home"
SECURITY_ESCAPE_BIN="$TMP/security-escape-bin"
SECURITY_ESCAPE_PID="$TMP/security-escape.pid"
mkdir -p "$SECURITY_ESCAPE_BIN"
write_canonical_settings "$SECURITY_ESCAPE_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$SECURITY_ESCAPE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$SECURITY_ESCAPE_BIN/"
write_security_probe_git \
    "$SECURITY_ESCAPE_BIN/git" "" "$SECURITY_ESCAPE_PID"
HOME="$SECURITY_ESCAPE_HOME" \
PATH="$SECURITY_ESCAPE_BIN:/usr/bin:/bin" \
INSTALL=false \
    /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/security-escape-output" 2>&1
security_escape_status=$?
security_escape_process=""
if [ -s "$SECURITY_ESCAPE_PID" ]; then
    read -r security_escape_process < "$SECURITY_ESCAPE_PID"
fi
security_escape_extinct=false
if [ -z "$security_escape_process" ]; then
    security_escape_extinct=true
elif wait_for_test_process_exit "$security_escape_process"; then
    security_escape_extinct=true
fi
if [ "$security_escape_status" -ne 0 ] && $security_escape_extinct; then
    pass "unsupported or escaped Git descendants fail closed and are extinct"
else
    fail "Mnemosyne Git returned without proving descendant extinction"
fi
if [ -n "$security_escape_process" ] \
    && process_is_live "$security_escape_process"; then
    if ! kill -KILL "$security_escape_process" 2>/dev/null; then :; fi
fi
if [ "$(uname -s)" = Darwin ]; then
    if [ ! -e "$SECURITY_ESCAPE_PID" ] \
        && grep -Eq \
            'exact Git process containment is unavailable on Darwin|canonical Mnemosyne.*unavailable' \
            "$TMP/security-escape-output"; then
        pass "Darwin rejects Mnemosyne Git before process creation"
    else
        fail "Darwin attempted Mnemosyne Git without exact containment"
    fi
else
    pass "Darwin host validation owns its pre-execution Git rejection"
fi

SECURITY_INTERRUPT_HOME="$TMP/security-interrupt-home"
SECURITY_INTERRUPT_BIN="$TMP/security-interrupt-bin"
SECURITY_INTERRUPT_PID="$TMP/security-interrupt-child.pid"
SECURITY_INTERRUPT_STARTED="$TMP/security-interrupt-started"
mkdir -p "$SECURITY_INTERRUPT_BIN"
write_canonical_settings \
    "$SECURITY_INTERRUPT_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$SECURITY_INTERRUPT_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$SECURITY_INTERRUPT_BIN/"
python3 -I -S - \
    "$SECURITY_INTERRUPT_BIN/git" \
    "$SECURITY_INTERRUPT_PID" \
    "$SECURITY_INTERRUPT_STARTED" <<'PY'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
pid_path = sys.argv[2]
started_path = sys.argv[3]
python = str(Path(sys.executable).resolve())
path.write_text(
    """#!/bin/bash
set -eu
{python} -I -S -c '
import os
from pathlib import Path
import signal
import sys
import time
os.setsid()
signal.signal(signal.SIGHUP, signal.SIG_IGN)
signal.signal(signal.SIGINT, signal.SIG_IGN)
signal.signal(signal.SIGTERM, signal.SIG_IGN)
Path(sys.argv[1]).write_text(str(os.getpid()), encoding="ascii")
time.sleep(30)
' {pid_path} </dev/null >/dev/null 2>&1 &
: > {started_path}
sleep 30
    """.format(
        pid_path=shlex.quote(pid_path),
        started_path=shlex.quote(started_path),
        python=shlex.quote(python),
    ),
    encoding="utf-8",
)
path.chmod(0o700)
PY
if [ "$(uname -s)" = Linux ] && [ -x /usr/bin/setsid ]; then
    HOME="$SECURITY_INTERRUPT_HOME" \
    PATH="$SECURITY_INTERRUPT_BIN:/usr/bin:/bin" \
    INSTALL=false \
        /usr/bin/setsid /bin/bash \
        "$ROOT/scripts/install/60-claude-tooling.sh" \
        >"$TMP/security-interrupt-output" 2>&1 &
    security_interrupt_supervisor=$!
    security_interrupt_target="-$security_interrupt_supervisor"
else
    HOME="$SECURITY_INTERRUPT_HOME" \
    PATH="$SECURITY_INTERRUPT_BIN:/usr/bin:/bin" \
    INSTALL=false \
        /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
        >"$TMP/security-interrupt-output" 2>&1 &
    security_interrupt_supervisor=$!
    security_interrupt_target="$security_interrupt_supervisor"
fi
security_interrupt_attempt=0
while [ "$security_interrupt_attempt" -lt 100 ] \
    && [ ! -e "$SECURITY_INTERRUPT_STARTED" ]; do
    sleep 0.02
    security_interrupt_attempt=$((security_interrupt_attempt + 1))
done
if ! kill -TERM -- "$security_interrupt_target" 2>/dev/null; then :; fi
security_interrupt_wait=0
while [ "$security_interrupt_wait" -lt 100 ] \
    && process_is_live "$security_interrupt_supervisor"; do
    sleep 0.02
    security_interrupt_wait=$((security_interrupt_wait + 1))
done
if process_is_live "$security_interrupt_supervisor"; then
    if ! kill -KILL "$security_interrupt_supervisor" 2>/dev/null; then :; fi
fi
if ! wait "$security_interrupt_supervisor" 2>/dev/null; then :; fi
security_interrupt_child=""
if [ -s "$SECURITY_INTERRUPT_PID" ]; then
    read -r security_interrupt_child < "$SECURITY_INTERRUPT_PID"
fi
if [ ! -e "$SECURITY_INTERRUPT_STARTED" ] \
    || [ -z "$security_interrupt_child" ] \
    || wait_for_test_process_exit "$security_interrupt_child"; then
    pass "Git interruption fails before execution or extinguishes descendants"
else
    fail "interrupting Git supervision left an escaped descendant alive"
    if ! kill -KILL "$security_interrupt_child" 2>/dev/null; then :; fi
fi

SECURITY_TRANSACTION_HOME="$TMP/security-transaction-home"
SECURITY_TRANSACTION_SETTINGS="$SECURITY_TRANSACTION_HOME/.claude/settings.json"
SECURITY_TRANSACTION_ROOT="$TMP/security-transaction-installer"
SECURITY_TRANSACTION_SAVED="$SECURITY_TRANSACTION_HOME/.claude/.source-saved"
SECURITY_TRANSACTION_FOREIGN='preserve post-exchange foreign object'
mkdir -p "$SECURITY_TRANSACTION_HOME/.claude" \
    "$SECURITY_TRANSACTION_HOME/.agent_brain/knowledge/.git" \
    "$SECURITY_TRANSACTION_ROOT"
cat > "$SECURITY_TRANSACTION_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {},
  "preserve": "original settings"
}
JSON
cp "$SECURITY_TRANSACTION_SETTINGS" \
    "$TMP/security-transaction-original.json"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SECURITY_TRANSACTION_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$SECURITY_TRANSACTION_ROOT/lib.sh"
python3 -I -S - \
    "$SECURITY_TRANSACTION_ROOT/60-claude-tooling.sh" \
    "$SECURITY_TRANSACTION_FOREIGN" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
foreign = sys.argv[2]
source = path.read_text(encoding="utf-8")
needle = """        verify_named_payload(
            parent_descriptor,
            output_name,
            source_state,
            source_payload,
            stat.S_IMODE(source_state.st_mode),
        )
"""
replacement = """        os.rename(
            output_name,
            ".source-saved",
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        foreign_descriptor = os.open(
            output_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_descriptor,
        )
        os.write(foreign_descriptor, {payload!r})
        os.fsync(foreign_descriptor)
        os.close(foreign_descriptor)
""".format(payload=(foreign + "\n").encode("utf-8")) + needle
if source.count(needle) < 1:
    raise SystemExit("settings transaction injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
HOME="$SECURITY_TRANSACTION_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
GIT_LOG="$TMP/security-transaction-git.log" \
    /bin/bash "$SECURITY_TRANSACTION_ROOT/60-claude-tooling.sh" \
    >"$TMP/security-transaction-output" 2>&1
security_transaction_status=$?
security_transaction_foreign_count=$(
    grep -rlx "$SECURITY_TRANSACTION_FOREIGN" \
        "$SECURITY_TRANSACTION_HOME/.claude" 2>/dev/null | wc -l | tr -d ' '
)
if [ "$security_transaction_status" -ne 0 ] \
    && ! grep -qx "$SECURITY_TRANSACTION_FOREIGN" \
        "$SECURITY_TRANSACTION_SETTINGS" \
    && cmp -s "$SECURITY_TRANSACTION_SAVED" \
        "$TMP/security-transaction-original.json" \
    && [ "$security_transaction_foreign_count" -eq 1 ]; then
    pass "settings rollback never promotes or deletes a late foreign object"
else
    fail "settings rollback promoted or lost a post-exchange replacement"
fi

SECURITY_EARLY_TRANSACTION_HOME="$TMP/security-early-transaction-home"
SECURITY_EARLY_TRANSACTION_SETTINGS="$SECURITY_EARLY_TRANSACTION_HOME/.claude/settings.json"
SECURITY_EARLY_TRANSACTION_ROOT="$TMP/security-early-transaction-installer"
SECURITY_EARLY_TRANSACTION_SAVED="$SECURITY_EARLY_TRANSACTION_HOME/.claude/.source-saved-early"
SECURITY_EARLY_TRANSACTION_FOREIGN='preserve unbound exchange object'
mkdir -p "$SECURITY_EARLY_TRANSACTION_HOME/.claude" \
    "$SECURITY_EARLY_TRANSACTION_HOME/.agent_brain/knowledge/.git" \
    "$SECURITY_EARLY_TRANSACTION_ROOT"
cat > "$SECURITY_EARLY_TRANSACTION_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {},
  "preserve": "original early transaction settings"
}
JSON
cp "$SECURITY_EARLY_TRANSACTION_SETTINGS" \
    "$TMP/security-early-transaction-original.json"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SECURITY_EARLY_TRANSACTION_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$SECURITY_EARLY_TRANSACTION_ROOT/lib.sh"
python3 -I -S - \
    "$SECURITY_EARLY_TRANSACTION_ROOT/60-claude-tooling.sh" \
    "$SECURITY_EARLY_TRANSACTION_FOREIGN" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
foreign = sys.argv[2]
source = path.read_text(encoding="utf-8")
needle = '''        rename_with_flags(
            parent_descriptor,
            output_name,
            parent_descriptor,
            settings_name,
            "exchange",
        )
        exchanged = True
        displaced_state = named_state(parent_descriptor, output_name)
'''
replacement = needle.replace(
    "        displaced_state = named_state(parent_descriptor, output_name)\n",
    '''        os.rename(
            output_name,
            ".source-saved-early",
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        foreign_descriptor = os.open(
            output_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_descriptor,
        )
        os.write(foreign_descriptor, {payload!r})
        os.fsync(foreign_descriptor)
        os.close(foreign_descriptor)
        displaced_state = named_state(parent_descriptor, output_name)
'''.format(payload=(foreign + "\n").encode("utf-8")),
)
if source.count(needle) != 1:
    raise SystemExit("early settings transaction injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
HOME="$SECURITY_EARLY_TRANSACTION_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
GIT_LOG="$TMP/security-early-transaction-git.log" \
    /bin/bash "$SECURITY_EARLY_TRANSACTION_ROOT/60-claude-tooling.sh" \
    >"$TMP/security-early-transaction-output" 2>&1
security_early_transaction_status=$?
security_early_transaction_foreign_count=$(
    grep -rlx "$SECURITY_EARLY_TRANSACTION_FOREIGN" \
        "$SECURITY_EARLY_TRANSACTION_HOME/.claude" 2>/dev/null \
        | wc -l | tr -d ' '
)
if [ "$security_early_transaction_status" -ne 0 ] \
    && ! grep -qx "$SECURITY_EARLY_TRANSACTION_FOREIGN" \
        "$SECURITY_EARLY_TRANSACTION_SETTINGS" \
    && cmp -s "$SECURITY_EARLY_TRANSACTION_SAVED" \
        "$TMP/security-early-transaction-original.json" \
    && [ "$security_early_transaction_foreign_count" -eq 1 ]; then
    pass "settings rollback never promotes an unbound exchanged object"
else
    fail "settings rollback promoted or lost an unbound exchanged object"
fi

SECURITY_COLLISION_HOME="$TMP/security-collision-home"
SECURITY_COLLISION_SETTINGS="$SECURITY_COLLISION_HOME/.claude/settings.json"
SECURITY_COLLISION_ROOT="$TMP/security-collision-installer"
SECURITY_COLLISION_PAYLOAD='preserve quarantine collision'
mkdir -p "$SECURITY_COLLISION_HOME/.claude" \
    "$SECURITY_COLLISION_HOME/.agent_brain/knowledge/.git" \
    "$SECURITY_COLLISION_ROOT"
cat > "$SECURITY_COLLISION_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {},
  "preserve": "original collision settings"
}
JSON
cp "$SECURITY_COLLISION_SETTINGS" \
    "$TMP/security-collision-original.json"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SECURITY_COLLISION_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$SECURITY_COLLISION_ROOT/lib.sh"
python3 -I -S - \
    "$SECURITY_COLLISION_ROOT/60-claude-tooling.sh" \
    "$SECURITY_COLLISION_PAYLOAD" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
payload = (sys.argv[2] + "\n").encode("utf-8")
source = path.read_text(encoding="utf-8")
needle = '''        quarantine_name = "settings.json.replaced." + secrets.token_hex(16)
        rename_with_flags(
'''
replacement = '''        quarantine_name = "settings.json.replaced." + secrets.token_hex(16)
        collision_descriptor = os.open(
            quarantine_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_descriptor,
        )
        os.write(collision_descriptor, {payload!r})
        os.fsync(collision_descriptor)
        os.close(collision_descriptor)
        rename_with_flags(
'''.format(payload=payload)
if source.count(needle) != 1:
    raise SystemExit("settings quarantine injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
HOME="$SECURITY_COLLISION_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
GIT_LOG="$TMP/security-collision-git.log" \
    /bin/bash "$SECURITY_COLLISION_ROOT/60-claude-tooling.sh" \
    >"$TMP/security-collision-output" 2>&1
security_collision_status=$?
security_collision_count=$(
    grep -rlx "$SECURITY_COLLISION_PAYLOAD" \
        "$SECURITY_COLLISION_HOME/.claude" 2>/dev/null | wc -l | tr -d ' '
)
if [ "$security_collision_status" -ne 0 ] \
    && cmp -s "$SECURITY_COLLISION_SETTINGS" \
        "$TMP/security-collision-original.json" \
    && [ "$security_collision_count" -eq 1 ]; then
    pass "quarantine collision rolls back without losing either object"
else
    fail "quarantine collision escaped the settings transaction"
fi

SECURITY_DURABILITY_HOME="$TMP/security-durability-home"
SECURITY_DURABILITY_SETTINGS="$SECURITY_DURABILITY_HOME/.claude/settings.json"
SECURITY_DURABILITY_ROOT="$TMP/security-durability-installer"
mkdir -p "$SECURITY_DURABILITY_HOME/.claude" \
    "$SECURITY_DURABILITY_HOME/.agent_brain/knowledge/.git" \
    "$SECURITY_DURABILITY_ROOT"
cat > "$SECURITY_DURABILITY_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {},
  "preserve": "original durable settings"
}
JSON
cp "$SECURITY_DURABILITY_SETTINGS" \
    "$TMP/security-durability-original.json"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SECURITY_DURABILITY_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$SECURITY_DURABILITY_ROOT/lib.sh"
python3 -I -S - \
    "$SECURITY_DURABILITY_ROOT/60-claude-tooling.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
needle = '''        verify_named_payload(
            parent_descriptor,
            settings_name,
            output_state,
            output_payload,
            output_mode,
        )
        return quarantine_name
'''
replacement = needle.replace(
    "        return quarantine_name\n",
    '        os.fsync(parent_descriptor)\n'
    '        raise OSError("injected post-publication durability failure")\n'
    '        return quarantine_name\n',
)
if source.count(needle) != 1:
    raise SystemExit("settings durability injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
HOME="$SECURITY_DURABILITY_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
GIT_LOG="$TMP/security-durability-git.log" \
    /bin/bash "$SECURITY_DURABILITY_ROOT/60-claude-tooling.sh" \
    >"$TMP/security-durability-output" 2>&1
security_durability_status=$?
security_durability_outputs=$(
    grep -rl '"athena@Athena": true' \
        "$SECURITY_DURABILITY_HOME/.claude" 2>/dev/null | wc -l | tr -d ' '
)
if [ "$security_durability_status" -ne 0 ] \
    && cmp -s "$SECURITY_DURABILITY_SETTINGS" \
        "$TMP/security-durability-original.json" \
    && [ "$security_durability_outputs" -eq 1 ]; then
    pass "durability failure rolls back while preserving the prepared output"
else
    fail "post-publication durability failure escaped the settings transaction"
fi

SECURITY_CHECK_HOME="$TMP/security-check-home"
SECURITY_CHECK_BIN="$TMP/security-check-bin"
SECURITY_CHECK_MARKER="$SECURITY_CHECK_HOME/claude-version-mutated-home"
mkdir -p "$SECURITY_CHECK_BIN"
write_canonical_settings "$SECURITY_CHECK_HOME/.claude/settings.json"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$SECURITY_CHECK_BIN/"
cat > "$SECURITY_CHECK_BIN/claude" <<'SH'
#!/bin/bash
: > "$HOME/claude-version-mutated-home"
printf 'claude 1.2.3\n'
SH
chmod 700 "$SECURITY_CHECK_BIN/claude"
HOME="$SECURITY_CHECK_HOME" \
PATH="$SECURITY_CHECK_BIN:/usr/bin:/bin" \
INSTALL=false \
    /bin/bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/security-check-output" 2>&1
security_check_status=$?
if [ ! -e "$SECURITY_CHECK_MARKER" ] \
    && ! grep -q 'executable identities could not be bound' \
        "$TMP/security-check-output" \
    && { [ "$security_check_status" -eq 0 ] \
        || grep -q 'exact Git process containment is unavailable on Darwin' \
            "$TMP/security-check-output"; }; then
    pass "check-only tooling does not execute Claude against the user home"
else
    fail "check-only Claude probing mutated the real user home"
fi

if [ "${ODYSSEUS_SECURITY_RED_ONLY:-false}" = true ]; then
    summary
    if exit_code; then
        exit 0
    fi
    exit 1
fi

if [ "$(uname -s)" != Linux ]; then
    pass "Linux fixture owns sealed Git and full descendant-containment coverage"
    summary
    if exit_code; then
        exit 0
    fi
    exit 1
fi

# Legacy behavioral fixtures need per-invocation observability and race
# controls, but production now constructs Git's environment from empty. Route
# only the exact installer-under-test through a disposable fixture runner that
# bakes those controls into the fake Git executable's private control file.
bash() {
    if [ "${1:-}" = "$ROOT/scripts/install/60-claude-tooling.sh" ]; then
        shift
        "$TOOLING_RUNNER" "$@"
        return
    fi
    /bin/bash "$@"
}

info "check-only tooling inspection performs no filesystem or network writes"
CHECK_ONLY_HOME="$TMP/check-only-empty-home"
CHECK_ONLY_GIT_LOG="$TMP/check-only-git.log"
HOME="$CHECK_ONLY_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$CHECK_ONLY_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/check-only-empty-output" 2>&1
check_only_status=$?

if [ "$check_only_status" -eq 0 ]; then
    pass "check-only inspection completes"
else
    fail "check-only inspection exited $check_only_status"
fi
if [ ! -e "$CHECK_ONLY_HOME" ]; then
    pass "check-only inspection leaves an absent home unchanged"
else
    fail "check-only inspection created files in an absent home"
fi
if [ ! -s "$CHECK_ONLY_GIT_LOG" ]; then
    pass "check-only inspection performs no Git network operation"
else
    fail "check-only inspection invoked Git"
fi

EXISTING_HOME="$TMP/check-only-existing-home"
write_fake_mnemosyne_checkout "$EXISTING_HOME/.agent_brain/knowledge"
: > "$CHECK_ONLY_GIT_LOG"
existing_home_before="$(tree_fingerprint "$EXISTING_HOME")"
HOME="$EXISTING_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$CHECK_ONLY_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/check-only-existing-output" 2>&1
existing_status=$?

if [ "$existing_status" -eq 0 ]; then
    pass "check-only inspection handles an existing knowledge checkout"
else
    fail "check-only existing-checkout inspection exited $existing_status"
fi
if [ ! -e "$EXISTING_HOME/.claude" ]; then
    pass "check-only inspection does not create a Claude settings directory"
else
    fail "check-only inspection created a Claude settings directory"
fi
if [ -s "$CHECK_ONLY_GIT_LOG" ] \
    && ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' \
        "$CHECK_ONLY_GIT_LOG" \
    && [ "$(tree_fingerprint "$EXISTING_HOME")" = \
        "$existing_home_before" ]; then
    pass "check-only inspects Git and leaves the complete home unchanged"
else
    fail "check-only skipped Git inspection or changed the existing home"
fi

info "check-only validates a real main-branch checkout without mutation"
if [ ! -x /usr/bin/git ]; then
    pass "cached Linux fixture has no real Git; CI owns the real-checkout case"
else
REAL_GIT_HOME="$TMP/real-git-home"
REAL_GIT_CHECKOUT="$REAL_GIT_HOME/.agent_brain/knowledge"
REAL_GIT_BIN="$TMP/real-git-bin"
mkdir -p "$REAL_GIT_CHECKOUT" "$REAL_GIT_BIN"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$REAL_GIT_BIN/"
/usr/bin/git -C "$REAL_GIT_CHECKOUT" init -q -b main
/usr/bin/git -C "$REAL_GIT_CHECKOUT" remote add origin \
    https://github.com/HomericIntelligence/Mnemosyne.git
write_canonical_settings "$REAL_GIT_HOME/.claude/settings.json"
real_git_home_before="$(tree_fingerprint "$REAL_GIT_HOME")"
HOME="$REAL_GIT_HOME" \
PATH="$REAL_GIT_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/real-git-output" 2>&1
real_git_status=$?
if [ "$real_git_status" -eq 0 ] \
    && grep -q 'canonical checkout present' "$TMP/real-git-output" \
    && [ "$(tree_fingerprint "$REAL_GIT_HOME")" = \
        "$real_git_home_before" ]; then
    pass "real Git checkout validation is read-only and accepts exact main"
else
    fail "real Git checkout validation rejected or changed canonical state"
fi
fi

info "embedded Python ignores ambient startup customization"
ISOLATED_HOME="$TMP/isolated-python-home"
ISOLATED_HOOKS="$TMP/isolated-python-hooks"
ISOLATED_MARKER="$TMP/ambient-sitecustomize-ran"
ISOLATED_GIT_LOG="$TMP/isolated-python-git.log"
mkdir -p "$ISOLATED_HOME/.claude" \
    "$ISOLATED_HOME/.agent_brain/knowledge/.git" "$ISOLATED_HOOKS"
write_canonical_settings "$ISOLATED_HOME/.claude/settings.json"
cat > "$ISOLATED_HOOKS/sitecustomize.py" <<'PY'
import os
from pathlib import Path

Path(os.environ["ISOLATED_MARKER"]).write_text("ambient startup ran\n")
PY
HOME="$ISOLATED_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
PYTHONPATH="$ISOLATED_HOOKS" \
ISOLATED_MARKER="$ISOLATED_MARKER" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$ISOLATED_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/isolated-python-output" 2>&1
isolated_status=$?
if [ "$isolated_status" -eq 0 ] && [ ! -e "$ISOLATED_MARKER" ]; then
    pass "production Python runs isolated from PYTHONPATH and sitecustomize"
else
    fail "ambient Python startup code reached the tooling process"
fi

info "every embedded Python invocation is isolated on a successful refresh"
STRICT_PYTHON_HOME="$TMP/strict-python-home"
STRICT_PYTHON_CHECKOUT="$STRICT_PYTHON_HOME/.agent_brain/knowledge"
STRICT_PYTHON_BIN="$TMP/strict-python-bin"
STRICT_PYTHON_LOG="$TMP/strict-python.log"
STRICT_PYTHON_GIT_LOG="$TMP/strict-python-git.log"
REAL_PYTHON3="$(command -v python3)"
write_fake_mnemosyne_checkout "$STRICT_PYTHON_CHECKOUT"
write_canonical_settings "$STRICT_PYTHON_HOME/.claude/settings.json"
mkdir -p "$STRICT_PYTHON_BIN"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$STRICT_PYTHON_BIN/"
cat > "$STRICT_PYTHON_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s|%s|%s\n' "${1:-}" "${2:-}" "${3:-}" \
    >> "${STRICT_PYTHON_LOG:?}"
[ "${1:-}" = -I ] && [ "${2:-}" = -S ] && [ "${3:-}" = - ] \
    || exit 97
exec "${REAL_PYTHON3:?}" "$@"
SH
chmod +x "$STRICT_PYTHON_BIN/python3"
HOME="$STRICT_PYTHON_HOME" \
PATH="$STRICT_PYTHON_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$STRICT_PYTHON_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
STRICT_PYTHON_LOG="$STRICT_PYTHON_LOG" \
REAL_PYTHON3="$REAL_PYTHON3" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/strict-python-output" 2>&1
strict_python_status=$?
if [ "$strict_python_status" -eq 0 ] \
    && grep -q 'Mnemosyne .* up to date' "$TMP/strict-python-output" \
    && [ ! -e "$STRICT_PYTHON_LOG" ]; then
    pass "successful refresh bypasses ambient Python and uses the fixed bootstrap"
else
    fail "a successful refresh reached the ambient Python entry point"
fi

info "tool executable bindings survive later ambient PATH replacement"
PYTHON_BIND_HOME="$TMP/python-binding-home"
PYTHON_BIND_BIN="$TMP/python-binding-bin"
PYTHON_BIND_COUNT="$TMP/python-binding-count"
PYTHON_BIND_POISON_EFFECT="$TMP/python-binding-poison-effect"
PYTHON_BIND_GIT_LOG="$TMP/python-binding-git.log"
REAL_PYTHON3="$(command -v python3)"
write_fake_mnemosyne_checkout \
    "$PYTHON_BIND_HOME/.agent_brain/knowledge"
write_canonical_settings "$PYTHON_BIND_HOME/.claude/settings.json"
mkdir -p "$PYTHON_BIND_BIN"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$PYTHON_BIND_BIN/"
cat > "$PYTHON_BIND_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
count=0
if [ -f "$PYTHON_BIND_COUNT" ]; then
    read -r count < "$PYTHON_BIND_COUNT"
fi
count=$((count + 1))
printf '%s\n' "$count" > "$PYTHON_BIND_COUNT"
if [ "$count" -eq 2 ]; then
    mv "$PYTHON_BIND_ORIGINAL" "$PYTHON_BIND_ORIGINAL.initial"
    cat > "$PYTHON_BIND_ORIGINAL" <<'POISON'
#!/usr/bin/env bash
: > "$PYTHON_BIND_POISON_EFFECT"
exec "$REAL_PYTHON3" "$@"
POISON
    chmod 700 "$PYTHON_BIND_ORIGINAL"
fi
exec "$REAL_PYTHON3" "$@"
SH
chmod 700 "$PYTHON_BIND_BIN/python3"
HOME="$PYTHON_BIND_HOME" \
PATH="$PYTHON_BIND_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$PYTHON_BIND_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
PYTHON_BIND_COUNT="$PYTHON_BIND_COUNT" \
PYTHON_BIND_ORIGINAL="$PYTHON_BIND_BIN/python3" \
PYTHON_BIND_POISON_EFFECT="$PYTHON_BIND_POISON_EFFECT" \
REAL_PYTHON3="$REAL_PYTHON3" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/python-binding-output" 2>&1
python_binding_status=$?
if [ "$python_binding_status" -eq 0 ] \
    && [ ! -e "$PYTHON_BIND_COUNT" ] \
    && [ ! -e "$PYTHON_BIND_POISON_EFFECT" ]; then
    pass "embedded Python never enters the mutable PATH bootstrap"
else
    fail "the mutable PATH Python participated in bootstrap or execution"
fi

GIT_BIND_HOME="$TMP/git-binding-home"
GIT_BIND_BIN="$TMP/git-binding-bin"
TOOL_GIT_BIND_SWAP_MARKER="$TMP/git-binding-swap-marker"
TOOL_GIT_BIND_POISON_EFFECT="$TMP/git-binding-poison-effect"
GIT_BIND_LOG="$TMP/git-binding.log"
write_fake_mnemosyne_checkout "$GIT_BIND_HOME/.agent_brain/knowledge"
write_canonical_settings "$GIT_BIND_HOME/.claude/settings.json"
mkdir -p "$GIT_BIND_BIN"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$GIT_BIND_BIN/"
cp "$FAKE_BIN/git" "$GIT_BIND_BIN/git.backing"
cat > "$GIT_BIND_BIN/git" <<'SH'
#!/bin/bash
set -eu
if [ ! -e "$TOOL_GIT_BIND_SWAP_MARKER" ]; then
    : > "$TOOL_GIT_BIND_SWAP_MARKER"
    mv "$TOOL_GIT_BIND_ORIGINAL" "$TOOL_GIT_BIND_ORIGINAL.initial"
    cat > "$TOOL_GIT_BIND_ORIGINAL" <<'POISON'
#!/usr/bin/env bash
: > "$TOOL_GIT_BIND_POISON_EFFECT"
exec "$TOOL_GIT_BIND_BACKING" "$@"
POISON
    chmod 700 "$TOOL_GIT_BIND_ORIGINAL"
fi
exec "$TOOL_GIT_BIND_BACKING" "$@"
SH
chmod 700 "$GIT_BIND_BIN/git" "$GIT_BIND_BIN/git.backing"
HOME="$GIT_BIND_HOME" \
PATH="$GIT_BIND_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$GIT_BIND_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
TOOL_GIT_BIND_SWAP_MARKER="$TOOL_GIT_BIND_SWAP_MARKER" \
TOOL_GIT_BIND_ORIGINAL="$GIT_BIND_BIN/git" \
TOOL_GIT_BIND_BACKING="$GIT_BIND_BIN/git.backing" \
TOOL_GIT_BIND_POISON_EFFECT="$TOOL_GIT_BIND_POISON_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/git-binding-output" 2>&1
git_binding_status=$?
if [ ! -e "$TOOL_GIT_BIND_POISON_EFFECT" ] \
    && { [ "$git_binding_status" -eq 0 ] \
        || grep -q 'bound\|unavailable\|failed' \
            "$TMP/git-binding-output"; }; then
    pass "Mnemosyne Git binds or rejects a late executable replacement"
else
    fail "a later PATH replacement redirected Mnemosyne Git"
fi

info "Mnemosyne Git output and elapsed time have one bounded supervisor"
BOUNDED_GIT_HOME="$TMP/bounded-git-home"
BOUNDED_GIT_BIN="$TMP/bounded-git-bin"
BOUNDED_GIT_LOG="$TMP/bounded-git.log"
write_fake_mnemosyne_checkout "$BOUNDED_GIT_HOME/.agent_brain/knowledge"
write_canonical_settings "$BOUNDED_GIT_HOME/.claude/settings.json"
mkdir -p "$BOUNDED_GIT_BIN"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$BOUNDED_GIT_BIN/"
cp "$FAKE_BIN/git" "$BOUNDED_GIT_BIN/git.backing"
cat > "$BOUNDED_GIT_BIN/git" <<'SH'
#!/bin/bash
set -eu
case " $* " in
    *' rev-parse --show-toplevel '*)
        count=0
        while [ "$count" -lt 4096 ]; do
            printf '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\n'
            count=$((count + 1))
        done
        sleep 30
        ;;
    *) exec "$BOUNDED_GIT_BACKING" "$@" ;;
esac
SH
chmod 700 "$BOUNDED_GIT_BIN/git" "$BOUNDED_GIT_BIN/git.backing"
run_with_wall_deadline 8 \
    /usr/bin/env \
    HOME="$BOUNDED_GIT_HOME" \
    PATH="$BOUNDED_GIT_BIN:/usr/bin:/bin" \
    INSTALL=false \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
    GIT_LOG="$BOUNDED_GIT_LOG" \
    SKILL_MARKER="$SKILL_MARKER" \
    BOUNDED_GIT_BACKING="$BOUNDED_GIT_BIN/git.backing" \
    "$TOOLING_RUNNER" \
    >"$TMP/bounded-git-output" 2>&1
bounded_git_status=$?
if [ "$bounded_git_status" -ne 0 ] \
    && [ "$bounded_git_status" -ne 124 ]; then
    pass "Mnemosyne Git rejects flood and hang behavior within its own bound"
else
    fail "Mnemosyne Git relied on the outer test deadline for flood or hang cleanup"
fi

if [ "$(uname -s)" = Linux ]; then
    ESCAPED_GIT_HOME="$TMP/escaped-git-home"
    ESCAPED_GIT_BIN="$TMP/escaped-git-bin"
    ESCAPED_GIT_LOG="$TMP/escaped-git.log"
    ESCAPED_GIT_PID="$TMP/escaped-git.pid"
    write_fake_mnemosyne_checkout \
        "$ESCAPED_GIT_HOME/.agent_brain/knowledge"
    write_canonical_settings "$ESCAPED_GIT_HOME/.claude/settings.json"
    mkdir -p "$ESCAPED_GIT_BIN"
    cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$ESCAPED_GIT_BIN/"
    cp "$FAKE_BIN/git" "$ESCAPED_GIT_BIN/git.backing"
    cat > "$ESCAPED_GIT_BIN/git" <<'SH'
#!/bin/bash
set -eu
case " $* " in
    *' pull --ff-only '*)
        __ODYSSEUS_TEST_PYTHON__ -I -S - \
            __ODYSSEUS_TEST_PID__ <<'PY'
import os
import sys
import time

first = os.fork()
if first:
    raise SystemExit(0)
os.setsid()
second = os.fork()
if second:
    os._exit(0)
with open(sys.argv[1], "w", encoding="ascii") as stream:
    stream.write(str(os.getpid()))
time.sleep(30)
PY
        ;;
esac
exec __ODYSSEUS_TEST_BACKING__ "$@"
SH
    python3 -I -S - "$ESCAPED_GIT_BIN/git" \
        "$(command -v python3)" "$ESCAPED_GIT_PID" \
        "$ESCAPED_GIT_BIN/git.backing" <<'PY'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
replacements = {
    "__ODYSSEUS_TEST_PYTHON__": shlex.quote(sys.argv[2]),
    "__ODYSSEUS_TEST_PID__": shlex.quote(sys.argv[3]),
    "__ODYSSEUS_TEST_BACKING__": shlex.quote(sys.argv[4]),
}
for old, new in replacements.items():
    if source.count(old) != 1:
        raise SystemExit(f"escaped Git placeholder count changed: {old}")
    source = source.replace(old, new)
path.write_text(source, encoding="utf-8")
PY
    chmod 700 "$ESCAPED_GIT_BIN/git" "$ESCAPED_GIT_BIN/git.backing"
    HOME="$ESCAPED_GIT_HOME" \
    PATH="$ESCAPED_GIT_BIN:/usr/bin:/bin" \
    INSTALL=true \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
    GIT_LOG="$ESCAPED_GIT_LOG" \
    SKILL_MARKER="$SKILL_MARKER" \
        bash "$ROOT/scripts/install/60-claude-tooling.sh" \
        >"$TMP/escaped-git-output" 2>&1
    escaped_git_status=$?
    escaped_git_process=""
    if [ -f "$ESCAPED_GIT_PID" ]; then
        read -r escaped_git_process < "$ESCAPED_GIT_PID"
    fi
    if [ -n "$escaped_git_process" ] \
        && wait_for_test_process_exit "$escaped_git_process"; then
        pass "Mnemosyne Git proves escaped descendants are extinct"
    else
        fail "Mnemosyne Git left an escaped descendant alive"
        if [ -n "$escaped_git_process" ]; then
            if ! kill -KILL "$escaped_git_process" 2>/dev/null; then :; fi
        fi
    fi
    if [ "$escaped_git_status" -ne 0 ]; then
        pass "escaped Mnemosyne Git descendants make the operation fail closed"
    else
        fail "an escaped Mnemosyne Git descendant produced success"
    fi

    CLEANUP_ERROR_GIT_HOME="$TMP/cleanup-error-git-home"
    CLEANUP_ERROR_GIT_BIN="$TMP/cleanup-error-git-bin"
    CLEANUP_ERROR_GIT_PID="$TMP/cleanup-error-git.pid"
    CLEANUP_ERROR_GIT_ROOT="$TMP/cleanup-error-git-installer"
    mkdir -p "$CLEANUP_ERROR_GIT_BIN" "$CLEANUP_ERROR_GIT_ROOT"
    write_fake_mnemosyne_checkout \
        "$CLEANUP_ERROR_GIT_HOME/.agent_brain/knowledge"
    write_canonical_settings \
        "$CLEANUP_ERROR_GIT_HOME/.claude/settings.json"
    cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$CLEANUP_ERROR_GIT_BIN/"
    write_security_probe_git \
        "$CLEANUP_ERROR_GIT_BIN/git" "" "$CLEANUP_ERROR_GIT_PID"
    cp "$ROOT/scripts/install/60-claude-tooling.sh" \
        "$CLEANUP_ERROR_GIT_ROOT/60-claude-tooling.sh"
    cp "$ROOT/scripts/install/lib.sh" "$CLEANUP_ERROR_GIT_ROOT/lib.sh"
    python3 -I -S - \
        "$CLEANUP_ERROR_GIT_ROOT/60-claude-tooling.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
needle = '''    def descendants(self):
        return tuple(item for item in self.live() if item[0] != self.root)
'''
replacement = '''    def descendants(self):
        active = tuple(item for item in self.live() if item[0] != self.root)
        if active:
            raise GitSupervisorError("injected descendant inventory failure")
        return active
'''
if source.count(needle) != 1:
    raise SystemExit("Git cleanup injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
    HOME="$CLEANUP_ERROR_GIT_HOME" \
    PATH="$CLEANUP_ERROR_GIT_BIN:/usr/bin:/bin" \
    INSTALL=false \
        /bin/bash "$CLEANUP_ERROR_GIT_ROOT/60-claude-tooling.sh" \
        >"$TMP/cleanup-error-git-output" 2>&1
    cleanup_error_git_status=$?
    cleanup_error_git_process=""
    if [ -s "$CLEANUP_ERROR_GIT_PID" ]; then
        read -r cleanup_error_git_process < "$CLEANUP_ERROR_GIT_PID"
    fi
    if [ "$cleanup_error_git_status" -ne 0 ] \
        && [ -n "$cleanup_error_git_process" ] \
        && wait_for_test_process_exit "$cleanup_error_git_process"; then
        pass "Git cleanup inventory failure still extinguishes descendants"
    else
        fail "Git cleanup inventory failure left a descendant alive"
        if [ -n "$cleanup_error_git_process" ]; then
            if ! kill -KILL "$cleanup_error_git_process" 2>/dev/null; then :; fi
        fi
    fi
else
    pass "Linux CI owns exact escaped-descendant proof for Mnemosyne Git"
    pass "Linux CI owns Git cleanup-error descendant proof"
fi

info "settings publication preserves a target replaced at the commit boundary"
SETTINGS_TARGET_HOME="$TMP/settings-target-race-home"
SETTINGS_TARGET_PARENT="$SETTINGS_TARGET_HOME/.claude"
SETTINGS_TARGET="$SETTINGS_TARGET_PARENT/settings.json"
SETTINGS_TARGET_ORIGINAL="$SETTINGS_TARGET_PARENT/.settings-target-original"
SETTINGS_TARGET_MARKER="$TMP/settings-target-race-marker"
SETTINGS_TARGET_BIN="$TMP/settings-target-race-bin"
SETTINGS_TARGET_GIT_LOG="$TMP/settings-target-race-git.log"
SETTINGS_TARGET_ROOT="$TMP/settings-target-race-installer"
mkdir -p "$SETTINGS_TARGET_PARENT" \
    "$SETTINGS_TARGET_HOME/.agent_brain/knowledge/.git" \
    "$SETTINGS_TARGET_BIN" "$SETTINGS_TARGET_ROOT"
cat > "$SETTINGS_TARGET" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {},
  "preserve": "original settings"
}
JSON
cp "$SETTINGS_TARGET" "$TMP/settings-target-expected.json"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$SETTINGS_TARGET_BIN/"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$SETTINGS_TARGET_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$SETTINGS_TARGET_ROOT/lib.sh"
python3 -I -S - \
    "$SETTINGS_TARGET_ROOT/60-claude-tooling.sh" \
    "$SETTINGS_TARGET_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
source = path.read_text(encoding="utf-8")
needle = '''    exchanged = False
    displaced_state = None
    quarantine_name = None
    try:
        current_source = named_state(parent_descriptor, settings_name)
'''
replacement = '''    exchanged = False
    displaced_state = None
    quarantine_name = None
    try:
        os.rename(
            settings_name,
            ".settings-target-original",
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        victim = os.open(
            settings_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
            0o600,
            dir_fd=parent_descriptor,
        )
        os.write(victim, b"preserve late settings target\\n")
        os.fsync(victim)
        os.close(victim)
        with open({marker!r}, "w", encoding="ascii") as stream:
            stream.write("replaced\\n")
        current_source = named_state(parent_descriptor, settings_name)
'''.format(marker=marker)
if source.count(needle) != 1:
    raise SystemExit("settings target injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
HOME="$SETTINGS_TARGET_HOME" \
PATH="$SETTINGS_TARGET_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
    /bin/bash "$SETTINGS_TARGET_ROOT/60-claude-tooling.sh" \
    >"$TMP/settings-target-race-output" 2>&1
settings_target_status=$?
if [ "$settings_target_status" -ne 0 ] \
    && [ -e "$SETTINGS_TARGET_MARKER" ] \
    && grep -qx 'preserve late settings target' "$SETTINGS_TARGET" \
    && cmp -s "$SETTINGS_TARGET_ORIGINAL" \
        "$TMP/settings-target-expected.json" \
    && [ ! -s "$SETTINGS_TARGET_GIT_LOG" ]; then
    pass "settings publication rejects a late target without overwriting it"
else
    fail "settings publication overwrote or lost a late target replacement"
fi

info "failed-clone retirement uses no-replace publication and recovery"
for failed_clone_race in target source; do
    FAILED_CLONE_HOME="$TMP/failed-clone-$failed_clone_race-home"
    FAILED_CLONE_PARENT="$FAILED_CLONE_HOME/.agent_brain"
    FAILED_CLONE_CHECKOUT="$FAILED_CLONE_PARENT/knowledge"
    FAILED_CLONE_BIN="$TMP/failed-clone-$failed_clone_race-bin"
    FAILED_CLONE_GIT_LOG="$TMP/failed-clone-$failed_clone_race-git.log"
    FAILED_CLONE_FAIL_MARKER="$TMP/failed-clone-$failed_clone_race-fail"
    FAILED_CLONE_RACE_MARKER="$TMP/failed-clone-$failed_clone_race-race"
    FAILED_CLONE_RETIRED="$FAILED_CLONE_PARENT/.knowledge.clone-failed.late"
    FAILED_CLONE_ORIGINAL="$FAILED_CLONE_PARENT/.knowledge.clone-original"
    FAILED_CLONE_ROOT="$TMP/failed-clone-$failed_clone_race-installer"
    mkdir -p "$FAILED_CLONE_BIN" "$FAILED_CLONE_ROOT"
    write_canonical_settings "$FAILED_CLONE_HOME/.claude/settings.json"
    cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
        "$FAILED_CLONE_BIN/"
    cp "$ROOT/scripts/install/60-claude-tooling.sh" \
        "$FAILED_CLONE_ROOT/60-claude-tooling.sh"
    cp "$ROOT/scripts/install/lib.sh" "$FAILED_CLONE_ROOT/lib.sh"
    python3 -I -S - \
        "$FAILED_CLONE_ROOT/60-claude-tooling.sh" \
        "$failed_clone_race" "$FAILED_CLONE_RACE_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
race = sys.argv[2]
marker = sys.argv[3]
source = path.read_text(encoding="utf-8")
random_name = '''                retired_name = ".knowledge.clone-failed." + secrets.token_hex(16)'''
fixed_name = '''                retired_name = ".knowledge.clone-failed.late"'''
if source.count(random_name) != 1:
    raise SystemExit("failed-clone name injection point is unavailable")
source = source.replace(random_name, fixed_name, 1)
needle = '''def retire_failed_checkout(parent_descriptor, retired_name, expected_identity):
    rename_noreplace(parent_descriptor, "knowledge", retired_name)
'''
replacement = '''def retire_failed_checkout(parent_descriptor, retired_name, expected_identity):
    if {race!r} == "target":
        os.mkdir(retired_name, 0o700, dir_fd=parent_descriptor)
        race_state = os.stat(
            retired_name,
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    else:
        os.rename(
            "knowledge",
            ".knowledge.clone-original",
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        os.mkdir("knowledge", 0o700, dir_fd=parent_descriptor)
        race_state = os.stat(
            "knowledge",
            dir_fd=parent_descriptor,
            follow_symlinks=False,
        )
    with open({marker!r}, "w", encoding="ascii") as stream:
        stream.write(
            f"{{race_state.st_dev}}:{{race_state.st_ino}}:"
            f"{{race_state.st_uid}}:{{stat.S_IMODE(race_state.st_mode):o}}\\n"
        )
    rename_noreplace(parent_descriptor, "knowledge", retired_name)
'''.format(race=race, marker=marker)
if source.count(needle) != 1:
    raise SystemExit("failed-clone race injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
    GIT_LOG="$FAILED_CLONE_GIT_LOG" \
    MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER="$FAILED_CLONE_FAIL_MARKER" \
        prepare_test_git_control \
            GIT_LOG MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER
    HOME="$FAILED_CLONE_HOME" \
    PATH="$FAILED_CLONE_BIN:/usr/bin:/bin" \
    INSTALL=true \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
        /bin/bash "$FAILED_CLONE_ROOT/60-claude-tooling.sh" \
        >"$TMP/failed-clone-$failed_clone_race-output" 2>&1
    failed_clone_status=$?
    failed_clone_receipt=""
    if [ -f "$FAILED_CLONE_RACE_MARKER" ]; then
        read -r failed_clone_receipt < "$FAILED_CLONE_RACE_MARKER"
    fi
    if [ "$failed_clone_race" = target ]; then
        if [ "$failed_clone_status" -ne 0 ] \
            && [ -n "$failed_clone_receipt" ] \
            && [ -d "$FAILED_CLONE_RETIRED" ] \
            && [ "$(settings_directory_receipt "$FAILED_CLONE_RETIRED")" = \
                "$failed_clone_receipt" ] \
            && [ -d "$FAILED_CLONE_CHECKOUT/.git" ]; then
            pass "failed-clone retirement preserves a late target"
        else
            fail "failed-clone retirement overwrote a late target"
        fi
    elif [ "$failed_clone_status" -ne 0 ] \
        && [ -n "$failed_clone_receipt" ] \
        && [ -d "$FAILED_CLONE_CHECKOUT" ] \
        && [ "$(settings_directory_receipt "$FAILED_CLONE_CHECKOUT")" = \
            "$failed_clone_receipt" ] \
        && [ -d "$FAILED_CLONE_ORIGINAL/.git" ]; then
        pass "failed-clone retirement restores a late source replacement"
    else
        fail "failed-clone retirement moved a late source replacement"
    fi
done

info "Mnemosyne reuse is bound to the direct canonical checkout"
WRONG_REMOTE_HOME="$TMP/wrong-remote-home"
WRONG_REMOTE_LOG="$TMP/wrong-remote-git.log"
mkdir -p "$WRONG_REMOTE_HOME/.agent_brain/knowledge/.git"
write_canonical_settings "$WRONG_REMOTE_HOME/.claude/settings.json"
printf '%s\n' preserve-me > "$WRONG_REMOTE_HOME/.agent_brain/knowledge/sentinel"
wrong_remote_before="$(settings_write_fingerprint \
    "$WRONG_REMOTE_HOME/.agent_brain/knowledge/sentinel")"
HOME="$WRONG_REMOTE_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$WRONG_REMOTE_LOG" \
MNEMOSYNE_FAKE_REMOTE=https://github.com/HomericIntelligence/Other.git \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/wrong-remote-output" 2>&1
wrong_remote_status=$?
if [ "$wrong_remote_status" -ne 0 ] \
    && grep -q 'canonical Mnemosyne checkout' "$TMP/wrong-remote-output" \
    && ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' "$WRONG_REMOTE_LOG" \
    && [ "$(settings_write_fingerprint \
        "$WRONG_REMOTE_HOME/.agent_brain/knowledge/sentinel")" = \
        "$wrong_remote_before" ]; then
    pass "an unrelated checkout is rejected without mutation"
else
    fail "an unrelated checkout was accepted or mutated"
fi

WRONG_ROOT_HOME="$TMP/wrong-root-home"
WRONG_ROOT_LOG="$TMP/wrong-root-git.log"
mkdir -p "$WRONG_ROOT_HOME/.agent_brain/knowledge/.git"
write_canonical_settings "$WRONG_ROOT_HOME/.claude/settings.json"
HOME="$WRONG_ROOT_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$WRONG_ROOT_LOG" \
MNEMOSYNE_FAKE_ROOT="$TMP/different-checkout" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/wrong-root-output" 2>&1
wrong_root_status=$?
if [ "$wrong_root_status" -ne 0 ] \
    && grep -q 'canonical Mnemosyne checkout' "$TMP/wrong-root-output" \
    && ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' "$WRONG_ROOT_LOG"; then
    pass "a nested or different Git root is not accepted as Mnemosyne"
else
    fail "a different Git root was accepted as Mnemosyne"
fi

for link_mode in parent knowledge; do
    link_home="$TMP/$link_mode-link-home"
    link_target="$TMP/$link_mode-link-target"
    link_log="$TMP/$link_mode-link-git.log"
    mkdir -p "$link_home" "$link_target/knowledge/.git"
    write_canonical_settings "$link_home/.claude/settings.json"
    printf '%s\n' preserve-me > "$link_target/knowledge/sentinel"
    link_target_before="$(settings_write_fingerprint \
        "$link_target/knowledge/sentinel")"
    : > "$link_log"
    if [ "$link_mode" = parent ]; then
        ln -s "$link_target" "$link_home/.agent_brain"
    else
        mkdir -p "$link_home/.agent_brain"
        ln -s "$link_target/knowledge" \
            "$link_home/.agent_brain/knowledge"
    fi

    HOME="$link_home" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    INSTALL=true \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
    GIT_LOG="$link_log" \
    SKILL_MARKER="$SKILL_MARKER" \
        bash "$ROOT/scripts/install/60-claude-tooling.sh" \
        >"$TMP/$link_mode-link-output" 2>&1
    link_status=$?
    if [ "$link_status" -ne 0 ] \
        && grep -q 'direct directory' "$TMP/$link_mode-link-output" \
        && ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' "$link_log" \
        && [ "$(settings_write_fingerprint \
            "$link_target/knowledge/sentinel")" = \
            "$link_target_before" ]; then
        pass "$link_mode symlink is rejected without target mutation"
    else
        fail "$link_mode symlink reached the Mnemosyne effect boundary"
    fi
done

info "Mnemosyne Git operations reject ambient repository routing"
ROUTING_HOME="$TMP/routing-home"
ROUTING_CHECKOUT="$ROUTING_HOME/.agent_brain/knowledge"
ROUTING_DECOY="$TMP/routing-decoy"
ROUTING_ENV_MARKER="$TMP/routing-environment-seen"
ROUTING_GIT_LOG="$TMP/routing-git.log"
ROUTING_PARAMETERS_EFFECT="$TMP/routing-parameters-effect"
write_fake_mnemosyne_checkout "$ROUTING_CHECKOUT"
mkdir -p "$ROUTING_DECOY/git" "$ROUTING_DECOY/worktree"
write_canonical_settings "$ROUTING_HOME/.claude/settings.json"
printf 'preserve decoy\n' > "$ROUTING_DECOY/sentinel"
routing_decoy_before="$(settings_write_fingerprint "$ROUTING_DECOY/sentinel")"
HOME="$ROUTING_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$ROUTING_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
GIT_DIR="$ROUTING_DECOY/git" \
GIT_WORK_TREE="$ROUTING_DECOY/worktree" \
GIT_INDEX_FILE="$ROUTING_DECOY/index" \
GIT_CONFIG="$ROUTING_DECOY/config" \
GIT_CONFIG_COUNT=1 \
GIT_CONFIG_KEY_0=url.https://example.invalid/.insteadOf \
GIT_CONFIG_VALUE_0=https://github.com/ \
GIT_CONFIG_PARAMETERS="'url.https://example.invalid/.insteadOf'='https://github.com/'" \
GIT_EXEC_PATH="$ROUTING_DECOY/git-exec" \
GIT_NAMESPACE=hostile-namespace \
GIT_TEMPLATE_DIR="$ROUTING_DECOY/template" \
GIT_ASKPASS="$ROUTING_DECOY/git-askpass" \
SSH_ASKPASS="$ROUTING_DECOY/ssh-askpass" \
GIT_SSH="$ROUTING_DECOY/git-ssh" \
GIT_SSH_COMMAND="$ROUTING_DECOY/git-ssh --hostile" \
GIT_PROXY_COMMAND="$ROUTING_DECOY/git-proxy" \
GIT_PROTOCOL_FROM_USER=1 \
GIT_ALLOW_PROTOCOL=file:https \
GIT_SSL_NO_VERIFY=true \
GIT_SSL_CAINFO="$ROUTING_DECOY/ca.pem" \
GIT_SSL_CAPATH="$ROUTING_DECOY/ca" \
GIT_ATTR_SOURCE=hostile-attributes \
GIT_REPLACE_REF_BASE=hostile-replace-base \
HTTP_PROXY=http://enterprise-proxy.invalid:8080 \
HTTPS_PROXY=http://enterprise-proxy.invalid:8443 \
ALL_PROXY=socks5://enterprise-proxy.invalid:1080 \
NO_PROXY=github.com \
http_proxy=http://lower-proxy.invalid:8080 \
https_proxy=http://lower-proxy.invalid:8443 \
all_proxy=socks5://lower-proxy.invalid:1080 \
no_proxy=api.github.com \
SSL_CERT_FILE="$ROUTING_DECOY/hostile-cert.pem" \
SSL_CERT_DIR="$ROUTING_DECOY/hostile-cert-dir" \
CURL_CA_BUNDLE="$ROUTING_DECOY/hostile-curl-ca.pem" \
REQUESTS_CA_BUNDLE="$ROUTING_DECOY/hostile-requests-ca.pem" \
AWS_CA_BUNDLE="$ROUTING_DECOY/hostile-aws-ca.pem" \
NODE_EXTRA_CA_CERTS="$ROUTING_DECOY/hostile-node-ca.pem" \
SSLKEYLOGFILE="$ROUTING_DECOY/tls-keys.log" \
GIT_CURL_VERBOSE=1 \
GIT_TRACE_CURL="$ROUTING_DECOY/git-curl.trace" \
GIT_TRACE_CURL_NO_DATA=0 \
GIT_HTTP_PROXY_AUTHMETHOD=basic \
GIT_HTTP_LOW_SPEED_LIMIT=1 \
GIT_HTTP_LOW_SPEED_TIME=1 \
GIT_HTTP_MAX_REQUESTS=99 \
GIT_HTTP_USER_AGENT=hostile-agent \
GIT_SSL_CIPHER=hostile-cipher \
GIT_SSL_VERSION=tlsv1.0 \
GIT_SSL_BACKEND=hostile-backend \
MNEMOSYNE_GIT_ENV_MARKER="$ROUTING_ENV_MARKER" \
MNEMOSYNE_PARAMETERS_EFFECT="$ROUTING_PARAMETERS_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/routing-output" 2>&1
routing_status=$?
if [ "$routing_status" -eq 0 ] \
    && [ ! -e "$ROUTING_ENV_MARKER" ] \
    && [ ! -e "$ROUTING_PARAMETERS_EFFECT" ] \
    && [ "$(settings_write_fingerprint "$ROUTING_DECOY/sentinel")" = \
        "$routing_decoy_before" ]; then
    pass "Mnemosyne Git ignores ambient repository, network, and TLS routing"
else
    fail "ambient Git, network, or TLS routing reached the Mnemosyne operation"
fi

info "Mnemosyne pull applies bounded config and execution controls"
PULL_CONTROL_HOME="$TMP/pull-control-home"
PULL_CONTROL_CHECKOUT="$PULL_CONTROL_HOME/.agent_brain/knowledge"
PULL_CONTROL_GIT_LOG="$TMP/pull-control-git.log"
PULL_CONTROL_EFFECT="$TMP/pull-control-effect"
CONFIG_READ_EFFECT="$TMP/config-read-effect"
write_fake_mnemosyne_checkout "$PULL_CONTROL_CHECKOUT"
write_canonical_settings "$PULL_CONTROL_HOME/.claude/settings.json"
HOME="$PULL_CONTROL_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$PULL_CONTROL_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_PULL_CONTROL_EFFECT="$PULL_CONTROL_EFFECT" \
MNEMOSYNE_CONFIG_READ_EFFECT="$CONFIG_READ_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/pull-control-output" 2>&1
pull_control_status=$?
if [ "$pull_control_status" -eq 0 ] \
    && [ ! -e "$PULL_CONTROL_EFFECT" ] \
    && [ ! -e "$CONFIG_READ_EFFECT" ] \
    && grep -Fq -- \
        '--git-dir=. --work-tree=.. config --file ./config --no-includes --get-all remote.origin.url' \
        "$PULL_CONTROL_GIT_LOG" \
    && grep -Eq -- \
        'pull --ff-only --no-recurse-submodules https://github[.]com/HomericIntelligence/Mnemosyne[.]git/[.]homeric-bound-[0-9a-f]{32} main$' \
        "$PULL_CONTROL_GIT_LOG"; then
    pass "pull uses direct config reads and bounded command controls"
else
    fail "pull omitted a direct config read or bounded command control"
fi

info "Mnemosyne rejects execution-capable local Git config before pull"
EXEC_CONFIG_FAILURES="$TMP/execution-config-failures"
: > "$EXEC_CONFIG_FAILURES"
while IFS='|' read -r case_name section_name key_name key_value; do
    exec_home="$TMP/execution-config-$case_name-home"
    exec_checkout="$exec_home/.agent_brain/knowledge"
    exec_git_log="$TMP/execution-config-$case_name-git.log"
    exec_effect="$TMP/execution-config-$case_name-effect"
    write_fake_mnemosyne_checkout "$exec_checkout"
    write_canonical_settings "$exec_home/.claude/settings.json"
    printf '[%s]\n    %s = %s\n' \
        "$section_name" "$key_name" "$key_value" \
        >> "$exec_checkout/.git/config"
    HOME="$exec_home" \
    PATH="$FAKE_BIN:/usr/bin:/bin" \
    INSTALL=true \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
    GIT_LOG="$exec_git_log" \
    SKILL_MARKER="$SKILL_MARKER" \
    MNEMOSYNE_LOCAL_CONFIG_EFFECT="$exec_effect" \
        bash "$ROOT/scripts/install/60-claude-tooling.sh" \
        >"$TMP/execution-config-$case_name-output" 2>&1
    exec_status=$?
    if [ "$exec_status" -eq 0 ] \
        || grep -Eq '(^| )pull( |$)' "$exec_git_log" \
        || [ -e "$exec_effect" ]; then
        printf '%s\n' "$case_name" >> "$EXEC_CONFIG_FAILURES"
    fi
done <<'CASES'
filter-process|filter "attack"|process|/tmp/filter-process
filter-clean|filter "attack"|clean|/tmp/filter-clean
filter-smudge|filter "attack"|smudge|/tmp/filter-smudge
core-fsmonitor|core|fsmonitor|/tmp/fsmonitor
core-hooks|core|hooksPath|/tmp/hooks
core-ssh|core|sshCommand|/bin/false
credential-helper|credential|helper|!/bin/false
http-proxy|http|proxy|http://127.0.0.1:9
http-url-proxy|http "https://github.com"|proxy|http://127.0.0.1:9
http-header|http|extraHeader|X-Test: value
http-ca|http|sslCAInfo|/tmp/ca.pem
http-ca-path|http|sslCAPath|/tmp/ca
http-url-ca-path|http "https://github.com"|sslCAPath|/tmp/ca
http-cert|http|sslCert|/tmp/cert.pem
http-key|http|sslKey|/tmp/key.pem
http-ssl-verify|http|sslVerify|false
http-url-ssl-verify|http "https://github.com"|sslVerify|false
http-curl-resolve|http|curloptResolve|+github.com:443:127.0.0.1
http-url-curl-resolve|http "https://github.com"|curloptResolve|+github.com:443:127.0.0.1
remote-upload|remote "origin"|uploadpack|/bin/false
remote-proxy|remote "origin"|proxy|/bin/false
remote-receive|remote "origin"|receivepack|/bin/false
diff-command|diff "attack"|command|/bin/false
diff-textconv|diff "attack"|textconv|/bin/false
merge-driver|merge "attack"|driver|/bin/false
protocol-allow|protocol "ext"|allow|always
submodule-update|submodule "attack"|update|!/bin/false
core-attributes|core|attributesFile|/tmp/attributes
CASES
if [ ! -s "$EXEC_CONFIG_FAILURES" ]; then
    pass "execution-capable local Git config stops before pull"
else
    printf '  unsafe cases that reached pull: %s\n' \
        "$(tr '\n' ' ' < "$EXEC_CONFIG_FAILURES")" >&2
    fail "execution-capable local Git config reached pull"
fi

WRITABLE_CONFIG_HOME="$TMP/writable-config-home"
WRITABLE_CONFIG_CHECKOUT="$WRITABLE_CONFIG_HOME/.agent_brain/knowledge"
WRITABLE_CONFIG_GIT_LOG="$TMP/writable-config-git.log"
write_fake_mnemosyne_checkout "$WRITABLE_CONFIG_CHECKOUT"
write_canonical_settings "$WRITABLE_CONFIG_HOME/.claude/settings.json"
chmod 664 "$WRITABLE_CONFIG_CHECKOUT/.git/config"
writable_config_before="$(settings_write_fingerprint \
    "$WRITABLE_CONFIG_CHECKOUT/.git/config")"
HOME="$WRITABLE_CONFIG_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$WRITABLE_CONFIG_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/writable-config-output" 2>&1
writable_config_status=$?
if [ "$writable_config_status" -ne 0 ] \
    && { [ ! -e "$WRITABLE_CONFIG_GIT_LOG" ] \
        || ! grep -Eq '(^| )pull( |$)' "$WRITABLE_CONFIG_GIT_LOG"; } \
    && [ "$(settings_write_fingerprint \
        "$WRITABLE_CONFIG_CHECKOUT/.git/config")" = \
        "$writable_config_before" ]; then
    pass "a group-writable local Git config is rejected before pull"
else
    fail "a group-writable local Git config reached pull or was changed"
fi

info "Mnemosyne updates require the exact main branch"
BRANCH_HOME="$TMP/wrong-branch-home"
BRANCH_CHECKOUT="$BRANCH_HOME/.agent_brain/knowledge"
BRANCH_GIT_LOG="$TMP/wrong-branch-git.log"
write_fake_mnemosyne_checkout "$BRANCH_CHECKOUT"
write_canonical_settings "$BRANCH_HOME/.claude/settings.json"
HOME="$BRANCH_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$BRANCH_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_FAKE_BRANCH=feature \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/wrong-branch-output" 2>&1
branch_status=$?
if [ "$branch_status" -ne 0 ] \
    && ! grep -Eq '(^| )pull( |$)' "$BRANCH_GIT_LOG"; then
    pass "a non-main checkout is rejected before pull"
else
    fail "a non-main checkout reached pull"
fi

info "Mnemosyne rejects local URL rewrites before network effects"
REWRITE_HOME="$TMP/url-rewrite-home"
REWRITE_CHECKOUT="$REWRITE_HOME/.agent_brain/knowledge"
REWRITE_GIT_LOG="$TMP/url-rewrite-git.log"
REWRITE_EFFECT="$TMP/url-rewrite-effect"
write_fake_mnemosyne_checkout "$REWRITE_CHECKOUT"
write_canonical_settings "$REWRITE_HOME/.claude/settings.json"
printf '%s\n' \
    '[url "https://example.invalid/"]' \
    '    insteadOf = https://github.com/' \
    >> "$REWRITE_CHECKOUT/.git/config"
HOME="$REWRITE_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$REWRITE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_REMOTE_EFFECT="$REWRITE_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/url-rewrite-output" 2>&1
rewrite_status=$?
if [ "$rewrite_status" -ne 0 ] && [ ! -e "$REWRITE_EFFECT" ]; then
    pass "a local insteadOf rule cannot reroute the Mnemosyne remote"
else
    fail "a local insteadOf rule reached the remote operation"
fi

info "Mnemosyne config identity is revalidated before pull"
CONFIG_SWAP_HOME="$TMP/config-swap-home"
CONFIG_SWAP_CHECKOUT="$CONFIG_SWAP_HOME/.agent_brain/knowledge"
CONFIG_SWAP_PATH="$CONFIG_SWAP_CHECKOUT/.git/config"
CONFIG_SWAP_ORIGINAL="$TMP/config-swap-original"
CONFIG_SWAP_VICTIM="$TMP/config-swap-victim"
CONFIG_SWAP_MARKER="$TMP/config-swap-marker"
CONFIG_SWAP_GIT_LOG="$TMP/config-swap-git.log"
write_fake_mnemosyne_checkout "$CONFIG_SWAP_CHECKOUT"
write_canonical_settings "$CONFIG_SWAP_HOME/.claude/settings.json"
printf '%s\n' \
    '[remote "origin"]' \
    '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
    '# replacement config' > "$CONFIG_SWAP_VICTIM"
HOME="$CONFIG_SWAP_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$CONFIG_SWAP_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_SWAP_CONFIG=true \
MNEMOSYNE_CONFIG_SWAP_MARKER="$CONFIG_SWAP_MARKER" \
MNEMOSYNE_CONFIG_PATH="$CONFIG_SWAP_PATH" \
MNEMOSYNE_CONFIG_ORIGINAL="$CONFIG_SWAP_ORIGINAL" \
MNEMOSYNE_CONFIG_VICTIM="$CONFIG_SWAP_VICTIM" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/config-swap-output" 2>&1
config_swap_status=$?
if [ "$config_swap_status" -ne 0 ] \
    && ! grep -Eq '(^| )pull( |$)' "$CONFIG_SWAP_GIT_LOG" \
    && cmp -s "$CONFIG_SWAP_PATH" "$CONFIG_SWAP_VICTIM"; then
    pass "a swapped local config stops before pull without rewriting the replacement"
else
    fail "a swapped local config reached pull or was overwritten"
fi

info "Mnemosyne pull cannot redirect effects after a config swap"
PULL_CONFIG_HOME="$TMP/pull-config-swap-home"
PULL_CONFIG_CHECKOUT="$PULL_CONFIG_HOME/.agent_brain/knowledge"
PULL_CONFIG_PATH="$PULL_CONFIG_CHECKOUT/.git/config"
PULL_CONFIG_ORIGINAL="$TMP/pull-config-swap-original"
PULL_CONFIG_VICTIM="$TMP/pull-config-swap-victim"
PULL_CONFIG_MARKER="$TMP/pull-config-swap-marker"
PULL_CONFIG_GIT_LOG="$TMP/pull-config-swap-git.log"
PULL_CONFIG_DECOY="$TMP/pull-config-swap-decoy"
PULL_CONFIG_DECOY_EFFECT="$PULL_CONFIG_DECOY/git-effect"
PULL_CONFIG_REMOTE_EFFECT="$TMP/pull-config-swap-remote-effect"
write_fake_mnemosyne_checkout "$PULL_CONFIG_CHECKOUT"
write_canonical_settings "$PULL_CONFIG_HOME/.claude/settings.json"
mkdir -p "$PULL_CONFIG_DECOY"
printf 'preserve pull-time decoy\n' > "$PULL_CONFIG_DECOY/sentinel"
pull_config_decoy_before="$(settings_write_fingerprint \
    "$PULL_CONFIG_DECOY/sentinel")"
printf '%s\n' \
    '[remote "origin"]' \
    '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
    '[core]' \
    "    worktree = $PULL_CONFIG_DECOY" \
    '[url "https://example.invalid/redirected"]' \
    '    insteadOf = https://github.com/HomericIntelligence/Mnemosyne.git' \
    > "$PULL_CONFIG_VICTIM"
HOME="$PULL_CONFIG_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$PULL_CONFIG_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_PULL_SWAP_CONFIG=true \
MNEMOSYNE_PULL_CONFIG_SWAP_MARKER="$PULL_CONFIG_MARKER" \
MNEMOSYNE_PULL_CONFIG_PATH="$PULL_CONFIG_PATH" \
MNEMOSYNE_PULL_CONFIG_ORIGINAL="$PULL_CONFIG_ORIGINAL" \
MNEMOSYNE_PULL_CONFIG_VICTIM="$PULL_CONFIG_VICTIM" \
MNEMOSYNE_PULL_DECOY_EFFECT="$PULL_CONFIG_DECOY_EFFECT" \
MNEMOSYNE_PULL_REMOTE_EFFECT="$PULL_CONFIG_REMOTE_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/pull-config-swap-output" 2>&1
pull_config_status=$?
if [ "$pull_config_status" -ne 0 ] \
    && [ -e "$PULL_CONFIG_MARKER" ] \
    && [ ! -e "$PULL_CONFIG_DECOY_EFFECT" ] \
    && [ ! -e "$PULL_CONFIG_REMOTE_EFFECT" ] \
    && [ "$(settings_write_fingerprint "$PULL_CONFIG_DECOY/sentinel")" = \
        "$pull_config_decoy_before" ] \
    && cmp -s "$PULL_CONFIG_PATH" "$PULL_CONFIG_VICTIM"; then
    pass "a pull-time config swap fails without mutating its decoy worktree"
else
    fail "a pull-time config swap reached an unbound Git effect"
fi

info "a failed pull is validated before it can become a warning"
FAILED_PULL_HOME="$TMP/failed-pull-home"
FAILED_PULL_CHECKOUT="$FAILED_PULL_HOME/.agent_brain/knowledge"
FAILED_PULL_CONFIG="$FAILED_PULL_CHECKOUT/.git/config"
FAILED_PULL_ORIGINAL="$TMP/failed-pull-original"
FAILED_PULL_VICTIM="$TMP/failed-pull-victim"
FAILED_PULL_MARKER="$TMP/failed-pull-marker"
FAILED_PULL_GIT_LOG="$TMP/failed-pull-git.log"
FAILED_PULL_DECOY_EFFECT="$TMP/failed-pull-decoy-effect"
FAILED_PULL_REMOTE_EFFECT="$TMP/failed-pull-remote-effect"
write_fake_mnemosyne_checkout "$FAILED_PULL_CHECKOUT"
write_canonical_settings "$FAILED_PULL_HOME/.claude/settings.json"
printf '%s\n' \
    '[remote "origin"]' \
    '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
    '[http]' \
    '    sslVerify = false' \
    > "$FAILED_PULL_VICTIM"
HOME="$FAILED_PULL_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$FAILED_PULL_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_PULL_SWAP_CONFIG=true \
MNEMOSYNE_PULL_FAIL=true \
MNEMOSYNE_PULL_CONFIG_SWAP_MARKER="$FAILED_PULL_MARKER" \
MNEMOSYNE_PULL_CONFIG_PATH="$FAILED_PULL_CONFIG" \
MNEMOSYNE_PULL_CONFIG_ORIGINAL="$FAILED_PULL_ORIGINAL" \
MNEMOSYNE_PULL_CONFIG_VICTIM="$FAILED_PULL_VICTIM" \
MNEMOSYNE_PULL_DECOY_EFFECT="$FAILED_PULL_DECOY_EFFECT" \
MNEMOSYNE_PULL_REMOTE_EFFECT="$FAILED_PULL_REMOTE_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/failed-pull-output" 2>&1
failed_pull_status=$?
if [ "$failed_pull_status" -ne 0 ] \
    && [ -e "$FAILED_PULL_MARKER" ] \
    && grep -q 'canonical Mnemosyne checkout changed during pull' \
        "$TMP/failed-pull-output" \
    && ! grep -q 'pull failed (offline? non-fast-forward?)' \
        "$TMP/failed-pull-output" \
    && cmp -s "$FAILED_PULL_CONFIG" "$FAILED_PULL_VICTIM"; then
    pass "failed pull revalidates and propagates a changed checkout"
else
    fail "failed pull was downgraded before post-effect validation"
fi

NETWORK_FAILURE_HOME="$TMP/network-failure-home"
NETWORK_FAILURE_CHECKOUT="$NETWORK_FAILURE_HOME/.agent_brain/knowledge"
NETWORK_FAILURE_GIT_LOG="$TMP/network-failure-git.log"
write_fake_mnemosyne_checkout "$NETWORK_FAILURE_CHECKOUT"
write_canonical_settings "$NETWORK_FAILURE_HOME/.claude/settings.json"
network_failure_config_before="$(settings_write_fingerprint \
    "$NETWORK_FAILURE_CHECKOUT/.git/config")"
HOME="$NETWORK_FAILURE_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$NETWORK_FAILURE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_PULL_FAIL=true \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/network-failure-output" 2>&1
network_failure_status=$?
if [ "$network_failure_status" -eq 0 ] \
    && grep -q 'pull failed (offline? non-fast-forward?)' \
        "$TMP/network-failure-output" \
    && [ "$(settings_write_fingerprint \
        "$NETWORK_FAILURE_CHECKOUT/.git/config")" = \
        "$network_failure_config_before" ]; then
    pass "validated transport failure remains a nonfatal offline warning"
else
    fail "unchanged transport failure lost its validated warning policy"
fi

info "Mnemosyne pull remains on the bound Git directory after replacement"
PULL_GITDIR_HOME="$TMP/pull-gitdir-swap-home"
PULL_GITDIR_CHECKOUT="$PULL_GITDIR_HOME/.agent_brain/knowledge"
PULL_GITDIR_PATH="$PULL_GITDIR_CHECKOUT/.git"
PULL_GITDIR_ORIGINAL="$TMP/pull-gitdir-swap-original"
PULL_GITDIR_VICTIM="$TMP/pull-gitdir-swap-victim"
PULL_GITDIR_MARKER="$TMP/pull-gitdir-swap-marker"
PULL_GITDIR_GIT_LOG="$TMP/pull-gitdir-swap-git.log"
PULL_GITDIR_DECOY_EFFECT="$PULL_GITDIR_CHECKOUT/git-effect"
write_fake_mnemosyne_checkout "$PULL_GITDIR_CHECKOUT"
mkdir -p "$PULL_GITDIR_VICTIM"
printf '%s\n' \
    '[remote "origin"]' \
    '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
    > "$PULL_GITDIR_VICTIM/config"
printf 'preserve replacement Git directory\n' \
    > "$PULL_GITDIR_VICTIM/sentinel"
write_canonical_settings "$PULL_GITDIR_HOME/.claude/settings.json"
pull_gitdir_victim_before="$(settings_write_fingerprint \
    "$PULL_GITDIR_VICTIM/sentinel")"
HOME="$PULL_GITDIR_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$PULL_GITDIR_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_PULL_SWAP_GITDIR=true \
MNEMOSYNE_PULL_GITDIR_SWAP_MARKER="$PULL_GITDIR_MARKER" \
MNEMOSYNE_PULL_GITDIR_PATH="$PULL_GITDIR_PATH" \
MNEMOSYNE_PULL_GITDIR_ORIGINAL="$PULL_GITDIR_ORIGINAL" \
MNEMOSYNE_PULL_GITDIR_VICTIM="$PULL_GITDIR_VICTIM" \
MNEMOSYNE_PULL_GITDIR_DECOY_EFFECT="$PULL_GITDIR_DECOY_EFFECT" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/pull-gitdir-swap-output" 2>&1
pull_gitdir_status=$?
if [ "$pull_gitdir_status" -ne 0 ] \
    && [ -e "$PULL_GITDIR_MARKER" ] \
    && [ ! -e "$PULL_GITDIR_DECOY_EFFECT" ] \
    && [ "$(settings_write_fingerprint "$PULL_GITDIR_PATH/sentinel")" = \
        "$pull_gitdir_victim_before" ]; then
    pass "a pull-time Git-directory swap cannot redirect the bound effect"
else
    fail "a pull-time Git-directory swap redirected the Git effect"
fi

info "Mnemosyne verifies the bound Git directory after entering it"
ENTER_GITDIR_HOME="$TMP/enter-gitdir-swap-home"
ENTER_GITDIR_CHECKOUT="$ENTER_GITDIR_HOME/.agent_brain/knowledge"
ENTER_GITDIR_NAMED="$ENTER_GITDIR_CHECKOUT/.git"
ENTER_GITDIR_ORIGINAL="$TMP/enter-gitdir-swap-original"
ENTER_GITDIR_VICTIM="$TMP/enter-gitdir-swap-victim"
ENTER_GITDIR_MARKER="$TMP/enter-gitdir-swap-marker"
ENTER_GITDIR_BIN="$TMP/enter-gitdir-swap-bin"
ENTER_GITDIR_GIT_LOG="$TMP/enter-gitdir-swap-git.log"
ENTER_GITDIR_ROOT="$TMP/enter-gitdir-swap-installer"
write_fake_mnemosyne_checkout "$ENTER_GITDIR_CHECKOUT"
mkdir -p "$ENTER_GITDIR_VICTIM" "$ENTER_GITDIR_BIN" \
    "$ENTER_GITDIR_ROOT"
printf '%s\n' \
    '[remote "origin"]' \
    '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
    > "$ENTER_GITDIR_VICTIM/config"
printf 'preserve entered replacement\n' > "$ENTER_GITDIR_VICTIM/sentinel"
write_canonical_settings "$ENTER_GITDIR_HOME/.claude/settings.json"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$ENTER_GITDIR_BIN/"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$ENTER_GITDIR_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$ENTER_GITDIR_ROOT/lib.sh"
python3 -I -S - \
    "$ENTER_GITDIR_ROOT/60-claude-tooling.sh" \
    "$ENTER_GITDIR_NAMED" "$ENTER_GITDIR_ORIGINAL" \
    "$ENTER_GITDIR_VICTIM" "$ENTER_GITDIR_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
named, original, victim, marker = sys.argv[2:]
source = path.read_text(encoding="utf-8")
bind_needle = '''if mode == "bind":
    print(encode(record(parent, checkout, True)))
'''
bind_replacement = '''if mode == "bind":
    binding = encode(record(parent, checkout, True))
    os.rename({named!r}, {original!r})
    os.rename({victim!r}, {named!r})
    with open({marker!r}, "w", encoding="ascii") as stream:
        stream.write("1\\n")
    print(binding)
'''.format(named=named, original=original, victim=victim, marker=marker)
verify_needle = '''elif mode in {"verify", "verify-container", "verify-git"}:
    expected = decode(sys.argv[4])
'''
verify_replacement = '''elif mode in {{"verify", "verify-container", "verify-git"}}:
    if mode == "verify-git" and os.path.exists({marker!r}):
        with open({marker!r}, encoding="ascii") as stream:
            marker_value = stream.read().strip()
        if marker_value == "1":
            os.rename({named!r}, {victim!r})
            os.rename({original!r}, {named!r})
            with open({marker!r}, "w", encoding="ascii") as stream:
                stream.write("2\\n")
    expected = decode(sys.argv[4])
'''.format(marker=marker, named=named, victim=victim, original=original)
if source.count(bind_needle) != 1 or source.count(verify_needle) != 1:
    raise SystemExit("Git-directory race injection point is unavailable")
source = source.replace(bind_needle, bind_replacement, 1)
path.write_text(source.replace(verify_needle, verify_replacement, 1), encoding="utf-8")
PY
enter_gitdir_victim_before="$(settings_write_fingerprint \
    "$ENTER_GITDIR_VICTIM/sentinel")"
GIT_LOG="$ENTER_GITDIR_GIT_LOG" prepare_test_git_control GIT_LOG
HOME="$ENTER_GITDIR_HOME" \
PATH="$ENTER_GITDIR_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
    /bin/bash "$ENTER_GITDIR_ROOT/60-claude-tooling.sh" \
    >"$TMP/enter-gitdir-swap-output" 2>&1
enter_gitdir_status=$?
if [ "$enter_gitdir_status" -ne 0 ] \
    && grep -qx '2' "$ENTER_GITDIR_MARKER" \
    && [ ! -s "$ENTER_GITDIR_GIT_LOG" ] \
    && [ "$(settings_write_fingerprint "$ENTER_GITDIR_VICTIM/sentinel")" = \
        "$enter_gitdir_victim_before" ]; then
    pass "a bind-to-cd Git-directory swap fails before Git effects"
else
    fail "a bind-to-cd Git-directory swap reached Git or changed its victim"
fi

info "Mnemosyne pull remains bound when the named checkout is replaced"
SWAP_HOME="$TMP/mnemosyne-swap-home"
SWAP_NAMED="$SWAP_HOME/.agent_brain/knowledge"
SWAP_ORIGINAL="$SWAP_HOME/.agent_brain/knowledge-original"
SWAP_VICTIM="$TMP/mnemosyne-swap-victim"
SWAP_MARKER="$TMP/mnemosyne-swap-marker"
SWAP_GIT_LOG="$TMP/mnemosyne-swap-git.log"
write_fake_mnemosyne_checkout "$SWAP_NAMED"
write_fake_mnemosyne_checkout "$SWAP_VICTIM"
write_canonical_settings "$SWAP_HOME/.claude/settings.json"
printf 'preserve original\n' > "$SWAP_NAMED/sentinel"
printf 'preserve victim\n' > "$SWAP_VICTIM/sentinel"
swap_victim_before="$(settings_write_fingerprint "$SWAP_VICTIM/sentinel")"
HOME="$SWAP_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$SWAP_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_SWAP_PATH=true \
MNEMOSYNE_SWAP_MARKER="$SWAP_MARKER" \
MNEMOSYNE_NAMED_PATH="$SWAP_NAMED" \
MNEMOSYNE_ORIGINAL_PATH="$SWAP_ORIGINAL" \
MNEMOSYNE_VICTIM_PATH="$SWAP_VICTIM" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/mnemosyne-swap-output" 2>&1
swap_status=$?
if [ "$swap_status" -ne 0 ] \
    && [ -f "$SWAP_NAMED/sentinel" ] \
    && [ "$(settings_write_fingerprint "$SWAP_NAMED/sentinel")" = \
        "$swap_victim_before" ] \
    && [ ! -e "$SWAP_NAMED/git-effect" ]; then
    pass "a replacement checkout is rejected without mutating the victim"
else
    fail "Mnemosyne pull followed a replaced checkout path"
fi

info "settings paths are data, never interpolated Python source"
ATTACK_COMPONENT='home-"+str(__import__("pathlib").Path(__import__("os").environ["INJECTION_MARKER"]).write_text("owned"))+"'
WEIRD_HOME="$TMP/$ATTACK_COMPONENT"
WEIRD_SETTINGS="$WEIRD_HOME/.claude/settings.json"
INJECTION_MARKER="$TMP/python-source-injection"
mkdir -p "$WEIRD_HOME/.claude" "$WEIRD_HOME/.agent_brain/knowledge/.git"
cat > "$WEIRD_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {
    "Athena": {
      "source": {
        "source": "git",
        "url": "https://github.com/HomericIntelligence/Athena.git"
      }
    }
  },
  "enabledPlugins": {
    "athena@Athena": true
  }
}
JSON
HOME="$WEIRD_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$CHECK_ONLY_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
INJECTION_MARKER="$INJECTION_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/weird-home-output" 2>&1
weird_home_status=$?

if [ "$weird_home_status" -eq 0 ] && \
   grep -q 'settings.json .* Athena marketplace and plugin configured' \
       "$TMP/weird-home-output"; then
    pass "canonical settings are inspected through an unusual literal path"
else
    fail "unusual settings path was interpreted instead of opened literally"
fi
if [ ! -e "$INJECTION_MARKER" ]; then
    pass "settings path cannot execute injected Python"
else
    fail "settings path executed as Python source"
fi

info "tooling setup rejects a settings symlink before mutation"
SYMLINK_HOME="$TMP/settings-symlink-home"
SYMLINK_SETTINGS="$SYMLINK_HOME/.claude/settings.json"
SYMLINK_TARGET="$TMP/external-settings.json"
SYMLINK_GIT_LOG="$TMP/settings-symlink-git.log"
mkdir -p "$SYMLINK_HOME/.claude" \
    "$SYMLINK_HOME/.agent_brain/knowledge/.git"
cat > "$SYMLINK_TARGET" <<'JSON'
{
  "extraKnownMarketplaces": {
    "Athena": {
      "source": {
        "source": "git",
        "url": "https://example.invalid/stale-athena"
      }
    }
  },
  "enabledPlugins": {
    "athena@Athena": false
  }
}
JSON
ln -s "$SYMLINK_TARGET" "$SYMLINK_SETTINGS"
symlink_target_before="$(settings_write_fingerprint "$SYMLINK_TARGET")"
symlink_link_before="$(settings_link_fingerprint "$SYMLINK_SETTINGS")"
symlink_backups_before="$(settings_backup_inventory "$SYMLINK_HOME/.claude")"

HOME="$SYMLINK_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$SYMLINK_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/settings-symlink-output" 2>&1
symlink_status=$?

if [ "$symlink_status" -ne 0 ] && \
   grep -q 'settings.json .* symbolic link' "$TMP/settings-symlink-output"; then
    pass "install mode fails closed on a settings symlink"
else
    fail "install mode accepted a settings symlink"
fi
if [ "$(settings_write_fingerprint "$SYMLINK_TARGET")" = \
    "$symlink_target_before" ]; then
    pass "settings symlink rejection leaves the external target unchanged"
else
    fail "settings symlink rejection changed the external target"
fi
if [ -L "$SYMLINK_SETTINGS" ] && \
   [ "$(settings_link_fingerprint "$SYMLINK_SETTINGS")" = \
       "$symlink_link_before" ]; then
    pass "settings symlink rejection leaves the link unchanged"
else
    fail "settings symlink rejection replaced or changed the link"
fi
if [ "$(settings_backup_inventory "$SYMLINK_HOME/.claude")" = \
    "$symlink_backups_before" ]; then
    pass "settings symlink rejection leaves the backup inventory unchanged"
else
    fail "settings symlink rejection created or changed a backup"
fi
if [ ! -s "$SYMLINK_GIT_LOG" ]; then
    pass "settings symlink rejection stops before Git"
else
    fail "settings symlink rejection reached Git"
fi

info "tooling setup rejects a non-regular settings path before mutation"
NONREGULAR_HOME="$TMP/nonregular-settings-home"
NONREGULAR_SETTINGS="$NONREGULAR_HOME/.claude/settings.json"
NONREGULAR_SENTINEL="$NONREGULAR_SETTINGS/sentinel"
NONREGULAR_GIT_LOG="$TMP/nonregular-settings-git.log"
mkdir -p "$NONREGULAR_SETTINGS" \
    "$NONREGULAR_HOME/.agent_brain/knowledge/.git"
printf 'preserve this directory\n' > "$NONREGULAR_SENTINEL"
nonregular_node_before="$(settings_node_fingerprint "$NONREGULAR_SETTINGS")"
nonregular_sentinel_before="$(settings_write_fingerprint "$NONREGULAR_SENTINEL")"
nonregular_backups_before="$(
    settings_backup_inventory "$NONREGULAR_HOME/.claude"
)"

HOME="$NONREGULAR_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$NONREGULAR_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/nonregular-settings-output" 2>&1
nonregular_status=$?

if [ "$nonregular_status" -ne 0 ] && \
   grep -q 'settings.json .* regular file' \
       "$TMP/nonregular-settings-output"; then
    pass "install mode fails closed on a non-regular settings path"
else
    fail "install mode did not reject a non-regular settings path early"
fi
if [ -d "$NONREGULAR_SETTINGS" ] && \
   [ "$(settings_node_fingerprint "$NONREGULAR_SETTINGS")" = \
       "$nonregular_node_before" ] && \
   [ "$(settings_write_fingerprint "$NONREGULAR_SENTINEL")" = \
       "$nonregular_sentinel_before" ]; then
    pass "non-regular settings rejection leaves the path unchanged"
else
    fail "non-regular settings rejection changed the settings path"
fi
if [ "$(settings_backup_inventory "$NONREGULAR_HOME/.claude")" = \
    "$nonregular_backups_before" ]; then
    pass "non-regular settings rejection leaves the backup inventory unchanged"
else
    fail "non-regular settings rejection created or changed a backup"
fi
if [ ! -s "$NONREGULAR_GIT_LOG" ]; then
    pass "non-regular settings rejection stops before Git"
else
    fail "non-regular settings rejection reached Git"
fi

info "explicit install migrates the direct owner-owned legacy settings parent"
PUBLIC_PARENT_HOME="$TMP/public-settings-parent-home"
PUBLIC_PARENT_SETTINGS="$PUBLIC_PARENT_HOME/.claude/settings.json"
PUBLIC_PARENT_GIT_LOG="$TMP/public-settings-parent-git.log"
mkdir -p "$PUBLIC_PARENT_HOME/.claude" \
    "$PUBLIC_PARENT_HOME/.agent_brain/knowledge/.git"
chmod 755 "$PUBLIC_PARENT_HOME/.claude"
write_canonical_settings "$PUBLIC_PARENT_SETTINGS"
public_parent_before="$(settings_directory_receipt \
    "$PUBLIC_PARENT_HOME/.claude")"
public_settings_before="$(settings_write_fingerprint \
    "$PUBLIC_PARENT_SETTINGS")"

HOME="$PUBLIC_PARENT_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$PUBLIC_PARENT_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/public-settings-parent-check-output" 2>&1
public_parent_check_status=$?

if [ "$public_parent_check_status" -eq 0 ] \
    && grep -Eq 'mode 0755.*--install.*0700' \
        "$TMP/public-settings-parent-check-output"; then
    pass "check-only reports the legacy settings-parent remediation"
else
    fail "check-only did not report the legacy settings-parent remediation"
fi
if [ "$(settings_directory_receipt "$PUBLIC_PARENT_HOME/.claude")" = \
    "$public_parent_before" ] \
    && [ "$(settings_write_fingerprint "$PUBLIC_PARENT_SETTINGS")" = \
        "$public_settings_before" ]; then
    pass "check-only leaves the legacy settings parent and file unchanged"
else
    fail "check-only mutated the legacy settings surface"
fi

HOME="$PUBLIC_PARENT_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$PUBLIC_PARENT_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/public-settings-parent-output" 2>&1
public_parent_status=$?
public_parent_after="$(settings_directory_receipt \
    "$PUBLIC_PARENT_HOME/.claude")"
IFS=: read -r public_before_dev public_before_ino public_before_uid \
    public_before_mode <<< "$public_parent_before"
IFS=: read -r public_after_dev public_after_ino public_after_uid \
    public_after_mode <<< "$public_parent_after"

if [ "$public_parent_status" -eq 0 ] \
    && [ "$public_before_dev:$public_before_ino:$public_before_uid" = \
        "$public_after_dev:$public_after_ino:$public_after_uid" ] \
    && [ "$public_before_mode" = 755 ] \
    && [ "$public_after_mode" = 700 ]; then
    pass "install migrates the bound legacy settings parent to mode 0700"
else
    fail "install did not safely migrate the bound legacy settings parent"
fi
if [ "$(settings_write_fingerprint "$PUBLIC_PARENT_SETTINGS")" = \
    "$public_settings_before" ] \
    && [ -z "$(settings_backup_inventory "$PUBLIC_PARENT_HOME/.claude")" ]; then
    pass "mode-only migration preserves canonical settings and backup state"
else
    fail "mode-only migration rewrote canonical settings or created a backup"
fi
if grep -q 'Mnemosyne .* up to date' "$TMP/public-settings-parent-output"; then
    pass "settings-parent migration allows the remaining install to complete"
else
    fail "settings-parent migration did not restore install availability"
fi

info "tooling setup rejects a hard-linked settings source without mutation"
HARDLINK_HOME="$TMP/hardlink-settings-home"
HARDLINK_SETTINGS="$HARDLINK_HOME/.claude/settings.json"
HARDLINK_VICTIM="$TMP/hardlink-settings-victim.json"
HARDLINK_GIT_LOG="$TMP/hardlink-settings-git.log"
mkdir -p "$HARDLINK_HOME/.claude" \
    "$HARDLINK_HOME/.agent_brain/knowledge/.git"
cat > "$HARDLINK_VICTIM" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {}
}
JSON
ln "$HARDLINK_VICTIM" "$HARDLINK_SETTINGS"
hardlink_victim_before="$(settings_write_fingerprint "$HARDLINK_VICTIM")"
hardlink_settings_before="$(settings_write_fingerprint "$HARDLINK_SETTINGS")"
hardlink_backups_before="$(
    settings_backup_inventory "$HARDLINK_HOME/.claude"
)"

HOME="$HARDLINK_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$HARDLINK_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/hardlink-settings-output" 2>&1
hardlink_status=$?

if [ "$hardlink_status" -ne 0 ] && \
   grep -q 'settings.json .* one link' "$TMP/hardlink-settings-output"; then
    pass "install mode fails closed on a hard-linked settings source"
else
    fail "install mode accepted a hard-linked settings source"
fi
if [ "$HARDLINK_SETTINGS" -ef "$HARDLINK_VICTIM" ] && \
   [ "$(settings_write_fingerprint "$HARDLINK_SETTINGS")" = \
       "$hardlink_settings_before" ] && \
   [ "$(settings_write_fingerprint "$HARDLINK_VICTIM")" = \
       "$hardlink_victim_before" ]; then
    pass "hard-link rejection preserves both names and source bytes"
else
    fail "hard-link rejection replaced or changed a linked source"
fi
if [ "$(settings_backup_inventory "$HARDLINK_HOME/.claude")" = \
    "$hardlink_backups_before" ]; then
    pass "hard-link rejection creates no backup"
else
    fail "hard-link rejection created a backup"
fi
if [ ! -s "$HARDLINK_GIT_LOG" ]; then
    pass "hard-link rejection stops before Git"
else
    fail "hard-link rejection reached Git"
fi

info "tooling setup rejects a swapped settings parent without following it"
ANCESTOR_HOME="$TMP/ancestor-swap-home"
ANCESTOR_PARENT="$ANCESTOR_HOME/.claude"
ANCESTOR_ORIGINAL_PARENT="$ANCESTOR_HOME/.claude-original"
ANCESTOR_VICTIM_PARENT="$TMP/ancestor-swap-victim"
ANCESTOR_VICTIM_SETTINGS="$ANCESTOR_VICTIM_PARENT/settings.json"
ANCESTOR_GIT_LOG="$TMP/ancestor-swap-git.log"
ANCESTOR_SWAP_MARKER="$TMP/ancestor-swap-marker"
ANCESTOR_BIN="$TMP/ancestor-swap-bin"
ANCESTOR_ROOT="$TMP/ancestor-swap-installer"
mkdir -p "$ANCESTOR_PARENT" "$ANCESTOR_VICTIM_PARENT" \
    "$ANCESTOR_HOME/.agent_brain/knowledge/.git" "$ANCESTOR_BIN" \
    "$ANCESTOR_ROOT"
cat > "$ANCESTOR_PARENT/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {}
}
JSON
cp "$ANCESTOR_PARENT/settings.json" "$ANCESTOR_VICTIM_SETTINGS"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" "$ANCESTOR_BIN/"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$ANCESTOR_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$ANCESTOR_ROOT/lib.sh"
python3 -I -S - \
    "$ANCESTOR_ROOT/60-claude-tooling.sh" \
    "$ANCESTOR_PARENT" "$ANCESTOR_ORIGINAL_PARENT" \
    "$ANCESTOR_VICTIM_PARENT" "$ANCESTOR_SWAP_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
parent, original, victim, marker = sys.argv[2:]
source = path.read_text(encoding="utf-8")
needle = '''def reconcile():
    expected_binding = parse_expected_binding(expected_binding_text)
    (
'''
replacement = '''def reconcile():
    expected_binding = parse_expected_binding(expected_binding_text)
    os.rename({parent!r}, {original!r})
    os.rename({victim!r}, {parent!r})
    with open({marker!r}, "w", encoding="ascii") as stream:
        stream.write("swapped\\n")
    (
'''.format(parent=parent, original=original, victim=victim, marker=marker)
if source.count(needle) != 1:
    raise SystemExit("settings-parent injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY
ancestor_original_before="$(
    settings_write_fingerprint "$ANCESTOR_PARENT/settings.json"
)"
ancestor_victim_before="$(
    settings_write_fingerprint "$ANCESTOR_VICTIM_SETTINGS"
)"

HOME="$ANCESTOR_HOME" \
PATH="$ANCESTOR_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
    /bin/bash "$ANCESTOR_ROOT/60-claude-tooling.sh" \
    >"$TMP/ancestor-swap-output" 2>&1
ancestor_status=$?

if [ "$ancestor_status" -ne 0 ] && \
   grep -q 'settings.json parent' "$TMP/ancestor-swap-output"; then
    pass "install mode fails closed when the direct settings parent is swapped"
else
    fail "install mode followed a swapped settings parent"
fi
if [ -d "$ANCESTOR_PARENT" ] && \
   [ "$(settings_write_fingerprint \
       "$ANCESTOR_ORIGINAL_PARENT/settings.json")" = \
       "$ancestor_original_before" ] && \
   [ "$(settings_write_fingerprint "$ANCESTOR_PARENT/settings.json")" = \
       "$ancestor_victim_before" ]; then
    pass "ancestor-swap rejection preserves original and victim bytes"
else
    fail "ancestor-swap rejection changed an original or victim file"
fi
if [ ! -s "$ANCESTOR_GIT_LOG" ]; then
    pass "ancestor-swap rejection stops before Git"
else
    fail "ancestor-swap rejection reached Git"
fi

info "a failed settings publication retains artifacts without name-based cleanup"
TEMP_FAILURE_HOME="$TMP/settings-temp-failure-home"
TEMP_FAILURE_SETTINGS="$TEMP_FAILURE_HOME/.claude/settings.json"
TEMP_FAILURE_ORIGINAL="$TMP/settings-temp-failure-original.json"
TEMP_FAILURE_GIT_LOG="$TMP/settings-temp-failure-git.log"
TEMP_FAILURE_BIN="$TMP/settings-temp-failure-bin"
TEMP_FAILURE_MARKER="$TMP/settings-temp-failure-name"
TEMP_FAILURE_ROOT="$TMP/settings-temp-failure-installer"
mkdir -p "$TEMP_FAILURE_HOME/.claude" \
    "$TEMP_FAILURE_HOME/.agent_brain/knowledge/.git" \
    "$TEMP_FAILURE_BIN" "$TEMP_FAILURE_ROOT"
: > "$TEMP_FAILURE_GIT_LOG"
cat > "$TEMP_FAILURE_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {}
}
JSON
cp "$TEMP_FAILURE_SETTINGS" "$TEMP_FAILURE_ORIGINAL"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$TEMP_FAILURE_BIN/"
cp "$ROOT/scripts/install/60-claude-tooling.sh" \
    "$TEMP_FAILURE_ROOT/60-claude-tooling.sh"
cp "$ROOT/scripts/install/lib.sh" "$TEMP_FAILURE_ROOT/lib.sh"
python3 -I -S - \
    "$TEMP_FAILURE_ROOT/60-claude-tooling.sh" \
    "$TEMP_FAILURE_MARKER" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
source = path.read_text(encoding="utf-8")
needle = '''        publish_settings_atomically(
'''
replacement = '''        os.rename(
            output_name,
            ".retained-settings-output",
            src_dir_fd=parent_descriptor,
            dst_dir_fd=parent_descriptor,
        )
        victim_descriptor = os.open(
            output_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
            dir_fd=parent_descriptor,
        )
        os.write(victim_descriptor, b"preserve mutable-name victim\\n")
        os.close(victim_descriptor)
        with open({marker!r}, "w", encoding="utf-8") as stream:
            stream.write(output_name)
        raise OSError("injected settings publication failure")
        publish_settings_atomically(
'''.format(marker=marker)
if source.count(needle) != 1:
    raise SystemExit("settings artifact injection point is unavailable")
path.write_text(source.replace(needle, replacement, 1), encoding="utf-8")
PY

HOME="$TEMP_FAILURE_HOME" \
PATH="$TEMP_FAILURE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
    /bin/bash "$TEMP_FAILURE_ROOT/60-claude-tooling.sh" \
    >"$TMP/settings-temp-failure-output" 2>&1
temp_failure_status=$?
temp_failure_name=""
if [ -f "$TEMP_FAILURE_MARKER" ]; then
    read -r temp_failure_name < "$TEMP_FAILURE_MARKER"
fi
if [ "$temp_failure_status" -ne 0 ] \
    && cmp -s "$TEMP_FAILURE_SETTINGS" "$TEMP_FAILURE_ORIGINAL" \
    && [ -f "$TEMP_FAILURE_HOME/.claude/.retained-settings-output" ] \
    && [ -n "$temp_failure_name" ] \
    && grep -qx 'preserve mutable-name victim' \
        "$TEMP_FAILURE_HOME/.claude/$temp_failure_name" \
    && ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' \
        "$TEMP_FAILURE_GIT_LOG"; then
    pass "a post-write failure retains evidence and does not delete a changed name"
else
    fail "settings failure cleanup deleted or replaced an unbound name"
fi

info "settings backup publication cannot follow a predictable planted name"
BACKUP_HOME="$TMP/preplanted-backup-home"
BACKUP_SETTINGS="$BACKUP_HOME/.claude/settings.json"
BACKUP_ORIGINAL="$TMP/preplanted-backup-original.json"
BACKUP_VICTIM="$TMP/preplanted-backup-victim.txt"
BACKUP_GIT_LOG="$TMP/preplanted-backup-git.log"
mkdir -p "$BACKUP_HOME/.claude" \
    "$BACKUP_HOME/.agent_brain/knowledge/.git"
cat > "$BACKUP_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {}
}
JSON
cp "$BACKUP_SETTINGS" "$BACKUP_ORIGINAL"
printf 'preserve predictable-backup victim\n' > "$BACKUP_VICTIM"
backup_victim_before="$(settings_write_fingerprint "$BACKUP_VICTIM")"
backup_epoch="$(date +%s)"
backup_offset=0
while [ "$backup_offset" -le 120 ]; do
    ln -s "$BACKUP_VICTIM" \
        "$BACKUP_HOME/.claude/settings.json.bak.$((backup_epoch + backup_offset))"
    backup_offset=$((backup_offset + 1))
done

HOME="$BACKUP_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$BACKUP_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/preplanted-backup-output" 2>&1
backup_status=$?
regular_backup="$(
    find "$BACKUP_HOME/.claude" -maxdepth 1 -type f \
        -name 'settings.json.bak.*' -print -quit
)"

if [ "$backup_status" -eq 0 ]; then
    pass "install mode reconciles settings despite planted predictable names"
else
    fail "planted predictable backup names blocked settings reconciliation"
fi
if [ "$(settings_write_fingerprint "$BACKUP_VICTIM")" = \
    "$backup_victim_before" ]; then
    pass "exclusive backup creation preserves the planted victim"
else
    fail "backup creation followed a planted name into its victim"
fi
if [ -n "$regular_backup" ] && cmp -s "$BACKUP_ORIGINAL" "$regular_backup" && \
   basename "$regular_backup" | \
       grep -Eq '^settings\.json\.bak\.[0-9a-f]{32}$'; then
    pass "backup uses an exclusive unpredictable regular file"
else
    fail "backup was not published as an unpredictable regular file"
fi

info "Athena marketplace conformance includes the source kind"
SHAPE_HOME="$TMP/marketplace-shape-home"
SHAPE_SETTINGS="$SHAPE_HOME/.claude/settings.json"
SHAPE_ORIGINAL="$TMP/marketplace-shape-original.json"
SHAPE_GIT_LOG="$TMP/marketplace-shape-git.log"
mkdir -p "$SHAPE_HOME/.claude" "$SHAPE_HOME/.agent_brain/knowledge/.git"
cat > "$SHAPE_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {
    "Athena": {
      "source": {
        "source": "directory",
        "url": "https://github.com/HomericIntelligence/Athena.git"
      }
    }
  },
  "enabledPlugins": {
    "athena@Athena": true
  }
}
JSON
cp "$SHAPE_SETTINGS" "$SHAPE_ORIGINAL"
HOME="$SHAPE_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$SHAPE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/marketplace-shape-check-output" 2>&1
shape_check_status=$?

if [ "$shape_check_status" -eq 0 ] && \
   grep -q 'marketplace Athena: wrong source kind (found: directory; expected: git)' \
       "$TMP/marketplace-shape-check-output" && \
   ! grep -q 'settings.json .* Athena marketplace and plugin configured' \
       "$TMP/marketplace-shape-check-output"; then
    pass "check-only detects a repairable Athena source-kind mismatch"
else
    fail "check-only accepted an incomplete Athena marketplace shape"
fi
if cmp -s "$SHAPE_SETTINGS" "$SHAPE_ORIGINAL" \
    && ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' "$SHAPE_GIT_LOG"; then
    pass "source-kind inspection is read-only"
else
    fail "source-kind inspection changed local or Git state"
fi

HOME="$SHAPE_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$SHAPE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/marketplace-shape-install-output" 2>&1
shape_install_status=$?
if [ "$shape_install_status" -eq 0 ] && python3 - "$SHAPE_SETTINGS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    settings = json.load(stream)

assert settings["extraKnownMarketplaces"]["Athena"]["source"] == {
    "source": "git",
    "url": "https://github.com/HomericIntelligence/Athena.git",
}
PY
then
    pass "install repairs the complete Athena marketplace shape"
else
    fail "install preserved a non-git Athena marketplace source"
fi

info "settings input enforces an incremental byte ceiling"
INPUT_LIMIT_HOME="$TMP/input-limit-home"
INPUT_LIMIT_SETTINGS="$INPUT_LIMIT_HOME/.claude/settings.json"
INPUT_LIMIT_GIT_LOG="$TMP/input-limit-git.log"
write_sized_canonical_settings \
    "$INPUT_LIMIT_SETTINGS" "$SETTINGS_BYTE_LIMIT"
write_fake_mnemosyne_checkout \
    "$INPUT_LIMIT_HOME/.agent_brain/knowledge"
input_limit_before="$(settings_write_fingerprint "$INPUT_LIMIT_SETTINGS")"
HOME="$INPUT_LIMIT_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$INPUT_LIMIT_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/input-limit-output" 2>&1
input_limit_status=$?
if [ "$input_limit_status" -eq 0 ] \
    && [ "$(wc -c < "$INPUT_LIMIT_SETTINGS")" -eq \
        "$SETTINGS_BYTE_LIMIT" ] \
    && [ "$(settings_write_fingerprint "$INPUT_LIMIT_SETTINGS")" = \
        "$input_limit_before" ]; then
    pass "an input exactly at the settings byte ceiling is accepted unchanged"
else
    fail "an input exactly at the settings byte ceiling was rejected or changed"
fi

INPUT_OVER_HOME="$TMP/input-over-limit-home"
INPUT_OVER_SETTINGS="$INPUT_OVER_HOME/.claude/settings.json"
INPUT_OVER_GIT_LOG="$TMP/input-over-limit-git.log"
write_sized_canonical_settings \
    "$INPUT_OVER_SETTINGS" "$((SETTINGS_BYTE_LIMIT + 1))"
write_fake_mnemosyne_checkout \
    "$INPUT_OVER_HOME/.agent_brain/knowledge"
input_over_before="$(settings_write_fingerprint "$INPUT_OVER_SETTINGS")"
HOME="$INPUT_OVER_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$INPUT_OVER_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/input-over-limit-output" 2>&1
input_over_status=$?
if [ "$input_over_status" -ne 0 ] \
    && grep -q 'settings.json exceeds the 1048576-byte limit' \
        "$TMP/input-over-limit-output" \
    && [ "$(settings_write_fingerprint "$INPUT_OVER_SETTINGS")" = \
        "$input_over_before" ] \
    && [ ! -s "$INPUT_OVER_GIT_LOG" ]; then
    pass "an input one byte above the settings ceiling fails without effects"
else
    fail "an oversized settings input was accepted or caused effects"
fi

info "settings output enforces an exact byte ceiling before publication"
OUTPUT_LIMIT_HOME="$TMP/output-limit-home"
OUTPUT_LIMIT_SETTINGS="$OUTPUT_LIMIT_HOME/.claude/settings.json"
OUTPUT_LIMIT_GIT_LOG="$TMP/output-limit-git.log"
write_settings_for_reconciled_size \
    "$OUTPUT_LIMIT_SETTINGS" "$SETTINGS_BYTE_LIMIT"
write_fake_mnemosyne_checkout \
    "$OUTPUT_LIMIT_HOME/.agent_brain/knowledge"
HOME="$OUTPUT_LIMIT_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$OUTPUT_LIMIT_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/output-limit-output" 2>&1
output_limit_status=$?
if [ "$output_limit_status" -eq 0 ] \
    && [ "$(wc -c < "$OUTPUT_LIMIT_SETTINGS")" -eq \
        "$SETTINGS_BYTE_LIMIT" ]; then
    pass "reconciled output exactly at the settings ceiling is published"
else
    fail "reconciled output exactly at the settings ceiling was rejected"
fi

OUTPUT_OVER_HOME="$TMP/output-over-limit-home"
OUTPUT_OVER_SETTINGS="$OUTPUT_OVER_HOME/.claude/settings.json"
OUTPUT_OVER_GIT_LOG="$TMP/output-over-limit-git.log"
write_settings_for_reconciled_size \
    "$OUTPUT_OVER_SETTINGS" "$((SETTINGS_BYTE_LIMIT + 1))"
write_fake_mnemosyne_checkout \
    "$OUTPUT_OVER_HOME/.agent_brain/knowledge"
output_over_before="$(settings_write_fingerprint "$OUTPUT_OVER_SETTINGS")"
HOME="$OUTPUT_OVER_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$OUTPUT_OVER_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/output-over-limit-output" 2>&1
output_over_status=$?
if [ "$output_over_status" -ne 0 ] \
    && grep -q 'reconciled settings exceed the 1048576-byte limit' \
        "$TMP/output-over-limit-output" \
    && [ "$(wc -c < "$OUTPUT_OVER_SETTINGS")" -le \
        "$SETTINGS_BYTE_LIMIT" ] \
    && [ "$(settings_write_fingerprint "$OUTPUT_OVER_SETTINGS")" = \
        "$output_over_before" ] \
    && [ -z "$(settings_backup_inventory "$OUTPUT_OVER_HOME/.claude")" ] \
    && [ ! -s "$OUTPUT_OVER_GIT_LOG" ]; then
    pass "oversized reconciled output fails before backup or publication"
else
    fail "oversized reconciled output was published or caused effects"
fi

info "check-only tooling fails closed on malformed settings"
CHECK_ONLY_MALFORMED_HOME="$TMP/check-only-malformed-home"
CHECK_ONLY_MALFORMED_SETTINGS="$CHECK_ONLY_MALFORMED_HOME/.claude/settings.json"
CHECK_ONLY_MALFORMED_GIT_LOG="$TMP/check-only-malformed-git.log"
mkdir -p "$CHECK_ONLY_MALFORMED_HOME/.claude" \
    "$CHECK_ONLY_MALFORMED_HOME/.agent_brain/knowledge/.git"
printf '{not valid json}\n' > "$CHECK_ONLY_MALFORMED_SETTINGS"
set +e
HOME="$CHECK_ONLY_MALFORMED_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$CHECK_ONLY_MALFORMED_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/check-only-malformed-output" 2>&1
check_only_malformed_status=$?
set +e

if [ "$check_only_malformed_status" -ne 0 ]; then
    pass "check-only malformed settings inspection exits nonzero"
else
    fail "check-only malformed settings inspection returned success"
fi
if grep -q 'settings.json .* inspection .*failed' \
    "$TMP/check-only-malformed-output"; then
    pass "check-only malformed settings reports inspection failure"
else
    fail "check-only malformed settings was reported as an ordinary config gap"
fi
if grep -qx '{not valid json}' "$CHECK_ONLY_MALFORMED_SETTINGS"; then
    pass "check-only malformed settings remains byte-unchanged"
else
    fail "check-only malformed settings changed the source file"
fi
if [ ! -s "$CHECK_ONLY_MALFORMED_GIT_LOG" ]; then
    pass "check-only malformed settings performs no Git operation"
else
    fail "check-only malformed settings invoked Git"
fi

info "check-only tooling rejects malformed nested marketplace fields"
NESTED_MALFORMED_HOME="$TMP/check-only-nested-malformed-home"
NESTED_MALFORMED_SETTINGS="$NESTED_MALFORMED_HOME/.claude/settings.json"
NESTED_MALFORMED_ORIGINAL="$TMP/check-only-nested-malformed-original.json"
NESTED_MALFORMED_GIT_LOG="$TMP/check-only-nested-malformed-git.log"
mkdir -p "$NESTED_MALFORMED_HOME/.claude" \
    "$NESTED_MALFORMED_HOME/.agent_brain/knowledge/.git"
cat > "$NESTED_MALFORMED_SETTINGS" <<'JSON'
{
  "extraKnownMarketplaces": {
    "Athena": {
      "source": {
        "source": "git",
        "url": ["https://github.com/HomericIntelligence/Athena.git"]
      }
    }
  },
  "enabledPlugins": {
    "athena@Athena": true
  }
}
JSON
cp "$NESTED_MALFORMED_SETTINGS" "$NESTED_MALFORMED_ORIGINAL"
HOME="$NESTED_MALFORMED_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=false \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$NESTED_MALFORMED_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/check-only-nested-malformed-output" 2>&1
nested_malformed_status=$?

if [ "$nested_malformed_status" -ne 0 ]; then
    pass "check-only malformed nested settings exits nonzero"
else
    fail "check-only malformed nested settings returned success"
fi
if grep -q \
    'inspection failed: extraKnownMarketplaces.Athena.source.url must be a string' \
    "$TMP/check-only-nested-malformed-output"; then
    pass "check-only malformed nested settings reports the exact invalid field"
else
    fail "check-only malformed nested settings omitted a clear diagnostic"
fi
if cmp -s "$NESTED_MALFORMED_SETTINGS" "$NESTED_MALFORMED_ORIGINAL" && \
   ! find "$NESTED_MALFORMED_HOME/.claude" -mindepth 1 \
       ! -name settings.json -print -quit | grep -q .; then
    pass "check-only malformed nested settings performs no filesystem write"
else
    fail "check-only malformed nested settings changed the settings surface"
fi
if [ ! -s "$NESTED_MALFORMED_GIT_LOG" ]; then
    pass "check-only malformed nested settings performs no Git operation"
else
    fail "check-only malformed nested settings invoked Git"
fi

HOME="$NESTED_MALFORMED_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$NESTED_MALFORMED_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/install-nested-malformed-output" 2>&1
install_nested_malformed_status=$?

if [ "$install_nested_malformed_status" -ne 0 ]; then
    pass "install mode malformed nested settings exits nonzero"
else
    fail "install mode malformed nested settings returned success"
fi
if grep -q \
    'inspection failed: extraKnownMarketplaces.Athena.source.url must be a string' \
    "$TMP/install-nested-malformed-output"; then
    pass "install mode malformed nested settings preserves the clear diagnostic"
else
    fail "install mode malformed nested settings omitted a clear diagnostic"
fi
if cmp -s "$NESTED_MALFORMED_SETTINGS" "$NESTED_MALFORMED_ORIGINAL" && \
   ! find "$NESTED_MALFORMED_HOME/.claude" -mindepth 1 \
       ! -name settings.json -print -quit | grep -q .; then
    pass "install mode malformed nested settings performs no filesystem write"
else
    fail "install mode malformed nested settings changed the settings surface"
fi
if [ ! -s "$NESTED_MALFORMED_GIT_LOG" ]; then
    pass "install mode malformed nested settings stops before Git"
else
    fail "install mode malformed nested settings reached Git"
fi

info "Claude checks require a valid executable version"

SECRET_CLAUDE_BIN="$TMP/secret-claude-bin"
SECRET_CLAUDE_HOME="$TMP/secret-claude-home"
SECRET_CLAUDE_GIT_LOG="$TMP/secret-claude-git.log"
SECRET_CLAUDE_MARKER="$SECRET_CLAUDE_HOME/secret-reached-version"
mkdir -p "$SECRET_CLAUDE_BIN"
write_canonical_settings "$SECRET_CLAUDE_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$SECRET_CLAUDE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$SECRET_CLAUDE_BIN/"
python3 -I -S - "$SECRET_CLAUDE_BIN/claude" \
    "$SECRET_CLAUDE_MARKER" <<'PY'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
marker = sys.argv[2]
path.write_text(
    "#!/bin/bash\n"
    'if [ -n "${ANTHROPIC_API_KEY:-}" ]; then\n'
    f"    : > {shlex.quote(marker)}\n"
    "fi\n"
    "printf 'claude 1.2.3\\n'\n",
    encoding="utf-8",
)
PY
chmod 700 "$SECRET_CLAUDE_BIN/claude"
HOME="$SECRET_CLAUDE_HOME" \
PATH="$SECRET_CLAUDE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$SECRET_CLAUDE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
ANTHROPIC_API_KEY=must-not-reach-version-probe \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/secret-claude-output" 2>&1
secret_claude_status=$?
if [ "$secret_claude_status" -eq 0 ] \
    && [ ! -e "$SECRET_CLAUDE_MARKER" ]; then
    pass "Claude version probe receives no ambient provider credential"
else
    fail "Claude version probe inherited an ambient provider credential"
fi

UNSAFE_CLAUDE_BIN="$TMP/unsafe-claude-bin"
UNSAFE_CLAUDE_HOME="$TMP/unsafe-claude-home"
UNSAFE_CLAUDE_GIT_LOG="$TMP/unsafe-claude-git.log"
UNSAFE_CLAUDE_MARKER="$UNSAFE_CLAUDE_HOME/unsafe-claude-invoked"
mkdir -p "$UNSAFE_CLAUDE_BIN"
write_canonical_settings "$UNSAFE_CLAUDE_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$UNSAFE_CLAUDE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$UNSAFE_CLAUDE_BIN/"
cat > "$UNSAFE_CLAUDE_BIN/claude" <<'SH'
#!/usr/bin/env bash
: > "$HOME/unsafe-claude-invoked"
printf 'claude 1.2.3\n'
SH
chmod 777 "$UNSAFE_CLAUDE_BIN/claude"
HOME="$UNSAFE_CLAUDE_HOME" \
PATH="$UNSAFE_CLAUDE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$UNSAFE_CLAUDE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/unsafe-claude-output" 2>&1
unsafe_claude_status=$?
if [ "$unsafe_claude_status" -ne 0 ] \
    && [ ! -e "$UNSAFE_CLAUDE_MARKER" ] \
    && grep -q 'claude — version check failed' \
        "$TMP/unsafe-claude-output"; then
    pass "Claude probe rejects a writable executable before invocation"
else
    fail "Claude probe invoked an executable with mutable authority"
fi

OVERSIZED_CLAUDE_BIN="$TMP/oversized-claude-bin"
OVERSIZED_CLAUDE_HOME="$TMP/oversized-claude-home"
OVERSIZED_CLAUDE_GIT_LOG="$TMP/oversized-claude-git.log"
mkdir -p "$OVERSIZED_CLAUDE_BIN"
write_canonical_settings "$OVERSIZED_CLAUDE_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$OVERSIZED_CLAUDE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$OVERSIZED_CLAUDE_BIN/"
cat > "$OVERSIZED_CLAUDE_BIN/claude" <<'SH'
#!/bin/bash
printf 'claude 1.2.3\n'
count=0
while [ "$count" -lt 700 ]; do
    printf '%0100d' 0
    count=$((count + 1))
done
SH
chmod 700 "$OVERSIZED_CLAUDE_BIN/claude"
HOME="$OVERSIZED_CLAUDE_HOME" \
PATH="$OVERSIZED_CLAUDE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$OVERSIZED_CLAUDE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/oversized-claude-output" 2>&1
oversized_claude_status=$?
if [ "$oversized_claude_status" -ne 0 ] \
    && grep -q 'claude — version check failed' \
        "$TMP/oversized-claude-output"; then
    pass "Claude probe rejects output past its byte boundary"
else
    fail "Claude probe accepted output past its byte boundary"
fi

DETACHED_CLAUDE_BIN="$TMP/detached-claude-bin"
DETACHED_CLAUDE_HOME="$TMP/detached-claude-home"
DETACHED_CLAUDE_GIT_LOG="$TMP/detached-claude-git.log"
DETACHED_CLAUDE_PID="$DETACHED_CLAUDE_HOME/detached-claude.pid"
DETACHED_CLAUDE_ATTEMPT="$DETACHED_CLAUDE_HOME/detached-claude.attempt"
mkdir -p "$DETACHED_CLAUDE_BIN"
write_canonical_settings "$DETACHED_CLAUDE_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$DETACHED_CLAUDE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$DETACHED_CLAUDE_BIN/"
python3 -I -S - "$DETACHED_CLAUDE_BIN/claude" \
    "$DETACHED_CLAUDE_ATTEMPT" "$DETACHED_CLAUDE_PID" <<'PY'
from pathlib import Path
import shlex
import sys

path = Path(sys.argv[1])
attempt_path = sys.argv[2]
marker_path = sys.argv[3]
python = str(Path(sys.executable).resolve())
path.write_text(
    f"#!{python}\n"
    "from pathlib import Path\n"
    "import os\n"
    "import subprocess\n"
    "import sys\n"
    "import time\n\n"
    f"attempt = Path({attempt_path!r})\n"
    f"marker = Path({marker_path!r})\n"
    'attempt.write_text("attempted\\n", encoding="ascii")\n'
    "subprocess.Popen(\n"
    "    [\n"
    "        sys.executable,\n"
    '        "-I",\n'
    '        "-S",\n'
    '        "-c",\n'
    "        (\n"
    '            "from pathlib import Path; import os, sys, time; "\n'
    '            "Path(sys.argv[1]).write_text(str(os.getpid()), encoding=\'ascii\'); "\n'
    '            "time.sleep(30)"\n'
    "        ),\n"
    "        str(marker),\n"
    "    ],\n"
    "    stdin=subprocess.DEVNULL,\n"
    "    stdout=subprocess.DEVNULL,\n"
    "    stderr=subprocess.DEVNULL,\n"
    "    close_fds=True,\n"
    "    start_new_session=True,\n"
    ")\n"
    "deadline = time.monotonic() + 1.0\n"
    "while not marker.exists() and time.monotonic() < deadline:\n"
    "    time.sleep(0.01)\n"
    'print("claude 1.2.3")\n',
    encoding="utf-8",
)
PY
chmod 700 "$DETACHED_CLAUDE_BIN/claude"
HOME="$DETACHED_CLAUDE_HOME" \
PATH="$DETACHED_CLAUDE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$DETACHED_CLAUDE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/detached-claude-output" 2>&1
detached_claude_status=$?
detached_claude_process=""
if [ -s "$DETACHED_CLAUDE_PID" ]; then
    detached_claude_process=$(cat "$DETACHED_CLAUDE_PID")
fi
detached_claude_contained=false
if [[ "$detached_claude_process" =~ ^[1-9][0-9]*$ ]]; then
    if ! process_is_live "$detached_claude_process"; then
        detached_claude_contained=true
    fi
elif [ ! -e "$DETACHED_CLAUDE_PID" ]; then
    detached_claude_contained=true
fi
if [ "$detached_claude_status" -ne 0 ] \
    && [ -e "$DETACHED_CLAUDE_ATTEMPT" ] \
    && $detached_claude_contained \
    && grep -q 'claude — version check failed' \
        "$TMP/detached-claude-output"; then
    pass "Claude probe extinguishes a detached descendant before return"
else
    fail "Claude probe returned while a detached descendant survived"
fi
if [[ "$detached_claude_process" =~ ^[1-9][0-9]*$ ]]; then
    wait_for_test_process_exit "$detached_claude_process" || \
        fail "detached Claude test process did not expire"
fi

if [ "$(uname -s)" = Linux ]; then
    CLEANUP_ERROR_CLAUDE_BIN="$TMP/cleanup-error-claude-bin"
    CLEANUP_ERROR_CLAUDE_HOME="$TMP/cleanup-error-claude-home"
    CLEANUP_ERROR_CLAUDE_PID="$TMP/cleanup-error-claude.pid"
    CLEANUP_ERROR_CLAUDE_ROOT="$TMP/cleanup-error-claude-installer"
    mkdir -p "$CLEANUP_ERROR_CLAUDE_BIN" "$CLEANUP_ERROR_CLAUDE_ROOT"
    write_canonical_settings \
        "$CLEANUP_ERROR_CLAUDE_HOME/.claude/settings.json"
    write_fake_mnemosyne_checkout \
        "$CLEANUP_ERROR_CLAUDE_HOME/.agent_brain/knowledge"
    cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$CLEANUP_ERROR_CLAUDE_BIN/"
    python3 -I -S - "$CLEANUP_ERROR_CLAUDE_BIN/claude" \
        "$CLEANUP_ERROR_CLAUDE_PID" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
marker_path = sys.argv[2]
python = str(Path(sys.executable).resolve())
path.write_text(
    f"#!{python}\n"
    "from pathlib import Path\n"
    "import subprocess\n"
    "import sys\n"
    "import time\n\n"
    f"marker = Path({marker_path!r})\n"
    "subprocess.Popen(\n"
    "    [\n"
    "        sys.executable,\n"
    '        "-I",\n'
    '        "-S",\n'
    '        "-c",\n'
    "        (\n"
    '            "from pathlib import Path; import os, sys, time; "\n'
    '            "Path(sys.argv[1]).write_text(str(os.getpid()), encoding=\'ascii\'); "\n'
    '            "time.sleep(30)"\n'
    "        ),\n"
    "        str(marker),\n"
    "    ],\n"
    "    stdin=subprocess.DEVNULL,\n"
    "    stdout=subprocess.DEVNULL,\n"
    "    stderr=subprocess.DEVNULL,\n"
    "    close_fds=True,\n"
    "    start_new_session=True,\n"
    ")\n"
    "deadline = time.monotonic() + 1.0\n"
    "while not marker.exists() and time.monotonic() < deadline:\n"
    "    time.sleep(0.01)\n"
    'print("claude 1.2.3")\n',
    encoding="utf-8",
)
path.chmod(0o700)
PY
    cp "$ROOT/scripts/install/60-claude-tooling.sh" \
        "$CLEANUP_ERROR_CLAUDE_ROOT/60-claude-tooling.sh"
    cp "$ROOT/scripts/install/lib.sh" "$CLEANUP_ERROR_CLAUDE_ROOT/lib.sh"
    python3 -I -S - \
        "$CLEANUP_ERROR_CLAUDE_ROOT/60-claude-tooling.sh" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
discover_needle = '''    def discover(self):
        while True:
'''
discover_replacement = '''    def discover(self):
        if getattr(self, "_inject_cleanup_inventory_failure", False):
            raise ProbeFailure("injected cleanup inventory failure")
        while True:
'''
descendants_needle = '''    def descendants(self, root):
        return tuple(item for item in self.live() if item[0] != root)
'''
descendants_replacement = '''    def descendants(self, root):
        active = tuple(item for item in self.live() if item[0] != root)
        if active:
            self._inject_cleanup_inventory_failure = True
            raise ProbeFailure("injected cleanup inventory failure")
        return active
'''
if source.count(discover_needle) != 1:
    raise SystemExit("Claude discover injection point is unavailable")
if source.count(descendants_needle) != 1:
    raise SystemExit("Claude descendant injection point is unavailable")
source = source.replace(discover_needle, discover_replacement, 1)
source = source.replace(descendants_needle, descendants_replacement, 1)
path.write_text(source, encoding="utf-8")
PY
    HOME="$CLEANUP_ERROR_CLAUDE_HOME" \
    PATH="$CLEANUP_ERROR_CLAUDE_BIN:/usr/bin:/bin" \
    INSTALL=true \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
    GIT_LOG="$TMP/cleanup-error-claude-git.log" \
    SKILL_MARKER="$SKILL_MARKER" \
        /bin/bash "$CLEANUP_ERROR_CLAUDE_ROOT/60-claude-tooling.sh" \
        >"$TMP/cleanup-error-claude-output" 2>&1
    cleanup_error_claude_status=$?
    cleanup_error_claude_process=""
    if [ -s "$CLEANUP_ERROR_CLAUDE_PID" ]; then
        read -r cleanup_error_claude_process < "$CLEANUP_ERROR_CLAUDE_PID"
    fi
    if [ "$cleanup_error_claude_status" -ne 0 ] \
        && [ -n "$cleanup_error_claude_process" ] \
        && wait_for_test_process_exit "$cleanup_error_claude_process"; then
        pass "Claude cleanup inventory failure still extinguishes descendants"
    else
        fail "Claude cleanup inventory failure left a descendant alive"
        if [ -n "$cleanup_error_claude_process" ]; then
            if ! kill -KILL "$cleanup_error_claude_process" 2>/dev/null; then :; fi
        fi
    fi
else
    pass "Linux CI owns Claude cleanup-error descendant proof"
fi

HANGING_CLAUDE_BIN="$TMP/hanging-claude-bin"
HANGING_CLAUDE_HOME="$TMP/hanging-claude-home"
HANGING_CLAUDE_GIT_LOG="$TMP/hanging-claude-git.log"
mkdir -p "$HANGING_CLAUDE_BIN"
write_canonical_settings "$HANGING_CLAUDE_HOME/.claude/settings.json"
write_fake_mnemosyne_checkout \
    "$HANGING_CLAUDE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$HANGING_CLAUDE_BIN/"
cat > "$HANGING_CLAUDE_BIN/claude" <<'SH'
#!/bin/bash
sleep 30
SH
chmod 700 "$HANGING_CLAUDE_BIN/claude"
run_with_wall_deadline 6 /usr/bin/env \
    HOME="$HANGING_CLAUDE_HOME" \
    PATH="$HANGING_CLAUDE_BIN:/usr/bin:/bin" \
    INSTALL=true \
    ODYSSEUS_ROOT="$FAKE_ROOT" \
    GIT_LOG="$HANGING_CLAUDE_GIT_LOG" \
    SKILL_MARKER="$SKILL_MARKER" \
    "$TOOLING_RUNNER" \
    >"$TMP/hanging-claude-output" 2>&1
hanging_claude_status=$?
if [ "$hanging_claude_status" -ne 0 ] \
    && [ "$hanging_claude_status" -ne 124 ] \
    && grep -q 'claude — version check failed' \
        "$TMP/hanging-claude-output"; then
    pass "Claude probe enforces one wall-clock deadline"
else
    fail "Claude probe exceeded its wall-clock deadline"
fi

BROKEN_CLAUDE_BIN="$TMP/broken-claude-bin"
BROKEN_CLAUDE_HOME="$TMP/broken-claude-home"
BROKEN_CLAUDE_GIT_LOG="$TMP/broken-claude-git.log"
BROKEN_CLAUDE_EXTERNAL="$TMP/broken-claude-external-knowledge"
mkdir -p "$BROKEN_CLAUDE_BIN" "$BROKEN_CLAUDE_HOME/.claude" \
    "$BROKEN_CLAUDE_HOME/.agent_brain" "$BROKEN_CLAUDE_EXTERNAL"
: > "$BROKEN_CLAUDE_GIT_LOG"
ln -s "$BROKEN_CLAUDE_EXTERNAL" \
    "$BROKEN_CLAUDE_HOME/.agent_brain/knowledge"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$BROKEN_CLAUDE_BIN/"
cat > "$BROKEN_CLAUDE_BIN/claude" <<'SH'
#!/usr/bin/env bash
printf 'broken version probe\n' >&2
exit 9
SH
chmod +x "$BROKEN_CLAUDE_BIN/claude"
cp "$WEIRD_SETTINGS" "$BROKEN_CLAUDE_HOME/.claude/settings.json"
HOME="$BROKEN_CLAUDE_HOME" \
PATH="$BROKEN_CLAUDE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$BROKEN_CLAUDE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/broken-claude-output" 2>&1
broken_claude_status=$?

if [ "$broken_claude_status" -ne 0 ] && \
   grep -q 'claude — version check failed' "$TMP/broken-claude-output" && \
   ! grep -q 'claude broken version probe' "$TMP/broken-claude-output"; then
    pass "a failing installed Claude executable is never reported as valid"
else
    fail "a failing installed Claude executable produced a false pass"
fi
if ! grep -Eq '(^| )pull( |$)|(^| )clone( |$)' \
    "$BROKEN_CLAUDE_GIT_LOG"; then
    pass "a failing Claude version probe does not trigger a Git mutation"
else
    fail "a failing Claude version probe triggered a Git mutation"
fi

POSTCONDITION_BIN="$TMP/postcondition-bin"
POSTCONDITION_HOME="$TMP/postcondition-home"
POSTCONDITION_GIT_LOG="$TMP/postcondition-git.log"
POSTCONDITION_CURL_MARKER="$TMP/postcondition-curl-invoked"
mkdir -p "$POSTCONDITION_BIN" "$POSTCONDITION_HOME/.claude" \
    "$POSTCONDITION_HOME/.agent_brain/knowledge/.git"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$POSTCONDITION_BIN/"
cat > "$POSTCONDITION_BIN/curl" <<'SH'
#!/usr/bin/env bash
: > "$POSTCONDITION_CURL_MARKER"
exit 99
SH
chmod +x "$POSTCONDITION_BIN/curl"
cp "$WEIRD_SETTINGS" "$POSTCONDITION_HOME/.claude/settings.json"
HOME="$POSTCONDITION_HOME" \
PATH="$POSTCONDITION_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$POSTCONDITION_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
POSTCONDITION_CURL_MARKER="$POSTCONDITION_CURL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/postcondition-output" 2>&1
postcondition_status=$?

if [ "$postcondition_status" -eq 0 ] && \
   grep -q 'pre-provision a verified Claude Code CLI' \
       "$TMP/postcondition-output" && \
   [ ! -e "$POSTCONDITION_CURL_MARKER" ] && \
   ! grep -q 'claude installed' "$TMP/postcondition-output"; then
    pass "missing Claude CLI never executes an unverified network installer"
else
    fail "missing Claude CLI reached an unverified network installer"
fi

info "a failed Mnemosyne clone leaves the next install retryable"
RETRY_HOME="$TMP/retry-home"
RETRY_GIT_LOG="$TMP/retry-git.log"
RETRY_CLONE_MARKER="$TMP/retry-clone-failed"
mkdir -p "$RETRY_HOME/.claude"
write_canonical_settings "$RETRY_HOME/.claude/settings.json"

HOME="$RETRY_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$RETRY_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER="$RETRY_CLONE_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/retry-first-output" 2>&1
retry_first_status=$?
retired_retry_checkout=""
for candidate in "$RETRY_HOME/.agent_brain"/.knowledge.clone-failed.*; do
    if [ -d "$candidate" ]; then
        retired_retry_checkout="$candidate"
        break
    fi
done

if [ "$retry_first_status" -eq 0 ] \
    && grep -q 'Mnemosyne clone failed' "$TMP/retry-first-output" \
    && [ ! -e "$RETRY_HOME/.agent_brain/knowledge" ] \
    && [ -n "$retired_retry_checkout" ] \
    && grep -qx 'incomplete clone' "$retired_retry_checkout/.git/config"; then
    pass "a failed clone leaves no canonical checkout reservation"
else
    fail "a failed clone left a poisoned canonical checkout path"
fi

HOME="$RETRY_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$RETRY_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
MNEMOSYNE_FAKE_CLONE_FAIL_ONCE_MARKER="$RETRY_CLONE_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/retry-second-output" 2>&1
retry_second_status=$?

if [ "$retry_second_status" -eq 0 ] \
    && grep -q 'Mnemosyne .* seeded' "$TMP/retry-second-output" \
    && [ -d "$RETRY_HOME/.agent_brain/knowledge/.git" ] \
    && [ "$(grep -c ' clone ' "$RETRY_GIT_LOG")" -eq 2 ]; then
    pass "the next install retries and publishes the canonical checkout"
else
    fail "the next install did not recover from the transient clone failure"
fi

info "tooling setup uses the canonical knowledge checkout"
prepare_test_git_control GIT_LOG
HOME="$TEST_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash -c \
    'source "$1"; printf "__PHASE_FAILS__=%s\n" "${_FAIL:-0}"' \
    _ "$ROOT/scripts/install/60-claude-tooling.sh" >"$TMP/output" 2>&1
status=$?

if [ "$status" -eq 0 ]; then
    pass "tooling setup completes"
else
    fail "tooling setup exited $status"
fi
if grep -qx '__PHASE_FAILS__=0' "$TMP/output"; then
    pass "successful install leaves no stale phase failure"
else
    fail "successful install retained a pre-repair phase failure"
fi

if [ -d "$TEST_HOME/.agent_brain/knowledge/.git" ]; then
    pass "Mnemosyne is available at .agent_brain/knowledge"
else
    fail "Mnemosyne was not seeded at .agent_brain/knowledge"
fi
if grep -Fqx -- \
    "-c core.attributesFile=/dev/null -c core.fsmonitor=false -c core.hooksPath=/dev/null -c credential.helper= -c credential.interactive=false -c protocol.allow=never -c protocol.https.allow=always -c protocol.file.allow=never -c http.sslVerify=true -c http.https://github.com/HomericIntelligence/Mnemosyne.git.sslVerify=true -c http.sslCAInfo= -c http.sslCAPath= -c http.proxy= -c http.https://github.com/HomericIntelligence/Mnemosyne.git.proxy= -c http.curloptResolve= clone --depth 1 --branch main --single-branch -- https://github.com/HomericIntelligence/Mnemosyne.git ." \
    "$GIT_LOG"; then
    pass "Mnemosyne is cloned from the exact canonical remote"
else
    fail "Mnemosyne clone did not bind the exact canonical remote"
fi

if [ ! -e "$TEST_HOME/.agent-brain/Mnemosyne" ]; then
    pass "tooling setup does not create the obsolete knowledge path"
else
    fail "tooling setup created the obsolete .agent-brain/Mnemosyne path"
fi

info "canonical settings reconciliation is write-idempotent"
SECOND_INSTALL_GIT_LOG="$TMP/second-install-git.log"
settings_before_second_install="$(settings_write_fingerprint "$SETTINGS")"
backups_before_second_install="$(settings_backup_inventory "$TEST_HOME/.claude")"

GIT_LOG="$SECOND_INSTALL_GIT_LOG" prepare_test_git_control GIT_LOG
HOME="$TEST_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$SECOND_INSTALL_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash -c \
    'source "$1"; printf "__PHASE_FAILS__=%s\n" "${_FAIL:-0}"' \
    _ "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/second-install-output" 2>&1
second_install_status=$?

settings_after_second_install="$(settings_write_fingerprint "$SETTINGS")"
backups_after_second_install="$(settings_backup_inventory "$TEST_HOME/.claude")"
if [ "$second_install_status" -eq 0 ] && \
   grep -qx '__PHASE_FAILS__=0' "$TMP/second-install-output"; then
    pass "a second install accepts canonical settings"
else
    fail "a second install failed against canonical settings"
fi
if [ "$settings_after_second_install" = "$settings_before_second_install" ]; then
    pass "a second install leaves canonical settings bytes and inode unchanged"
else
    fail "a second install rewrote canonical settings"
fi
if [ "$backups_after_second_install" = "$backups_before_second_install" ]; then
    pass "a second install leaves the settings backup inventory unchanged"
else
    fail "a second install created or replaced a settings backup"
fi
if grep -Eq -- \
    '^-c core[.]attributesFile=/dev/null -c core[.]fsmonitor=false -c core[.]hooksPath=/dev/null -c credential[.]helper= -c credential[.]interactive=false -c protocol[.]allow=never -c protocol[.]https[.]allow=always -c protocol[.]file[.]allow=never -c http[.]sslVerify=true -c http[.]https://github[.]com/HomericIntelligence/Mnemosyne[.]git[.]sslVerify=true -c http[.]sslCAInfo= -c http[.]sslCAPath= -c http[.]proxy= -c http[.]https://github[.]com/HomericIntelligence/Mnemosyne[.]git[.]proxy= -c http[.]curloptResolve= --git-dir=[.] --work-tree=[.][.] -c url[.]https://github[.]com/HomericIntelligence/Mnemosyne[.]git[.]insteadOf=https://github[.]com/HomericIntelligence/Mnemosyne[.]git/[.]homeric-bound-[0-9a-f]{32} pull --ff-only --no-recurse-submodules https://github[.]com/HomericIntelligence/Mnemosyne[.]git/[.]homeric-bound-[0-9a-f]{32} main$' \
    "$SECOND_INSTALL_GIT_LOG"; then
    pass "the expected Mnemosyne refresh is logged independently"
else
    fail "the second install performed an unexpected Git operation"
fi

info "tooling setup exposes Athena without the retired Hephaestus plugin"
if python3 - "$SETTINGS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    settings = json.load(stream)

marketplaces = settings["extraKnownMarketplaces"]
plugins = settings["enabledPlugins"]
athena_url = marketplaces["Athena"]["source"]["url"]

assert athena_url == "https://github.com/HomericIntelligence/Athena.git"
assert plugins["athena@Athena"] is True
assert "Hephaestus" not in marketplaces
assert "ProjectHephaestus" not in marketplaces
assert not any(key.startswith("hephaestus@") for key in plugins)
assert marketplaces["Other"]["source"]["url"] == "https://example.invalid/other"
assert plugins["other@Other"] is True
assert settings["customSetting"] is True
PY
then
    pass "settings preserve unrelated data and expose only the Athena provider"
else
    fail "settings contain a stale or incorrect agent plugin surface"
fi

if [ ! -e "$SKILL_MARKER" ]; then
    pass "tooling setup does not run the duplicate Hephaestus skill installer"
else
    fail "tooling setup ran the duplicate Hephaestus skill installer"
fi

info "settings reconciliation reports a real write failure truthfully"
MALFORMED_HOME="$TMP/malformed-home"
MALFORMED_SETTINGS="$MALFORMED_HOME/.claude/settings.json"
mkdir -p "$MALFORMED_HOME/.claude" \
    "$MALFORMED_HOME/.agent_brain/knowledge/.git"
printf '{not valid json}\n' >"$MALFORMED_SETTINGS"
prepare_test_git_control GIT_LOG
HOME="$MALFORMED_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash -c \
    'source "$1"; printf "__PHASE_FAILS__=%s\n" "${_FAIL:-0}"' \
    _ "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/malformed-output" 2>&1
malformed_status=$?

if [ "$malformed_status" -eq 0 ]; then
    pass "phase wrapper completes so aggregate state can be inspected"
else
    fail "phase wrapper exited before reporting aggregate state"
fi
if grep -qx '__PHASE_FAILS__=1' "$TMP/malformed-output"; then
    pass "failed settings reconciliation increments the phase failure count once"
else
    fail "failed settings reconciliation has an incorrect failure count"
fi
if ! grep -q 'settings.json .* reconciled' "$TMP/malformed-output"; then
    pass "failed settings reconciliation is not described as successful"
else
    fail "failed settings reconciliation emitted a false success"
fi
if grep -qx '{not valid json}' "$MALFORMED_SETTINGS"; then
    pass "failed settings reconciliation preserves the original file"
else
    fail "failed settings reconciliation changed the malformed file"
fi

HOME="$MALFORMED_HOME" \
PATH="$FAKE_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/malformed-direct-output" 2>&1
direct_status=$?
if [ "$direct_status" -ne 0 ]; then
    pass "direct tooling entry point propagates its failed check"
else
    fail "direct tooling entry point returned success after a failed check"
fi

summary
exit_code
