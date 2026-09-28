#!/usr/bin/env bash
# scripts/install/root-install.sh — Phase 2: Root-privileged installs
#
# Invoked by install.sh as: sudo -E ... bash root-install.sh [skip-phases...]
#
# Runs only the phases that require root:
#   Phase 10 — apt system packages
#   Phase 20 — Hephaestus base tooling (runs as the invoking user and uses its
#              explicit sudo boundaries for system operations)
#
# Reads STATE_FILE (written by Phase 1) to skip phases already satisfied.
# Positional args: phase numbers to skip (forwarded from --skip flags).
#
# shellcheck disable=SC2015,SC2034
set -uo pipefail

# ─── Env expectations (set by parent install.sh via sudo -E) ─────────────────
: "${ODYSSEUS_ROOT:?ODYSSEUS_ROOT must be set}"
: "${INSTALL:=true}"
: "${ROLE:=all}"
: "${STATE_FILE:=}"

export INSTALL ROLE ODYSSEUS_ROOT

# ─── Parse skip list from positional args ─────────────────────────────────────
SKIP_PHASES=("$@")

_should_skip() {
    local phase="$1"
    for skip in "${SKIP_PHASES[@]:-}"; do
        [[ "$phase" == "$skip" ]] && return 0
    done
    return 1
}

# ─── Source helpers ───────────────────────────────────────────────────────────
# shellcheck source=lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

_real_user="${SUDO_USER:-}"

