#!/usr/bin/env bash
# Behavior tests for safe pre-commit hook propagation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

fixture_parent="$(CDPATH='' cd -P -- "${TMPDIR:-/tmp}" && pwd -P)"
fixture_prefix="${fixture_parent%/}/odysseus-hook-propagation."
fixture_root=""
fixture_valid=false
fixture_repo=""
fixture_bin=""
git_log=""
real_git="$(command -v git)"
real_python="$(command -v python3)"
subject_bash="${BASH:?}"
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

inode_of() {
    "$real_python" -c 'import os, sys; print(os.lstat(sys.argv[1]).st_ino)' "$1"
}

fingerprint_of() {
    "$real_python" -c \
        'import os, sys; value = os.lstat(sys.argv[1]); print(f"{value.st_dev}:{value.st_ino}:{value.st_nlink}:{value.st_size}")' \
        "$1"
}

temporary_artifact_count() {
    find "$fixture_repo/.git/modules" -name '.pre-commit.*' \
        | wc -l | tr -d ' '
}

cleanup_fixture() {
    local incoming_status="$1" suffix cleanup_status=0
    trap - EXIT
    if [ "$fixture_valid" != true ]; then
        cleanup_status=79
    else
        suffix="${fixture_root#"$fixture_prefix"}"
        if [ -z "$fixture_root" ] || [ "$suffix" = "$fixture_root" ] \
            || [ -z "$suffix" ] || [ ! -d "$fixture_root" ] \
            || [ -L "$fixture_root" ]; then
            echo "ERROR: refusing unsafe hook-propagation fixture cleanup: $fixture_root" >&2
            cleanup_status=79
        else
            case "$suffix" in
                *[!A-Za-z0-9]*)
                    echo "ERROR: refusing unsafe hook-propagation fixture cleanup: $fixture_root" >&2
                    cleanup_status=79
                    ;;
            esac
        fi
        if [ "$cleanup_status" -eq 0 ] && ! rm -r -- "$fixture_root"; then
            echo "ERROR: failed to remove hook-propagation fixture: $fixture_root" >&2
            cleanup_status=79
        elif [ "$cleanup_status" -eq 0 ] \
            && [ "${ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE:-0}" = 1 ]; then
            echo "ERROR: controlled hook-propagation cleanup failure" >&2
            cleanup_status=79
        fi
    fi
    if [ "$incoming_status" -ne 0 ]; then
        exit "$incoming_status"
    fi
    if [ "$suite_completed" -ne 1 ]; then
        echo "ERROR: hook-propagation suite did not reach its completion marker" >&2
        exit 78
    fi
    if [ "$cleanup_status" -ne 0 ]; then
        exit "$cleanup_status"
    fi
    exit 0
}

if ! fixture_root="$(make_fixture_directory "$fixture_prefix")"; then
    echo "ERROR: could not create a safe hook-propagation fixture" >&2
    exit 1
fi
fixture_valid=true
fixture_repo="$fixture_root/repo"
fixture_bin="$fixture_root/bin"
git_log="$fixture_root/git.log"
mkdir -p "$fixture_repo/tools" "$fixture_repo/.githooks" "$fixture_bin"
trap 'cleanup_fixture "$?"' EXIT

case "${ODYSSEUS_TEST_HARNESS_PROBE:-}" in
    fatal) exit 73 ;;
    incomplete) exit 0 ;;
    complete)
        suite_completed=1
        exit 0
        ;;
esac

cp "$ROOT/tools/propagate-pre-commit-hooks.sh" "$fixture_repo/tools/"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$fixture_repo/.githooks/pre-commit"
chmod 0755 "$fixture_repo/.githooks/pre-commit"

write_valid_inventory() {
    cat > "$fixture_repo/.gitmodules" <<'EOF'
[submodule "control/Alpha"]
    path = control/Alpha
    url = https://github.com/HomericIntelligence/Alpha.git
[submodule "shared/Beta"]
    path = shared/Beta
    url = https://github.com/HomericIntelligence/Beta.git
EOF
}

reset_destinations() {
    rm -rf -- "$fixture_repo/.git" "$fixture_repo/control" \
        "$fixture_repo/shared"
    mkdir -p \
        "$fixture_repo/.git/modules/control/Alpha/hooks" \
        "$fixture_repo/.git/modules/shared/Beta/hooks" \
        "$fixture_repo/control/Alpha" "$fixture_repo/shared/Beta"
    printf 'gitdir: %s\n' \
        "$fixture_repo/.git/modules/control/Alpha" \
        > "$fixture_repo/control/Alpha/.git"
    printf 'gitdir: %s\n' \
        "$fixture_repo/.git/modules/shared/Beta" \
        > "$fixture_repo/shared/Beta/.git"
}

write_valid_inventory
reset_destinations

cat > "$fixture_bin/git" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
printf '%s\n' "$*" >> "${ODYSSEUS_TEST_GIT_LOG:?}"

if [ "${ODYSSEUS_TEST_ASSERT_CLEAN_ENV:-0}" = 1 ]; then
    if [ "${GIT_OPTIONAL_LOCKS:-}" != 0 ] \
        || [ -n "${GIT_TRACE+x}" ] || [ -n "${GIT_TRACE2+x}" ] \
        || [ -n "${GIT_TRACE2_EVENT+x}" ] \
        || [ -n "${LD_PRELOAD+x}" ] || [ -n "${LD_LIBRARY_PATH+x}" ] \
        || [ -n "${DYLD_INSERT_LIBRARIES+x}" ] \
        || [ -n "${ODYSSEUS_UNRELATED_ENV+x}" ] \
        || [ "${HOME:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_GLOBAL:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_SYSTEM:-}" != /dev/null ] \
        || [ "${GIT_CONFIG_NOSYSTEM:-}" != 1 ] \
        || [ "${GIT_CONFIG_COUNT:-}" != 0 ]; then
        printf '%s\n' 'unclean Git environment' >> "$ODYSSEUS_TEST_GIT_LOG"
        exit 98
    fi
fi

if [ "${1:-}" = -C ]; then
    shift 2
fi

if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = helper-swap ] \
    && { [ "${1:-}" = config ] \
        || { [ "${1:-}" = submodule ] && [ "${2:-}" = status ]; }; } \
    && [ ! -e "${ODYSSEUS_TEST_HELPER_SWAP_MARKER:?}" ]; then
    : > "$ODYSSEUS_TEST_HELPER_SWAP_MARKER"
    mv "$ODYSSEUS_TEST_GITMODULES" "$ODYSSEUS_TEST_GITMODULES.original"
    cp "$ODYSSEUS_TEST_GITMODULES.original" "$ODYSSEUS_TEST_GITMODULES"
fi

if [ "${1:-}" = rev-parse ] \
    && [ "${2:-}" = --path-format=absolute ] \
    && [ "${3:-}" = --git-common-dir ] \
    && [ -n "${ODYSSEUS_TEST_GIT_COMMON_DIR:-}" ]; then
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = slow-total ]; then
        sleep 1.1
    fi
    printf '%s\n' "$ODYSSEUS_TEST_GIT_COMMON_DIR"
    exit 0
fi

if [ "${1:-}" = ls-files ] && [ "${2:-}" = --stage ]; then
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = status-fail ]; then
        exit 71
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = pause ]; then
        : > "${ODYSSEUS_TEST_READY:?}"
        until [ -e "${ODYSSEUS_TEST_RELEASE:?}" ]; do
            sleep 0.01
        done
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = success-eof-order ]; then
        leader_pid=$$
        (
            exec >/dev/null 2>&1
            trap '
                if kill -0 '"$leader_pid"' 2>/dev/null; then
                    printf "%s\n" reserved
                else
                    printf "%s\n" reaped
                fi > "${ODYSSEUS_TEST_ORDER_MARKER:?}"
                exit 0
            ' TERM
            while :; do
                sleep 0.05
            done
        ) &
        printf '%s\n' "$!" > "${ODYSSEUS_TEST_DESCENDANT_PID_FILE:?}"
        printf '%s\n' \
            $'160000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tcontrol/Alpha' \
            $'160000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tshared/Beta'
        exit 0
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = exception-cleanup ]; then
        printf '%s\n' "$$" > "${ODYSSEUS_TEST_DESCENDANT_PID_FILE:?}"
        sleep 30
        exit 88
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = hang-status ]; then
        sleep 5
        exit 88
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = pipe-eof-status ]; then
        (sleep 30) &
        printf '%s\n' "$!" > "${ODYSSEUS_TEST_DESCENDANT_PID_FILE:?}"
        printf '%s\n' \
            $'160000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tcontrol/Alpha' \
            $'160000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tshared/Beta'
        exit 0
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = flood-status ]; then
        /usr/bin/python3 - <<'PY'
import sys
sys.stdout.write("x" * (2 * 1024 * 1024))
PY
        exit 0
    fi
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = slow-total ]; then
        sleep 1.1
    fi

    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" = conflicted ]; then
        printf '%s\n' \
            $'160000 1111111111111111111111111111111111111111 1\tcontrol/Alpha' \
            $'160000 2222222222222222222222222222222222222222 2\tcontrol/Alpha' \
            $'160000 3333333333333333333333333333333333333333 3\tcontrol/Alpha' \
            $'160000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tshared/Beta'
        exit 0
    fi

    printf '%s\n' \
        $'160000 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 0\tcontrol/Alpha'
    if [ "${ODYSSEUS_TEST_GIT_MODE:-ok}" != partial ]; then
        printf '%s\n' \
            $'160000 bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb 0\tshared/Beta'
    fi
    exit 0
fi

if [[ "${1:-}" = --git-dir=* ]] \
    && [ "${2:-}" = rev-parse ] && [ "${3:-}" = --verify ] \
    && [ "${4:-}" = 'HEAD^{commit}' ]; then
    case "${1#--git-dir=}" in
        */control/Alpha) printf '%s\n' aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ;;
        */shared/Beta) printf '%s\n' bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ;;
        *) exit 72 ;;
    esac
    exit 0
fi

exec "${ODYSSEUS_TEST_REAL_GIT:?}" "$@"
EOF
chmod +x "$fixture_bin/git"

cat > "$fixture_bin/python-driver.py" <<'PY'
import os
import sys
import tempfile


inline_argv = sys.argv[1:]
source = inline_argv[1]
destination = inline_argv[2]
parent = os.path.dirname(destination)
with open(source, "rb") as source_file:
    source_bytes = source_file.read()

descriptor, replacement = tempfile.mkstemp(prefix=".test-valid.", dir=parent)
replacement_pending = True
try:
    os.fchmod(descriptor, 0o755)
    with os.fdopen(descriptor, "wb", closefd=True) as output:
        output.write(source_bytes)
        output.flush()
        os.fsync(output.fileno())
    descriptor = -1

    original_open = os.open

    def replace_before_destination_open(path, *args, **kwargs):
        global replacement_pending
        opened_path = os.fspath(path)
        destination_open = opened_path == destination or (
            opened_path == os.path.basename(destination)
            and kwargs.get("dir_fd") is not None
        )
        if replacement_pending and destination_open:
            os.replace(replacement, destination)
            replacement_pending = False
        return original_open(path, *args, **kwargs)

    os.open = replace_before_destination_open
    sys.argv = inline_argv
    program = sys.stdin.read()
    exec(compile(program, "<stdin>", "exec"))
    if replacement_pending:
        raise SystemExit("controlled replacement boundary was not reached")
finally:
    if descriptor >= 0:
        os.close(descriptor)
    if replacement_pending:
        try:
            os.unlink(replacement)
        except FileNotFoundError:
            pass
PY

cat > "$fixture_bin/python-read-observer.py" <<'PY'
import os
import sys


inline_argv = sys.argv[1:]
target = os.environ["ODYSSEUS_TEST_READ_OBSERVER_TARGET"]
marker = os.environ["ODYSSEUS_TEST_READ_OBSERVER_MARKER"]
limit = 1024 * 1024
target_state = os.stat(target, follow_symlinks=False)
original_read = os.read
observed = 0


