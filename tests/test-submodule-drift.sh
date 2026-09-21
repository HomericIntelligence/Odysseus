#!/usr/bin/env bash
# Hermetic behavior tests for read-only, fail-closed submodule drift checks.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

TMP_PARENT="$(CDPATH='' cd -P -- "${TMPDIR:-/tmp}" && pwd -P)"
TMP_PREFIX="${TMP_PARENT%/}/odysseus-submodule-drift."
TMP=""
TMP_VALID=false
suite_completed=0

make_fixture_directory() {
    local prefix="$1" created suffix
    if ! created="$(mktemp -d "${prefix}XXXXXX")"; then
        return 1
    fi
    suffix="${created#"$prefix"}"
    if [ -z "$created" ] || [ "$suffix" = "$created" ] || [ -z "$suffix" ] \
        || [ ! -d "$created" ] || [ -L "$created" ]; then
        return 1
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*) return 1 ;;
    esac
    printf '%s\n' "$created"
}

cleanup_fixture() {
    local incoming_status="$1" suffix cleanup_status=0
    trap - EXIT
    if [ "$TMP_VALID" != true ]; then
        cleanup_status=79
    else
    suffix="${TMP#"$TMP_PREFIX"}"
    if [ -z "$TMP" ] || [ "$suffix" = "$TMP" ] || [ -z "$suffix" ] \
        || [ ! -d "$TMP" ] || [ -L "$TMP" ]; then
        printf 'ERROR: refusing unsafe drift fixture cleanup: %s\n' "$TMP" >&2
        cleanup_status=79
    else
        case "$suffix" in
            *[!A-Za-z0-9]*)
                printf 'ERROR: refusing unsafe drift fixture cleanup: %s\n' "$TMP" >&2
                cleanup_status=79
                ;;
        esac
    fi
    if [ "$cleanup_status" -eq 0 ] && ! rm -rf -- "$TMP"; then
        printf 'ERROR: failed to remove drift fixture: %s\n' "$TMP" >&2
        cleanup_status=79
    elif [ "$cleanup_status" -eq 0 ] \
        && [ "${ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE:-0}" = 1 ]; then
        printf '%s\n' 'ERROR: controlled drift cleanup failure' >&2
        cleanup_status=79
    fi
    fi
    if [ "$incoming_status" -ne 0 ]; then
        exit "$incoming_status"
    fi
    if [ "$suite_completed" -ne 1 ]; then
        printf '%s\n' 'ERROR: drift suite did not reach its completion marker' >&2
        exit 78
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        exit "$cleanup_status"
    fi
    exit 0
}

if ! TMP="$(make_fixture_directory "$TMP_PREFIX")"; then
    printf '%s\n' 'ERROR: could not create a safe drift fixture' >&2
    exit 1
fi
TMP_VALID=true
trap 'cleanup_fixture "$?"' EXIT

case "${ODYSSEUS_TEST_HARNESS_PROBE:-}" in
    fatal) exit 73 ;;
    incomplete) exit 0 ;;
    complete)
        suite_completed=1
        exit 0
        ;;
esac
FIXTURE="$TMP/repo"
FAKE_BIN="$TMP/bin"
GIT_LOG="$TMP/git.log"
PYTHON_LOG="$TMP/python.log"
REAL_PYTHON="$(command -v python3)"
REAL_GIT="$(command -v git)"
ROOT_COMMIT=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
# Never let CI runner output paths or shell startup hooks enter a hermetic
# fixture. Individual cases below inject only paths rooted under $TMP.
unset BASH_ENV GITHUB_OUTPUT PYTHONPATH GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR \
    GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_CONFIG \
    GIT_CONFIG_GLOBAL GIT_CONFIG_SYSTEM GIT_CONFIG_NOSYSTEM GIT_CONFIG_COUNT \
    GIT_CONFIG_KEY_0 GIT_CONFIG_VALUE_0 GIT_CONFIG_PARAMETERS \
    GIT_SSH GIT_SSH_COMMAND GIT_ASKPASS GIT_PROXY_COMMAND \
    GIT_PROTOCOL_FROM_USER GIT_ALLOW_PROTOCOL GIT_EXEC_PATH
CHECKER_SHELL="${ODYSSEUS_TEST_SHELL:-$BASH}"
# shellcheck disable=SC2016  # Expanded by the selected child Bash.
CHECKER_BASH_VERSION="$("$CHECKER_SHELL" -c \
    'printf "%s.%s.%s" "${BASH_VERSINFO[0]}" "${BASH_VERSINFO[1]}" "${BASH_VERSINFO[2]}"')"
mkdir -p "$FIXTURE/.git" "$FIXTURE/components/Alpha/.git" \
    "$FIXTURE/scripts" "$FAKE_BIN"
printf '%s\n' 'ref: refs/heads/main' > "$FIXTURE/.git/HEAD"
printf '%s\n' '[core]' '    repositoryformatversion = 0' \
    > "$FIXTURE/.git/config"
printf '%s\n' 'ref: refs/heads/main' > "$FIXTURE/components/Alpha/.git/HEAD"
printf '%s\n' '[core]' '    repositoryformatversion = 0' \
    > "$FIXTURE/components/Alpha/.git/config"
cp "$ROOT/scripts/check-submodule-drift.sh" \
    "$FIXTURE/scripts/check-submodule-drift.sh"
cp "$ROOT/scripts/safe_report_publish.py" "$FIXTURE/scripts/safe_report_publish.py"

append_submodule() {
    local name="$1" path="$2" url="$3"
    printf '[submodule "%s"]\n' "$name" >> "$FIXTURE/.gitmodules"
    [ "$path" = __OMIT__ ] \
        || printf '    path = %s\n' "$path" >> "$FIXTURE/.gitmodules"
    [ "$url" = __OMIT__ ] \
        || printf '    url = %s\n' "$url" >> "$FIXTURE/.gitmodules"
}

write_inventory() {
    local mode="$1"
    : > "$FIXTURE/.gitmodules"
    case "$mode" in
        current|partial-tree|partial-symref|partial-upstream|mismatched-head|\
        extra-tree|extra-symref|extra-upstream|drift|behind|ahead|diverged|\
        hang-remote|flood-remote|escaped-remote|cancel-remote|zero-oid|hang-repo|pipe-eof-repo|\
        flood-repo|slow-total|swap-publisher|\
        swap-submodule|\
        swap-gitmodules|symlink-gitmodules)
            append_submodule Alpha components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        partial-inventory)
            append_submodule Alpha components/Alpha __OMIT__
            ;;
        partial-url-inventory)
            append_submodule Alpha __OMIT__ \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        duplicate-name)
            append_submodule Alpha components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            append_submodule Alpha components/Alternate \
                https://github.com/HomericIntelligence/Alternate.git
            ;;
        duplicate-path)
            append_submodule Alpha components/Agents \
                https://github.com/HomericIntelligence/Alpha.git
            append_submodule Beta components/Agents \
                https://github.com/HomericIntelligence/Beta.git
            ;;
        duplicate-url-entry)
            printf '%s\n' \
                '[submodule "Alpha"]' \
                '    path = components/Alpha' \
                '    url = https://github.com/HomericIntelligence/Alpha.git' \
                '    url = https://github.com/HomericIntelligence/Beta.git' \
                > "$FIXTURE/.gitmodules"
            ;;
        orphan-url|missing-url)
            append_submodule Alpha components/Alpha __OMIT__
            ;;
        duplicate-repo-url)
            append_submodule Alpha components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            append_submodule Beta components/Beta \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        nested-url)
            append_submodule Alpha components/Alpha \
                https://github.com/HomericIntelligence/team/Alpha.git
            ;;
        prefix-url)
            append_submodule Alpha components/Alpha \
                prefix-https://github.com/HomericIntelligence/Alpha.git
            ;;
        suffix-url)
            append_submodule Alpha components/Alpha \
                'https://github.com/HomericIntelligence/Alpha.git?ref=main'
            ;;
        scheme-url)
            append_submodule Alpha components/Alpha \
                http://github.com/HomericIntelligence/Alpha.git
            ;;
        host-url)
            append_submodule Alpha components/Alpha \
                https://example.com/HomericIntelligence/Alpha.git
            ;;
        org-url)
            append_submodule Alpha components/Alpha \
                https://github.com/OtherOrg/Alpha.git
            ;;
        dot-name)
            append_submodule components/./Alpha components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        dot-path)
            append_submodule Alpha components/./Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        leading-dot-name)
            append_submodule ../Alpha components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        terminal-dot-name)
            append_submodule Alpha/.. components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        trailing-slash-name)
            append_submodule Alpha/ components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        leading-dot-path)
            append_submodule Alpha ./components/Alpha \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        terminal-dot-path)
            append_submodule Alpha components/Alpha/. \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        trailing-slash-path)
            append_submodule Alpha components/Alpha/ \
                https://github.com/HomericIntelligence/Alpha.git
            ;;
        *) return 1 ;;
    esac
}

write_inventory current

cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$GIT_LOG"
if [ "${ASSERT_CLEAN_GIT_ENV:-0}" = 1 ]; then
    if [ -n "${GIT_DIR+x}" ] || [ -n "${GIT_WORK_TREE+x}" ] \
        || [ -n "${GIT_COMMON_DIR+x}" ] \
        || [ -n "${GIT_OBJECT_DIRECTORY+x}" ] \
        || [ -n "${GIT_ALTERNATE_OBJECT_DIRECTORIES+x}" ] \
        || [ -n "${GIT_CONFIG+x}" ] \
        || [ "${GIT_CONFIG_GLOBAL:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_SYSTEM:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_NOSYSTEM:-}" != 1 ] \
        || [ "${GIT_CONFIG_COUNT:-}" != 0 ] \
        || [ -n "${GIT_CONFIG_PARAMETERS+x}" ] \
        || [ -n "${GIT_SSH+x}" ] || [ -n "${GIT_SSH_COMMAND+x}" ] \
        || [ -n "${GIT_ASKPASS+x}" ] || [ -n "${GIT_PROXY_COMMAND+x}" ] \
        || [ -n "${GIT_PROTOCOL_FROM_USER+x}" ] \
        || [ -n "${GIT_ALLOW_PROTOCOL+x}" ] \
        || [ -n "${GIT_EXEC_PATH+x}" ] \
        || [ "${GIT_OPTIONAL_LOCKS:-}" != 0 ] \
        || [ -n "${GIT_TRACE+x}" ] || [ -n "${GIT_TRACE2+x}" ] \
        || [ -n "${GIT_TRACE2_EVENT+x}" ] \
        || [ -n "${LD_PRELOAD+x}" ] || [ -n "${LD_LIBRARY_PATH+x}" ] \
        || [ -n "${DYLD_INSERT_LIBRARIES+x}" ] \
        || [ -n "${ODYSSEUS_UNRELATED_ENV+x}" ] \
        || [ "${HOME:-}" = "${HOSTILE_HOME:-}" ]; then
        printf '%s\n' 'unclean Git environment' >> "$GIT_LOG"
        exit 98
    fi
fi
if [ "${GIT_MODE:-current}" = leader-order ] \
    && [ ! -e "$FIXTURE_ROOT/.leader-order-done" ]; then
    : > "$FIXTURE_ROOT/.leader-order-done"
    leader=$$
    (
        trap '
            if kill -0 "$leader" 2>/dev/null; then
                printf "%s\n" term-before-reap > "$RUNNER_ORDER_FILE"
            else
                printf "%s\n" leader-reaped-before-term > "$RUNNER_ORDER_FILE"
            fi
            exit 0
        ' TERM
        while :; do :; done
    ) </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$RUNNER_DESCENDANT_PID_FILE"
    printf '%s\n' "$FIXTURE_ROOT"
    exit 0
fi
if [ "${GIT_MODE:-current}" = post-popen-exception ]; then
    printf '%s\n' "$$" > "$RUNNER_LEADER_PID_FILE"
    (
        while :; do
            /bin/sleep 1
        done
    ) </dev/null >/dev/null 2>&1 &
    printf '%s\n' "$!" > "$RUNNER_DESCENDANT_PID_FILE"
    : > "$RUNNER_READY_FILE"
    wait
fi
if [ "${GIT_MODE:-current}" = permission-denied ]; then
    printf '%s\n' "$$" > "$RUNNER_LEADER_PID_FILE"
    : > "$RUNNER_READY_FILE"
    while :; do :; done
fi
GIT_CWD=""
if [ "${1:-}" = -C ]; then
    GIT_CWD="${2:-}"
    shift 2
