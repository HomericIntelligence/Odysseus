#!/usr/bin/env bash
# Behavior tests for the pre-push signature boundary and its hook installer.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck disable=SC1091
source "$ROOT/e2e/lib/common.sh"

TMP="$(mktemp -d)"
TMP="$(cd "$TMP" && pwd -P)"
trap 'rm -rf "$TMP"' EXIT

FAKE_BIN="$TMP/bin"
GIT_LOG="$TMP/git.log"
mkdir -p "$FAKE_BIN"

cat > "$FAKE_BIN/git" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$GIT_LOG"
case "${1:-}" in
    ls-remote)
        printf '%s\t%s\n' \
            '1111111111111111111111111111111111111111' \
            'refs/heads/main'
        ;;
    symbolic-ref)
        printf 'refs/remotes/origin/main\n'
        ;;
    merge-base)
        if [ "${2:-}" = "local-orphan" ]; then
            exit 1
        fi
        printf 'base-sha\n'
        ;;
    rev-list)
        case "${2:-}" in
            remote-good..local-good) printf 'good-sha\n' ;;
            remote-bad..local-bad) printf 'bad-sha\ngood-sha\n' ;;
            remote-error..local-error) printf 'verify-error-sha\n' ;;
            local-new) printf 'bad-sha\n' ;;
            base-sha..local-new-foreign) printf 'good-sha\n' ;;
            upstream..HEAD) printf 'good-sha\n' ;;
            local-orphan) printf 'orphan-root-sha\n' ;;
            local-new-foreign)
                if [ "${4:-}" = \
                    '1111111111111111111111111111111111111111' ]; then
                    printf 'foreign-unsigned-sha\ngood-sha\n'
                else
                    printf 'good-sha\n'
                fi
                ;;
            local-forged)
                if [ "${4:-}" = \
                    '1111111111111111111111111111111111111111' ]; then
                    printf 'bad-sha\n'
                fi
                ;;
            --max-parents=0) printf 'root-sha\n' ;;
        esac
        ;;
    log)
        case "${!#}" in
            good-sha) printf 'G\n' ;;
            bad-sha) printf 'N\n' ;;
            orphan-root-sha) printf 'N\n' ;;
            foreign-unsigned-sha) printf 'N\n' ;;
            verify-error-sha) exit 86 ;;
            *) printf 'N\n' ;;
        esac
        ;;
    rev-parse)
        printf 'upstream\n'
        ;;
    *)
        printf 'unexpected git invocation: %s\n' "$*" >&2
        exit 91
        ;;
esac
SH
chmod +x "$FAKE_BIN/git"

ZERO=0000000000000000000000000000000000000000

info "a deletion-first multi-ref push still validates later refs"
printf '%s\n%s\n' \
    "refs/heads/deleted $ZERO refs/heads/deleted remote-deleted" \
    "refs/heads/topic local-bad refs/heads/topic remote-bad" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" origin ssh://origin.invalid/repo \
        >"$TMP/deletion-first.out" 2>"$TMP/deletion-first.err"
status=$?
if [ "$status" -ne 0 ] && grep -q 'bad-sha(N)' "$TMP/deletion-first.err"; then
    pass "deletion-first push rejects a later unsigned commit"
else
    sed 's/^/    /' "$TMP/deletion-first.err" >&2
    fail "deletion-first push skipped or accepted a later unsigned commit"
fi

info "all pushed refs are inspected and duplicate commits are checked once"
: > "$GIT_LOG"
printf '%s\n%s\n' \
    "refs/heads/one local-bad refs/heads/one remote-bad" \
    "refs/heads/two local-new refs/heads/two $ZERO" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" origin ssh://origin.invalid/repo \
        >"$TMP/multi.out" 2>"$TMP/multi.err"
status=$?
if ! bad_checks=$(grep -c '^log -1 --format=%G? bad-sha$' "$GIT_LOG"); then
    bad_checks=0
fi
if [ "$status" -ne 0 ] && [ "$bad_checks" -eq 1 ] &&
    grep -q \
        '^rev-list local-new --not 1111111111111111111111111111111111111111$' \
        "$GIT_LOG"; then
    pass "multi-ref push rejects and deduplicates unsigned commits"
else
    sed 's/^/    /' "$TMP/multi.err" >&2
    fail "multi-ref push did not inspect the exact deduplicated commit set"
fi

info "a fully signed multi-ref push succeeds"
if printf '%s\n%s\n' \
    "refs/heads/deleted $ZERO refs/heads/deleted remote-deleted" \
    "refs/heads/good local-good refs/heads/good remote-good" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" origin ssh://origin.invalid/repo \
        >"$TMP/good.out" 2>"$TMP/good.err"; then
    pass "signed multi-ref push succeeds"
else
    sed 's/^/    /' "$TMP/good.err" >&2
    fail "signed multi-ref push failed"
fi

info "an orphan branch includes its unsigned root commit"
printf '%s\n' \
    "refs/heads/orphan local-orphan refs/heads/orphan $ZERO" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" origin ssh://origin.invalid/repo \
        >"$TMP/orphan.out" 2>"$TMP/orphan.err"
status=$?
if [ "$status" -ne 0 ] && grep -q 'orphan-root-sha(N)' "$TMP/orphan.err"; then
    pass "unsigned orphan root commit is rejected"
else
    sed 's/^/    /' "$TMP/orphan.err" >&2
    fail "orphan root commit was excluded from signature verification"
fi

info "a new ref uses an immutable destination ref snapshot"
printf '%s\n' \
    "refs/heads/foreign local-new-foreign refs/heads/foreign $ZERO" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" upstream ssh://upstream.invalid/repo \
        >"$TMP/non-origin.out" 2>"$TMP/non-origin.err"
status=$?
if [ "$status" -ne 0 ] && grep -q 'foreign-unsigned-sha(N)' "$TMP/non-origin.err"; then
    pass "new non-origin ref is compared with its actual destination"
else
    sed 's/^/    /' "$TMP/non-origin.err" >&2
    fail "new non-origin ref did not use its actual destination"
fi

info "a literal-URL harness push uses the destination snapshot"
: > "$GIT_LOG"
printf '%s\n' \
    "refs/heads/foreign local-new-foreign refs/heads/foreign $ZERO" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" \
        ssh://harness.invalid/repo ssh://harness.invalid/repo \
        >"$TMP/url-remote.out" 2>"$TMP/url-remote.err"
status=$?
if [ "$status" -ne 0 ] \
    && grep -q 'foreign-unsigned-sha(N)' "$TMP/url-remote.err" \
    && grep -q '^ls-remote --refs -- ssh://harness.invalid/repo$' "$GIT_LOG" \
    && ! grep -q -- '--remotes=' "$GIT_LOG"; then
    pass "literal-URL pushes verify only commits absent from that destination"
else
    sed 's/^/    /' "$TMP/url-remote.err" >&2
    fail "literal-URL push fell back to mutable local remote-tracking state"
fi

info "a forged remote-tracking ref cannot hide an unsigned new-ref tip"
: > "$GIT_LOG"
printf '%s\n' \
    "refs/heads/forged local-forged refs/heads/forged $ZERO" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" origin \
        ssh://origin.invalid/repo \
        >"$TMP/forged-remote.out" 2>"$TMP/forged-remote.err"
status=$?
if [ "$status" -ne 0 ] \
   && grep -q 'bad-sha(N)' "$TMP/forged-remote.err" \
   && grep -q '^ls-remote --refs -- ssh://origin.invalid/repo$' "$GIT_LOG" \
   && ! grep -q -- '--remotes=origin' "$GIT_LOG"; then
    pass "new-ref exclusions are bound to the destination snapshot"
else
    sed 's/^/    /' "$TMP/forged-remote.err" >&2
    fail "mutable remote-tracking state hid an unsigned new-ref tip"
fi

info "signature inspection failure cannot pass verification"
printf '%s\n' \
    "refs/heads/topic local-error refs/heads/topic remote-error" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        bash "$ROOT/scripts/check-push-signatures.sh" origin ssh://origin.invalid/repo \
        >"$TMP/helper-failure.out" 2>"$TMP/helper-failure.err"
status=$?
if [ "$status" -ne 0 ] && grep -q \
    'could not verify the signature for commit verify-error-sha' \
    "$TMP/helper-failure.err"; then
    pass "signature inspection failure cannot produce false success"
else
    sed 's/^/    /' "$TMP/helper-failure.err" >&2
    fail "signature inspection failure was swallowed"
fi

INSTALL_BIN="$TMP/install-bin"
PRECOMMIT_FIXTURE="$INSTALL_BIN/pre-commit-fixture"
PRECOMMIT_REGISTRY="$PRECOMMIT_FIXTURE.registry"
PRECOMMIT_FIXTURE_SHA256=c1aa9caa1d4bcf7598e851f03d007fd706fdaa9874cbeb46a3607a66c94ae748
INSTALL_WRAPPER_REL=scripts/install/dev/80-precommit.sh
HELPER_REL=scripts/install/dev/precommit_hooks.py
SYSTEM_GIT="$(command -v git)"
mkdir -p "$INSTALL_BIN"

sha256_file() {
    python3 -I -S - "$1" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
PY
}

cat > "$PRECOMMIT_FIXTURE" <<'SH'
#!/bin/bash
set -eu

origin=${ODYSSEUS_EXECUTABLE_ORIGIN:-$0}
registry="$origin.registry"
fixture_version=3.8.0

unexpected() {
    printf 'unexpected fixture syntax: %s\n' "$*" >&2
    exit 76
}

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    else
        printf 'no SHA-256 command is available\n' >&2
        exit 73
    fi
}

require_clean_environment() {
    if [ "${PYTHONPATH+x}" = x ] || [ "${PYTHONHOME+x}" = x ] ||
        [ "${ATTACK_MARKER+x}" = x ] ||
        [ "${PYTHONNOUSERSITE:-}" != 1 ] ||
        [ "${GIT_CONFIG_GLOBAL:-}" != /dev/null ] ||
        [ "${GIT_CONFIG_NOSYSTEM:-}" != 1 ] ||
        [ ! -d "${HOME:-}" ] || [ ! -d "${PRE_COMMIT_HOME:-}" ]; then
        printf 'fixture received an unsafe environment\n' >&2
        exit 72
    fi
}

lookup_config() {
    digest=$(sha256_file .pre-commit-config.yaml)
    record=$(awk -F '|' -v digest="$digest" \
        '$1 == digest { print; exit }' "$registry")
    if [ -z "$record" ]; then
        printf 'unregistered fixture config digest: %s\n' "$digest" >&2
        exit 74
    fi
    hook_types=$(printf '%s\n' "$record" | awk -F '|' '{print $2}')
    action=$(printf '%s\n' "$record" | awk -F '|' '{print $3}')
}

write_hook() {
    hook_type=$1
    hook_path=".git/hooks/$hook_type"
    cat > "$hook_path" <<HOOK
#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
# ID: 138fd403232d2ddd5efb44317e38bf03

# start templated
INSTALL_PYTHON=/definitely/missing/python
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=$hook_type)
# end templated

HERE="\$(cd "\$(dirname "\$0")" && pwd)"
ARGS+=(--hook-dir "\$HERE" -- "\$@")

if [ -x "\$INSTALL_PYTHON" ]; then
    exec "\$INSTALL_PYTHON" -mpre_commit "\${ARGS[@]}"
elif command -v pre-commit > /dev/null; then
    exec pre-commit "\${ARGS[@]}"
else
    echo '\`pre-commit\` not found.  Did you forget to activate your virtualenv?' 1>&2
    exit 1
fi
HOOK
    chmod +x "$hook_path"
}

require_clean_environment
command_name=${1:-}

if [ "$command_name" = --version ]; then
    [ "$#" -eq 1 ] || unexpected "$@"
    printf 'pre-commit %s\n' "$fixture_version"
    exit 0
fi

if [ "$command_name" = hook-impl ]; then
    shift
    config=''
    hook_type=''
    hook_dir=''
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --config=.pre-commit-config.yaml)
                config=.pre-commit-config.yaml
                shift
                ;;
            --hook-type=*)
                hook_type=${1#*=}
                [ -n "$hook_type" ] || unexpected "$1"
                shift
                ;;
            --hook-dir)
                [ "$#" -ge 2 ] && [ -n "$2" ] || unexpected "$1"
                hook_dir=$2
                shift 2
                ;;
            --) shift; break ;;
            *) unexpected "$1" ;;
        esac
    done
    [ "$config" = .pre-commit-config.yaml ] || unexpected 'missing --config'
    [ -n "$hook_type" ] || unexpected 'missing --hook-type'
    [ -n "$hook_dir" ] || unexpected 'missing --hook-dir'
    legacy="$hook_dir/$hook_type.legacy"
    if [ -x "$legacy" ]; then
        exec "$legacy" "$@"
    fi
    exit 0
fi

lookup_config
case "$action" in
    fail-*)
        printf 'fixture validation failure: %s\n' "${action#fail-}" >&2
        exit 78
        ;;
    pass) ;;
    *)
        printf 'invalid fixture action: %s\n' "$action" >&2
        exit 75
        ;;
esac

if [ "$command_name" = validate-config ]; then
    [ "$#" -eq 2 ] && [ "$2" = .pre-commit-config.yaml ] ||
        unexpected "$@"
    exit 0
fi
if [ "$command_name" != install ]; then
    printf 'unexpected fixture command: %s\n' "$*" >&2
    exit 76
fi

shift
install_hooks=false
requested=''
while [ "$#" -gt 0 ]; do
    case "$1" in
        --install-hooks) install_hooks=true; shift ;;
        --hook-type)
            [ "$#" -ge 2 ] && [ -n "$2" ] || unexpected "$1"
            case "$2" in
                --*) unexpected "$@" ;;
            esac
            requested="${requested}${requested:+ }$2"
            shift 2
            ;;
        *) unexpected "$1" ;;
    esac
done
if [ "$install_hooks" = true ] && [ "$requested" != "$hook_types" ]; then
    printf 'requested hook inventory differs from registered inventory\n' >&2
    exit 77
fi
if [ "$install_hooks" = false ] && [ -n "$requested" ]; then
    printf 'discovery received explicit hook types\n' >&2
    exit 77
fi

mkdir -p .git/hooks
for hook_type in $hook_types; do
    write_hook "$hook_type"
done
SH
chmod +x "$PRECOMMIT_FIXTURE"
ln -s "$(basename "$PRECOMMIT_FIXTURE")" "$INSTALL_BIN/pre-commit"
: > "$PRECOMMIT_REGISTRY"
register_config() {
    local path=$1 hook_types=$2 action=${3:-pass} digest record
    digest=$(sha256_file "$path")
    record="$digest|$hook_types|$action"
    if ! grep -Fqx "$record" "$PRECOMMIT_REGISTRY" 2>/dev/null; then
        printf '%s\n' "$record" >> "$PRECOMMIT_REGISTRY"
    fi
}

write_config() {
    local repo=$1 hook_types=$2 tag=$3 action=${4:-pass}
    case "$hook_types" in
        'pre-commit pre-push')
            printf '%s\n' \
                "# fixture: $tag" \
                'default_install_hook_types: [pre-commit, pre-push]' \
                'repos: []' > "$repo/.pre-commit-config.yaml"
            ;;
        pre-push)
            printf '%s\n' \
                "# fixture: $tag" \
                'default_install_hook_types: [pre-push]' \
                'repos: []' > "$repo/.pre-commit-config.yaml"
            ;;
        commit-msg)
            printf '%s\n' \
                "# fixture: $tag" \
                'default_install_hook_types:' \
                '  - "commit-msg"' \
                'repos: []' > "$repo/.pre-commit-config.yaml"
            ;;
        *)
            fail_exit "test fixture requested unsupported hooks: $hook_types"
            ;;
    esac
    register_config "$repo/.pre-commit-config.yaml" "$hook_types" "$action"
}