def observed_read(descriptor, size):
    global observed
    data = original_read(descriptor, size)
    try:
        state = os.fstat(descriptor)
    except OSError:
        return data
    if state.st_dev == target_state.st_dev and state.st_ino == target_state.st_ino:
        observed += len(data)
        if observed > limit:
            with open(marker, "w", encoding="utf-8") as output:
                output.write("read beyond limit\n")
    return data


os.read = observed_read
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
PY

cat > "$fixture_bin/python3" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
python_isolated=0
deadline_wrapper=0
deadline_arguments=()
if [ "${1:-}" = -I ] && [ "${2:-}" = -S ]; then
    python_isolated=1
    shift 2
    if [[ "${1:-}" = /dev/fd/* ]]; then
        deadline_wrapper=1
        deadline_arguments=("$@")
        shift 2
    fi
fi
python_runner=("${ODYSSEUS_TEST_REAL_PYTHON:?}")
if [ "$python_isolated" -eq 1 ]; then
    python_runner+=(-I -S)
fi
if [ "${ODYSSEUS_TEST_LINUX_FALLBACK:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_LINUX_FALLBACK_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_MALFORMED_RECEIPT:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    printf '%s\n' installed
    exit 0
fi
if [ "${ODYSSEUS_TEST_SWAP_CLEANUP_LEAF:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_CLEANUP_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_PUBLICATION_BARRIER:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_PUBLICATION_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_FLOCK_OBSERVER:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_FLOCK_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_SWAP_BEFORE_INSTALL:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_PREINSTALL_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_SWAP_SOURCE_BEFORE_INSTALL:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_SOURCE_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_SWAP_SOURCE_AFTER_OPEN:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_SOURCE_OPEN_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_SWAP_DESTINATION_AFTER_OPEN:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_DESTINATION_OPEN_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_HOOK_DIRECTORY_BARRIER:-0}" = 1 ] \
    && [ "$#" -eq 4 ] && [ "$1" = - ] \
    && [ "$2" = "${ODYSSEUS_TEST_TARGET_MODULE:?}" ] \
    && [[ "$3" =~ ^[0-9]+:[0-9]+$ ]]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_HOOK_DIRECTORY_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_HOOK_DIRECTORY_FLOCK_OBSERVER:-0}" = 1 ] \
    && [ "$#" -eq 4 ] && [ "$1" = - ] \
    && [ "$2" = "${ODYSSEUS_TEST_TARGET_MODULE:?}" ] \
    && [[ "$3" =~ ^[0-9]+:[0-9]+$ ]]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_FLOCK_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_SWAP_HOOK_PARENT:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_TARGET_DESTINATION:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_ANCESTOR_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_REPLACE_ON_DEST_OPEN:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [[ "$3" = */hooks/pre-commit ]]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_PYTHON_DRIVER:?}" "$@"
fi
if [ "${ODYSSEUS_TEST_READ_OBSERVER:-0}" = 1 ] \
    && [ "$#" -ge 4 ] && [ "$1" = - ] \
    && [ "$3" = "${ODYSSEUS_TEST_READ_OBSERVER_TARGET:?}" ]; then
    exec "${python_runner[@]}" \
        "${ODYSSEUS_TEST_READ_OBSERVER_DRIVER:?}" "$@"
fi
if [ "$deadline_wrapper" -eq 1 ]; then
    exec "${python_runner[@]}" "${deadline_arguments[@]}"
fi
exec "${python_runner[@]}" "$@"
EOF
chmod +x "$fixture_bin/python3"

bind_test_dependencies() {
    /usr/bin/python3 - "$1" "$fixture_bin/git" "$fixture_bin/python3" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
replacements = {
    "TRUSTED_GIT=/usr/bin/git": f"TRUSTED_GIT={sys.argv[2]}",
    "TRUSTED_PYTHON=/usr/bin/python3": f"TRUSTED_PYTHON={sys.argv[3]}",
    "GIT_CALL_TIMEOUT_SECONDS=20": "GIT_CALL_TIMEOUT_SECONDS=2",
    "GIT_RUNNER_TEST_ENV_KEYS=()": """GIT_RUNNER_TEST_ENV_KEYS=(
    ODYSSEUS_TEST_ASSERT_CLEAN_ENV ODYSSEUS_TEST_GIT_COMMON_DIR
    ODYSSEUS_TEST_DESCENDANT_PID_FILE ODYSSEUS_TEST_GIT_LOG
    ODYSSEUS_TEST_GIT_MODE ODYSSEUS_TEST_READY ODYSSEUS_TEST_REAL_GIT
    ODYSSEUS_TEST_RELEASE ODYSSEUS_TEST_ORDER_MARKER
)""",
    "PYTHON_RUNNER_TEST_ENV_KEYS=()": """PYTHON_RUNNER_TEST_ENV_KEYS=(
    ODYSSEUS_TEST_ANCESTOR_DRIVER ODYSSEUS_TEST_ANCESTOR_KIND
    ODYSSEUS_TEST_ANCESTOR_RECEIPT ODYSSEUS_TEST_CLEANUP_DRIVER
    ODYSSEUS_TEST_CLEANUP_MARKER ODYSSEUS_TEST_CLEANUP_VICTIM
    ODYSSEUS_TEST_DESTINATION_OPEN_DRIVER ODYSSEUS_TEST_DESTINATION_OPEN_RECEIPT
    ODYSSEUS_TEST_FLOCK_DRIVER ODYSSEUS_TEST_FLOCK_MARKER
    ODYSSEUS_TEST_FLOCK_OBSERVER ODYSSEUS_TEST_HOOK_DIRECTORY_BARRIER
    ODYSSEUS_TEST_HOOK_DIRECTORY_DRIVER ODYSSEUS_TEST_HOOK_DIRECTORY_FLOCK_OBSERVER
    ODYSSEUS_TEST_HOOK_DIRECTORY_READY ODYSSEUS_TEST_HOOK_DIRECTORY_RELEASE
    ODYSSEUS_TEST_LINUX_FALLBACK ODYSSEUS_TEST_LINUX_FALLBACK_DIRECTORY
    ODYSSEUS_TEST_LINUX_FALLBACK_DRIVER ODYSSEUS_TEST_LINUX_FALLBACK_MARKER
    ODYSSEUS_TEST_LINUX_FALLBACK_ERRNO
    ODYSSEUS_TEST_MALFORMED_RECEIPT ODYSSEUS_TEST_PREINSTALL_DRIVER
    ODYSSEUS_TEST_PREINSTALL_MARKER ODYSSEUS_TEST_PUBLICATION_BARRIER
    ODYSSEUS_TEST_PUBLICATION_DRIVER ODYSSEUS_TEST_PUBLICATION_READY
    ODYSSEUS_TEST_PUBLICATION_RELEASE ODYSSEUS_TEST_PYTHON_DRIVER
    ODYSSEUS_TEST_READ_OBSERVER ODYSSEUS_TEST_READ_OBSERVER_DRIVER
    ODYSSEUS_TEST_READ_OBSERVER_MARKER ODYSSEUS_TEST_READ_OBSERVER_TARGET
    ODYSSEUS_TEST_REAL_PYTHON ODYSSEUS_TEST_REPLACE_ON_DEST_OPEN
    ODYSSEUS_TEST_SOURCE_DRIVER ODYSSEUS_TEST_SOURCE_OPEN_DRIVER
    ODYSSEUS_TEST_SOURCE_SWAP_KIND ODYSSEUS_TEST_SWAP_BEFORE_INSTALL
    ODYSSEUS_TEST_SWAP_CLEANUP_LEAF ODYSSEUS_TEST_SWAP_DESTINATION_AFTER_OPEN
    ODYSSEUS_TEST_SWAP_HOOK_PARENT ODYSSEUS_TEST_SWAP_SOURCE_AFTER_OPEN
    ODYSSEUS_TEST_SWAP_SOURCE_BEFORE_INSTALL ODYSSEUS_TEST_TARGET_DESTINATION
    ODYSSEUS_TEST_TARGET_MODULE
)""",
}
for original, replacement in replacements.items():
    count = text.count(original)
    if count > 1:
        raise SystemExit(f"test dependency seam changed: {original}")
    if count == 1:
        text = text.replace(original, replacement)
path.write_text(text, encoding="utf-8")
PY
}

cat > "$fixture_bin/python-linux-fallback-driver.py" <<'PY'
import ctypes
import errno
import os
import sys
import tempfile


inline_argv = sys.argv[1:]
destination = inline_argv[2]
marker = os.environ["ODYSSEUS_TEST_LINUX_FALLBACK_MARKER"]
anonymous_directory = os.environ["ODYSSEUS_TEST_LINUX_FALLBACK_DIRECTORY"]
original_cdll = ctypes.CDLL
original_open = os.open
fake_tmpfile_flag = 1 << 29
os.O_TMPFILE = fake_tmpfile_flag
fallback_descriptor, anonymous_path = tempfile.mkstemp(
    prefix=".linux-fallback-test.",
    dir=anonymous_directory,
)
os.unlink(anonymous_path)
anonymous_available = True


def controlled_open(path, flags, *args, **kwargs):
    global anonymous_available
    if flags & fake_tmpfile_flag:
        if not anonymous_available:
            raise SystemExit("anonymous descriptor requested more than once")
        anonymous_available = False
        return fallback_descriptor
    return original_open(path, flags, *args, **kwargs)


class LinkAt:
    def __init__(self):
        self.calls = 0
        self.argtypes = None
        self.restype = None

    def __call__(self, old_directory, old_path, new_directory, new_path, flags):
        self.calls += 1
        if self.calls == 1:
            if (
                old_directory != fallback_descriptor
                or old_path != b""
                or flags != 0x1000
            ):
                raise SystemExit("unexpected AT_EMPTY_PATH publication")
            ctypes.set_errno(getattr(errno, os.environ.get(
                "ODYSSEUS_TEST_LINUX_FALLBACK_ERRNO", "EPERM"
            )))
            return -1
        expected_source = os.fsencode(f"/proc/self/fd/{fallback_descriptor}")
        if (
            self.calls != 2
            or old_directory != getattr(os, "AT_FDCWD", -100)
            or old_path != expected_source
            or new_path != os.fsencode(os.path.basename(destination))
            or flags != 0x400
        ):
            raise SystemExit("ordinary-user descriptor fallback was not used")
        output = original_open(
            os.fsdecode(new_path),
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o755,
            dir_fd=new_directory,
        )
        try:
            os.lseek(fallback_descriptor, 0, os.SEEK_SET)
            while True:
                chunk = os.read(fallback_descriptor, 1024 * 1024)
                if not chunk:
                    break
                offset = 0
                while offset < len(chunk):
                    offset += os.write(output, chunk[offset:])
            os.fchmod(output, 0o755)
            os.fsync(output)
        finally:
            os.close(output)
        with open(marker, "w", encoding="utf-8") as marker_file:
            marker_file.write("ordinary-user fallback\n")
        ctypes.set_errno(0)
        return 0


class LibraryProxy:
    def __init__(self, library, linkat):
        self.library = library
        self.linkat = linkat

    def __getattr__(self, name):
        if name == "linkat":
            return self.linkat
        return getattr(self.library, name)


linkat = LinkAt()


def controlled_cdll(*args, **kwargs):
    return LibraryProxy(original_cdll(*args, **kwargs), linkat)


os.open = controlled_open
ctypes.CDLL = controlled_cdll
sys.platform = "linux"
sys.argv = inline_argv
program = sys.stdin.read()
try:
    exec(compile(program, "<stdin>", "exec"))
finally:
    if anonymous_available:
        os.close(fallback_descriptor)
if linkat.calls != 2:
    raise SystemExit("descriptor fallback did not complete")
PY

cat > "$fixture_bin/python-cleanup-driver.py" <<'PY'
import os
import sys


inline_argv = sys.argv[1:]
destination = inline_argv[2]
victim = os.environ["ODYSSEUS_TEST_CLEANUP_VICTIM"]
marker = os.environ["ODYSSEUS_TEST_CLEANUP_MARKER"]
original_link = os.link
original_unlink = os.unlink
publication_seen = False

