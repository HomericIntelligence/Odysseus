#!/usr/bin/env bash
# tools/propagate-pre-commit-hooks.sh
#
# Propagates the meta-repo's `.githooks/pre-commit` banlist + 512 KiB +
# signing hook into every initialized submodule's default hooks directory
# (`.git/modules/<submodule>/hooks/pre-commit`).
#
# Why this script exists
# ----------------------
# The meta-repo's pre-commit hook (banlist patterns + 512 KiB large-file
# guard + remediation hints) is canonical for the meta-repo itself. But
# when a developer commits from INSIDE a submodule directory — e.g. to
# fix a bug in HomericIntelligence/Argus — git consults that
# submodule's OWN `core.hooksPath`. If the submodule repo doesn't set
# `core.hooksPath`, the default is the meta-repo-controlled directory
# `.git/modules/<submodule>/hooks/pre-commit`. This script copies the
# meta-repo hook into that default location so the same protections
# extend into submodule work WITHOUT requiring each submodule repo to
# set `core.hooksPath` (which would mean changes IN each submodule).
#
# Policy compliance with AGENTS.md
# ---------------------------------
# AGENTS.md states submodule WORKING TREES are read-only for meta-repo
# agents — changes belong in each submodule's own repo. This script
# writes only into the meta-repo's `.git/modules/<submodule>/hooks/`
# directory. That path lives in the META-REPO's `.git/` (not the
# submodule working tree), so the policy still applies — but the hook
# directory is meta-repo territory and IS safe to manage here.
# Submodule `core.hooksPath` is NOT set — if/when a submodule repo
# chooses its own hook layout, its setting takes precedence (correct
# behavior). The script does not modify any submodule's git config.
#
# Idempotency
# -----------
# Running twice is safe. An absent destination is installed atomically and an
# exact canonical destination is retained. Any other existing hook is
# preserved and requires explicit human disposition before replacement.
# The `--dry-run` mode shows what would change without writing.
# The `--verify` mode confirms each installed hook still matches the source.
#
# Uninitialized submodules
# ------------------------
# Submodules that haven't been `git submodule update --init`'d yet are reported
# as incomplete coverage. Live and verification modes stop before a partial
# fleet write or a successful fleet verdict.
#
# Usage
# -----
#   tools/propagate-pre-commit-hooks.sh            # live copy + verify
#   tools/propagate-pre-commit-hooks.sh --dry-run  # show what would happen
#   tools/propagate-pre-commit-hooks.sh --verify   # check post-install state
#   tools/propagate-pre-commit-hooks.sh --help     # show this help

set -euo pipefail

PATH=/usr/bin:/bin
export PATH
TRUSTED_PYTHON=/usr/bin/python3
TRUSTED_GIT=/usr/bin/git
TRUSTED_ENV=/usr/bin/env
MAX_TRUSTED_FILE_BYTES=1048576
MAX_SUBMODULES=256
GIT_CALL_TIMEOUT_SECONDS=20
GIT_MAX_OUTPUT_BYTES=1048576
TOTAL_OPERATION_TIMEOUT_SECONDS=120
GIT_RUNNER_TEST_ENV_KEYS=()
# shellcheck disable=SC2034  # Indirectly consumed through a nameref.
PYTHON_RUNNER_TEST_ENV_KEYS=()
if [ ! -x "$TRUSTED_PYTHON" ] || [ ! -x "$TRUSTED_GIT" ] \
    || [ ! -x "$TRUSTED_ENV" ]; then
    echo "ERROR: trusted Git or Python runtime is unavailable" >&2
    exit 2
fi

# Do not let diagnostics or dynamic-loader controls flow into later tools.
unset BASH_ENV ENV GIT_TRACE GIT_TRACE2 GIT_TRACE2_EVENT \
    GIT_TRACE2_PERF GIT_TRACE_CURL GIT_TRACE_PACKET GIT_TRACE_PACK_ACCESS \
    GIT_TRACE_SETUP GIT_TRACE_SHALLOW LD_PRELOAD LD_LIBRARY_PATH \
    LD_AUDIT LD_DEBUG LD_DEBUG_OUTPUT LD_PROFILE \
    DYLD_INSERT_LIBRARIES DYLD_LIBRARY_PATH DYLD_FRAMEWORK_PATH \
    DYLD_FALLBACK_LIBRARY_PATH DYLD_FALLBACK_FRAMEWORK_PATH DYLD_PRINT_TO_FILE

OPERATION_STARTED_SECONDS=$SECONDS

operation_remaining() {
    local elapsed
    elapsed=$((SECONDS - OPERATION_STARTED_SECONDS))
    OPERATION_REMAINING_SECONDS=$((TOTAL_OPERATION_TIMEOUT_SECONDS - elapsed))
    if [ "$OPERATION_REMAINING_SECONDS" -le 0 ]; then
        echo "ERROR: hook propagation operation deadline expired" >&2
        return 124
    fi
}

append_test_environment() {
    local destination_name="$1" keys_name="$2" key
    local -n destination="$destination_name"
    local -n keys="$keys_name"
    for key in "${keys[@]}"; do
        if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]] && [ -n "${!key+x}" ]; then
            destination+=("$key=${!key}")
        fi
    done
}

isolated_python() {
    local test_environment=()
    operation_remaining || return $?
    append_test_environment test_environment PYTHON_RUNNER_TEST_ENV_KEYS
    "$TRUSTED_ENV" -i HOME=/dev/null PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
        "${test_environment[@]}" "$TRUSTED_PYTHON" -I -S /dev/fd/3 \
        "$OPERATION_REMAINING_SECONDS" "$@" 3<<'PY'
import signal
import sys


class OperationDeadlineExpired(Exception):
    pass


def expire_operation(_signal_number, _frame):
    raise OperationDeadlineExpired


remaining = int(sys.argv[1])
arguments = sys.argv[2:]
if remaining < 1 or not arguments or arguments[0] != "-":
    raise SystemExit(2)
signal.signal(signal.SIGALRM, expire_operation)
signal.setitimer(signal.ITIMER_REAL, remaining)
program = sys.stdin.read()
sys.argv = arguments
namespace = {
    "__builtins__": __builtins__,
    "__file__": "<stdin>",
    "__name__": "__main__",
    "__package__": None,
}
try:
    exec(compile(program, "<stdin>", "exec"), namespace, namespace)
except OperationDeadlineExpired:
    print("ERROR: hook propagation operation deadline expired", file=sys.stderr)
    raise SystemExit(124)
finally:
    signal.setitimer(signal.ITIMER_REAL, 0)
PY
}

# Parse args
DRY_RUN=0
VERIFY_ONLY=0
for arg in "$@"; do
    case "$arg" in
        --dry-run)  DRY_RUN=1 ;;
        --verify)   VERIFY_ONLY=1 ;;
        --help|-h)
            # --help goes to STDERR by design: prevents accidental pollution of
            # `script --dry-run | tee propagation.log` pipelines where stdout is
            # the report. Users capturing help explicitly with `script --help
            # 2>&1 | less` still see it; terminals always show stderr.
            printf '%s\n' \
'Usage: tools/propagate-pre-commit-hooks.sh [--dry-run | --verify | --help]' \
'' \
'Propagates the meta-repo'\''s .githooks/pre-commit into each initialized' \
'submodule'\''s default hooks directory (.git/modules/<sub>/hooks/pre-commit).' \
'' \
'  (default)    live copy + per-submodule report to stdout' \
'  --dry-run    plan copy operations; no filesystem changes' \
'  --verify     check each installed hook matches source; exit 1 on stale' \
'  --help       print this help and exit 0' \
'' \
'Exit codes:' \
'  0   complete success (or help)' \
'  1   incomplete coverage, stale/absent verification, or live copy failure' \
'  2   argument error or missing source hook / .gitmodules' \
'' \
'See the file'\''s leading docstring (lines after the shebang) for the full' \
'rationale, idempotency notes, AGENTS.md policy compliance discussion,' \
'and uninitialized-submodule recovery steps.' >&2
            exit 0
            ;;
        *) echo "ERROR: unknown argument: $arg" >&2; exit 2 ;;
    esac
done
if [ "$DRY_RUN" -eq 1 ] && [ "$VERIFY_ONLY" -eq 1 ]; then
    echo "ERROR: --dry-run and --verify are mutually exclusive" >&2
    exit 2
fi

# Resolve meta-repo root (script lives in /tools/) only after the requested
# operation has been validated without consulting repository state.
script_parent="${BASH_SOURCE[0]%/*}"
[ "$script_parent" != "${BASH_SOURCE[0]}" ] || script_parent=.
SCRIPT_DIR="$(CDPATH='' cd -P -- "$script_parent" && pwd -P)"
META_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
SRC_HOOK="$META_ROOT/.githooks/pre-commit"