make_repo() {
    local repo=$1
    mkdir -p \
        "$repo/.githooks" \
        "$repo/scripts/install/dev" \
        "$repo/scripts/install"
    cp "$ROOT/.githooks/pre-push" "$repo/.githooks/pre-push"
    cp "$ROOT/$INSTALL_WRAPPER_REL" "$repo/$INSTALL_WRAPPER_REL"
    cp "$ROOT/$HELPER_REL" "$repo/$HELPER_REL"
    cp "$ROOT/scripts/install/lib.sh" "$repo/scripts/install/lib.sh"
    chmod +x "$repo/.githooks/pre-push" "$repo/$INSTALL_WRAPPER_REL"
    cat > "$repo/scripts/check-push-signatures.sh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$#" > "$HOOK_ARGC_LOG"
printf '%s\0' "$@" > "$HOOK_ARGS_LOG"
cp /dev/stdin "$HOOK_STDIN_LOG"
SH
    chmod +x "$repo/scripts/check-push-signatures.sh"
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -c init.templateDir= -C "$repo" init -q
    mkdir -p "$repo/.git/hooks"
}

run_installer() {
    local repo=$1 mode=$2 expected=$3 output=$4
    env \
        PATH="$INSTALL_BIN:/usr/bin:/bin" \
        HOME="$TMP/ambient-home" \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        ODYSSEUS_ROOT="$repo" \
        ODYSSEUS_PRECOMMIT_BINARY="$PRECOMMIT_FIXTURE" \
        ODYSSEUS_PRECOMMIT_EXPECTED_VERSION="$expected" \
        INSTALL="$mode" \
        /bin/bash "$repo/$INSTALL_WRAPPER_REL" > "$output" 2>&1
}

hook_inventory() {
    local repo=$1
    find "$repo/.git/hooks" -maxdepth 1 -type f ! -name '*.sample' \
        -exec basename {} \; | LC_ALL=C sort
}

info "the controlled pre-commit fixture has an immutable digest and exact version"
FIXTURE_REPO="$TMP/fixture-version"
mkdir -p "$TMP/ambient-home"
make_repo "$FIXTURE_REPO"
write_config "$FIXTURE_REPO" 'pre-commit pre-push' fixture-version
actual_fixture_digest=$(sha256_file "$PRECOMMIT_FIXTURE")
run_installer "$FIXTURE_REPO" true 3.8.0 "$TMP/version-pass.out"
version_pass_status=$?
run_installer "$FIXTURE_REPO" false 9.9.9 "$TMP/version-mismatch.out"
version_mismatch_status=$?
if [ "$actual_fixture_digest" = "$PRECOMMIT_FIXTURE_SHA256" ] &&
    [ "$version_pass_status" -eq 0 ] &&
    [ "$version_mismatch_status" -ne 0 ] &&
    grep -q 'expected pre-commit 9.9.9, found 3.8.0' \
        "$TMP/version-mismatch.out"; then
    pass "explicit pre-commit selection enforces the exact locked version"
else
    sed 's/^/    /' "$TMP/version-pass.out" >&2
    sed 's/^/    /' "$TMP/version-mismatch.out" >&2
    fail "explicit pre-commit selection or exact version enforcement failed"
fi

info "the controlled pre-commit fixture rejects unknown options"
mkdir -p "$TMP/fixture-command-home" "$TMP/fixture-command-cache"
(
    cd "$FIXTURE_REPO" || exit 90
    env -i \
        PATH="$INSTALL_BIN:/usr/bin:/bin" \
        HOME="$TMP/fixture-command-home" \
        PRE_COMMIT_HOME="$TMP/fixture-command-cache" \
        PYTHONNOUSERSITE=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        "$PRECOMMIT_FIXTURE" install --unknown-fixture-option
) > "$TMP/fixture-unknown.out" 2>&1
fixture_unknown_status=$?
if [ "$fixture_unknown_status" -ne 0 ]; then
    pass "the exact 3.8.0 fixture fails closed on unknown command syntax"
else
    sed 's/^/    /' "$TMP/fixture-unknown.out" >&2
    fail "the controlled pre-commit fixture accepted an unknown option"
fi

info "install and check preserve the signed pre-push transaction"
INSTALL_REPO="$TMP/install-contract"
make_repo "$INSTALL_REPO"
write_config "$INSTALL_REPO" 'pre-commit pre-push' install-contract
cp "$INSTALL_REPO/.githooks/pre-push" "$INSTALL_REPO/.git/hooks/pre-push"
chmod +x "$INSTALL_REPO/.git/hooks/pre-push"
run_installer "$INSTALL_REPO" true 3.8.0 "$TMP/install-contract.out"
install_status=$?
run_installer "$INSTALL_REPO" false 3.8.0 "$TMP/check-contract.out"
check_status=$?
printf '%s\n%s\n' \
    "refs/heads/deleted $ZERO refs/heads/deleted remote-deleted" \
    "refs/heads/topic local-good refs/heads/topic $ZERO" \
    > "$TMP/installed-hook.input"
printf '%s\0' 'upstream remote' 'ssh://upstream.invalid/repo with space' \
    > "$TMP/installed-hook.expected-args"
mkdir -p "$TMP/hook-home" "$TMP/hook-cache"
(
    cd "$INSTALL_REPO" || exit 90
    env -i \
        PATH="$INSTALL_BIN:/usr/bin:/bin" \
        HOME="$TMP/hook-home" \
        PRE_COMMIT_HOME="$TMP/hook-cache" \
        PYTHONNOUSERSITE=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        HOOK_ARGC_LOG="$TMP/installed-hook.argc" \
        HOOK_ARGS_LOG="$TMP/installed-hook.args" \
        HOOK_STDIN_LOG="$TMP/installed-hook.stdin" \
        "$INSTALL_REPO/.git/hooks/pre-push" \
        'upstream remote' 'ssh://upstream.invalid/repo with space'
) < "$TMP/installed-hook.input" > "$TMP/installed-hook.out" 2>&1
hook_status=$?
inventory=$(hook_inventory "$INSTALL_REPO")
if [ "$install_status" -eq 0 ] && [ "$check_status" -eq 0 ] &&
    [ "$hook_status" -eq 0 ] &&
    [ "$inventory" = $'pre-commit\npre-push\npre-push.legacy' ] &&
    cmp -s "$INSTALL_REPO/.githooks/pre-push" \
        "$INSTALL_REPO/.git/hooks/pre-push.legacy" &&
    cmp -s "$TMP/installed-hook.input" "$TMP/installed-hook.stdin" &&
    grep -qx '2' "$TMP/installed-hook.argc" &&
    cmp -s "$TMP/installed-hook.expected-args" \
        "$TMP/installed-hook.args"; then
    pass "install and check keep the exact hook inventory and full push input"
else
    sed 's/^/    /' "$TMP/install-contract.out" >&2
    sed 's/^/    /' "$TMP/check-contract.out" >&2
    sed 's/^/    /' "$TMP/installed-hook.out" >&2
    fail "installed hooks did not preserve the signed pre-push transaction"
fi

info "check mode detects a changed managed hook without repairing it"
printf '\n# tampered\n' >> "$INSTALL_REPO/.git/hooks/pre-commit"
tampered_digest=$(sha256_file "$INSTALL_REPO/.git/hooks/pre-commit")
run_installer "$INSTALL_REPO" false 3.8.0 "$TMP/tampered-check.out"
tampered_status=$?
after_check_digest=$(sha256_file "$INSTALL_REPO/.git/hooks/pre-commit")
if [ "$tampered_status" -ne 0 ] &&
    [ "$tampered_digest" = "$after_check_digest" ] &&
    grep -q 'installed managed hook inventory is not exact' \
        "$TMP/tampered-check.out"; then
    pass "check mode rejects but does not rewrite a changed managed hook"
else
    sed 's/^/    /' "$TMP/tampered-check.out" >&2
    fail "check mode repaired or accepted a changed managed hook"
fi

info "install removes managed hooks that are no longer configured"
STALE_REPO="$TMP/stale-managed"
make_repo "$STALE_REPO"
write_config "$STALE_REPO" 'pre-commit pre-push' stale-before
run_installer "$STALE_REPO" true 3.8.0 "$TMP/stale-before.out"
stale_before_status=$?
write_config "$STALE_REPO" pre-push stale-after
run_installer "$STALE_REPO" true 3.8.0 "$TMP/stale-after.out"
stale_after_status=$?
stale_inventory=$(hook_inventory "$STALE_REPO")
if [ "$stale_before_status" -eq 0 ] && [ "$stale_after_status" -eq 0 ] &&
    [ "$stale_inventory" = $'pre-push\npre-push.legacy' ]; then
    pass "install removes stale managed hooks and retains configured hooks"
else
    sed 's/^/    /' "$TMP/stale-before.out" >&2
    sed 's/^/    /' "$TMP/stale-after.out" >&2
    fail "install retained a managed hook outside the configured inventory"
fi

info "install does not overwrite unmanaged hook content"
UNMANAGED_REPO="$TMP/unmanaged-hook"
make_repo "$UNMANAGED_REPO"
write_config "$UNMANAGED_REPO" 'pre-commit pre-push' unmanaged-hook
printf '#!/bin/sh\nprintf "unmanaged hook\\n"\n' \
    > "$UNMANAGED_REPO/.git/hooks/pre-commit"
chmod +x "$UNMANAGED_REPO/.git/hooks/pre-commit"
unmanaged_digest=$(sha256_file "$UNMANAGED_REPO/.git/hooks/pre-commit")
run_installer "$UNMANAGED_REPO" true 3.8.0 "$TMP/unmanaged-hook.out"
unmanaged_status=$?
unmanaged_after=$(sha256_file "$UNMANAGED_REPO/.git/hooks/pre-commit")

LEGACY_REPO="$TMP/unmanaged-legacy"
make_repo "$LEGACY_REPO"
write_config "$LEGACY_REPO" 'pre-commit pre-push' unmanaged-legacy
cp "$LEGACY_REPO/.githooks/pre-push" "$LEGACY_REPO/.git/hooks/pre-push"
printf '#!/bin/sh\nprintf "unmanaged legacy\\n"\n' \
    > "$LEGACY_REPO/.git/hooks/pre-push.legacy"
chmod +x \
    "$LEGACY_REPO/.git/hooks/pre-push" \
    "$LEGACY_REPO/.git/hooks/pre-push.legacy"
legacy_digest=$(sha256_file "$LEGACY_REPO/.git/hooks/pre-push.legacy")
run_installer "$LEGACY_REPO" true 3.8.0 "$TMP/unmanaged-legacy.out"
legacy_status=$?
legacy_after=$(sha256_file "$LEGACY_REPO/.git/hooks/pre-push.legacy")
if [ "$unmanaged_status" -ne 0 ] &&
    [ "$unmanaged_digest" = "$unmanaged_after" ] &&
    [ "$legacy_status" -ne 0 ] && [ "$legacy_digest" = "$legacy_after" ] &&
    grep -q 'unmanaged pre-commit hook already exists' \
        "$TMP/unmanaged-hook.out" &&
    grep -q 'unmanaged legacy pre-push hook already exists' \
        "$TMP/unmanaged-legacy.out"; then
    pass "install rejects conflicts without changing unmanaged hook content"
else
    sed 's/^/    /' "$TMP/unmanaged-hook.out" >&2
    sed 's/^/    /' "$TMP/unmanaged-legacy.out" >&2
    fail "install changed or accepted unmanaged hook content"
fi

info "ambient Python startup controls do not enter helper commands"
POISON_REPO="$TMP/poisoned-environment"
make_repo "$POISON_REPO"
write_config "$POISON_REPO" 'pre-commit pre-push' poisoned-environment
mkdir -p "$TMP/hostile-python"
cat > "$TMP/hostile-python/sitecustomize.py" <<PY
from pathlib import Path
Path("$TMP/sitecustomize-ran").write_text("unsafe", encoding="utf-8")
PY
env \
    PATH="$INSTALL_BIN:/usr/bin:/bin" \
    HOME="$TMP/ambient-home" \
    PYTHONPATH="$TMP/hostile-python" \
    PYTHONHOME="$TMP/missing-python-home" \
    ATTACK_MARKER=present \
    ODYSSEUS_ROOT="$POISON_REPO" \
    ODYSSEUS_PRECOMMIT_BINARY="$PRECOMMIT_FIXTURE" \
    ODYSSEUS_PRECOMMIT_EXPECTED_VERSION=3.8.0 \
    INSTALL=true \
    /bin/bash "$POISON_REPO/$INSTALL_WRAPPER_REL" \
    > "$TMP/poisoned-environment.out" 2>&1
poison_status=$?
if [ "$poison_status" -eq 0 ] && [ ! -e "$TMP/sitecustomize-ran" ]; then
    pass "the version probe and hook commands use a clean Python environment"
else
    sed 's/^/    /' "$TMP/poisoned-environment.out" >&2
    fail "ambient Python startup state entered the trusted helper boundary"
fi

run_helper() {
    local repo=$1 pre_commit=$2 mode=$3 timeout=$4 output=$5
    env TMPDIR="$TMP/helper-tmp" \
        python3 -I -S "$ROOT/$HELPER_REL" \
        --root "$repo" \
        --pre-commit "$pre_commit" \
        --git "$SYSTEM_GIT" \
        --mode "$mode" \
        --timeout "$timeout" > "$output" 2>&1
}

info "FIFO input and a hung child fail within the helper deadline"
mkdir -p "$TMP/helper-tmp"
FIFO_REPO="$TMP/fifo-config"
make_repo "$FIFO_REPO"
mkfifo "$FIFO_REPO/.pre-commit-config.yaml"
run_helper "$FIFO_REPO" "$PRECOMMIT_FIXTURE" check 2 "$TMP/fifo.out"
fifo_status=$?

HUNG_PRECOMMIT="$INSTALL_BIN/pre-commit-hung"
cat > "$HUNG_PRECOMMIT" <<'SH'
#!/bin/bash
trap '' TERM
while :; do
    sleep 1
done
SH
chmod +x "$HUNG_PRECOMMIT"
HUNG_REPO="$TMP/hung-child"
make_repo "$HUNG_REPO"
write_config "$HUNG_REPO" 'pre-commit pre-push' hung-child
python3 -I -S - \
    "$ROOT/$HELPER_REL" "$HUNG_REPO" "$HUNG_PRECOMMIT" \
    "$SYSTEM_GIT" "$TMP/hung.out" <<'PY'
import os
import subprocess
import sys

helper, root, pre_commit, git, output = sys.argv[1:]
command = [
    sys.executable, "-I", "-S", helper,
    "--root", root,
    "--pre-commit", pre_commit,
    "--git", git,
    "--mode", "check",
    "--timeout", "0.2",
]
try:
    result = subprocess.run(
        command,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=5,
        check=False,
    )
except subprocess.TimeoutExpired:
    with open(output, "wb") as stream:
        stream.write(b"outer watchdog expired\n")
    raise SystemExit(99)
with open(output, "wb") as stream:
    stream.write(result.stdout)
raise SystemExit(result.returncode)
PY
hung_status=$?
if [ "$fifo_status" -ne 0 ] && [ "$hung_status" -ne 0 ] &&
    [ "$hung_status" -ne 99 ] &&
    grep -q 'not a direct regular file' "$TMP/fifo.out" &&
    grep -q 'command timed out' "$TMP/hung.out"; then
    pass "FIFO reads and hung process groups terminate with clear failures"
else
    sed 's/^/    /' "$TMP/fifo.out" >&2
    sed 's/^/    /' "$TMP/hung.out" >&2
    fail "a FIFO or hung child escaped the bounded failure contract"
fi

