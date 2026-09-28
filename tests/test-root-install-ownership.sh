#!/usr/bin/env bash
# Behavior tests for the privileged ownership-repair boundary.
set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP="$(cd "$(mktemp -d)" && pwd -P)"
REAL_USER="$(id -un)"
SAFE_PATH="/usr/bin:/bin:/usr/sbin:/sbin"
PRIVILEGED_TMP=""
MOUNT_TARGET=""
MOUNT_SOURCE=""

run_as_root() {
    if [[ "$(id -u)" -eq 0 ]]; then
        "$@"
    else
        sudo -n -- "$@"
    fi
}

_cleanup_unmount_path() {
    run_as_root "${UMOUNT_BIN:-/bin/umount}" "$1"
}

_cleanup_remove_root_path() {
    run_as_root /bin/rm -rf -- "$1"
}

_cleanup_remove_user_path() {
    /bin/rm -rf -- "$1"
}

_cleanup_make_writable() {
    /bin/chmod -R u+rwx "$1"
}

_cleanup_attempt() {
    local description="$1"
    local step_status
    shift

    if "$@"; then
        return 0
    else
        step_status=$?
    fi
    printf 'cleanup failed (%s): status %s\n' \
        "$description" "$step_status" >&2
    return 1
}

cleanup() {
    local trapped_status=$?
    local incoming_status="${1:-$trapped_status}"
    local cleanup_failed=0
    local unmount_action root_remove_action user_remove_action chmod_action

    trap - EXIT
    unmount_action="${CLEANUP_UNMOUNT_ACTION:-_cleanup_unmount_path}"
    root_remove_action="${CLEANUP_ROOT_REMOVE_ACTION:-${CLEANUP_REMOVE_ACTION:-_cleanup_remove_root_path}}"
    user_remove_action="${CLEANUP_USER_REMOVE_ACTION:-${CLEANUP_REMOVE_ACTION:-_cleanup_remove_user_path}}"
    chmod_action="${CLEANUP_CHMOD_ACTION:-_cleanup_make_writable}"

    if [[ -n "$MOUNT_TARGET" ]]; then
        if _cleanup_attempt "unmount $MOUNT_TARGET" \
            "$unmount_action" "$MOUNT_TARGET"; then
            :
        else
            cleanup_failed=1
        fi
    fi
    if [[ -n "$MOUNT_SOURCE" && -e "$MOUNT_SOURCE" ]]; then
        if _cleanup_attempt "remove $MOUNT_SOURCE" \
            "$root_remove_action" "$MOUNT_SOURCE"; then
            :
        else
            cleanup_failed=1
        fi
    fi
    if [[ -n "$PRIVILEGED_TMP" && -e "$PRIVILEGED_TMP" ]]; then
        if _cleanup_attempt "remove $PRIVILEGED_TMP" \
            "$root_remove_action" "$PRIVILEGED_TMP"; then
            :
        else
            cleanup_failed=1
        fi
    fi
    if _cleanup_attempt "make writable $TMP" "$chmod_action" "$TMP"; then
        :
    else
        cleanup_failed=1
    fi
    if _cleanup_attempt "remove $TMP" "$user_remove_action" "$TMP"; then
        :
    else
        cleanup_failed=1
    fi

    if [[ "$incoming_status" -ne 0 ]]; then
        exit "$incoming_status"
    fi
    if [[ "$cleanup_failed" -ne 0 ]]; then
        exit 1
    fi
    exit 0
}
trap cleanup EXIT

capture_nonempty() {
    local destination="$1"
    local output
    local status
    shift

    if output="$("$@")"; then
        status=0
    else
        status=$?
    fi
    if [[ "$status" -ne 0 ]]; then
        echo "receipt command failed with status $status: $*" >&2
        return "$status"
    fi
    if [[ -z "$output" ]]; then
        echo "receipt command returned empty output: $*" >&2
        return 1
    fi
    printf -v "$destination" '%s' "$output"
}

capture_status() {
    local destination="$1"
    local status
    shift

    if "$@"; then
        status=0
    else
        status=$?
    fi
    printf -v "$destination" '%s' "$status"
}

tree_receipt() {
    python3 -I -S - "$1" <<'PY'
import hashlib
import os
from pathlib import Path
import stat
import sys

if len(sys.argv) != 2:
    raise SystemExit("tree_receipt requires exactly one path")
root = Path(sys.argv[1])
if not root.exists() and not root.is_symlink():
    raise SystemExit(f"tree_receipt path does not exist: {root}")
digest = hashlib.sha256()
for path in sorted([root, *root.rglob("*")], key=lambda item: str(item)):
    metadata = os.lstat(path)
    if stat.S_ISREG(metadata.st_mode):
        payload = path.read_bytes()
    elif stat.S_ISLNK(metadata.st_mode):
        payload = os.readlink(path).encode("utf-8", "surrogateescape")
    else:
        payload = b""
    digest.update(str(path.relative_to(root.parent)).encode("utf-8"))
    digest.update(b"\0")
    digest.update(str(metadata.st_mode).encode("ascii"))
    digest.update(b"\0")
    digest.update(str(metadata.st_uid).encode("ascii"))
    digest.update(b"\0")
    digest.update(str(metadata.st_gid).encode("ascii"))
    digest.update(b"\0")
    digest.update(str(metadata.st_nlink).encode("ascii"))
    digest.update(b"\0")
    digest.update(str(metadata.st_dev).encode("ascii"))
    digest.update(b"\0")
    digest.update(str(metadata.st_ino).encode("ascii"))
    digest.update(b"\0")
    digest.update(payload)
    digest.update(b"\0\0")
print(digest.hexdigest())
PY
}

root_path_receipt() {
    run_as_root /usr/bin/python3 -I -S - "$@" <<'PY'
import hashlib
import os
import stat
import sys

if len(sys.argv) < 2:
    raise SystemExit("root_path_receipt requires at least one path")
digest = hashlib.sha256()
for path in sys.argv[1:]:
    metadata = os.lstat(path)
    digest.update(os.fsencode(path))
    digest.update(b"\0")
    for value in (
        metadata.st_mode,
        metadata.st_uid,
        metadata.st_gid,
        metadata.st_nlink,
        metadata.st_dev,
        metadata.st_ino,
    ):
        digest.update(str(value).encode("ascii"))
        digest.update(b"\0")
    if stat.S_ISREG(metadata.st_mode):
        with open(path, "rb") as stream:
            digest.update(stream.read())
    elif stat.S_ISLNK(metadata.st_mode):
        digest.update(os.fsencode(os.readlink(path)))
    digest.update(b"\0\0")
print(digest.hexdigest())
PY
}