# ─── Load state from Phase 1 ─────────────────────────────────────────────────
if [[ -n "$STATE_FILE" && -f "$STATE_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$STATE_FILE"
fi

# ─── Phase 10: System dependencies ───────────────────────────────────────────
if _should_skip "10"; then
    check_skip "Phase 10: skipped (--skip)"
elif [[ "${PHASE_10_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 10: system-deps — all packages already present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 10${NC} — system-deps"
    # shellcheck source=10-system-deps.sh
    source "$(dirname "${BASH_SOURCE[0]}")/10-system-deps.sh"
fi

# ─── Phase 20: Base tooling (Hephaestus) ───────────────────────────────
if _should_skip "20"; then
    check_skip "Phase 20: skipped (--skip)"
elif [[ "${PHASE_20_MISSING:-true}" == "false" ]]; then
    check_skip "Phase 20: base-tooling — all tools already present"
else
    echo ""
    echo -e "${BOLD}▶ Phase 20${NC} — base-tooling"
    _phase_20_script="$(dirname "${BASH_SOURCE[0]}")/20-base-tooling.sh"
    if [[ "$EUID" -eq 0 && -n "$_real_user" && "$_real_user" != root ]]; then
        if /usr/bin/python3 -I -S - \
            "$_real_user" "$HOME" "$_phase_20_script" <<'PY'
import os
import pwd
import sys

user_name, home, phase_script = sys.argv[1:4]
try:
    user = pwd.getpwnam(user_name)
except KeyError as error:
    raise SystemExit(f"root-install phase 20: unknown user {user_name!r}") from error

environment = {
    "HOME": home,
    "INSTALL": os.environ["INSTALL"],
    "LC_ALL": "C",
    "LOGNAME": user_name,
    "ODYSSEUS_ROOT": os.environ["ODYSSEUS_ROOT"],
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "ROLE": os.environ["ROLE"],
    "SHELL": "/bin/bash",
    "USER": user_name,
}
os.initgroups(user_name, user.pw_gid)
if hasattr(os, "setresgid"):
    os.setresgid(user.pw_gid, user.pw_gid, user.pw_gid)
else:
    os.setgid(user.pw_gid)
if hasattr(os, "setresuid"):
    os.setresuid(user.pw_uid, user.pw_uid, user.pw_uid)
else:
    os.setuid(user.pw_uid)
os.chdir(home)
os.execve("/bin/bash", ["/bin/bash", phase_script], environment)
PY
        then
            :
        else
            check_fail "Phase 20 did not complete as $_real_user"
        fi
    else
        # shellcheck source=20-base-tooling.sh
        source "$_phase_20_script"
    fi
    unset _phase_20_script
fi

# ─── Prepare user-directory nodes ─────────────────────────────────────────────
# Create missing cache and tool directories for Phase 3 after dropping to the
# invoking user. Existing nodes must already belong to that user. Work through
# directory descriptors below a verified HOME. The helper holds no root
# authority while it touches user-controlled paths, and it never changes node
# ownership.
if [[ -n "$_real_user" ]]; then
    if /usr/bin/python3 -I -S - "$HOME" "$_real_user" <<'PY'
import os
import pwd
import stat
import sys


DIRECTORY_FLAGS = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC


class OwnershipError(Exception):
    pass


def identity(metadata):
    return metadata.st_dev, metadata.st_ino


def check_directory(metadata, label, allowed_owners):
    if not stat.S_ISDIR(metadata.st_mode):
        raise OwnershipError(f"{label} is not a direct directory")
    if metadata.st_uid not in allowed_owners:
        raise OwnershipError(f"{label} has an unexpected owner")
    if stat.S_IMODE(metadata.st_mode) & 0o022:
        raise OwnershipError(f"{label} is writable by its group or by other users")


def open_verified_directory(parent_fd, name, label, allowed_owners):
    try:
        before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise OwnershipError(
            f"{label} could not be inspected safely: {error.strerror}"
        ) from error
    check_directory(before, label, allowed_owners)
    try:
        child_fd = os.open(name, DIRECTORY_FLAGS, dir_fd=parent_fd)
    except OSError as error:
        raise OwnershipError(
            f"{label} could not be opened safely: {error.strerror}"
        ) from error
    try:
        after = os.fstat(child_fd)
        check_directory(after, label, allowed_owners)
        if identity(before) != identity(after):
            raise OwnershipError(f"{label} changed while it was opened")
        return child_fd
    except Exception:
        os.close(child_fd)
        raise


def open_home(home, expected_uid):
    if not os.path.isabs(home) or os.path.normpath(home) != home:
        raise OwnershipError("HOME must be an absolute normalized path")
    current_fd = os.open("/", DIRECTORY_FLAGS)
    try:
        components = [component for component in home.split("/") if component]
        if not components:
            raise OwnershipError("HOME must not be the filesystem root")
        for offset, component in enumerate(components):
            before = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise OwnershipError("HOME contains a link or a non-directory component")
            child_fd = os.open(component, DIRECTORY_FLAGS, dir_fd=current_fd)
            after = os.fstat(child_fd)
            if identity(before) != identity(after) or not stat.S_ISDIR(after.st_mode):
                os.close(child_fd)
                raise OwnershipError("HOME changed while it was opened")
            os.close(current_fd)
            current_fd = child_fd
            if offset == len(components) - 1:
                check_directory(after, "HOME", {expected_uid})
        return current_fd
    except Exception:
        os.close(current_fd)
        raise


def ensure_directory(parent_fd, name, label, exact_mode=None):
    try:
        os.mkdir(name, 0o700, dir_fd=parent_fd)
    except FileExistsError:
        pass
    try:
        entry_before = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    except OSError as error:
        raise OwnershipError(
            f"{label} could not be inspected safely: {error.strerror}"
        ) from error
    check_directory(entry_before, label, {target_uid})
    if entry_before.st_dev != home_device:
        raise OwnershipError(f"{label} crosses the HOME filesystem boundary")
    current_mode = stat.S_IMODE(entry_before.st_mode)
    desired_mode = (
        exact_mode
        if exact_mode is not None
        else (current_mode | 0o700) & 0o755
    )
    if current_mode & 0o500 != 0o500:
        try:
            os.chmod(
                name,
                desired_mode,
                dir_fd=parent_fd,
                follow_symlinks=False,
            )
        except OSError as error:
            raise OwnershipError(
                f"{label} could not be made accessible safely: {error.strerror}"
            ) from error
    child_fd = open_verified_directory(parent_fd, name, label, {target_uid})
    try:
        before = os.fstat(child_fd)
        if identity(entry_before) != identity(before):
            raise OwnershipError(f"{label} changed during mode preparation")
        if before.st_dev != home_device:
            raise OwnershipError(f"{label} crosses the HOME filesystem boundary")
        expected_gid = before.st_gid
        os.fchmod(child_fd, desired_mode)
        after = os.fstat(child_fd)
        if identity(before) != identity(after):
            raise OwnershipError(f"{label} changed during ownership repair")
        if after.st_uid != target_uid or after.st_gid != expected_gid:
            raise OwnershipError(f"{label} does not have the required ownership")
        if stat.S_IMODE(after.st_mode) != desired_mode:
            raise OwnershipError(f"{label} does not have the required mode")
        return child_fd
    except Exception:
        os.close(child_fd)
        raise


def ensure_path(home_fd, relative_path, final_mode=None):
    current_fd = os.dup(home_fd)
    label_parts = []
    try:
        components = relative_path.split("/")
        for offset, component in enumerate(components):
            label_parts.append(component)
            child_fd = ensure_directory(
                current_fd,
                component,
                "/".join(label_parts),
                final_mode if offset == len(components) - 1 else None,
            )
            os.close(current_fd)
            current_fd = child_fd
        return current_fd
    except Exception:
        os.close(current_fd)
        raise


home_path, user_name = sys.argv[1:3]
try:
    user = pwd.getpwnam(user_name)
except KeyError as error:
    raise SystemExit(f"root-install ownership repair: unknown user {user_name!r}") from error

target_uid = user.pw_uid
target_gid = user.pw_gid
if os.geteuid() == 0 and target_uid != 0:
    os.initgroups(user_name, target_gid)
    if hasattr(os, "setresgid"):
        os.setresgid(target_gid, target_gid, target_gid)
    else:
        os.setgid(target_gid)
    if hasattr(os, "setresuid"):
        os.setresuid(target_uid, target_uid, target_uid)
    else:
        os.setuid(target_uid)
elif os.geteuid() != target_uid:
    raise SystemExit(
        "root-install ownership repair: helper does not have target-user authority"
    )
home_fd = -1
opened = []
try:
    home_fd = open_home(home_path, target_uid)
    home_device = os.fstat(home_fd).st_dev
    required_directories = (
        ".cache/rattler/cache/pkgs",
        ".cache/rattler/cache/repodata",
        ".cache/uv",
        ".pixi",
        ".local/bin",
        ".local/lib/pkgconfig",
        ".local/include",
    )
    for target in required_directories:
        target_fd = ensure_path(home_fd, target)
        opened.append(target_fd)

    # Phase 3 manages the contents of this directory. Repair only the directory
    # node, so the helper does not traverse user-controlled Claude data.
    claude_fd = ensure_path(home_fd, ".claude", final_mode=0o700)
    opened.append(claude_fd)
except (OSError, OwnershipError) as error:
    print(f"root-install ownership repair: {error}", file=sys.stderr)
    raise SystemExit(1) from error
finally:
    for descriptor in opened:
        os.close(descriptor)
    if home_fd >= 0:
        os.close(home_fd)
PY
    then
        check_pass "User directories are present and usable by $_real_user"
    else
        check_fail "User-directory ownership repair did not pass its safety checks"
    fi
fi
unset _real_user

# ─── Propagate failure to the parent installer ───────────────────────────────
# The phase scripts are *sourced*, so a check_fail only increments _FAIL — it
# does not set this subprocess's exit status. Without an explicit gate the
# script exits with the last command's status (0), and install.sh's
# `if sudo -E ... bash root-install.sh; then` wrapper reports success on a
# failed phase (issue #372). Exit non-zero when any check failed.
[[ ${_FAIL:-0} -gt 0 ]] && exit 1
exit 0