# Pre-flight. Both inputs must be direct regular files because these bytes and
# paths control writes inside the Git administration directory.
if [ ! -f "$SRC_HOOK" ] || [ -L "$SRC_HOOK" ]; then
    echo "ERROR: source hook is missing, nonregular, or a symlink: $SRC_HOOK" >&2
    exit 2
fi
GITMODULES="$META_ROOT/.gitmodules"
if [ ! -f "$GITMODULES" ] || [ -L "$GITMODULES" ]; then
    echo "ERROR: .gitmodules is missing, nonregular, or a symlink: $GITMODULES" >&2
    exit 2
fi

hash_direct_file() {
    isolated_python - "$1" "${2:-1}" \
        "$MAX_TRUSTED_FILE_BYTES" <<'PY'
import hashlib
import os
import stat
import sys

path = sys.argv[1]
require_owner_execute = sys.argv[2] == "1"
maximum_bytes = int(sys.argv[3])
descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_NOFOLLOW", 0))
try:
    metadata = os.fstat(descriptor)
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != os.geteuid()
        or metadata.st_nlink != 1
        or stat.S_IMODE(metadata.st_mode) & 0o022 != 0
        or (
            require_owner_execute
            and stat.S_IMODE(metadata.st_mode) & 0o100 == 0
        )
        or metadata.st_size > maximum_bytes
    ):
        raise SystemExit(1)
    digest = hashlib.sha256()
    bytes_read = 0
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        bytes_read += len(chunk)
        if bytes_read > maximum_bytes:
            raise SystemExit(1)
        digest.update(chunk)
    print(f"{digest.hexdigest()} {metadata.st_dev}:{metadata.st_ino}")
finally:
    os.close(descriptor)
PY
}

# Return the device/inode receipt for an owner-controlled direct directory.
# Every path component is opened relative to its already-bound parent.
directory_identity() {
    isolated_python - "$1" "$2" <<'PY'
import os
import stat
import sys

path = os.path.abspath(sys.argv[1])
trusted_root = os.path.abspath(sys.argv[2])
parts = [part for part in path.split(os.path.sep) if part]
trusted_parts = [part for part in trusted_root.split(os.path.sep) if part]
if parts[: len(trusted_parts)] != trusted_parts:
    raise SystemExit(1)
if not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW
descriptor = os.open(os.path.sep, flags)
try:
    for index, component in enumerate(parts):
        next_descriptor = os.open(component, flags, dir_fd=descriptor)
        os.close(descriptor)
        descriptor = next_descriptor
        value = os.fstat(descriptor)
        if index >= len(trusted_parts) - 1 and (
            not stat.S_ISDIR(value.st_mode)
            or value.st_uid != os.geteuid()
            or stat.S_IMODE(value.st_mode) & 0o022 != 0
        ):
            raise SystemExit(1)
    value = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(value.st_mode)
        or value.st_uid != os.geteuid()
        or stat.S_IMODE(value.st_mode) & 0o022 != 0
    ):
        raise SystemExit(1)
    print(f"{value.st_dev}:{value.st_ino}")
finally:
    os.close(descriptor)
PY
}