with open(marker + ".entered", "wb"):
    pass


def observe_publication(source, target, *args, **kwargs):
    global publication_seen
    result = original_link(source, target, *args, **kwargs)
    target_path = os.fspath(target)
    if target_path in {destination, os.path.basename(destination)}:
        publication_seen = True
    return result


def substitute_before_cleanup(path, *args, **kwargs):
    cleanup_name = os.fspath(path)
    directory = kwargs.get("dir_fd")
    if (
        publication_seen
        and not os.path.exists(marker)
        and directory is not None
        and os.path.basename(cleanup_name).startswith(".pre-commit.")
    ):
        original_unlink(path, *args, **kwargs)
        os.rename(victim, cleanup_name, dst_dir_fd=directory)
        with open(marker, "wb"):
            pass
        return original_unlink(path, *args, **kwargs)
    return original_unlink(path, *args, **kwargs)


os.link = observe_publication
os.unlink = substitute_before_cleanup
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
PY

cat > "$fixture_bin/python-source-open-driver.py" <<'PY'
import os
import sys
import tempfile


inline_argv = sys.argv[1:]
source = inline_argv[1]
displaced = source + ".opened-source"
swap_kind = os.environ.get("ODYSSEUS_TEST_SOURCE_SWAP_KIND", "source-file")
with open(source, "rb") as current:
    source_bytes = current.read()
descriptor, replacement = tempfile.mkstemp(
    prefix=".pre-commit-source-open.",
    dir=os.path.dirname(source),
)
try:
    os.fchmod(descriptor, 0o755)
    os.write(descriptor, source_bytes)
    os.fsync(descriptor)
finally:
    os.close(descriptor)

original_open = os.open
replacement_pending = True


def replace_source_after_open(path, *args, **kwargs):
    global replacement_pending
    opened = original_open(path, *args, **kwargs)
    opened_path = os.fspath(path)
    source_open = opened_path == source or (
        opened_path == os.path.basename(source) and kwargs.get("dir_fd") is not None
    )
    if replacement_pending and source_open:
        if swap_kind == "ancestor-symlink":
            parent = os.path.dirname(source)
            displaced_parent = parent + ".opened-parent"
            os.unlink(replacement)
            os.rename(parent, displaced_parent)
            os.symlink(os.path.basename(displaced_parent), parent)
        else:
            os.rename(source, displaced)
            os.rename(replacement, source)
        replacement_pending = False
    return opened


os.open = replace_source_after_open
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
if replacement_pending:
    raise SystemExit("controlled source-open boundary was not reached")
PY

cat > "$fixture_bin/python-destination-open-driver.py" <<'PY'
import os
import sys


inline_argv = sys.argv[1:]
destination = inline_argv[2]
destination_name = os.path.basename(destination)
displaced = destination + ".opened-canonical"
victim_bytes = b"post-open replacement victim\n"
original_open = os.open
replacement_pending = True


def replace_destination_after_open(path, *args, **kwargs):
    global replacement_pending
    opened = original_open(path, *args, **kwargs)
    directory = kwargs.get("dir_fd")
    relative_destination = False
    if os.fspath(path) == destination_name and directory is not None:
        opened_parent = os.fstat(directory)
        destination_parent = os.stat(
            os.path.dirname(destination),
            follow_symlinks=False,
        )
        relative_destination = (
            opened_parent.st_dev == destination_parent.st_dev
            and opened_parent.st_ino == destination_parent.st_ino
        )
    if replacement_pending and relative_destination:
        os.replace(destination, displaced)
        victim_descriptor = original_open(
            destination,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o700,
        )
        try:
            os.write(victim_descriptor, victim_bytes)
            os.fsync(victim_descriptor)
        finally:
            os.close(victim_descriptor)
        receipt = os.environ["ODYSSEUS_TEST_DESTINATION_OPEN_RECEIPT"]
        state = os.lstat(destination)
        with open(receipt, "w", encoding="ascii") as output:
            output.write(
                f"{state.st_dev}:{state.st_ino}:{state.st_nlink}:{state.st_size}\n"
            )
        replacement_pending = False
    return opened


os.open = replace_destination_after_open
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
if replacement_pending:
    raise SystemExit("controlled destination-open boundary was not reached")
PY

cat > "$fixture_bin/python-hooks-directory-barrier.py" <<'PY'
import os
import sys
import time


inline_argv = sys.argv[1:]
ready = os.environ["ODYSSEUS_TEST_HOOK_DIRECTORY_READY"]
release = os.environ["ODYSSEUS_TEST_HOOK_DIRECTORY_RELEASE"]
original_mkdir = os.mkdir
paused = False


def create_then_pause(path, *args, **kwargs):
    global paused
    if not paused and os.fspath(path) == "hooks" and kwargs.get("dir_fd") is not None:
        paused = True
        marker = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        os.close(marker)
        while not os.path.exists(release):
            time.sleep(0.01)
    return original_mkdir(path, *args, **kwargs)


os.mkdir = create_then_pause
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
if not paused:
    raise SystemExit("controlled hooks-directory boundary was not reached")
PY

cat > "$fixture_bin/python-publication-barrier.py" <<'PY'
import ctypes
import os
import sys
import time


inline_argv = sys.argv[1:]
ready = os.environ["ODYSSEUS_TEST_PUBLICATION_READY"]
release = os.environ["ODYSSEUS_TEST_PUBLICATION_RELEASE"]
original_cdll = ctypes.CDLL
original_link = os.link
paused = False