fi
if [ "${REAL_GIT_DELEGATE:-0}" = 1 ] && [ -n "$GIT_CWD" ]; then
    if [ "$GIT_CWD" = "$REAL_FIXTURE_ROOT" ]; then
        if [ "${GIT_MODE:-}" = real-swap-root-gitdir ] \
            && [ "${1:-}" = ls-tree ] \
            && [ ! -e "$REAL_SWAP_MARKER" ]; then
            : > "$REAL_SWAP_MARKER"
            mv "$REAL_ROOT_GITDIR_TARGET" "$REAL_ROOT_GITDIR_BACKUP"
            cp -R "$REAL_ROOT_GITDIR_BACKUP" "$REAL_ROOT_GITDIR_TARGET"
        fi
        exec "$REAL_GIT" -C "$GIT_CWD" "$@"
    fi
    if [ "$GIT_CWD" = "$REAL_FIXTURE_LOCAL" ]; then
        if [ "${GIT_MODE:-}" = real-swap-local-gitdir ] \
            && [ "${1:-}" = cat-file ] \
            && [ ! -e "$REAL_SWAP_MARKER" ]; then
            : > "$REAL_SWAP_MARKER"
            mv "$REAL_LOCAL_GITDIR_TARGET" "$REAL_LOCAL_GITDIR_BACKUP"
            cp -R "$REAL_LOCAL_GITDIR_BACKUP" "$REAL_LOCAL_GITDIR_TARGET"
        fi
        exec "$REAL_GIT" -C "$GIT_CWD" "$@"
    fi
fi
if [ "${REAL_GIT_DELEGATE:-0}" = 1 ] && [ "${1:-}" = ls-remote ]; then
    if [ "${2:-}" = --symref ]; then
        printf '%s\n' 'ref: refs/heads/main HEAD' "$REAL_UPSTREAM HEAD"
    else
        printf '%s\t%s\n' "$REAL_UPSTREAM" 'refs/heads/main'
    fi
    exit 0
fi
if [ "${1:-}" = rev-parse ]; then
    if [ "${GIT_MODE:-current}" = hang-repo ]; then
        sleep 5
        exit 88
    fi
    if [ "${GIT_MODE:-current}" = pipe-eof-repo ]; then
        (sleep 30) &
        printf '%s\n' "$!" > "${DESCENDANT_PID_FILE:?}"
        printf '%s\n' "$FIXTURE_ROOT"
        exit 0
    fi
    if [ "${GIT_MODE:-current}" = flood-repo ]; then
        /usr/bin/python3 - <<'PY'
import sys
sys.stdout.write("x" * (300 * 1024))
PY
        exit 0
    fi
    if [ "${2:-}" = --verify ] && [ "${3:-}" = 'HEAD^{commit}' ]; then
        printf '%s\n' "$ROOT_COMMIT"
        exit 0
    fi
    if [ -z "$GIT_CWD" ] || [ "$GIT_CWD" = "$FIXTURE_ROOT" ]; then
        printf '%s\n' "$FIXTURE_ROOT"
    elif [ "$GIT_CWD" = "$FIXTURE_ROOT/components/Alpha" ]; then
        printf '%s\n' "$FIXTURE_ROOT/components/Alpha"
    else
        printf '%s\n' "$FIXTURE_ROOT/decoy"
    fi
    exit 0
fi
if [ "${1:-}" = ls-tree ]; then
    if [ "${GIT_MODE:-current}" = swap-publisher ] \
        && [ ! -e "$FIXTURE_ROOT/.swap-publisher-done" ]; then
        : > "$FIXTURE_ROOT/.swap-publisher-done"
        mv "$PUBLISHER_PATH" "$PUBLISHER_PATH.original"
        cat > "$PUBLISHER_PATH" <<'PY'
import os
from pathlib import Path

Path(os.environ["PUBLISHER_MARKER"]).write_text("replacement ran\n")
raise SystemExit(2)
PY
    fi
    if [ "${ASSERT_IMMUTABLE_ROOT:-0}" = 1 ] \
        && [ "${2:-}" != "$ROOT_COMMIT" ]; then
        printf '%s\n' 'mutable root revision' >> "$GIT_LOG"
        exit 97
    fi
    case "${GIT_MODE:-current}" in
        swap-root-gitdir)
            if [ ! -e "$FIXTURE_ROOT/.swap-root-gitdir-done" ]; then
                : > "$FIXTURE_ROOT/.swap-root-gitdir-done"
                mv "$ROOT_GITDIR_TARGET" "$ROOT_GITDIR_BACKUP"
                cp -R "$ROOT_GITDIR_BACKUP" "$ROOT_GITDIR_TARGET"
            fi
            ;;
        swap-root-common)
            if [ ! -e "$FIXTURE_ROOT/.swap-root-common-done" ]; then
                : > "$FIXTURE_ROOT/.swap-root-common-done"
                mv "$ROOT_COMMON_TARGET" "$ROOT_COMMON_BACKUP"
                cp -R "$ROOT_COMMON_BACKUP" "$ROOT_COMMON_TARGET"
            fi
            ;;
        swap-root-config)
            if [ ! -e "$FIXTURE_ROOT/.swap-root-config-done" ]; then
                : > "$FIXTURE_ROOT/.swap-root-config-done"
                printf '%s\n' '[core]' '    repositoryformatversion = 1' \
                    > "$ROOT_CONFIG_PATH"
            fi
            ;;
    esac
    if [ "${GIT_MODE:-current}" = swap-gitmodules ] \
        && [ ! -e "$FIXTURE_ROOT/.swap-gitmodules-done" ]; then
        : > "$FIXTURE_ROOT/.swap-gitmodules-done"
        mv "$FIXTURE_ROOT/.gitmodules" "$FIXTURE_ROOT/.gitmodules-original"
        printf '%s\n' \
            '[submodule "Decoy"]' \
            '    path = components/Decoy' \
            '    url = https://github.com/HomericIntelligence/Decoy.git' \
            > "$FIXTURE_ROOT/.gitmodules"
    fi
    if [ "${GIT_MODE:-current}" = symlink-gitmodules ] \
        && [ ! -e "$FIXTURE_ROOT/.swap-gitmodules-done" ]; then
        : > "$FIXTURE_ROOT/.swap-gitmodules-done"
        mv "$FIXTURE_ROOT/.gitmodules" "$FIXTURE_ROOT/.gitmodules-original"
        ln -s "$FIXTURE_ROOT/.gitmodules-victim" "$FIXTURE_ROOT/.gitmodules"
    fi
    printf '%s\t%s\n' \
        '160000 commit 1111111111111111111111111111111111111111' \
        'components/Alpha'
    [ "${GIT_MODE:-current}" != partial-tree ] || exit 45
    if [ "${GIT_MODE:-current}" = extra-tree ]; then
        printf '%s\t%s\n' \
            '160000 commit 2222222222222222222222222222222222222222' \
            'components/Unexpected'
    fi
    exit 0
fi
if [ "${1:-}" = ls-remote ] && [ "${2:-}" = --symref ]; then
    if [ "${GIT_MODE:-current}" = slow-total ]; then
        sleep 1.1
    fi
    if [ "${GIT_MODE:-current}" = hang-remote ]; then
        sleep 5
        exit 88
    fi
    if [ "${GIT_MODE:-current}" = flood-remote ]; then
        /usr/bin/python3 - <<'PY'
import sys
sys.stdout.write("x" * (300 * 1024))
PY
        exit 0
    fi
    if [ "${GIT_MODE:-current}" = escaped-remote ]; then
        /usr/bin/python3 -I -S -c '
import os
import signal
import time

heartbeat = os.environ["DETACHED_HEARTBEAT_FILE"]
stop = os.environ["DETACHED_STOP_FILE"]
identity = os.environ["DETACHED_IDENTITY_FILE"]

def fork_after_cleanup_starts(_number, _frame):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    ready_read, ready_write = os.pipe()
    child = os.fork()
    if child:
        os.close(ready_write)
        os.read(ready_read, 1)
        os._exit(0)
    os.close(ready_read)
    os.setsid()
    detached = os.fork()
    if detached:
        os._exit(0)
    os.setsid()
    for descriptor in (0, 1, 2):
        try:
            os.close(descriptor)
        except OSError:
            pass
    with open(f"/proc/{os.getpid()}/stat", "rb", buffering=0) as stream:
        stat_line = stream.read(65537)
    closing = stat_line.rfind(b")")
    start_time = int(stat_line[closing + 2 :].split()[19])
    with open(identity, "w", encoding="ascii") as stream:
        stream.write(f"{os.getpid()} {start_time}\n")
    count = 0
    with open(heartbeat, "w", encoding="ascii") as stream:
        stream.write(f"{count:020d}\n")
    os.write(ready_write, b"1")
    os.close(ready_write)
    while not os.path.exists(stop):
        count += 1
        with open(heartbeat, "w", encoding="ascii") as stream:
            stream.write(f"{count:020d}\n")
        time.sleep(0.01)
    os._exit(0)

signal.signal(signal.SIGTERM, fork_after_cleanup_starts)
while True:
    signal.pause()
'
    fi
    if [ "${GIT_MODE:-current}" = cancel-remote ]; then
        exec /usr/bin/python3 -I -S - \
            "${CANCEL_IDENTITY_FILE:?}" \
            "${CANCEL_HEARTBEAT_FILE:?}" <<'PY'
import os
import signal
import sys
import time


identity_path, heartbeat_path = sys.argv[1:]


def process_start_time(process_id):
    with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
        content = stream.read(65537)
    closing = content.rfind(b")")
    return int(content[closing + 2:].split()[19])


for number in (signal.SIGHUP, signal.SIGINT, signal.SIGQUIT, signal.SIGTERM):
    signal.signal(number, signal.SIG_IGN)
descendant = os.fork()
if descendant == 0:
    for descriptor in (0, 1, 2):
        try:
            os.close(descriptor)
        except OSError:
            pass
    while True:
        with open(heartbeat_path, "ab", buffering=0) as stream:
            stream.write(b"x")
        time.sleep(0.02)
runner = os.getppid()
with open(identity_path, "w", encoding="ascii") as stream:
    stream.write(
        f"{runner} {process_start_time(runner)} "
        f"{os.getpid()} {process_start_time(os.getpid())} "
        f"{descendant} {process_start_time(descendant)}\n"
    )
while True:
    time.sleep(1)
PY
    fi
    if [ "${GIT_MODE:-current}" = zero-oid ]; then
        printf '%s\n' \
            'ref: refs/heads/main HEAD' \
            '0000000000000000000000000000000000000000 HEAD'
        exit 0
    fi
    case "${GIT_MODE:-current}" in
        drift|behind|ahead|diverged|swap-submodule|swap-local-gitdir|\
        swap-local-config)
        symref_sha=2222222222222222222222222222222222222222
        ;;
        *)
        symref_sha=1111111111111111111111111111111111111111
        ;;
    esac
    printf '%s\n' \
        'ref: refs/heads/main HEAD' \
        "$symref_sha HEAD"
    [ "${GIT_MODE:-current}" != partial-symref ] || exit 46
    if [ "${GIT_MODE:-current}" = extra-symref ]; then
        printf '%s\n' \
            '3333333333333333333333333333333333333333 refs/heads/unexpected'
    fi
    exit 0
fi
if [ "${1:-}" = ls-remote ]; then
    if [ "${GIT_MODE:-current}" = slow-total ]; then
        sleep 1.1
    fi
    if [ "${GIT_MODE:-current}" = zero-oid ]; then
        printf '%s\t%s\n' \
            '0000000000000000000000000000000000000000' \
            'refs/heads/main'
        exit 0
    fi
    case "${GIT_MODE:-current}" in
        drift|behind|ahead|diverged|swap-submodule|swap-local-gitdir|\
        swap-local-config|mismatched-head)
        sha=2222222222222222222222222222222222222222
        ;;
        *)
        sha=1111111111111111111111111111111111111111
        ;;
    esac
    printf '%s\t%s\n' "$sha" 'refs/heads/main'
    [ "${GIT_MODE:-current}" != partial-upstream ] || exit 47
    if [ "${GIT_MODE:-current}" = extra-upstream ]; then
        printf '%s\t%s\n' \
            '3333333333333333333333333333333333333333' \
            'refs/heads/main'
    fi
    exit 0