info "one repository failure does not hide a later repository failure"
AGGREGATE_REPO="$TMP/aggregate-failures"
make_repo "$AGGREGATE_REPO"
write_config "$AGGREGATE_REPO" 'pre-commit pre-push' aggregate-alpha fail-alpha
mkdir -p "$AGGREGATE_REPO/child"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -c init.templateDir= -C "$AGGREGATE_REPO/child" init -q
write_config "$AGGREGATE_REPO/child" commit-msg aggregate-beta fail-beta
run_installer "$AGGREGATE_REPO" true 3.8.0 "$TMP/aggregate.out"
aggregate_status=$?
if [ "$aggregate_status" -ne 0 ] &&
    grep -q 'fixture validation failure: alpha' "$TMP/aggregate.out" &&
    grep -q 'fixture validation failure: beta' "$TMP/aggregate.out"; then
    pass "the installer reports each repository failure in one run"
else
    sed 's/^/    /' "$TMP/aggregate.out" >&2
    fail "the installer stopped before it reported all repository failures"
fi

info "cleanup preserves a replacement at a swapped temporary-root name"
SWAP_PRECOMMIT="$INSTALL_BIN/pre-commit-cleanup-swap"
cat > "$SWAP_PRECOMMIT" <<'SH'
#!/bin/bash
set -eu
if [ "${1:-}" != --version ]; then
    exit 76
fi
tree=${HOME%/home}
mv "$tree" "$tree.original"
mkdir -m 700 "$tree"
printf 'replacement\n' > "$tree/replacement-marker"
printf 'pre-commit 3.8.0\n'
SH
chmod +x "$SWAP_PRECOMMIT"
SWAP_REPO="$TMP/cleanup-swap"
make_repo "$SWAP_REPO"
write_config "$SWAP_REPO" 'pre-commit pre-push' cleanup-swap
SWAP_TMP="$TMP/cleanup-swap-tmp"
mkdir -p "$SWAP_TMP"
env TMPDIR="$SWAP_TMP" \
    python3 -I -S "$ROOT/$HELPER_REL" \
    --root "$SWAP_REPO" \
    --pre-commit "$SWAP_PRECOMMIT" \
    --git "$SYSTEM_GIT" \
    --mode check \
    --timeout 1 > "$TMP/cleanup-swap.out" 2>&1
swap_status=$?
replacement_count=$(find "$SWAP_TMP" -name replacement-marker -type f | wc -l | tr -d ' ')
if { [ "$swap_status" -ne 0 ] && [ "$replacement_count" -eq 1 ] &&
        grep -q 'directory changed after binding' "$TMP/cleanup-swap.out" &&
        grep -q 'cannot safely clean temporary resources' "$TMP/cleanup-swap.out"; } ||
    { [ "$swap_status" -ne 0 ] && [ "$replacement_count" -eq 0 ] &&
        grep -Eq 'Read-only file system|Device or resource busy' \
            "$TMP/cleanup-swap.out"; }; then
    pass "the boundary blocks a root swap or cleanup preserves its replacement"
else
    sed 's/^/    /' "$TMP/cleanup-swap.out" >&2
    fail "cleanup removed or ignored a replacement at a swapped name"
fi

info "the real locked pre-commit 3.8.0 owns YAML hook-type semantics"
if REAL_PRECOMMIT=$(command -v pre-commit 2>/dev/null); then
    REAL_REPO="$TMP/real-precommit"
    make_repo "$REAL_REPO"
    printf '%s\n' \
        'default_install_hook_types: [pre-commit, pre-push]' \
        'repos: []' > "$REAL_REPO/.pre-commit-config.yaml"
    mkdir -p "$REAL_REPO/quoted-block"
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -c init.templateDir= \
        -C "$REAL_REPO/quoted-block" init -q
    printf '%s\n' \
        '"default_install_hook_types":' \
        '  - "commit-msg"' \
        'repos: []' > "$REAL_REPO/quoted-block/.pre-commit-config.yaml"
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -C "$REAL_REPO" \
        -c user.name='Hook Test' \
        -c user.email='hook@example.invalid' \
        -c commit.gpgsign=false \
        commit --allow-empty -qm fixture
    real_head=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -C "$REAL_REPO" rev-parse HEAD)
    mkdir -p "$TMP/real-version-home"
    real_version=$(
        env -i PATH="$(dirname "$REAL_PRECOMMIT"):/usr/bin:/bin" \
            HOME="$TMP/real-version-home" \
            "$REAL_PRECOMMIT" --version 2>/dev/null | awk '{print $2}'
    )
    if [ "$real_version" = 3.8.0 ]; then
        env \
            PATH="$(dirname "$REAL_PRECOMMIT"):/usr/bin:/bin" \
            HOME="$TMP/real-version-home" \
            GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 \
            ODYSSEUS_ROOT="$REAL_REPO" \
            ODYSSEUS_PRECOMMIT_BINARY="$REAL_PRECOMMIT" \
            ODYSSEUS_PRECOMMIT_EXPECTED_VERSION="$real_version" \
            INSTALL=true \
            /bin/bash "$REAL_REPO/$INSTALL_WRAPPER_REL" \
            > "$TMP/real-precommit.out" 2>&1
        real_status=$?
        printf '%s\n%s\n' \
            "refs/heads/deleted $ZERO refs/heads/deleted remote-deleted" \
            "refs/heads/topic $real_head refs/heads/topic $ZERO" \
            > "$TMP/real-installed-hook.input"
        printf '%s\0' 'upstream remote' \
            'ssh://upstream.invalid/repo with space' \
            > "$TMP/real-installed-hook.expected-args"
        mkdir -p "$TMP/real-hook-home" "$TMP/real-hook-cache"
        (
            cd "$REAL_REPO" || exit 90
            env \
                PATH="$(dirname "$REAL_PRECOMMIT"):/usr/bin:/bin" \
                HOME="$TMP/real-hook-home" \
                PRE_COMMIT_HOME="$TMP/real-hook-cache" \
                GIT_CONFIG_GLOBAL=/dev/null \
                GIT_CONFIG_NOSYSTEM=1 \
                HOOK_ARGC_LOG="$TMP/real-installed-hook.argc" \
                HOOK_ARGS_LOG="$TMP/real-installed-hook.args" \
                HOOK_STDIN_LOG="$TMP/real-installed-hook.stdin" \
                "$REAL_REPO/.git/hooks/pre-push" \
                'upstream remote' 'ssh://upstream.invalid/repo with space'
        ) < "$TMP/real-installed-hook.input" \
            > "$TMP/real-installed-hook.out" 2>&1
        real_hook_status=$?
        real_root_inventory=$(hook_inventory "$REAL_REPO")
        real_child_inventory=$(hook_inventory "$REAL_REPO/quoted-block")
        if [ "$real_status" -eq 0 ] && [ "$real_hook_status" -eq 0 ] &&
            [ "$real_root_inventory" = $'pre-commit\npre-push\npre-push.legacy' ] &&
            [ "$real_child_inventory" = commit-msg ] &&
            cmp -s "$TMP/real-installed-hook.input" \
                "$TMP/real-installed-hook.stdin" &&
            grep -qx '2' "$TMP/real-installed-hook.argc" &&
            cmp -s "$TMP/real-installed-hook.expected-args" \
                "$TMP/real-installed-hook.args"; then
            pass "real pre-commit 3.8.0 preserves exact push arguments"
        else
            sed 's/^/    /' "$TMP/real-precommit.out" >&2
            sed 's/^/    /' "$TMP/real-installed-hook.out" >&2
            fail "real pre-commit 3.8.0 lost YAML selection or the push transaction"
        fi
    else
        fail "real pre-commit 3.8.0 is required; found ${real_version:-unknown}"
    fi
else
    fail "real pre-commit 3.8.0 is required; no executable was found"
fi

RED_HARNESS="$TMP/precommit-red-harness.py"
cat > "$RED_HARNESS" <<'PY'
#!/usr/bin/env python3
"""Behavior fault harness for the pre-commit installer boundary."""

import errno
import importlib.util
import os
import resource
import shutil
import shlex
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time


def load_subject(path):
    sys.dont_write_bytecode = True
    spec = importlib.util.spec_from_file_location("precommit_hooks_subject", path)
    subject = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = subject
    spec.loader.exec_module(subject)
    return subject


def write_file(path, data, mode=0o644):
    with open(path, "wb") as stream:
        stream.write(data)
    os.chmod(path, mode)


def route_snapshot(path):
    entries = {}
    for name in sorted(os.listdir(path)):
        entry = os.path.join(path, name)
        item = os.lstat(entry)
        if not stat.S_ISREG(item.st_mode):
            entries[name] = (item.st_ino, stat.S_IFMT(item.st_mode), None)
            continue
        with open(entry, "rb") as stream:
            data = stream.read()
        entries[name] = (item.st_ino, stat.S_IMODE(item.st_mode), data)
    item = os.stat(path, follow_symlinks=False)
    return (item.st_dev, item.st_ino, stat.S_IMODE(item.st_mode), entries)


class InstallFixture:
    def __init__(self, subject, base, active, hooks_mode=0o755,
                 preserved=False):
        self.subject = subject
        self.root = tempfile.mkdtemp(prefix="install-transaction-", dir=base)
        self.git = os.path.join(self.root, ".git")
        self.hooks_path = os.path.join(self.git, "hooks")
        os.makedirs(self.hooks_path)
        os.chmod(self.hooks_path, hooks_mode)
        os.makedirs(os.path.join(self.root, ".githooks"))
        self.native_data = b"#!/bin/sh\nprintf 'native signed boundary\\n'\n"
        self.native_path = os.path.join(self.root, ".githooks", "pre-push")
        write_file(self.native_path, self.native_data, 0o755)
        self.config_path = os.path.join(self.root, ".pre-commit-config.yaml")
        write_file(
            self.config_path,
            b"default_install_hook_types: [pre-push]\nrepos: []\n",
        )
        self.payload = b"opaque generated hook bytes\n"
        active_path = os.path.join(self.hooks_path, "pre-push")
        if active == "native":
            write_file(active_path, self.native_data, 0o755)
        else:
            raise ValueError(active)
        self.preserved = {}
        if preserved:
            entries = (
                ("pre-push.legacy", self.native_data, 0o755),
                ("local audit hook", b"#!/bin/sh\nprintf 'unmanaged\\n'\n", 0o750),
                ("pre-commit.sample", b"sample bytes with spaces\n", 0o640),
            )
            for name, data, mode in entries:
                write_file(os.path.join(self.hooks_path, name), data, mode)
                self.preserved[name] = (data, mode)
        self.hooks_mode = hooks_mode
        hooks = subject.BoundDir.open(self.hooks_path, safe=True)
        self.repo = subject.Repo(
            path=self.root,
            label=".",
            config=subject.BoundFile.open(self.config_path),
            directory=subject.BoundDir.open(self.root),
            git_dir=subject.BoundDir.open(self.git, safe=True),
            common=subject.BoundDir.open(self.git, safe=True),
            hooks=hooks,
            before=subject.inventory(hooks),
        )
        self.native = subject.BoundFile.open(self.native_path, executable=True)

    def close(self):
        self.repo.close()
        shutil.rmtree(self.root, ignore_errors=True)


def committed_publication_behavior(subject, base):
    fixture = InstallFixture(subject, base, "native")
    before = route_snapshot(fixture.hooks_path)
    payloads = {"pre-push": b"opaque generated hook bytes\n"}
    saw_commit = {"value": False}

    def fail_after_commit():
        try:
            with open(
                os.path.join(fixture.hooks_path, "pre-push"), "rb"
            ) as stream:
                live = stream.read()
        except OSError:
            return
        if live == payloads["pre-push"]:
            saw_commit["value"] = True
            raise subject.SetupError("injected post-commit verification failure")

    error = None
    try:
        subject.install(
            fixture.repo,
            {"pre-push"},
            payloads,
            fixture.native,
            fixture.root,
            fail_after_commit,
        )
    except (OSError, subject.SetupError) as caught:
        error = caught

    message = str(error) if error is not None else ""
    reported_paths = []
    for token in message.split():
        path = token.strip("'\"(),:;")
        if (
            os.path.isabs(path)
            and os.path.dirname(path) == fixture.git
            and path != fixture.hooks_path
        ):
            reported_paths.append(path)
    reported_paths = sorted(set(reported_paths))
    recovery_path = reported_paths[0] if len(reported_paths) == 1 else None
    active = None
    recovery = None
    try:
        active = route_snapshot(fixture.hooks_path)
    except OSError:
        pass
    if recovery_path is not None:
        try:
            recovery = route_snapshot(recovery_path)
        except OSError:
            pass
    active_entries = active[3] if active is not None else {}
    active_exact = (
        active_entries.get("pre-push", (None, None, None))[2]
        == payloads["pre-push"]
        and active_entries.get("pre-push.legacy", (None, None, None))[2]
        == fixture.native_data
    )
    safe = (
        saw_commit["value"]
        and error is not None
        and fixture.hooks_path in message
        and recovery_path is not None
        and active_exact
        and recovery == before
    )
    if not safe:
        print(
            "post-commit failure lost or hid a route: "
            "commit={}, active={}, recovery={}, reported={}, error={!r}".format(
                saw_commit["value"], active_exact, recovery == before,
                reported_paths, message,
            )
        )
    fixture.close()
    return safe


def directory_preservation_behavior(subject, base):
    broken = []
    for mode in (0o750, 0o755):
        fixture = InstallFixture(
            subject, base, "native", hooks_mode=mode, preserved=True
        )
        error = None
        try:
            subject.install(
                fixture.repo,
                {"pre-push"},
                {"pre-push": fixture.payload},
                fixture.native,
                fixture.root,
                lambda: None,
            )
        except (OSError, subject.SetupError) as caught:
            error = caught
        actual = route_snapshot(fixture.hooks_path)
        entries = actual[3]
        expected_names = set(fixture.preserved) | {"pre-push"}
        installed = (
            entries.get("pre-push", (None, None, None))[1:] ==
            (0o755, fixture.payload)
        )
        preserved = all(
            entries.get(name, (None, None, None))[1:] == (value[1], value[0])
            for name, value in fixture.preserved.items()
        )
        if (error is not None or set(entries) != expected_names or
                actual[2] != mode or not installed or not preserved):
            broken.append(
                "{:04o}(error={},names={},mode={:04o},installed={},bytes={})".format(
                    mode, error, sorted(entries), actual[2], installed, preserved
                )
            )
        fixture.close()
    if broken:
        print("hooks directory metadata or untouched bytes changed: {}".format(
            ", ".join(broken)
        ))
        return False
    return True