root_identity_receipt() {
    run_as_root /usr/bin/python3 -I -S - "$@" <<'PY'
import os
import sys

if len(sys.argv) < 2:
    raise SystemExit("root_identity_receipt requires at least one path")
for path in sys.argv[1:]:
    metadata = os.lstat(path)
    print(f"{path}\t{metadata.st_dev}:{metadata.st_ino}:{metadata.st_nlink}")
PY
}

run_root_install() {
    local home_dir="$1"
    HOME="$home_dir" \
        SUDO_USER="$REAL_USER" \
        ODYSSEUS_ROOT="$ROOT" \
        INSTALL=true \
        ROLE=all \
        PATH="$SAFE_PATH" \
        bash "$ROOT/scripts/install/root-install.sh" 10 20
}

run_root_install_privileged() {
    local home_dir="$1"
    local target_user="$2"

    run_as_root /usr/bin/env -i \
        HOME="$home_dir" \
        SUDO_USER="$target_user" \
        ODYSSEUS_ROOT="$ROOT" \
        INSTALL=true \
        ROLE=all \
        PATH="$SAFE_PATH" \
        /bin/bash "$ROOT/scripts/install/root-install.sh" 10 20
}

run_phase20_privileged() {
    local home_dir="$1"
    local target_user="$2"
    local fixture_root="$3"

    run_as_root /usr/bin/env -i \
        BASH_ENV=/dev/null \
        ENV=/dev/null \
        GITHUB_TOKEN=must-not-cross-phase-20 \
        HOME="$home_dir" \
        HTTPS_PROXY=http://untrusted.invalid:8443 \
        HTTP_PROXY=http://untrusted.invalid:8080 \
        NO_PROXY=untrusted.invalid \
        PHASE20_AMBIENT_SECRET=must-not-cross-phase-20 \
        SUDO_USER="$target_user" \
        TMPDIR="$fixture_root/untrusted-tmp" \
        ODYSSEUS_ROOT="$fixture_root" \
        INSTALL=true \
        ROLE=all \
        PATH="$SAFE_PATH:/untrusted/bin" \
        /bin/bash "$ROOT/scripts/install/root-install.sh" 10
}

can_run_linux_privileged_proof() {
    [[ "$(uname -s)" == Linux ]] || return 1
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    command -v sudo >/dev/null 2>&1 && sudo -n /usr/bin/true >/dev/null 2>&1
}

cleanup_fixture_unmount() {
    printf 'unmount:%s\n' "$1" >> "$CLEANUP_FIXTURE_LOG"
    return 41
}

cleanup_fixture_remove() {
    printf 'remove:%s\n' "$1" >> "$CLEANUP_FIXTURE_LOG"
    if [[ "$1" == "$CLEANUP_FIXTURE_REMOVE_FAILURE" ]]; then
        return 42
    fi
    return 0
}

cleanup_fixture_chmod() {
    printf 'chmod:%s\n' "$1" >> "$CLEANUP_FIXTURE_LOG"
    return 0
}

info "cleanup failures are surfaced without stopping later cleanup actions"
cleanup_contract_root="$TMP/cleanup-contract"
cleanup_contract_tmp="$cleanup_contract_root/tmp"
cleanup_contract_source="$cleanup_contract_root/fail-remove"
cleanup_contract_privileged="$cleanup_contract_root/privileged"
cleanup_contract_log="$cleanup_contract_root/actions.log"
cleanup_contract_stderr="$cleanup_contract_root/stderr"
mkdir -p \
    "$cleanup_contract_tmp" \
    "$cleanup_contract_source" \
    "$cleanup_contract_privileged"
cleanup_contract_status=0
if (
    trap - EXIT
    TMP="$cleanup_contract_tmp"
    MOUNT_TARGET="$cleanup_contract_tmp/mount-target"
    MOUNT_SOURCE="$cleanup_contract_source"
    PRIVILEGED_TMP="$cleanup_contract_privileged"
    UMOUNT_BIN=/usr/bin/false
    CLEANUP_UNMOUNT_ACTION=cleanup_fixture_unmount
    CLEANUP_REMOVE_ACTION=cleanup_fixture_remove
    CLEANUP_CHMOD_ACTION=cleanup_fixture_chmod
    CLEANUP_FIXTURE_LOG="$cleanup_contract_log"
    CLEANUP_FIXTURE_REMOVE_FAILURE="$cleanup_contract_source"
    cleanup 0
) > "$cleanup_contract_root/stdout" 2> "$cleanup_contract_stderr"; then
    cleanup_contract_status=0
else
    cleanup_contract_status=$?
fi
cleanup_contract_expected="$(printf \
    'unmount:%s\nremove:%s\nremove:%s\nchmod:%s\nremove:%s' \
    "$cleanup_contract_tmp/mount-target" \
    "$cleanup_contract_source" \
    "$cleanup_contract_privileged" \
    "$cleanup_contract_tmp" \
    "$cleanup_contract_tmp")"
cleanup_contract_actual=""
if [[ -f "$cleanup_contract_log" ]]; then
    cleanup_contract_actual="$(cat "$cleanup_contract_log")"
fi
if [[ "$cleanup_contract_status" -ne 0 \
    && "$cleanup_contract_actual" == "$cleanup_contract_expected" \
    && -f "$cleanup_contract_stderr" \
    && $(grep -Fc "cleanup failed (unmount $cleanup_contract_tmp/mount-target): status 41" \
        "$cleanup_contract_stderr") -eq 1 \
    && $(grep -Fc "cleanup failed (remove $cleanup_contract_source): status 42" \
        "$cleanup_contract_stderr") -eq 1 ]]; then
    pass "cleanup reports failures and still attempts every later action"
else
    fail "cleanup hid a failure or stopped before a later action"
    sed -n '1,120p' "$cleanup_contract_stderr" >&2
fi