fi
if [ -n "$GIT_CWD" ]; then
    pinned=1111111111111111111111111111111111111111
    upstream=2222222222222222222222222222222222222222
    case "${1:-}" in
        cat-file)
            if [ "${GIT_MODE:-current}" = swap-submodule ] \
                && [ ! -e "$FIXTURE_ROOT/.swap-submodule-done" ]; then
                : > "$FIXTURE_ROOT/.swap-submodule-done"
                mv "$GIT_CWD" "$FIXTURE_ROOT/components/Alpha-original"
                ln -s "$FIXTURE_ROOT/components/Alpha-victim" "$GIT_CWD"
            fi
            if [ "${GIT_MODE:-current}" = swap-local-gitdir ] \
                && [ ! -e "$FIXTURE_ROOT/.swap-local-gitdir-done" ]; then
                : > "$FIXTURE_ROOT/.swap-local-gitdir-done"
                mv "$LOCAL_GITDIR_TARGET" "$LOCAL_GITDIR_BACKUP"
                cp -R "$LOCAL_GITDIR_BACKUP" "$LOCAL_GITDIR_TARGET"
            fi
            if [ "${GIT_MODE:-current}" = swap-local-config ] \
                && [ ! -e "$FIXTURE_ROOT/.swap-local-config-done" ]; then
                : > "$FIXTURE_ROOT/.swap-local-config-done"
                printf '%s\n' '[core]' '    repositoryformatversion = 1' \
                    > "$LOCAL_CONFIG_PATH"
            fi
            case "${GIT_MODE:-current}" in
                behind|ahead|diverged|swap-submodule|swap-local-gitdir|\
                swap-local-config) exit 0 ;;
                *) exit 1 ;;
            esac
            ;;
        merge-base)
            left="${3:-}"
            right="${4:-}"
            case "${GIT_MODE:-current}:$left:$right" in
                behind:$pinned:$upstream|ahead:$upstream:$pinned) exit 0 ;;
                behind:$upstream:$pinned|ahead:$pinned:$upstream|diverged:*) exit 1 ;;
                *) exit 94 ;;
            esac
            ;;
        rev-list)
            [ "${2:-}" = --count ] || exit 95
            case "${GIT_MODE:-current}" in
                behind)
                    [ "${3:-}" = "$pinned..$upstream" ] || exit 95
                    printf '3\n'
                    ;;
                ahead)
                    [ "${3:-}" = "$upstream..$pinned" ] || exit 95
                    printf '2\n'
                    ;;
                diverged)
                    case "${3:-}" in
                        "$pinned..$upstream") printf '3\n' ;;
                        "$upstream..$pinned") printf '2\n' ;;
                        *) exit 95 ;;
                    esac
                    ;;
                *) exit 95 ;;
            esac
            ;;
        show) printf '2026-09-15\n' ;;
        *) exit 93 ;;
    esac
    exit 0
fi
exit 94
SH
chmod +x "$FAKE_BIN/git"

cat > "$FAKE_BIN/python3" <<'SH'
#!/usr/bin/env bash
printf '%s %s\n' "${1:-}" "${2:-}" >> "$PYTHON_LOG"
if [ "${1:-}" != -I ] || [ "${2:-}" != -S ]; then
    printf '%s\n' 'test python wrapper: missing -I -S' >&2
    exit 90
fi
slow_boundary=false
case "${PYTHON_MODE:-}" in
    slow-guard)
        if [ "${3:-}" = - ] && [[ ! "${4:-}" =~ ^[0-9]+$ ]]; then
            slow_boundary=true
        fi
        ;;
    slow-publisher-bind)
        if [ "${3:-}" = -c ]; then
            for argument in "$@"; do
                [ "$argument" = bind ] && slow_boundary=true
            done
        fi
        ;;
    slow-validation)
        case "${4:-}" in
            *'report = json.load(sys.stdin)'*) slow_boundary=true ;;
        esac
        ;;
    slow-publication)
        if [ "${3:-}" = -c ]; then
            for argument in "$@"; do
                [ "$argument" = publish ] && slow_boundary=true
            done
        fi
        ;;
esac
if [ "$slow_boundary" = true ] && [ ! -e "${SLOW_BOUNDARY_MARKER:?}" ]; then
    : > "${SLOW_BOUNDARY_MARKER:?}"
    /bin/sleep 5
fi
exec "$REAL_PYTHON" "$@"
SH
chmod +x "$FAKE_BIN/python3"

bind_test_dependencies() {
    local checker="$1"
    # Compile the controlled external boundaries into a private checker copy.
    # The production script keeps fixed system executable paths and has no
    # runtime environment override for either dependency.
    /usr/bin/python3 - "$checker" "$FAKE_BIN/git" "$FAKE_BIN/python3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = {
    "TRUSTED_GIT=/usr/bin/git": f"TRUSTED_GIT={sys.argv[2]}",
    "TRUSTED_PYTHON=/usr/bin/python3": f"TRUSTED_PYTHON={sys.argv[3]}",
    "TRUSTED_DATE=/bin/date": f"TRUSTED_DATE={sys.argv[2].rsplit('/', 1)[0]}/date",
    "GIT_CALL_TIMEOUT_SECONDS=20": "GIT_CALL_TIMEOUT_SECONDS=2",
    "GIT_RUNNER_TEST_ENV_KEYS=()": "GIT_RUNNER_TEST_ENV_KEYS=(GIT_LOG ASSERT_CLEAN_GIT_ENV CANCEL_HEARTBEAT_FILE CANCEL_IDENTITY_FILE DESCENDANT_PID_FILE DETACHED_HEARTBEAT_FILE DETACHED_STOP_FILE DETACHED_IDENTITY_FILE HOSTILE_HOME FIXTURE_ROOT REAL_GIT REAL_GIT_DELEGATE REAL_FIXTURE_ROOT REAL_FIXTURE_LOCAL REAL_ROOT_GITDIR_TARGET REAL_ROOT_GITDIR_BACKUP REAL_LOCAL_GITDIR_TARGET REAL_LOCAL_GITDIR_BACKUP REAL_SWAP_MARKER REAL_UPSTREAM ROOT_COMMIT ROOT_GITDIR_TARGET ROOT_GITDIR_BACKUP ROOT_COMMON_TARGET ROOT_COMMON_BACKUP ROOT_CONFIG_PATH LOCAL_GITDIR_TARGET LOCAL_GITDIR_BACKUP LOCAL_CONFIG_PATH GIT_MODE PUBLISHER_PATH PUBLISHER_MARKER RUNNER_CANCEL_POPEN_RECEIPT RUNNER_CANCEL_RELEASE_FILE RUNNER_DESCENDANT_PID_FILE RUNNER_LEADER_PID_FILE RUNNER_ORDER_FILE RUNNER_POST_POPEN_FAILURE RUNNER_READY_FILE)",
    "PYTHON_RUNNER_TEST_ENV_KEYS=()": "PYTHON_RUNNER_TEST_ENV_KEYS=(PYTHON_LOG PYTHON_MODE REAL_PYTHON SLOW_BOUNDARY_MARKER)",
    "DATE_RUNNER_TEST_ENV_KEYS=()": "DATE_RUNNER_TEST_ENV_KEYS=(DATE_MODE FIXTURE_ROOT SLOW_BOUNDARY_MARKER TEST_SWAP_ORIGINAL TEST_SWAP_VICTIM)",
}
for original, replacement in replacements.items():
    if text.count(original) != 1:
        raise SystemExit(f"test dependency seam changed: {original}")
    text = text.replace(original, replacement)
path.write_text(text, encoding="utf-8")
PY
}

bind_test_dependencies "$FIXTURE/scripts/check-submodule-drift.sh"

cat > "$FAKE_BIN/date" <<'SH'
#!/usr/bin/env bash
case "${DATE_MODE:-}" in
    slow-deadline)
        : > "${SLOW_BOUNDARY_MARKER:?}"
        /bin/sleep 5
        ;;
    invalid-success)
        printf '%s\n' 'not-a-utc-timestamp'
        exit 0
        ;;
    swap-report)
        if [ -e "$FIXTURE_ROOT/drift-report.json" ] \
            || [ -L "$FIXTURE_ROOT/drift-report.json" ]; then
            mv "$FIXTURE_ROOT/drift-report.json" "$TEST_SWAP_ORIGINAL"
        fi
        ln -s "$TEST_SWAP_VICTIM" "$FIXTURE_ROOT/drift-report.json"
        ;;
    swap-parent)
        mv "$FIXTURE_ROOT" "$TEST_SWAP_ORIGINAL"
        ln -s "$TEST_SWAP_VICTIM" "$FIXTURE_ROOT"
        ;;
esac
printf '%s\n' '2026-09-15T00:00:00Z'
SH
chmod +x "$FAKE_BIN/date"

run_drift() {
    local shell_bin="${1:-/bin/bash}"
    local checker_path="${CHECKER_PATH:-$FIXTURE/scripts/check-submodule-drift.sh}"
    if [ "$#" -gt 0 ]; then shift; fi
    : > "$GIT_LOG"
    : > "$PYTHON_LOG"
    set +e
    DRIFT_OUTPUT="$(
        GIT_LOG="$GIT_LOG" PYTHON_LOG="$PYTHON_LOG" \
        REAL_PYTHON="$REAL_PYTHON" FIXTURE_ROOT="$FIXTURE" \
        REAL_GIT="$REAL_GIT" \
        REAL_GIT_DELEGATE="${REAL_GIT_DELEGATE:-0}" \
        REAL_FIXTURE_ROOT="${REAL_FIXTURE_ROOT:-}" \
        REAL_FIXTURE_LOCAL="${REAL_FIXTURE_LOCAL:-}" \
        REAL_ROOT_GITDIR_TARGET="${REAL_ROOT_GITDIR_TARGET:-}" \
        REAL_ROOT_GITDIR_BACKUP="${REAL_ROOT_GITDIR_BACKUP:-}" \
        REAL_LOCAL_GITDIR_TARGET="${REAL_LOCAL_GITDIR_TARGET:-}" \
        REAL_LOCAL_GITDIR_BACKUP="${REAL_LOCAL_GITDIR_BACKUP:-}" \
        REAL_SWAP_MARKER="${REAL_SWAP_MARKER:-}" \
        REAL_UPSTREAM="${REAL_UPSTREAM:-}" \
        ROOT_COMMIT="$ROOT_COMMIT" \
        ROOT_GITDIR_TARGET="${ROOT_GITDIR_TARGET:-}" \
        ROOT_GITDIR_BACKUP="${ROOT_GITDIR_BACKUP:-}" \
        ROOT_COMMON_TARGET="${ROOT_COMMON_TARGET:-}" \
        ROOT_COMMON_BACKUP="${ROOT_COMMON_BACKUP:-}" \
        ROOT_CONFIG_PATH="${ROOT_CONFIG_PATH:-}" \
        LOCAL_GITDIR_TARGET="${LOCAL_GITDIR_TARGET:-}" \
        LOCAL_GITDIR_BACKUP="${LOCAL_GITDIR_BACKUP:-}" \
        LOCAL_CONFIG_PATH="${LOCAL_CONFIG_PATH:-}" \
        GIT_MODE="${GIT_MODE:-current}" \
        CANCEL_HEARTBEAT_FILE="${CANCEL_HEARTBEAT_FILE:-}" \
        CANCEL_IDENTITY_FILE="${CANCEL_IDENTITY_FILE:-}" \
        DETACHED_HEARTBEAT_FILE="${DETACHED_HEARTBEAT_FILE:-}" \
        DETACHED_STOP_FILE="${DETACHED_STOP_FILE:-}" \
        DETACHED_IDENTITY_FILE="${DETACHED_IDENTITY_FILE:-}" \
        PYTHON_MODE="${PYTHON_MODE:-}" \
        DATE_MODE="${DATE_MODE:-}" \
        SLOW_BOUNDARY_MARKER="${SLOW_BOUNDARY_MARKER:-}" \
        RUNNER_DESCENDANT_PID_FILE="${RUNNER_DESCENDANT_PID_FILE:-}" \
        RUNNER_LEADER_PID_FILE="${RUNNER_LEADER_PID_FILE:-}" \
        RUNNER_ORDER_FILE="${RUNNER_ORDER_FILE:-}" \
        RUNNER_CANCEL_POPEN_RECEIPT="${RUNNER_CANCEL_POPEN_RECEIPT:-}" \
        RUNNER_CANCEL_RELEASE_FILE="${RUNNER_CANCEL_RELEASE_FILE:-}" \
        RUNNER_POST_POPEN_FAILURE="${RUNNER_POST_POPEN_FAILURE:-}" \
        RUNNER_READY_FILE="${RUNNER_READY_FILE:-}" \
        TEST_SWAP_ORIGINAL="${TEST_SWAP_ORIGINAL:-}" \
        TEST_SWAP_VICTIM="${TEST_SWAP_VICTIM:-}" \
        TEST_PUBLISHER_SENTINEL="${TEST_PUBLISHER_SENTINEL:-}" \
        PUBLISHER_PATH="${PUBLISHER_PATH:-$FIXTURE/scripts/safe_report_publish.py}" \
        PUBLISHER_MARKER="${PUBLISHER_MARKER:-$TMP/replacement-publisher-executed}" \
        BASH_ENV="${BASH_ENV:-}" GITHUB_OUTPUT="${GITHUB_OUTPUT:-}" \
        PATH="$FAKE_BIN:/usr/bin:/bin" \
            "$shell_bin" "$checker_path" "$@" 2>&1
    )"
    DRIFT_STATUS=$?
    set -e
}