def process_group_behavior(subject, base):
    flood_marker = os.path.join(base, "flood-reached-tail")
    flood_script = os.path.join(base, "flood.py")
    write_file(
        flood_script,
        (
            "import os, sys\n"
            "chunk = b'x' * 65536\n"
            "for index in range(256):\n"
            "    os.write(1, chunk)\n"
            "    if index == 63:\n"
            "        open({!r}, 'wb').write(b'tail')\n".format(flood_marker)
        ).encode("utf-8"),
    )
    flood_failed = False
    try:
        subject.run([sys.executable, "-I", "-S", flood_script], base, {}, 5)
    except subject.SetupError as error:
        flood_failed = "output exceeded" in str(error)
    flood_killed_at_limit = flood_failed and not os.path.exists(flood_marker)

    state = {
        "leader_exited": False,
        "leader_reaped": False,
        "member_alive": True,
        "signal_after_reap": False,
    }

    class ControlledProcess:
        pid = 424242

        def __init__(self, *_args, **_kwargs):
            read_out, write_out = os.pipe()
            read_err, write_err = os.pipe()
            os.close(write_out)
            os.close(write_err)
            self.stdout = os.fdopen(read_out, "rb", buffering=0)
            self.stderr = os.fdopen(read_err, "rb", buffering=0)
            self.returncode = None

        def poll(self):
            if state["leader_reaped"]:
                self.returncode = 0
                return 0
            if state["leader_exited"]:
                state["leader_reaped"] = True
                self.returncode = 0
                return 0
            return None

        def wait(self, timeout=None):
            if not state["leader_exited"]:
                raise subprocess.TimeoutExpired("controlled", timeout)
            state["leader_reaped"] = True
            self.returncode = 0
            return 0

    original_popen = subject.subprocess.Popen
    original_killpg = subject.os.killpg
    original_getpgid = subject.os.getpgid
    original_getsid = subject.os.getsid
    original_monotonic = subject.time.monotonic
    clock = {"value": 0}

    def monotonic():
        clock["value"] += 1
        return clock["value"]

    def killpg(pid, sig):
        if pid != ControlledProcess.pid:
            raise AssertionError("unexpected process group: {}".format(pid))
        if sig != 0 and state["leader_reaped"]:
            state["signal_after_reap"] = True
            raise ProcessLookupError
        if sig == signal.SIGTERM:
            state["leader_exited"] = True
            return
        if sig == signal.SIGKILL:
            state["leader_exited"] = True
            state["member_alive"] = False
            return
        if sig == 0:
            if state["member_alive"] or not state["leader_reaped"]:
                return
            raise ProcessLookupError
        raise AssertionError("unexpected group signal: {}".format(sig))

    subject.subprocess.Popen = ControlledProcess
    subject.os.killpg = killpg
    subject.os.getpgid = lambda pid: pid
    subject.os.getsid = lambda pid: pid
    subject.time.monotonic = monotonic
    timed_out = False
    try:
        try:
            subject.run(["controlled-child"], base, {}, 0.5)
        except subject.SetupError as error:
            timed_out = "timed out" in str(error)
    finally:
        subject.subprocess.Popen = original_popen
        subject.os.killpg = original_killpg
        subject.os.getpgid = original_getpgid
        subject.os.getsid = original_getsid
        subject.time.monotonic = original_monotonic
    if not flood_killed_at_limit:
        print("output producer reached its tail after the configured byte limit")
    if (not timed_out or state["member_alive"] or
            state["signal_after_reap"] or not state["leader_reaped"]):
        print(
            "timeout returned without safe group extinction: "
            "timed_out={}, member_alive={}, reaped={}, signal_after_reap={}".format(
                timed_out, state["member_alive"], state["leader_reaped"],
                state["signal_after_reap"],
            )
        )
    return (
        flood_killed_at_limit
        and timed_out
        and not state["member_alive"]
        and state["leader_reaped"]
        and not state["signal_after_reap"]
    )


def signal_cancellation_behavior(subject, base):
    broken = []
    child_code = "import signal; signal.pause()"
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        original_popen = subject.subprocess.Popen
        state = {"process": None, "cancelled": False}

        def signal_during_return(*args, **kwargs):
            process = original_popen(*args, **kwargs)
            state["process"] = process
            os.kill(os.getpid(), sig)
            return process

        subject.subprocess.Popen = signal_during_return
        try:
            try:
                subject.run(
                    [sys.executable, "-I", "-S", "-c", child_code],
                    base,
                    {},
                    10,
                )
            except subject.SetupError as error:
                state["cancelled"] = signal.Signals(sig).name in str(error)
        finally:
            subject.subprocess.Popen = original_popen

        process = state["process"]
        extinct = False
        if process is not None:
            try:
                os.killpg(process.pid, 0)
            except ProcessLookupError:
                extinct = True
        if process is None or not state["cancelled"] or not extinct:
            broken.append(
                "{}(spawned={},cancelled={},extinct={})".format(
                    signal.Signals(sig).name, process is not None,
                    state["cancelled"], extinct,
                )
            )
        if process is not None and not extinct:
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
        if process is not None:
            try:
                process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=1)
    if broken:
        print(
            "spawn-window cancellation returned before teardown: {}".format(
                ", ".join(broken)
            )
        )
        return False
    return True


def terminal_cancellation_behavior(helper, base, git, signal_name):
    """A cancellation from one repository stops aggregation immediately."""

    subject = load_subject(helper)
    root = tempfile.mkdtemp(
        prefix="terminal-{}-".format(signal_name.lower()), dir=base
    )
    child = os.path.join(root, "child")
    native_dir = os.path.join(root, ".githooks")
    os.makedirs(native_dir)
    write_file(
        os.path.join(native_dir, "pre-push"),
        b"#!/bin/sh\nexit 0\n",
        0o755,
    )
    root_config = os.path.join(root, ".pre-commit-config.yaml")
    child_config = os.path.join(child, ".pre-commit-config.yaml")
    write_file(root_config, b"repos: []\n")
    os.mkdir(child)
    write_file(child_config, b"repos: []\n")
    pre_commit = os.path.join(root, "terminal-pre-commit")
    git_tool = os.path.join(root, "terminal-git")
    write_file(pre_commit, b"#!/bin/sh\nexit 0\n", 0o755)
    write_file(git_tool, b"#!/bin/sh\nexit 0\n", 0o755)

    class FakeRepo:
        def __init__(self, path):
            self.path = path
            self.label = "." if path == root else "child"
            self.closed = False

        def close(self):
            self.closed = True

    calls = []
    closed = []
    emitted = []
    originals = {
        "require": subject.ReadOnlyExecutionBoundary.require,
        "run": subject.run,
        "configs_under": subject.configs_under,
        "bind_repo": subject.bind_repo,
        "generate": subject.generate,
        "emit": subject.emit,
    }

    def bind_repo(_root, config_path, _git, _env, _timeout):
        repo = FakeRepo(os.path.dirname(config_path))
        original_close = repo.close

        def close():
            original_close()
            closed.append(repo.label)

        repo.close = close
        return repo

    def generate(repo, *_args, **_kwargs):
        calls.append(repo.label)
        raise subject.CancellationError(getattr(signal, signal_name))

    subject.ReadOnlyExecutionBoundary.require = lambda _self: None
    subject.run = lambda _argv, _cwd, _env, _timeout: (
        0, b"pre-commit 3.8.0\n", b""
    )
    subject.configs_under = lambda _root: [root_config, child_config]
    subject.bind_repo = bind_repo
    subject.generate = generate
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )
    try:
        status = subject.main([
            "--root", root,
            "--pre-commit", pre_commit,
            "--git", git_tool,
            "--mode", "install",
            "--expected-version", "3.8.0",
            "--timeout", "2",
        ])
    finally:
        subject.ReadOnlyExecutionBoundary.require = originals["require"]
        subject.run = originals["run"]
        subject.configs_under = originals["configs_under"]
        subject.bind_repo = originals["bind_repo"]
        subject.generate = originals["generate"]
        subject.emit = originals["emit"]

    safe = (
        status != 0
        and calls == ["."]
        and closed == ["."]
        and any(
            "command cancelled by {}".format(signal_name) in line
            for line in emitted
        )
    )
    if not safe:
        print(
            "{} cancellation was not terminal: status={}, calls={!r}, "
            "closed={!r}, messages={!r}".format(
                signal_name, status, calls, closed, emitted
            )
        )
    shutil.rmtree(root, ignore_errors=True)
    return safe


def teardown_cancellation_behavior(subject, base, signal_name):
    original_stop_group = subject.stop_group
    state = {"fired": False}

    def cancel_after_teardown(*args, **kwargs):
        result = original_stop_group(*args, **kwargs)
        state["fired"] = True
        os.kill(os.getpid(), getattr(signal, signal_name))
        return result

    subject.stop_group = cancel_after_teardown
    result = None
    error = None
    try:
        try:
            result = subject.run(
                [sys.executable, "-I", "-S", "-c", "pass"],
                base,
                {},
                5,
            )
        except BaseException as caught:
            error = caught
    finally:
        subject.stop_group = original_stop_group
    cancellation_type = getattr(subject, "CancellationError", None)
    safe = (
        state["fired"]
        and result is None
        and cancellation_type is not None
        and isinstance(error, cancellation_type)
        and signal_name in str(error)
    )
    if not safe:
        print(
            "{} during final teardown was lost: fired={}, result={!r}, "
            "error={!r}".format(signal_name, state["fired"], result, error)
        )
    return safe


def observer_exit_latch_behavior(subject):
    class OneShotQueue:
        def __init__(self):
            self.calls = 0

        def control(self, _changes, _events, _timeout):
            self.calls += 1
            return [object()] if self.calls == 1 else []

    observer = subject.LeaderObserver.__new__(subject.LeaderObserver)
    observer.pid = 424242
    observer.kind = "kqueue"
    observer.queue = OneShotQueue()
    observer.seen = False
    first = observer.exited()
    second = observer.exited()
    if not first or not second:
        print(
            "a one-shot exit notification was forgotten: first={}, second={}".format(
                first, second
            )
        )
        return False
    return True


def short_write_behavior(subject, base, git):
    config_path = os.path.join(base, "short-write-source.yaml")
    prefix = b"repos: []\n"
    source = prefix + b"default_install_hook_types: [pre-commit, pre-push]\n"
    write_file(config_path, source)
    config = subject.BoundFile.open(config_path)
    tree = subject.PrivateTree()
    original_open = subject.os.open
    original_write = subject.os.write
    state = {"descriptor": None, "fired": False}

    def tracked_open(path, flags, mode=0o777, *, dir_fd=None):
        descriptor = original_open(path, flags, mode, dir_fd=dir_fd)
        if (
            os.path.basename(os.fspath(path)) == ".pre-commit-config.yaml"
            and flags & (os.O_WRONLY | os.O_RDWR)
            and flags & os.O_CREAT
        ):
            state["descriptor"] = descriptor
        return descriptor

    def short_write(descriptor, data):
        if descriptor == state["descriptor"] and not state["fired"]:
            state["fired"] = True
            return original_write(descriptor, data[: len(prefix)])
        return original_write(descriptor, data)

    subject.os.open = tracked_open
    subject.os.write = short_write
    result = None
    rejected = False
    home = tree.mkdir("short-home")
    cache = tree.mkdir("short-cache")
    environment = subject.clean_env(git, git, home, cache)
    try:
        try:
            _, result = subject.shadow_repo(
                tree, "short-repo", config, git, environment, 5
            )
        except (OSError, subject.SetupError):
            rejected = True
    finally:
        subject.os.open = original_open
        subject.os.write = original_write
        tree.close()
    exact = result is not None and result.data == source
    if not state["fired"] or not (rejected or exact):
        print("a permitted short write produced truncated valid configuration bytes")
        return False
    return True


def descriptor_count():
    for path in ("/proc/self/fd", "/dev/fd"):
        try:
            return len(os.listdir(path))
        except OSError:
            continue
    raise RuntimeError("no descriptor inventory is available")


def descriptor_numbers():
    for path in ("/proc/self/fd", "/dev/fd"):
        try:
            return {
                int(name) for name in os.listdir(path) if name.isdigit()
            }
        except OSError:
            continue
    raise RuntimeError("no descriptor inventory is available")


def acquisition_failure_behavior(subject, base):
    broken = []
    original_tempdir = tempfile.tempdir
    original_mkdir = subject.os.mkdir
    original_open = subject.os.open
    tempfile.tempdir = base
    for fault in ("private-mkdir", "private-root-open"):
        before_names = set(os.listdir(base))
        before_fds = descriptor_numbers()
        state = {"name": None, "fired": False}

        def mkdir_fault(path, mode=0o777, *, dir_fd=None):
            if dir_fd is not None and state["name"] is None:
                state["name"] = os.fspath(path)
                if fault == "private-mkdir":
                    state["fired"] = True
                    raise OSError(errno.EIO, "injected private mkdir failure")
            return original_mkdir(path, mode, dir_fd=dir_fd)

        def open_fault(path, flags, mode=0o777, *, dir_fd=None):
            if (
                fault == "private-root-open"
                and state["name"] is not None
                and os.path.basename(os.fspath(path)) == state["name"]
                and flags & os.O_DIRECTORY
            ):
                state["fired"] = True
                raise OSError(errno.EIO, "injected private root-open failure")
            return original_open(path, flags, mode, dir_fd=dir_fd)

        subject.os.mkdir = mkdir_fault
        subject.os.open = open_fault
        error = None
        try:
            try:
                subject.PrivateTree()
            except (OSError, subject.SetupError) as caught:
                error = caught
        finally:
            subject.os.mkdir = original_mkdir
            subject.os.open = original_open
        after_names = set(os.listdir(base))
        after_fds = descriptor_numbers()
        leaked_fds = sorted(after_fds - before_fds)
        leftovers = sorted(after_names - before_names)
        expected_leftovers = (
            [state["name"]] if fault == "private-root-open" else []
        )
        preserved_path = (
            os.path.join(base, state["name"])
            if fault == "private-root-open" and state["name"] is not None
            else None
        )
        reported = (
            preserved_path is None or
            (error is not None and preserved_path in str(error))
        )
        for descriptor in leaked_fds:
            try:
                os.close(descriptor)
            except OSError:
                pass
        for name in leftovers:
            shutil.rmtree(os.path.join(base, name), ignore_errors=True)
        if (not state["fired"] or error is None or leaked_fds or
                leftovers != expected_leftovers or not reported):
            broken.append(
                "{}(fired={},error={},fds={},paths={},reported={})".format(
                    fault, state["fired"], error, leaked_fds, leftovers,
                    reported,
                )
            )

    tempfile.tempdir = original_tempdir
    for fault in ("candidate-mkdir", "candidate-bind"):
        fixture = InstallFixture(subject, base, "native")
        before_names = set(os.listdir(fixture.git))
        before_fds = descriptor_numbers()
        state = {"name": None, "fired": False}

        def mkdir_fault(path, mode=0o777, *, dir_fd=None):
            if dir_fd == fixture.repo.common.descriptor:
                state["name"] = os.fspath(path)
                if fault == "candidate-mkdir":
                    state["fired"] = True
                    raise OSError(errno.EIO, "injected candidate mkdir failure")
            return original_mkdir(path, mode, dir_fd=dir_fd)

        def open_fault(path, flags, mode=0o777, *, dir_fd=None):
            if (
                fault == "candidate-bind"
                and state["name"] is not None
                and os.fspath(path) == state["name"]
                and dir_fd == fixture.repo.common.descriptor
                and flags & os.O_DIRECTORY
            ):
                state["fired"] = True
                raise OSError(errno.EIO, "injected candidate bind failure")
            return original_open(path, flags, mode, dir_fd=dir_fd)

        subject.os.mkdir = mkdir_fault
        subject.os.open = open_fault
        error = None
        try:
            try:
                subject.install(
                    fixture.repo,
                    {"pre-push"},
                    {"pre-push": b"opaque generated hook bytes\n"},
                    fixture.native,
                    fixture.root,
                    lambda: None,
                )
            except (OSError, subject.SetupError) as caught:
                error = caught
        finally:
            subject.os.mkdir = original_mkdir
            subject.os.open = original_open
        after_names = set(os.listdir(fixture.git))
        after_fds = descriptor_numbers()
        leaked_fds = sorted(after_fds - before_fds)
        leftovers = sorted(after_names - before_names)
        expected_leftovers = (
            [state["name"]] if fault == "candidate-bind" else []
        )
        preserved_path = (
            os.path.join(fixture.git, state["name"])
            if fault == "candidate-bind" and state["name"] is not None
            else None
        )
        reported = (
            preserved_path is None or
            (error is not None and preserved_path in str(error))
        )
        for descriptor in leaked_fds:
            try:
                os.close(descriptor)
            except OSError:
                pass
        for name in leftovers:
            shutil.rmtree(os.path.join(fixture.git, name), ignore_errors=True)
        if (not state["fired"] or error is None or leaked_fds or
                leftovers != expected_leftovers or not reported):
            broken.append(
                "{}(fired={},error={},fds={},paths={},reported={})".format(
                    fault, state["fired"], error, leaked_fds, leftovers,
                    reported,
                )
            )
        fixture.close()

    if broken:
        print("acquisition failures violated recovery: {}".format(", ".join(broken)))
        return False
    return True


