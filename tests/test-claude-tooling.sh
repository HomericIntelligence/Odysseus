#!/usr/bin/env bash
# Behavior tests for the agent-tooling installation surface.
set -uo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

TEST_HOME="$TMP/home"
FAKE_ROOT="$TMP/odysseus"
FAKE_BIN="$TMP/bin"
SETTINGS="$TEST_HOME/.claude/settings.json"
GIT_LOG="$TMP/git.log"
SKILL_MARKER="$TMP/hephaestus-skill-installer-ran"
SETTINGS_BYTE_LIMIT=1048576

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
#!/usr/bin/env bash
printf 'claude 1.2.3\n'
SH

cat > "$FAKE_BIN/codex" <<'SH'
#!/usr/bin/env bash
exit 0
SH

cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GIT_LOG"
if [ -n "${MNEMOSYNE_GIT_ENV_MARKER:-}" ]; then
    unsafe_environment=false
    for variable_name in GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE \
        GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
        GIT_CONFIG_PARAMETERS GIT_EXEC_PATH GIT_NAMESPACE GIT_TEMPLATE_DIR \
        GIT_ASKPASS SSH_ASKPASS GIT_SSH GIT_SSH_COMMAND GIT_PROXY_COMMAND \
        GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_SSL_NO_VERIFY \
        GIT_SSL_CAINFO GIT_SSL_CAPATH GIT_ATTR_SOURCE GIT_REPLACE_REF_BASE; do
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
    if [ -n "${MNEMOSYNE_EXPECT_HTTP_PROXY:-}" ] \
        && [ "${HTTP_PROXY:-}" != "$MNEMOSYNE_EXPECT_HTTP_PROXY" ]; then
        printf 'HTTP_PROXY was not preserved\n' >> "$MNEMOSYNE_GIT_ENV_MARKER"
        unsafe_environment=true
    fi
    if [ -n "${MNEMOSYNE_EXPECT_HTTPS_PROXY:-}" ] \
        && [ "${HTTPS_PROXY:-}" != "$MNEMOSYNE_EXPECT_HTTPS_PROXY" ]; then
        printf 'HTTPS_PROXY was not preserved\n' >> "$MNEMOSYNE_GIT_ENV_MARKER"
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
http_ssl_ca_path_cleared=false
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
                http.sslCAPath=)
                    http_ssl_ca_path_cleared=true
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
                /usr/bin/git config --file "${3:-}" --no-includes \
                    --get-regexp "${6:-}"
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
                || ! $http_ssl_ca_path_cleared \
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
    && [ -s "$STRICT_PYTHON_LOG" ] \
    && ! grep -Fvx -- '-I|-S|-' "$STRICT_PYTHON_LOG" >/dev/null; then
    pass "successful Mnemosyne refresh uses exact -I -S - Python entry points"
else
    fail "a successful Mnemosyne refresh used a non-isolated Python entry point"
fi

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
MNEMOSYNE_GIT_ENV_MARKER="$ROUTING_ENV_MARKER" \
MNEMOSYNE_PARAMETERS_EFFECT="$ROUTING_PARAMETERS_EFFECT" \
MNEMOSYNE_EXPECT_HTTP_PROXY=http://enterprise-proxy.invalid:8080 \
MNEMOSYNE_EXPECT_HTTPS_PROXY=http://enterprise-proxy.invalid:8443 \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/routing-output" 2>&1
routing_status=$?
if [ "$routing_status" -eq 0 ] \
    && [ ! -e "$ROUTING_ENV_MARKER" ] \
    && [ ! -e "$ROUTING_PARAMETERS_EFFECT" ] \
    && [ "$(settings_write_fingerprint "$ROUTING_DECOY/sentinel")" = \
        "$routing_decoy_before" ]; then
    pass "Mnemosyne Git ignores ambient repository and config routing"
else
    fail "ambient Git routing reached the Mnemosyne operation"
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
write_fake_mnemosyne_checkout "$ENTER_GITDIR_CHECKOUT"
mkdir -p "$ENTER_GITDIR_VICTIM" "$ENTER_GITDIR_BIN"
printf '%s\n' \
    '[remote "origin"]' \
    '    url = https://github.com/HomericIntelligence/Mnemosyne.git' \
    > "$ENTER_GITDIR_VICTIM/config"
printf 'preserve entered replacement\n' > "$ENTER_GITDIR_VICTIM/sentinel"
write_canonical_settings "$ENTER_GITDIR_HOME/.claude/settings.json"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" \
    "$ENTER_GITDIR_BIN/"
cat > "$ENTER_GITDIR_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${1:-}" = -I ] && [ "${2:-}" = -S ] && [ "${3:-}" = - ] \
    || exit 97