linux_process_identity_is_active() {
    /usr/bin/python3 -I -S - "$1" "$2" <<'PY'
import sys

process_id = int(sys.argv[1])
expected_start_time = int(sys.argv[2])
try:
    with open(f"/proc/{process_id}/stat", "rb", buffering=0) as stream:
        content = stream.read(65537)
except (FileNotFoundError, ProcessLookupError):
    raise SystemExit(1)
closing = content.rfind(b")")
if closing < 1:
    raise SystemExit(2)
fields = content[closing + 2 :].split()
if len(fields) <= 19:
    raise SystemExit(2)
raise SystemExit(0 if int(fields[19]) == expected_start_time else 1)
PY
}

real_git() {
    env -u BASH_ENV -u GIT_DIR -u GIT_WORK_TREE -u GIT_COMMON_DIR \
        -u GIT_INDEX_FILE \
        -u GIT_OBJECT_DIRECTORY -u GIT_ALTERNATE_OBJECT_DIRECTORIES \
        -u GIT_NAMESPACE -u GIT_CEILING_DIRECTORIES \
        -u GIT_DISCOVERY_ACROSS_FILESYSTEM \
        -u GIT_CONFIG -u GIT_CONFIG_PARAMETERS -u GIT_ATTR_SOURCE \
        -u GIT_SSH -u GIT_SSH_COMMAND -u GIT_ASKPASS -u SSH_ASKPASS \
        -u GIT_PROXY_COMMAND -u GIT_PROTOCOL_FROM_USER \
        -u GIT_ALLOW_PROTOCOL -u GIT_SSL_NO_VERIFY -u GIT_SSL_CAINFO \
        -u GIT_REPLACE_REF_BASE -u GIT_EXEC_PATH \
        HOME=/dev/null XDG_CONFIG_HOME=/dev/null \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_COUNT=0 \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_AUTHOR_NAME=Odysseus \
        GIT_AUTHOR_EMAIL=odysseus@example.invalid \
        GIT_COMMITTER_NAME=Odysseus \
        GIT_COMMITTER_EMAIL=odysseus@example.invalid \
        GIT_AUTHOR_DATE=2001-01-01T00:00:00Z \
        GIT_COMMITTER_DATE=2001-01-01T00:00:00Z \
        LC_ALL=C TZ=UTC \
        "$REAL_GIT" "$@"
}

REAL_GIT_COMMAND="$REAL_GIT"
REAL_GIT_ENV_PROBE="$TMP/real-git-env-probe"
cat > "$REAL_GIT_ENV_PROBE" <<'SH'
#!/bin/sh
for variable in GIT_NAMESPACE GIT_CEILING_DIRECTORIES \
    GIT_DISCOVERY_ACROSS_FILESYSTEM; do
    eval "value=\${$variable-}"
    [ -z "$value" ] || exit 1
done
[ "${GIT_AUTHOR_DATE:-}" = '2001-01-01T00:00:00Z' ] || exit 1
[ "${GIT_COMMITTER_DATE:-}" = '2001-01-01T00:00:00Z' ] || exit 1
SH
chmod +x "$REAL_GIT_ENV_PROBE"
REAL_GIT="$REAL_GIT_ENV_PROBE"
if GIT_NAMESPACE=ambient-namespace \
    GIT_CEILING_DIRECTORIES=/ \
    GIT_DISCOVERY_ACROSS_FILESYSTEM=1 \
    GIT_AUTHOR_DATE=2040-01-01T00:00:00Z \
    GIT_COMMITTER_DATE=2040-01-01T00:00:00Z \
    real_git probe; then
    pass "the real-Git fixture scrubs ambient discovery and fixes commit dates"
else
    fail "the real-Git fixture inherited ambient discovery or commit dates"
fi
REAL_GIT="$REAL_GIT_COMMAND"

if [ "$(/usr/bin/uname -s)" != Linux ]; then
    info "remote process containment fails closed outside Linux"
    GIT_MODE=current run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 2 ] \
        && grep -q 'exact remote Git process containment is Linux-only' \
            <<<"$DRIFT_OUTPUT"; then
        pass "an unsupported host cannot perform a remote drift read"
    else
        printf 'status=%s output=%s\n' "$DRIFT_STATUS" "$DRIFT_OUTPUT" >&2
        fail "an unsupported host accepted a remote drift read"
    fi
    pass "the complete remote-containment matrix is explicitly Linux-only"
    summary
    suite_completed=1
    if exit_code; then
        exit 0
    fi
    exit 1
fi

info "the canonical checker runs under selected Bash $CHECKER_BASH_VERSION"
ASSERT_IMMUTABLE_ROOT=1 GIT_MODE=current run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 0 ] \
    && grep -q 'All 1 submodule pins are up to date' <<<"$DRIFT_OUTPUT" \
    && ! grep -q 'mutable root revision' "$GIT_LOG"; then
    pass "Bash $CHECKER_BASH_VERSION receives a complete current inventory"
else
    fail "Bash $CHECKER_BASH_VERSION could not execute the canonical drift check"
fi

info "repository selection does not follow a symlinked checkout root"
ln -s "$FIXTURE" "$TMP/repo-link"
CHECKER_PATH="$TMP/repo-link/scripts/check-submodule-drift.sh" \
    GIT_MODE=current run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
    pass "a symlinked repository root is unavailable"
else
    fail "repository selection followed a symlinked checkout root"
fi
rm "$TMP/repo-link"

info "repository identity requires a direct .git entry"
mkdir "$TMP/root-git-decoy"
mv "$FIXTURE/.git" "$FIXTURE/.git-direct"
ln -s "$TMP/root-git-decoy" "$FIXTURE/.git"
GIT_MODE=current run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && ! grep -Eq '(^| )ls-tree( |$)|(^| )ls-remote( |$)' "$GIT_LOG"; then
    pass "a symlinked root .git entry is unavailable"
else
    fail "repository identity followed a symlinked .git entry"
fi
rm "$FIXTURE/.git"
mv "$FIXTURE/.git-direct" "$FIXTURE/.git"

info "repository identity binds a gitfile, common directory, and configuration"
ROOT_GITDIR_TARGET="$TMP/root-gitdir"
ROOT_GITDIR_BACKUP="$TMP/root-gitdir-original"
ROOT_COMMON_TARGET="$TMP/root-common"
ROOT_COMMON_BACKUP="$TMP/root-common-original"
ROOT_CONFIG_PATH="$ROOT_COMMON_TARGET/config"
mv "$FIXTURE/.git" "$ROOT_GITDIR_TARGET"
mkdir "$ROOT_COMMON_TARGET"
mv "$ROOT_GITDIR_TARGET/config" "$ROOT_CONFIG_PATH"
printf '%s\n' '../root-common' > "$ROOT_GITDIR_TARGET/commondir"
printf 'gitdir: %s\n' "$ROOT_GITDIR_TARGET" > "$FIXTURE/.git"
for root_swap_mode in swap-root-gitdir swap-root-common swap-root-config; do
    rm -f "$FIXTURE/.swap-root-gitdir-done" \
        "$FIXTURE/.swap-root-common-done" "$FIXTURE/.swap-root-config-done"
    ROOT_GITDIR_TARGET="$ROOT_GITDIR_TARGET" \
    ROOT_GITDIR_BACKUP="$ROOT_GITDIR_BACKUP" \
    ROOT_COMMON_TARGET="$ROOT_COMMON_TARGET" \
    ROOT_COMMON_BACKUP="$ROOT_COMMON_BACKUP" \
    ROOT_CONFIG_PATH="$ROOT_CONFIG_PATH" \
    GIT_MODE="$root_swap_mode" run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 2 ] \
        && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
        pass "$root_swap_mode invalidates the resolved root repository"
    else
        fail "$root_swap_mode supplied unbound root repository state"
    fi
    case "$root_swap_mode" in
        swap-root-gitdir)
            rm -rf "$ROOT_GITDIR_TARGET"
            mv "$ROOT_GITDIR_BACKUP" "$ROOT_GITDIR_TARGET"
            ;;
        swap-root-common)
            rm -rf "$ROOT_COMMON_TARGET"
            mv "$ROOT_COMMON_BACKUP" "$ROOT_COMMON_TARGET"
            ;;
        swap-root-config)
            printf '%s\n' '[core]' '    repositoryformatversion = 0' \
                > "$ROOT_CONFIG_PATH"
            ;;
    esac
done
rm "$FIXTURE/.git" "$ROOT_GITDIR_TARGET/commondir"
mv "$ROOT_CONFIG_PATH" "$ROOT_GITDIR_TARGET/config"
rmdir "$ROOT_COMMON_TARGET"
mv "$ROOT_GITDIR_TARGET" "$FIXTURE/.git"

printf '%s\n' '[include]' "    path = $TMP/decoy-git-config" \
    > "$FIXTURE/.git/config"
GIT_MODE=current run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && ! grep -Eq '(^| )ls-tree( |$)|(^| )ls-remote( |$)' "$GIT_LOG"; then
    pass "an external repository config include is unavailable"
else
    fail "an external repository config include escaped the binding"
fi
printf '%s\n' '[core]' '    repositoryformatversion = 0' \
    > "$FIXTURE/.git/config"

info "ambient Git routing and URL rewrite configuration is scrubbed"
mkdir "$TMP/hostile-home"
printf '%s\n' \
    '[url "https://example.invalid/"]' \
    '    insteadOf = https://github.com/' \
    > "$TMP/hostile-home/.gitconfig"
ASSERT_CLEAN_GIT_ENV=1 HOSTILE_HOME="$TMP/hostile-home" \
GIT_DIR="$TMP/decoy-git" GIT_WORK_TREE="$TMP/decoy-worktree" \
GIT_COMMON_DIR="$TMP/decoy-common" \
GIT_OBJECT_DIRECTORY="$TMP/decoy-objects" \
GIT_ALTERNATE_OBJECT_DIRECTORIES="$TMP/alternate-objects" \
GIT_CONFIG="$TMP/decoy-config" GIT_CONFIG_GLOBAL="$TMP/decoy-global" \
GIT_CONFIG_SYSTEM="$TMP/decoy-system" GIT_CONFIG_NOSYSTEM=0 \
GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0='url.https://example.invalid/.insteadOf' \
GIT_CONFIG_VALUE_0='https://github.com/' \
GIT_CONFIG_PARAMETERS="'url.https://example.invalid/.insteadOf'='https://github.com/'" \
GIT_SSH="$TMP/decoy-ssh" GIT_SSH_COMMAND="$TMP/decoy-ssh-command" \
GIT_ASKPASS="$TMP/decoy-askpass" GIT_PROXY_COMMAND="$TMP/decoy-proxy" \
GIT_PROTOCOL_FROM_USER=1 GIT_ALLOW_PROTOCOL=file \
GIT_EXEC_PATH="$TMP/decoy-git-exec" GIT_OPTIONAL_LOCKS=1 \
GIT_TRACE="$TMP/ambient-git-trace" GIT_TRACE2_EVENT="$TMP/ambient-trace2" \
ODYSSEUS_UNRELATED_ENV=present HOME="$TMP/hostile-home" \
GIT_MODE=current run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 0 ] \
    && ! grep -q 'unclean Git environment' "$GIT_LOG"; then
    pass "Git commands ignore ambient repository and URL routing"
else
    printf '%s\n' "$DRIFT_OUTPUT" >&2
    if ! grep -F 'unclean Git environment' "$GIT_LOG" >&2; then :; fi
    fail "an ambient Git setting reached a trusted Git command"
fi

info "the production checker does not select Git through PATH"
trusted_git_repo="$TMP/trusted-git-repo"
trusted_git_bin="$TMP/trusted-git-bin"
mkdir -p "$trusted_git_repo/scripts" "$trusted_git_bin"
cp "$ROOT/scripts/check-submodule-drift.sh" \
    "$trusted_git_repo/scripts/check-submodule-drift.sh"
cp "$ROOT/scripts/safe_report_publish.py" \
    "$trusted_git_repo/scripts/safe_report_publish.py"
/usr/bin/git -C "$trusted_git_repo" init -q
cat > "$trusted_git_repo/.gitmodules" <<'EOF'
[submodule "components/Alpha"]
    path = components/Alpha
    url = https://github.com/HomericIntelligence/Alpha.git