# Create or bind a direct hooks directory through the already-approved module
# directory. A concurrent canonical creator is accepted after validation.
ensure_hooks_directory() {
    isolated_python - "$1" "$2" "$3" <<'PY'
import fcntl
import os
import stat
import sys
import time

path, expected_identity, trusted_root = sys.argv[1:]
path = os.path.abspath(path)
trusted_root = os.path.abspath(trusted_root)
parts = [part for part in path.split(os.path.sep) if part]
trusted_parts = [part for part in trusted_root.split(os.path.sep) if part]
if parts[: len(trusted_parts)] != trusted_parts:
    raise SystemExit(1)
if not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit(1)
flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW
descriptor = os.open(os.path.sep, flags)
try:
    for index, component in enumerate(parts):
        next_descriptor = os.open(component, flags, dir_fd=descriptor)
        os.close(descriptor)
        descriptor = next_descriptor
        value = os.fstat(descriptor)
        if index >= len(trusted_parts) - 1 and (
            not stat.S_ISDIR(value.st_mode)
            or value.st_uid != os.geteuid()
            or stat.S_IMODE(value.st_mode) & 0o022 != 0
        ):
            raise SystemExit(1)
    module_state = os.fstat(descriptor)
    if (
        not stat.S_ISDIR(module_state.st_mode)
        or module_state.st_uid != os.geteuid()
        or stat.S_IMODE(module_state.st_mode) & 0o022 != 0
        or f"{module_state.st_dev}:{module_state.st_ino}" != expected_identity
    ):
        raise SystemExit(1)
    for _ in range(200):
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            time.sleep(0.01)
    else:
        raise SystemExit(1)
    try:
        hooks_state = os.stat("hooks", dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        try:
            os.mkdir("hooks", 0o755, dir_fd=descriptor)
        except FileExistsError:
            pass
        hooks_state = os.stat("hooks", dir_fd=descriptor, follow_symlinks=False)
        os.fsync(descriptor)
    if (
        not stat.S_ISDIR(hooks_state.st_mode)
        or stat.S_ISLNK(hooks_state.st_mode)
        or hooks_state.st_uid != os.geteuid()
        or stat.S_IMODE(hooks_state.st_mode) & 0o022 != 0
    ):
        raise SystemExit(1)
    current_descriptor = os.open(os.path.sep, flags)
    try:
        for index, component in enumerate(parts):
            next_descriptor = os.open(component, flags, dir_fd=current_descriptor)
            os.close(current_descriptor)
            current_descriptor = next_descriptor
            current_component = os.fstat(current_descriptor)
            if index >= len(trusted_parts) - 1 and (
                not stat.S_ISDIR(current_component.st_mode)
                or current_component.st_uid != os.geteuid()
                or stat.S_IMODE(current_component.st_mode) & 0o022 != 0
            ):
                raise SystemExit(1)
        current_module = os.fstat(current_descriptor)
        if (
            not stat.S_ISDIR(current_module.st_mode)
            or current_module.st_dev != module_state.st_dev
            or current_module.st_ino != module_state.st_ino
        ):
            raise SystemExit(1)
    finally:
        os.close(current_descriptor)
    print(f"{hooks_state.st_dev}:{hooks_state.st_ino}")
finally:
    os.close(descriptor)
PY
}

# Print "present" or "missing" for a relative directory below a direct base.
# A symlink or non-directory component is an error, not an absent module.
classify_direct_directory() {
    isolated_python - "$1" "$2" <<'PY'
import os
import stat
import sys

base, relative = sys.argv[1:]
current = base
parts = [part for part in relative.split("/") if part]
try:
    base_state = os.lstat(base)
except FileNotFoundError:
    print("missing")
    raise SystemExit(0)
if stat.S_ISLNK(base_state.st_mode) or not stat.S_ISDIR(base_state.st_mode):
    raise SystemExit(1)
for part in parts:
    current = os.path.join(current, part)
    try:
        state = os.lstat(current)
    except FileNotFoundError:
        print("missing")
        raise SystemExit(0)
    if stat.S_ISLNK(state.st_mode) or not stat.S_ISDIR(state.st_mode):
        raise SystemExit(1)
print("present")
PY
}

# Classify an initialized checkout without asking Git to reopen .gitmodules.
# The checkout's direct .git file must point at the already-selected module
# administration directory. Missing checkout state is reported as incomplete;
# malformed, redirected, or weakly controlled state is an error.
classify_initialized_checkout() {
    isolated_python - "$META_ROOT" "$1" "$2" <<'PY'
import os
import stat
import sys


root, relative, expected_gitdir = sys.argv[1:]
root = os.path.abspath(root)
expected_gitdir = os.path.abspath(expected_gitdir)
parts = relative.split("/")
if (
    not hasattr(os, "O_NOFOLLOW")
    or not parts
    or any(part in {"", ".", ".."} for part in parts)
):
    raise SystemExit(1)

directory_flags = (
    os.O_RDONLY
    | getattr(os, "O_DIRECTORY", 0)
    | os.O_NOFOLLOW
    | getattr(os, "O_CLOEXEC", 0)
)
read_flags = (
    os.O_RDONLY
    | os.O_NOFOLLOW
    | getattr(os, "O_CLOEXEC", 0)
    | getattr(os, "O_NONBLOCK", 0)
)


def safe_directory(value):
    return (
        stat.S_ISDIR(value.st_mode)
        and value.st_uid == os.geteuid()
        and stat.S_IMODE(value.st_mode) & 0o022 == 0
    )


def file_state(value):
    return (
        value.st_dev,
        value.st_ino,
        value.st_mode,
        value.st_uid,
        value.st_gid,
        value.st_nlink,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


root_descriptor = os.open(root, directory_flags)
try:
    if not safe_directory(os.fstat(root_descriptor)):
        raise OSError("unsafe repository root")
    checkout_descriptor = os.dup(root_descriptor)
    try:
        for component in parts:
            try:
                next_descriptor = os.open(
                    component,
                    directory_flags,
                    dir_fd=checkout_descriptor,
                )
            except FileNotFoundError:
                print("missing")
                raise SystemExit(0)
            os.close(checkout_descriptor)
            checkout_descriptor = next_descriptor
            if not safe_directory(os.fstat(checkout_descriptor)):
                raise OSError("unsafe checkout directory")

        try:
            named = os.lstat(".git", dir_fd=checkout_descriptor)
        except FileNotFoundError:
            print("missing")
            raise SystemExit(0)
        if (
            not stat.S_ISREG(named.st_mode)
            or named.st_uid != os.geteuid()
            or named.st_nlink != 1
            or stat.S_IMODE(named.st_mode) & 0o022
            or named.st_size > 4096
        ):
            raise OSError("unsafe checkout Git pointer")
        descriptor = os.open(
            ".git",
            read_flags,
            dir_fd=checkout_descriptor,
        )
        try:
            opened = os.fstat(descriptor)
            if file_state(opened) != file_state(named) \
                    or not stat.S_ISREG(opened.st_mode):
                raise OSError("checkout Git pointer changed while opened")
            chunks = []
            total = 0
            while True:
                chunk = os.read(descriptor, 4096)
                if not chunk:
                    break
                total += len(chunk)
                if total > 4096:
                    raise OSError("checkout Git pointer exceeds its byte limit")
                chunks.append(chunk)
            final = os.fstat(descriptor)
            rebound = os.lstat(".git", dir_fd=checkout_descriptor)
            if file_state(final) != file_state(opened) \
                    or file_state(rebound) != file_state(opened):
                raise OSError("checkout Git pointer changed while read")
        finally:
            os.close(descriptor)
    finally:
        os.close(checkout_descriptor)
finally:
    os.close(root_descriptor)

try:
    pointer = b"".join(chunks).decode("utf-8")
except UnicodeDecodeError as error:
    raise OSError("checkout Git pointer is not UTF-8") from error
lines = pointer.splitlines()
if len(lines) != 1 or not lines[0].startswith("gitdir: "):
    raise OSError("malformed checkout Git pointer")
target = lines[0][len("gitdir: "):]
if not target or "\x00" in target:
    raise OSError("malformed checkout Git pointer")
checkout_path = os.path.join(root, *parts)
if not os.path.isabs(target):
    target = os.path.join(checkout_path, target)
target = os.path.abspath(target)
if target != expected_gitdir:
    raise OSError("checkout Git pointer targets another repository")

expected_descriptor = os.open(expected_gitdir, directory_flags)
try:
    if not safe_directory(os.fstat(expected_descriptor)):
        raise OSError("unsafe module administration directory")
finally:
    os.close(expected_descriptor)
print("present")
PY
}

file_mode() {
    isolated_python - "$1" <<'PY'
import os
import stat
import sys
value = os.lstat(sys.argv[1])
if stat.S_ISLNK(value.st_mode) or not stat.S_ISREG(value.st_mode):
    raise SystemExit(1)
if (
    value.st_uid != os.geteuid()
    or stat.S_IMODE(value.st_mode) & 0o022 != 0
    or stat.S_IMODE(value.st_mode) & 0o100 == 0
):
    raise SystemExit(1)
print(format(stat.S_IMODE(value.st_mode), "o"))
PY
}

verify_hook() {
    isolated_python - "$SRC_HOOK" "$1" "$SRC_HASH" "$SRC_IDENTITY" \
        "${2:-}" "$META_ROOT" "$GIT_ADMIN" "$MAX_TRUSTED_FILE_BYTES" <<'PY'
import hashlib
import os
import stat
import sys

(
    source,
    destination,
    expected_hash,
    expected_source,
    expected_parent,
    source_root,
    destination_root,
    maximum_bytes,
) = sys.argv[1:]
maximum_bytes = int(maximum_bytes)
source_parent = os.path.dirname(source)
source_name = os.path.basename(source)
parent = os.path.dirname(destination)
destination_name = os.path.basename(destination)

if (
    not os.path.isabs(destination)
    or not destination_name
    or not hasattr(os, "O_NOFOLLOW")
):
    raise SystemExit(1)


def open_bound_directory(path, trusted_root, expected_identity=None):
    path = os.path.abspath(path)
    root = os.path.abspath(trusted_root)
    parts = [part for part in path.split(os.path.sep) if part]
    trusted_parts = [part for part in root.split(os.path.sep) if part]
    if parts[: len(trusted_parts)] != trusted_parts:
        raise SystemExit(1)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW
    descriptor = os.open(os.path.sep, flags)
    try:
        for index, component in enumerate(parts):
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            component_state = os.fstat(descriptor)
            if index >= len(trusted_parts) - 1 and (
                not stat.S_ISDIR(component_state.st_mode)
                or component_state.st_uid != os.geteuid()
                or stat.S_IMODE(component_state.st_mode) & 0o022 != 0
            ):
                raise SystemExit(1)
        value = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(value.st_mode)
            or value.st_uid != os.geteuid()
            or stat.S_IMODE(value.st_mode) & 0o022 != 0
        ):
            raise SystemExit(1)
        if expected_identity and f"{value.st_dev}:{value.st_ino}" != expected_identity:
            raise SystemExit(1)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def bound_directory_is_current(
    descriptor,
    path,
    trusted_root,
    expected_identity=None,
):
    try:
        current_descriptor = open_bound_directory(path, trusted_root, expected_identity)
    except (OSError, SystemExit):
        return False
    try:
        current_state = os.fstat(current_descriptor)
        descriptor_state = os.fstat(descriptor)
        return (
            current_state.st_dev == descriptor_state.st_dev
            and current_state.st_ino == descriptor_state.st_ino
        )
    finally:
        os.close(current_descriptor)


def same_file_state(left, right):
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
        left.st_uid,
        left.st_nlink,
        left.st_size,
        left.st_mtime_ns,
        left.st_ctime_ns,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
        right.st_uid,
        right.st_nlink,
        right.st_size,
        right.st_mtime_ns,
        right.st_ctime_ns,
    )


def read_direct(path, directory=None, require_owner_execute=False):
    descriptor = os.open(
        path,
        os.O_RDONLY | os.O_NOFOLLOW,
        dir_fd=directory,
    )
    try:
        state = os.fstat(descriptor)
        if (
            not stat.S_ISREG(state.st_mode)
            or state.st_uid != os.geteuid()
            or state.st_nlink != 1
            or state.st_size > maximum_bytes
            or stat.S_IMODE(state.st_mode) & 0o022 != 0
            or (
                require_owner_execute
                and stat.S_IMODE(state.st_mode) & 0o100 == 0
            )
        ):
            raise SystemExit(1)
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise SystemExit(1)
            digest.update(chunk)
        final_state = os.fstat(descriptor)
        current_state = os.stat(path, dir_fd=directory, follow_symlinks=False)
        if (
            not same_file_state(state, final_state)
            or not same_file_state(final_state, current_state)
        ):
            raise SystemExit(1)
        return digest.hexdigest(), final_state
    finally:
        os.close(descriptor)

source_parent_descriptor = open_bound_directory(source_parent, source_root)
try:
    source_hash, source_state = read_direct(source_name, source_parent_descriptor)
    if (
        source_hash != expected_hash
        or f"{source_state.st_dev}:{source_state.st_ino}" != expected_source
        or not bound_directory_is_current(
            source_parent_descriptor,
            source_parent,
            source_root,
        )
    ):
        raise SystemExit(1)
    parent_descriptor = open_bound_directory(
        parent,
        destination_root,
        expected_parent,
    )
    try:
        destination_hash, destination_state = read_direct(
            destination_name,
            parent_descriptor,
            True,
        )
        final_source_hash, final_source_state = read_direct(
            source_name,
            source_parent_descriptor,
        )
        if (
            destination_hash != expected_hash
            or final_source_hash != expected_hash
            or f"{final_source_state.st_dev}:{final_source_state.st_ino}"
            != expected_source
            or stat.S_IMODE(destination_state.st_mode) & 0o100 == 0
            or not bound_directory_is_current(
                parent_descriptor,
                parent,
                destination_root,
                expected_parent,
            )
            or not bound_directory_is_current(
                source_parent_descriptor,
                source_parent,
                source_root,
            )
        ):
            raise SystemExit(1)
        print(format(stat.S_IMODE(destination_state.st_mode), "o"))
    finally:
        os.close(parent_descriptor)
finally:
    os.close(source_parent_descriptor)
PY
}