mode=${4:-}
script_file=$(mktemp "${TMPDIR:-/tmp}/enter-gitdir-python.XXXXXX")
trap 'rm -f "$script_file"' EXIT
cat > "$script_file"
if [ "$mode" = verify-git ] \
    && [ "$(cat "$ENTER_GITDIR_MARKER" 2>/dev/null || :)" = 1 ]; then
    mv "$ENTER_GITDIR_NAMED" "$ENTER_GITDIR_VICTIM"
    mv "$ENTER_GITDIR_ORIGINAL" "$ENTER_GITDIR_NAMED"
    printf '2\n' > "$ENTER_GITDIR_MARKER"
fi
shift 3
set +e
output=$("$REAL_PYTHON3" -I -S "$script_file" "$@")
python_status=$?
set -e
if [ "$python_status" -eq 0 ] && [ "$mode" = bind ]; then
    mv "$ENTER_GITDIR_NAMED" "$ENTER_GITDIR_ORIGINAL"
    mv "$ENTER_GITDIR_VICTIM" "$ENTER_GITDIR_NAMED"
    printf '1\n' > "$ENTER_GITDIR_MARKER"
fi
if [ -n "$output" ]; then
    printf '%s\n' "$output"
fi
exit "$python_status"
SH
chmod +x "$ENTER_GITDIR_BIN/python3"
enter_gitdir_victim_before="$(settings_write_fingerprint \
    "$ENTER_GITDIR_VICTIM/sentinel")"
HOME="$ENTER_GITDIR_HOME" \
PATH="$ENTER_GITDIR_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$ENTER_GITDIR_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
ENTER_GITDIR_NAMED="$ENTER_GITDIR_NAMED" \
ENTER_GITDIR_ORIGINAL="$ENTER_GITDIR_ORIGINAL" \
ENTER_GITDIR_VICTIM="$ENTER_GITDIR_VICTIM" \
ENTER_GITDIR_MARKER="$ENTER_GITDIR_MARKER" \
REAL_PYTHON3="$REAL_PYTHON3" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
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
REAL_PYTHON3="$(command -v python3)"
mkdir -p "$ANCESTOR_PARENT" "$ANCESTOR_VICTIM_PARENT" \
    "$ANCESTOR_HOME/.agent_brain/knowledge/.git" "$ANCESTOR_BIN"
cat > "$ANCESTOR_PARENT/settings.json" <<'JSON'
{
  "extraKnownMarketplaces": {},
  "enabledPlugins": {}
}
JSON
cp "$ANCESTOR_PARENT/settings.json" "$ANCESTOR_VICTIM_SETTINGS"
cp "$FAKE_BIN/claude" "$FAKE_BIN/codex" "$FAKE_BIN/git" "$ANCESTOR_BIN/"
cat > "$ANCESTOR_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
invocation=0
if [ -f "$ANCESTOR_SWAP_MARKER" ]; then
    read -r invocation < "$ANCESTOR_SWAP_MARKER"
fi
invocation=$((invocation + 1))
printf '%s\n' "$invocation" > "$ANCESTOR_SWAP_MARKER"
if [ "$invocation" -eq 2 ]; then
    mv "$ANCESTOR_PARENT" "$ANCESTOR_ORIGINAL_PARENT"
    mv "$ANCESTOR_VICTIM_PARENT" "$ANCESTOR_PARENT"
fi
exec "$REAL_PYTHON3" "$@"
SH
chmod +x "$ANCESTOR_BIN/python3"
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
GIT_LOG="$ANCESTOR_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
ANCESTOR_SWAP_MARKER="$ANCESTOR_SWAP_MARKER" \
ANCESTOR_PARENT="$ANCESTOR_PARENT" \
ANCESTOR_ORIGINAL_PARENT="$ANCESTOR_ORIGINAL_PARENT" \
ANCESTOR_VICTIM_PARENT="$ANCESTOR_VICTIM_PARENT" \
REAL_PYTHON3="$REAL_PYTHON3" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
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
mkdir -p "$TEMP_FAILURE_HOME/.claude" \
    "$TEMP_FAILURE_HOME/.agent_brain/knowledge/.git" \
    "$TEMP_FAILURE_BIN"
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
cat > "$TEMP_FAILURE_BIN/python3" <<'SH'
#!/usr/bin/env bash
set -eu
script_file="$(mktemp "${TMPDIR:-/tmp}/settings-python.XXXXXX")"
trap 'rm -f "$script_file" "$script_file.injected"' EXIT
cat > "$script_file"
if grep -q '^def reconcile():' "$script_file"; then
    awk '
        $0 == "        os.replace(" {
            print "        os.rename(output_name, \".retained-settings-output\", src_dir_fd=parent_descriptor, dst_dir_fd=parent_descriptor)"
            print "        victim_descriptor = os.open(output_name, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600, dir_fd=parent_descriptor)"
            print "        os.write(victim_descriptor, b\"preserve mutable-name victim\\n\")"
            print "        os.close(victim_descriptor)"
            print "        with open(os.environ[\"TEMP_FAILURE_MARKER\"], \"w\", encoding=\"utf-8\") as marker_stream:"
            print "            marker_stream.write(output_name)"
            print "        raise OSError(\"injected settings publication failure\")"
        }
        { print }
    ' "$script_file" > "$script_file.injected"
    mv "$script_file.injected" "$script_file"