EOF
cat > "$trusted_git_bin/git" <<'EOF'
#!/usr/bin/env bash
: > "${HOSTILE_GIT_MARKER:?}"
exec /usr/bin/git "$@"
EOF
chmod +x "$trusted_git_bin/git"
set +e
trusted_git_output="$(
    HOSTILE_GIT_MARKER="$trusted_git_repo/hostile-git-ran" \
    PATH="$trusted_git_bin:/usr/bin:/bin" \
        "$CHECKER_SHELL" \
        "$trusted_git_repo/scripts/check-submodule-drift.sh" 2>&1
)"
trusted_git_status=$?
set -e
if [ "$trusted_git_status" -eq 2 ] \
    && [ ! -e "$trusted_git_repo/hostile-git-ran" ] \
    && grep -q 'repository commit identity unavailable' \
        <<<"$trusted_git_output"; then
    pass "a PATH Git executable has zero effects"
else
    fail "the production checker selected Git through PATH"
fi

info "exported shell functions cannot replace path-resolution builtins"
# shellcheck disable=SC2329  # Exported into the checker subprocess.
cd() {
    : > "${HOSTILE_CD_MARKER:?}"
    return 90
}
# shellcheck disable=SC2329  # Exported into the checker subprocess.
pwd() {
    : > "${HOSTILE_PWD_MARKER:?}"
    return 91
}
export -f cd pwd
set +e
hostile_builtin_output="$(
    HOSTILE_CD_MARKER="$trusted_git_repo/hostile-cd-ran" \
    HOSTILE_PWD_MARKER="$trusted_git_repo/hostile-pwd-ran" \
        "$CHECKER_SHELL" \
        "$trusted_git_repo/scripts/check-submodule-drift.sh" 2>&1
)"
hostile_builtin_status=$?
set -e
unset -f cd pwd
if [ "$hostile_builtin_status" -eq 2 ] \
    && [ ! -e "$trusted_git_repo/hostile-cd-ran" ] \
    && [ ! -e "$trusted_git_repo/hostile-pwd-ran" ] \
    && grep -q 'repository commit identity unavailable' \
        <<<"$hostile_builtin_output"; then
    pass "exported cd and pwd functions have zero effects"
else
    fail "an exported cd or pwd function replaced trusted path resolution"
fi

info "help output does not execute a PATH-selected formatter"
cat > "$trusted_git_bin/sed" <<'EOF'
#!/usr/bin/env bash
: > "${HOSTILE_SED_MARKER:?}"
exit 0
EOF
chmod +x "$trusted_git_bin/sed"
set +e
trusted_help_output="$(
    HOSTILE_SED_MARKER="$trusted_git_repo/hostile-sed-ran" \
    PATH="$trusted_git_bin:/usr/bin:/bin" \
        "$CHECKER_SHELL" \
        "$trusted_git_repo/scripts/check-submodule-drift.sh" --help 2>&1
)"
trusted_help_status=$?
set -e
if [ "$trusted_help_status" -eq 0 ] \
    && [ ! -e "$trusted_git_repo/hostile-sed-ran" ] \
    && grep -Fq 'Usage: check-submodule-drift.sh [--ci]' \
        <<<"$trusted_help_output"; then
    pass "help text is emitted without an external formatter"
else
    fail "help selected a PATH formatter"
fi

info "the bound .gitmodules entry and content remain unchanged"
printf '%s\n' preserve-me > "$FIXTURE/.gitmodules-victim"
for swap_mode in swap-gitmodules symlink-gitmodules; do
    rm -f "$FIXTURE/.swap-gitmodules-done"
    GIT_MODE="$swap_mode" run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 2 ] \
        && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
        pass "$swap_mode invalidates the repository snapshot"
    else
        fail "$swap_mode was accepted as one repository snapshot"
    fi
    rm -f "$FIXTURE/.gitmodules"
    mv "$FIXTURE/.gitmodules-original" "$FIXTURE/.gitmodules"
done

info "the canonical path and URL table comes from one descriptor snapshot"
if ! grep -Eq '(^| )config( |$)' "$GIT_LOG"; then
    pass "Git does not reopen the bound .gitmodules pathname"
else
    fail "Git reparsed .gitmodules outside its descriptor binding"
fi

info "partial Git output is never accepted as complete evidence"
for failure_mode in partial-inventory partial-url-inventory partial-tree \
                    partial-symref partial-upstream; do
    write_inventory "$failure_mode"
    GIT_MODE="$failure_mode" run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 2 ] \
        && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
        pass "$failure_mode remains an unavailable readback"
    else
        fail "$failure_mode became a complete drift report"
    fi
done
write_inventory current

info "remote observation has finite time, output, and object-ID bounds"
write_inventory hang-remote
SECONDS=0
GIT_MODE=hang-remote run_drift "$CHECKER_SHELL"
hang_elapsed=$SECONDS
if [ "$DRIFT_STATUS" -eq 2 ] && [ "$hang_elapsed" -le 3 ] \
    && grep -q 'timed out' <<<"$DRIFT_OUTPUT"; then
    pass "a hanging ls-remote is terminated within its fixed bound"
else
    fail "a hanging ls-remote ran for ${hang_elapsed}s with status $DRIFT_STATUS"
fi

write_inventory flood-remote
GIT_MODE=flood-remote run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && grep -q 'output limit' <<<"$DRIFT_OUTPUT"; then
    pass "an ls-remote output flood is rejected at the byte limit"
else
    fail "an ls-remote output flood did not reach the bounded failure"
fi

if [ "$(uname -s)" = Linux ]; then
    write_inventory escaped-remote
    DETACHED_HEARTBEAT_FILE="$TMP/detached-remote-heartbeat"
    DETACHED_STOP_FILE="$TMP/detached-remote-stop"
    DETACHED_IDENTITY_FILE="$TMP/detached-remote-identity"
    heartbeat_snapshot="$TMP/detached-remote-heartbeat.snapshot"
    rm -f "$DETACHED_HEARTBEAT_FILE" "$DETACHED_STOP_FILE" \
        "$DETACHED_IDENTITY_FILE" "$heartbeat_snapshot"
    GIT_MODE=escaped-remote run_drift "$CHECKER_SHELL"
    for _ in $(seq 1 40); do
        [ -s "$DETACHED_HEARTBEAT_FILE" ] \
            && [ -s "$DETACHED_IDENTITY_FILE" ] && break
        sleep 0.025
    done
    cp -- "$DETACHED_HEARTBEAT_FILE" "$heartbeat_snapshot"
    read -r detached_pid detached_start_time < "$DETACHED_IDENTITY_FILE"
    sleep 0.25
    heartbeat_is_stable=false
    if cmp -s "$heartbeat_snapshot" "$DETACHED_HEARTBEAT_FILE"; then
        heartbeat_is_stable=true
    fi
    identity_is_extinct=false
    for _ in $(seq 1 40); do
        if ! linux_process_identity_is_active \
            "$detached_pid" "$detached_start_time"; then
            identity_is_extinct=true
            break
        fi
        sleep 0.025
    done
    : > "$DETACHED_STOP_FILE"
    if [ "$DRIFT_STATUS" -eq 2 ] \
        && [ "$heartbeat_is_stable" = true ] \
        && [ "$identity_is_extinct" = true ] \
        && grep -Eq 'timed out|detached descendant|containment' <<<"$DRIFT_OUTPUT"; then
        pass "a remote child forked during cleanup is extinguished before return"
    else
        printf 'status=%s pid=%s start=%s stable=%s extinct=%s output=%s\n' \
            "$DRIFT_STATUS" "${detached_pid:-missing}" \
            "${detached_start_time:-missing}" "$heartbeat_is_stable" \
            "$identity_is_extinct" "$DRIFT_OUTPUT" >&2
        fail "a remote child forked during cleanup escaped containment"
    fi
    unset DETACHED_HEARTBEAT_FILE DETACHED_STOP_FILE DETACHED_IDENTITY_FILE
else
    pass "detached remote containment proof is Linux-only (explicitly skipped)"
fi

info "fatal runner cancellation extinguishes its exact Git process tree"
cancel_checker="$FIXTURE/scripts/check-submodule-drift-cancel.sh"
cp "$FIXTURE/scripts/check-submodule-drift.sh" "$cancel_checker"
/usr/bin/python3 -I -S - "$cancel_checker" <<'PY'
from pathlib import Path
import sys


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
timeout_entry = "GIT_CALL_TIMEOUT_SECONDS=2"
if source.count(timeout_entry) != 1:
    raise SystemExit("Git runner cancellation timeout seam changed")
source = source.replace(timeout_entry, "GIT_CALL_TIMEOUT_SECONDS=10")
entry = """try:
    if process_scope is not None:
        process_scope.track_root(process.pid)"""
replacement = """try:
    if requires_exact_containment and os.environ.get("RUNNER_CANCEL_POPEN_RECEIPT"):
        receipt_path = os.environ["RUNNER_CANCEL_POPEN_RECEIPT"]
        release_path = os.environ["RUNNER_CANCEL_RELEASE_FILE"]
        descriptor = os.open(
            receipt_path,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC,
            0o600,
        )
        os.close(descriptor)
        while not os.path.exists(release_path):
            time.sleep(0.005)
    if process_scope is not None:
        process_scope.track_root(process.pid)"""
if source.count(entry) != 1:
    raise SystemExit("Git runner cancellation acquisition seam changed")
path.write_text(source.replace(entry, replacement), encoding="utf-8")
PY
cancellation_failures=0
for cancellation_signal in TERM HUP QUIT; do
    cancel_identity="$TMP/cancel-$cancellation_signal.identity"
    cancel_heartbeat="$TMP/cancel-$cancellation_signal.heartbeat"
    cancel_receipt="$TMP/cancel-$cancellation_signal.popen"
    cancel_release="$TMP/cancel-$cancellation_signal.release"
    cancel_status_file="$TMP/cancel-$cancellation_signal.status"
    cancel_output_file="$TMP/cancel-$cancellation_signal.output"
    rm -f "$cancel_identity" "$cancel_heartbeat" "$cancel_receipt" \
        "$cancel_release" "$cancel_status_file" "$cancel_output_file"
    : > "$cancel_heartbeat"
    (
        CHECKER_PATH="$cancel_checker" \
        GIT_MODE=cancel-remote \
        CANCEL_IDENTITY_FILE="$cancel_identity" \
        CANCEL_HEARTBEAT_FILE="$cancel_heartbeat" \
        RUNNER_CANCEL_POPEN_RECEIPT="$cancel_receipt" \
        RUNNER_CANCEL_RELEASE_FILE="$cancel_release" \
            run_drift "$CHECKER_SHELL"
        printf '%s\n' "$DRIFT_STATUS" > "$cancel_status_file"
        printf '%s' "$DRIFT_OUTPUT" > "$cancel_output_file"
    ) &
    cancel_wrapper=$!
    for _ in $(seq 1 300); do
        [ -s "$cancel_identity" ] && [ -e "$cancel_receipt" ] && break
        sleep 0.01
    done
    cancel_finished_promptly=false
    cancel_status=missing
    cancel_output=""
    if [ -s "$cancel_identity" ] && [ -e "$cancel_receipt" ]; then
        read -r runner_pid runner_start leader_pid leader_start \
            descendant_pid descendant_start < "$cancel_identity"
        if linux_process_identity_is_active "$runner_pid" "$runner_start"; then
            if ! kill -"$cancellation_signal" "$runner_pid" 2>/dev/null; then :; fi
        fi
        : > "$cancel_release"
        # The private checker uses a 10-second Git timeout. This two-second
        # deadline proves signal cancellation, not ordinary timeout cleanup.
        cancel_cleanup_deadline=$((SECONDS + 2))
        while [ "$SECONDS" -lt "$cancel_cleanup_deadline" ]; do
            if [ -s "$cancel_status_file" ] \
                && ! linux_process_identity_is_active "$leader_pid" "$leader_start" \
                && ! linux_process_identity_is_active \
                    "$descendant_pid" "$descendant_start"; then
                cancel_finished_promptly=true
                break
            fi
            sleep 0.01
        done
    fi
    if [ -e "$cancel_receipt" ]; then : > "$cancel_release"; fi
    if [ "$cancel_finished_promptly" != true ]; then
        cancellation_failures=$((cancellation_failures + 1))
        if [ -n "${descendant_pid:-}" ] \
            && linux_process_identity_is_active \
                "$descendant_pid" "$descendant_start"; then
            if ! kill -KILL "$descendant_pid" 2>/dev/null; then :; fi
        fi
        if [ -n "${leader_pid:-}" ] \
            && linux_process_identity_is_active "$leader_pid" "$leader_start"; then
            if ! kill -KILL "$leader_pid" 2>/dev/null; then :; fi
        fi
        if [ -n "${runner_pid:-}" ] \
            && linux_process_identity_is_active "$runner_pid" "$runner_start"; then
            if ! kill -KILL "$runner_pid" 2>/dev/null; then :; fi
        fi
    fi
    set +e
    wait "$cancel_wrapper"
    set -e
    if [ -s "$cancel_status_file" ]; then
        cancel_status="$(cat "$cancel_status_file")"
        cancel_output="$(cat "$cancel_output_file")"
    fi
    if [ "$cancel_status" != 2 ] \
        || ! grep -Eq "RunnerCancellation: received SIG$cancellation_signal" \
            <<<"$cancel_output"; then
        cancellation_failures=$((cancellation_failures + 1))
    fi
    cancel_snapshot="$cancel_heartbeat.snapshot"
    cp -- "$cancel_heartbeat" "$cancel_snapshot"
    sleep 0.05
    if ! cmp -s "$cancel_snapshot" "$cancel_heartbeat"; then
        cancellation_failures=$((cancellation_failures + 1))
    fi
    unset runner_pid runner_start leader_pid leader_start \
        descendant_pid descendant_start