# Install one hook from a bound source descriptor with an atomic, no-clobber
# platform primitive. Linux publishes an anonymous O_TMPFILE; Darwin clones
# an anonymous tmpfile containing the bound bytes. Neither path exposes a
# staging pathname or requires pathname cleanup.
install_hook() {
    isolated_python - "$SRC_HOOK" "$1" "$SRC_HASH" "$SRC_IDENTITY" "$2" \
        "$META_ROOT" "$GIT_ADMIN" "$MAX_TRUSTED_FILE_BYTES" <<'PY'
import ctypes
import errno
import fcntl
import hashlib
import os
import stat
import sys
import time

(
    source,
    destination,
    expected_hash,
    expected_source,
    expected_parent,
    source_root,
    destination_root,
    maximum_bytes,
) = sys.argv[1:]
maximum_bytes = int(maximum_bytes)
source_parent = os.path.dirname(source)
source_name = os.path.basename(source)
parent = os.path.dirname(destination)
destination_name = os.path.basename(destination)

if (
    not os.path.isabs(destination)
    or not destination_name
    or not expected_parent
    or not hasattr(os, "O_NOFOLLOW")
):
    raise SystemExit(1)


def open_bound_directory(path, trusted_root, expected_identity=None):
    path = os.path.abspath(path)
    root = os.path.abspath(trusted_root)
    parts = [part for part in path.split(os.path.sep) if part]
    trusted_parts = [part for part in root.split(os.path.sep) if part]
    if parts[: len(trusted_parts)] != trusted_parts:
        raise SystemExit(1)
    flags = os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW
    descriptor = os.open(os.path.sep, flags)
    try:
        for index, component in enumerate(parts):
            next_descriptor = os.open(component, flags, dir_fd=descriptor)
            os.close(descriptor)
            descriptor = next_descriptor
            component_state = os.fstat(descriptor)
            if index >= len(trusted_parts) - 1 and (
                not stat.S_ISDIR(component_state.st_mode)
                or component_state.st_uid != os.geteuid()
                or stat.S_IMODE(component_state.st_mode) & 0o022 != 0
            ):
                raise SystemExit(1)
        value = os.fstat(descriptor)
        if (
            not stat.S_ISDIR(value.st_mode)
            or value.st_uid != os.geteuid()
            or stat.S_IMODE(value.st_mode) & 0o022 != 0
            or (
                expected_identity
                and f"{value.st_dev}:{value.st_ino}" != expected_identity
            )
        ):
            raise SystemExit(1)
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def bound_directory_is_current(
    descriptor,
    path,
    trusted_root,
    expected_identity=None,
):
    try:
        current_descriptor = open_bound_directory(path, trusted_root, expected_identity)
    except (OSError, SystemExit):
        return False
    try:
        current_state = os.fstat(current_descriptor)
        descriptor_state = os.fstat(descriptor)
        return (
            current_state.st_dev == descriptor_state.st_dev
            and current_state.st_ino == descriptor_state.st_ino
        )
    finally:
        os.close(current_descriptor)


def snapshot_at(descriptor, name):
    try:
        value = os.stat(name, dir_fd=descriptor, follow_symlinks=False)
    except FileNotFoundError:
        return None
    if (
        stat.S_ISLNK(value.st_mode)
        or not stat.S_ISREG(value.st_mode)
        or value.st_uid != os.geteuid()
        or value.st_nlink != 1
        or value.st_size > maximum_bytes
        or stat.S_IMODE(value.st_mode) & 0o022 != 0
        or stat.S_IMODE(value.st_mode) & 0o100 == 0
    ):
        raise SystemExit(1)
    return value


def same_file_state(left, right):
    return (
        left.st_dev,
        left.st_ino,
        left.st_mode,
        left.st_uid,
        left.st_nlink,
        left.st_size,
        left.st_mtime_ns,
        left.st_ctime_ns,
    ) == (
        right.st_dev,
        right.st_ino,
        right.st_mode,
        right.st_uid,
        right.st_nlink,
        right.st_size,
        right.st_mtime_ns,
        right.st_ctime_ns,
    )


def read_descriptor(descriptor, current_directory, current_name):
    value = os.fstat(descriptor)
    if (
        not stat.S_ISREG(value.st_mode)
        or value.st_uid != os.geteuid()
        or value.st_nlink != 1
        or value.st_size > maximum_bytes
        or stat.S_IMODE(value.st_mode) & 0o022 != 0
    ):
        raise SystemExit(1)
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    digest = hashlib.sha256()
    total = 0
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            break
        total += len(chunk)
        if total > maximum_bytes:
            raise SystemExit(1)
        chunks.append(chunk)
        digest.update(chunk)
    final_value = os.fstat(descriptor)
    current_value = os.stat(
        current_name,
        dir_fd=current_directory,
        follow_symlinks=False,
    )
    if (
        not same_file_state(value, final_value)
        or not same_file_state(final_value, current_value)
    ):
        raise SystemExit(1)
    return b"".join(chunks), digest.hexdigest(), final_value


def read_at(directory, name, expected=None):
    descriptor = os.open(
        name,
        os.O_RDONLY | os.O_NOFOLLOW,
        dir_fd=directory,
    )
    try:
        value = os.fstat(descriptor)
        if (
            not stat.S_ISREG(value.st_mode)
            or value.st_uid != os.geteuid()
            or value.st_nlink != 1
            or value.st_size > maximum_bytes
            or stat.S_IMODE(value.st_mode) & 0o022 != 0
            or stat.S_IMODE(value.st_mode) & 0o100 == 0
        ):
            raise SystemExit(1)
        if expected is not None and (
            value.st_dev != expected.st_dev or value.st_ino != expected.st_ino
        ):
            raise SystemExit(1)
        digest = hashlib.sha256()
        total = 0
        while True:
            chunk = os.read(descriptor, 1024 * 1024)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise SystemExit(1)
            digest.update(chunk)
        final_value = os.fstat(descriptor)
        current_value = os.stat(name, dir_fd=directory, follow_symlinks=False)
        if (
            not same_file_state(value, final_value)
            or not same_file_state(final_value, current_value)
        ):
            raise SystemExit(1)
        return digest.hexdigest(), final_value
    finally:
        os.close(descriptor)


source_parent_descriptor = open_bound_directory(source_parent, source_root)
source_descriptor = os.open(
    source_name,
    os.O_RDONLY | os.O_NOFOLLOW,
    dir_fd=source_parent_descriptor,
)
parent_descriptor = -1
anonymous_descriptor = -1
anonymous_stream = None
try:
    source_bytes, source_hash, source_state = read_descriptor(
        source_descriptor,
        source_parent_descriptor,
        source_name,
    )
    if (
        source_hash != expected_hash
        or f"{source_state.st_dev}:{source_state.st_ino}" != expected_source
        or not bound_directory_is_current(
            source_parent_descriptor,
            source_parent,
            source_root,
        )
    ):
        raise SystemExit(1)

    parent_descriptor = open_bound_directory(
        parent,
        destination_root,
        expected_parent,
    )
    for _ in range(200):
        try:
            fcntl.flock(parent_descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            break
        except BlockingIOError:
            time.sleep(0.01)
    else:
        raise SystemExit(1)
    initial = snapshot_at(parent_descriptor, destination_name)
    if initial is not None:
        initial_hash, initial_state = read_at(
            parent_descriptor,
            destination_name,
            initial,
        )
        if (
            initial_hash != expected_hash
            or stat.S_IMODE(initial_state.st_mode) & 0o100 == 0
            or not bound_directory_is_current(
                parent_descriptor,
                parent,
                destination_root,
                expected_parent,
            )
        ):
            raise SystemExit(1)
        _, final_source_hash, final_source_state = read_descriptor(
            source_descriptor,
            source_parent_descriptor,
            source_name,
        )
        if (
            final_source_hash != expected_hash
            or f"{final_source_state.st_dev}:{final_source_state.st_ino}"
            != expected_source
            or not bound_directory_is_current(
                source_parent_descriptor,
                source_parent,
                source_root,
            )
        ):
            raise SystemExit(1)
        print(f"retained {format(stat.S_IMODE(initial_state.st_mode), 'o')}")
        raise SystemExit(0)

    # Revalidate both trusted inputs at the last pre-effect boundary.
    _, current_source_hash, current_source_state = read_descriptor(
        source_descriptor,
        source_parent_descriptor,
        source_name,
    )
    if (
        current_source_hash != expected_hash
        or current_source_state.st_dev != source_state.st_dev
        or current_source_state.st_ino != source_state.st_ino
        or not bound_directory_is_current(
            parent_descriptor,
            parent,
            destination_root,
            expected_parent,
        )
        or not bound_directory_is_current(
            source_parent_descriptor,
            source_parent,
            source_root,
        )
    ):
        raise SystemExit(1)

    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform == "darwin":
        # Darwin has no O_TMPFILE. C tmpfile(3) supplies an already-unlinked
        # regular file, so exact validated bytes can be cloned without ever
        # exposing a cleanup pathname.
        libc.tmpfile.argtypes = []
        libc.tmpfile.restype = ctypes.c_void_p
        libc.fileno.argtypes = [ctypes.c_void_p]
        libc.fileno.restype = ctypes.c_int
        anonymous_stream = libc.tmpfile()
        if not anonymous_stream:
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number))
        anonymous_descriptor = libc.fileno(anonymous_stream)
        if anonymous_descriptor < 0:
            error_number = ctypes.get_errno()
            raise OSError(error_number, os.strerror(error_number))
        os.fchmod(anonymous_descriptor, 0o755)
        offset = 0
        while offset < len(source_bytes):
            written = os.write(anonymous_descriptor, source_bytes[offset:])
            if written <= 0:
                raise SystemExit(1)
            offset += written
        os.fsync(anonymous_descriptor)
        anonymous_state = os.fstat(anonymous_descriptor)
        if (
            not stat.S_ISREG(anonymous_state.st_mode)
            or anonymous_state.st_uid != os.geteuid()
            or anonymous_state.st_nlink != 0
        ):
            raise SystemExit(1)
        publish = libc.fclonefileat
        publish.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
        publish.restype = ctypes.c_int
        result = publish(
            anonymous_descriptor,
            parent_descriptor,
            os.fsencode(destination_name),
            0,
        )
    elif sys.platform.startswith("linux") and hasattr(os, "O_TMPFILE"):
        anonymous_descriptor = os.open(
            ".",
            os.O_RDWR | os.O_TMPFILE,
            0o755,
            dir_fd=parent_descriptor,
        )
        os.fchmod(anonymous_descriptor, 0o755)
        offset = 0
        while offset < len(source_bytes):
            written = os.write(anonymous_descriptor, source_bytes[offset:])
            if written <= 0:
                raise SystemExit(1)
            offset += written
        os.fsync(anonymous_descriptor)
        anonymous_state = os.fstat(anonymous_descriptor)
        if (
            not stat.S_ISREG(anonymous_state.st_mode)
            or anonymous_state.st_uid != os.geteuid()
            or anonymous_state.st_nlink != 0
            or stat.S_IMODE(anonymous_state.st_mode) & 0o022 != 0
            or stat.S_IMODE(anonymous_state.st_mode) & 0o100 == 0
        ):
            raise SystemExit(1)
        publish = libc.linkat
        publish.argtypes = [
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
            ctypes.c_char_p,
            ctypes.c_int,
        ]
        publish.restype = ctypes.c_int
        # Linux AT_EMPTY_PATH publishes the already-bound anonymous inode.
        result = publish(
            anonymous_descriptor,
            b"",
            parent_descriptor,
            os.fsencode(destination_name),
            0x1000,
        )
        if result != 0 and ctypes.get_errno() in {errno.EPERM, errno.EACCES}:
            # AT_EMPTY_PATH normally requires CAP_DAC_READ_SEARCH. Preserve the
            # already-bound anonymous descriptor while publishing as an
            # ordinary user through procfs' descriptor symlink.
            ctypes.set_errno(0)
            result = publish(
                getattr(os, "AT_FDCWD", -100),
                os.fsencode(f"/proc/self/fd/{anonymous_descriptor}"),
                parent_descriptor,
                os.fsencode(destination_name),
                0x400,
            )
    else:
        raise SystemExit(1)

    published = result == 0
    if not published:
        error_number = ctypes.get_errno()
        if error_number != errno.EEXIST:
            raise OSError(error_number, os.strerror(error_number))
    os.fsync(parent_descriptor)

    if not bound_directory_is_current(
        parent_descriptor,
        parent,
        destination_root,
        expected_parent,
    ):
        raise SystemExit(1)
    final = snapshot_at(parent_descriptor, destination_name)
    if final is None:
        raise SystemExit(1)
    # Accept a concurrent canonical replacement only after binding and reading
    # the complete direct regular file at the final verification boundary.
    final_hash, final_state = read_at(parent_descriptor, destination_name)
    if (
        final_hash != expected_hash
        or stat.S_IMODE(final_state.st_mode) & 0o100 == 0
    ):
        raise SystemExit(1)
    _, final_source_hash, final_source_state = read_descriptor(
        source_descriptor,
        source_parent_descriptor,
        source_name,
    )
    if (
        final_source_hash != expected_hash
        or f"{final_source_state.st_dev}:{final_source_state.st_ino}"
        != expected_source
        or not bound_directory_is_current(
            source_parent_descriptor,
            source_parent,
            source_root,
        )
        or not bound_directory_is_current(
            parent_descriptor,
            parent,
            destination_root,
            expected_parent,
        )
    ):
        raise SystemExit(1)
    outcome = "installed" if published else "retained"
    print(f"{outcome} {format(stat.S_IMODE(final_state.st_mode), 'o')}")
