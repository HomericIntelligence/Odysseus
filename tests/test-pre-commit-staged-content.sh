#!/usr/bin/env bash
# The standalone pre-commit hook must inspect the bytes in Git's index.
set -euo pipefail

if ! ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); then
    printf 'ERROR: could not resolve the repository root\n' >&2
    exit 1
fi
fixture_prefix="${TMPDIR:-/tmp}/odysseus-precommit-index."
MKTEMP_BIN="${ODYSSEUS_TEST_MKTEMP:-}"
if [ -z "$MKTEMP_BIN" ]; then
    if ! MKTEMP_BIN=$(command -v mktemp); then
        printf 'ERROR: mktemp is required for the pre-commit test fixture\n' >&2
        exit 1
    fi
fi
TMP_ROOT=""
if [ ! -x "$MKTEMP_BIN" ] \
   || ! TMP_ROOT=$("$MKTEMP_BIN" -d "${fixture_prefix}XXXXXX"); then
    printf 'ERROR: could not create a safe pre-commit test fixture\n' >&2
    exit 1
fi
fixture_suffix="${TMP_ROOT#"$fixture_prefix"}"
if [ "$fixture_suffix" = "$TMP_ROOT" ] || [ -z "$fixture_suffix" ] \
   || [ ! -d "$TMP_ROOT" ] || [ -L "$TMP_ROOT" ]; then
    printf 'ERROR: mktemp returned an unsafe pre-commit test fixture: %s\n' \
        "$TMP_ROOT" >&2
    exit 1
fi
case "$fixture_suffix" in
    *[!A-Za-z0-9]*)
        printf 'ERROR: mktemp returned an unsafe pre-commit test fixture: %s\n' \
            "$TMP_ROOT" >&2
        exit 1
        ;;
esac
cleanup_test_root() {
    cleanup_status=$1
    trap - EXIT
    if ! rm -rf -- "$TMP_ROOT"; then
        printf 'ERROR: failed to remove pre-commit test fixture: %s\n' \
            "$TMP_ROOT" >&2
        if [ "$cleanup_status" -eq 0 ]; then
            cleanup_status=1
        fi
    fi
    exit "$cleanup_status"
}
trap 'cleanup_test_root "$?"' EXIT

HOOK_SHELL="${ODYSSEUS_HOOK_SHELL:-$BASH}"
if ! REAL_GIT=$(command -v git); then
    printf 'ERROR: git is required for the pre-commit test fixture\n' >&2
    exit 1
fi
PASS=0
FAIL=0

if [ ! -x "$HOOK_SHELL" ]; then
    printf 'ERROR: selected hook shell is not executable: %s\n' "$HOOK_SHELL" >&2
    exit 1
fi
TEST_HOME="$TMP_ROOT/home"
mkdir -m 700 "$TEST_HOME" "$TMP_ROOT/tmp"

fixture_git() {
    local git_variable
    (
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        HOME="$TEST_HOME" \
        LC_ALL=C \
        PATH="$PATH" \
        TMPDIR="$TMP_ROOT/tmp" \
        "$REAL_GIT" "$@"
    )
}

pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }

new_repo() {
    case_root=$1
    case "$case_root" in
        "$TMP_ROOT"/*) ;;
        *)
            printf 'ERROR: refusing fixture repository outside %s: %s\n' \
                "$TMP_ROOT" "$case_root" >&2
            return 1
            ;;
    esac
    if ! mkdir -p "$case_root"; then
        printf 'ERROR: failed to create pre-commit fixture repository: %s\n' \
            "$case_root" >&2
        return 1
    fi
    if ! fixture_git -C "$case_root" init -q; then
        printf 'ERROR: failed to initialize pre-commit fixture repository: %s\n' \
            "$case_root" >&2
        return 1
    fi
    if ! fixture_git -C "$case_root" config user.email test@example.invalid \
       || ! fixture_git -C "$case_root" config user.name "Hook Test" \
       || ! fixture_git -C "$case_root" config commit.gpgsign false; then
        printf 'ERROR: failed to configure pre-commit fixture repository: %s\n' \
            "$case_root" >&2
        return 1
    fi
    if ! mkdir -p "$case_root/empty-hooks" "$case_root/tmp" \
       || ! fixture_git -C "$case_root" config core.hooksPath \
            "$case_root/empty-hooks" \
       || ! mkdir -p "$case_root/.githooks" \
       || ! cp "$ROOT/.githooks/pre-commit" "$case_root/.githooks/pre-commit" \
       || ! chmod +x "$case_root/.githooks/pre-commit"; then
        printf 'ERROR: failed to prepare pre-commit fixture repository: %s\n' \
            "$case_root" >&2
        return 1
    fi
}

run_hook() {
    local git_variable
    case_root=$1
    output_path=$2
    hook_path=${3:-$PATH}
    real_git=${4:-$REAL_GIT}
    (
        cd "$case_root" || exit 99
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 \
            HOME="$TEST_HOME" \
            LC_ALL=C \
            ODYSSEUS_TEST_REAL_GIT="$real_git" \
            PATH="$hook_path" \
            TMPDIR="$case_root/tmp" \
            "$HOOK_SHELL" .githooks/pre-commit
    ) >"$output_path" 2>&1
}

printf 'Selected hook shell: %s (%s)\n' "$HOOK_SHELL" "$BASH_VERSION"

printf '\n== staged tracked environment example ==\n'
example_repo="$TMP_ROOT/environment-example"
new_repo "$example_repo"
printf 'SERVICE_URL=http://example.invalid\n' > "$example_repo/.env.example"
fixture_git -C "$example_repo" add .env.example
fixture_git -C "$example_repo" commit -q -m "Add environment example"
printf 'SERVICE_URL=http://localhost\n' > "$example_repo/.env.example"
fixture_git -C "$example_repo" add .env.example
if run_hook "$example_repo" "$TMP_ROOT/environment-example.out" \
   && grep -Fqx "Pre-commit staged-content check passed." \
       "$TMP_ROOT/environment-example.out"; then
    pass "hook accepts a staged modification to tracked .env.example"
else
    sed -n '1,20p' "$TMP_ROOT/environment-example.out" >&2
    fail "hook did not complete a staged modification to tracked .env.example"
fi

printf '\n== staged secret paths ==\n'
while IFS='|' read -r case_name secret_path; do
    secret_repo="$TMP_ROOT/$case_name"
    new_repo "$secret_repo"
    mkdir -p "$(dirname "$secret_repo/$secret_path")"
    printf 'test fixture\n' > "$secret_repo/$secret_path"
    fixture_git -C "$secret_repo" add "$secret_path"
    if run_hook "$secret_repo" "$TMP_ROOT/$case_name.out"; then
        fail "hook accepted banned path $secret_path"
    elif grep -Fq "Banned credential / secret file(s) staged" "$TMP_ROOT/$case_name.out"; then
        pass "hook rejects banned path $secret_path"
    else
        fail "hook rejected $secret_path without the banned-path diagnostic"
    fi
done <<'EOF'
dotenv|.env
dotenv-local|.env.local
private-key|tls/private.key
credentials-json|credentials.json
EOF

printf '\n== staged large blob with a truncated worktree file ==\n'
truncate_repo="$TMP_ROOT/truncated"
new_repo "$truncate_repo"
dd if=/dev/zero of="$truncate_repo/large.bin" bs=1024 count=513 2>/dev/null
fixture_git -C "$truncate_repo" add large.bin
: > "$truncate_repo/large.bin"
if run_hook "$truncate_repo" "$TMP_ROOT/truncated.out"; then
    fail "hook accepted a staged large blob after the worktree file was truncated"
elif grep -Fq "larger than 512 KiB staged" "$TMP_ROOT/truncated.out"; then
    pass "hook rejects the staged large blob after worktree truncation"
else
    fail "hook failed without identifying the staged large blob"
fi

printf '\n== staged large blob with a deleted worktree file ==\n'
deleted_repo="$TMP_ROOT/deleted"
new_repo "$deleted_repo"
dd if=/dev/zero of="$deleted_repo/large.bin" bs=1024 count=513 2>/dev/null
fixture_git -C "$deleted_repo" add large.bin
rm "$deleted_repo/large.bin"
if run_hook "$deleted_repo" "$TMP_ROOT/deleted.out"; then
    fail "hook accepted a staged large blob after the worktree file was deleted"
elif grep -Fq "larger than 512 KiB staged" "$TMP_ROOT/deleted.out"; then
    pass "hook rejects the staged large blob after worktree deletion"
else
    fail "hook failed without identifying the deleted-worktree staged blob"
fi

printf '\n== staged symlink-to-large-blob type change ==\n'
type_change_repo="$TMP_ROOT/type-change"
new_repo "$type_change_repo"
printf 'target\n' > "$type_change_repo/target.txt"
ln -s target.txt "$type_change_repo/payload"
fixture_git -C "$type_change_repo" add payload target.txt
fixture_git -C "$type_change_repo" commit -q -m "Add symlink"
rm "$type_change_repo/payload"
dd if=/dev/zero of="$type_change_repo/payload" bs=1024 count=513 2>/dev/null
fixture_git -C "$type_change_repo" add payload
: > "$type_change_repo/payload"
if run_hook "$type_change_repo" "$TMP_ROOT/type-change.out"; then
    fail "hook accepted a staged large blob whose entry type changed"
elif grep -Fq "larger than 512 KiB staged" "$TMP_ROOT/type-change.out"; then
    pass "hook rejects a staged type-change using the large index blob"
else
    fail "hook rejected the staged type-change without the large-blob diagnostic"
fi

printf '\n== staged small blob ==\n'
small_repo="$TMP_ROOT/small"
new_repo "$small_repo"
printf 'small\n' > "$small_repo/note.txt"
fixture_git -C "$small_repo" add note.txt
if run_hook "$small_repo" "$TMP_ROOT/small.out"; then
    if grep -Fqx "Pre-commit staged-content check passed." \
        "$TMP_ROOT/small.out"; then
        pass "hook accepts a staged small non-secret blob"
    else
        sed -n '1,20p' "$TMP_ROOT/small.out" >&2
        fail "hook returned success before its terminal completion marker"
    fi
else
    fail "hook rejected a staged small non-secret blob"
fi

printf '\n== staged object inspection failure ==\n'
index_repo="$TMP_ROOT/index-failure"
new_repo "$index_repo"
printf 'small\n' > "$index_repo/note.txt"
fixture_git -C "$index_repo" add note.txt
index_bin="$index_repo/failing-git-bin"
mkdir -p "$index_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [ "${1:-}" = "cat-file" ]; then' \
    '    exit 53' \
    'fi' \
    'exec "${ODYSSEUS_TEST_REAL_GIT:?}" "$@"' \
    > "$index_bin/git"
chmod +x "$index_bin/git"
if run_hook "$index_repo" "$TMP_ROOT/index-failure.out" \
    "$index_bin:$PATH" "$REAL_GIT"; then
    fail "hook accepted an unavailable staged object"
elif grep -Fq "Could not inspect staged Git object(s)" \
    "$TMP_ROOT/index-failure.out"; then
    pass "hook rejects an unavailable staged object"
else
    fail "hook rejected staged-object inspection without its diagnostic"
fi

printf '\n== temporary-file cleanup failure after clean inspection ==\n'
cleanup_repo="$TMP_ROOT/cleanup-failure"
new_repo "$cleanup_repo"
printf 'small\n' > "$cleanup_repo/note.txt"
fixture_git -C "$cleanup_repo" add note.txt
cleanup_bin="$cleanup_repo/failing-cleanup-bin"
mkdir -p "$cleanup_bin"
printf '%s\n' '#!/usr/bin/env bash' 'exit 71' > "$cleanup_bin/rm"
chmod +x "$cleanup_bin/rm"
if run_hook "$cleanup_repo" "$TMP_ROOT/cleanup-failure.out" \
    "$cleanup_bin:$PATH"; then
    fail "hook accepted failed temporary-file cleanup"
elif grep -Fq "failed to remove pre-commit temporary file" \
    "$TMP_ROOT/cleanup-failure.out"; then
    pass "hook rejects failed temporary-file cleanup after clean inspection"
else
    fail "hook rejected temporary-file cleanup without its diagnostic"
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'PRE_COMMIT_STAGED_CONTENT_TESTS_COMPLETE\n'