done
if [ "$cancellation_failures" -eq 0 ]; then
    pass "SIGTERM, SIGHUP, and SIGQUIT leave no Git leader or descendant"
else
    fail "fatal runner cancellation leaked a Git leader or descendant"
fi

write_inventory zero-oid
GIT_MODE=zero-oid run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && grep -q 'invalid default branch' <<<"$DRIFT_OUTPUT"; then
    pass "the all-zero remote object ID is rejected"
else
    fail "the all-zero remote object ID became revision evidence"
fi
write_inventory current

info "every Git read has one finite process-tree and output boundary"
for bounded_mode in hang-repo pipe-eof-repo flood-repo; do
    write_inventory "$bounded_mode"
    DESCENDANT_PID_FILE="$TMP/$bounded_mode.pid"
    export DESCENDANT_PID_FILE
    rm -f "$DESCENDANT_PID_FILE"
    SECONDS=0
    GIT_MODE="$bounded_mode" run_drift "$CHECKER_SHELL"
    bounded_elapsed=$SECONDS
    descendant_stopped=true
    if [ "$bounded_mode" = pipe-eof-repo ]; then
        descendant_stopped=false
        descendant_pid=""
        if ! descendant_pid=$(cat "$DESCENDANT_PID_FILE" 2>/dev/null); then :; fi
        if [[ "$descendant_pid" =~ ^[0-9]+$ ]]; then
            for _ in $(seq 1 20); do
                if ! kill -0 "$descendant_pid" 2>/dev/null; then
                    descendant_stopped=true
                    break
                fi
                sleep 0.05
            done
        fi
    fi
    if [ "$DRIFT_STATUS" -eq 2 ] && [ "$bounded_elapsed" -le 3 ] \
        && [ "$descendant_stopped" = true ] \
        && grep -Eq 'timed out|output limit' <<<"$DRIFT_OUTPUT"; then
        pass "$bounded_mode is rejected inside the shared Git runner"
    else
        printf 'status=%s elapsed=%s output=%s\n' \
            "$DRIFT_STATUS" "$bounded_elapsed" "$DRIFT_OUTPUT" >&2
        fail "$bounded_mode escaped the shared Git runner after ${bounded_elapsed}s"
    fi
done
unset DESCENDANT_PID_FILE
write_inventory current

info "Git process groups are terminated before the direct child is reaped"
rm -f "$FIXTURE/.leader-order-done" "$TMP/runner-order" \
    "$TMP/runner-order-descendant.pid"
RUNNER_ORDER_FILE="$TMP/runner-order" \
RUNNER_DESCENDANT_PID_FILE="$TMP/runner-order-descendant.pid" \
GIT_MODE=leader-order run_drift "$CHECKER_SHELL"
order_descendant_stopped=false
order_descendant_pid=""
if ! order_descendant_pid=$(cat "$TMP/runner-order-descendant.pid" 2>/dev/null); then :; fi
if [[ "$order_descendant_pid" =~ ^[0-9]+$ ]]; then
    for _ in $(seq 1 40); do
        if ! kill -0 "$order_descendant_pid" 2>/dev/null; then
            order_descendant_stopped=true
            break
        fi
        sleep 0.05
    done
fi
runner_order=""
if ! runner_order=$(cat "$TMP/runner-order" 2>/dev/null); then :; fi
if [ "$DRIFT_STATUS" -eq 0 ] \
    && [ "$runner_order" = term-before-reap ] \
    && [ "$order_descendant_stopped" = true ]; then
    pass "Git receives TERM and KILL before its leader is reaped"
else
    fail "the Git leader was reaped before its process group was terminated"
fi

info "every post-Popen runner exception terminates and reaps the owned tree"
post_popen_checker="$FIXTURE/scripts/check-submodule-drift-post-popen.sh"
cp "$FIXTURE/scripts/check-submodule-drift.sh" "$post_popen_checker"
/usr/bin/python3 -I -S - "$post_popen_checker" <<'PY'
from pathlib import Path
import sys


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
entry = "selector = selectors.DefaultSelector()"
replacement = """selector = selectors.DefaultSelector()
    if (
        profile == \"git\"
        and os.environ.get(\"RUNNER_POST_POPEN_FAILURE\") == \"1\"
    ):
        ready_path = os.environ[\"RUNNER_READY_FILE\"]
        for _ in range(200):
            if os.path.exists(ready_path):
                break
            time.sleep(0.01)
        raise RuntimeError(\"controlled post-Popen failure\")"""
if source.count(entry) != 1:
    raise SystemExit("Git runner post-Popen seam changed")
path.write_text(source.replace(entry, replacement), encoding="utf-8")
PY
rm -f "$TMP/runner-leader.pid" "$TMP/runner-descendant.pid" \
    "$TMP/runner-ready"
CHECKER_PATH="$post_popen_checker" \
RUNNER_POST_POPEN_FAILURE=1 \
RUNNER_READY_FILE="$TMP/runner-ready" \
RUNNER_LEADER_PID_FILE="$TMP/runner-leader.pid" \
RUNNER_DESCENDANT_PID_FILE="$TMP/runner-descendant.pid" \
GIT_MODE=post-popen-exception run_drift "$CHECKER_SHELL"
runner_leader_pid=""
if ! runner_leader_pid=$(cat "$TMP/runner-leader.pid" 2>/dev/null); then :; fi
runner_descendant_pid=""
if ! runner_descendant_pid=$(cat "$TMP/runner-descendant.pid" 2>/dev/null); then :; fi
post_popen_tree_stopped=false
process_is_active() {
    local process_state
    process_state="$(/bin/ps -o stat= -p "$1" 2>/dev/null)" || return 1
    case "$process_state" in
        *Z*) return 1 ;;
        *) [ -n "$process_state" ] ;;
    esac
}
if [[ "$runner_leader_pid" =~ ^[0-9]+$ ]] \
    && [[ "$runner_descendant_pid" =~ ^[0-9]+$ ]]; then
    for _ in $(seq 1 40); do
        if ! process_is_active "$runner_leader_pid" \
            && ! process_is_active "$runner_descendant_pid"; then
            post_popen_tree_stopped=true
            break
        fi
        sleep 0.05
    done
fi
if [ "$DRIFT_STATUS" -eq 2 ] && [ "$post_popen_tree_stopped" = true ]; then
    pass "a post-Popen exception cannot leak the Git process tree"
else
    runner_leader_state=""
    if ! runner_leader_state=$(
        /bin/ps -o stat= -p "$runner_leader_pid" 2>/dev/null
    ); then :; fi
    runner_descendant_state=""
    if ! runner_descendant_state=$(
        /bin/ps -o stat= -p "$runner_descendant_pid" 2>/dev/null
    ); then :; fi
    printf 'status=%s leader=%s descendant=%s leader_state=%s descendant_state=%s output=%s\n' \
        "$DRIFT_STATUS" "$runner_leader_pid" "$runner_descendant_pid" \
        "$runner_leader_state" "$runner_descendant_state" \
        "$DRIFT_OUTPUT" >&2
    fail "a post-Popen exception leaked an owned Git process"
fi
if [[ "$runner_leader_pid" =~ ^[0-9]+$ ]] \
    && process_is_active "$runner_leader_pid"; then
    if ! kill -TERM -- "-$runner_leader_pid" 2>/dev/null; then :; fi
    sleep 0.2
    if ! kill -KILL -- "-$runner_leader_pid" 2>/dev/null; then :; fi
fi

info "process-group permission failures cannot become successful cleanup"
permission_checker="$FIXTURE/scripts/check-submodule-drift-permission.sh"
cp "$FIXTURE/scripts/check-submodule-drift.sh" "$permission_checker"
/usr/bin/python3 -I -S - "$permission_checker" <<'PY'
from pathlib import Path
import sys


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
for call in (
    "os.killpg(process.pid, signal.SIGTERM)",
    "os.killpg(process.pid, signal.SIGKILL)",
):
    if source.count(call) != 1:
        raise SystemExit(f"Git runner signal seam changed: {call}")
    denial = (
        f"{call} if profile != 'git' else "
        "(_ for _ in ()).throw(PermissionError('controlled denial'))"
    )
    source = source.replace(call, denial)
path.write_text(source, encoding="utf-8")
PY
rm -f "$TMP/permission-leader.pid" "$TMP/permission-ready"
CHECKER_PATH="$permission_checker" \
RUNNER_READY_FILE="$TMP/permission-ready" \
RUNNER_LEADER_PID_FILE="$TMP/permission-leader.pid" \
GIT_MODE=permission-denied run_drift "$CHECKER_SHELL"
permission_leader_pid=""
if ! permission_leader_pid=$(cat "$TMP/permission-leader.pid" 2>/dev/null); then :; fi
if [ "$DRIFT_STATUS" -eq 2 ] \
    && grep -q 'could not terminate Git process group: controlled denial' \
        <<<"$DRIFT_OUTPUT" \
    && [[ "$permission_leader_pid" =~ ^[0-9]+$ ]] \
    && ! process_is_active "$permission_leader_pid"; then
    pass "a live leader makes process-group permission denial fail closed"
else
    permission_leader_state=""
    if ! permission_leader_state=$(
        /bin/ps -o stat= -p "$permission_leader_pid" 2>/dev/null
    ); then :; fi
    printf 'status=%s leader=%s state=%s output=%s\n' \
        "$DRIFT_STATUS" "$permission_leader_pid" \
        "$permission_leader_state" \
        "$DRIFT_OUTPUT" >&2
    fail "process-group permission denial was accepted as cleanup"
fi

info "the complete operation uses one absolute deadline"
write_inventory slow-total
total_deadline_checker="$FIXTURE/scripts/check-submodule-drift-total-deadline.sh"
cp "$FIXTURE/scripts/check-submodule-drift.sh" "$total_deadline_checker"
/usr/bin/python3 - "$total_deadline_checker" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
old = "TOTAL_OPERATION_TIMEOUT_SECONDS=120"
if text.count(old) != 1:
    raise SystemExit("total-operation deadline seam changed")
path.write_text(text.replace(old, "TOTAL_OPERATION_TIMEOUT_SECONDS=2"), encoding="utf-8")
PY
SECONDS=0
CHECKER_PATH="$total_deadline_checker" GIT_MODE=slow-total \
    run_drift "$CHECKER_SHELL"
total_elapsed=$SECONDS
if [ "$DRIFT_STATUS" -eq 2 ] && [ "$total_elapsed" -le 3 ] \
    && grep -q 'operation deadline' <<<"$DRIFT_OUTPUT"; then
    pass "separate successful Git calls cannot reset the operation deadline"
else
    fail "the operation deadline reset between Git calls after ${total_elapsed}s"
fi
write_inventory current

info "the operation deadline covers guards and every CI publication stage"
non_git_deadline_checker="$FIXTURE/scripts/check-submodule-drift-non-git-deadline.sh"
cp "$FIXTURE/scripts/check-submodule-drift.sh" "$non_git_deadline_checker"
/usr/bin/python3 -I -S - "$non_git_deadline_checker" <<'PY'
from pathlib import Path
import sys


path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = "TOTAL_OPERATION_TIMEOUT_SECONDS=120"
if source.count(old) != 1:
    raise SystemExit("total-operation deadline seam changed")