finally:
    if anonymous_stream is not None:
        libc.fclose.argtypes = [ctypes.c_void_p]
        libc.fclose.restype = ctypes.c_int
        libc.fclose(anonymous_stream)
    elif anonymous_descriptor >= 0:
        os.close(anonymous_descriptor)
    if parent_descriptor >= 0:
        os.close(parent_descriptor)
    os.close(source_descriptor)
    os.close(source_parent_descriptor)
PY
}

contains_value() {
    local needle="$1" item
    shift
    for item in "$@"; do
        if [ "$item" = "$needle" ]; then
            return 0
        fi
    done
    return 1
}

git_clean() {
    local elapsed remaining key test_keys="" deadline_kind=operation
    local test_environment=()
    elapsed=$((SECONDS - OPERATION_STARTED_SECONDS))
    remaining=$((TOTAL_OPERATION_TIMEOUT_SECONDS - elapsed))
    if [ "$remaining" -le 0 ]; then
        echo "ERROR: hook propagation operation deadline expired" >&2
        return 124
    fi
    if [ "$remaining" -ge "$GIT_CALL_TIMEOUT_SECONDS" ]; then
        remaining=$GIT_CALL_TIMEOUT_SECONDS
        deadline_kind=call
    fi
    append_test_environment test_environment GIT_RUNNER_TEST_ENV_KEYS
    append_test_environment test_environment PYTHON_RUNNER_TEST_ENV_KEYS
    for key in "${GIT_RUNNER_TEST_ENV_KEYS[@]}"; do
        if [[ "$key" =~ ^[A-Z][A-Z0-9_]*$ ]]; then
            test_keys="${test_keys}${test_keys:+,}${key}"
        fi
    done
    "$TRUSTED_ENV" -i HOME=/dev/null PATH=/usr/bin:/bin LC_ALL=C TZ=UTC \
        "${test_environment[@]}" "$TRUSTED_PYTHON" -I -S - \
        "$remaining" "$GIT_MAX_OUTPUT_BYTES" "$deadline_kind" "$test_keys" \
        "$TRUSTED_GIT" "$@" <<'PY'
import os
import selectors
import signal
import subprocess
import sys
import time


timeout = int(sys.argv[1])
output_limit = int(sys.argv[2])
deadline_kind = sys.argv[3]
test_keys = tuple(filter(None, sys.argv[4].split(",")))
argv = sys.argv[5:]
if timeout < 1 or output_limit < 1024 or not argv:
    raise SystemExit(2)

child_environment = {
    "GIT_CONFIG_COUNT": "0",
    "GIT_CONFIG_GLOBAL": "/dev/null",
    "GIT_CONFIG_NOSYSTEM": "1",
    "GIT_CONFIG_SYSTEM": "/dev/null",
    "GIT_NO_REPLACE_OBJECTS": "1",
    "GIT_OPTIONAL_LOCKS": "0",
    "GIT_TERMINAL_PROMPT": "0",
    "HOME": "/dev/null",
    "LC_ALL": "C",
    "PATH": "/usr/bin:/bin",
    "TZ": "UTC",
    "XDG_CONFIG_HOME": "/dev/null",
}
for key in test_keys:
    if key in os.environ:
        child_environment[key] = os.environ[key]

try:
    process = subprocess.Popen(
        argv,
        cwd="/",
        env=child_environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
except OSError as error:
    print(f"ERROR: could not start trusted Git: {error}", file=sys.stderr)
    raise SystemExit(127) from error
buffers = {"stdout": bytearray(), "stderr": bytearray()}
total = 0
deadline = time.monotonic() + timeout
failure = None
collection_error = None
cleanup_failure = None
final_status = None
selector = None


def leader_has_exited_without_reaping():
    if not hasattr(os, "waitid") or not hasattr(os, "WNOWAIT"):
        return False
    try:
        observed = os.waitid(
            os.P_PID,
            process.pid,
            os.WEXITED | os.WNOHANG | os.WNOWAIT,
        )
    except (ChildProcessError, OSError):
        return False
    return observed is not None


try:
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ, "stdout")
    selector.register(process.stderr, selectors.EVENT_READ, "stderr")
    while selector.get_map():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            failure = (
                "hook propagation operation deadline expired"
                if deadline_kind == "operation"
                else f"Git command timed out after {timeout}s"
            )
            break
        events = selector.select(remaining)
        if not events:
            failure = (
                "hook propagation operation deadline expired"
                if deadline_kind == "operation"
                else f"Git command timed out after {timeout}s"
            )
            break
        for key, _ in events:
            chunk = os.read(key.fileobj.fileno(), 65536)
            if not chunk:
                selector.unregister(key.fileobj)
                key.fileobj.close()
                continue
            total += len(chunk)
            if total > output_limit:
                failure = (
                    f"Git command exceeded the {output_limit}-byte output limit"
                )
                break
            buffers[key.data].extend(chunk)
        if failure is not None:
            break
    if failure is None:
        # Give a leader that has closed both pipes a brief chance to exit, but
        # do not wait/reap it: its PID must reserve the process-group ID until
        # TERM and KILL have both been attempted.
        grace = min(0.1, max(0.0, deadline - time.monotonic()))
        if grace:
            time.sleep(grace)
except BaseException as error:
    collection_error = error
finally:
    if selector is not None:
        try:
            selector.close()
        except BaseException as error:
            cleanup_failure = (
                f"could not close Git output selector: {error}"
            )
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        # Darwin reports EPERM for a process group containing only the
        # deliberately unreaped zombie leader. A non-reaping observation
        # distinguishes that state without releasing the PGID.
        if sys.platform != "darwin" or not leader_has_exited_without_reaping():
            cleanup_failure = f"could not terminate Git process group: {error}"
    except OSError as error:
        cleanup_failure = f"could not terminate Git process group: {error}"
    try:
        time.sleep(0.2)
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"Git termination grace was interrupted: {error}"
        )
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    except PermissionError as error:
        if sys.platform != "darwin" or not leader_has_exited_without_reaping():
            cleanup_failure = cleanup_failure or (
                f"could not kill Git process group: {error}"
            )
    except OSError as error:
        cleanup_failure = cleanup_failure or (
            f"could not kill Git process group: {error}"
        )
    try:
        final_status = process.wait(timeout=1)
    except subprocess.TimeoutExpired:
        cleanup_failure = cleanup_failure or "could not reap trusted Git"
        final_status = 125
    except BaseException as error:
        cleanup_failure = cleanup_failure or (
            f"could not reap trusted Git: {error}"
        )
        final_status = 125
    for stream in (process.stdout, process.stderr):
        if stream is not None and not stream.closed:
            try:
                stream.close()
            except BaseException as error:
                cleanup_failure = cleanup_failure or (
                    f"could not close Git output stream: {error}"
                )

