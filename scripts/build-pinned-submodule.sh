#!/bin/bash -p
# Build one root-supported C++ component from the superproject's exact gitlink.
#
# The component checkout is used only to locate its object database. Before the
# first build tool starts, every blob in the selected gitlink tree is copied to
# a private snapshot, made read-only, and bound through an open directory
# descriptor where the host supports it. Later checkout or Git-dir replacement
# therefore cannot change the source/configuration bytes consumed by a stage.
set -euo pipefail
umask 077

die() {
    printf 'ERROR: %s\n' "$1" >&2
    exit 1
}

canonical_bounded_decimal() {
    local value=$1 maximum=$2
    [[ "$value" =~ ^[1-9][0-9]*$ ]] || return 1
    [[ ${#value} -lt ${#maximum} ]] && return 0
    [[ ${#value} -eq ${#maximum} ]] || return 1
    (( 10#$value <= maximum ))
}

path_state() {
    if /usr/bin/stat -L -c '%d:%i:%f:%u:%g' -- "$1" 2>/dev/null; then
        return 0
    fi
    /usr/bin/stat -L -f '%d:%i:%p:%u:%g' -- "$1" 2>/dev/null
}

path_inode() {
    if /usr/bin/stat -L -c '%i' -- "$1" 2>/dev/null; then
        return 0
    fi
    /usr/bin/stat -L -f '%i' -- "$1" 2>/dev/null
}

path_device() {
    if /usr/bin/stat -L -c '%d' -- "$1" 2>/dev/null; then
        return 0
    fi
    /usr/bin/stat -L -f '%d' -- "$1" 2>/dev/null
}

file_mode() {
    if /usr/bin/stat -c '%a' -- "$1" 2>/dev/null; then
        return 0
    fi
    /usr/bin/stat -f '%Lp' -- "$1" 2>/dev/null
}

canonical_object_id() {
    [[ "$1" =~ ^[0-9a-f]{40}$ || "$1" =~ ^[0-9a-f]{64}$ ]]
}

[[ $# -eq 1 ]] || die 'usage: build-pinned-submodule.sh <component>'
component=$1
case "$component" in
    agamemnon)
        submodule_path=control/Agamemnon
        source_subdir=
        output_name=Agamemnon
        conan_profile=conan/profiles/debug
        build_type=Debug
        testing_flag=-DAgamemnon_BUILD_TESTING=ON
        export_commands=true
        ;;
    nestor)
        submodule_path=control/Nestor
        source_subdir=
        output_name=Nestor
        conan_profile=conan/profiles/nestor-debug
        build_type=Debug
        testing_flag=-DNestor_BUILD_TESTING=ON
        export_commands=true
        ;;
    charybdis)
        submodule_path=testing/Charybdis
        source_subdir=
        output_name=Charybdis
        conan_profile=conan/profiles/debug
        build_type=Debug
        testing_flag=-DCharybdis_BUILD_TESTING=ON
        export_commands=true
        ;;
    keystone)
        submodule_path=provisioning/Keystone
        source_subdir=
        output_name=Keystone
        conan_profile=conan/profiles/debug
        build_type=Debug
        testing_flag=
        export_commands=true
        ;;
    myrmidon)
        submodule_path=provisioning/Myrmidons
        source_subdir=hello-world
        output_name=Myrmidons/hello-world
        conan_profile=
        build_type=Release
        testing_flag=
        export_commands=false
        ;;
    *) die "unsupported C++ component: $component" ;;
esac

script_path=${BASH_SOURCE[0]}
script_parent=.
[[ "$script_path" != */* ]] || script_parent=${script_path%/*}
script_dir=$(cd "$script_parent" && pwd -P) \
    || die 'cannot resolve the helper directory'
root=$(cd "$script_dir/.." && pwd -P) \
    || die 'cannot resolve the Odysseus root'
[[ -d "$root" && ! -L "$root" ]] \
    || die 'Odysseus root must be a direct directory'

build_jobs=${ODYSSEUS_BUILD_JOBS:-2}
build_vmem_kb=${ODYSSEUS_BUILD_VMEM_KB:-6291456}
canonical_bounded_decimal "$build_jobs" 8 \
    || die 'ODYSSEUS_BUILD_JOBS must be a canonical decimal from 1 through 8'
canonical_bounded_decimal "$build_vmem_kb" 67108864 \
    || die 'ODYSSEUS_BUILD_VMEM_KB must be a canonical decimal from 1 through 67108864'

git_path=/usr/bin/git
bash_path=/bin/bash
python_path=/usr/bin/python3
env_path=/usr/bin/env
# Ubuntu's system Python entry point is a link to a versioned sibling. Accept
# that distribution-owned layout without accepting arbitrary linked routes or
# an interpreter selected through the caller's PATH.
if [[ -L "$python_path" ]]; then
    python_target=$(/usr/bin/readlink "$python_path") \
        || die 'cannot resolve the system Python entry point'
    [[ "$python_target" =~ ^python3\.[0-9]+$ ]] \
        || die 'system Python must link to a versioned sibling in /usr/bin'
    python_path="/usr/bin/$python_target"
fi
[[ -f "$git_path" && ! -L "$git_path" && -x "$git_path" ]] \
    || die 'Git is unavailable through /usr/bin/git'
[[ -f "$bash_path" && ! -L "$bash_path" && -x "$bash_path" ]] \
    || die 'Bash is unavailable through /bin/bash'
[[ -f "$python_path" && ! -L "$python_path" && -x "$python_path" ]] \
    || die 'Python is unavailable through /usr/bin/python3'
[[ -f "$env_path" && -x "$env_path" ]] \
    || die 'env is unavailable through /usr/bin/env'
if [[ ${ODYSSEUS_PIXI_SNAPSHOT_ACTIVE:-} != 1 ]]; then
    if ! pixi_path=$(command -v pixi 2>/dev/null); then
        die 'pixi must resolve to one direct executable'
    fi
    [[ "$pixi_path" == /* && -f "$pixi_path" && ! -L "$pixi_path" \
        && -x "$pixi_path" ]] \
        || die 'pixi must resolve to one direct executable'
    exec "$python_path" -I -S - \
        "$bash_path" "$script_path" "$component" "$pixi_path" <<'PY'
import fcntl
import hashlib
import os
import stat
import sys


def fail(message):
    print("ERROR: {}".format(message), file=sys.stderr)
    raise SystemExit(1)


bash_path, script_path, component, pixi_path = sys.argv[1:]
flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
try:
    named = os.stat(pixi_path, follow_symlinks=False)
    source = os.open(pixi_path, flags)
    opened = os.fstat(source)
except OSError as error:
    fail("cannot bind the selected pixi executable: {}".format(error))
identity = lambda value: (
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
if (
    identity(named) != identity(opened)
    or not stat.S_ISREG(opened.st_mode)
    or not opened.st_mode & 0o111
):
    os.close(source)
    fail("pixi must resolve to one direct executable")

if sys.platform.startswith("linux"):
    names = (
        "F_ADD_SEALS",
        "F_GET_SEALS",
        "F_SEAL_SEAL",
        "F_SEAL_SHRINK",
        "F_SEAL_GROW",
        "F_SEAL_WRITE",
    )
    if not hasattr(os, "memfd_create") or not all(hasattr(fcntl, name) for name in names):
        os.close(source)
        fail("immutable pixi executable snapshots are unavailable")
    snapshot = os.memfd_create("odysseus-pixi", getattr(os, "MFD_ALLOW_SEALING", 0x0002))
    digest = hashlib.sha256()
    offset = 0
    while offset < opened.st_size:
        data = os.pread(source, min(64 * 1024, opened.st_size - offset), offset)
        if not data:
            break
        view = memoryview(data)
        while view:
            written = os.write(snapshot, view)
            if written <= 0:
                fail("pixi executable snapshot write made no progress")
            view = view[written:]
        digest.update(data)
        offset += len(data)
    if offset != opened.st_size or identity(os.fstat(source)) != identity(opened):
        os.close(source)
        os.close(snapshot)
        fail("pixi executable changed while it was snapshotted")
    second = hashlib.sha256()
    verify_offset = 0
    while verify_offset < opened.st_size:
        data = os.pread(source, min(64 * 1024, opened.st_size - verify_offset), verify_offset)
        if not data:
            break
        second.update(data)
        verify_offset += len(data)
    os.close(source)
    if verify_offset != opened.st_size or second.digest() != digest.digest():
        os.close(snapshot)
        fail("pixi executable changed while it was snapshotted")
    os.fchmod(snapshot, 0o500)
    seals = (
        fcntl.F_SEAL_SHRINK
        | fcntl.F_SEAL_GROW
        | fcntl.F_SEAL_WRITE
        | fcntl.F_SEAL_SEAL
    )
    fcntl.fcntl(snapshot, fcntl.F_ADD_SEALS, seals)
    if fcntl.fcntl(snapshot, fcntl.F_GET_SEALS) & seals != seals:
        os.close(snapshot)
        fail("pixi executable snapshot could not be sealed")
    # memfd_create returns O_RDWR even after sealing. Reopen the same sealed
    # object read-only so the downstream descriptor policy remains uniform.
    readonly_snapshot = os.open(f"/proc/self/fd/{snapshot}", os.O_RDONLY)
    readonly_value = os.fstat(readonly_snapshot)
    snapshot_value = os.fstat(snapshot)
    if (
        (readonly_value.st_dev, readonly_value.st_ino)
        != (snapshot_value.st_dev, snapshot_value.st_ino)
        or fcntl.fcntl(readonly_snapshot, fcntl.F_GET_SEALS) & seals != seals
    ):
        os.close(readonly_snapshot)
        os.close(snapshot)
        fail("read-only pixi snapshot identity changed")
    os.close(snapshot)
    snapshot = readonly_snapshot
else:
    snapshot = source
    digest = hashlib.sha256()
    offset = 0
    while offset < opened.st_size:
        data = os.pread(source, min(64 * 1024, opened.st_size - offset), offset)
        if not data:
            break
        digest.update(data)
        offset += len(data)
    if offset != opened.st_size:
        os.close(snapshot)
        fail("pixi executable changed while it was snapshotted")

if snapshot != 8:
    os.dup2(snapshot, 8)
    os.close(snapshot)
os.set_inheritable(8, True)
environment = dict(os.environ)
environment["ODYSSEUS_PIXI_SNAPSHOT_ACTIVE"] = "1"
environment["ODYSSEUS_PIXI_SOURCE_PATH"] = pixi_path
environment["ODYSSEUS_PIXI_SNAPSHOT_SHA256"] = digest.hexdigest()
os.execve(
    bash_path,
    [bash_path, "-p", os.path.abspath(script_path), component],
    environment,
)
PY
fi
pixi_path=${ODYSSEUS_PIXI_SOURCE_PATH:?}
pixi_digest=${ODYSSEUS_PIXI_SNAPSHOT_SHA256:?}
[[ "$pixi_digest" =~ ^[0-9a-f]{64}$ ]] \
    || die 'invalid pixi executable snapshot digest'
PATH=/usr/bin:/bin
export PATH

git_fd=9
exec 9<"$git_path" || die 'cannot bind the Git executable'
git_state=$(path_state "$git_path") || die 'cannot read the Git identity'
git_fd_inode=$(path_inode "/dev/fd/$git_fd") \
    || die 'cannot read the bound Git identity'
pixi_fd=8
pixi_fd_inode=$(path_inode "/dev/fd/$pixi_fd") \
    || die 'cannot read the bound pixi identity'
bash_state=$(path_state "$bash_path") || die 'cannot read the Bash identity'
python_state=$(path_state "$python_path") || die 'cannot read the Python identity'
env_state=$(path_state "$env_path") || die 'cannot read the env identity'

git_exec=$git_path
pixi_exec=$pixi_path
if [[ -e "/proc/self/fd/$git_fd" && -e "/proc/self/fd/$pixi_fd" ]]; then
    git_exec="/proc/self/fd/$git_fd"
    pixi_exec="/proc/self/fd/$pixi_fd"
fi

bound_git() {
    [[ "$(path_inode "/dev/fd/$git_fd")" == "$git_fd_inode" ]] \
        || return 125
    if [[ "$git_exec" == "$git_path" ]]; then
        [[ "$(path_state "$git_path")" == "$git_state" ]] || return 125
    fi
    [[ "$(path_state "$env_path")" == "$env_state" ]] || return 125
    "$env_path" -i \
        HOME=/nonexistent \
        XDG_CONFIG_HOME=/nonexistent \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_NO_LAZY_FETCH=1 \
        LC_ALL=C \
        PATH=/usr/bin:/bin \
        "$git_exec" "$@"
}

# Security-sensitive filesystem operations are descriptor-relative and use
# exclusive rename primitives. A missing primitive is a hard failure: falling
# back to a pathname check followed by mutation would reopen the race this
# helper is intended to close.
guarded_python() {
    [[ "$(path_state "$python_path")" == "$python_state" ]] || {
        printf '%s\n' 'ERROR: bound Python executable identity changed' >&2
        return 125
    }
    "$python_path" -I -S - "$@" <<'PY'
import ctypes
import json
import os
import secrets
import stat
import sys


def fail(message, status=1):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(status)


def open_dir(path):
    flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    return os.open(path, flags)


def same_object(value, device, inode):
    return value.st_dev == int(device) and value.st_ino == int(inode)


def rename_exclusive(source_fd, source, target_fd, target):
    source_bytes = os.fsencode(source)
    target_bytes = os.fsencode(target)
    libc = ctypes.CDLL(None, use_errno=True)
    if sys.platform.startswith("linux") and hasattr(libc, "renameat2"):
        result = libc.renameat2(
            source_fd,
            ctypes.c_char_p(source_bytes),
            target_fd,
            ctypes.c_char_p(target_bytes),
            1,
        )
    elif sys.platform == "darwin" and hasattr(libc, "renameatx_np"):
        result = libc.renameatx_np(
            source_fd,
            ctypes.c_char_p(source_bytes),
            target_fd,
            ctypes.c_char_p(target_bytes),
            0x4,
        )
    else:
        fail("exclusive descriptor-relative rename is unavailable", 78)
    if result != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), source)


def unique_name(prefix):
    return f".{prefix}.{secrets.token_hex(16)}"


def quarantine(parent_fd, name, expected=None):
    initial = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
    if expected is not None and not same_object(initial, *expected):
        fail("cleanup target identity changed; replacement preserved")
    for _ in range(64):
        holding = unique_name("odysseus-delete")
        try:
            rename_exclusive(parent_fd, name, parent_fd, holding)
            break
        except FileExistsError:
            continue
    else:
        fail("cannot allocate an exclusive cleanup name")
    moved = os.stat(holding, dir_fd=parent_fd, follow_symlinks=False)
    if moved.st_dev != initial.st_dev or moved.st_ino != initial.st_ino:
        fail("cleanup target was replaced during quarantine; replacement preserved")
    return holding, moved


def remove_entry(parent_fd, name, expected=None):
    holding, entry = quarantine(parent_fd, name, expected)
    if stat.S_ISDIR(entry.st_mode):
        child_fd = os.open(
            holding,
            os.O_RDONLY
            | os.O_DIRECTORY
            | os.O_CLOEXEC
            | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=parent_fd,
        )
        try:
            opened = os.fstat(child_fd)
            if opened.st_dev != entry.st_dev or opened.st_ino != entry.st_ino:
                fail("cleanup directory changed after quarantine; replacement preserved")
            os.fchmod(child_fd, 0o700)
            for child in os.listdir(child_fd):
                remove_entry(child_fd, child)
            final = os.stat(holding, dir_fd=parent_fd, follow_symlinks=False)
            if final.st_dev != entry.st_dev or final.st_ino != entry.st_ino:
                fail("cleanup directory changed before removal; replacement preserved")
            os.rmdir(holding, dir_fd=parent_fd)
        finally:
            os.close(child_fd)
    else:
        final = os.stat(holding, dir_fd=parent_fd, follow_symlinks=False)
        if final.st_dev != entry.st_dev or final.st_ino != entry.st_ino:
            fail("cleanup entry changed before removal; replacement preserved")
        os.unlink(holding, dir_fd=parent_fd)


def materialize_link(blob_path, destination, relative):
    with open(blob_path, "rb") as stream:
        target = stream.read()
    if b"\x00" in target:
        fail("component symlink target contains NUL")
    if not target or target.startswith(b"/"):
        fail("component tree contains an escaping symlink")
    relative_bytes = os.fsencode(relative)
    parts = []
    if b"/" in relative_bytes:
        parts.extend(relative_bytes.rsplit(b"/", 1)[0].split(b"/"))
    for part in target.split(b"/"):
        if part in (b"", b"."):
            continue
        if part == b"..":
            if not parts:
                fail("component tree contains an escaping symlink")
            parts.pop()
        else:
            parts.append(part)
    os.symlink(target, os.fsencode(destination))


def validate_null_device():
    flags = getattr(os, "O_PATH", os.O_RDONLY) | os.O_CLOEXEC
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open("/dev/null", flags)
    try:
        value = os.fstat(descriptor)
        valid = stat.S_ISCHR(value.st_mode)
        if sys.platform.startswith("linux"):
            valid = valid and os.major(value.st_rdev) == 1 and os.minor(value.st_rdev) == 3
        if not valid:
            fail("/dev/null is not the kernel null character device", 78)
    finally:
        os.close(descriptor)


operation = sys.argv[1] if len(sys.argv) > 1 else ""
arguments = sys.argv[2:]
try:
    if operation == "materialize-link" and len(arguments) == 3:
        materialize_link(*arguments)
    elif operation == "validate-null" and not arguments:
        validate_null_device()
    elif operation == "readlink" and len(arguments) == 1:
        target = os.readlink(os.fsencode(arguments[0]))
        if isinstance(target, str):
            target = os.fsencode(target)
        os.write(1, target)
    elif operation == "make-stage" and len(arguments) == 4:
        parent, leaf, device, inode = arguments
        parent_fd = open_dir(parent)
        try:
            if not same_object(os.fstat(parent_fd), device, inode):
                fail("component build-output parent identity changed")
            for _ in range(64):
                name = f".{leaf}.odysseus-stage.{secrets.token_hex(16)}"
                try:
                    os.mkdir(name, 0o700, dir_fd=parent_fd)
                    break
                except FileExistsError:
                    continue
            else:
                fail("cannot allocate a private component build output")
            value = os.stat(name, dir_fd=parent_fd, follow_symlinks=False)
            print(f"{name}\t{value.st_dev}\t{value.st_ino}")
        finally:
            os.close(parent_fd)
    elif operation == "publish" and len(arguments) == 7:
        parent, stage, final, parent_device, parent_inode, stage_device, stage_inode = arguments
        parent_fd = open_dir(parent)
        backup = None
        moved_old = False
        try:
            if not same_object(os.fstat(parent_fd), parent_device, parent_inode):
                fail("component build-output parent identity changed before publication")
            staged = os.stat(stage, dir_fd=parent_fd, follow_symlinks=False)
            if not stat.S_ISDIR(staged.st_mode) or not same_object(
                staged, stage_device, stage_inode
            ):
                fail("private component build output changed before publication")
            try:
                previous = os.stat(final, dir_fd=parent_fd, follow_symlinks=False)
            except FileNotFoundError:
                previous = None
            if previous is not None:
                if not stat.S_ISDIR(previous.st_mode):
                    fail("existing component build output is not a direct directory")
                backup = unique_name(f"{final}.odysseus-previous")
                rename_exclusive(parent_fd, final, parent_fd, backup)
                moved = os.stat(backup, dir_fd=parent_fd, follow_symlinks=False)
                if moved.st_dev != previous.st_dev or moved.st_ino != previous.st_ino:
                    fail("existing component output changed during publication; replacement preserved")
                moved_old = True
            try:
                rename_exclusive(parent_fd, stage, parent_fd, final)
            except BaseException:
                if moved_old:
                    try:
                        rename_exclusive(parent_fd, backup, parent_fd, final)
                    except BaseException:
                        pass
                raise
            published = os.stat(final, dir_fd=parent_fd, follow_symlinks=False)
            if not same_object(published, stage_device, stage_inode):
                fail("published component output identity is not the built object")
            if moved_old:
                remove_entry(
                    parent_fd,
                    backup,
                    (previous.st_dev, previous.st_ino),
                )
        finally:
            os.close(parent_fd)
    elif operation == "secure-remove" and len(arguments) == 4:
        parent, name, device, inode = arguments
        parent_fd = open_dir(parent)
        try:
            remove_entry(parent_fd, name, (int(device), int(inode)))
        finally:
            os.close(parent_fd)
    elif operation == "secure-rmdir-empty" and len(arguments) == 4:
        parent, name, device, inode = arguments
        parent_fd = open_dir(parent)
        try:
            holding, entry = quarantine(
                parent_fd, name, (int(device), int(inode))
            )
            if not stat.S_ISDIR(entry.st_mode):
                fail("empty-cleanup target is not a directory; replacement preserved")
            child_fd = os.open(
                holding,
                os.O_RDONLY
                | os.O_DIRECTORY
                | os.O_CLOEXEC
                | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=parent_fd,
            )
            try:
                opened = os.fstat(child_fd)
                if opened.st_dev != entry.st_dev or opened.st_ino != entry.st_ino:
                    fail("empty-cleanup directory changed; replacement preserved")
                os.fchmod(child_fd, 0o700)
                if os.listdir(child_fd):
                    fail("cleanup workspace has unowned children; replacement preserved")
                final = os.stat(
                    holding, dir_fd=parent_fd, follow_symlinks=False
                )
                if final.st_dev != entry.st_dev or final.st_ino != entry.st_ino:
                    fail("empty-cleanup directory changed before removal")
                os.rmdir(holding, dir_fd=parent_fd)
            finally:
                os.close(child_fd)
        finally:
            os.close(parent_fd)
    elif operation == "write-pixi-config" and len(arguments) == 2:
        config_path, environment_path = arguments
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(config_path, flags, 0o400)
        try:
            payload = f"detached-environments = {json.dumps(environment_path)}\n".encode()
            os.write(descriptor, payload)
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    else:
        fail("internal guarded operation is malformed", 78)
except OSError as error:
    fail(f"guarded operation failed: {error.strerror}")
PY
}

guarded_python validate-null || die 'cannot validate the null device'

root_git_dir=$(bound_git -C "$root" rev-parse --absolute-git-dir 2>/dev/null) \
    || die 'cannot resolve the superproject Git directory'
root_top=$(bound_git -C "$root" rev-parse --show-toplevel 2>/dev/null) \
    || die 'cannot resolve the superproject root'
[[ "$root_top" == "$root" ]] || die 'helper is not running at the superproject root'
root_commit=$(bound_git -C "$root" rev-parse --verify 'HEAD^{commit}' 2>/dev/null) \
    || die 'cannot bind the superproject commit'
canonical_object_id "$root_commit" || die 'superproject commit identity is malformed'

gitlink_record=$(bound_git -C "$root" ls-tree "$root_commit" -- \
    "$submodule_path" 2>/dev/null) || die 'cannot read the component gitlink'
IFS=$' \t' read -r gitlink_mode gitlink_type gitlink_commit \
    gitlink_path gitlink_extra <<< "$gitlink_record"
[[ "$gitlink_mode" == 160000 && "$gitlink_type" == commit \
    && "$gitlink_path" == "$submodule_path" && -z "${gitlink_extra:-}" ]] \
    || die "$submodule_path is not one exact superproject gitlink"
canonical_object_id "$gitlink_commit" || die 'component gitlink identity is malformed'

checkout="$root/$submodule_path"
[[ -d "$checkout" && ! -L "$checkout" ]] \
    || die "$submodule_path is not initialized as a direct directory"
checkout_top=$(bound_git -C "$checkout" rev-parse --show-toplevel 2>/dev/null) \
    || die "cannot resolve the $submodule_path checkout"
checkout_physical=$(cd "$checkout" && pwd -P) \
    || die "cannot resolve the physical $submodule_path checkout"
[[ "$checkout_top" == "$checkout_physical" ]] \
    || die "$submodule_path is not an independent Git worktree"
component_git_dir=$(bound_git -C "$checkout" rev-parse --absolute-git-dir 2>/dev/null) \
    || die "cannot resolve the $submodule_path object database"
[[ "$component_git_dir" == /* && -d "$component_git_dir" \
    && ! -L "$component_git_dir" ]] \
    || die "$submodule_path object database is not a direct directory"
component_tree=$(bound_git --git-dir="$component_git_dir" rev-parse --verify \
    "$gitlink_commit^{tree}" 2>/dev/null) \
    || die "the recorded $submodule_path gitlink object is unavailable"
canonical_object_id "$component_tree" || die 'component tree identity is malformed'

tmp_base=${TMPDIR:-/tmp}
tmp_base=$(cd "$tmp_base" && pwd -P) || die 'cannot resolve the temporary directory'
private_prefix="$tmp_base/odysseus-pinned-build."
private_root=$(mktemp -d "${private_prefix}XXXXXXXX") \
    || die 'cannot create a private build-input snapshot'
private_suffix=${private_root#"$private_prefix"}
case "$private_suffix" in
    ''|*[!A-Za-z0-9]*) die 'private snapshot path is malformed' ;;
esac
chmod 0700 "$private_root" || die 'cannot restrict the private snapshot'
private_root_fd=7
exec 7<"$private_root" \
    || die 'cannot bind the private snapshot root'
private_root_state=$(path_state "$private_root") \
    || die 'cannot read the private snapshot identity'
private_root_device=$(path_device "$private_root") \
    || die 'cannot read the private snapshot device'
private_root_fd_inode=$(path_inode "/dev/fd/$private_root_fd") \
    || die 'cannot read the bound private snapshot identity'

snapshot=
snapshot_fd=
snapshot_state=
snapshot_device=
snapshot_inode=
snapshot_fd_inode=
run_bounded_fd=
run_bounded_fd_inode=
tree_inventory_fd=
tree_inventory_fd_inode=
tree_inventory_oid=
build_root_fd=
build_root_fd_inode=
build_root_recorded_inode=
build_stage=
build_stage_name=
build_stage_device=
build_stage_inode=
build_parent=
build_parent_device=
build_parent_inode=
tool_state=
tool_state_device=
tool_state_inode=
tool_state_fd=
tool_state_fd_inode=
external_stage_started=false
declare -a snapshot_paths=()
declare -a snapshot_modes=()
declare -a snapshot_oids=()
declare -a snapshot_directories=()
declare -a build_ancestor_paths=()
declare -a build_ancestor_states=()

private_root_is_current() {
    [[ -d "$private_root" && ! -L "$private_root" \
        && "$(path_state "$private_root")" == "$private_root_state" \
        && "$(path_inode "/dev/fd/$private_root_fd")" == \
            "$private_root_fd_inode" ]]
}

cleanup() {
    local cleanup_failed=false private_name=${private_root##*/}
    [[ -z "$run_bounded_fd" ]] || eval "exec ${run_bounded_fd}<&-"
    [[ -z "$tree_inventory_fd" ]] \
        || eval "exec ${tree_inventory_fd}<&-"
    [[ -z "$snapshot_fd" ]] || eval "exec ${snapshot_fd}<&-"
    [[ -z "$build_root_fd" ]] || eval "exec ${build_root_fd}<&-"
    [[ -z "$tool_state_fd" ]] || eval "exec ${tool_state_fd}<&-"
    eval "exec ${private_root_fd}<&-"
    eval "exec ${pixi_fd}<&-"
    eval "exec ${git_fd}<&-"
    run_bounded_fd=
    tree_inventory_fd=
    snapshot_fd=
    build_root_fd=
    tool_state_fd=
    if [[ -n "$build_stage_name" ]]; then
        guarded_python secure-remove "$build_parent" "$build_stage_name" \
            "$build_stage_device" "$build_stage_inode" \
            || cleanup_failed=true
        build_stage_name=
    fi
    if $external_stage_started; then
        if [[ -n "$snapshot_device" && -n "$snapshot_inode" ]]; then
            guarded_python secure-remove "$private_root" source \
                "$snapshot_device" "$snapshot_inode" \
                || cleanup_failed=true
        else
            cleanup_failed=true
        fi
        if [[ -n "$tool_state_device" && -n "$tool_state_inode" ]]; then
            guarded_python secure-remove "$private_root" tool-state \
                "$tool_state_device" "$tool_state_inode" \
                || cleanup_failed=true
        else
            cleanup_failed=true
        fi
        if ! $cleanup_failed; then
            guarded_python secure-rmdir-empty "$tmp_base" "$private_name" \
                "$private_root_device" "$private_root_fd_inode" \
                || cleanup_failed=true
        fi
    else
        guarded_python secure-remove "$tmp_base" "$private_name" \
            "$private_root_device" "$private_root_fd_inode" \
            || cleanup_failed=true
    fi
    if $cleanup_failed; then
        printf '%s\n' \
            'ERROR: exact-object build workspace cleanup failed; replacements were preserved' \
            >&2
        return 1
    fi
}

handle_signal() {
    local exit_status=$1
    trap - EXIT HUP INT TERM
    if ! cleanup; then :; fi
    exit "$exit_status"
}

handle_exit() {
    local exit_status=$?
    trap - EXIT HUP INT TERM
    if ! cleanup; then
        exit 1
    fi
    exit "$exit_status"
}

trap handle_exit EXIT
trap 'handle_signal 129' HUP
trap 'handle_signal 130' INT
trap 'handle_signal 143' TERM

run_bounded_record=$(bound_git --git-dir="$root_git_dir" ls-tree \
    "$root_commit" -- scripts/run-bounded.sh 2>/dev/null) \
    || die 'cannot bind scripts/run-bounded.sh from the superproject commit'
IFS=$' \t' read -r run_bounded_mode run_bounded_type run_bounded_oid \
    run_bounded_path run_bounded_extra <<< "$run_bounded_record"
[[ "$run_bounded_mode" == 100755 && "$run_bounded_type" == blob \
    && "$run_bounded_path" == scripts/run-bounded.sh \
    && -z "${run_bounded_extra:-}" ]] \
    || die 'the selected resource helper is not one executable Git blob'
canonical_object_id "$run_bounded_oid" \
    || die 'run-bounded helper identity is malformed'
run_bounded_copy="$private_root/run-bounded"
bound_git --git-dir="$root_git_dir" cat-file blob "$run_bounded_oid" \
    > "$run_bounded_copy" || die 'cannot materialize the bound resource helper'
actual_oid=$(bound_git --git-dir="$root_git_dir" hash-object --no-filters \
    "$run_bounded_copy") \
    || die 'cannot verify the bound resource helper'
[[ "$actual_oid" == "$run_bounded_oid" ]] \
    || die 'materialized resource-helper bytes differ from the Git object'
chmod 0400 "$run_bounded_copy" || die 'cannot restrict the bound resource helper'
run_bounded_fd=6
exec 6<"$run_bounded_copy" \
    || die 'cannot open the bound resource helper'
run_bounded_fd_inode=$(path_inode "/dev/fd/$run_bounded_fd") \
    || die 'cannot read the bound resource-helper identity'
/bin/rm -f -- "$run_bounded_copy" \
    || die 'cannot unlink the private resource-helper name'

snapshot="$private_root/source"
mkdir -p "$snapshot" || die 'cannot create the source snapshot'
tree_inventory="$private_root/tree.inventory"
bound_git --git-dir="$component_git_dir" ls-tree -rz "$component_tree" \
    > "$tree_inventory" || die 'cannot enumerate the recorded component tree'
tree_inventory_oid=$(bound_git --git-dir="$component_git_dir" \
    hash-object --no-filters "$tree_inventory") \
    || die 'cannot bind the component-tree inventory'
canonical_object_id "$tree_inventory_oid" \
    || die 'component-tree inventory identity is malformed'
chmod 0400 "$tree_inventory" \
    || die 'cannot restrict the component-tree inventory'
tree_inventory_fd=4
exec 4<"$tree_inventory" \
    || die 'cannot bind the component-tree inventory'
tree_inventory_fd_inode=$(path_inode "/dev/fd/$tree_inventory_fd") \
    || die 'cannot read the bound component-tree inventory identity'

record_snapshot_directory() {
    local candidate=$1 existing
    [[ -n "$candidate" && "$candidate" != . ]] || return 0
    if [[ ${#snapshot_directories[@]} -gt 0 ]]; then
        for existing in "${snapshot_directories[@]}"; do
            [[ "$existing" != "$candidate" ]] || return 0
        done
    fi
    snapshot_directories+=("$candidate")
}

while IFS= read -r -d '' tree_entry; do
    tree_header=${tree_entry%%$'\t'*}
    relative=${tree_entry#*$'\t'}
    [[ "$tree_header" != "$tree_entry" && -n "$relative" \
        && "$relative" != /* ]] || die 'component tree contains a malformed path'
    IFS=' ' read -r object_mode object_type object_id object_extra \
        <<< "$tree_header"
    canonical_object_id "$object_id" || die 'component tree contains a malformed object'
    [[ "$object_type" == blob && -z "${object_extra:-}" ]] \
        || die 'nested gitlinks or non-blob build inputs are unsupported'
    case "/$relative/" in
        */../*|*/./*) die 'component tree contains a non-canonical path' ;;
    esac
    destination="$snapshot/$relative"
    mkdir -p "$(dirname "$destination")" \
        || die 'cannot create a snapshot directory'
    parent_relative=${relative%/*}
    if [[ "$parent_relative" != "$relative" ]]; then
        while [[ -n "$parent_relative" && "$parent_relative" != . ]]; do
            record_snapshot_directory "$parent_relative"
            [[ "$parent_relative" == */* ]] || break
            parent_relative=${parent_relative%/*}
        done
    fi
    [[ ! -e "$destination" && ! -L "$destination" ]] \
        || die 'component tree contains a colliding path'
    case "$object_mode" in
        100644|100755)
            bound_git --git-dir="$component_git_dir" cat-file blob "$object_id" \
                > "$destination" || die 'cannot materialize a component blob'
            actual_oid=$(bound_git --git-dir="$component_git_dir" \
                hash-object --no-filters "$destination") \
                || die 'cannot verify a materialized component blob'
            [[ "$actual_oid" == "$object_id" ]] \
                || die 'materialized component bytes differ from the gitlink object'
            if [[ "$object_mode" == 100755 ]]; then
                chmod 0555 "$destination" || die 'cannot restrict an executable input'
            else
                chmod 0444 "$destination" || die 'cannot restrict a regular input'
            fi
            ;;
        120000)
            link_blob="$private_root/link-target"
            bound_git --git-dir="$component_git_dir" cat-file blob "$object_id" \
                > "$link_blob" || die 'cannot materialize a symlink target'
            actual_oid=$(bound_git --git-dir="$component_git_dir" \
                hash-object --no-filters "$link_blob") \
                || die 'cannot verify a materialized symlink target'
            [[ "$actual_oid" == "$object_id" ]] \
                || die 'materialized symlink bytes differ from the gitlink object'
            if ! guarded_python materialize-link "$link_blob" \
                "$destination" "$relative"; then
                exit 1
            fi
            /bin/rm -f -- "$link_blob" \
                || die 'cannot unlink the verified symlink blob'
            ;;
        *) die "unsupported tracked mode in component tree: $object_mode" ;;
    esac
    snapshot_paths+=("$relative")
    snapshot_modes+=("$object_mode")
    snapshot_oids+=("$object_id")
done < "$tree_inventory"
[[ "$(path_inode "/dev/fd/$tree_inventory_fd")" == \
    "$tree_inventory_fd_inode" ]] \
    || die 'bound component-tree inventory identity changed'
/bin/rm -f -- "$tree_inventory" \
    || die 'cannot unlink the component-tree inventory name'
[[ ${#snapshot_paths[@]} -gt 0 ]] || die 'component gitlink tree is empty'
for index in "${!snapshot_paths[@]}"; do
    if [[ "${snapshot_modes[$index]}" == 120000 \
        && ! -e "$snapshot/${snapshot_paths[$index]}" ]]; then
        die 'component tree contains a dangling tracked symlink'
    fi
done

source_root="$snapshot"
[[ -z "$source_subdir" ]] || source_root="$snapshot/$source_subdir"
[[ -f "$source_root/CMakeLists.txt" && ! -L "$source_root/CMakeLists.txt" ]] \
    || die 'the exact component tree lacks a direct CMakeLists.txt'
if [[ -n "$conan_profile" ]]; then
    [[ -f "$snapshot/$conan_profile" && ! -L "$snapshot/$conan_profile" ]] \
        || die "the exact component tree lacks $conan_profile"
    if [[ ! -f "$snapshot/conanfile.py" && ! -f "$snapshot/conanfile.txt" ]]; then
        die 'the exact component tree lacks a Conan manifest'
    fi
fi

# chmod is defense in depth and makes accidental mutation obvious. Landlock,
# installed for every build stage below, is the enforcement boundary.
while IFS= read -r -d '' directory; do
    chmod 0555 "$directory" || die 'cannot restrict a snapshot directory'
done < <(/usr/bin/find "$snapshot" -type d -print0)

snapshot_fd=5
exec 5<"$snapshot" || die 'cannot bind the source snapshot'
snapshot_state=$(path_state "$snapshot") || die 'cannot read the snapshot identity'
snapshot_device=$(path_device "$snapshot") || die 'cannot read the snapshot device'
snapshot_inode=$(path_inode "$snapshot") || die 'cannot read the snapshot inode'
snapshot_fd_inode=$(path_inode "/dev/fd/$snapshot_fd") \
    || die 'cannot read the bound snapshot identity'
snapshot_exec=$snapshot
if [[ -d "/proc/self/fd/$snapshot_fd" ]] \
    && (cd "/proc/self/fd/$snapshot_fd" 2>/dev/null); then
    snapshot_exec="/proc/self/fd/$snapshot_fd"
elif [[ -d "/dev/fd/$snapshot_fd" ]] \
    && (cd "/dev/fd/$snapshot_fd" 2>/dev/null); then
    snapshot_exec="/dev/fd/$snapshot_fd"
fi
source_exec=$snapshot_exec
[[ -z "$source_subdir" ]] || source_exec="$snapshot_exec/$source_subdir"

snapshot_is_current() {
    local index current_oid current_mode relative destination actual_path
    local expected=false actual_count=0 expected_count
    [[ -d "$snapshot" && ! -L "$snapshot" \
        && "$(path_state "$snapshot")" == "$snapshot_state" \
        && "$(path_inode "/dev/fd/$snapshot_fd")" == \
            "$snapshot_fd_inode" ]] || return 1
    for index in "${!snapshot_paths[@]}"; do
        relative=${snapshot_paths[$index]}
        destination="$snapshot/$relative"
        case "${snapshot_modes[$index]}" in
            100644|100755)
                [[ -f "$destination" && ! -L "$destination" ]] || return 1
                current_mode=$(file_mode "$destination") || return 1
                if [[ "${snapshot_modes[$index]}" == 100755 ]]; then
                    [[ "$current_mode" == 555 ]] || return 1
                else
                    [[ "$current_mode" == 444 ]] || return 1
                fi
                current_oid=$(bound_git --git-dir="$component_git_dir" \
                    hash-object --no-filters "$destination") \
                    || return 1
                [[ "$current_oid" == "${snapshot_oids[$index]}" ]] || return 1
                ;;
            120000)
                [[ -L "$destination" ]] || return 1
                current_oid=$(guarded_python readlink "$destination" \
                    | bound_git --git-dir="$component_git_dir" \
                        hash-object --stdin) || return 1
                [[ "$current_oid" == "${snapshot_oids[$index]}" ]] || return 1
                ;;
            *) return 1 ;;
        esac
    done
    if [[ ${#snapshot_directories[@]} -gt 0 ]]; then
        for relative in "${snapshot_directories[@]}"; do
            destination="$snapshot/$relative"
            [[ -d "$destination" && ! -L "$destination" ]] || return 1
            current_mode=$(file_mode "$destination") || return 1
            [[ "$current_mode" == 555 ]] || return 1
        done
    fi
    while IFS= read -r -d '' actual_path; do
        relative=${actual_path#"$snapshot/"}
        [[ "$relative" != "$actual_path" ]] || return 1
        expected=false
        for index in "${!snapshot_paths[@]}"; do
            if [[ "${snapshot_paths[$index]}" == "$relative" ]]; then
                expected=true
                break
            fi
        done
        if ! $expected && [[ ${#snapshot_directories[@]} -gt 0 ]]; then
            for destination in "${snapshot_directories[@]}"; do
                if [[ "$destination" == "$relative" ]]; then
                    expected=true
                    break
                fi
            done
        fi
        $expected || return 1
        actual_count=$((actual_count + 1))
    done < <(/usr/bin/find "$snapshot" -mindepth 1 -print0)
    expected_count=$((${#snapshot_paths[@]} + ${#snapshot_directories[@]}))
    [[ "$actual_count" -eq "$expected_count" ]]
}

record_direct_build_directory() {
    local directory=$1 state
    if [[ -e "$directory" || -L "$directory" ]]; then
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
    else
        mkdir -- "$directory" || return 1
        [[ -d "$directory" && ! -L "$directory" ]] || return 1
    fi
    state=$(path_state "$directory") || return 1
    build_ancestor_paths+=("$directory")
    build_ancestor_states+=("$state")
}

build_output_is_current() {
    local index state
    [[ -n "$build_root_fd" ]] || return 1
    for index in "${!build_ancestor_paths[@]}"; do
        [[ -d "${build_ancestor_paths[$index]}" \
            && ! -L "${build_ancestor_paths[$index]}" ]] || return 1
        state=$(path_state "${build_ancestor_paths[$index]}") || return 1
        [[ "$state" == "${build_ancestor_states[$index]}" ]] || return 1
    done
    [[ "$(path_inode "/dev/fd/$build_root_fd")" == \
        "$build_root_fd_inode" \
        && "$build_root_fd_inode" == "$build_root_recorded_inode" ]]
}

bounded_pixi() {
    if ! snapshot_is_current; then
        printf '%s\n' 'ERROR: component source inventory changed before build stage' >&2
        return 90
    fi
    if ! build_output_is_current; then
        printf '%s\n' 'ERROR: private component build output changed before build stage' >&2
        return 91
    fi
    if [[ "$(path_inode "/dev/fd/$run_bounded_fd")" != \
        "$run_bounded_fd_inode" ]]; then
        printf '%s\n' 'ERROR: bound resource helper identity changed' >&2
        return 125
    fi
    if [[ "$(path_inode "/dev/fd/$pixi_fd")" != "$pixi_fd_inode" ]]; then
        printf '%s\n' 'ERROR: bound pixi executable identity changed' >&2
        return 125
    fi
    if [[ "$(path_inode "/dev/fd/$tree_inventory_fd")" != \
        "$tree_inventory_fd_inode" ]]; then
        printf '%s\n' 'ERROR: bound component-tree inventory identity changed' >&2
        return 125
    fi
    if [[ "$(path_inode "/dev/fd/$tool_state_fd")" != \
        "$tool_state_fd_inode" ]]; then
        printf '%s\n' 'ERROR: bound build-tool state identity changed' >&2
        return 125
    fi
    if [[ "$(path_state "$bash_path")" != "$bash_state" ]]; then
        printf '%s\n' 'ERROR: bound Bash executable identity changed' >&2
        return 125
    fi
    if [[ "$(path_state "$env_path")" != "$env_state" ]]; then
        printf '%s\n' 'ERROR: bound env executable identity changed' >&2
        return 125
    fi
    "$env_path" -i \
        HOME="$tool_home_exec" \
        XDG_CACHE_HOME="$tool_cache_exec" \
        XDG_CONFIG_HOME="$tool_config_exec" \
        TMPDIR="$tool_tmp_exec" \
        LC_ALL=C \
        LANG=C \
        PATH=/usr/bin:/bin \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        GIT_NO_REPLACE_OBJECTS=1 \
        GIT_NO_LAZY_FETCH=1 \
        GIT_CEILING_DIRECTORIES="$private_root" \
        PIXI_HOME="$pixi_home_exec" \
        PIXI_CACHE_DIR="$pixi_cache_exec" \
        PIXI_CONFIG_FILE="$pixi_config_exec" \
        RUN_BOUNDED_VMEM_KB="$build_vmem_kb" \
        CMAKE_BUILD_PARALLEL_LEVEL="$build_jobs" \
        "$bash_path" -p "/dev/fd/$run_bounded_fd" \
        "$python_path" -I -S - \
        "$snapshot" "$snapshot_device" "$snapshot_inode" \
        "$tree_inventory_oid" \
        "$build_stage_device" "$build_stage_inode" \
        "$tool_state_device" "$tool_state_inode" \
        "$pixi_digest" -- \
        "$pixi_exec" "$@" <<'PY'
import ctypes
import fcntl
import hashlib
import os
import stat
import sys


def fail(message):
    print(f"ERROR: {message}", file=sys.stderr)
    raise SystemExit(78)


def git_blob_hasher(size, oid_length):
    if oid_length == 40:
        value = hashlib.sha1()
    elif oid_length == 64:
        value = hashlib.sha256()
    else:
        fail("component-tree inventory contains a malformed object identity")
    value.update(b"blob " + str(size).encode("ascii") + b"\0")
    return value


def git_blob_oid(payload, oid_length):
    value = git_blob_hasher(len(payload), oid_length)
    value.update(payload)
    return value.hexdigest()


def read_all(descriptor):
    os.lseek(descriptor, 0, os.SEEK_SET)
    chunks = []
    while True:
        chunk = os.read(descriptor, 1024 * 1024)
        if not chunk:
            return b"".join(chunks)
        chunks.append(chunk)


def parse_inventory(payload, expected_oid):
    if git_blob_oid(payload, len(expected_oid)) != expected_oid:
        fail("bound component-tree inventory bytes changed")
    records = payload.split(b"\0")
    if not records or records[-1] != b"":
        fail("component-tree inventory is not NUL terminated")
    entries = {}
    directories = set()
    for record in records[:-1]:
        try:
            header, path = record.split(b"\t", 1)
            mode, object_type, oid = header.split(b" ")
        except ValueError:
            fail("component-tree inventory contains a malformed entry")
        if (
            mode not in (b"100644", b"100755", b"120000")
            or object_type != b"blob"
            or len(oid) not in (40, 64)
        ):
            fail("component-tree inventory contains an unsupported entry")
        try:
            oid_text = oid.decode("ascii")
        except UnicodeDecodeError:
            fail("component-tree inventory contains a malformed object identity")
        if any(character not in "0123456789abcdef" for character in oid_text):
            fail("component-tree inventory contains a malformed object identity")
        parts = path.split(b"/")
        if not path or path.startswith(b"/") or any(
            part in (b"", b".", b"..") for part in parts
        ):
            fail("component-tree inventory contains a non-canonical path")
        if path in entries:
            fail("component-tree inventory contains a duplicate path")
        entries[path] = (mode, oid_text)
        for count in range(1, len(parts)):
            directories.add(b"/".join(parts[:count]))
    if not entries:
        fail("component-tree inventory is empty")
    if set(entries).intersection(directories):
        fail("component-tree inventory contains a path collision")
    return entries, directories


def open_relative_directory(root_fd, relative, create=False):
    descriptor = os.dup(root_fd)
    try:
        for part in relative.split(b"/") if relative else ():
            if create:
                try:
                    os.mkdir(part, 0o700, dir_fd=descriptor)
                except FileExistsError:
                    pass
            flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
            flags |= getattr(os, "O_NOFOLLOW", 0)
            child = os.open(part, flags, dir_fd=descriptor)
            value = os.fstat(child)
            if not stat.S_ISDIR(value.st_mode):
                os.close(child)
                fail("sealed source contains a non-directory path component")
            os.close(descriptor)
            descriptor = child
        return descriptor
    except BaseException:
        os.close(descriptor)
        raise


def validate_symlink_target(target, relative):
    if b"\0" in target or not target or target.startswith(b"/"):
        fail("component tree contains an escaping symlink")
    parts = list(relative.split(b"/")[:-1])
    for part in target.split(b"/"):
        if part in (b"", b"."):
            continue
        if part == b"..":
            if not parts:
                fail("component tree contains an escaping symlink")
            parts.pop()
        else:
            parts.append(part)


def copy_regular(source_parent, name, relative, initial, specification, target_root):
    mode, expected_oid = specification
    flags = os.O_RDONLY | os.O_CLOEXEC | getattr(os, "O_NOFOLLOW", 0)
    source = os.open(name, flags, dir_fd=source_parent)
    target_parent = None
    target = None
    try:
        opened = os.fstat(source)
        expected_mode = 0o555 if mode == b"100755" else 0o444
        if (
            not stat.S_ISREG(opened.st_mode)
            or opened.st_dev != initial.st_dev
            or opened.st_ino != initial.st_ino
            or stat.S_IMODE(opened.st_mode) != expected_mode
        ):
            fail("component source file identity or mode changed while sealing")
        if target_root is not None:
            parent, leaf = relative.rsplit(b"/", 1) if b"/" in relative else (b"", relative)
            target_parent = open_relative_directory(target_root, parent)
            target_flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_CLOEXEC
            target_flags |= getattr(os, "O_NOFOLLOW", 0)
            target = os.open(leaf, target_flags, 0o600, dir_fd=target_parent)
        digest = git_blob_hasher(opened.st_size, len(expected_oid))
        size = 0
        while True:
            chunk = os.read(source, 1024 * 1024)
            if not chunk:
                break
            size += len(chunk)
            digest.update(chunk)
            if target is not None:
                view = memoryview(chunk)
                while view:
                    written = os.write(target, view)
                    if written <= 0:
                        fail("cannot write the sealed source copy")
                    view = view[written:]
        final = os.fstat(source)
        if (
            size != opened.st_size
            or final.st_dev != opened.st_dev
            or final.st_ino != opened.st_ino
            or final.st_size != opened.st_size
            or stat.S_IMODE(final.st_mode) != expected_mode
            or digest.hexdigest() != expected_oid
        ):
            fail("component source file bytes changed while sealing")
        if target is not None:
            os.fchmod(target, expected_mode)
            os.fsync(target)
    finally:
        if target is not None:
            os.close(target)
        if target_parent is not None:
            os.close(target_parent)
        os.close(source)


def verify_tree(root_fd, entries, directories, target_root=None):
    root = os.fstat(root_fd)
    if not stat.S_ISDIR(root.st_mode) or stat.S_IMODE(root.st_mode) != 0o555:
        fail("component source root identity or mode changed while sealing")
    seen_entries = set()
    seen_directories = set()

    def visit(directory_fd, prefix):
        try:
            names = sorted(os.fsencode(name) for name in os.listdir(directory_fd))
        except OSError as error:
            fail(f"cannot enumerate component source while sealing: {error.strerror}")
        for name in names:
            relative = prefix + b"/" + name if prefix else name
            try:
                initial = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
            except OSError as error:
                fail(f"cannot inspect component source while sealing: {error.strerror}")
            if stat.S_ISDIR(initial.st_mode):
                if relative not in directories or stat.S_IMODE(initial.st_mode) != 0o555:
                    fail("component source contains an unexpected directory")
                flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
                flags |= getattr(os, "O_NOFOLLOW", 0)
                child = os.open(name, flags, dir_fd=directory_fd)
                try:
                    opened = os.fstat(child)
                    if opened.st_dev != initial.st_dev or opened.st_ino != initial.st_ino:
                        fail("component source directory changed while sealing")
                    seen_directories.add(relative)
                    visit(child, relative)
                finally:
                    os.close(child)
                continue
            specification = entries.get(relative)
            if specification is None:
                fail("component source contains an unexpected entry")
            mode, expected_oid = specification
            if stat.S_ISREG(initial.st_mode) and mode in (b"100644", b"100755"):
                copy_regular(
                    directory_fd,
                    name,
                    relative,
                    initial,
                    specification,
                    target_root,
                )
            elif stat.S_ISLNK(initial.st_mode) and mode == b"120000":
                target = os.readlink(name, dir_fd=directory_fd)
                if isinstance(target, str):
                    target = os.fsencode(target)
                final = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                if final.st_dev != initial.st_dev or final.st_ino != initial.st_ino:
                    fail("component source symlink changed while sealing")
                validate_symlink_target(target, relative)
                if git_blob_oid(target, len(expected_oid)) != expected_oid:
                    fail("component source symlink bytes changed while sealing")
                if target_root is not None:
                    parent, leaf = (
                        relative.rsplit(b"/", 1)
                        if b"/" in relative
                        else (b"", relative)
                    )
                    target_parent = open_relative_directory(target_root, parent)
                    try:
                        os.symlink(target, leaf, dir_fd=target_parent)
                    finally:
                        os.close(target_parent)
            else:
                fail("component source entry type or mode changed while sealing")
            seen_entries.add(relative)

    visit(root_fd, b"")
    if seen_entries != set(entries) or seen_directories != directories:
        fail("component source inventory changed while sealing")


def prepare_target_directories(root_fd, directories):
    for relative in sorted(directories, key=lambda value: (value.count(b"/"), value)):
        descriptor = open_relative_directory(root_fd, relative, create=True)
        os.close(descriptor)


def restrict_target_modes(root_fd, directories):
    for relative in sorted(
        directories, key=lambda value: (value.count(b"/"), value), reverse=True
    ):
        descriptor = open_relative_directory(root_fd, relative)
        try:
            os.fchmod(descriptor, 0o555)
        finally:
            os.close(descriptor)
    os.fchmod(root_fd, 0o555)


def require_directory(descriptor, device, inode, label):
    try:
        value = os.fstat(descriptor)
    except OSError as error:
        fail(f"cannot inspect {label}: {error.strerror}")
    if (
        not stat.S_ISDIR(value.st_mode)
        or value.st_dev != device
        or value.st_ino != inode
    ):
        fail(f"{label} identity changed before enforcement")


if not sys.platform.startswith("linux"):
    fail("OS-enforced read-only source boundary requires Linux Landlock ABI 3 or newer")
try:
    separator = sys.argv.index("--")
except ValueError:
    fail("internal Landlock invocation is malformed")
if separator != 10:
    fail("internal Landlock invocation is malformed")
source_path = sys.argv[1]
source_device = int(sys.argv[2])
source_inode = int(sys.argv[3])
inventory_oid = sys.argv[4]
build_device = int(sys.argv[5])
build_inode = int(sys.argv[6])
tool_device = int(sys.argv[7])
tool_inode = int(sys.argv[8])
pixi_digest = sys.argv[9]
command = sys.argv[separator + 1 :]
if command[0] != "/proc/self/fd/8":
    fail("internal Landlock invocation is malformed")

required_seals = (
    fcntl.F_SEAL_SHRINK
    | fcntl.F_SEAL_GROW
    | fcntl.F_SEAL_WRITE
    | fcntl.F_SEAL_SEAL
)
try:
    pixi_value = os.fstat(8)
    pixi_seals = fcntl.fcntl(8, fcntl.F_GET_SEALS)
except OSError as error:
    fail(f"cannot inspect the sealed pixi executable: {error.strerror}")
if (
    not stat.S_ISREG(pixi_value.st_mode)
    or not pixi_value.st_mode & 0o111
    or pixi_seals & required_seals != required_seals
):
    fail("sealed pixi executable identity changed before enforcement")
pixi_hash = hashlib.sha256()
pixi_offset = 0
while pixi_offset < pixi_value.st_size:
    data = os.pread(8, min(64 * 1024, pixi_value.st_size - pixi_offset), pixi_offset)
    if not data:
        break
    pixi_hash.update(data)
    pixi_offset += len(data)
if pixi_offset != pixi_value.st_size or pixi_hash.hexdigest() != pixi_digest:
    fail("sealed pixi executable content changed before enforcement")

require_directory(5, source_device, source_inode, "exact source snapshot")
require_directory(3, build_device, build_inode, "private component build output")
require_directory(10, tool_device, tool_inode, "isolated build-tool state")
try:
    manifest_value = os.fstat(4)
except OSError as error:
    fail(f"cannot inspect the bound component-tree inventory: {error.strerror}")
if not stat.S_ISREG(manifest_value.st_mode):
    fail("bound component-tree inventory is not a regular file")
entries, directories = parse_inventory(read_all(4), inventory_oid)

libc = ctypes.CDLL(None, use_errno=True)
source_before = os.stat(source_path, follow_symlinks=False)
if (
    not os.path.isdir(source_path)
    or source_before.st_dev != source_device
    or source_before.st_ino != source_inode
):
    fail("exact source snapshot identity changed before mount enforcement")

# Establish a private mount namespace. A namespace-private tmpfs copy becomes
# the exact source object used by the selected tool. The copy is reconstructed
# and verified against the immutable Git inventory, then remounted read-only.
# A process in the parent namespace therefore has no alias to its inodes.
outer_uid = os.getuid()
outer_gid = os.getgid()
clone_newns = 0x00020000
clone_newuser = 0x10000000
if libc.unshare(clone_newuser | clone_newns) != 0:
    error = ctypes.get_errno()
    fail(f"cannot create the read-only source mount namespace: {os.strerror(error)}")
try:
    with open("/proc/self/setgroups", "w", encoding="ascii") as stream:
        stream.write("deny\n")
except FileNotFoundError:
    pass
except OSError as error:
    fail(f"cannot restrict namespace group mapping: {error.strerror}")
try:
    with open("/proc/self/uid_map", "w", encoding="ascii") as stream:
        stream.write(f"{outer_uid} {outer_uid} 1\n")
    with open("/proc/self/gid_map", "w", encoding="ascii") as stream:
        stream.write(f"{outer_gid} {outer_gid} 1\n")
except OSError as error:
    fail(f"cannot establish the source-mount identity map: {error.strerror}")

mount = libc.mount
mount.argtypes = [
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_char_p,
    ctypes.c_ulong,
    ctypes.c_void_p,
]
mount.restype = ctypes.c_int
source_bytes = os.fsencode(source_path)
ms_nosuid = 2
ms_nodev = 4
ms_rec = 16384
ms_private = 1 << 18
if mount(None, b"/", None, ms_rec | ms_private, None) != 0:
    error = ctypes.get_errno()
    fail(f"cannot privatize the source mount namespace: {os.strerror(error)}")
if mount(
    b"tmpfs",
    source_bytes,
    b"tmpfs",
    ms_nosuid | ms_nodev,
    ctypes.c_char_p(b"mode=0700"),
) != 0:
    error = ctypes.get_errno()
    fail(f"cannot create an alias-free source snapshot: {os.strerror(error)}")

source_flags = os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC
source_flags |= getattr(os, "O_NOFOLLOW", 0)
sealed_source_fd = os.open(source_path, source_flags)
try:
    prepare_target_directories(sealed_source_fd, directories)
    verify_tree(5, entries, directories, sealed_source_fd)
    restrict_target_modes(sealed_source_fd, directories)
finally:
    os.close(sealed_source_fd)

class MountAttributes(ctypes.Structure):
    _fields_ = [
        ("attr_set", ctypes.c_uint64),
        ("attr_clr", ctypes.c_uint64),
        ("propagation", ctypes.c_uint64),
        ("userns_fd", ctypes.c_uint64),
    ]


mount_attributes = MountAttributes(1 | 2 | 4, 0, 0, 0)
if libc.syscall(
    442,
    -100,
    source_bytes,
    0,
    ctypes.byref(mount_attributes),
    ctypes.sizeof(mount_attributes),
) != 0:
    error = ctypes.get_errno()
    fail(f"cannot enforce the read-only source snapshot: {os.strerror(error)}")
if not (os.statvfs(source_path).f_flag & os.ST_RDONLY):
    fail("read-only source mount did not report its enforced state")

# Revalidate every path, type, mode, symlink target, and blob identity after
# the alias-free source has been sealed read-only. Then replace descriptor 5
# with the only source object that build tools may observe.
mounted_source_fd = os.open(source_path, source_flags)
try:
    verify_tree(mounted_source_fd, entries, directories)
    os.fchdir(mounted_source_fd)
    os.dup2(mounted_source_fd, 5, inheritable=True)
finally:
    os.close(mounted_source_fd)
os.close(4)

# Prevent remounting or otherwise escaping the namespace boundary before the
# untrusted build command is executed.
if libc.prctl(28, 47, 0, 0, 0) != 0:
    error = ctypes.get_errno()
    fail(f"cannot lock namespace securebits: {os.strerror(error)}")
for capability in range(64):
    if libc.prctl(24, capability, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        if error not in (22,):
            fail(f"cannot drop a namespace capability: {os.strerror(error)}")
if libc.prctl(47, 4, 0, 0, 0) != 0:
    error = ctypes.get_errno()
    if error not in (22,):
        fail(f"cannot clear ambient capabilities: {os.strerror(error)}")


class CapabilityHeader(ctypes.Structure):
    _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]


class CapabilityData(ctypes.Structure):
    _fields_ = [
        ("effective", ctypes.c_uint32),
        ("permitted", ctypes.c_uint32),
        ("inheritable", ctypes.c_uint32),
    ]


capability_header = CapabilityHeader(0x20080522, 0)
capability_data = (CapabilityData * 2)()
if libc.capset(ctypes.byref(capability_header), ctypes.byref(capability_data)) != 0:
    error = ctypes.get_errno()
    fail(f"cannot clear namespace capabilities: {os.strerror(error)}")
capability_fields = {"CapEff", "CapPrm", "CapBnd", "CapAmb"}
observed_capabilities = {}
try:
    with open("/proc/self/status", "r", encoding="ascii") as stream:
        for line in stream:
            name, separator_text, value = line.partition(":")
            if separator_text and name in capability_fields:
                observed_capabilities[name] = int(value.strip(), 16)
except (OSError, ValueError) as error:
    fail(f"cannot verify cleared namespace capabilities: {error}")
if set(observed_capabilities) != capability_fields or any(
    observed_capabilities.values()
):
    fail("namespace capabilities remain after source mount enforcement")

create_ruleset = 444
add_rule = 445
restrict_self = 446
version = libc.syscall(create_ruleset, 0, 0, 1)
if version < 3:
    fail("OS-enforced read-only source boundary requires Linux Landlock ABI 3 or newer")

handled = sum(1 << bit for bit in (1, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14))


class Ruleset(ctypes.Structure):
    _fields_ = [("handled_access_fs", ctypes.c_uint64)]


class PathBeneath(ctypes.Structure):
    _fields_ = [
        ("allowed_access", ctypes.c_uint64),
        ("parent_fd", ctypes.c_int32),
        ("reserved", ctypes.c_uint32),
    ]


ruleset = Ruleset(handled)
ruleset_fd = libc.syscall(
    create_ruleset, ctypes.byref(ruleset), ctypes.sizeof(ruleset), 0
)
if ruleset_fd < 0:
    error = ctypes.get_errno()
    fail(f"cannot create the Landlock source boundary: {os.strerror(error)}")
try:
    for descriptor in (3, 10):
        rule = PathBeneath(handled, descriptor, 0)
        if libc.syscall(add_rule, ruleset_fd, 1, ctypes.byref(rule), 0) != 0:
            error = ctypes.get_errno()
            fail(f"cannot add a Landlock writable object: {os.strerror(error)}")
    null_flags = getattr(os, "O_PATH", os.O_RDONLY) | os.O_CLOEXEC
    null_flags |= getattr(os, "O_NOFOLLOW", 0)
    null_fd = os.open("/dev/null", null_flags)
    try:
        null_value = os.fstat(null_fd)
        if (
            not stat.S_ISCHR(null_value.st_mode)
            or os.major(null_value.st_rdev) != 1
            or os.minor(null_value.st_rdev) != 3
        ):
            fail("/dev/null is not the kernel null character device")
        null_rule = PathBeneath((1 << 1) | (1 << 14), null_fd, 0)
        if libc.syscall(
            add_rule, ruleset_fd, 1, ctypes.byref(null_rule), 0
        ) != 0:
            error = ctypes.get_errno()
            fail(f"cannot allow the null device: {os.strerror(error)}")
    finally:
        os.close(null_fd)
    if libc.prctl(38, 1, 0, 0, 0) != 0:
        error = ctypes.get_errno()
        fail(f"cannot enable no-new-privileges: {os.strerror(error)}")
    if libc.syscall(restrict_self, ruleset_fd, 0) != 0:
        error = ctypes.get_errno()
        fail(f"cannot install the Landlock source boundary: {os.strerror(error)}")
finally:
    os.close(ruleset_fd)

names = (
    "HOME",
    "XDG_CACHE_HOME",
    "XDG_CONFIG_HOME",
    "TMPDIR",
    "LC_ALL",
    "LANG",
    "PATH",
    "RUN_BOUNDED_VMEM_KB",
    "CMAKE_BUILD_PARALLEL_LEVEL",
    "GIT_CONFIG_GLOBAL",
    "GIT_CONFIG_NOSYSTEM",
    "GIT_NO_REPLACE_OBJECTS",
    "GIT_NO_LAZY_FETCH",
    "GIT_CEILING_DIRECTORIES",
    "PIXI_HOME",
    "PIXI_CACHE_DIR",
    "PIXI_CONFIG_FILE",
)
environment = {name: os.environ[name] for name in names if name in os.environ}

# Landlock does not revoke write authority held by descriptors opened before
# restriction. Keep only standard streams and the four exact read/directory
# capabilities that the selected build tool needs.
kept_descriptors = {0, 1, 2, 3, 5, 8, 10}
try:
    inherited_descriptors = [int(value) for value in os.listdir("/proc/self/fd")]
except (OSError, ValueError) as error:
    fail(f"cannot enumerate inherited descriptors: {error}")
for descriptor in inherited_descriptors:
    if descriptor not in kept_descriptors:
        try:
            os.close(descriptor)
        except OSError:
            pass
for descriptor in kept_descriptors:
    try:
        os.fstat(descriptor)
        os.set_inheritable(descriptor, True)
    except OSError as error:
        fail(f"required descriptor {descriptor} is unavailable: {error.strerror}")
for descriptor in (3, 5, 8, 10):
    if fcntl.fcntl(descriptor, fcntl.F_GETFL) & os.O_ACCMODE != os.O_RDONLY:
        fail(f"required descriptor {descriptor} is writable")
try:
    remaining_descriptors = [int(value) for value in os.listdir("/proc/self/fd")]
except (OSError, ValueError) as error:
    fail(f"cannot verify inherited descriptor closure: {error}")
for descriptor in remaining_descriptors:
    if descriptor in kept_descriptors:
        continue
    try:
        os.fstat(descriptor)
    except OSError:
        continue
    fail(f"unexpected inherited descriptor {descriptor} remains open")
os.execve(command[0], command, environment)
PY
}

run_stage() {
    local label=$1 status
    shift
    external_stage_started=true
    set +e
    (
        cd "$snapshot_exec" || exit 126
        bounded_pixi "$@"
    )
    status=$?
    set -e
    if [[ "$status" -ne 0 ]]; then
        printf 'ERROR: %s failed with status %d\n' "$label" "$status" >&2
        return 1
    fi
    if ! snapshot_is_current; then
        printf 'ERROR: component source inventory changed during %s\n' "$label" >&2
        return 1
    fi
    if ! build_output_is_current; then
        printf 'ERROR: private component build output changed during %s\n' "$label" >&2
        return 1
    fi
}

tool_state="$private_root/tool-state"
tool_home="$tool_state/home"
tool_cache="$tool_state/cache"
tool_config="$tool_state/config"
tool_tmp="$tool_state/tmp"
pixi_home="$tool_state/pixi-home"
pixi_cache="$tool_state/pixi-cache"
pixi_environments="$tool_state/pixi-environments"
pixi_config="$tool_state/pixi-config.toml"
private_root_is_current || die 'private build workspace identity changed'
mkdir -p "$tool_home" "$tool_cache" "$tool_config" "$tool_tmp" \
    "$pixi_home" "$pixi_cache" "$pixi_environments" \
    || die 'cannot create isolated build-tool state'
tool_state_device=$(path_device "$tool_state") \
    || die 'cannot read the isolated build-tool state device'
tool_state_inode=$(path_inode "$tool_state") \
    || die 'cannot read the isolated build-tool state identity'
tool_state_fd=10
exec 10<"$tool_state" || die 'cannot bind the isolated build-tool state'
tool_state_fd_inode=$(path_inode "/dev/fd/$tool_state_fd") \
    || die 'cannot read the bound build-tool state identity'
[[ "$tool_state_fd_inode" == "$tool_state_inode" ]] \
    || die 'isolated build-tool state changed while binding'
tool_state_exec=$tool_state
if [[ -d "/proc/self/fd/$tool_state_fd" ]] \
    && (cd "/proc/self/fd/$tool_state_fd" 2>/dev/null); then
    tool_state_exec="/proc/self/fd/$tool_state_fd"
elif [[ -d "/dev/fd/$tool_state_fd" ]] \
    && (cd "/dev/fd/$tool_state_fd" 2>/dev/null); then
    tool_state_exec="/dev/fd/$tool_state_fd"
fi
tool_home_exec="$tool_state_exec/home"
tool_cache_exec="$tool_state_exec/cache"
tool_config_exec="$tool_state_exec/config"
tool_tmp_exec="$tool_state_exec/tmp"
pixi_home_exec="$tool_state_exec/pixi-home"
pixi_cache_exec="$tool_state_exec/pixi-cache"
pixi_environments_exec="$tool_state_exec/pixi-environments"
pixi_config_exec="$tool_state_exec/pixi-config.toml"
guarded_python write-pixi-config "$pixi_config" "$pixi_environments_exec" \
    || die 'cannot create isolated Pixi configuration'

build_parent="$root/build"
record_direct_build_directory "$build_parent" \
    || die 'root build output must be a direct directory'
IFS=/ read -r -a build_parts <<< "$output_name"
last_build_index=$((${#build_parts[@]} - 1))
for build_index in "${!build_parts[@]}"; do
    build_part=${build_parts[$build_index]}
    [[ -n "$build_part" && "$build_part" != . && "$build_part" != .. ]] \
        || die 'component build output contains an invalid path segment'
    if [[ "$build_index" -lt "$last_build_index" ]]; then
        build_parent="$build_parent/$build_part"
        record_direct_build_directory "$build_parent" \
            || die 'component build output ancestors must be direct directories'
    fi
done
build_leaf=${build_parts[$last_build_index]}
canonical_build_root="$build_parent/$build_leaf"
[[ "$canonical_build_root" == "$root/build/$output_name" ]] \
    || die 'component build output escaped build/'
build_parent_device=$(path_device "$build_parent") \
    || die 'cannot read the component build-output parent device'
build_parent_inode=$(path_inode "$build_parent") \
    || die 'cannot read the component build-output parent identity'
stage_record=$(guarded_python make-stage "$build_parent" "$build_leaf" \
    "$build_parent_device" "$build_parent_inode") \
    || die 'cannot create a private component build output'
IFS=$'\t' read -r build_stage_name build_stage_device build_stage_inode \
    stage_extra <<< "$stage_record"
[[ "$build_stage_name" == ".${build_leaf}.odysseus-stage."* \
    && "$build_stage_name" != */* && -z "${stage_extra:-}" \
    && "$build_stage_device" =~ ^[0-9]+$ \
    && "$build_stage_inode" =~ ^[0-9]+$ ]] \
    || die 'private component build-output receipt is malformed'
build_stage="$build_parent/$build_stage_name"
build_root=$build_stage
build_root_recorded_inode=$build_stage_inode
build_root_fd=3
exec 3<"$build_root" || die 'cannot bind the private component build output'
build_root_fd_inode=$(path_inode "/dev/fd/$build_root_fd") \
    || die 'cannot read the bound component build-output identity'
build_output_is_current || die 'private component build output changed while binding'
build_root_exec=$build_root
if [[ -d "/proc/self/fd/$build_root_fd" ]] \
    && (cd "/proc/self/fd/$build_root_fd" 2>/dev/null); then
    build_root_exec="/proc/self/fd/$build_root_fd"
elif [[ -d "/dev/fd/$build_root_fd" ]] \
    && (cd "/dev/fd/$build_root_fd" 2>/dev/null); then
    build_root_exec="/dev/fd/$build_root_fd"
fi

if [[ -n "$conan_profile" ]]; then
    printf '%s\n' "--- Conan deps for $submodule_path ---"
    run_stage 'Conan install' run --frozen -- conan install . \
        --output-folder="$build_root_exec" \
        --profile="$conan_profile" \
        --build=missing || exit 1
    [[ -f "$build_root_exec/conan_toolchain.cmake" \
        && ! -L "$build_root_exec/conan_toolchain.cmake" ]] \
        || die 'Conan did not produce one direct toolchain file'
fi

printf '%s\n' "--- Building $submodule_path${source_subdir:+/$source_subdir} ---"
configure_args=(
    run --frozen -- cmake
    -S "$source_exec"
    -B "$build_root_exec"
    "-DCMAKE_BUILD_TYPE=$build_type"
    -G Ninja
)
if [[ -n "$conan_profile" ]]; then
    configure_args+=("-DCMAKE_TOOLCHAIN_FILE=$build_root_exec/conan_toolchain.cmake")
fi
[[ -z "$testing_flag" ]] || configure_args+=("$testing_flag")
if $export_commands; then
    configure_args+=(-DCMAKE_EXPORT_COMPILE_COMMANDS=ON)
fi
run_stage 'CMake configure' "${configure_args[@]}" || exit 1
run_stage 'CMake build' run --frozen -- cmake --build "$build_root_exec" \
    || exit 1

guarded_python publish "$build_parent" "$build_stage_name" "$build_leaf" \
    "$build_parent_device" "$build_parent_inode" \
    "$build_stage_device" "$build_stage_inode" \
    || die 'cannot publish the exact component build output'
build_stage_name=

trap - EXIT HUP INT TERM
cleanup