def descriptor_lifecycle_behavior(subject, base):
    root = tempfile.mkdtemp(prefix="descriptor-lifecycle-", dir=base)
    child = os.path.join(root, "child")
    os.mkdir(child, 0o700)
    parent = subject.BoundDir.open(root, safe=True)
    cases = (
        ("absolute", lambda: subject.BoundDir.open(child, safe=True)),
        (
            "relative",
            lambda: subject.BoundDir.open_at(
                parent.descriptor, "child", child, safe=True
            ),
        ),
    )
    broken = []
    for label, acquire in cases:
        before = descriptor_count()
        rejected = 0
        for _ in range(8):
            original_fstat = subject.os.fstat
            fired = {"value": False}

            def fail_after_open(descriptor):
                fired["value"] = True
                raise OSError(errno.EIO, "injected post-open failure")

            subject.os.fstat = fail_after_open
            try:
                try:
                    acquire()
                except (OSError, subject.SetupError):
                    rejected += 1
            finally:
                subject.os.fstat = original_fstat
            if not fired["value"]:
                broken.append("{}-fault-not-reached".format(label))
                break
        leaked = descriptor_count() - before
        if rejected != 8 or leaked != 0:
            broken.append(
                "{}(rejected={},fd-delta={})".format(label, rejected, leaked)
            )

    owned = subject.BoundDir.open(child, safe=True)
    closed_descriptor = owned.descriptor
    owned.close()
    sentinel = os.open(child, subject.DIR_FLAGS)
    close_error = False
    try:
        try:
            owned.close()
        except OSError:
            close_error = True
        try:
            os.fstat(sentinel)
            sentinel_alive = True
        except OSError:
            sentinel_alive = False
        if close_error or not sentinel_alive:
            broken.append(
                "idempotent-close(error={},reused={},sentinel={})".format(
                    close_error, sentinel == closed_descriptor, sentinel_alive
                )
            )
    finally:
        try:
            os.close(sentinel)
        except OSError:
            pass
        parent.close()
        shutil.rmtree(root, ignore_errors=True)
    if broken:
        print("descriptor ownership failures: {}".format(", ".join(broken)))
        return False
    return True


def descriptor_behavior(subject, base):
    inventory_root = os.path.join(base, "descriptor-inventory")
    os.makedirs(inventory_root)
    configs = []
    for index in range(40):
        repo = os.path.join(inventory_root, "repo-{:02d}".format(index))
        git_dir = os.path.join(repo, ".git")
        target = os.path.join(git_dir, "hooks-target")
        os.makedirs(target)
        os.symlink(target, os.path.join(git_dir, "hooks"))
        config = os.path.join(repo, ".pre-commit-config.yaml")
        write_file(config, b"repos: []\n")
        configs.append((repo, config))

    original_git_value = subject.git_value
    original_run = subject.run

    def controlled_git_value(_git, repo, args, _env, _timeout):
        if args == ["rev-parse", "--show-toplevel"]:
            return repo
        if args == ["rev-parse", "--absolute-git-dir"]:
            return os.path.join(repo, ".git")
        if args == ["rev-parse", "--git-common-dir"]:
            return os.path.join(repo, ".git")
        raise AssertionError(args)

    def controlled_run(argv, _cwd, _env, _timeout):
        if argv[-4:] == ["config", "--show-origin", "--get", "core.hooksPath"]:
            return (1, b"", b"")
        raise AssertionError(argv)

    subject.git_value = controlled_git_value
    subject.run = controlled_run
    before = descriptor_count()
    old_soft, old_hard = resource.getrlimit(resource.RLIMIT_NOFILE)
    limit = min(old_hard, 64) if old_hard != resource.RLIM_INFINITY else 64
    messages = []
    processed = 0
    try:
        resource.setrlimit(resource.RLIMIT_NOFILE, (limit, old_hard))
        for repo, config in configs:
            try:
                subject.bind_repo(
                    inventory_root, config, "/controlled/git", {}, 1
                )
            except (OSError, subject.SetupError) as error:
                messages.append(str(error))
            processed += 1
    finally:
        resource.setrlimit(resource.RLIMIT_NOFILE, (old_soft, old_hard))
        subject.git_value = original_git_value
        subject.run = original_run
    after = descriptor_count()
    no_exhaustion = not any("Too many open files" in message for message in messages)
    bounded = after - before <= 6
    complete = processed == len(configs) and len(messages) == len(configs)
    if not no_exhaustion or not bounded:
        print(
            "malformed repository inventory leaked descriptors: delta={}, emfile={}".format(
                after - before, not no_exhaustion
            )
        )
    return no_exhaustion and bounded and complete


def named_route_behavior(subject, base):
    fixture = InstallFixture(subject, base, "native")
    displaced = fixture.hooks_path + ".detached"
    state = {"fired": False}
    replacement = b"concurrent replacement route\n"

    def replace_committed_route():
        try:
            with open(
                os.path.join(fixture.hooks_path, "pre-push"), "rb"
            ) as stream:
                live = stream.read()
        except OSError:
            return
        if live != fixture.payload:
            return
        state["fired"] = True
        os.rename(fixture.hooks_path, displaced)
        os.mkdir(fixture.hooks_path, 0o755)
        write_file(os.path.join(fixture.hooks_path, "replacement"), replacement)
        raise subject.SetupError("injected live-route replacement")

    accepted = False
    try:
        subject.install(
            fixture.repo,
            {"pre-push"},
            {"pre-push": fixture.payload},
            fixture.native,
            fixture.root,
            replace_committed_route,
        )
        accepted = True
    except (OSError, subject.SetupError):
        pass
    committed_is_recoverable = False
    replacement_is_live = False
    try:
        detached_active = os.path.join(displaced, "pre-push")
        with open(detached_active, "rb") as stream:
            committed_is_recoverable = stream.read() == fixture.payload
        with open(os.path.join(fixture.hooks_path, "replacement"), "rb") as stream:
            replacement_is_live = stream.read() == replacement
    except OSError:
        pass
    fired = state["fired"]
    fixture.close()
    if (not fired or accepted or not committed_is_recoverable or
            not replacement_is_live):
        print("a swapped hooks-directory name was accepted through a detached descriptor")
        return False
    return True


def preserve_private_tree_closes(subject):
    """Keep private-tree bytes for an execution assertion, but close all fds."""

    original_close = subject.PrivateTree.close
    preserved = []

    def preserve(tree):
        preserved.append(tree.path)
        if tree.root is not None:
            tree.root.close()
        if tree.parent is not None:
            tree.parent.close()
        tree.root = None
        tree.parent = None
        return None

    subject.PrivateTree.close = preserve
    return original_close, preserved


def private_marker_exists(preserved, name):
    return any(
        os.path.isfile(os.path.join(path, "home", name))
        for path in preserved
    )


def discard_preserved_trees(paths):
    for path in paths:
        shutil.rmtree(path, ignore_errors=True)


def tool_swap_behavior(subject, base, git):
    broken = []
    for swap_target in ("pre-commit", "git"):
        root = tempfile.mkdtemp(
            prefix="{}-swap-".format(swap_target), dir=base
        )
        native_dir = os.path.join(root, ".githooks")
        os.mkdir(native_dir, 0o700)
        write_file(
            os.path.join(native_dir, "pre-push"),
            b"#!/bin/sh\nexit 0\n",
            0o755,
        )
        original_marker = "original-pre-commit-ran"
        replacement_marker = "replacement-pre-commit-ran"
        original_git_marker = "original-git-ran"
        replacement_git_marker = "replacement-git-ran"
        tool = os.path.join(root, "pre-commit")
        replacement = os.path.join(root, "pre-commit-replacement")
        git_tool = os.path.join(root, "git")
        git_replacement = os.path.join(root, "git-replacement")
        write_file(
            tool,
            (
                "#!/bin/sh\n"
                "git --version >/dev/null\n"
                "printf original > \"$HOME/{!s}\"\n"
                "printf 'pre-commit 3.8.0\\n'\n"
            ).format(original_marker).encode("utf-8"),
            0o755,
        )
        write_file(
            replacement,
            (
                "#!/bin/sh\n"
                "printf replacement > \"$HOME/{!s}\"\n"
                "printf 'pre-commit 3.8.0\\n'\n"
            ).format(replacement_marker).encode("utf-8"),
            0o755,
        )
        write_file(
            git_tool,
            (
                "#!/bin/sh\n"
                "printf original > \"$HOME/{!s}\"\n"
                "printf 'git version controlled\\n'\n"
            ).format(original_git_marker).encode("utf-8"),
            0o755,
        )
        write_file(
            git_replacement,
            (
                "#!/bin/sh\n"
                "printf replacement > \"$HOME/{!s}\"\n"
                "printf 'git version controlled\\n'\n"
            ).format(replacement_git_marker).encode("utf-8"),
            0o755,
        )

        original_popen = subject.subprocess.Popen
        original_close, preserved = preserve_private_tree_closes(subject)
        original_emit = subject.emit
        emitted = []
        subject.emit = lambda kind, message: emitted.append(
            "{}\t{}".format(kind, message)
        )
        state = {"swapped": False}
        descriptors_before = descriptor_count()

        def swap_at_spawn(*args, **kwargs):
            if not state["swapped"]:
                if swap_target == "pre-commit":
                    os.replace(replacement, tool)
                else:
                    os.replace(git_replacement, git_tool)
                state["swapped"] = True
            return original_popen(*args, **kwargs)

        subject.subprocess.Popen = swap_at_spawn
        try:
            status = subject.main([
                "--root", root,
                "--pre-commit", tool,
                "--git", git_tool,
                "--mode", "check",
                "--expected-version", "3.8.0",
                "--timeout", "5",
            ])
        finally:
            subject.subprocess.Popen = original_popen
            subject.PrivateTree.close = original_close
            subject.emit = original_emit

        original_ran = private_marker_exists(preserved, original_marker)
        replacement_ran = private_marker_exists(preserved, replacement_marker)
        original_git_ran = private_marker_exists(preserved, original_git_marker)
        replacement_git_ran = private_marker_exists(
            preserved, replacement_git_marker
        )
        descriptor_delta = descriptor_count() - descriptors_before
        swapped = state["swapped"]
        unavailable = status != 0 and not swapped and any(
            marker in line
            for marker in (
                "no trusted secure execution boundary",
                "no secure execution boundary",
            )
            for line in emitted
        )
        discard_preserved_trees(preserved)
        shutil.rmtree(root, ignore_errors=True)
        if unavailable:
            continue
        if (status == 0 or not swapped or replacement_ran or
                replacement_git_ran or not original_ran or
                not original_git_ran or descriptor_delta):
            broken.append(
                "{}(status={},swapped={},pre-commit={}/{},git={}/{},fds={})".format(
                    swap_target, status, swapped, original_ran,
                    replacement_ran, original_git_ran,
                    replacement_git_ran, descriptor_delta,
                )
            )
    if broken:
        print(
            "verified executable route selected different bytes: {}".format(
                ", ".join(broken)
            )
        )
        return False
    return True


def interpreter_swap_behavior(subject, base, git):
    root = tempfile.mkdtemp(prefix="interpreter-swap-", dir=base)
    native_dir = os.path.join(root, ".githooks")
    os.mkdir(native_dir, 0o700)
    write_file(
        os.path.join(native_dir, "pre-push"),
        b"#!/bin/sh\nexit 0\n",
        0o755,
    )
    original_marker = "original-interpreter-ran"
    replacement_marker = "replacement-interpreter-ran"
    interpreter = os.path.join(root, "python")
    replacement = os.path.join(root, "python-replacement")
    shutil.copyfile(sys.executable, interpreter)
    os.chmod(interpreter, 0o755)
    os.symlink("/bin/sh", replacement)
    tool = os.path.join(root, "pre-commit")
    write_file(
        tool,
        (
            "#!{}\n"
            "''':'\n"
            "printf replacement > \"$HOME/{!s}\"\n"
            "printf 'pre-commit 3.8.0\\n'\n"
            "exit 0\n"
            "':'''\n"
            "import os\n"
            "from pathlib import Path\n"
            "Path(os.environ['HOME'], {!r}).write_text('original', encoding='ascii')\n"
            "print('pre-commit 3.8.0')\n"
        ).format(
            interpreter, replacement_marker, original_marker
        ).encode("utf-8"),
        0o755,
    )

    original_popen = subject.subprocess.Popen
    original_close, preserved = preserve_private_tree_closes(subject)
    original_emit = subject.emit
    emitted = []
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )
    state = {"swapped": False}

    def swap_at_spawn(*args, **kwargs):
        if not state["swapped"]:
            os.replace(replacement, interpreter)
            state["swapped"] = True
        return original_popen(*args, **kwargs)

    subject.subprocess.Popen = swap_at_spawn
    try:
        status = subject.main([
            "--root", root,
            "--pre-commit", tool,
            "--git", git,
            "--mode", "check",
            "--expected-version", "3.8.0",
            "--timeout", "5",
        ])
    finally:
        subject.subprocess.Popen = original_popen
        subject.PrivateTree.close = original_close
        subject.emit = original_emit

    original_ran = private_marker_exists(preserved, original_marker)
    replacement_ran = private_marker_exists(preserved, replacement_marker)
    swapped = state["swapped"]
    unavailable = status != 0 and not swapped and any(
        marker in line
        for marker in (
            "no trusted secure execution boundary",
            "no secure execution boundary",
            "mutable interpreter/runtime closure",
        )
        for line in emitted
    )
    discard_preserved_trees(preserved)
    shutil.rmtree(root, ignore_errors=True)
    if unavailable:
        return True
    if status == 0 or not swapped or replacement_ran or not original_ran:
        print(
            "verified shebang selected different interpreter bytes: "
            "status={}, swapped={}, original={}, replacement={}".format(
                status, swapped, original_ran, replacement_ran
            )
            + ", messages={!r}".format(emitted)
        )
        return False
    return True