path.write_text(source.replace(old, "TOTAL_OPERATION_TIMEOUT_SECONDS=2"), encoding="utf-8")
PY
while IFS='|' read -r boundary python_mode date_mode; do
    [ -n "$boundary" ] || continue
    rm -f "$TMP/slow-boundary" "$FIXTURE/drift-report.json"
    SECONDS=0
    CHECKER_PATH="$non_git_deadline_checker" \
    SLOW_BOUNDARY_MARKER="$TMP/slow-boundary" \
    PYTHON_MODE="$python_mode" DATE_MODE="$date_mode" \
    GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
    boundary_elapsed=$SECONDS
    if [ "$DRIFT_STATUS" -eq 2 ] && [ -e "$TMP/slow-boundary" ] \
        && [ "$boundary_elapsed" -le 3 ] \
        && grep -q 'operation deadline' <<<"$DRIFT_OUTPUT" \
        && [ ! -e "$FIXTURE/drift-report.json" ]; then
        pass "$boundary cannot outlive the operation deadline"
    else
        fail "$boundary escaped the operation deadline after ${boundary_elapsed}s"
    fi
done <<'EOF'
repository guard|slow-guard|
publisher binding|slow-publisher-bind|
report validation|slow-validation|
report publication|slow-publication|
timestamp generation||slow-deadline
EOF
write_inventory current

info "canonical inventory bytes have a fixed aggregate limit"
/usr/bin/python3 - "$FIXTURE/.gitmodules" <<'PY'
from pathlib import Path
import sys

with Path(sys.argv[1]).open("a", encoding="utf-8") as stream:
    stream.write("#" + "x" * (1024 * 1024 + 1) + "\n")
PY
GIT_MODE=current run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && ! grep -Eq '(^| )ls-tree( |$)|(^| )ls-remote( |$)' "$GIT_LOG"; then
    pass "an oversized .gitmodules snapshot stops before Git reads"
else
    fail "an oversized .gitmodules snapshot escaped the input limit"
fi
write_inventory current

GIT_MODE=mismatched-head run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
    pass "different symref and branch OIDs remain inconsistent evidence"
else
    fail "different symref and branch OIDs became a complete report"
fi

info "successful Git reads must still contain exactly the expected records"
for extra_mode in extra-tree extra-symref extra-upstream; do
    GIT_MODE="$extra_mode" run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 2 ] \
        && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
        pass "$extra_mode cannot hide an unexpected successful record"
    else
        fail "$extra_mode was truncated into apparently complete evidence"
    fi
done

info "canonical path and URL inventories are complete and one-to-one"
for malformed_inventory in duplicate-name duplicate-path duplicate-url-entry \
                           orphan-url missing-url duplicate-repo-url nested-url \
                           prefix-url suffix-url scheme-url host-url org-url \
                           dot-name dot-path leading-dot-name terminal-dot-name \
                           trailing-slash-name leading-dot-path terminal-dot-path \
                           trailing-slash-path; do
    write_inventory "$malformed_inventory"
    GIT_MODE="$malformed_inventory" run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -ne 2 ]; then
        fail "$malformed_inventory canonical inventory did not report unavailable"
    elif grep -Eq '(^| )ls-tree( |$)|(^| )ls-remote( |$)' "$GIT_LOG"; then
        fail "$malformed_inventory canonical inventory reached a remote or gitlink read"
    else
        pass "$malformed_inventory canonical inventory stops before external reads"
    fi
done
write_inventory current

info "drift enrichment never fetches or mutates a component checkout"
GIT_MODE=drift run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 1 ] \
    && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
    && ! grep -q '| behind |' <<<"$DRIFT_OUTPUT" \
    && ! grep -Eq '(^| )fetch( |$)' "$GIT_LOG"; then
    pass "unknown ancestry is reported as different without mutation"
else
    fail "unknown ancestry was mislabeled or mutated component refs"
fi

info "local ancestry requires a direct checkout and direct .git entry"
mv "$FIXTURE/components/Alpha" "$FIXTURE/components/Alpha-direct"
ln -s "$FIXTURE/components/Alpha-direct" "$FIXTURE/components/Alpha"
GIT_MODE=behind run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 1 ] \
    && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
    && ! grep -Eq -- "-C $FIXTURE/components/Alpha (cat-file|merge-base|rev-list|show)" \
        "$GIT_LOG"; then
    pass "a symlinked local checkout cannot supply ancestry evidence"
else
    fail "a symlinked local checkout supplied ancestry evidence"
fi
rm "$FIXTURE/components/Alpha"
mv "$FIXTURE/components/Alpha-direct" "$FIXTURE/components/Alpha"

mkdir "$TMP/git-decoy"
mv "$FIXTURE/components/Alpha/.git" \
    "$FIXTURE/components/Alpha/.git-original"
ln -s "$TMP/git-decoy" "$FIXTURE/components/Alpha/.git"
GIT_MODE=behind run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 1 ] \
    && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
    && ! grep -Eq -- "-C $FIXTURE/components/Alpha (cat-file|merge-base|rev-list|show)" \
        "$GIT_LOG"; then
    pass "a symlinked local .git entry cannot supply ancestry evidence"
else
    fail "a symlinked local .git entry supplied ancestry evidence"
fi
rm "$FIXTURE/components/Alpha/.git"
mv "$FIXTURE/components/Alpha/.git-original" \
    "$FIXTURE/components/Alpha/.git"

info "local ancestry binds a gitfile target and its configuration"
LOCAL_GITDIR_TARGET="$TMP/local-gitdir"
LOCAL_GITDIR_BACKUP="$TMP/local-gitdir-original"
LOCAL_CONFIG_PATH="$LOCAL_GITDIR_TARGET/config"
mv "$FIXTURE/components/Alpha/.git" "$LOCAL_GITDIR_TARGET"
printf 'gitdir: %s\n' "$LOCAL_GITDIR_TARGET" \
    > "$FIXTURE/components/Alpha/.git"
for local_swap_mode in swap-local-gitdir swap-local-config; do
    rm -f "$FIXTURE/.swap-local-gitdir-done" \
        "$FIXTURE/.swap-local-config-done"
    LOCAL_GITDIR_TARGET="$LOCAL_GITDIR_TARGET" \
    LOCAL_GITDIR_BACKUP="$LOCAL_GITDIR_BACKUP" \
    LOCAL_CONFIG_PATH="$LOCAL_CONFIG_PATH" \
    GIT_MODE="$local_swap_mode" run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 1 ] \
        && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
        && grep -q 'local repository changed during inspection' \
            <<<"$DRIFT_OUTPUT"; then
        pass "$local_swap_mode cannot supply local ancestry evidence"
    else
        printf 'mode=%s status=%s output=%s\n' \
            "$local_swap_mode" "$DRIFT_STATUS" "$DRIFT_OUTPUT" >&2
        fail "$local_swap_mode supplied unbound local ancestry evidence"
    fi
    case "$local_swap_mode" in
        swap-local-gitdir)
            rm -rf "$LOCAL_GITDIR_TARGET"
            mv "$LOCAL_GITDIR_BACKUP" "$LOCAL_GITDIR_TARGET"
            ;;
        swap-local-config)
            printf '%s\n' '[core]' '    repositoryformatversion = 0' \
                > "$LOCAL_CONFIG_PATH"
            ;;
    esac
done
rm "$FIXTURE/components/Alpha/.git"
mv "$LOCAL_GITDIR_TARGET" "$FIXTURE/components/Alpha/.git"

info "graph-affecting local metadata cannot become ancestry evidence"
mkdir -p "$FIXTURE/components/Alpha/.git/info" \
    "$FIXTURE/components/Alpha/.git/objects/info" "$TMP/alternate-objects"
for graph_case in shallow grafts alternates; do
    case "$graph_case" in
        shallow)
            graph_path="$FIXTURE/components/Alpha/.git/shallow"
            printf '%s\n' 1111111111111111111111111111111111111111 \
                > "$graph_path"
            ;;
        grafts)
            graph_path="$FIXTURE/components/Alpha/.git/info/grafts"
            printf '%s\n' \
                '1111111111111111111111111111111111111111 2222222222222222222222222222222222222222' \
                > "$graph_path"
            ;;
        alternates)
            graph_path="$FIXTURE/components/Alpha/.git/objects/info/alternates"
            printf '%s\n' "$TMP/alternate-objects" > "$graph_path"
            ;;
    esac
    GIT_MODE=behind run_drift "$CHECKER_SHELL"
    if [ "$DRIFT_STATUS" -eq 1 ] \
        && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
        && ! grep -q '| behind |' <<<"$DRIFT_OUTPUT"; then
        pass "$graph_case metadata cannot supply local ancestry evidence"
    else
        fail "$graph_case metadata changed local graph evidence"
    fi
    rm -f "$graph_path"
done

info "real Git worktrees keep gitfile and Git-directory identity bound"
REAL_COMPONENT_SOURCE="$TMP/real-component-source"
REAL_ROOT_SOURCE="$TMP/real-root-source"
REAL_FIXTURE_ROOT="$TMP/real-root"
REAL_FIXTURE_LOCAL="$REAL_FIXTURE_ROOT/components/Alpha"
mkdir "$REAL_COMPONENT_SOURCE" "$REAL_ROOT_SOURCE"
real_git init -q "$REAL_COMPONENT_SOURCE"
printf '%s\n' one > "$REAL_COMPONENT_SOURCE/value.txt"
real_git -C "$REAL_COMPONENT_SOURCE" add value.txt
real_git -C "$REAL_COMPONENT_SOURCE" \
    -c user.name=Odysseus -c user.email=odysseus@example.invalid \
    commit -qm one
REAL_PINNED=$(real_git -C "$REAL_COMPONENT_SOURCE" rev-parse HEAD)
printf '%s\n' two > "$REAL_COMPONENT_SOURCE/value.txt"
real_git -C "$REAL_COMPONENT_SOURCE" add value.txt
real_git -C "$REAL_COMPONENT_SOURCE" \
    -c user.name=Odysseus -c user.email=odysseus@example.invalid \
    commit -qm two
REAL_UPSTREAM=$(real_git -C "$REAL_COMPONENT_SOURCE" rev-parse HEAD)

real_git init -q "$REAL_ROOT_SOURCE"
printf '%s\n' \
    '[submodule "Alpha"]' \
    '    path = components/Alpha' \
    '    url = https://github.com/HomericIntelligence/Alpha.git' \
    > "$REAL_ROOT_SOURCE/.gitmodules"
real_git -C "$REAL_ROOT_SOURCE" add .gitmodules
real_git -C "$REAL_ROOT_SOURCE" update-index --add \
    --cacheinfo "160000,$REAL_PINNED,components/Alpha"
real_git -C "$REAL_ROOT_SOURCE" \
    -c user.name=Odysseus -c user.email=odysseus@example.invalid \
    commit -qm root
real_git -C "$REAL_ROOT_SOURCE" worktree add -q --detach \
    "$REAL_FIXTURE_ROOT" HEAD
mkdir -p "$REAL_FIXTURE_ROOT/components"
if [ -d "$REAL_FIXTURE_LOCAL" ]; then
    rmdir "$REAL_FIXTURE_LOCAL"
fi
real_git -C "$REAL_COMPONENT_SOURCE" worktree add -q --detach \
    "$REAL_FIXTURE_LOCAL" "$REAL_PINNED"
mkdir -p "$REAL_FIXTURE_ROOT/scripts"
cp "$ROOT/scripts/check-submodule-drift.sh" \
    "$REAL_FIXTURE_ROOT/scripts/check-submodule-drift.sh"
cp "$ROOT/scripts/safe_report_publish.py" \
    "$REAL_FIXTURE_ROOT/scripts/safe_report_publish.py"
bind_test_dependencies "$REAL_FIXTURE_ROOT/scripts/check-submodule-drift.sh"
REAL_ROOT_GITDIR_TARGET=$(sed -n 's/^gitdir: //p' \
    "$REAL_FIXTURE_ROOT/.git")
REAL_LOCAL_GITDIR_TARGET=$(sed -n 's/^gitdir: //p' \
    "$REAL_FIXTURE_LOCAL/.git")
REAL_ROOT_GITDIR_BACKUP="$TMP/real-root-gitdir-original"
REAL_LOCAL_GITDIR_BACKUP="$TMP/real-local-gitdir-original"
REAL_SWAP_MARKER="$TMP/real-git-swap-done"

REAL_GIT_DELEGATE=1 \
CHECKER_PATH="$REAL_FIXTURE_ROOT/scripts/check-submodule-drift.sh" \
GIT_MODE=real-behind run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 1 ] \
    && grep -q '| behind |' <<<"$DRIFT_OUTPUT"; then
    pass "the real linked-worktree fixture supplies valid ancestry evidence"
else
    fail "the real linked-worktree fixture could not establish its baseline"