info "cleanup retains an original nonzero test status"
cleanup_original_log="$cleanup_contract_root/original-actions.log"
cleanup_original_stderr="$cleanup_contract_root/original-stderr"
cleanup_original_status=0
if (
    trap - EXIT
    TMP="$cleanup_contract_tmp"
    MOUNT_TARGET="$cleanup_contract_tmp/mount-target"
    MOUNT_SOURCE="$cleanup_contract_source"
    PRIVILEGED_TMP="$cleanup_contract_privileged"
    CLEANUP_UNMOUNT_ACTION=cleanup_fixture_unmount
    CLEANUP_REMOVE_ACTION=cleanup_fixture_remove
    CLEANUP_CHMOD_ACTION=cleanup_fixture_chmod
    CLEANUP_FIXTURE_LOG="$cleanup_original_log"
    CLEANUP_FIXTURE_REMOVE_FAILURE="$cleanup_contract_source"
    cleanup 37
) > "$cleanup_contract_root/original-stdout" \
    2> "$cleanup_original_stderr"; then
    cleanup_original_status=0
else
    cleanup_original_status=$?
fi
if [[ "$cleanup_original_status" -eq 37 \
    && -f "$cleanup_original_log" \
    && $(wc -l < "$cleanup_original_log") -eq 5 ]]; then
    pass "cleanup preserves the original nonzero status after all attempts"
else
    fail "cleanup replaced the original test status or skipped an action"
    sed -n '1,120p' "$cleanup_original_stderr" >&2
fi

prepare_link_fixture() {
    local fixture="$1"
    local relative_link="$2"
    local home_dir="$TMP/$fixture/home"
    local external_dir="$TMP/$fixture/external"
    local parent_dir

    mkdir -p "$home_dir" "$external_dir/retained"
    chmod 700 "$home_dir" "$external_dir"
    printf 'must remain unchanged\n' > "$external_dir/retained/marker"
    parent_dir="$(dirname "$home_dir/$relative_link")"
    mkdir -p "$parent_dir"
    ln -s "$external_dir" "$home_dir/$relative_link"
}

assert_rejected_without_external_change() {
    local fixture="$1"
    local home_path="$2"
    local external_dir="$TMP/$fixture/external"
    local before after install_status

    capture_nonempty before tree_receipt "$external_dir"
    capture_status install_status run_root_install "$home_path" \
        > "$TMP/$fixture/stdout" 2> "$TMP/$fixture/stderr"
    capture_nonempty after tree_receipt "$external_dir"

    if [[ "$install_status" -ne 0 && "$after" == "$before" ]]; then
        pass "$fixture is rejected without changing its external target"
    else
        fail "$fixture crossed the privileged ownership boundary"
        sed -n '1,120p' "$TMP/$fixture/stdout" >&2
        sed -n '1,120p' "$TMP/$fixture/stderr" >&2
    fi
}

info "root-install creates the required user directories through safe direct paths"
normal_home="$TMP/normal/home"
mkdir -p "$normal_home/.claude"
chmod 700 "$normal_home"
printf 'retained\n' > "$normal_home/.claude/retained"
if run_root_install "$normal_home" \
    > "$TMP/normal.stdout" 2> "$TMP/normal.stderr" \
    && [[ -d "$normal_home/.cache/rattler/cache/pkgs" ]] \
    && [[ -d "$normal_home/.cache/rattler/cache/repodata" ]] \
    && [[ -d "$normal_home/.cache/uv" ]] \
    && [[ -d "$normal_home/.pixi" ]] \
    && [[ -d "$normal_home/.local/bin" ]] \
    && [[ -d "$normal_home/.local/lib/pkgconfig" ]] \
    && [[ -d "$normal_home/.local/include" ]] \
    && [[ -d "$normal_home/.claude" ]] \
    && [[ "$(cat "$normal_home/.claude/retained")" == retained ]]; then
    pass "required directories exist and existing Claude data remains intact"
else
    fail "root-install did not create the required direct-directory set"
    sed -n '1,120p' "$TMP/normal.stdout" >&2
    sed -n '1,120p' "$TMP/normal.stderr" >&2
fi

info "root-install makes required directory modes usable"
mode_home="$TMP/mode-contract/home"
mkdir -p \
    "$mode_home/.cache/rattler/cache/pkgs" \
    "$mode_home/.cache/rattler/cache/repodata" \
    "$mode_home/.cache/uv" \
    "$mode_home/.pixi" \
    "$mode_home/.local/bin" \
    "$mode_home/.local/lib/pkgconfig" \
    "$mode_home/.local/include" \
    "$mode_home/.claude"
chmod 700 "$mode_home"
find "$mode_home/.cache" "$mode_home/.pixi" "$mode_home/.local" \
    -type d -exec chmod 500 {} +
chmod 1500 "$mode_home/.cache"
chmod 000 "$mode_home/.cache/uv"
chmod 750 "$mode_home/.claude"
if run_root_install "$mode_home" \
    > "$TMP/mode-contract/stdout" 2> "$TMP/mode-contract/stderr" \
    && python3 -I -S - "$mode_home" <<'PY'
import os
import stat
import sys

home = sys.argv[1]
required = (
    ".cache",
    ".cache/rattler",
    ".cache/rattler/cache",
    ".cache/rattler/cache/pkgs",
    ".cache/rattler/cache/repodata",
    ".cache/uv",
    ".pixi",
    ".local",
    ".local/bin",
    ".local/lib",
    ".local/lib/pkgconfig",
    ".local/include",
)
for relative_path in required:
    mode = stat.S_IMODE(os.stat(os.path.join(home, relative_path)).st_mode)
    if mode & 0o700 != 0o700 or mode & ~0o755:
        raise SystemExit(f"{relative_path} has unusable mode {mode:04o}")
claude_mode = stat.S_IMODE(os.stat(os.path.join(home, ".claude")).st_mode)
if claude_mode != 0o700:
    raise SystemExit(f".claude has mode {claude_mode:04o}, expected 0700")
PY
then
    pass "required directories have usable owner modes and .claude is private"
else
    fail "root-install left a required directory with an unusable mode"
    sed -n '1,120p' "$TMP/mode-contract/stdout" >&2
    sed -n '1,120p' "$TMP/mode-contract/stderr" >&2
fi