if cleanup_failure is not None:
    print(f"ERROR: {cleanup_failure}", file=sys.stderr)
    raise SystemExit(125)
if collection_error is not None:
    print(
        "ERROR: Git output collection failed: "
        f"{type(collection_error).__name__}: {collection_error}",
        file=sys.stderr,
    )
    raise SystemExit(125)
if failure is None and final_status is not None and final_status < 0:
    failure = "Git command closed output before it terminated"
if failure is not None:
    print(f"ERROR: {failure}", file=sys.stderr)
    raise SystemExit(124)
sys.stdout.buffer.write(buffers["stdout"])
sys.stderr.buffer.write(buffers["stderr"])
raise SystemExit(final_status)
PY
}

load_inventory() {
    local inventory_rows kind path url
    if ! inventory_rows=$(isolated_python - "$GITMODULES" \
        "$MAX_TRUSTED_FILE_BYTES" "$MAX_SUBMODULES" <<'PY'
import configparser
import io
import os
import re
import stat
import sys


path = os.path.abspath(sys.argv[1])
maximum_bytes = int(sys.argv[2])
maximum_submodules = int(sys.argv[3])
if maximum_bytes < 1 or maximum_submodules < 1 or not hasattr(os, "O_NOFOLLOW"):
    raise SystemExit(2)
parent, name = os.path.split(path)
directory = os.open(
    parent,
    os.O_RDONLY | getattr(os, "O_DIRECTORY", 0) | os.O_NOFOLLOW,
)
try:
    named = os.lstat(name, dir_fd=directory)
    if (
        not stat.S_ISREG(named.st_mode)
        or named.st_uid != os.geteuid()
        or named.st_nlink != 1
        or stat.S_IMODE(named.st_mode) & 0o022
        or named.st_size > maximum_bytes
    ):
        raise OSError("untrusted canonical inventory")
    descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
    try:
        opened = os.fstat(descriptor)
        chunks = []
        total = 0
        while True:
            chunk = os.read(descriptor, 65536)
            if not chunk:
                break
            total += len(chunk)
            if total > maximum_bytes:
                raise OSError("canonical inventory exceeds its byte limit")
            chunks.append(chunk)
        final = os.fstat(descriptor)
        rebound = os.lstat(name, dir_fd=directory)
        fields = ("st_dev", "st_ino", "st_uid", "st_gid", "st_mode", "st_nlink", "st_size", "st_mtime_ns", "st_ctime_ns")
        if any(getattr(opened, field) != getattr(named, field) for field in fields) \
                or any(getattr(final, field) != getattr(opened, field) for field in fields) \
                or any(getattr(rebound, field) != getattr(opened, field) for field in fields):
            raise OSError("canonical inventory changed while read")
        content = b"".join(chunks)
    finally:
        os.close(descriptor)
finally:
    os.close(directory)

try:
    text = content.decode("utf-8")
except UnicodeDecodeError as error:
    raise ValueError("canonical inventory is not UTF-8") from error
parser = configparser.RawConfigParser(
    interpolation=None,
    strict=True,
    allow_no_value=False,
    empty_lines_in_values=False,
)
parser.optionxform = str.lower
try:
    parser.read_file(io.StringIO(text), source="retained .gitmodules bytes")
except configparser.Error as error:
    raise ValueError("malformed canonical inventory") from error
if parser.defaults() or not parser.sections() \
        or len(parser.sections()) > maximum_submodules:
    raise ValueError("empty or oversized canonical inventory")

section_pattern = re.compile(r'^submodule "([A-Za-z0-9._/-]+)"$')
path_pattern = re.compile(r'^[A-Za-z0-9._/-]+$')
seen_paths = set()
seen_urls = set()
rows = []
for section in parser.sections():
    match = section_pattern.fullmatch(section)
    if match is None:
        raise ValueError("unexpected canonical inventory section")
    values = dict(parser.items(section, raw=True))
    if set(values) != {"path", "url"}:
        raise ValueError("canonical inventory entry has unexpected keys")
    name = match.group(1)
    submodule_path = values["path"]
    url = values["url"]
    if (
        name != submodule_path
        or len(submodule_path.encode("utf-8")) > 512
        or path_pattern.fullmatch(submodule_path) is None
        or submodule_path.startswith("/")
        or submodule_path.endswith("/")
        or "//" in submodule_path
        or any(part in {"", ".", ".."} for part in submodule_path.split("/"))
        or submodule_path in seen_paths
    ):
        raise ValueError("duplicate or unsafe canonical submodule path")
    if (
        not url
        or len(url.encode("utf-8")) > 2048
        or any(character.isspace() or ord(character) < 32 or ord(character) == 127 for character in url)
        or url in seen_urls
    ):
        raise ValueError("duplicate or malformed canonical submodule URL")
    seen_paths.add(submodule_path)
    seen_urls.add(url)
    rows.append((submodule_path, url))

for submodule_path, url in rows:
    print(f"ROW\t{submodule_path}\t{url}")
PY
    ); then
        echo "ERROR: canonical submodule inventory is unavailable or unsafe" >&2
        return 2
    fi
    SM_PATHS=()
    while IFS=$'\t' read -r kind path url; do
        if [ "$kind" != ROW ] || [ -z "$path" ] || [ -z "$url" ]; then
            echo "ERROR: malformed retained submodule inventory" >&2
            return 2
        fi
        SM_PATHS+=("$path")
    done <<< "$inventory_rows"
    if [ "${#SM_PATHS[@]}" -eq 0 ] \
        || [ "${#SM_PATHS[@]}" -gt "$MAX_SUBMODULES" ]; then
        echo "ERROR: canonical submodule inventory is empty or oversized" >&2
        return 2
    fi
}