fi

rm -f "$REAL_SWAP_MARKER"
REAL_GIT_DELEGATE=1 \
CHECKER_PATH="$REAL_FIXTURE_ROOT/scripts/check-submodule-drift.sh" \
GIT_MODE=real-swap-root-gitdir run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 2 ] \
    && [ -e "$REAL_SWAP_MARKER" ] \
    && ! grep -q 'All .* up to date' <<<"$DRIFT_OUTPUT"; then
    pass "a real root gitfile target swap invalidates the report"
else
    fail "a real root gitfile target swap supplied repository evidence"
fi
rm -rf "$REAL_ROOT_GITDIR_TARGET"
mv "$REAL_ROOT_GITDIR_BACKUP" "$REAL_ROOT_GITDIR_TARGET"

rm -f "$REAL_SWAP_MARKER"
REAL_GIT_DELEGATE=1 \
CHECKER_PATH="$REAL_FIXTURE_ROOT/scripts/check-submodule-drift.sh" \
GIT_MODE=real-swap-local-gitdir run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 1 ] \
    && [ -e "$REAL_SWAP_MARKER" ] \
    && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
    && grep -q 'local repository changed during inspection' \
        <<<"$DRIFT_OUTPUT"; then
    pass "a real local gitfile target swap discards ancestry evidence"
else
    fail "a real local gitfile target swap supplied ancestry evidence"
fi
rm -rf "$REAL_LOCAL_GITDIR_TARGET"
mv "$REAL_LOCAL_GITDIR_BACKUP" "$REAL_LOCAL_GITDIR_TARGET"

info "local ancestry is discarded if the checkout changes during inspection"
mkdir -p "$FIXTURE/components/Alpha-victim/.git"
rm -f "$FIXTURE/.swap-submodule-done"
GIT_MODE=swap-submodule run_drift "$CHECKER_SHELL"
if [ "$DRIFT_STATUS" -eq 1 ] \
    && grep -q '| different |' <<<"$DRIFT_OUTPUT" \
    && grep -q 'local repository changed during inspection' \
        <<<"$DRIFT_OUTPUT"; then
    pass "a path swap cannot convert decoy objects into ancestry evidence"
else
    fail "a changed local checkout supplied ancestry evidence"
fi
rm "$FIXTURE/components/Alpha"
mv "$FIXTURE/components/Alpha-original" "$FIXTURE/components/Alpha"

info "local ancestry evidence distinguishes behind, ahead, and diverged pins"
HOSTILE_PYTHON_DIR="$TMP/hostile-python"
HOSTILE_PYTHON_SENTINEL="$TMP/hostile-python-loaded"
mkdir "$HOSTILE_PYTHON_DIR"
cat > "$HOSTILE_PYTHON_DIR/sitecustomize.py" <<'PY'
import os

with open(os.environ["TEST_SITE_SENTINEL"], "w", encoding="utf-8") as stream:
    stream.write("loaded\n")
PY
rm -f "$HOSTILE_PYTHON_SENTINEL"
PYTHONPATH="$HOSTILE_PYTHON_DIR" \
TEST_SITE_SENTINEL="$HOSTILE_PYTHON_SENTINEL" \
    "$REAL_PYTHON" -I -S -c 'import json; assert json.loads("1") == 1'
if [ ! -e "$HOSTILE_PYTHON_SENTINEL" ]; then
    pass "test-side Python validation ignores startup customization"
else
    fail "test-side Python validation loaded ambient startup customization"
fi

for relation_case in behind ahead diverged; do
    GIT_MODE="$relation_case" run_drift "$CHECKER_SHELL" --ci
    if [ "$DRIFT_STATUS" -eq 0 ] \
        && "$REAL_PYTHON" -I -S - "$FIXTURE/drift-report.json" \
            "$relation_case" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    report = json.load(stream)
row, expected = report["submodules"][0], sys.argv[2]
expected_distance = {
    "behind": "3",
    "ahead": "2",
    "diverged": "2 ahead / 3 behind",
}[expected]
expected_behind = {"behind": "3", "ahead": "0", "diverged": "3"}[expected]
assert report["drift_count"] == 1, report
assert row["status"] == expected, row
assert row["relation"] == expected, row
assert row["distance"] == expected_distance, row
assert row["behind"] == expected_behind, row
PY
    then
        pass "$relation_case ancestry is reported without relabeling"
    else
        fail "$relation_case ancestry was reported as a different relation"
    fi
    rm -f "$FIXTURE/drift-report.json"
done

info "CI metadata is emitted to stdout without mutating runner output files"
printf '%s\n' 'runner-owned-output' > "$TMP/github-output"
GITHUB_OUTPUT="$TMP/github-output" GIT_MODE=behind \
    run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 0 ] \
    && [ "$(cat "$TMP/github-output")" = runner-owned-output ] \
    && grep -Fxq 'has_drift=true' <<<"$DRIFT_OUTPUT" \
    && "$REAL_PYTHON" -I -S -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["submodules"][0]["status"] == "behind"' \
        "$FIXTURE/drift-report.json"; then
    pass "CI output is reviewable without writing an existing runner sink"
else
    fail "CI metadata still depended on mutating the runner output file"
fi
rm -f "$FIXTURE/drift-report.json" "$TMP/github-output"

info "CI mode prints the current-state value for downstream capture"
GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 0 ] \
    && grep -Fxq 'has_drift=false' <<<"$DRIFT_OUTPUT" \
    && "$REAL_PYTHON" -I -S -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["drift_count"] == 0' \
        "$FIXTURE/drift-report.json"; then
    pass "current-state metadata remains available for explicit caller capture"
else
    fail "current-state metadata was not printed with its complete report"
fi

rm -f "$FIXTURE/drift-report.json"
DATE_MODE=invalid-success GIT_MODE=current \
    run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 2 ] \
    && [ ! -e "$FIXTURE/drift-report.json" ]; then
    pass "a successful malformed timestamp cannot publish a CI report"
else
    fail "a malformed timestamp produced a successful or published CI report"
fi

GIT_MODE=partial-tree run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 2 ] \
    && "$REAL_PYTHON" -I -S -c 'import json,sys; d=json.load(open(sys.argv[1])); assert d["error_count"] == 1' \
        "$FIXTURE/drift-report.json"; then
    pass "unavailable evidence still stops the scheduled caller"
else
    fail "unavailable evidence became a successful CI report"
fi
rm -f "$FIXTURE/drift-report.json"

info "CI publication code must be an owner-controlled direct file"
chmod 0666 "$FIXTURE/scripts/safe_report_publish.py"
GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
unsafe_publisher_status=$DRIFT_STATUS
chmod 0644 "$FIXTURE/scripts/safe_report_publish.py"
if [ "$unsafe_publisher_status" -eq 2 ] \
    && [ ! -e "$FIXTURE/drift-report.json" ]; then
    pass "a group- or world-writable publisher cannot execute"
else
    rm -f "$FIXTURE/drift-report.json"
    fail "unsafe publisher permissions produced a CI report"
fi

info "CI publication code is bound before repository observation"
rm -f "$FIXTURE/.swap-publisher-done" "$TMP/replacement-publisher-executed"
GIT_MODE=swap-publisher \
PUBLISHER_PATH="$FIXTURE/scripts/safe_report_publish.py" \
PUBLISHER_MARKER="$TMP/replacement-publisher-executed" \
    run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 0 ] \
    && [ ! -e "$TMP/replacement-publisher-executed" ] \
    && [ -s "$FIXTURE/drift-report.json" ]; then
    pass "a later publisher path replacement cannot execute"
else
    fail "repository observation replaced the report publisher"
fi
rm -f "$FIXTURE/scripts/safe_report_publish.py"
mv "$FIXTURE/scripts/safe_report_publish.py.original" \
    "$FIXTURE/scripts/safe_report_publish.py"
rm -f "$FIXTURE/drift-report.json"

info "CI report publication does not follow an existing symlink"
printf '%s\n' 'preserve-me' > "$TMP/victim"
ln -s "$TMP/victim" "$FIXTURE/drift-report.json"
GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 2 ] \
    && [ "$(cat "$TMP/victim")" = preserve-me ]; then
    pass "a symlinked report target is rejected without overwriting its referent"
else
    fail "CI report publication followed an unsafe target"
fi
rm "$FIXTURE/drift-report.json"

info "a bound CI report is valid JSON and complete"
GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 0 ] \
    && "$REAL_PYTHON" -I -S -c 'import json,sys; d=json.load(open(sys.argv[1], encoding="utf-8")); assert d["drift_count"] == 0; assert len(d["submodules"]) == 1' \
        "$FIXTURE/drift-report.json" \
    && [ -s "$PYTHON_LOG" ] \
    && ! grep -Ev '^-I -S( |$)' "$PYTHON_LOG" >/dev/null; then
    pass "safe isolated publication preserves the complete inventory"
else
    fail "report publication was incomplete, invalid, or not isolated"
fi
rm -f "$FIXTURE/drift-report.json"

info "CI report publication rebinds after its initial identity check"
printf '%s\n' preserve-me > "$TMP/report-victim"
DATE_MODE=swap-report \
TEST_SWAP_ORIGINAL="$TMP/drift-report-original" \
TEST_SWAP_VICTIM="$TMP/report-victim" \
GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 2 ] \
    && [ "$(cat "$TMP/report-victim")" = preserve-me ] \
    && [ -L "$FIXTURE/drift-report.json" ]; then
    pass "a post-binding report swap cannot redirect the CI report"
else
    fail "CI report publication did not rebind its destination"
fi
rm "$FIXTURE/drift-report.json"

info "CI report publication remains inside its bound parent directory"
mkdir -p "$TMP/report-parent-victim/scripts"
cat > "$TMP/report-parent-victim/scripts/safe_report_publish.py" <<'PY'
import os

with open(os.environ["TEST_PUBLISHER_SENTINEL"], "w", encoding="utf-8") as stream:
    stream.write("replacement publisher executed\n")
raise SystemExit(2)
PY
rm -f "$TMP/replacement-publisher-executed"
DATE_MODE=swap-parent \
TEST_SWAP_ORIGINAL="$TMP/report-parent-original" \
TEST_SWAP_VICTIM="$TMP/report-parent-victim" \
TEST_PUBLISHER_SENTINEL="$TMP/replacement-publisher-executed" \
GIT_MODE=current run_drift "$CHECKER_SHELL" --ci
if [ "$DRIFT_STATUS" -eq 2 ] \
    && [ ! -e "$TMP/replacement-publisher-executed" ] \
    && [ ! -e "$TMP/report-parent-victim/drift-report.json" ] \
    && grep -q 'error: unsafe report publication target' \
        <<<"$DRIFT_OUTPUT"; then
    pass "a changed report parent cannot replace the bound publisher"
else
    fail "CI report publication ran unbound code or escaped its parent binding"
fi
rm "$FIXTURE"
mv "$TMP/report-parent-original" "$FIXTURE"

info "the suite trap preserves fatal status, incomplete execution, and cleanup failure"
set +e
ODYSSEUS_TEST_HARNESS_PROBE=fatal \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=1 \
    "$CHECKER_SHELL" "$SCRIPT_DIR/test-submodule-drift.sh" \
    > "$TMP/harness-fatal.out" 2>&1
harness_fatal_status=$?
ODYSSEUS_TEST_HARNESS_PROBE=incomplete \
    "$CHECKER_SHELL" "$SCRIPT_DIR/test-submodule-drift.sh" \
    > "$TMP/harness-incomplete.out" 2>&1
harness_incomplete_status=$?
ODYSSEUS_TEST_HARNESS_PROBE=complete \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=1 \
    "$CHECKER_SHELL" "$SCRIPT_DIR/test-submodule-drift.sh" \
    > "$TMP/harness-cleanup.out" 2>&1
harness_cleanup_status=$?
set -e
if [ "$harness_fatal_status" -eq 73 ] \
    && [ "$harness_incomplete_status" -eq 78 ] \
    && [ "$harness_cleanup_status" -eq 79 ] \
    && grep -Fq 'did not reach its completion marker' \
        "$TMP/harness-incomplete.out" \
    && grep -Fq 'controlled drift cleanup failure' \
        "$TMP/harness-fatal.out" \
    && grep -Fq 'controlled drift cleanup failure' \
        "$TMP/harness-cleanup.out"; then
    pass "only a completed drift suite with successful cleanup can exit zero"
else
    printf '%s\n' \
        "fatal=$harness_fatal_status incomplete=$harness_incomplete_status cleanup=$harness_cleanup_status" >&2
    fail "the drift suite trap converted incomplete or cleanup-failed work to success"
fi

summary
suite_completed=1
exit_code