info "root-install repairs only the Claude directory node"
claude_direct_home="$TMP/claude-direct/home"
claude_external="$TMP/claude-direct/external"
mkdir -p "$claude_direct_home/.claude" "$claude_external/retained"
chmod 700 "$claude_direct_home" "$claude_external"
printf 'must remain unchanged\n' > "$claude_external/retained/marker"
ln -s "$claude_external" "$claude_direct_home/.claude/external-link"
claude_before=""
capture_nonempty claude_before tree_receipt "$claude_external"
claude_after=""
if run_root_install "$claude_direct_home" \
    > "$TMP/claude-direct/stdout" 2> "$TMP/claude-direct/stderr" \
    && capture_nonempty claude_after tree_receipt "$claude_external" \
    && [[ "$claude_after" == "$claude_before" ]]; then
    pass "Claude contents are not traversed by the privileged repair"
else
    fail "the privileged repair traversed Claude contents"
    sed -n '1,120p' "$TMP/claude-direct/stdout" >&2
    sed -n '1,120p' "$TMP/claude-direct/stderr" >&2
fi

info "root-install does not traverse pre-existing cache contents"
content_home="$TMP/content-boundary/home"
content_external="$TMP/content-boundary/external"
mkdir -p "$content_home/.cache/uv" "$content_external"
chmod 700 "$content_home" "$content_home/.cache" "$content_home/.cache/uv"
printf 'must remain unchanged\n' > "$content_external/retained"
ln "$content_external/retained" "$content_home/.cache/uv/external-hard-link"
content_before=""
capture_nonempty content_before tree_receipt "$content_external"
content_after=""
if run_root_install "$content_home" \
    > "$TMP/content-boundary/stdout" 2> "$TMP/content-boundary/stderr" \
    && capture_nonempty content_after tree_receipt "$content_external" \
    && [[ "$content_after" == "$content_before" ]]; then
    pass "pre-existing cache contents remain outside the privileged repair"
else
    fail "the privileged repair traversed pre-existing cache contents"
    sed -n '1,120p' "$TMP/content-boundary/stdout" >&2
    sed -n '1,120p' "$TMP/content-boundary/stderr" >&2
fi

info "root-install preserves the group of a pre-existing target-owned directory"
primary_gid="$(id -g)"
alternate_gid=""
read -r -a current_gids <<< "$(id -G)"
for member_gid in "${current_gids[@]}"; do
    if [[ "$member_gid" != "$primary_gid" ]]; then
        alternate_gid="$member_gid"
        break
    fi
done
if [[ -z "$alternate_gid" ]]; then
    echo -e "  ${BLUE}N/A${NC}: current user has no supplementary group for the portable group-preservation proof"
else
    group_home="$TMP/group-contract/home"
    mkdir -p "$group_home/.cache/uv"
    chmod 700 "$group_home" "$group_home/.cache" "$group_home/.cache/uv"
    chgrp "$alternate_gid" "$group_home/.cache/uv"
    group_before=""
    capture_nonempty group_before python3 -I -S -c \
        'import os,sys; print(os.stat(sys.argv[1], follow_symlinks=False).st_gid)' \
        "$group_home/.cache/uv"
    group_after=""
    if run_root_install "$group_home" \
        > "$TMP/group-contract/stdout" 2> "$TMP/group-contract/stderr" \
        && capture_nonempty group_after python3 -I -S -c \
            'import os,sys; print(os.stat(sys.argv[1], follow_symlinks=False).st_gid)' \
            "$group_home/.cache/uv" \
        && [[ "$group_after" == "$group_before" ]]; then
        pass "pre-existing target-owned directory group is preserved"
    else
        fail "root-install changed a pre-existing target-owned directory group"
        sed -n '1,120p' "$TMP/group-contract/stdout" >&2
        sed -n '1,120p' "$TMP/group-contract/stderr" >&2
    fi
fi

info "root-install proves distinct root and target-user ownership on Linux"
if can_run_linux_privileged_proof; then
    if [[ "$(id -u)" -eq 0 ]]; then
        target_record=""
        capture_nonempty target_record /usr/bin/python3 -I -S - <<'PY'
import pwd

try:
    target = pwd.getpwnam("nobody")
except KeyError:
    target = next(entry for entry in pwd.getpwall() if entry.pw_uid != 0)
if target.pw_uid == 0:
    raise SystemExit("a non-root target account is required")
print(f"{target.pw_name}:{target.pw_uid}:{target.pw_gid}")
PY
        IFS=: read -r target_user target_uid target_gid <<< "$target_record"
    else
        target_user="$(id -un)"
        target_uid="$(id -u)"
        target_gid="$(id -g)"
    fi
    if [[ "$target_gid" == 0 ]]; then
        alternate_target_gid=1
    else
        alternate_target_gid=0
    fi
    run_as_root /bin/chmod 755 "$TMP"

    PRIVILEGED_TMP="$TMP/privileged"
    privileged_home="$PRIVILEGED_TMP/home"
    privileged_external="$PRIVILEGED_TMP/external"
    run_as_root /usr/bin/python3 -I -S - \
        "$privileged_home" "$privileged_external" \
        "$target_uid" "$target_gid" "$alternate_target_gid" <<'PY'
import os
from pathlib import Path
import sys

home = Path(sys.argv[1])
external = Path(sys.argv[2])
target_uid = int(sys.argv[3])
target_gid = int(sys.argv[4])
alternate_target_gid = int(sys.argv[5])
required = (
    ".cache",
    ".cache/rattler",
    ".cache/rattler/cache",
    ".cache/rattler/cache/pkgs",
    ".cache/rattler/cache/repodata",
    ".cache/uv",
    ".pixi",
    ".local",
    ".local/bin",
    ".local/lib",
    ".local/lib/pkgconfig",
    ".local/include",
    ".claude",
)
home.mkdir(parents=True)
os.chmod(home.parent, 0o755)
for relative_path in required:
    if relative_path == ".pixi":
        continue
    path = home / relative_path
    path.mkdir(parents=True, exist_ok=True)
for relative_path in required:
    if relative_path == ".pixi":
        continue
    path = home / relative_path
    os.chown(path, target_uid, target_gid)
    os.chmod(path, 0o750 if relative_path == ".claude" else 0o500)