def pause_once():
    global paused
    if paused:
        return
    paused = True
    descriptor = os.open(ready, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    os.close(descriptor)
    while not os.path.exists(release):
        time.sleep(0.01)


def link_then_pause(source, target, *args, **kwargs):
    result = original_link(source, target, *args, **kwargs)
    pause_once()
    return result


class PublishCall:
    def __init__(self, function):
        self.function = function
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        pause_once()
        return self.function(*args)


class LibraryProxy:
    def __init__(self, library):
        self.library = library

    def __getattr__(self, name):
        function = getattr(self.library, name)
        if name in {"fclonefileat", "linkat"}:
            return PublishCall(function)
        return function


def controlled_cdll(*args, **kwargs):
    return LibraryProxy(original_cdll(*args, **kwargs))


os.link = link_then_pause
ctypes.CDLL = controlled_cdll
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
if not paused:
    raise SystemExit("controlled publication boundary was not reached")
PY

cat > "$fixture_bin/python-flock-observer.py" <<'PY'
import fcntl
import os
import sys


inline_argv = sys.argv[1:]
marker = os.environ["ODYSSEUS_TEST_FLOCK_MARKER"]
original_flock = fcntl.flock
observed = False


def observe_flock(descriptor, operation):
    global observed
    if not observed:
        observed = True
        marker_descriptor = os.open(
            marker,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL,
            0o600,
        )
        os.close(marker_descriptor)
    return original_flock(descriptor, operation)


fcntl.flock = observe_flock
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
if not observed:
    raise SystemExit("directory serialization boundary was not reached")
PY

cat > "$fixture_bin/python-preinstall-driver.py" <<'PY'
import os
import sys


inline_argv = sys.argv[1:]
destination = inline_argv[2]
parent = os.path.dirname(destination)
displaced_parent = parent + ".preflight-displaced"
marker = os.environ["ODYSSEUS_TEST_PREINSTALL_MARKER"]

if not os.path.exists(marker):
    os.replace(parent, displaced_parent)
    os.mkdir(parent, 0o700)
    victim = os.path.join(parent, "victim")
    with open(victim, "wb") as output:
        output.write(b"pre-install replacement victim\n")
        output.flush()
        os.fsync(output.fileno())
    with open(marker, "wb"):
        pass

sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
PY

cat > "$fixture_bin/python-source-driver.py" <<'PY'
import os
import sys
import tempfile


inline_argv = sys.argv[1:]
source = inline_argv[1]
with open(source, "rb") as current:
    source_bytes = current.read()
descriptor, replacement = tempfile.mkstemp(
    prefix=".pre-commit-source.",
    dir=os.path.dirname(source),
)
try:
    os.fchmod(descriptor, 0o755)
    offset = 0
    while offset < len(source_bytes):
        written = os.write(descriptor, source_bytes[offset:])
        if written <= 0:
            raise SystemExit(1)
        offset += written
    os.fsync(descriptor)
finally:
    os.close(descriptor)
os.replace(replacement, source)

sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
PY

cat > "$fixture_bin/python-ancestor-driver.py" <<'PY'
import ctypes
import os
import sys


inline_argv = sys.argv[1:]
destination = inline_argv[2]
parent = os.path.dirname(destination)
displaced_parent = parent + ".displaced"
victim_bytes = b"replacement-path victim\n"
swap_kind = os.environ.get("ODYSSEUS_TEST_ANCESTOR_KIND", "replacement-parent")
replacement_pending = True
original_replace = os.replace
original_link = os.link
original_cdll = ctypes.CDLL


def prepare_ancestor_swap(source, target, kwargs):
    global replacement_pending
    target_path = os.fspath(target)
    if isinstance(target_path, bytes):
        target_path = os.fsdecode(target_path)
    if replacement_pending and target_path in {destination, os.path.basename(destination)}:
        if swap_kind == "intermediate-symlink":
            ancestor = os.path.dirname(parent)
            displaced_ancestor = ancestor + ".displaced"
            original_replace(ancestor, displaced_ancestor)
            os.symlink(os.path.basename(displaced_ancestor), ancestor)
            replacement_pending = False
            return
        original_replace(parent, displaced_parent)
        os.mkdir(parent, 0o700)
        with open(destination, "wb") as victim:
            victim.write(victim_bytes)
            victim.flush()
            os.fsync(victim.fileno())
        receipt = os.environ.get("ODYSSEUS_TEST_ANCESTOR_RECEIPT")
        if receipt:
            value = os.lstat(destination)
            with open(receipt, "w", encoding="ascii") as output:
                output.write(
                    f"{value.st_dev}:{value.st_ino}:{value.st_nlink}:{value.st_size}\n"
                )
        if not kwargs.get("src_dir_fd") and source and os.path.isabs(os.fspath(source)):
            with open(os.fspath(source), "wb") as redirected_source:
                redirected_source.write(b"redirected publication\n")
        replacement_pending = False


def swap_parent_before_replace(source, target, *args, **kwargs):
    prepare_ancestor_swap(source, target, kwargs)
    return original_replace(source, target, *args, **kwargs)


def swap_parent_before_link(source, target, *args, **kwargs):
    prepare_ancestor_swap(source, target, kwargs)
    return original_link(source, target, *args, **kwargs)


class PublishCall:
    def __init__(self, function, target_index):
        self.function = function
        self.target_index = target_index
        self.argtypes = None
        self.restype = None

    def __call__(self, *args):
        prepare_ancestor_swap(
            "", args[self.target_index], {"dst_dir_fd": args[self.target_index - 1]}
        )
        return self.function(*args)


class LibraryProxy:
    def __init__(self, library):
        self.library = library

    def __getattr__(self, name):
        function = getattr(self.library, name)
        if name == "fclonefileat":
            return PublishCall(function, 2)
        if name == "linkat":
            return PublishCall(function, 3)
        return function


def controlled_cdll(*args, **kwargs):
    return LibraryProxy(original_cdll(*args, **kwargs))


os.replace = swap_parent_before_replace
os.link = swap_parent_before_link
ctypes.CDLL = controlled_cdll
sys.argv = inline_argv
program = sys.stdin.read()
exec(compile(program, "<stdin>", "exec"))
if replacement_pending:
    raise SystemExit("controlled ancestor-swap boundary was not reached")
PY

run_propagator() {
    local git_mode="$1"
    shift
    : > "$git_log"
    set +e
    ODYSSEUS_TEST_GIT_LOG="$git_log" \
    ODYSSEUS_TEST_GIT_MODE="$git_mode" \
    ODYSSEUS_TEST_REAL_GIT="$real_git" \
    ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_GITMODULES="$fixture_repo/.gitmodules" \
    ODYSSEUS_TEST_HELPER_SWAP_MARKER="$fixture_root/helper-swap.marker" \
    ODYSSEUS_TEST_ASSERT_CLEAN_ENV="${ODYSSEUS_TEST_ASSERT_CLEAN_ENV:-0}" \
    PATH="$fixture_bin:$PATH" \
        "$subject_bash" \
        "${PROPAGATOR_PATH:-$fixture_repo/tools/propagate-pre-commit-hooks.sh}" \
        "$@" \
        > "$fixture_root/stdout" 2> "$fixture_root/stderr"
    propagator_status=$?
    set -e
}

bind_test_dependencies "$fixture_repo/tools/propagate-pre-commit-hooks.sh"

info "conflicting dry-run and verify modes stop before filesystem inspection"
write_valid_inventory
reset_destinations
mv "$fixture_repo/.githooks/pre-commit" \
    "$fixture_repo/.githooks/pre-commit.unavailable"
run_propagator ok --dry-run --verify
conflicting_mode_status=$propagator_status
mv "$fixture_repo/.githooks/pre-commit.unavailable" \
    "$fixture_repo/.githooks/pre-commit"
if [ "$conflicting_mode_status" -eq 2 ] \
    && grep -Fq 'mutually exclusive' "$fixture_root/stderr" \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "the conflicting operation is rejected before source inspection"
else
    fail "conflicting operation modes reached filesystem validation"
fi

info "the subject interpreter is not selected through hostile PATH content"
write_valid_inventory
reset_destinations
bash_shadow_marker="$fixture_root/path-bash.executed"
cat > "$fixture_bin/bash" <<'EOF'
#!/bin/sh
if [ "${1:-}" = "${ODYSSEUS_TEST_SUBJECT_PATH:?}" ]; then
    : > "${ODYSSEUS_TEST_BASH_SHADOW_MARKER:?}"
fi
exec "${ODYSSEUS_TEST_SELECTED_BASH:?}" "$@"
EOF
chmod +x "$fixture_bin/bash"
export ODYSSEUS_TEST_SUBJECT_PATH="$fixture_repo/tools/propagate-pre-commit-hooks.sh"
export ODYSSEUS_TEST_BASH_SHADOW_MARKER="$bash_shadow_marker"
export ODYSSEUS_TEST_SELECTED_BASH="$subject_bash"
run_propagator ok --dry-run
bash_shadow_status=$propagator_status
unset ODYSSEUS_TEST_SUBJECT_PATH ODYSSEUS_TEST_BASH_SHADOW_MARKER
unset ODYSSEUS_TEST_SELECTED_BASH
rm "$fixture_bin/bash"
if [ "$bash_shadow_status" -eq 0 ] && [ ! -e "$bash_shadow_marker" ]; then
    pass "the exact suite-selected Bash executes the subject"
else
    fail "PATH content selected or intercepted the subject interpreter"
fi

info "embedded Python ignores hostile import and site customization paths"
write_valid_inventory
reset_destinations
hostile_python="$fixture_root/hostile-python"
site_marker="$fixture_root/sitecustomize.executed"
module_marker="$fixture_root/hashlib-shadow.executed"
mkdir "$hostile_python"
cat > "$hostile_python/sitecustomize.py" <<'PY'
import os
with open(os.environ["ODYSSEUS_TEST_SITE_MARKER"], "w", encoding="utf-8") as output:
    output.write("executed\n")
PY
cat > "$hostile_python/hashlib.py" <<'PY'
import os
with open(os.environ["ODYSSEUS_TEST_MODULE_MARKER"], "w", encoding="utf-8") as output:
    output.write("executed\n")
raise RuntimeError("hostile hashlib shadow executed")
PY
export PYTHONPATH="$hostile_python"
export ODYSSEUS_TEST_SITE_MARKER="$site_marker"
export ODYSSEUS_TEST_MODULE_MARKER="$module_marker"
run_propagator ok --dry-run
python_isolation_status=$propagator_status
unset PYTHONPATH ODYSSEUS_TEST_SITE_MARKER ODYSSEUS_TEST_MODULE_MARKER
if [ "$python_isolation_status" -eq 0 ] \
    && [ ! -e "$site_marker" ] && [ ! -e "$module_marker" ] \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "untrusted Python startup and shadow modules have no effects"
else
    fail "an embedded Python invocation loaded hostile environment content"
fi

info "trusted Git receives an exact minimal environment"
write_valid_inventory
reset_destinations
ODYSSEUS_TEST_ASSERT_CLEAN_ENV=1 \
GIT_OPTIONAL_LOCKS=1 GIT_TRACE="$fixture_root/ambient-git-trace" \
GIT_TRACE2_EVENT="$fixture_root/ambient-trace2" \
LD_LIBRARY_PATH="$fixture_root/ambient-library" \
ODYSSEUS_UNRELATED_ENV=present \
    run_propagator ok --dry-run
if [ "$propagator_status" -eq 0 ] \
    && ! grep -Fq 'unclean Git environment' "$git_log" \
    && [ ! -e "$fixture_root/ambient-git-trace" ] \
    && [ ! -e "$fixture_root/ambient-trace2" ]; then
    pass "ambient trace, loader, routing, and unrelated values have zero effects"
else
    fail "trusted Git inherited ambient process state"
fi

info "the production propagator does not select Git or Python through PATH"
trusted_runtime_repo="$fixture_root/trusted-runtime-repo"
trusted_runtime_bin="$fixture_root/trusted-runtime-bin"
mkdir -p "$trusted_runtime_repo/tools" "$trusted_runtime_repo/.githooks" \
    "$trusted_runtime_repo/.git" "$trusted_runtime_bin"
cp "$ROOT/tools/propagate-pre-commit-hooks.sh" \
    "$trusted_runtime_repo/tools/propagate-pre-commit-hooks.sh"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' \
    > "$trusted_runtime_repo/.githooks/pre-commit"
chmod 0755 "$trusted_runtime_repo/.githooks/pre-commit"
cat > "$trusted_runtime_repo/.gitmodules" <<'EOF'
[submodule "control/Alpha"]
    path = control/Alpha
    url = https://github.com/HomericIntelligence/Alpha.git
EOF
for executable in git python3; do
    cat > "$trusted_runtime_bin/$executable" <<'EOF'
#!/usr/bin/env bash
: > "${ODYSSEUS_TEST_HOSTILE_RUNTIME_MARKER:?}"
exit 91
EOF
    chmod +x "$trusted_runtime_bin/$executable"
done
set +e
ODYSSEUS_TEST_HOSTILE_RUNTIME_MARKER="$trusted_runtime_repo/runtime-ran" \
PATH="$trusted_runtime_bin:/usr/bin:/bin" \
    "$subject_bash" \
    "$trusted_runtime_repo/tools/propagate-pre-commit-hooks.sh" --dry-run \
    > "$fixture_root/trusted-runtime.out" 2>&1
trusted_runtime_status=$?
set -e
if [ "$trusted_runtime_status" -ne 0 ] \
    && [ ! -e "$trusted_runtime_repo/runtime-ran" ]; then
    pass "PATH Git and Python executables have zero effects"
else
    fail "the production propagator selected a runtime through PATH"
fi

info "ambient exported functions cannot intercept production commands"
exported_function_marker="$fixture_root/exported-function.executed"
set +e
(
    # shellcheck disable=SC2329  # Exported into the subject Bash process.
    cat() {
        : > "${ODYSSEUS_TEST_EXPORTED_FUNCTION_MARKER:?}"
        return 91
    }
    # shellcheck disable=SC2329  # Exported into the subject Bash process.
    dirname() {
        : > "${ODYSSEUS_TEST_EXPORTED_FUNCTION_MARKER:?}"
        return 92
    }
    export -f cat dirname
    ODYSSEUS_TEST_EXPORTED_FUNCTION_MARKER="$exported_function_marker" \
        "$subject_bash" \
        "$fixture_repo/tools/propagate-pre-commit-hooks.sh" --help \
        > "$fixture_root/exported-function.out" 2>&1
)
exported_function_status=$?
set -e
if [ "$exported_function_status" -eq 0 ] \
    && [ ! -e "$exported_function_marker" ] \
    && grep -Fq 'Usage: tools/propagate-pre-commit-hooks.sh' \
        "$fixture_root/exported-function.out"; then
    pass "help uses only shell built-ins before isolated execution"
else
    fail "an exported function intercepted a production command"
fi

info "the canonical inventory file stays bound through helper parsing"
write_valid_inventory
reset_destinations
rm -f "$fixture_root/helper-swap.marker" \
    "$fixture_repo/.gitmodules.original"
run_propagator helper-swap
helper_swap_status=$propagator_status
if [ "$helper_swap_status" -eq 0 ] \
    && [ ! -e "$fixture_root/helper-swap.marker" ] \
    && [ ! -e "$fixture_repo/.gitmodules.original" ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "the retained descriptor bytes are parsed without reopening .gitmodules"
else
    fail "Git reparsed the canonical inventory pathname"
fi
if [ -f "$fixture_repo/.gitmodules.original" ]; then
    rm -f "$fixture_repo/.gitmodules"
    mv "$fixture_repo/.gitmodules.original" "$fixture_repo/.gitmodules"
fi
reset_destinations

info "ordinary-user Linux publication falls back without losing descriptor binding"
for fallback_errno in EPERM EACCES ENOENT; do
write_valid_inventory
reset_destinations
linux_fallback_marker="$fixture_root/linux-fallback.executed"
linux_fallback_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
export ODYSSEUS_TEST_LINUX_FALLBACK=1
export ODYSSEUS_TEST_LINUX_FALLBACK_ERRNO="$fallback_errno"
export ODYSSEUS_TEST_TARGET_DESTINATION="$linux_fallback_destination"
export ODYSSEUS_TEST_LINUX_FALLBACK_DRIVER="$fixture_bin/python-linux-fallback-driver.py"
export ODYSSEUS_TEST_LINUX_FALLBACK_MARKER="$linux_fallback_marker"
export ODYSSEUS_TEST_LINUX_FALLBACK_DIRECTORY="$fixture_root"
run_propagator ok
linux_fallback_status=$propagator_status
unset ODYSSEUS_TEST_LINUX_FALLBACK ODYSSEUS_TEST_TARGET_DESTINATION
unset ODYSSEUS_TEST_LINUX_FALLBACK_DRIVER ODYSSEUS_TEST_LINUX_FALLBACK_MARKER
unset ODYSSEUS_TEST_LINUX_FALLBACK_DIRECTORY
unset ODYSSEUS_TEST_LINUX_FALLBACK_ERRNO
if [ "$linux_fallback_status" -eq 0 ] \
    && [ "$(cat "$linux_fallback_marker" 2>/dev/null)" = 'ordinary-user fallback' ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "$fallback_errno uses the proc-fd fallback and verifies the published inode"
else
    cat "$fixture_root/stderr" >&2
    fail "AT_EMPTY_PATH privilege failure prevented safe publication"
fi
done
if [ "$(uname -s)" != Linux ] || [ "$(id -u)" -eq 0 ]; then
    printf '%s\n' \
        '[INFO] real unprivileged O_TMPFILE publication remains a Linux CI boundary' >&2
fi

info "a complete canonical inventory is bound before a dry-run report"
write_valid_inventory
reset_destinations
run_propagator ok --dry-run
if [ "$propagator_status" -eq 0 ] \
    && grep -Fq 'total submodules parsed:       2' "$fixture_root/stdout" \
    && grep -Fq 'control/Alpha' "$fixture_root/stdout" \
    && grep -Fq 'shared/Beta' "$fixture_root/stdout"; then
    pass "the complete inventory is represented exactly once"
else
    fail "a valid canonical inventory did not produce a complete plan"
fi

info "conflicted gitlinks preserve the public U status marker"
write_valid_inventory
reset_destinations
run_propagator conflicted --dry-run
if [ "$propagator_status" -eq 0 ] \
    && grep -Fq "control/Alpha -> .git/modules/control/Alpha/hooks/pre-commit" \
        "$fixture_root/stdout" \
    && grep -Fq "submodule-status='U'" "$fixture_root/stdout" \
    && grep -Fq 'planned (initialized):        2' "$fixture_root/stdout"; then
    pass "an unmerged canonical gitlink remains initialized and explicit"
else
    cat "$fixture_root/stderr" >&2
    fail "unmerged index stages became unavailable propagation state"
fi

info "a worktree may publish into its separately bound common Git directory"
write_valid_inventory
reset_destinations
worktree_common_dir="$fixture_root/worktree-common-git"
mv "$fixture_repo/.git" "$worktree_common_dir"
printf 'gitdir: %s\n' "$worktree_common_dir" > "$fixture_repo/.git"
printf 'gitdir: %s\n' "$worktree_common_dir/modules/control/Alpha" \
    > "$fixture_repo/control/Alpha/.git"
printf 'gitdir: %s\n' "$worktree_common_dir/modules/shared/Beta" \
    > "$fixture_repo/shared/Beta/.git"
export ODYSSEUS_TEST_GIT_COMMON_DIR="$worktree_common_dir"
run_propagator ok
worktree_common_status=$propagator_status
unset ODYSSEUS_TEST_GIT_COMMON_DIR
rm "$fixture_repo/.git"
mv "$worktree_common_dir" "$fixture_repo/.git"
printf 'gitdir: %s\n' "$fixture_repo/.git/modules/control/Alpha" \
    > "$fixture_repo/control/Alpha/.git"
printf 'gitdir: %s\n' "$fixture_repo/.git/modules/shared/Beta" \
    > "$fixture_repo/shared/Beta/.git"
if [ "$worktree_common_status" -eq 0 ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "source and external Git-admin roots remain independently bound"
else
    cat "$fixture_root/stderr" >&2
    fail "a valid linked-worktree common directory was rejected"
fi

info "malformed and duplicate inventory entries fail before reporting"
printf '%s\n' '[submodule "broken"' > "$fixture_repo/.gitmodules"
run_propagator ok --dry-run
malformed_status=$propagator_status
malformed_stdout_size=$(wc -c < "$fixture_root/stdout")
cat > "$fixture_repo/.gitmodules" <<'EOF'
[submodule "control/Alpha"]
    path = control/Alpha
    url = https://github.com/HomericIntelligence/Alpha.git
[submodule "duplicate"]
    path = control/Alpha
    url = https://github.com/HomericIntelligence/Other.git
EOF
run_propagator ok --dry-run
duplicate_status=$propagator_status
duplicate_stdout_size=$(wc -c < "$fixture_root/stdout")
cat > "$fixture_repo/.gitmodules" <<'EOF'
[submodule "control/Alpha"]
    path = control/Alpha
    url = https://github.com/HomericIntelligence/Alpha.git
[submodule "shared/Beta"]
    path = shared/Beta
    url = https://github.com/HomericIntelligence/Alpha.git
EOF
run_propagator ok --dry-run
duplicate_url_status=$propagator_status
duplicate_url_stdout_size=$(wc -c < "$fixture_root/stdout")
if [ "$malformed_status" -ne 0 ] \
    && [ "$duplicate_status" -ne 0 ] \
    && [ "$duplicate_url_status" -ne 0 ] \
    && [ "$malformed_stdout_size" -eq 0 ] \
    && [ "$duplicate_stdout_size" -eq 0 ] \
    && [ "$duplicate_url_stdout_size" -eq 0 ]; then
    pass "invalid inventories cannot become zero-coverage success"
else
    fail "a malformed or duplicate inventory produced a report"
fi

info "partial Git status inventory is unavailable before writes"
write_valid_inventory
reset_destinations
run_propagator partial
if [ "$propagator_status" -ne 0 ] \
    && [ ! -s "$fixture_root/stdout" ] \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "partial status data cannot install a partial hook fleet"
else
    fail "partial status data produced output or hook writes"
fi

info "every Git read has one finite process-tree and output boundary"
for bounded_mode in hang-status pipe-eof-status flood-status; do
    write_valid_inventory
    reset_destinations
    ODYSSEUS_TEST_DESCENDANT_PID_FILE="$fixture_root/$bounded_mode.pid"
    export ODYSSEUS_TEST_DESCENDANT_PID_FILE
    rm -f "$ODYSSEUS_TEST_DESCENDANT_PID_FILE"
    SECONDS=0
    run_propagator "$bounded_mode" --dry-run
    bounded_elapsed=$SECONDS
    descendant_stopped=true
    if [ "$bounded_mode" = pipe-eof-status ]; then
        descendant_stopped=false
        descendant_pid=""
        if ! descendant_pid=$(cat "$ODYSSEUS_TEST_DESCENDANT_PID_FILE" \
            2>/dev/null); then :; fi
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
    if [ "$propagator_status" -ne 0 ] && [ "$bounded_elapsed" -le 3 ] \
        && [ "$descendant_stopped" = true ] \
        && grep -Eq 'timed out|output limit' "$fixture_root/stderr"; then
        pass "$bounded_mode is rejected inside the shared Git runner"
    else
        printf 'mode=%s status=%s elapsed=%s\n' \
            "$bounded_mode" "$propagator_status" "$bounded_elapsed" >&2
        cat "$fixture_root/stderr" >&2
        fail "$bounded_mode escaped the shared Git runner"
    fi
done
unset ODYSSEUS_TEST_DESCENDANT_PID_FILE

info "successful EOF cleanup terminates the group before reaping its leader"
write_valid_inventory
reset_destinations
ODYSSEUS_TEST_DESCENDANT_PID_FILE="$fixture_root/success-eof-order.pid"
ODYSSEUS_TEST_ORDER_MARKER="$fixture_root/success-eof-order.marker"
export ODYSSEUS_TEST_DESCENDANT_PID_FILE ODYSSEUS_TEST_ORDER_MARKER
rm -f "$ODYSSEUS_TEST_DESCENDANT_PID_FILE" "$ODYSSEUS_TEST_ORDER_MARKER"
run_propagator success-eof-order --dry-run
order_descendant_stopped=false
order_descendant_pid=""
if ! order_descendant_pid=$(cat "$ODYSSEUS_TEST_DESCENDANT_PID_FILE" 2>/dev/null); then :; fi
if [[ "$order_descendant_pid" =~ ^[0-9]+$ ]]; then
    for _ in $(seq 1 20); do
        if ! kill -0 "$order_descendant_pid" 2>/dev/null; then
            order_descendant_stopped=true
            break
        fi
        sleep 0.05
    done
fi
order_marker=""
if ! order_marker=$(cat "$ODYSSEUS_TEST_ORDER_MARKER" 2>/dev/null); then :; fi
if [ "$propagator_status" -eq 0 ] \
    && [ "$order_descendant_stopped" = true ] \
    && [ "$order_marker" = reserved ]; then
    pass "the leader PID remains reserved until its process group is extinct"
else
    fail "the Git leader was reaped before process-group termination"
fi
unset ODYSSEUS_TEST_DESCENDANT_PID_FILE ODYSSEUS_TEST_ORDER_MARKER

info "unexpected collection failures still terminate and reap trusted Git"
write_valid_inventory
reset_destinations
exception_subject="$fixture_repo/tools/propagate-runner-exception.sh"
cp "$fixture_repo/tools/propagate-pre-commit-hooks.sh" "$exception_subject"
/usr/bin/python3 - "$exception_subject" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
seam = 'selector.register(process.stderr, selectors.EVENT_READ, "stderr")'
if source.count(seam) != 1:
    raise SystemExit("Git collection exception seam changed")
source = source.replace(seam, seam + '\nraise RuntimeError("controlled collection failure")')
path.write_text(source, encoding="utf-8")
PY
ODYSSEUS_TEST_DESCENDANT_PID_FILE="$fixture_root/exception-cleanup.pid"
export ODYSSEUS_TEST_DESCENDANT_PID_FILE
rm -f "$ODYSSEUS_TEST_DESCENDANT_PID_FILE"
PROPAGATOR_PATH="$exception_subject" run_propagator exception-cleanup --dry-run
exception_pid=""
for _ in $(seq 1 20); do
    exception_pid=""
    if ! exception_pid=$(cat "$ODYSSEUS_TEST_DESCENDANT_PID_FILE" 2>/dev/null); then :; fi
    [[ "$exception_pid" =~ ^[0-9]+$ ]] && break
    sleep 0.05
done
exception_process_stopped=true
if [[ "$exception_pid" =~ ^[0-9]+$ ]] \
    && kill -0 "$exception_pid" 2>/dev/null; then
    exception_process_stopped=false
    if ! /bin/kill -TERM -- "-$exception_pid" 2>/dev/null; then :; fi
fi
if [ "$propagator_status" -ne 0 ] \
    && [ "$exception_process_stopped" = true ]; then
    pass "all post-spawn runner paths perform process-group cleanup"
else
    fail "a collection exception abandoned the trusted Git process group"
fi
unset ODYSSEUS_TEST_DESCENDANT_PID_FILE

info "the whole propagation operation shares one finite deadline"
write_valid_inventory
reset_destinations
total_subject="$fixture_repo/tools/propagate-total-deadline.sh"
cp "$fixture_repo/tools/propagate-pre-commit-hooks.sh" "$total_subject"
/usr/bin/python3 - "$total_subject" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
old = "TOTAL_OPERATION_TIMEOUT_SECONDS=120"
if source.count(old) != 1:
    raise SystemExit("total-operation deadline seam changed")
path.write_text(source.replace(old, "TOTAL_OPERATION_TIMEOUT_SECONDS=2"), encoding="utf-8")
PY
total_common_dir="$fixture_root/total-common-git"
mv "$fixture_repo/.git" "$total_common_dir"
printf 'gitdir: %s\n' "$total_common_dir" > "$fixture_repo/.git"
printf 'gitdir: %s\n' "$total_common_dir/modules/control/Alpha" \
    > "$fixture_repo/control/Alpha/.git"
printf 'gitdir: %s\n' "$total_common_dir/modules/shared/Beta" \
    > "$fixture_repo/shared/Beta/.git"
export ODYSSEUS_TEST_GIT_COMMON_DIR="$total_common_dir"
PROPAGATOR_PATH="$total_subject"
SECONDS=0
run_propagator slow-total --dry-run
total_deadline_elapsed=$SECONDS
total_deadline_status=$propagator_status
unset PROPAGATOR_PATH ODYSSEUS_TEST_GIT_COMMON_DIR
rm "$fixture_repo/.git"
mv "$total_common_dir" "$fixture_repo/.git"
printf 'gitdir: %s\n' "$fixture_repo/.git/modules/control/Alpha" \
    > "$fixture_repo/control/Alpha/.git"
printf 'gitdir: %s\n' "$fixture_repo/.git/modules/shared/Beta" \
    > "$fixture_repo/shared/Beta/.git"
if [ "$total_deadline_status" -ne 0 ] \
    && [ "$total_deadline_elapsed" -le 3 ] \
    && grep -Fq 'operation deadline expired' "$fixture_root/stderr" \
    && [ ! -s "$fixture_root/stdout" ]; then
    pass "successive Git reads cannot extend the whole-operation deadline"
else
    printf 'status=%s elapsed=%s\n' \
        "$total_deadline_status" "$total_deadline_elapsed" >&2
    cat "$fixture_root/stderr" >&2
    fail "successive Git reads reset the whole-operation deadline"
fi

info "the operation deadline also bounds post-Git helper work"
write_valid_inventory
reset_destinations
post_git_subject="$fixture_repo/tools/propagate-post-git-deadline.sh"
cp "$fixture_repo/tools/propagate-pre-commit-hooks.sh" "$post_git_subject"
/usr/bin/python3 - "$post_git_subject" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
source = path.read_text(encoding="utf-8")
deadline = "TOTAL_OPERATION_TIMEOUT_SECONDS=120"
helper = "def read_descriptor(descriptor, current_directory, current_name):"
if source.count(deadline) != 1 or source.count(helper) != 1:
    raise SystemExit("post-Git deadline seam changed")
source = source.replace(deadline, "TOTAL_OPERATION_TIMEOUT_SECONDS=2")
source = source.replace(helper, "time.sleep(5)\n\n\n" + helper)
path.write_text(source, encoding="utf-8")
PY
PROPAGATOR_PATH="$post_git_subject"
SECONDS=0
run_propagator ok
post_git_deadline_elapsed=$SECONDS
post_git_deadline_status=$propagator_status
unset PROPAGATOR_PATH
if [ "$post_git_deadline_status" -ne 0 ] \
    && [ "$post_git_deadline_elapsed" -le 3 ] \
    && grep -Fq 'operation deadline expired' "$fixture_root/stderr" \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "post-Git verification and publication share the absolute deadline"
else
    printf 'status=%s elapsed=%s\n' \
        "$post_git_deadline_status" "$post_git_deadline_elapsed" >&2
    cat "$fixture_root/stderr" >&2
    fail "post-Git helper work escaped the whole-operation deadline"
fi

info "canonical inventory count is bounded before Git observation"
{
    for inventory_index in $(seq 1 257); do
        printf '[submodule "group/Repo%s"]\n' "$inventory_index"
        printf '    path = group/Repo%s\n' "$inventory_index"
        printf '    url = https://github.com/HomericIntelligence/Repo%s.git\n' \
            "$inventory_index"
    done
} > "$fixture_repo/.gitmodules"
reset_destinations
run_propagator ok --dry-run
if [ "$propagator_status" -ne 0 ] && [ ! -s "$git_log" ]; then
    pass "an oversized submodule inventory stops before Git reads"
else
    fail "an oversized submodule inventory reached Git or reporting"
fi
write_valid_inventory

info "verify and live modes cannot claim exact coverage for an uninitialized member"
write_valid_inventory
reset_destinations
rm -rf -- "$fixture_repo/.git/modules/shared/Beta"
cp "$fixture_repo/.githooks/pre-commit" \
    "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
run_propagator ok --verify
verify_uninitialized_status=$propagator_status
run_propagator ok
live_uninitialized_status=$propagator_status
if [ "$verify_uninitialized_status" -ne 0 ] \
    && [ "$live_uninitialized_status" -ne 0 ]; then
    pass "uninitialized members remain explicit incomplete coverage"
else
    fail "uninitialized members were summarized as successful fleet coverage"
fi

info "an uninitialized status marker overrides a stale module administration directory"
write_valid_inventory
reset_destinations
rm "$fixture_repo/shared/Beta/.git"
run_propagator uninitialized-stale
if [ "$propagator_status" -ne 0 ] \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "stale administration state cannot conceal an uninitialized member"
else
    fail "an uninitialized status marker was treated as complete coverage"
fi

info "verify requires an executable hook, not matching bytes alone"
write_valid_inventory
reset_destinations
for hook_path in \
    "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; do
    cp "$fixture_repo/.githooks/pre-commit" "$hook_path"
    chmod 0755 "$hook_path"
done
chmod 0644 "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
run_propagator ok --verify
if [ "$propagator_status" -ne 0 ]; then
    pass "a non-executable installed hook is stale"
else
    fail "matching but non-executable hook bytes passed verification"
fi

info "trusted files and repository-controlled directories require safe owner modes"
permission_boundary_failures=0
write_valid_inventory
reset_destinations
chmod 0644 "$fixture_repo/.githooks/pre-commit"
run_propagator ok
nonexecuted_source_status=$propagator_status
if [ "$nonexecuted_source_status" -ne 0 ] \
    || [ ! -x "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    || [ ! -x "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi
chmod 0755 "$fixture_repo/.githooks/pre-commit"

for source_mode in 0001 0022 0777; do
    write_valid_inventory
    reset_destinations
    chmod "$source_mode" "$fixture_repo/.githooks/pre-commit"
    run_propagator ok
    if [ "$propagator_status" -eq 0 ] \
        || [ -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
        || [ -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
        permission_boundary_failures=$((permission_boundary_failures + 1))
    fi
done
chmod 0755 "$fixture_repo/.githooks/pre-commit"

for destination_mode in 0001 0022 0601 0777; do
    write_valid_inventory
    reset_destinations
    for hook_path in \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; do
        cp "$fixture_repo/.githooks/pre-commit" "$hook_path"
        chmod "$destination_mode" "$hook_path"
    done
    run_propagator ok --verify
    if [ "$propagator_status" -eq 0 ]; then
        permission_boundary_failures=$((permission_boundary_failures + 1))
    fi
done

write_valid_inventory
reset_destinations
chmod 0777 "$fixture_repo/.git/modules/control/Alpha/hooks"
run_propagator ok
unsafe_hook_directory_status=$propagator_status
chmod 0755 "$fixture_repo/.git/modules/control/Alpha/hooks"
if [ "$unsafe_hook_directory_status" -eq 0 ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi

write_valid_inventory
reset_destinations
chmod 0777 "$fixture_repo/.git/modules/control/Alpha"
run_propagator ok
unsafe_module_directory_status=$propagator_status
chmod 0755 "$fixture_repo/.git/modules/control/Alpha"
if [ "$unsafe_module_directory_status" -eq 0 ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi

write_valid_inventory
reset_destinations
chmod 0777 "$fixture_repo/.git/modules/control"
run_propagator ok
unsafe_ancestor_status=$propagator_status
chmod 0755 "$fixture_repo/.git/modules/control"
if [ "$unsafe_ancestor_status" -eq 0 ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi

write_valid_inventory
reset_destinations
chmod 0777 "$fixture_repo/.githooks"
run_propagator ok
unsafe_source_parent_status=$propagator_status
chmod 0755 "$fixture_repo/.githooks"
if [ "$unsafe_source_parent_status" -eq 0 ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi

write_valid_inventory
reset_destinations
chmod 0777 "$fixture_repo/.gitmodules"
run_propagator ok --dry-run
unsafe_inventory_status=$propagator_status
chmod 0644 "$fixture_repo/.gitmodules"
if [ "$unsafe_inventory_status" -eq 0 ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi

write_valid_inventory
reset_destinations
unsafe_pointer_common="$fixture_root/unsafe-pointer-common"
mv "$fixture_repo/.git" "$unsafe_pointer_common"
printf 'gitdir: %s\n' "$unsafe_pointer_common" > "$fixture_repo/.git"
chmod 0777 "$fixture_repo/.git"
export ODYSSEUS_TEST_GIT_COMMON_DIR="$unsafe_pointer_common"
run_propagator ok
unsafe_pointer_status=$propagator_status
unset ODYSSEUS_TEST_GIT_COMMON_DIR
rm "$fixture_repo/.git"
mv "$unsafe_pointer_common" "$fixture_repo/.git"
if [ "$unsafe_pointer_status" -eq 0 ]; then
    permission_boundary_failures=$((permission_boundary_failures + 1))
fi

if [ "$permission_boundary_failures" -eq 0 ]; then
    pass "unsafe execution and write modes fail before fleet mutation"
else
    fail "$permission_boundary_failures unsafe permission cases were accepted"
fi

info "all destinations are validated before any hook is replaced"
write_valid_inventory
reset_destinations
external_hook="$fixture_root/external-hook"
printf '%s\n' 'external sentinel' > "$external_hook"
ln -s "$external_hook" \
    "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
mkdir "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"
run_propagator ok
if [ "$propagator_status" -ne 0 ] \
    && [ -L "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ "$(cat "$external_hook")" = 'external sentinel' ] \
    && [ -d "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "symlink and nonregular destinations stop the batch before writes"
else
    fail "propagation followed or replaced an unsafe destination"
fi

info "an unmanaged regular hook stops the batch without overwriting bytes"
write_valid_inventory
reset_destinations
unmanaged_hook="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
unmanaged_copy="$fixture_root/unmanaged-pre-commit.expected"
printf '%s\n' '#!/usr/bin/env bash' 'echo unmanaged sentinel' > "$unmanaged_hook"
chmod 0700 "$unmanaged_hook"
cp "$unmanaged_hook" "$unmanaged_copy"
unmanaged_inode=$(inode_of "$unmanaged_hook")
run_propagator ok
if [ "$propagator_status" -ne 0 ] \
    && cmp -s "$unmanaged_copy" "$unmanaged_hook" \
    && [ "$(inode_of "$unmanaged_hook")" = "$unmanaged_inode" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ] \
    && grep -Fq 'refusing to overwrite an existing noncanonical hook' \
        "$fixture_root/stderr"; then
    pass "unmanaged regular hook bytes and inode are preserved"
else
    fail "propagation overwrote an unmanaged regular hook"
fi

info "oversized installed hooks stop before unbounded content reads"
write_valid_inventory
reset_destinations
oversized_hook="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
oversized_marker="$fixture_root/oversized-hook-read.marker"
"$real_python" - "$oversized_hook" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"x" * (1024 * 1024 + 1))
PY
chmod 0700 "$oversized_hook"
rm -f "$oversized_marker"
ODYSSEUS_TEST_READ_OBSERVER=1 \
ODYSSEUS_TEST_READ_OBSERVER_DRIVER="$fixture_bin/python-read-observer.py" \
ODYSSEUS_TEST_READ_OBSERVER_MARKER="$oversized_marker" \
ODYSSEUS_TEST_READ_OBSERVER_TARGET="$oversized_hook" \
    run_propagator ok
if [ "$propagator_status" -ne 0 ] \
    && [ ! -e "$oversized_marker" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ]; then
    pass "the per-hook byte cap is checked before hashing file contents"
else
    fail "an oversized hook was read beyond the per-file byte limit"
fi

info "a canonical-looking hard link is never accepted as an installed hook"
write_valid_inventory
reset_destinations
hardlink_victim="$fixture_root/hardlink-victim"
cp "$fixture_repo/.githooks/pre-commit" "$hardlink_victim"
chmod 0755 "$hardlink_victim"
hardlink_destination="$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"
ln "$hardlink_victim" "$hardlink_destination"
hardlink_fingerprint=$(fingerprint_of "$hardlink_victim")
run_propagator ok
hardlink_live_status=$propagator_status
hardlink_live_artifacts=$(temporary_artifact_count)
if [ -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ]; then
    hardlink_partial_write=1
else
    hardlink_partial_write=0
fi
cp "$fixture_repo/.githooks/pre-commit" \
    "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
chmod 0755 "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
run_propagator ok --verify
hardlink_verify_status=$propagator_status
if [ "$hardlink_live_status" -ne 0 ] \
    && [ "$hardlink_verify_status" -ne 0 ] \
    && [ "$hardlink_partial_write" -eq 0 ] \
    && [ "$hardlink_live_artifacts" -eq 0 ] \
    && [ "$(fingerprint_of "$hardlink_victim")" = "$hardlink_fingerprint" ] \
    && [ "$(fingerprint_of "$hardlink_destination")" = "$hardlink_fingerprint" ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" "$hardlink_victim"; then
    pass "hard-linked destinations fail closed without partial mutation"
else
    printf '%s\n' \
        "live=$hardlink_live_status verify=$hardlink_verify_status artifacts=$hardlink_live_artifacts" >&2
    fail "a hard-linked destination was accepted or mutated"
fi

info "a hard-linked source cannot become trusted hook evidence"
write_valid_inventory
reset_destinations
source_victim="$fixture_root/source-hardlink-victim"
cp "$fixture_repo/.githooks/pre-commit" "$source_victim"
chmod 0755 "$source_victim"
rm "$fixture_repo/.githooks/pre-commit"
ln "$source_victim" "$fixture_repo/.githooks/pre-commit"
source_fingerprint=$(fingerprint_of "$source_victim")
for hook_path in \
    "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; do
    cp "$source_victim" "$hook_path"
    chmod 0755 "$hook_path"
done
run_propagator ok --verify
source_hardlink_status=$propagator_status
if [ "$source_hardlink_status" -ne 0 ] \
    && [ "$(fingerprint_of "$source_victim")" = "$source_fingerprint" ] \
    && [ "$(fingerprint_of "$fixture_repo/.githooks/pre-commit")" = "$source_fingerprint" ]; then
    pass "source ownership and one-link identity are required"
else
    fail "a hard-linked source was accepted or changed"
fi
rm "$fixture_repo/.githooks/pre-commit"
cp "$source_victim" "$fixture_repo/.githooks/pre-commit"
chmod 0755 "$fixture_repo/.githooks/pre-commit"

info "an exact-byte source replacement after preflight is not trusted"
write_valid_inventory
reset_destinations
source_path="$fixture_repo/.githooks/pre-commit"
source_expected="$fixture_root/source-before-replacement"
cp "$source_path" "$source_expected"
source_inode=$(inode_of "$source_path")
source_swap_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_SOURCE_BEFORE_INSTALL=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$source_swap_destination" \
ODYSSEUS_TEST_SOURCE_DRIVER="$fixture_bin/python-source-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/source-swap.out" 2>&1
source_swap_status=$?
set -e
if [ "$source_swap_status" -ne 0 ] \
    && [ "$(inode_of "$source_path")" != "$source_inode" ] \
    && cmp -s "$source_expected" "$source_path" \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "the preflight source identity remains bound through publication"
else
    printf '%s\n' "source_swap_status=$source_swap_status" >&2
    cat "$fixture_root/source-swap.out" >&2
    fail "an exact-byte source replacement was accepted"
fi

info "an exact-byte source replacement after descriptor open is not trusted"
write_valid_inventory
reset_destinations
source_path="$fixture_repo/.githooks/pre-commit"
source_expected="$fixture_root/source-before-open-replacement"
cp "$source_path" "$source_expected"
source_inode=$(inode_of "$source_path")
source_open_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_SOURCE_AFTER_OPEN=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$source_open_destination" \
ODYSSEUS_TEST_SOURCE_OPEN_DRIVER="$fixture_bin/python-source-open-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/source-open-swap.out" 2>&1
source_open_swap_status=$?
set -e
if [ "$source_open_swap_status" -ne 0 ] \
    && [ "$(inode_of "$source_path")" != "$source_inode" ] \
    && cmp -s "$source_expected" "$source_path" \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "the source path must still name the bound source inode"
else
    printf '%s\n' "source_open_swap_status=$source_open_swap_status" >&2
    cat "$fixture_root/source-open-swap.out" >&2
    fail "a post-open exact-byte source replacement was accepted"
fi

info "a source-parent symlink swap after descriptor open is not trusted"
write_valid_inventory
reset_destinations
source_parent="$fixture_repo/.githooks"
source_parent_displaced="$source_parent.opened-parent"
source_parent_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_SOURCE_AFTER_OPEN=1 \
ODYSSEUS_TEST_SOURCE_SWAP_KIND=ancestor-symlink \
ODYSSEUS_TEST_TARGET_DESTINATION="$source_parent_destination" \
ODYSSEUS_TEST_SOURCE_OPEN_DRIVER="$fixture_bin/python-source-open-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/source-parent-swap.out" 2>&1
source_parent_swap_status=$?
set -e
if [ "$source_parent_swap_status" -ne 0 ] \
    && [ -L "$source_parent" ] \
    && [ "$(readlink "$source_parent")" = '.githooks.opened-parent' ] \
    && [ -f "$source_parent_displaced/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -e "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit" ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "the source parent must remain a direct bound directory"
else
    printf '%s\n' "source_parent_swap_status=$source_parent_swap_status" >&2
    cat "$fixture_root/source-parent-swap.out" >&2
    fail "a source-parent symlink replacement produced a hook write"
fi
rm -- "$source_parent"
mv -- "$source_parent_displaced" "$source_parent"

info "a parent replaced after preflight cannot redirect installation"
write_valid_inventory
reset_destinations
preinstall_parent="$fixture_repo/.git/modules/control/Alpha/hooks"
preinstall_displaced="$preinstall_parent.preflight-displaced"
preinstall_destination="$preinstall_parent/pre-commit"
preinstall_marker="$fixture_root/preinstall-marker"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_BEFORE_INSTALL=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$preinstall_destination" \
ODYSSEUS_TEST_PREINSTALL_MARKER="$preinstall_marker" \
ODYSSEUS_TEST_PREINSTALL_DRIVER="$fixture_bin/python-preinstall-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/preinstall-swap.out" 2>&1
preinstall_status=$?
set -e
preinstall_victim="$preinstall_parent/victim"
if [ "$preinstall_status" -ne 0 ] \
    && [ -f "$preinstall_victim" ] \
    && [ "$(cat "$preinstall_victim")" = 'pre-install replacement victim' ] \
    && [ ! -e "$preinstall_destination" ] \
    && [ ! -e "$preinstall_displaced/pre-commit" ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "the preflight parent receipt prevents redirected installation"
else
    printf '%s\n' "preinstall_status=$preinstall_status" >&2
    cat "$fixture_root/preinstall-swap.out" >&2
    fail "a post-preflight parent replacement received a hook"
fi

info "a malformed installer receipt cannot become completion evidence"
write_valid_inventory
reset_destinations
malformed_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_MALFORMED_RECEIPT=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$malformed_destination" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/malformed-receipt.out" 2>&1
malformed_receipt_status=$?
set -e
if [ "$malformed_receipt_status" -ne 0 ] \
    && [ ! -e "$malformed_destination" ] \
    && grep -Fq 'installer returned a malformed receipt' \
        "$fixture_root/malformed-receipt.out"; then
    pass "completion requires an exact installer receipt"
else
    cat "$fixture_root/malformed-receipt.out" >&2
    fail "a malformed installer receipt produced completion"
fi

info "a predictable legacy temporary-path symlink cannot redirect hook bytes"
write_valid_inventory
reset_destinations
ready="$fixture_root/status-ready"
release="$fixture_root/status-release"
external_temp_target="$fixture_root/temp-target"
printf '%s\n' 'temp sentinel' > "$external_temp_target"
: > "$git_log"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" \
ODYSSEUS_TEST_GIT_MODE=pause \
ODYSSEUS_TEST_REAL_GIT="$real_git" \
ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_READY="$ready" \
ODYSSEUS_TEST_RELEASE="$release" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/race-stdout" 2> "$fixture_root/race-stderr" &
race_pid=$!
set -e
for _ in $(seq 1 200); do
    [ -e "$ready" ] && break
    sleep 0.01
done
predicted_tmp="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit.tmp.$race_pid"
ln -s "$external_temp_target" "$predicted_tmp"
: > "$release"
set +e
wait "$race_pid"
race_status=$?
set -e
if [ "$race_status" -eq 0 ] \
    && [ "$(cat "$external_temp_target")" = 'temp sentinel' ] \
    && [ -f "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && [ ! -L "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"; then
    pass "publication does not use the predictable legacy staging path"
else
    fail "a predictable temporary file allowed redirected or incomplete publication"
fi

info "concurrent valid propagations leave exact regular hooks and no temp artifacts"
write_valid_inventory
reset_destinations
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/concurrent-one.out" 2>&1 &
pid_one=$!
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/concurrent-two.out" 2>&1 &
pid_two=$!
wait "$pid_one"
status_one=$?
wait "$pid_two"
status_two=$?
set -e
temp_count=$(temporary_artifact_count)
if [ "$status_one" -eq 0 ] && [ "$status_two" -eq 0 ] \
    && [ "$temp_count" -eq 0 ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "concurrent propagation converges to the exact source hook"
else
    printf '%s\n' "status_one=$status_one status_two=$status_two temp_count=$temp_count" >&2
    printf '%s\n' '--- concurrent-one.out ---' >&2
    cat "$fixture_root/concurrent-one.out" >&2
    printf '%s\n' '--- concurrent-two.out ---' >&2
    cat "$fixture_root/concurrent-two.out" >&2
    printf '%s\n' '--- destination state ---' >&2
    ls -li "$fixture_repo/.git/modules/control/Alpha/hooks" \
        "$fixture_repo/.git/modules/shared/Beta/hooks" >&2
    fail "concurrent propagation left stale or temporary files"
fi

info "a canonical concurrent winner is serialized at the publication boundary"
write_valid_inventory
reset_destinations
publication_ready="$fixture_root/publication-ready"
publication_release="$fixture_root/publication-release"
flock_marker="$fixture_root/flock-attempt"
first_status_file="$fixture_root/first-status"
second_status_file="$fixture_root/second-status"
concurrent_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
set +e
(
    ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
    ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_PUBLICATION_BARRIER=1 \
    ODYSSEUS_TEST_TARGET_DESTINATION="$concurrent_destination" \
    ODYSSEUS_TEST_PUBLICATION_READY="$publication_ready" \
    ODYSSEUS_TEST_PUBLICATION_RELEASE="$publication_release" \
    ODYSSEUS_TEST_PUBLICATION_DRIVER="$fixture_bin/python-publication-barrier.py" \
    PATH="$fixture_bin:$PATH" \
        "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
        > "$fixture_root/boundary-one.out" 2>&1
    printf '%s\n' "$?" > "$first_status_file"
) &
boundary_pid_one=$!
for _ in $(seq 1 1000); do
    if [ -e "$publication_ready" ] || [ -e "$first_status_file" ]; then
        break
    fi
    sleep 0.01
done
if [ -e "$publication_ready" ]; then
    (
        ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
        ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
        ODYSSEUS_TEST_FLOCK_OBSERVER=1 \
        ODYSSEUS_TEST_TARGET_DESTINATION="$concurrent_destination" \
        ODYSSEUS_TEST_FLOCK_MARKER="$flock_marker" \
        ODYSSEUS_TEST_FLOCK_DRIVER="$fixture_bin/python-flock-observer.py" \
        PATH="$fixture_bin:$PATH" \
            "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
            > "$fixture_root/boundary-two.out" 2>&1
        printf '%s\n' "$?" > "$second_status_file"
    ) &
    boundary_pid_two=$!
    for _ in $(seq 1 1000); do
        if [ -e "$flock_marker" ] || [ -e "$second_status_file" ]; then
            break
        fi
        sleep 0.01
    done
else
    boundary_pid_two=
fi
if [ -e "$flock_marker" ] && [ ! -e "$second_status_file" ]; then
    second_blocked=1
else
    second_blocked=0
fi
: > "$publication_release"
wait "$boundary_pid_one"
if [ -n "$boundary_pid_two" ]; then
    wait "$boundary_pid_two"
fi
set -e
boundary_status_one=missing
boundary_status_two=missing
[ -e "$first_status_file" ] && boundary_status_one=$(cat "$first_status_file")
[ -e "$second_status_file" ] && boundary_status_two=$(cat "$second_status_file")
if [ "$boundary_status_one" = 0 ] && [ "$boundary_status_two" = 0 ] \
    && [ "$second_blocked" -eq 1 ] \
    && [ "$(temporary_artifact_count)" -eq 0 ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "concurrent publishers serialize and converge without transient evidence"
else
    printf '%s\n' \
        "first=$boundary_status_one second=$boundary_status_two blocked=$second_blocked" >&2
    [ -e "$fixture_root/boundary-one.out" ] \
        && cat "$fixture_root/boundary-one.out" >&2
    [ -e "$fixture_root/boundary-two.out" ] \
        && cat "$fixture_root/boundary-two.out" >&2
    fail "a concurrent invocation escaped serialization or failed to converge"
fi

info "cleanup never unlinks a same-UID replacement of an owned staging leaf"
write_valid_inventory
reset_destinations
cleanup_victim="$fixture_root/cleanup-victim"
cleanup_marker="$fixture_root/cleanup-marker"
printf '%s\n' 'cleanup victim' > "$cleanup_victim"
cleanup_fingerprint=$(fingerprint_of "$cleanup_victim")
cleanup_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_CLEANUP_LEAF=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$cleanup_destination" \
ODYSSEUS_TEST_CLEANUP_VICTIM="$cleanup_victim" \
ODYSSEUS_TEST_CLEANUP_MARKER="$cleanup_marker" \
ODYSSEUS_TEST_CLEANUP_DRIVER="$fixture_bin/python-cleanup-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/cleanup-swap.out" 2>&1
cleanup_status=$?
set -e
if [ "$cleanup_status" -eq 0 ] \
    && [ -e "$cleanup_marker.entered" ] \
    && [ -f "$cleanup_victim" ] \
    && [ "$(fingerprint_of "$cleanup_victim")" = "$cleanup_fingerprint" ] \
    && [ "$(cat "$cleanup_victim")" = 'cleanup victim' ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "publication has no mutable staging leaf to clean up"
else
    printf '%s\n' "cleanup_status=$cleanup_status" >&2
    cat "$fixture_root/cleanup-swap.out" >&2
    fail "cleanup removed or changed a substituted victim"
fi

info "a valid replacement between destination inspection and open is accepted"
write_valid_inventory
reset_destinations
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_REPLACE_ON_DEST_OPEN=1 \
ODYSSEUS_TEST_PYTHON_DRIVER="$fixture_bin/python-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/controlled-replacement.out" 2>&1
controlled_status=$?
set -e
controlled_temp_count=$(find "$fixture_repo/.git/modules" -type f \
    \( -name '.pre-commit.*' -o -name '.test-valid.*' \) | wc -l | tr -d ' ')
if [ "$controlled_status" -eq 0 ] && [ "$controlled_temp_count" -eq 0 ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "a concurrent valid replacement cannot create a false failure"
else
    printf '%s\n' \
        "controlled_status=$controlled_status temp_count=$controlled_temp_count" >&2
    cat "$fixture_root/controlled-replacement.out" >&2
    fail "an exact concurrent replacement caused a false failure"
fi

info "a destination replaced after descriptor open cannot become success"
write_valid_inventory
reset_destinations
destination_open_target="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
destination_open_receipt="$fixture_root/destination-open-victim.receipt"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_DESTINATION_AFTER_OPEN=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$destination_open_target" \
ODYSSEUS_TEST_DESTINATION_OPEN_DRIVER="$fixture_bin/python-destination-open-driver.py" \
ODYSSEUS_TEST_DESTINATION_OPEN_RECEIPT="$destination_open_receipt" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/destination-open-swap.out" 2>&1
destination_open_status=$?
set -e
if [ "$destination_open_status" -ne 0 ] \
    && [ -f "$destination_open_target" ] \
    && [ "$(cat "$destination_open_target")" = 'post-open replacement victim' ] \
    && [ "$(fingerprint_of "$destination_open_target")" = "$(cat "$destination_open_receipt")" ] \
    && [ -f "$destination_open_target.opened-canonical" ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "readback rejects a destination path that changed after open"
else
    printf '%s\n' "destination_open_status=$destination_open_status" >&2
    cat "$fixture_root/destination-open-swap.out" >&2
    fail "a post-open destination replacement produced completion"
fi

info "an ancestor swap cannot redirect publication onto a replacement-path victim"
write_valid_inventory
reset_destinations
ancestor_victim="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
ancestor_receipt="$fixture_root/ancestor-victim.receipt"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_HOOK_PARENT=1 \
ODYSSEUS_TEST_TARGET_DESTINATION="$ancestor_victim" \
ODYSSEUS_TEST_ANCESTOR_DRIVER="$fixture_bin/python-ancestor-driver.py" \
ODYSSEUS_TEST_ANCESTOR_RECEIPT="$ancestor_receipt" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/ancestor-swap.out" 2>&1
ancestor_status=$?
set -e
if [ "$ancestor_status" -ne 0 ] \
    && [ -f "$ancestor_victim" ] \
    && [ "$(cat "$ancestor_victim")" = 'replacement-path victim' ] \
    && [ "$(fingerprint_of "$ancestor_victim")" = "$(cat "$ancestor_receipt")" ] \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "descriptor-bound publication preserves a replacement-path victim"
else
    printf '%s\n' "ancestor_status=$ancestor_status" >&2
    cat "$fixture_root/ancestor-swap.out" >&2
    if [ -e "$ancestor_victim" ]; then
        printf '%s\n' '--- replacement-path victim bytes ---' >&2
        cat "$ancestor_victim" >&2
    fi
    fail "ancestor replacement redirected hook publication onto a victim"
fi

info "an intermediate symlink swap cannot become completion"
write_valid_inventory
reset_destinations
intermediate_destination="$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit"
intermediate_ancestor="$fixture_repo/.git/modules/control/Alpha"
intermediate_displaced="$intermediate_ancestor.displaced"
set +e
ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
ODYSSEUS_TEST_SWAP_HOOK_PARENT=1 \
ODYSSEUS_TEST_ANCESTOR_KIND=intermediate-symlink \
ODYSSEUS_TEST_TARGET_DESTINATION="$intermediate_destination" \
ODYSSEUS_TEST_ANCESTOR_DRIVER="$fixture_bin/python-ancestor-driver.py" \
PATH="$fixture_bin:$PATH" \
    "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
    > "$fixture_root/intermediate-symlink-swap.out" 2>&1
intermediate_status=$?
set -e
if [ "$intermediate_status" -ne 0 ] \
    && [ -L "$intermediate_ancestor" ] \
    && [ "$(readlink "$intermediate_ancestor")" = 'Alpha.displaced' ] \
    && [ -f "$intermediate_displaced/hooks/pre-commit" ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$intermediate_displaced/hooks/pre-commit" \
    && [ "$(temporary_artifact_count)" -eq 0 ]; then
    pass "final parent validation rejects every symlinked path component"
else
    printf '%s\n' "intermediate_status=$intermediate_status" >&2
    cat "$fixture_root/intermediate-symlink-swap.out" >&2
    fail "an intermediate symlink was accepted as the current hook parent"
fi

info "concurrent propagations serialize a same-directory creation winner"
write_valid_inventory
reset_destinations
rm -r -- \
    "$fixture_repo/.git/modules/control/Alpha/hooks" \
    "$fixture_repo/.git/modules/shared/Beta/hooks"
hook_directory_ready="$fixture_root/hook-directory-ready"
hook_directory_release="$fixture_root/hook-directory-release"
hook_directory_flock="$fixture_root/hook-directory-flock"
hook_directory_first_status="$fixture_root/hook-directory-first-status"
hook_directory_second_status="$fixture_root/hook-directory-second-status"
hook_directory_module="$fixture_repo/.git/modules/control/Alpha"
set +e
( ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
    ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
    ODYSSEUS_TEST_HOOK_DIRECTORY_BARRIER=1 \
    ODYSSEUS_TEST_TARGET_MODULE="$hook_directory_module" \
    ODYSSEUS_TEST_HOOK_DIRECTORY_READY="$hook_directory_ready" \
    ODYSSEUS_TEST_HOOK_DIRECTORY_RELEASE="$hook_directory_release" \
    ODYSSEUS_TEST_HOOK_DIRECTORY_DRIVER="$fixture_bin/python-hooks-directory-barrier.py" \
    PATH="$fixture_bin:$PATH" \
        "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
        > "$fixture_root/concurrent-mkdir-one.out" 2>&1
    printf '%s\n' "$?" > "$hook_directory_first_status"
) &
mkdir_pid_one=$!
for _ in $(seq 1 1000); do
    if [ -e "$hook_directory_ready" ] || [ -e "$hook_directory_first_status" ]; then
        break
    fi
    sleep 0.01
done
if [ -e "$hook_directory_ready" ]; then
    ( ODYSSEUS_TEST_GIT_LOG="$git_log" ODYSSEUS_TEST_GIT_MODE=ok \
        ODYSSEUS_TEST_REAL_GIT="$real_git" ODYSSEUS_TEST_REAL_PYTHON="$real_python" \
        ODYSSEUS_TEST_HOOK_DIRECTORY_FLOCK_OBSERVER=1 \
        ODYSSEUS_TEST_TARGET_MODULE="$hook_directory_module" \
        ODYSSEUS_TEST_FLOCK_MARKER="$hook_directory_flock" \
        ODYSSEUS_TEST_FLOCK_DRIVER="$fixture_bin/python-flock-observer.py" \
        PATH="$fixture_bin:$PATH" \
            "$subject_bash" "$fixture_repo/tools/propagate-pre-commit-hooks.sh" \
            > "$fixture_root/concurrent-mkdir-two.out" 2>&1
        printf '%s\n' "$?" > "$hook_directory_second_status"
    ) &
    mkdir_pid_two=$!
    for _ in $(seq 1 1000); do
        if [ -e "$hook_directory_flock" ] \
            || [ -e "$hook_directory_second_status" ]; then
            break
        fi
        sleep 0.01
    done
else
    mkdir_pid_two=
fi
if [ -e "$hook_directory_flock" ] \
    && [ ! -e "$hook_directory_second_status" ]; then
    hook_directory_second_blocked=1
else
    hook_directory_second_blocked=0
fi
: > "$hook_directory_release"
wait "$mkdir_pid_one"
if [ -n "$mkdir_pid_two" ]; then
    wait "$mkdir_pid_two"
fi
set -e
mkdir_status_one=missing
mkdir_status_two=missing
[ -e "$hook_directory_first_status" ] \
    && mkdir_status_one=$(cat "$hook_directory_first_status")
[ -e "$hook_directory_second_status" ] \
    && mkdir_status_two=$(cat "$hook_directory_second_status")
if [ "$mkdir_status_one" = 0 ] && [ "$mkdir_status_two" = 0 ] \
    && [ "$hook_directory_second_blocked" -eq 1 ] \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/control/Alpha/hooks/pre-commit" \
    && cmp -s "$fixture_repo/.githooks/pre-commit" \
        "$fixture_repo/.git/modules/shared/Beta/hooks/pre-commit"; then
    pass "a concurrent directory-creation winner is accepted after validation"
else
    printf '%s\n' \
        "first=$mkdir_status_one second=$mkdir_status_two blocked=$hook_directory_second_blocked" >&2
    [ -e "$fixture_root/concurrent-mkdir-one.out" ] \
        && cat "$fixture_root/concurrent-mkdir-one.out" >&2
    [ -e "$fixture_root/concurrent-mkdir-two.out" ] \
        && cat "$fixture_root/concurrent-mkdir-two.out" >&2
    fail "a harmless concurrent hooks-directory creation caused a false failure"
fi

info "the suite trap preserves fatal status, incomplete execution, and cleanup failure"
set +e
ODYSSEUS_TEST_HARNESS_PROBE=fatal \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=1 \
    "$subject_bash" "$SCRIPT_DIR/test-propagate-pre-commit-hooks.sh" \
    > "$fixture_root/harness-fatal.out" 2>&1
harness_fatal_status=$?
ODYSSEUS_TEST_HARNESS_PROBE=incomplete \
    "$subject_bash" "$SCRIPT_DIR/test-propagate-pre-commit-hooks.sh" \
    > "$fixture_root/harness-incomplete.out" 2>&1
harness_incomplete_status=$?
ODYSSEUS_TEST_HARNESS_PROBE=complete \
ODYSSEUS_TEST_FORCE_CLEANUP_FAILURE=1 \
    "$subject_bash" "$SCRIPT_DIR/test-propagate-pre-commit-hooks.sh" \
    > "$fixture_root/harness-cleanup.out" 2>&1
harness_cleanup_status=$?
set -e
if [ "$harness_fatal_status" -eq 73 ] \
    && [ "$harness_incomplete_status" -eq 78 ] \
    && [ "$harness_cleanup_status" -eq 79 ] \
    && grep -Fq 'did not reach its completion marker' \
        "$fixture_root/harness-incomplete.out" \
    && grep -Fq 'controlled hook-propagation cleanup failure' \
        "$fixture_root/harness-fatal.out" \
    && grep -Fq 'controlled hook-propagation cleanup failure' \
        "$fixture_root/harness-cleanup.out"; then
    pass "only a completed suite with successful cleanup can exit zero"
else
    printf '%s\n' \
        "fatal=$harness_fatal_status incomplete=$harness_incomplete_status cleanup=$harness_cleanup_status" >&2
    fail "the suite trap converted an incomplete or cleanup-failed run to success"
fi

summary
suite_completed=1
exit_code