source_hook_parent="${SRC_HOOK%/*}"
if ! directory_identity "$META_ROOT" "$META_ROOT" >/dev/null \
    || ! directory_identity "$source_hook_parent" "$META_ROOT" >/dev/null; then
    echo "ERROR: repository or source-hook directory has unsafe permissions" >&2
    exit 2
fi
declare -a SM_PATHS=()
load_inventory
total=${#SM_PATHS[@]}

if [ -d "$META_ROOT/.git" ] && [ ! -L "$META_ROOT/.git" ]; then
    GIT_ADMIN="$META_ROOT/.git"
elif [ -f "$META_ROOT/.git" ] && [ ! -L "$META_ROOT/.git" ]; then
    if ! hash_direct_file "$META_ROOT/.git" 0 >/dev/null; then
        echo "ERROR: Git administration pointer is not an owner-controlled file" >&2
        exit 2
    fi
    if ! GIT_ADMIN=$(git_clean -C "$META_ROOT" rev-parse --path-format=absolute \
        --git-common-dir); then
        echo "ERROR: Git administration directory is unavailable" >&2
        exit 2
    fi
else
    echo "ERROR: Git administration entry is missing or unsafe" >&2
    exit 2
fi
if [ ! -d "$GIT_ADMIN" ] || [ -L "$GIT_ADMIN" ]; then
    echo "ERROR: Git administration directory is missing or unsafe" >&2
    exit 2
fi

if ! index_rows=$(git_clean -C "$META_ROOT" ls-files --stage -- \
    "${SM_PATHS[@]}"); then
    echo "ERROR: complete submodule index inventory is unavailable" >&2
    exit 2
fi
if [ -z "$index_rows" ]; then
    echo "ERROR: complete submodule index inventory is empty" >&2
    exit 2
fi

declare -a INDEX_PATHS=() INDEX_OIDS=() INDEX_STAGE_MASKS=()
while IFS=$'\t' read -r index_metadata index_path index_extra; do
    index_entry=-1
    [ -n "$index_metadata" ] || continue
    read -r index_mode index_oid index_stage metadata_extra \
        <<< "$index_metadata"
    if [ "$index_mode" != 160000 ] \
        || [[ ! "$index_stage" =~ ^[0-3]$ ]] \
        || [[ ! "$index_oid" =~ ^[0-9a-fA-F]{40,64}$ ]] \
        || [[ "$index_oid" =~ ^0+$ ]] \
        || [ -n "${metadata_extra:-}${index_extra:-}" ] \
        || ! contains_value "$index_path" "${SM_PATHS[@]}"; then
        echo "ERROR: malformed, duplicate, or unexpected submodule index entry" >&2
        exit 2
    fi
    for index in "${!INDEX_PATHS[@]}"; do
        if [ "${INDEX_PATHS[$index]}" = "$index_path" ]; then
            index_entry=$index
            break
        fi
    done
    if [ "$index_entry" -lt 0 ]; then
        INDEX_PATHS+=("$index_path")
        INDEX_OIDS+=("")
        INDEX_STAGE_MASKS+=(0)
        index_entry=$((${#INDEX_PATHS[@]} - 1))
    fi
    index_stage_bit=$((1 << index_stage))
    if (( INDEX_STAGE_MASKS[index_entry] & index_stage_bit )); then
        echo "ERROR: malformed, duplicate, or unexpected submodule index entry" >&2
        exit 2
    fi
    INDEX_STAGE_MASKS[index_entry]=$((
        INDEX_STAGE_MASKS[index_entry] | index_stage_bit
    ))
    if [ "$index_stage" -eq 0 ]; then
        INDEX_OIDS[index_entry]="$index_oid"
    fi
done <<< "$index_rows"
if [ "${#INDEX_PATHS[@]}" -ne "$total" ]; then
    echo "ERROR: submodule index inventory is partial: expected $total, read ${#INDEX_PATHS[@]}" >&2
    exit 2
fi
declare -a INDEX_CONFLICTS=()
for index in "${!INDEX_PATHS[@]}"; do
    case "${INDEX_STAGE_MASKS[$index]}" in
        1)
            [ -n "${INDEX_OIDS[$index]}" ] || {
                echo "ERROR: malformed canonical submodule index entry" >&2
                exit 2
            }
            INDEX_CONFLICTS+=(0)
            ;;
        6|10|12|14)
            [ -z "${INDEX_OIDS[$index]}" ] || {
                echo "ERROR: mixed resolved and unmerged submodule index entry" >&2
                exit 2
            }
            INDEX_CONFLICTS+=(1)
            ;;
        *)
            echo "ERROR: incomplete or mixed submodule index stages" >&2
            exit 2
            ;;
    esac
done
for sm_path in "${SM_PATHS[@]}"; do
    if ! contains_value "$sm_path" "${INDEX_PATHS[@]}"; then
        echo "ERROR: submodule index inventory omitted $sm_path" >&2
        exit 2
    fi
done

index_entry_for_path() {
    local lookup_path="$1" index
    INDEX_OID=
    INDEX_CONFLICT=0
    for index in "${!INDEX_PATHS[@]}"; do
        if [ "${INDEX_PATHS[$index]}" = "$lookup_path" ]; then
            INDEX_OID="${INDEX_OIDS[$index]}"
            INDEX_CONFLICT="${INDEX_CONFLICTS[$index]}"
            return 0
        fi
    done
    return 1
}

declare -a STATUS_PATHS=() STATUS_MARKER_VALUES=()
status_marker_for_path() {
    local lookup_path="$1" status_index
    STATUS_MARKER=
    for status_index in "${!STATUS_PATHS[@]}"; do
        if [ "${STATUS_PATHS[$status_index]}" = "$lookup_path" ]; then
            STATUS_MARKER="${STATUS_MARKER_VALUES[$status_index]}"
            return 0
        fi
    done
    return 1
}

if ! source_receipt=$(hash_direct_file "$SRC_HOOK" 0); then
    echo "ERROR: source hook could not be hashed safely" >&2
    exit 2
fi
read -r SRC_HASH SRC_IDENTITY <<< "$source_receipt"
if [[ ! "$SRC_HASH" =~ ^[0-9a-f]{64}$ \
    || ! "$SRC_IDENTITY" =~ ^[0-9]+:[0-9]+$ ]]; then
    echo "ERROR: source hook receipt is malformed" >&2
    exit 2
fi
TS=$(isolated_python - <<'PY'
import datetime

print(datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"))
PY
) || {
    echo "ERROR: propagation timestamp unavailable" >&2
    exit 2
}

declare -a INITIALIZED_PATHS=() MODULE_DIR_IDENTITIES=()
declare -a HOOK_DIR_IDENTITIES=() SKIPPED_PATHS=()
for sm_path in "${SM_PATHS[@]}"; do
    if ! index_entry_for_path "$sm_path"; then
        echo "ERROR: submodule index inventory omitted $sm_path" >&2
        exit 2
    fi
    if ! module_state=$(classify_direct_directory "$GIT_ADMIN/modules" "$sm_path"); then
        echo "ERROR: unsafe Git module administration path for $sm_path" >&2
        exit 2
    fi
    if [ "$module_state" = missing ]; then
        STATUS_PATHS+=("$sm_path")
        STATUS_MARKER_VALUES+=(-)
        SKIPPED_PATHS+=("$sm_path")
        continue
    fi
    module_dir="$GIT_ADMIN/modules/$sm_path"
    if ! module_dir_identity=$(directory_identity "$module_dir" "$GIT_ADMIN"); then
        echo "ERROR: module administration directory is not owner-controlled for $sm_path" >&2
        exit 2
    fi
    if ! checkout_state=$(classify_initialized_checkout \
        "$sm_path" "$module_dir"); then
        echo "ERROR: unsafe initialized checkout state for $sm_path" >&2
        exit 2
    fi
    if [ "$checkout_state" = missing ]; then
        STATUS_PATHS+=("$sm_path")
        STATUS_MARKER_VALUES+=(-)
        SKIPPED_PATHS+=("$sm_path")
        continue
    fi
    if [ "$checkout_state" != present ]; then
        echo "ERROR: malformed initialized checkout state for $sm_path" >&2
        exit 2
    fi
    if [ "$INDEX_CONFLICT" -eq 1 ]; then
        marker=U
    else
        if ! checkout_head=$(git_clean --git-dir="$module_dir" \
            rev-parse --verify 'HEAD^{commit}'); then
            echo "ERROR: initialized submodule HEAD is unavailable for $sm_path" >&2
            exit 2
        fi
        if [[ "$checkout_head" == *$'\n'* ]] \
            || [[ ! "$checkout_head" =~ ^[0-9a-fA-F]{40,64}$ ]] \
            || [[ "$checkout_head" =~ ^0+$ ]]; then
            echo "ERROR: initialized submodule HEAD is malformed for $sm_path" >&2
            exit 2
        fi
        marker=' '
        if [ "$checkout_head" != "$INDEX_OID" ]; then
            marker=+
        fi
    fi
    STATUS_PATHS+=("$sm_path")
    STATUS_MARKER_VALUES+=("$marker")
    hook_dir="$module_dir/hooks"
    if ! hook_dir_state=$(classify_direct_directory \
        "$GIT_ADMIN/modules/$sm_path" hooks); then
        echo "ERROR: unsafe hooks directory for $sm_path" >&2
        exit 2
    fi
    hook_dir_identity=missing
    if [ "$hook_dir_state" = present ]; then
        if ! hook_dir_identity=$(directory_identity "$hook_dir" "$GIT_ADMIN"); then
            echo "ERROR: hooks directory is not owner-controlled for $sm_path" >&2
            exit 2
        fi
    fi
    dst="$hook_dir/pre-commit"
    if [ -L "$dst" ] || { [ -e "$dst" ] && [ ! -f "$dst" ]; }; then
        echo "ERROR: hook destination is a symlink or nonregular object for $sm_path" >&2
        exit 2
    fi
    if [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] \
        && [ -e "$dst" ] && ! verify_hook "$dst" "$hook_dir_identity" >/dev/null; then
        echo "ERROR: refusing to overwrite an existing noncanonical hook for $sm_path" >&2
        exit 2
    fi
    INITIALIZED_PATHS+=("$sm_path")
    MODULE_DIR_IDENTITIES+=("$module_dir_identity")
    HOOK_DIR_IDENTITIES+=("$hook_dir_identity")
done

copied=0
verified=0
skipped=${#SKIPPED_PATHS[@]}
stale=0
planned=0
report_lines=()

if [ "$skipped" -gt 0 ]; then
    for sm_path in "${SKIPPED_PATHS[@]}"; do
        report_lines+=("[skip]   $sm_path  (not initialized; exact fleet coverage is incomplete)")
    done
fi

# Live and verification modes never make a partial initialized-subset claim.
if [ "$skipped" -eq 0 ]; then
    for initialized_index in "${!INITIALIZED_PATHS[@]}"; do
        sm_path="${INITIALIZED_PATHS[$initialized_index]}"
        module_dir_identity="${MODULE_DIR_IDENTITIES[$initialized_index]}"
        hook_dir_identity="${HOOK_DIR_IDENTITIES[$initialized_index]}"
        dst_rel=".git/modules/$sm_path/hooks/pre-commit"
        hook_dir="$GIT_ADMIN/modules/$sm_path/hooks"
        dst="$hook_dir/pre-commit"
        if ! status_marker_for_path "$sm_path"; then
            echo "ERROR: submodule status inventory omitted $sm_path" >&2
            exit 2
        fi
        marker="$STATUS_MARKER"

        if [ "$DRY_RUN" -eq 1 ]; then
            if [ -e "$dst" ]; then
                mode=$(file_mode "$dst")
            else
                mode="(none)"
            fi
            report_lines+=("[plan]   $sm_path -> $dst_rel  (current mode=$mode, submodule-status='$marker')")
            planned=$((planned + 1))
            continue
        fi

        if [ "$VERIFY_ONLY" -eq 1 ]; then
            if [ -f "$dst" ] && [ ! -L "$dst" ] \
                && mode=$(verify_hook "$dst" "$hook_dir_identity"); then
                report_lines+=("[ok]     $sm_path  (sha256 matches; executable mode=$mode)")
                verified=$((verified + 1))
            elif [ -e "$dst" ]; then
                report_lines+=("[stale]  $sm_path  (bytes or executable mode differ from source)")
                stale=$((stale + 1))
            else
                report_lines+=("[absent] $sm_path  (hook not installed; re-run to install)")
                stale=$((stale + 1))
            fi
            continue
        fi

        if [ "$hook_dir_identity" = missing ]; then
            module_dir="$GIT_ADMIN/modules/$sm_path"
            if ! hook_dir_identity=$(ensure_hooks_directory \
                "$module_dir" "$module_dir_identity" "$GIT_ADMIN"); then
                report_lines+=("[FAIL]   $sm_path  (could not create direct hooks directory)")
                stale=$((stale + 1))
                continue
            fi
        fi
        if ! hook_dir_state=$(classify_direct_directory \
            "$GIT_ADMIN/modules/$sm_path" hooks) || [ "$hook_dir_state" != present ]; then
            report_lines+=("[FAIL]   $sm_path  (hooks directory changed or became unsafe)")
            stale=$((stale + 1))
            continue
        fi
        if ! current_hook_dir_identity=$(directory_identity "$hook_dir" "$GIT_ADMIN") \
            || [ "$current_hook_dir_identity" != "$hook_dir_identity" ]; then
            report_lines+=("[FAIL]   $sm_path  (hooks directory changed after preflight)")
            stale=$((stale + 1))
            continue
        fi
        if install_result=$(install_hook "$dst" "$hook_dir_identity" 2>&1); then
            if [[ ! "$install_result" =~ ^(installed|retained)[[:space:]]([0-7]{3,4})$ ]]; then
                report_lines+=("[FAIL]   $sm_path  (installer returned a malformed receipt)")
                stale=$((stale + 1))
                continue
            fi
            install_outcome="${BASH_REMATCH[1]}"
            mode="${BASH_REMATCH[2]}"
            if [ "$install_outcome" = retained ]; then
                report_lines+=("[ok]     $sm_path  (canonical hook retained; executable mode=$mode)")
            else
                report_lines+=("[copy]   $sm_path -> $dst_rel  (mode=$mode, sha256 matches)")
            fi
            copied=$((copied + 1))
        else
            if [ -n "$install_result" ]; then
                printf 'ERROR: hook installer: %s\n' "$install_result" >&2
            fi
            report_lines+=("[FAIL]   $sm_path  (atomic no-follow installation failed)")
            stale=$((stale + 1))
        fi
    done
fi

echo "=== tools/propagate-pre-commit-hooks.sh ==="
echo "timestamp:        $TS"
echo "source hook:      $SRC_HOOK"
echo "source sha256:    $SRC_HASH"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "mode:             dry-run"
elif [ "$VERIFY_ONLY" -eq 1 ]; then
    echo "mode:             verify"
else
    echo "mode:             live"
fi
echo
echo "--- per-submodule status ---"
for line in "${report_lines[@]}"; do
    echo "$line"
done
echo "--- end ---"
echo
echo "=== SUMMARY ==="
echo "total submodules parsed:       $total"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "planned (initialized):        $planned"
    echo "incomplete (uninitialized):   $skipped"
elif [ "$VERIFY_ONLY" -eq 1 ]; then
    echo "verified (matches source):    $verified"
    echo "stale or absent:              $stale"
    echo "incomplete (uninitialized):   $skipped"
else
    echo "installed or retained:        $copied"
    echo "stale or failed (live):       $stale"
    echo "incomplete (uninitialized):   $skipped"
fi

if [ "$skipped" -gt 0 ]; then
    echo
    echo "Initialize every canonical submodule, then re-run:"
    echo "  git submodule update --init --recursive"
    echo "  ./tools/propagate-pre-commit-hooks.sh --verify"
fi

if [ "$skipped" -gt 0 ] || [ "$stale" -gt 0 ]; then
    exit 1
fi
if [ "$DRY_RUN" -eq 1 ] && [ "$planned" -ne "$total" ]; then
    exit 1
fi
if [ "$VERIFY_ONLY" -eq 1 ] && [ "$verified" -ne "$total" ]; then
    exit 1
fi
if [ "$DRY_RUN" -eq 0 ] && [ "$VERIFY_ONLY" -eq 0 ] \
    && [ "$copied" -ne "$total" ]; then
    exit 1
fi
exit 0