os.chown(home / ".cache/uv", target_uid, alternate_target_gid)
external.mkdir(parents=True)
retained = external / "retained"
retained.write_bytes(b"must remain root-owned\n")
os.chown(external, 0, 0)
os.chown(retained, 0, 0)
os.chmod(external, 0o700)
os.chmod(retained, 0o640)
os.link(retained, home / ".cache/uv/external-hard-link")
claude_retained = home / ".claude/retained"
claude_retained.write_bytes(b"must remain root-owned\n")
os.chown(claude_retained, 0, 0)
os.chmod(claude_retained, 0o640)
os.chown(home, target_uid, target_gid)
os.chmod(home, 0o700)
PY

    privileged_paths=(
        "$privileged_home/.cache"
        "$privileged_home/.cache/rattler"
        "$privileged_home/.cache/rattler/cache"
        "$privileged_home/.cache/rattler/cache/pkgs"
        "$privileged_home/.cache/rattler/cache/repodata"
        "$privileged_home/.cache/uv"
        "$privileged_home/.local"
        "$privileged_home/.local/bin"
        "$privileged_home/.local/lib"
        "$privileged_home/.local/lib/pkgconfig"
        "$privileged_home/.local/include"
        "$privileged_home/.claude"
    )
    privileged_identity_before=""
    privileged_content_before=""
    capture_nonempty privileged_identity_before \
        root_identity_receipt "${privileged_paths[@]}"
    capture_nonempty privileged_content_before root_path_receipt \
        "$privileged_external/retained" \
        "$privileged_home/.cache/uv/external-hard-link" \
        "$privileged_home/.claude/retained"
    privileged_identity_after=""
    privileged_content_after=""
    if run_root_install_privileged "$privileged_home" "$target_user" \
        > "$PRIVILEGED_TMP/stdout" 2> "$PRIVILEGED_TMP/stderr" \
        && capture_nonempty privileged_identity_after \
            root_identity_receipt "${privileged_paths[@]}" \
        && [[ "$privileged_identity_after" == "$privileged_identity_before" ]] \
        && capture_nonempty privileged_content_after root_path_receipt \
            "$privileged_external/retained" \
            "$privileged_home/.cache/uv/external-hard-link" \
            "$privileged_home/.claude/retained" \
        && [[ "$privileged_content_after" == "$privileged_content_before" ]] \
        && run_as_root /usr/bin/python3 -I -S - \
            "$privileged_home" "$target_uid" "$target_gid" \
            "$alternate_target_gid" <<'PY'
import os
import stat
import sys

home = sys.argv[1]
target_uid = int(sys.argv[2])
target_gid = int(sys.argv[3])
alternate_target_gid = int(sys.argv[4])
required = (
    ".cache",
    ".cache/rattler",
    ".cache/rattler/cache",
    ".cache/rattler/cache/pkgs",
    ".cache/rattler/cache/repodata",
    ".cache/uv",
    ".pixi",
    ".local",
    ".local/bin",
    ".local/lib",
    ".local/lib/pkgconfig",
    ".local/include",
)
home_metadata = os.stat(home, follow_symlinks=False)
for relative_path in required:
    metadata = os.stat(os.path.join(home, relative_path), follow_symlinks=False)
    mode = stat.S_IMODE(metadata.st_mode)
    expected_gid = alternate_target_gid if relative_path == ".cache/uv" else target_gid
    if metadata.st_uid != target_uid or metadata.st_gid != expected_gid:
        raise SystemExit(f"{relative_path} has incorrect ownership")
    if metadata.st_dev != home_metadata.st_dev:
        raise SystemExit(f"{relative_path} crossed the HOME device")
    if mode & 0o700 != 0o700 or mode & ~0o755:
        raise SystemExit(f"{relative_path} has unusable mode {mode:04o}")
claude = os.stat(os.path.join(home, ".claude"), follow_symlinks=False)
if (
    claude.st_uid != target_uid
    or claude.st_gid != target_gid
    or claude.st_dev != home_metadata.st_dev
    or stat.S_IMODE(claude.st_mode) != 0o700
):
    raise SystemExit(".claude does not have the exact ownership and mode contract")
hard_link = os.stat(
    os.path.join(home, ".cache/uv/external-hard-link"),
    follow_symlinks=False,
)
if hard_link.st_uid != 0 or hard_link.st_gid != 0 or hard_link.st_nlink != 2:
    raise SystemExit("pre-existing hard-linked content was changed")
PY
    then
        pass "user-directory work creates target-owned nodes and preserves existing nodes"
    else
        fail "the distinct root-to-target ownership contract did not hold"
        sed -n '1,120p' "$PRIVILEGED_TMP/stdout" >&2
        sed -n '1,120p' "$PRIVILEGED_TMP/stderr" >&2
    fi

    unbound_home="$PRIVILEGED_TMP/unbound-root-node/home"
    unbound_cache="$unbound_home/.cache"
    run_as_root /usr/bin/python3 -I -S - \
        "$unbound_home" "$target_uid" "$target_gid" <<'PY'
import os
from pathlib import Path
import sys

home = Path(sys.argv[1])
target_uid = int(sys.argv[2])
target_gid = int(sys.argv[3])
cache = home / ".cache"
cache.mkdir(parents=True)
os.chmod(home.parent, 0o755)
(cache / "retained").write_bytes(b"unbound root-owned node\n")
os.chown(cache, 0, 0)
os.chown(cache / "retained", 0, 0)
os.chmod(cache, 0o500)
os.chmod(cache / "retained", 0o400)
os.chown(home, target_uid, target_gid)
os.chmod(home, 0o700)
PY
    unbound_before=""
    unbound_after=""
    unbound_status=""
    capture_nonempty unbound_before root_path_receipt \
        "$unbound_cache" "$unbound_cache/retained"
    capture_status unbound_status run_root_install_privileged \
        "$unbound_home" "$target_user" \
        > "$PRIVILEGED_TMP/unbound-root-node/stdout" \
        2> "$PRIVILEGED_TMP/unbound-root-node/stderr"
    capture_nonempty unbound_after root_path_receipt \
        "$unbound_cache" "$unbound_cache/retained"
    if [[ "$unbound_status" -ne 0 && "$unbound_after" == "$unbound_before" ]]; then
        pass "an unbound pre-existing root-owned node is rejected unchanged"
    else
        fail "root-install transferred an unbound pre-existing root-owned node"
        sed -n '1,120p' "$PRIVILEGED_TMP/unbound-root-node/stdout" >&2
        sed -n '1,120p' "$PRIVILEGED_TMP/unbound-root-node/stderr" >&2
    fi

    phase20_root="$PRIVILEGED_TMP/phase20"
    phase20_home="$phase20_root/home"
    phase20_fixture="$phase20_root/repository"
    phase20_receipt="$phase20_fixture/receipt"
    run_as_root /usr/bin/python3 -I -S - \
        "$phase20_root" "$phase20_home" "$phase20_fixture" \
        "$phase20_receipt" "$target_uid" "$target_gid" <<'PY'