fi
[ "${1:-}" = -I ] && [ "${2:-}" = -S ] && [ "${3:-}" = - ] || exit 97
shift 3
exec "$REAL_PYTHON3" -I -S "$script_file" "$@"
SH
chmod +x "$TEMP_FAILURE_BIN/python3"

HOME="$TEMP_FAILURE_HOME" \
PATH="$TEMP_FAILURE_BIN:/usr/bin:/bin" \
TEMP_FAILURE_MARKER="$TEMP_FAILURE_MARKER" \
REAL_PYTHON3="$REAL_PYTHON3" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$TEMP_FAILURE_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
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
BROKEN_CLAUDE_BIN="$TMP/broken-claude-bin"
BROKEN_CLAUDE_HOME="$TMP/broken-claude-home"
BROKEN_CLAUDE_GIT_LOG="$TMP/broken-claude-git.log"
mkdir -p "$BROKEN_CLAUDE_BIN" "$BROKEN_CLAUDE_HOME/.claude" \
    "$BROKEN_CLAUDE_HOME/.agent_brain/knowledge/.git"
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
INSTALL=false \
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
mkdir -p "$POSTCONDITION_BIN" "$POSTCONDITION_HOME/.claude" \
    "$POSTCONDITION_HOME/.agent_brain/knowledge/.git"
cp "$FAKE_BIN/git" "$FAKE_BIN/codex" "$POSTCONDITION_BIN/"
cat > "$POSTCONDITION_BIN/curl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' '#!/usr/bin/env bash' 'exit 0'
SH
chmod +x "$POSTCONDITION_BIN/curl"
cp "$WEIRD_SETTINGS" "$POSTCONDITION_HOME/.claude/settings.json"
HOME="$POSTCONDITION_HOME" \
PATH="$POSTCONDITION_BIN:/usr/bin:/bin" \
INSTALL=true \
ODYSSEUS_ROOT="$FAKE_ROOT" \
GIT_LOG="$POSTCONDITION_GIT_LOG" \
SKILL_MARKER="$SKILL_MARKER" \
    bash "$ROOT/scripts/install/60-claude-tooling.sh" \
    >"$TMP/postcondition-output" 2>&1
postcondition_status=$?

if [ "$postcondition_status" -eq 0 ] && \
   grep -q 'installer completed but no executable returned a valid version' \
       "$TMP/postcondition-output" && \
   ! grep -q 'claude installed' "$TMP/postcondition-output"; then
    pass "installer success is not reported before a valid version postcondition"
else
    fail "installer transport success bypassed the executable postcondition"
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
    "-c core.attributesFile=/dev/null -c core.fsmonitor=false -c core.hooksPath=/dev/null -c credential.helper= -c credential.interactive=false -c protocol.allow=never -c protocol.https.allow=always -c protocol.file.allow=never -c http.sslVerify=true -c http.sslCAPath= -c http.curloptResolve= clone --depth 1 --branch main --single-branch -- https://github.com/HomericIntelligence/Mnemosyne.git ." \
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
    '^-c core[.]attributesFile=/dev/null -c core[.]fsmonitor=false -c core[.]hooksPath=/dev/null -c credential[.]helper= -c credential[.]interactive=false -c protocol[.]allow=never -c protocol[.]https[.]allow=always -c protocol[.]file[.]allow=never -c http[.]sslVerify=true -c http[.]sslCAPath= -c http[.]curloptResolve= --git-dir=[.] --work-tree=[.][.] -c url[.]https://github[.]com/HomericIntelligence/Mnemosyne[.]git[.]insteadOf=https://github[.]com/HomericIntelligence/Mnemosyne[.]git/[.]homeric-bound-[0-9a-f]{32} pull --ff-only --no-recurse-submodules https://github[.]com/HomericIntelligence/Mnemosyne[.]git/[.]homeric-bound-[0-9a-f]{32} main$' \
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