def execution_copy_write_behavior(subject, base, git, target):
    root = tempfile.mkdtemp(
        prefix="{}-copy-write-".format(target), dir=base
    )
    native_dir = os.path.join(root, ".githooks")
    os.mkdir(native_dir, 0o700)
    write_file(
        os.path.join(native_dir, "pre-push"),
        b"#!/bin/sh\nexit 0\n",
        0o755,
    )
    attempted_marker = "{}-write-attempted".format(target)
    original_marker = "original-{}-ran".format(target)
    replacement_marker = "replacement-{}-ran".format(target)
    tool = os.path.join(root, "pre-commit")
    git_tool = git
    if target == "pre-commit":
        tool_body = (
            "#!/bin/sh\n"
            "set -eu\n"
            "if [ \"${{1:-}}\" = --replacement ]; then\n"
            "  printf replacement > \"$HOME/{!s}\"\n"
            "  printf 'pre-commit 3.8.0\\n'\n"
            "  exit 0\n"
            "fi\n"
            "printf attempted > \"$HOME/{!s}\"\n"
            "if /bin/chmod u+w \"$0\" 2>/dev/null; then\n"
            "  printf '%s\\n' '#!/bin/sh' "
            "'printf replacement > \"$HOME/{!s}\"' "
            "\"printf 'pre-commit 3.8.0\\\\n'\" > \"$0\"\n"
            "  /bin/chmod 500 \"$0\"\n"
            "  exec \"$0\" --replacement\n"
            "fi\n"
            "printf original > \"$HOME/{!s}\"\n"
            "printf 'pre-commit 3.8.0\\n'\n"
        ).format(
            replacement_marker,
            attempted_marker,
            replacement_marker,
            original_marker,
        )
    elif target == "git":
        git_tool = os.path.join(root, "git")
        write_file(
            git_tool,
            (
                "#!/bin/sh\n"
                "printf original > \"$HOME/{!s}\"\n"
                "printf 'git version original\\n'\n"
            ).format(original_marker).encode("utf-8"),
            0o755,
        )
        tool_body = (
            "#!/bin/sh\n"
            "set -eu\n"
            "git_path=$(command -v git)\n"
            "printf attempted > \"$HOME/{!s}\"\n"
            "if /bin/chmod u+w \"$git_path\" 2>/dev/null; then\n"
            "  printf '%s\\n' '#!/bin/sh' "
            "'printf replacement > \"$HOME/{!s}\"' "
            "\"printf 'git version replacement\\\\n'\" > \"$git_path\"\n"
            "  /bin/chmod 500 \"$git_path\"\n"
            "fi\n"
            "git --version >/dev/null\n"
            "printf 'pre-commit 3.8.0\\n'\n"
        ).format(attempted_marker, replacement_marker)
    else:
        raise AssertionError(target)
    write_file(tool, tool_body.encode("utf-8"), 0o755)

    emitted = []
    original_emit = subject.emit
    original_close, preserved = preserve_private_tree_closes(subject)
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )
    descriptors_before = descriptor_count()
    try:
        status = subject.main([
            "--root", root,
            "--pre-commit", tool,
            "--git", git_tool,
            "--mode", "check",
            "--expected-version", "3.8.0",
            "--timeout", "5",
        ])
    finally:
        subject.emit = original_emit
        subject.PrivateTree.close = original_close
    attempted = private_marker_exists(preserved, attempted_marker)
    original_ran = private_marker_exists(preserved, original_marker)
    replacement_ran = private_marker_exists(preserved, replacement_marker)
    descriptor_delta = descriptor_count() - descriptors_before
    discard_preserved_trees(preserved)
    shutil.rmtree(root, ignore_errors=True)
    enforced = (
        status == 0 and attempted and original_ran and not replacement_ran
    )
    unavailable = status != 0 and not any(
        (attempted, original_ran, replacement_ran)
    ) and any(
        marker in line
        for marker in (
            "no trusted read-only executable boundary",
            "no read-only executable boundary",
            "no trusted secure execution boundary",
            "no secure execution boundary",
            "sandbox-exec:",
            "bwrap:",
        )
        for line in emitted
    )
    if (not enforced and not unavailable) or descriptor_delta:
        print(
            "{} copy was writable during child execution: ".format(target) +
            "status={}, attempted={}, original={}, replacement={}, fds={}, "
            "messages={!r}".format(
                status, attempted, original_ran, replacement_ran,
                descriptor_delta, emitted,
            )
        )
        return False
    return True


def boundary_policy_behavior(subject):
    """Require a read-only host plus one writable private data tree."""

    class FakeTree:
        def __init__(self, path):
            self.path = path

        def verify(self):
            return None

    class FakeGuard:
        path = "/usr/bin/bwrap"

        def verify(self):
            return None

        def trusted_system_route(self):
            return True

        def close(self):
            return None

    boundary = subject.ReadOnlyExecutionBoundary.__new__(
        subject.ReadOnlyExecutionBoundary
    )
    boundary.tree = FakeTree("/private-execution")
    boundary.data_tree = FakeTree("/private-data")
    boundary.bound_tools = []
    boundary.guard = FakeGuard()
    boundary.kind = "bubblewrap"
    command, executable = boundary.wrap(["/private-execution/tool", "arg"])

    def has_sequence(values):
        width = len(values)
        return any(
            command[index:index + width] == list(values)
            for index in range(len(command) - width + 1)
        )

    linux_safe = (
        executable == "/usr/bin/bwrap"
        and not has_sequence(("--ro-bind", "/", "/"))
        and not has_sequence(("--bind", "/", "/"))
        and has_sequence(("--ro-bind", "/usr", "/usr"))
        and has_sequence(("--bind", "/private-data", "/private-data"))
        and has_sequence(("--ro-bind", "/private-execution", "/private-execution"))
        and has_sequence(("--tmpfs", "/tmp"))
        and has_sequence(("--dev", "/dev"))
        and has_sequence(("--proc", "/proc"))
        and "--unshare-net" in command
        and "--unshare-ipc" in command
        and "--unshare-pid" in command
        and "--new-session" in command
        and "--die-with-parent" in command
    )

    original_platform = subject.sys.platform
    original_open = subject.BoundTool.open
    darwin_opened = {"value": False}

    def open_darwin_guard(_cls, _path):
        darwin_opened["value"] = True
        return FakeGuard()

    darwin_failed_closed = False
    subject.sys.platform = "darwin"
    subject.BoundTool.open = classmethod(open_darwin_guard)
    darwin = subject.ReadOnlyExecutionBoundary.__new__(
        subject.ReadOnlyExecutionBoundary
    )
    darwin.tree = FakeTree("/private-execution")
    darwin.data_tree = FakeTree("/private-data")
    darwin.bound_tools = []
    darwin.guard = None
    darwin.kind = None
    try:
        try:
            darwin.require()
        except subject.SetupError:
            darwin_failed_closed = True
    finally:
        subject.BoundTool.open = original_open
        subject.sys.platform = original_platform

    if not linux_safe or not darwin_failed_closed or darwin_opened["value"]:
        print(
            "execution policy did not bind a read-only host and PID namespace: "
            "linux_safe={}, darwin_failed_closed={}, darwin_opened={}, "
            "command={!r}".format(
                linux_safe, darwin_failed_closed, darwin_opened["value"],
                command,
            )
        )
        return False
    return True


def runtime_dependency_write_behavior(subject, base):
    """A configured tool cannot change its verified runtime dependency."""

    root = tempfile.mkdtemp(prefix="runtime-write-", dir=base)
    native_dir = os.path.join(root, ".githooks")
    os.mkdir(native_dir, 0o700)
    write_file(
        os.path.join(native_dir, "pre-push"),
        b"#!/bin/sh\nexit 0\n",
        0o755,
    )
    dependency = os.path.join(root, "verified-runtime")
    original = b"#!/bin/sh\nexit 0\n"
    write_file(dependency, original, 0o755)
    pre_commit = os.path.join(root, "pre-commit")
    write_file(
        pre_commit,
        (
            "#!/bin/sh\n"
            "if /bin/chmod u+w {!r} 2>/dev/null; then\n"
            "  printf corrupted > {!r}\n"
            "fi\n"
            "printf 'pre-commit 3.8.0\\n'\n"
        ).format(dependency, dependency).encode("utf-8"),
        0o755,
    )
    emitted = []
    original_emit = subject.emit
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )
    try:
        status = subject.main([
            "--root", root,
            "--pre-commit", pre_commit,
            "--git", dependency,
            "--mode", "check",
            "--expected-version", "3.8.0",
            "--timeout", "5",
        ])
    finally:
        subject.emit = original_emit
    try:
        with open(dependency, "rb") as stream:
            after = stream.read()
        after_mode = stat.S_IMODE(os.stat(dependency).st_mode)
    except OSError:
        after = None
        after_mode = None
    unavailable = status != 0 and any(
        marker in line
        for marker in (
            "no trusted secure execution boundary",
            "no secure execution boundary",
            "bwrap:",
        )
        for line in emitted
    )
    safe = after == original and after_mode == 0o755
    if not safe or (status != 0 and not unavailable):
        print(
            "configured execution changed a verified runtime dependency: "
            "status={}, bytes={!r}, mode={!r}, messages={!r}".format(
                status, after, after_mode, emitted
            )
        )
        shutil.rmtree(root, ignore_errors=True)
        return False
    shutil.rmtree(root, ignore_errors=True)
    return True