import os
from pathlib import Path
import sys

root = Path(sys.argv[1])
home = Path(sys.argv[2])
repository = Path(sys.argv[3])
receipt = Path(sys.argv[4])
target_uid = int(sys.argv[5])
target_gid = int(sys.argv[6])
installer = repository / "shared/Hephaestus/scripts/shell/install.sh"
installer.parent.mkdir(parents=True)
receipt.mkdir(parents=True)
home.mkdir(parents=True)
installer.write_text(
    """#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME/.local/bin"
printf 'artifact\\n' > "$HOME/.local/bin/phase20-artifact"
exec /usr/bin/python3 -I -S - "$ODYSSEUS_ROOT/receipt/identity.json" "$PPID" <<'INNER_PY'
import json
import os
from pathlib import Path
import sys

receipt = Path(sys.argv[1])
phase_shell_pid = int(sys.argv[2])
raw_environment = Path(f"/proc/{phase_shell_pid}/environ").read_bytes()
entries = [entry for entry in raw_environment.split(b"\\0") if entry]
environment = {}
for entry in entries:
    key, separator, value = entry.partition(b"=")
    if not separator or key in environment:
        raise SystemExit("phase-20 shell environment is malformed")
    environment[key.decode("utf-8")] = value.decode("utf-8")


def privilege_regain_is_blocked(operation):
    try:
        operation()
    except OSError:
        return True
    return False


payload = {
    "environment": environment,
    "groups": sorted(os.getgroups()),
    "resgid": list(os.getresgid()),
    "resuid": list(os.getresuid()),
    "setgroups_blocked": privilege_regain_is_blocked(
        lambda: os.setgroups([0])
    ),
    "setresgid_blocked": privilege_regain_is_blocked(
        lambda: os.setresgid(0, 0, 0)
    ),
    "setresuid_blocked": privilege_regain_is_blocked(
        lambda: os.setresuid(0, 0, 0)
    ),
}
receipt.write_text(json.dumps(payload, sort_keys=True), encoding="utf-8")
INNER_PY
""",
    encoding="utf-8",
)
os.chmod(installer, 0o555)
for directory in (
    repository,
    repository / "shared",
    repository / "shared/Hephaestus",
    repository / "shared/Hephaestus/scripts",
    installer.parent,
):
    os.chmod(directory, 0o711)
for directory in (root.parent.parent, root.parent, root):
    os.chmod(directory, 0o755)
for path in (home, receipt):
    os.chown(path, target_uid, target_gid)
    os.chmod(path, 0o700)
PY
    if run_phase20_privileged \
        "$phase20_home" "$target_user" "$phase20_fixture" \
        > "$phase20_root/stdout" 2> "$phase20_root/stderr" \
        && run_as_root /usr/bin/python3 -I -S - \
            "$phase20_home/.local/bin/phase20-artifact" \
            "$phase20_receipt/identity.json" \
            "$phase20_home" "$phase20_fixture" \
            "$target_user" "$target_uid" "$target_gid" <<'PY'
import json
import os
from pathlib import Path
import sys

artifact = Path(sys.argv[1])
identity = Path(sys.argv[2])
home = sys.argv[3]
repository = sys.argv[4]
target_user = sys.argv[5]
target_uid = int(sys.argv[6])
target_gid = int(sys.argv[7])
artifact_metadata = os.stat(artifact, follow_symlinks=False)
if artifact_metadata.st_uid != target_uid or artifact_metadata.st_gid != target_gid:
    raise SystemExit("the phase-20 artifact is not owned by the target user")
payload = json.loads(identity.read_text(encoding="utf-8"))
if payload["resuid"] != [target_uid, target_uid, target_uid]:
    raise SystemExit(f"phase 20 retained UID authority: {payload['resuid']}")
if payload["resgid"] != [target_gid, target_gid, target_gid]:
    raise SystemExit(f"phase 20 retained GID authority: {payload['resgid']}")
expected_groups = sorted(os.getgrouplist(target_user, target_gid))
if payload["groups"] != expected_groups:
    raise SystemExit(
        f"phase 20 groups {payload['groups']} do not match {expected_groups}"
    )
for key in ("setgroups_blocked", "setresgid_blocked", "setresuid_blocked"):
    if payload[key] is not True:
        raise SystemExit(f"phase 20 could regain authority through {key}")
expected_environment = {
    "HOME": home,
    "INSTALL": "true",
    "LC_ALL": "C",
    "LOGNAME": target_user,
    "ODYSSEUS_ROOT": repository,
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "ROLE": "all",
    "SHELL": "/bin/bash",
    "USER": target_user,
}
if payload["environment"] != expected_environment:
    raise SystemExit(
        "phase 20 received a non-canonical environment: "
        f"{payload['environment']!r}"
    )
PY
    then
        pass "phase 20 has target-user identity and an exact minimal environment"
    else
        fail "phase 20 retained authority or inherited ambient environment data"
        sed -n '1,120p' "$phase20_root/stdout" >&2
        sed -n '1,120p' "$phase20_root/stderr" >&2
    fi
else
    echo -e "  ${BLUE}N/A${NC}: distinct root-to-target proof requires Linux root or passwordless sudo; CI is authoritative"
fi

info "root-install rejects a cross-device mounted cache directory"
MOUNT_BIN="$(command -v mount 2>/dev/null)"
UMOUNT_BIN="$(command -v umount 2>/dev/null)"
if can_run_linux_privileged_proof; then
    if [[ -z "$MOUNT_BIN" || -z "$UMOUNT_BIN" || ! -d /dev/shm ]]; then
        fail "the root-capable Linux host lacks the mount-test prerequisites"
    else
    mount_home="$TMP/mount-boundary/home"
    MOUNT_TARGET="$mount_home/.cache/uv"
    MOUNT_SOURCE="/dev/shm/odysseus-root-install-${TMP##*/}"
    run_as_root /usr/bin/python3 -I -S - \
        "$mount_home" "$MOUNT_TARGET" "$MOUNT_SOURCE" \
        "$target_uid" "$target_gid" <<'PY'
import os
from pathlib import Path
import sys

home = Path(sys.argv[1])
target = Path(sys.argv[2])
source = Path(sys.argv[3])
target_uid = int(sys.argv[4])
target_gid = int(sys.argv[5])
target.mkdir(parents=True)
os.chmod(home.parent, 0o755)
source.mkdir(mode=0o500)
(source / "retained").write_bytes(b"must remain unchanged\n")
os.chown(home / ".cache", target_uid, target_gid)
os.chmod(home / ".cache", 0o700)
os.chown(source, target_uid, target_gid)
os.chown(source / "retained", target_uid, target_gid)
os.chmod(source, 0o500)
os.chmod(source / "retained", 0o400)
os.chown(home, target_uid, target_gid)
os.chmod(home, 0o700)
PY
    home_device=""
    source_device=""
    capture_nonempty home_device run_as_root /usr/bin/python3 -I -S -c \
        'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$mount_home"
    capture_nonempty source_device run_as_root /usr/bin/python3 -I -S -c \
        'import os,sys; print(os.stat(sys.argv[1]).st_dev)' "$MOUNT_SOURCE"
    if [[ "$home_device" == "$source_device" ]]; then
        fail "/dev/shm is not a distinct filesystem on this root-capable Linux host"
        MOUNT_TARGET=""
        run_as_root /bin/rm -rf -- "$MOUNT_SOURCE"
        MOUNT_SOURCE=""
    elif run_as_root "$MOUNT_BIN" --bind "$MOUNT_SOURCE" "$MOUNT_TARGET" \
        >/dev/null 2>&1; then
        mounted_before=""
        mounted_after=""
        mounted_status=""
        capture_nonempty mounted_before root_path_receipt \
            "$MOUNT_SOURCE" "$MOUNT_SOURCE/retained"
        capture_status mounted_status run_root_install_privileged \
            "$mount_home" "$target_user" \
            > "$TMP/mount-boundary/stdout" \
            2> "$TMP/mount-boundary/stderr"
        capture_nonempty mounted_after root_path_receipt \
            "$MOUNT_SOURCE" "$MOUNT_SOURCE/retained"
        run_as_root "$UMOUNT_BIN" "$MOUNT_TARGET"
        MOUNT_TARGET=""
        run_as_root /bin/rm -rf -- "$MOUNT_SOURCE"
        MOUNT_SOURCE=""
        if [[ "$mounted_status" -ne 0 && "$mounted_after" == "$mounted_before" ]]; then
            pass "cross-device cache mounts are rejected without changing their source"
        else
            fail "root-install accepted or changed a cross-device cache mount"
            sed -n '1,120p' "$TMP/mount-boundary/stdout" >&2
            sed -n '1,120p' "$TMP/mount-boundary/stderr" >&2
        fi
    else
        MOUNT_TARGET=""
        run_as_root /bin/rm -rf -- "$MOUNT_SOURCE"
        MOUNT_SOURCE=""
        fail "the root-capable Linux host could not create the required bind mount"
    fi
    fi
else
    echo -e "  ${BLUE}N/A${NC}: cross-device mount proof requires a root-capable Linux host; CI is authoritative"
fi

info "root-install remains confined during an inode-replacement race"
if [[ "$(uname -s)" != Linux ]]; then
    echo -e "  ${BLUE}N/A${NC}: deterministic rename exchange requires Linux renameat2; CI is authoritative"
elif ! python3 -I -S - <<'PY'
import ctypes

raise SystemExit(0 if hasattr(ctypes.CDLL(None), "renameat2") else 1)
PY
then
    fail "this Linux host lacks renameat2 for the deterministic race proof"
else
    race_home="$TMP/inode-race/home"
    race_external="$TMP/inode-race/external"
    race_alternate="$race_home/.local/include-alternate"
    race_trigger="$race_home/.cache"
    race_ready="$TMP/inode-race/ready"
    race_active="$TMP/inode-race/installer-active"
    race_result="$TMP/inode-race/race-result.json"
    race_install_result="$TMP/inode-race/install-status"
    mkdir -p \
        "$race_trigger" \
        "$race_home/.local/include" \
        "$race_external/retained"
    chmod 700 "$race_home" "$race_home/.local"
    chmod 500 "$race_trigger" "$race_home/.local/include"
    chmod 500 "$race_external"
    printf 'must remain unchanged\n' > "$race_external/retained/marker"
    ln -s "$race_external" "$race_alternate"
    race_external_before=""
    capture_nonempty race_external_before tree_receipt "$race_external"
    python3 -I -S - \
        "$race_home/.local/include" "$race_alternate" \
        "$race_trigger" "$race_ready" "$race_active" "$race_result" \
        > "$TMP/inode-race/racer.stdout" \
        2> "$TMP/inode-race/racer.stderr" <<'PY' &
import ctypes
import json
import os
from pathlib import Path
import stat
import sys
import time

direct = os.fsencode(sys.argv[1])
alternate = os.fsencode(sys.argv[2])
trigger = Path(sys.argv[3])
ready = Path(sys.argv[4])
active = Path(sys.argv[5])
result_path = Path(sys.argv[6])
at_fdcwd = -100
rename_exchange = 2
libc = ctypes.CDLL(None, use_errno=True)
renameat2 = libc.renameat2
renameat2.argtypes = (
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_int,
    ctypes.c_char_p,
    ctypes.c_uint,
)
renameat2.restype = ctypes.c_int


def exchange():
    if renameat2(at_fdcwd, direct, at_fdcwd, alternate, rename_exchange) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))


count = 0
ready.touch()
deadline = time.monotonic() + 10
while not active.exists():
    if time.monotonic() >= deadline:
        raise SystemExit("installer did not enter the active state")
    time.sleep(0.001)