def runtime_dependency_swap_behavior(subject, base):
    """A last-moment imported sibling swap cannot select replacement bytes."""

    source_root = tempfile.mkdtemp(prefix="runtime-swap-", dir=base)
    script = os.path.join(source_root, "pre-commit")
    dependency = script + ".registry"
    replacement = dependency + ".replacement"
    write_file(
        script,
        (
            "#!/bin/sh\n"
            ". \"${ODYSSEUS_EXECUTABLE_ORIGIN}.registry\"\n"
            "printf '%s' \"$VALUE\" > \"$1\"\n"
        ).encode("utf-8"),
        0o755,
    )
    write_file(dependency, b"VALUE=original\n")
    write_file(replacement, b"VALUE=replacement\n")
    execution_tree = subject.PrivateTree()
    data_tree = subject.PrivateTree()
    marker = os.path.join(data_tree.mkdir("data"), "selected")
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(
        execution_tree, data_tree, bound_tools
    )
    unavailable = False
    rejected = False
    fired = False
    original_popen = subject.subprocess.Popen
    try:
        try:
            boundary.require()
        except subject.SetupError as error:
            unavailable = "secure execution boundary" in str(error)
        if not unavailable:
            source = subject.BoundTool.open(script)
            bound_tools.append(source)
            bound = subject.bind_executable(
                source,
                execution_tree,
                "pre-commit",
                bound_tools,
                boundary,
            )

            def swap_at_spawn(*args, **kwargs):
                nonlocal fired
                os.replace(replacement, dependency)
                fired = True
                return original_popen(*args, **kwargs)

            subject.subprocess.Popen = swap_at_spawn
            try:
                try:
                    subject.run(
                        [bound, marker],
                        "/",
                        {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                        2,
                    )
                except subject.SetupError:
                    rejected = True
            finally:
                subject.subprocess.Popen = original_popen
    finally:
        subject.subprocess.Popen = original_popen
        try:
            with open(marker, "rb") as stream:
                selected = stream.read()
        except OSError:
            selected = None
        for tool in reversed(bound_tools):
            tool.close()
        execution_tree.close()
        data_tree.close()
        shutil.rmtree(source_root, ignore_errors=True)
    if unavailable:
        return True
    if not fired or not rejected or selected != b"original":
        print(
            "an imported sibling swap selected mutable bytes: "
            "fired={},rejected={},selected={!r}".format(
                fired, rejected, selected
            )
        )
        return False
    return True


def untrusted_interpreter_behavior(subject, base):
    """A mutable interpreter/runtime closure is rejected before execution."""

    source_root = tempfile.mkdtemp(prefix="mutable-interpreter-", dir=base)
    interpreter = os.path.join(source_root, "python")
    shutil.copyfile(sys.executable, interpreter)
    os.chmod(interpreter, 0o755)
    script = os.path.join(source_root, "pre-commit")
    write_file(
        script,
        ("#!{}\nprint('pre-commit 3.8.0')\n".format(interpreter)).encode(
            "utf-8"
        ),
        0o755,
    )
    execution_tree = subject.PrivateTree()
    data_tree = subject.PrivateTree()
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(
        execution_tree, data_tree, bound_tools
    )
    boundary.require = lambda: None
    rejected = False
    bound = None
    try:
        source = subject.BoundTool.open(script)
        bound_tools.append(source)
        try:
            bound = subject.bind_executable(
                source,
                execution_tree,
                "pre-commit",
                bound_tools,
                boundary,
            )
        except subject.SetupError:
            rejected = True
    finally:
        for tool in reversed(bound_tools):
            tool.close()
        execution_tree.close()
        data_tree.close()
        shutil.rmtree(source_root, ignore_errors=True)
    if not rejected or bound is not None:
        print("a mutable interpreter/runtime closure was accepted")
        return False
    return True


def resource_limit_behavior(subject, base):
    """Host rlimits stop fork, memory, descriptor, and file growth."""

    probe = (
        "import json,resource,sys\n"
        "names=('RLIMIT_AS','RLIMIT_CPU','RLIMIT_NOFILE','RLIMIT_FSIZE','RLIMIT_NPROC')\n"
        "values={}\n"
        "for name in names:\n"
        " value=getattr(resource,name,None)\n"
        " values[name]=None if value is None else resource.getrlimit(value)[0]\n"
        "print(json.dumps(values,sort_keys=True))\n"
    )
    result = subject.run(
        [sys.executable, "-I", "-S", "-c", probe],
        "/",
        {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
        2,
    )
    if result[0] != 0:
        print("resource-limit probe failed: {!r}".format(result))
        return False
    import json

    try:
        limits = json.loads(result[1].decode("ascii"))
    except (UnicodeError, ValueError) as error:
        print("resource-limit probe returned invalid data: {}".format(error))
        return False
    expected = {
        "RLIMIT_AS": 512 * 1024 * 1024,
        "RLIMIT_CPU": 4,
        "RLIMIT_NOFILE": 128,
        "RLIMIT_FSIZE": 8 * 1024 * 1024,
        "RLIMIT_NPROC": 512,
    }
    bounded = all(
        limits.get(name) is not None
        and 0 < limits[name] <= maximum
        for name, maximum in expected.items()
    )
    if not bounded:
        print("child resource limits are not bounded: {!r}".format(limits))
        return False
    return True


def external_write_channel_behavior(subject, base):
    """Loopback, Unix sockets, and FIFOs outside private data stay unreachable."""

    if not sys.platform.startswith("linux"):
        return True
    execution_tree = subject.PrivateTree()
    data_tree = subject.PrivateTree()
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(
        execution_tree, data_tree, bound_tools
    )
    unix_path = os.path.join(base, "host-unix.sock")
    fifo_path = os.path.join(base, "host-fifo")
    unix_server = socket.socket(socket.AF_UNIX, socket.SOCK_DGRAM)
    tcp_server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    fifo_reader = None
    detail = b""
    try:
        unix_server.bind(unix_path)
        unix_server.settimeout(0.2)
        tcp_server.bind(("127.0.0.1", 0))
        tcp_server.listen(1)
        tcp_server.settimeout(0.2)
        os.mkfifo(fifo_path, 0o600)
        fifo_reader = os.open(fifo_path, os.O_RDONLY | os.O_NONBLOCK)
        boundary.require()
        program = (
            "import os,socket,sys\n"
            "for family,target in ((socket.AF_INET,('127.0.0.1',int(sys.argv[1]))),"
            "(socket.AF_UNIX,sys.argv[2])):\n"
            " try:\n"
            "  sock=socket.socket(family,socket.SOCK_STREAM if family==socket.AF_INET else socket.SOCK_DGRAM)\n"
            "  (sock.connect(target),sock.send(b'escape')) if family==socket.AF_INET else sock.sendto(b'escape',target)\n"
            " except OSError: pass\n"
            " try: sock.close()\n"
            " except Exception: pass\n"
            "try:\n"
            " fd=os.open(sys.argv[3],os.O_WRONLY|os.O_NONBLOCK);os.write(fd,b'escape');os.close(fd)\n"
            "except OSError: pass\n"
        )
        command, executable = boundary.wrap(
            [
                sys.executable,
                "-I",
                "-S",
                "-c",
                program,
                str(tcp_server.getsockname()[1]),
                unix_path,
                fifo_path,
            ]
        )
        result = subprocess.run(
            command,
            executable=executable,
            cwd="/",
            env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
        detail = result.stdout + result.stderr
        if result.returncode != 0:
            print("external-channel namespace did not execute: {!r}".format(detail))
            return False
        escaped = []
        try:
            tcp_connection, _address = tcp_server.accept()
        except OSError:
            pass
        else:
            escaped.append("loopback")
            tcp_connection.close()
        try:
            unix_server.recv(32)
        except OSError:
            pass
        else:
            escaped.append("unix")
        try:
            if os.read(fifo_reader, 32):
                escaped.append("fifo")
        except OSError:
            pass
        if escaped:
            print("external write channels remained reachable: {}".format(escaped))
            return False
        return True
    finally:
        if fifo_reader is not None:
            os.close(fifo_reader)
        unix_server.close()
        tcp_server.close()
        for path in (unix_path, fifo_path):
            try:
                os.unlink(path)
            except OSError:
                pass
        for tool in reversed(bound_tools):
            tool.close()
        execution_tree.close()
        data_tree.close()


def cleanup_entry_race_behavior(subject, base):
    """A replacement at the real final quarantine name is never removed."""

    broken = []
    for managed_root in ("data", "execution"):
        for kind in ("file", "directory"):
            tree = subject.PrivateTree()
            root_path = tree.path
            root_fd = tree.root.descriptor
            victim = "nested-victim"
            displaced = "nested-victim.displaced"
            victim_path = os.path.join(root_path, victim)
            displaced_path = os.path.join(root_path, displaced)
            if kind == "file":
                write_file(victim_path, b"original\n")
            else:
                os.mkdir(victim_path, 0o700)
                write_file(os.path.join(victim_path, "original"), b"original\n")

            original_rename = subject.os.rename
            original_unlink = subject.os.unlink
            original_rmdir = subject.os.rmdir
            fired = {"value": False, "quarantine": None}

            def install_replacement(quarantine):
                original_rename(
                    quarantine,
                    displaced,
                    src_dir_fd=root_fd, dst_dir_fd=root_fd,
                )
                if kind == "file":
                    descriptor = os.open(
                        quarantine,
                        os.O_WRONLY | os.O_CREAT | os.O_EXCL,
                        0o600,
                        dir_fd=root_fd,
                    )
                    os.close(descriptor)
                else:
                    os.mkdir(quarantine, 0o700, dir_fd=root_fd)
                fired["value"] = True
                fired["quarantine"] = quarantine

            def racing_unlink(name, *args, **kwargs):
                if (
                    kind == "file"
                    and not fired["value"]
                    and name.startswith(".odysseus-quarantine-")
                    and kwargs.get("dir_fd") == root_fd
                ):
                    install_replacement(name)
                return original_unlink(name, *args, **kwargs)

            def racing_rmdir(name, *args, **kwargs):
                if (
                    kind == "directory"
                    and not fired["value"]
                    and name.startswith(".odysseus-quarantine-")
                    and kwargs.get("dir_fd") == root_fd
                ):
                    install_replacement(name)
                return original_rmdir(name, *args, **kwargs)

            subject.os.unlink = racing_unlink
            subject.os.rmdir = racing_rmdir
            try:
                problem = tree.close()
            finally:
                subject.os.unlink = original_unlink
                subject.os.rmdir = original_rmdir

            quarantine = fired["quarantine"]
            replacement_path = (
                os.path.join(root_path, quarantine) if quarantine else ""
            )
            replacement_preserved = bool(quarantine) and (
                os.path.isfile(replacement_path)
                if kind == "file"
                else os.path.isdir(replacement_path)
            )
            original_preserved = os.path.exists(displaced_path)
            if (
                not fired["value"]
                or not problem
                or not replacement_preserved
                or not original_preserved
            ):
                broken.append(
                    "{}/{}(fired={},quarantine={!r},problem={!r},"
                    "replacement={},original={})".format(
                        managed_root, kind, fired["value"], quarantine, problem,
                        replacement_preserved, original_preserved,
                    )
                )
            shutil.rmtree(root_path, ignore_errors=True)
    if broken:
        print(
            "cleanup removed a nested replacement at its final quarantine-name "
            "operation: {}".format(", ".join(broken))
        )
        return False
    return True


def cleanup_root_race_behavior(subject):
    """Both roots preserve a replacement at the real quarantine name."""

    broken = []
    for managed_root in ("data", "execution"):
        tree = subject.PrivateTree()
        root_path = tree.path
        parent_path = tree.parent.path
        parent_fd = tree.parent.descriptor
        original_token = tree.root.token
        displaced = tree.name + ".displaced-" + managed_root
        displaced_path = os.path.join(parent_path, displaced)
        write_file(os.path.join(root_path, "original"), b"original\n")
        original_rename = subject.os.rename
        original_rmdir = subject.os.rmdir
        fired = {"value": False, "quarantine": None}

        def install_replacement(quarantine):
            original_rename(
                quarantine,
                displaced,
                src_dir_fd=parent_fd, dst_dir_fd=parent_fd,
            )
            os.mkdir(quarantine, 0o700, dir_fd=parent_fd)
            fired["value"] = True
            fired["quarantine"] = quarantine

        def racing_rmdir(name, *args, **kwargs):
            if (
                not fired["value"]
                and name.startswith(".odysseus-quarantine-")
                and kwargs.get("dir_fd") == parent_fd
            ):
                install_replacement(name)
            return original_rmdir(name, *args, **kwargs)

        subject.os.rmdir = racing_rmdir
        try:
            problem = tree.close()
        finally:
            subject.os.rmdir = original_rmdir

        quarantine = fired["quarantine"]
        replacement_path = (
            os.path.join(parent_path, quarantine) if quarantine else ""
        )
        replacement_preserved = bool(quarantine) and os.path.isdir(
            replacement_path
        )
        try:
            original_preserved = (
                subject.dir_ident(os.stat(displaced_path, follow_symlinks=False))
                == original_token
            )
        except OSError:
            original_preserved = False
        if (
            not fired["value"]
            or not problem
            or not replacement_preserved
            or not original_preserved
        ):
            broken.append(
                "{}(fired={},quarantine={!r},problem={!r},replacement={},"
                "original={})".format(
                    managed_root, fired["value"], quarantine, problem,
                    replacement_preserved, original_preserved,
                )
            )
        shutil.rmtree(root_path, ignore_errors=True)
        shutil.rmtree(displaced_path, ignore_errors=True)
        if replacement_path:
            shutil.rmtree(replacement_path, ignore_errors=True)
    if broken:
        print(
            "cleanup removed a managed-root replacement at its final "
            "quarantine-name operation: {}".format(", ".join(broken))
        )
        return False
    return True


def escaped_session_behavior(subject):
    """A setsid plus double-fork descendant cannot outlive containment."""

    execution_tree = subject.PrivateTree()
    data_tree = subject.PrivateTree()
    data = data_tree.mkdir("data")
    attempted = os.path.join(data, "attempted")
    escaped = os.path.join(data, "escaped-session")
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary.__new__(
        subject.ReadOnlyExecutionBoundary
    )
    boundary.tree = execution_tree
    boundary.data_tree = data_tree
    boundary.bound_tools = bound_tools
    boundary.guard = None
    boundary.kind = None
    unavailable = False
    result = None
    detail = b""
    try:
        try:
            boundary.require()
        except subject.SetupError:
            unavailable = True
        if not unavailable:
            program = (
                "import os,sys,time\n"
                "open(sys.argv[1], 'w').write('attempted')\n"
                "first = os.fork()\n"
                "if first:\n"
                "    os.waitpid(first, 0)\n"
                "    os._exit(0)\n"
                "os.setsid()\n"
                "second = os.fork()\n"
                "if second:\n"
                "    os._exit(0)\n"
                "time.sleep(0.4)\n"
                "open(sys.argv[2], 'w').write('escaped')\n"
                "os._exit(0)\n"
            )
            command, executable = boundary.wrap([
                sys.executable, "-I", "-S", "-c", program,
                attempted, escaped,
            ])
            try:
                result = subprocess.run(
                    command,
                    executable=executable,
                    cwd="/",
                    env={"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE,
                    timeout=5,
                    check=False,
                )
            except subprocess.TimeoutExpired as error:
                detail = (error.stdout or b"") + (error.stderr or b"")
                result = None
            time.sleep(0.8)
            if result is None:
                unavailable = False
            elif result.returncode != 0 and not os.path.exists(attempted):
                detail = result.stdout + result.stderr
                unavailable = any(
                    marker in detail
                    for marker in (
                        b"Operation not permitted",
                        b"No permissions to creating new namespace",
                        b"Creating new namespace failed",
                    )
                )
        if not sys.platform.startswith("linux"):
            safe = unavailable
        else:
            safe = (
                not unavailable
                and result is not None
                and result.returncode == 0
                and os.path.exists(attempted)
                and not os.path.exists(escaped)
            )
        if not safe:
            print(
                "a setsid/double-fork descendant escaped containment: "
                "unavailable={}, attempted={}, escaped={}, detail={!r}".format(
                    unavailable, os.path.exists(attempted),
                    os.path.exists(escaped), detail,
                )
            )
            return False
        return True
    finally:
        for tool in reversed(bound_tools):
            tool.close()
        execution_tree.close()
        data_tree.close()


def generated_install_python_behavior(subject):
    """Generated hook bytes use only the installer-owned executable path."""

    marker = "/tmp/odysseus-generated-hook-marker"
    candidate = b"\n".join(
        line.encode("utf-8")
        for line in (
            *subject.HEADER,
            "INSTALL_PYTHON=/untrusted;touch${IFS}" + marker,
            "ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-push)",
            *subject.TAIL,
        )
    ) + b"\n"
    selected = "/tmp/pre commit;$(touch should-not-run)/python"
    canonicalize = getattr(subject, "canonical_generated_hook", None)
    if canonicalize is None:
        print("generated hook canonicalization is missing")
        return False
    try:
        result = canonicalize(candidate, "pre-push", selected)
    except (OSError, subject.SetupError, UnicodeError) as error:
        print("metacharacter path was not encoded safely: {}".format(error))
        return False
    lines = result.decode("utf-8").splitlines()
    if len(lines) != 20:
        print("canonical generated hook has the wrong line count")
        return False
    try:
        assignment = shlex.split(lines[5], posix=True)
    except ValueError:
        assignment = []
    exact = assignment == ["INSTALL_PYTHON=" + selected]
    candidate_absent = b"/untrusted" not in result and b"touch${IFS}" not in result
    stable = subject.generated(result, "pre-push", selected)
    if not exact or not candidate_absent or not stable:
        print(
            "generated assignment was not replaced exactly: "
            "assignment={!r},candidate_absent={},stable={}".format(
                assignment, candidate_absent, stable
            )
        )
        return False
    return True


def independent_git_metadata_behavior(subject, base):
    """Git-reported metadata cannot select an unrelated owned directory."""

    root = tempfile.mkdtemp(prefix="git-metadata-root-", dir=base)
    unrelated = tempfile.mkdtemp(prefix="git-metadata-unrelated-", dir=base)
    os.mkdir(os.path.join(root, ".git"), 0o700)
    config = os.path.join(root, ".pre-commit-config.yaml")
    write_file(config, b"repos: []\n")
    hooks = os.path.join(unrelated, "hooks")
    os.mkdir(hooks, 0o700)
    marker = os.path.join(hooks, "unrelated-marker")
    write_file(marker, b"must remain exact\n")
    before = route_snapshot(hooks)
    original_git_value = subject.git_value
    original_run = subject.run

    def forged_git_value(_git, _repo, args, _env, _timeout):
        if args == ["rev-parse", "--show-toplevel"]:
            return root
        if args in (
            ["rev-parse", "--absolute-git-dir"],
            ["rev-parse", "--git-common-dir"],
        ):
            return unrelated
        raise AssertionError(args)

    def controlled_run(argv, _cwd, _env, _timeout):
        if argv[-4:] == ["config", "--show-origin", "--get", "core.hooksPath"]:
            return (1, b"", b"")
        raise AssertionError(argv)

    subject.git_value = forged_git_value
    subject.run = controlled_run
    accepted = False
    error = None
    repo = None
    try:
        try:
            repo = subject.bind_repo(root, config, "/controlled/git", {}, 1)
            accepted = True
        except (OSError, subject.SetupError, UnicodeError) as caught:
            error = caught
    finally:
        if repo is not None:
            repo.close()
        subject.git_value = original_git_value
        subject.run = original_run
    after = route_snapshot(hooks)
    shutil.rmtree(root, ignore_errors=True)
    shutil.rmtree(unrelated, ignore_errors=True)
    if accepted or error is None or after != before:
        print(
            "forged Git metadata selected an unrelated route: "
            "accepted={},error={!r},unchanged={}".format(
                accepted, error, after == before
            )
        )
        return False
    return True


def timeout_and_sigchld_preflight_behavior(subject, base):
    """Safety budgets are finite and child ownership is established pre-spawn."""

    opened = {"value": False}
    original_open = subject.BoundDir.open

    def observed_open(*args, **kwargs):
        opened["value"] = True
        return original_open(*args, **kwargs)

    subject.BoundDir.open = observed_open
    emitted = []
    original_emit = subject.emit
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )
    root = tempfile.mkdtemp(prefix="nonfinite-timeout-", dir=base)
    try:
        status = subject.main([
            "--root", root,
            "--pre-commit", "/missing/pre-commit",
            "--git", "/missing/git",
            "--mode", "check",
            "--timeout", "nan",
        ])
    finally:
        subject.emit = original_emit
        subject.BoundDir.open = original_open
        shutil.rmtree(root, ignore_errors=True)
    finite_rejected = (
        status != 0
        and not opened["value"]
        and any("timeout must be finite" in line for line in emitted)
    )

    original_sigchld = signal.getsignal(signal.SIGCHLD)
    original_popen = subject.subprocess.Popen
    spawned = {"value": False}

    def observed_popen(*args, **kwargs):
        spawned["value"] = True
        return original_popen(*args, **kwargs)

    subject.subprocess.Popen = observed_popen
    signal.signal(signal.SIGCHLD, signal.SIG_IGN)
    ownership_rejected = False
    try:
        try:
            subject.run([sys.executable, "-I", "-S", "-c", "pass"], "/", {}, 1)
        except subject.SetupError:
            ownership_rejected = not spawned["value"]
    finally:
        signal.signal(signal.SIGCHLD, original_sigchld)
        subject.subprocess.Popen = original_popen
    if not finite_rejected or not ownership_rejected:
        print(
            "unsafe budget or child ownership reached execution: "
            "finite={},ownership={},spawned={},messages={!r}".format(
                finite_rejected, ownership_rejected, spawned["value"], emitted
            )
        )
        return False
    return True


def main(argv):
    if len(argv) != 5:
        raise SystemExit("usage: harness HELPER MODE BASE GIT")
    helper, mode, base, git = argv[1:]
    subject = load_subject(helper)
    checks = {
        "committed-publication": lambda: committed_publication_behavior(
            subject, base
        ),
        "processes": lambda: process_group_behavior(subject, base),
        "signals": lambda: signal_cancellation_behavior(subject, base),
        "terminal-TERM": lambda: terminal_cancellation_behavior(
            helper, base, git, "SIGTERM"
        ),
        "terminal-HUP": lambda: terminal_cancellation_behavior(
            helper, base, git, "SIGHUP"
        ),
        "teardown-TERM": lambda: teardown_cancellation_behavior(
            subject, base, "SIGTERM"
        ),
        "teardown-HUP": lambda: teardown_cancellation_behavior(
            subject, base, "SIGHUP"
        ),
        "observer-latch": lambda: observer_exit_latch_behavior(subject),
        "preservation": lambda: directory_preservation_behavior(subject, base),
        "short-write": lambda: short_write_behavior(subject, base, git),
        "descriptors": lambda: descriptor_behavior(subject, base),
        "descriptor-lifecycle": lambda: descriptor_lifecycle_behavior(subject, base),
        "acquisition-failures": lambda: acquisition_failure_behavior(
            subject, base
        ),
        "named-route": lambda: named_route_behavior(subject, base),
        "tool-swap": lambda: tool_swap_behavior(subject, base, git),
        "interpreter-swap": lambda: interpreter_swap_behavior(
            subject, base, git
        ),
        "execution-copy-write": lambda: execution_copy_write_behavior(
            subject, base, git, "pre-commit"
        ),
        "transitive-copy-write": lambda: execution_copy_write_behavior(
            subject, base, git, "git"
        ),
        "boundary-policy": lambda: boundary_policy_behavior(subject),
        "runtime-host-write": lambda: runtime_dependency_write_behavior(
            subject, base
        ),
        "runtime-sibling-swap": lambda: runtime_dependency_swap_behavior(
            subject, base
        ),
        "cleanup-entry-races": lambda: cleanup_entry_race_behavior(
            subject, base
        ),
        "cleanup-root-races": lambda: cleanup_root_race_behavior(subject),
        "escaped-session": lambda: escaped_session_behavior(subject),
        "generated-install-python": lambda: generated_install_python_behavior(
            subject
        ),
        "independent-git-metadata": lambda: independent_git_metadata_behavior(
            subject, base
        ),
        "timeout-sigchld-preflight": lambda: timeout_and_sigchld_preflight_behavior(
            subject, base
        ),
        "untrusted-interpreter": lambda: untrusted_interpreter_behavior(
            subject, base
        ),
        "resource-limits": lambda: resource_limit_behavior(subject, base),
        "external-write-channels": lambda: external_write_channel_behavior(
            subject, base
        ),
    }
    if mode not in checks:
        raise SystemExit("unknown harness mode: {}".format(mode))
    raise SystemExit(0 if checks[mode]() else 1)


if __name__ == "__main__":
    main(sys.argv)
PY

run_red_harness() {
    local mode=$1 output=$2
    python3 -I -S "$RED_HARNESS" \
        "$ROOT/$HELPER_REL" "$mode" "$TMP" "$SYSTEM_GIT" \
        > "$output" 2>&1
}

info "the forward directory exchange is the publication commit point"
run_red_harness committed-publication "$TMP/red-committed-publication.out"
red_committed_publication_status=$?
if [ "$red_committed_publication_status" -eq 0 ]; then
    pass "post-commit failures preserve and report exact active and recovery routes"
else
    sed 's/^/    /' "$TMP/red-committed-publication.out" >&2
    fail "a post-commit path changed or hid an active or recovery route"
fi

info "hook publication preserves directory mode and untouched entries"
run_red_harness preservation "$TMP/red-preservation.out"
red_preservation_status=$?
if [ "$red_preservation_status" -eq 0 ]; then
    pass "safe directory modes and legacy, unmanaged, and sample bytes remain exact"
else
    sed 's/^/    /' "$TMP/red-preservation.out" >&2
    fail "hook publication changed safe directory metadata or untouched bytes"
fi

info "output limits and cancellation terminate the complete process group"
run_red_harness processes "$TMP/red-processes.out"
red_process_status=$?
if [ "$red_process_status" -eq 0 ]; then
    pass "output flooding and TERM-ignoring descendants are killed within bounds"
else
    sed 's/^/    /' "$TMP/red-processes.out" >&2
    fail "a flooded or cancelled child escaped bounded process-group teardown"
fi

info "a one-shot leader-exit notification remains observable until reap"
run_red_harness observer-latch "$TMP/red-observer-latch.out"
red_observer_latch_status=$?
if [ "$red_observer_latch_status" -eq 0 ]; then
    pass "leader exit remains latched while output drains before group cleanup"
else
    sed 's/^/    /' "$TMP/red-observer-latch.out" >&2
    fail "leader exit was forgotten before group cleanup could reap it"
fi

info "SIGTERM, SIGHUP, and SIGINT cancel the complete in-flight process group"
run_red_harness signals "$TMP/red-signals.out"
red_signal_status=$?
if [ "$red_signal_status" -eq 0 ]; then
    pass "outer cancellation reaps a leader-exited, signal-ignoring descendant"
else
    sed 's/^/    /' "$TMP/red-signals.out" >&2
    fail "outer cancellation left an in-flight process-group member alive"
fi

for terminal_signal in TERM HUP; do
    signal_name="SIG$terminal_signal"
    info "$signal_name is terminal across teardown and repository aggregation"
    run_red_harness "terminal-$terminal_signal" \
        "$TMP/red-terminal-$terminal_signal.out"
    red_terminal_status=$?
    run_red_harness "teardown-$terminal_signal" \
        "$TMP/red-teardown-$terminal_signal.out"
    red_teardown_status=$?
    if [ "$red_terminal_status" -eq 0 ] && \
        [ "$red_teardown_status" -eq 0 ]; then
        pass "$signal_name stops after cleanup without touching a later repository"
    else
        sed 's/^/    /' "$TMP/red-terminal-$terminal_signal.out" >&2
        sed 's/^/    /' "$TMP/red-teardown-$terminal_signal.out" >&2
        fail "$signal_name became success or an aggregating repository failure"
    fi
done

info "a permitted short write cannot become a valid truncated configuration"
run_red_harness short-write "$TMP/red-short-write.out"
red_short_write_status=$?
if [ "$red_short_write_status" -eq 0 ]; then
    pass "shadow configuration writes are exact or fail closed"
else
    sed 's/^/    /' "$TMP/red-short-write.out" >&2
    fail "a short write changed configuration semantics without a failure"
fi

info "malformed repository aggregation keeps descriptor use bounded"
run_red_harness descriptors "$TMP/red-descriptors.out"
red_descriptor_status=$?
if [ "$red_descriptor_status" -eq 0 ]; then
    pass "many malformed repositories report all failures without descriptor exhaustion"
else
    sed 's/^/    /' "$TMP/red-descriptors.out" >&2
    fail "malformed repository aggregation leaked descriptors or reached EMFILE"
fi

info "post-open failures and repeated close preserve descriptor ownership"
run_red_harness descriptor-lifecycle "$TMP/red-descriptor-lifecycle.out"
red_descriptor_lifecycle_status=$?
if [ "$red_descriptor_lifecycle_status" -eq 0 ]; then
    pass "descriptor acquisition failures close once and ownership is idempotent"
else
    sed 's/^/    /' "$TMP/red-descriptor-lifecycle.out" >&2
    fail "descriptor acquisition or repeated close leaked or closed foreign state"
fi

info "failed acquisition closes descriptors and reports preserved recovery paths"
run_red_harness acquisition-failures "$TMP/red-acquisition-failures.out"
red_acquisition_status=$?
if [ "$red_acquisition_status" -eq 0 ]; then
    pass "failed acquisition closes descriptors and reports preserved unbound paths"
else
    sed 's/^/    /' "$TMP/red-acquisition-failures.out" >&2
    fail "failed acquisition leaked a descriptor or hid a preserved recovery path"
fi

info "a hooks-directory name swap cannot verify through a detached directory"
run_red_harness named-route "$TMP/red-named-route.out"
red_named_route_status=$?
if [ "$red_named_route_status" -eq 0 ]; then
    pass "post-install verification binds the live named hooks route"
else
    sed 's/^/    /' "$TMP/red-named-route.out" >&2
    fail "post-install verification accepted a detached hooks directory"
fi

info "a verified executable route cannot select replacement bytes"
run_red_harness tool-swap "$TMP/red-tool-swap.out"
red_tool_swap_status=$?
if [ "$red_tool_swap_status" -eq 0 ]; then
    pass "tool execution remains bound to the verified executable bytes"
else
    sed 's/^/    /' "$TMP/red-tool-swap.out" >&2
    fail "tool execution re-resolved a mutable path after verification"
fi

info "a verified script cannot select replacement interpreter bytes"
run_red_harness interpreter-swap "$TMP/red-interpreter-swap.out"
red_interpreter_swap_status=$?
if [ "$red_interpreter_swap_status" -eq 0 ]; then
    pass "script execution remains bound to the verified interpreter bytes"
else
    sed 's/^/    /' "$TMP/red-interpreter-swap.out" >&2
    fail "script execution re-resolved a mutable shebang after verification"
fi

info "an executing child cannot replace its verified executable copy"
run_red_harness execution-copy-write "$TMP/red-execution-copy-write.out"
red_execution_copy_write_status=$?
if [ "$red_execution_copy_write_status" -eq 0 ]; then
    pass "the executable copy remains read-only for its complete child lifetime"
else
    sed 's/^/    /' "$TMP/red-execution-copy-write.out" >&2
    fail "a child changed its executable copy and ran replacement bytes"
fi

info "an executing child cannot replace the verified git copy on PATH"
run_red_harness transitive-copy-write "$TMP/red-transitive-copy-write.out"
red_transitive_copy_write_status=$?
if [ "$red_transitive_copy_write_status" -eq 0 ]; then
    pass "the transitive git copy remains read-only for the child lifetime"
else
    sed 's/^/    /' "$TMP/red-transitive-copy-write.out" >&2
    fail "a child changed the git copy on PATH and ran replacement bytes"
fi

info "the execution boundary makes the host read-only and owns all descendants"
run_red_harness boundary-policy "$TMP/red-boundary-policy.out"
red_boundary_policy_status=$?
if [ "$red_boundary_policy_status" -eq 0 ]; then
    pass "the Linux boundary exposes one writable data tree and a PID namespace"
else
    sed 's/^/    /' "$TMP/red-boundary-policy.out" >&2
    fail "the execution boundary left host writes or session escape available"
fi

info "a configured tool cannot mutate its verified runtime dependency"
run_red_harness runtime-host-write "$TMP/red-runtime-host-write.out"
red_runtime_host_write_status=$?
if [ "$red_runtime_host_write_status" -eq 0 ]; then
    pass "runtime dependencies remain unchanged or execution fails closed"
else
    sed 's/^/    /' "$TMP/red-runtime-host-write.out" >&2
    fail "configured execution changed a host runtime dependency"
fi

info "an imported runtime sibling cannot swap after immutable binding"
run_red_harness runtime-sibling-swap "$TMP/red-runtime-sibling-swap.out"
red_runtime_sibling_swap_status=$?
if [ "$red_runtime_sibling_swap_status" -eq 0 ]; then
    pass "runtime siblings execute from immutable copies and source swaps fail closed"
else
    sed 's/^/    /' "$TMP/red-runtime-sibling-swap.out" >&2
    fail "an imported runtime sibling selected bytes from a mutable source route"
fi

info "nested cleanup preserves last-operation file and directory replacements"
run_red_harness cleanup-entry-races "$TMP/red-cleanup-entry-races.out"
red_cleanup_entry_races_status=$?
if [ "$red_cleanup_entry_races_status" -eq 0 ]; then
    pass "nested cleanup quarantines exact objects and preserves mismatches"
else
    sed 's/^/    /' "$TMP/red-cleanup-entry-races.out" >&2
    fail "nested cleanup removed a replacement selected at the last operation"
fi

info "both managed-root cleanups preserve a last-operation replacement"
run_red_harness cleanup-root-races "$TMP/red-cleanup-root-races.out"
red_cleanup_root_races_status=$?
if [ "$red_cleanup_root_races_status" -eq 0 ]; then
    pass "managed roots are quarantined and revalidated before cleanup"
else
    sed 's/^/    /' "$TMP/red-cleanup-root-races.out" >&2
    fail "managed-root cleanup removed a replacement selected at the last operation"
fi

info "setsid and double-fork descendants cannot outlive execution containment"
run_red_harness escaped-session "$TMP/red-escaped-session.out"
red_escaped_session_status=$?
if [ "$red_escaped_session_status" -eq 0 ]; then
    pass "escaped sessions are extinct before the execution boundary returns"
else
    sed 's/^/    /' "$TMP/red-escaped-session.out" >&2
    fail "a detached session survived the execution boundary"
fi

info "generated hooks publish only the installer-owned executable path"
run_red_harness generated-install-python "$TMP/red-generated-install-python.out"
red_generated_install_python_status=$?
if [ "$red_generated_install_python_status" -eq 0 ]; then
    pass "metacharacter paths are encoded and candidate shell text is discarded"
else
    sed 's/^/    /' "$TMP/red-generated-install-python.out" >&2
    fail "candidate-generated INSTALL_PYTHON shell text reached publication"
fi

info "repository metadata is bound independently of selected Git output"
run_red_harness independent-git-metadata "$TMP/red-independent-git-metadata.out"
red_independent_git_metadata_status=$?
if [ "$red_independent_git_metadata_status" -eq 0 ]; then
    pass "forged Git metadata cannot select an unrelated owned directory"
else
    sed 's/^/    /' "$TMP/red-independent-git-metadata.out" >&2
    fail "selected Git output retained authority over repository metadata"
fi

info "deadlines and child ownership fail closed before process creation"
run_red_harness timeout-sigchld-preflight "$TMP/red-timeout-sigchld.out"
red_timeout_sigchld_status=$?
if [ "$red_timeout_sigchld_status" -eq 0 ]; then
    pass "non-finite timeouts and unsafe SIGCHLD state are rejected pre-spawn"
else
    sed 's/^/    /' "$TMP/red-timeout-sigchld.out" >&2
    fail "an unsafe budget or child-observer state reached process creation"
fi

info "mutable interpreter and runtime closures fail closed"
run_red_harness untrusted-interpreter "$TMP/red-untrusted-interpreter.out"
red_untrusted_interpreter_status=$?
if [ "$red_untrusted_interpreter_status" -eq 0 ]; then
    pass "a mutable interpreter/runtime closure is rejected before execution"
else
    sed 's/^/    /' "$TMP/red-untrusted-interpreter.out" >&2
    fail "a mutable interpreter/runtime closure retained execution authority"
fi

info "host resource limits bound every selected process"
run_red_harness resource-limits "$TMP/red-resource-limits.out"
red_resource_limits_status=$?
if [ "$red_resource_limits_status" -eq 0 ]; then
    pass "fork, memory, descriptor, CPU, and file-growth ceilings are inherited"
else
    sed 's/^/    /' "$TMP/red-resource-limits.out" >&2
    fail "selected code inherited an unbounded host resource"
fi

info "network, Unix socket, FIFO, and device surfaces are private"
run_red_harness external-write-channels "$TMP/red-external-write-channels.out"
red_external_write_channels_status=$?
if [ "$red_external_write_channels_status" -eq 0 ]; then
    pass "loopback and host IPC canaries receive no selected bytes"
else
    sed 's/^/    /' "$TMP/red-external-write-channels.out" >&2
    fail "selected code reached an external network or IPC write channel"
fi

info "a sourced installer returns to its caller and preserves failure accounting"
SOURCE_REPO="$TMP/sourced-wrapper"
make_repo "$SOURCE_REPO"
write_config "$SOURCE_REPO" 'pre-commit pre-push' sourced-wrapper
run_installer "$SOURCE_REPO" true 3.8.0 "$TMP/sourced-prime.out"
sourced_prime_status=$?
env \
    PATH="$INSTALL_BIN:/usr/bin:/bin" \
    HOME="$TMP/ambient-home" \
    ODYSSEUS_ROOT="$SOURCE_REPO" \
    ODYSSEUS_PRECOMMIT_BINARY="$PRECOMMIT_FIXTURE" \
    ODYSSEUS_PRECOMMIT_EXPECTED_VERSION=3.8.0 \
    INSTALL=false \
    /bin/bash -c '
        _PASS=0; _FAIL=0; _WARN=0; _SKIP=0
        source "$1"
        source_status=$?
        printf "after-success status=%s fail=%s\n" "$source_status" "$_FAIL"
    ' _ "$SOURCE_REPO/$INSTALL_WRAPPER_REL" \
    > "$TMP/sourced-success.out" 2>&1
sourced_success_status=$?
env \
    PATH="$INSTALL_BIN:/usr/bin:/bin" \
    HOME="$TMP/ambient-home" \
    ODYSSEUS_ROOT="$SOURCE_REPO" \
    ODYSSEUS_PRECOMMIT_BINARY="$PRECOMMIT_FIXTURE" \
    ODYSSEUS_PRECOMMIT_EXPECTED_VERSION=9.9.9 \
    INSTALL=false \
    /bin/bash -c '
        _PASS=0; _FAIL=0; _WARN=0; _SKIP=0
        source "$1"
        source_status=$?
        printf "after-failure status=%s fail=%s\n" "$source_status" "$_FAIL"
    ' _ "$SOURCE_REPO/$INSTALL_WRAPPER_REL" \
    > "$TMP/sourced-failure.out" 2>&1
sourced_failure_status=$?
if [ "$sourced_prime_status" -eq 0 ] &&
    [ "$sourced_success_status" -eq 0 ] &&
    [ "$sourced_failure_status" -eq 0 ] &&
    grep -q '^after-success status=0 fail=0$' "$TMP/sourced-success.out" &&
    grep -q '^after-failure status=0 fail=1$' "$TMP/sourced-failure.out"; then
    pass "sourced success and failure return to the caller with exact counters"
else
    sed 's/^/    /' "$TMP/sourced-success.out" >&2
    sed 's/^/    /' "$TMP/sourced-failure.out" >&2
    fail "sourced installer control flow or failure accounting was lost"
fi

summary
exit_code