trigger_seen = False
while active.exists():
    metadata = os.lstat(trigger)
    if stat.S_ISDIR(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o700:
        trigger_seen = True
        break
if not trigger_seen:
    raise SystemExit("installer exited before repairing the protected trigger route")

active_during_exchange = active.exists()
if not active_during_exchange:
    raise SystemExit("installer exited before the synchronized exchange")
exchange()
exchange()
count += 2
while active.exists():
    exchange()
    exchange()
    count += 2
if os.path.islink(os.fsdecode(direct)):
    exchange()
    count += 1
result_path.write_text(
    json.dumps(
        {
            "active_during_exchange": active_during_exchange,
            "exchanges": count,
            "trigger_seen": trigger_seen,
        },
        sort_keys=True,
    ),
    encoding="ascii",
)
PY
    racer_pid=$!
    race_ready_seen=0
    _attempt=0
    while [[ "$_attempt" -lt 500 ]]; do
        _attempt=$((_attempt + 1))
        if [[ -e "$race_ready" ]]; then
            race_ready_seen=1
            break
        fi
        if ! kill -0 "$racer_pid" 2>/dev/null; then
            break
        fi
        sleep 0.01
    done
    if [[ "$race_ready_seen" -eq 1 ]]; then
        : > "$race_active"
        (
            if run_root_install "$race_home"; then
                printf '0\n' > "$race_install_result"
            else
                printf '%s\n' "$?" > "$race_install_result"
            fi
            rm -f "$race_active"
        ) > "$TMP/inode-race/stdout" 2> "$TMP/inode-race/stderr" &
        race_install_pid=$!
        if wait "$race_install_pid"; then
            race_wrapper_status=0
        else
            race_wrapper_status=$?
        fi
        if wait "$racer_pid"; then
            racer_status=0
        else
            racer_status=$?
        fi
        race_install_status=""
        race_result_summary=""
        race_external_after=""
        capture_nonempty race_install_status sed -n '1p' "$race_install_result"
        capture_nonempty race_result_summary \
            /usr/bin/python3 -I -S - "$race_result" <<'PY'
import json
from pathlib import Path
import sys

payload = json.loads(Path(sys.argv[1]).read_text(encoding="ascii"))
if payload != {
    "active_during_exchange": True,
    "exchanges": payload.get("exchanges"),
    "trigger_seen": True,
}:
    raise SystemExit(1)
count = payload["exchanges"]
if not isinstance(count, int) or isinstance(count, bool) or count < 2:
    raise SystemExit(1)
print(count)
PY
        capture_nonempty race_external_after tree_receipt "$race_external"
        race_outcome_valid=0
        if [[ "$race_install_status" == 0 ]] \
            && /usr/bin/python3 -I -S - \
                "$race_home/.local/include" <<'PY'
import os
import stat
import sys

metadata = os.stat(sys.argv[1], follow_symlinks=False)
raise SystemExit(
    0
    if stat.S_ISDIR(metadata.st_mode) and stat.S_IMODE(metadata.st_mode) == 0o700
    else 1
)
PY
        then
            race_outcome_valid=1
        elif [[ "$race_install_status" =~ ^[1-9][0-9]*$ ]] \
            && grep -Eq \
                '\.local/include.*(not a direct directory|changed while it was opened|could not be (inspected|opened) safely|unexpected owner|crosses the HOME filesystem boundary)' \
                "$TMP/inode-race/stderr"; then
            race_outcome_valid=1
        fi
        if [[ "$race_wrapper_status" -eq 0 \
            && "$racer_status" -eq 0 \
            && "$race_result_summary" =~ ^[0-9]+$ \
            && "$race_result_summary" -ge 2 \
            && "$race_outcome_valid" -eq 1 \
            && "$race_external_after" == "$race_external_before" \
            && -d "$race_home/.local/include" \
            && ! -L "$race_home/.local/include" \
            && -L "$race_alternate" ]]; then
            pass "synchronized inode replacement repairs the node or fails closed"
        else
            fail "inode replacement redirected or destabilized the repair"
            printf 'root-install status: %s; wrapper status: %s; racer status: %s; exchanges: %s\n' \
                "${race_install_status:-missing}" "$race_wrapper_status" \
                "$racer_status" "${race_result_summary:-missing}" >&2
            sed -n '1,120p' "$TMP/inode-race/stderr" >&2
            sed -n '1,120p' "$TMP/inode-race/racer.stderr" >&2
        fi
    else
        : > "$race_active"
        rm -f "$race_active"
        if wait "$racer_pid"; then
            :
        fi
        fail "the inode-replacement racer did not become ready"
        sed -n '1,120p' "$TMP/inode-race/racer.stderr" >&2
    fi
fi

info "root-install rejects hostile links before a privileged external effect"
prepare_link_fixture local-link .local
assert_rejected_without_external_change local-link "$TMP/local-link/home"

prepare_link_fixture lib-link .local/lib
assert_rejected_without_external_change lib-link "$TMP/lib-link/home"

prepare_link_fixture include-link .local/include
assert_rejected_without_external_change include-link "$TMP/include-link/home"

prepare_link_fixture cache-link .cache/rattler
assert_rejected_without_external_change cache-link "$TMP/cache-link/home"

prepare_link_fixture claude-link .claude
assert_rejected_without_external_change claude-link "$TMP/claude-link/home"

home_link_root="$TMP/home-link"
mkdir -p "$home_link_root/external/retained"
chmod 700 "$home_link_root/external"
printf 'must remain unchanged\n' > "$home_link_root/external/retained/marker"
ln -s "$home_link_root/external" "$home_link_root/home"
assert_rejected_without_external_change home-link "$home_link_root/home"

home_parent_link_root="$TMP/home-parent-link"
mkdir -p \
    "$home_parent_link_root/external/home" \
    "$home_parent_link_root/external/retained"
chmod 700 "$home_parent_link_root/external/home"
printf 'must remain unchanged\n' \
    > "$home_parent_link_root/external/retained/marker"
ln -s "$home_parent_link_root/external" "$home_parent_link_root/linked-parent"
assert_rejected_without_external_change \
    home-parent-link "$home_parent_link_root/linked-parent/home"

summary
exit_code
