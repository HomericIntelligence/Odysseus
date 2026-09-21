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
SYSTEM_GIT="$(command -v git)"
HOST_KERNEL="$(uname -s)"
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

info "the test-only Git seam is gated and remote arguments cannot collide with it"
: > "$GIT_LOG"
bash "$ROOT/scripts/check-push-signatures.sh" \
    --odysseus-test-git "$FAKE_BIN/git" -- \
    origin ssh://origin.invalid/repo </dev/null \
    > "$TMP/test-seam-disabled.out" 2> "$TMP/test-seam-disabled.err"
test_seam_disabled_status=$?
printf '%s\n' \
    "refs/heads/good local-good refs/heads/good remote-good" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            --git ssh://origin.invalid/repo \
        > "$TMP/test-seam-collision.out" 2> "$TMP/test-seam-collision.err"
test_seam_collision_status=$?
if [ "$test_seam_disabled_status" -ne 0 ] &&
    grep -q 'test Git seam is disabled' "$TMP/test-seam-disabled.err" &&
    [ "$test_seam_collision_status" -eq 0 ]; then
    pass "the fake-Git seam is explicit and a --git remote name stays data"
else
    sed 's/^/    /' "$TMP/test-seam-disabled.err" >&2
    sed 's/^/    /' "$TMP/test-seam-collision.err" >&2
    fail "test authority leaked into forwarded pre-push arguments"
fi

info "the native verifier gives transitive Git tools a fixed environment"
TRANSITIVE_BIN="$TMP/transitive-hostile-bin"
TRANSITIVE_MARKER="$TMP/transitive-hostile-ran"
mkdir "$TRANSITIVE_BIN"
cat > "$TRANSITIVE_BIN/bash" <<'SH'
#!/bin/sh
printf 'hostile transitive shell ran\n' > "${TRANSITIVE_MARKER:?}"
exit 97
SH
chmod +x "$TRANSITIVE_BIN/bash"
: > "$GIT_LOG"
printf '%s\n' \
    "refs/heads/good local-good refs/heads/good remote-good" |
    PATH="$TRANSITIVE_BIN:/usr/bin:/bin" \
        GIT_LOG="$GIT_LOG" TRANSITIVE_MARKER="$TRANSITIVE_MARKER" \
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        /bin/bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            origin ssh://origin.invalid/repo \
        > "$TMP/transitive-environment.out" \
        2> "$TMP/transitive-environment.err"
transitive_environment_status=$?
if [ "$transitive_environment_status" -eq 0 ] \
    && [ ! -e "$TRANSITIVE_MARKER" ]; then
    pass "Git descendants cannot select commands from ambient PATH"
else
    sed 's/^/    /' "$TMP/transitive-environment.err" >&2
    fail "ambient process state reached a transitive Git execution boundary"
fi

info "a deletion-first multi-ref push still validates later refs"
printf '%s\n%s\n' \
    "refs/heads/deleted $ZERO refs/heads/deleted remote-deleted" \
    "refs/heads/topic local-bad refs/heads/topic remote-bad" |
    PATH="$FAKE_BIN:/usr/bin:/bin" GIT_LOG="$GIT_LOG" \
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            origin ssh://origin.invalid/repo \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            origin ssh://origin.invalid/repo \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            origin ssh://origin.invalid/repo \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            origin ssh://origin.invalid/repo \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            upstream ssh://upstream.invalid/repo \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
        --odysseus-test-git "$FAKE_BIN/git" -- \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
        --odysseus-test-git "$FAKE_BIN/git" -- origin \
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
        ODYSSEUS_SIGNATURE_TEST_MODE=1 \
        bash "$ROOT/scripts/check-push-signatures.sh" \
            --odysseus-test-git "$FAKE_BIN/git" -- \
            origin ssh://origin.invalid/repo \
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

info "the native verifier ignores an ambient PATH replacement for Git"
AMBIENT_GIT_REPO="$TMP/ambient-git-repo"
mkdir "$AMBIENT_GIT_REPO"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -c init.templateDir= -C "$AMBIENT_GIT_REPO" init -q
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$AMBIENT_GIT_REPO" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit --allow-empty -qm base
ambient_base=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$AMBIENT_GIT_REPO" rev-parse HEAD)
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$AMBIENT_GIT_REPO" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit --allow-empty -qm topic
ambient_tip=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$AMBIENT_GIT_REPO" rev-parse HEAD)
AMBIENT_BIN="$TMP/ambient-git-bin"
AMBIENT_MARKER="$TMP/ambient-git-ran"
mkdir "$AMBIENT_BIN"
cat > "$AMBIENT_BIN/git" <<'SH'
#!/usr/bin/env bash
: > "${AMBIENT_MARKER:?}"
case "${1:-}" in
    rev-list) printf '%s\n' "${AMBIENT_TIP:?}" ;;
    log) printf 'G\n' ;;
    *) exit 92 ;;
esac
SH
chmod +x "$AMBIENT_BIN/git"
printf '%s\n' \
    "refs/heads/topic $ambient_tip refs/heads/topic $ambient_base" |
    (
        cd "$AMBIENT_GIT_REPO" || exit 93
        PATH="$AMBIENT_BIN:/usr/bin:/bin" \
            AMBIENT_MARKER="$AMBIENT_MARKER" AMBIENT_TIP="$ambient_tip" \
            bash "$ROOT/scripts/check-push-signatures.sh" origin unused
    ) > "$TMP/ambient-git.out" 2> "$TMP/ambient-git.err"
ambient_status=$?
if [ "$ambient_status" -ne 0 ] && [ ! -e "$AMBIENT_MARKER" ] \
    && { grep -q "$ambient_tip(N)" "$TMP/ambient-git.err" \
        || grep -q 'explicit commit-signature policy is required' \
            "$TMP/ambient-git.err"; }; then
    pass "ambient PATH cannot replace the Git or signature-verifier boundary"
else
    sed 's/^/    /' "$TMP/ambient-git.err" >&2
    fail "ambient PATH selected the Git or signature-verifier boundary"
fi

info "the native pre-push hook executes the verifier from immutable HEAD bytes"
NATIVE_HOOK_REPO="$TMP/native-hook-repo"
NATIVE_VERIFIER_RESULT="$TMP/native-verifier-result"
mkdir -p "$NATIVE_HOOK_REPO/scripts"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -c init.templateDir= -C "$NATIVE_HOOK_REPO" init -q
cat > "$NATIVE_HOOK_REPO/scripts/check-push-signatures.sh" <<'SH'
#!/bin/bash
printf 'committed-verifier\n' > "${NATIVE_VERIFIER_RESULT:?}"
SH
chmod +x "$NATIVE_HOOK_REPO/scripts/check-push-signatures.sh"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$NATIVE_HOOK_REPO" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false add scripts/check-push-signatures.sh
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$NATIVE_HOOK_REPO" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm verifier
cat > "$NATIVE_HOOK_REPO/scripts/check-push-signatures.sh" <<'SH'
#!/bin/bash
printf 'worktree-replacement\n' > "${NATIVE_VERIFIER_RESULT:?}"
SH
chmod +x "$NATIVE_HOOK_REPO/scripts/check-push-signatures.sh"
(
    cd "$NATIVE_HOOK_REPO" || exit 93
    NATIVE_VERIFIER_RESULT="$NATIVE_VERIFIER_RESULT" \
        /bin/bash "$ROOT/.githooks/pre-push" origin unused </dev/null
) > "$TMP/native-hook.out" 2> "$TMP/native-hook.err"
native_hook_status=$?
native_verifier_value=
if [ -f "$NATIVE_VERIFIER_RESULT" ]; then
    native_verifier_value=$(cat "$NATIVE_VERIFIER_RESULT")
fi
if [ "$native_hook_status" -eq 0 ] \
    && [ "$native_verifier_value" = committed-verifier ]; then
    pass "worktree replacement cannot change the bound verifier bytes"
else
    sed 's/^/    /' "$TMP/native-hook.err" >&2
    fail "native pre-push reopened the mutable worktree verifier"
fi

info "the native pre-push shebang ignores ambient Bash startup code"
NATIVE_STARTUP_MARKER="$TMP/native-startup-ran"
NATIVE_STARTUP_FILE="$TMP/native-startup.sh"
NATIVE_STARTUP_HOME="$TMP/native-startup-home"
mkdir "$NATIVE_STARTUP_HOME"
printf ': > %q\n' "$NATIVE_STARTUP_MARKER" > "$NATIVE_STARTUP_FILE"
rm -f "$NATIVE_VERIFIER_RESULT"
(
    cd "$NATIVE_HOOK_REPO" || exit 93
    env -i \
        BASH_ENV="$NATIVE_STARTUP_FILE" \
        ENV="$NATIVE_STARTUP_FILE" \
        HOME="$NATIVE_STARTUP_HOME" \
        NATIVE_VERIFIER_RESULT="$NATIVE_VERIFIER_RESULT" \
        PATH=/usr/bin:/bin \
        "$ROOT/.githooks/pre-push" origin unused </dev/null
) > "$TMP/native-startup.out" 2> "$TMP/native-startup.err"
native_startup_status=$?
native_startup_value=
if [ -f "$NATIVE_VERIFIER_RESULT" ]; then
    native_startup_value=$(cat "$NATIVE_VERIFIER_RESULT")
fi
if [ "$native_startup_status" -eq 0 ] && \
    [ "$native_startup_value" = committed-verifier ] && \
    [ ! -e "$NATIVE_STARTUP_MARKER" ]; then
    pass "the native pre-push boundary starts without ambient shell code"
else
    sed 's/^/    /' "$TMP/native-startup.err" >&2
    fail "ambient shell startup code ran before the pre-push boundary"
fi

info "the native pre-push hook pins one verifier blob across a concurrent HEAD move"
HEAD_MOVE_REPO="$TMP/native-head-move"
HEAD_MOVE_RESULT="$TMP/native-head-move-result"
mkdir -p "$HEAD_MOVE_REPO/scripts"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -c init.templateDir= -C "$HEAD_MOVE_REPO" init -q
cat > "$HEAD_MOVE_REPO/scripts/check-push-signatures.sh" <<'SH'
#!/bin/bash
printf 'old-head-verifier\n' > "${HEAD_MOVE_RESULT:?}"
SH
chmod +x "$HEAD_MOVE_REPO/scripts/check-push-signatures.sh"
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" add scripts/check-push-signatures.sh
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm old-verifier
old_head=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" rev-parse HEAD)
cat > "$HEAD_MOVE_REPO/scripts/check-push-signatures.sh" <<'SH'
#!/bin/bash
printf 'new-head-verifier\n' > "${HEAD_MOVE_RESULT:?}"
SH
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" add scripts/check-push-signatures.sh
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" \
    -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c commit.gpgsign=false commit -qm new-verifier
new_head=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" rev-parse HEAD)
head_ref=$(env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" symbolic-ref HEAD)
env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    "$SYSTEM_GIT" -C "$HEAD_MOVE_REPO" update-ref "$head_ref" "$old_head" "$new_head"
head_ref_path="$HEAD_MOVE_REPO/.git/$head_ref"
rm "$head_ref_path"
mkfifo "$head_ref_path"
head_fifo_ready="$HEAD_MOVE_REPO/fifo-ready"
head_fifo_release="$HEAD_MOVE_REPO/fifo-release"
python3 -I -S - "$head_ref_path" "$old_head" \
    "$head_fifo_ready" "$head_fifo_release" <<'PY' &
import os
import sys
import time

fifo, old_head, ready, release = sys.argv[1:]
descriptor = os.open(fifo, os.O_WRONLY)
with open(ready, "xb"):
    pass
deadline = time.monotonic() + 5
while not os.path.exists(release):
    if time.monotonic() >= deadline:
        os.close(descriptor)
        raise SystemExit(2)
    time.sleep(0.01)
os.write(descriptor, (old_head + "\n").encode("ascii"))
os.close(descriptor)
PY
head_fifo_writer=$!
(
    cd "$HEAD_MOVE_REPO" || exit 93
    HEAD_MOVE_RESULT="$HEAD_MOVE_RESULT" \
        /bin/bash "$ROOT/.githooks/pre-push" origin unused </dev/null
) > "$TMP/native-head-move.out" 2> "$TMP/native-head-move.err" &
head_move_hook=$!
for _attempt in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do
    [ -e "$head_fifo_ready" ] && break
    kill -0 "$head_move_hook" 2>/dev/null || break
    /bin/sleep 0.05
done
if [ -e "$head_fifo_ready" ]; then
    rm "$head_ref_path"
    printf '%s\n' "$new_head" > "$head_ref_path"
    : > "$head_fifo_release"
fi
set +e
wait "$head_move_hook"
head_move_status=$?
kill "$head_fifo_writer" 2>/dev/null
wait "$head_fifo_writer" 2>/dev/null
set +e
head_move_value=
if [ -f "$HEAD_MOVE_RESULT" ]; then
    head_move_value=$(cat "$HEAD_MOVE_RESULT")
fi
if [ -e "$head_fifo_ready" ] && [ "$head_move_status" -eq 0 ] \
    && [ "$head_move_value" = old-head-verifier ]; then
    pass "one resolved verifier blob remains authoritative after HEAD moves"
else
    sed 's/^/    /' "$TMP/native-head-move.err" >&2
    fail "a concurrent HEAD move changed the verifier transaction"
fi

INSTALL_BIN="$TMP/install-bin"
PRECOMMIT_FIXTURE="$INSTALL_BIN/pre-commit-fixture"
PRECOMMIT_PROVIDER_PREFIX="$INSTALL_BIN/provider"
PRECOMMIT_PROVIDER_PYTHON="$PRECOMMIT_PROVIDER_PREFIX/bin/python3"
PRECOMMIT_ABI=$(python3 -I -S -c \
    'import sys; print("python{}.{}".format(*sys.version_info[:2]))')
PRECOMMIT_SITE="$PRECOMMIT_PROVIDER_PREFIX/lib/$PRECOMMIT_ABI/site-packages"
PRECOMMIT_FIXTURE_BODY_SHA256=275fd99404a7a8772fd7ab66a800b934db632f4c4e64787f9b5aa6f9662c870c
INSTALL_WRAPPER_REL=scripts/install/dev/80-precommit.sh
HELPER_REL=scripts/install/dev/precommit_hooks.py
mkdir -p \
    "$PRECOMMIT_PROVIDER_PREFIX/bin" \
    "$PRECOMMIT_SITE/pre_commit" \
    "$PRECOMMIT_SITE/pre_commit-3.8.0.dist-info" \
    "$PRECOMMIT_SITE/yaml" \
    "$PRECOMMIT_SITE/PyYAML-6.0.3.dist-info"
PRECOMMIT_HOST_PYTHON=$(python3 -I -S -c \
    'import os,sys; print(os.path.realpath(sys.executable))')
cp "$PRECOMMIT_HOST_PYTHON" "$PRECOMMIT_PROVIDER_PYTHON"
chmod +x "$PRECOMMIT_PROVIDER_PYTHON"
printf 'home = %s\ninclude-system-site-packages = false\n' \
    "$(dirname "$PRECOMMIT_HOST_PYTHON")" \
    > "$PRECOMMIT_PROVIDER_PREFIX/pyvenv.cfg"

sha256_file() {
    python3 -I -S - "$1" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as stream:
    print(hashlib.sha256(stream.read()).hexdigest())
PY
}

cat > "$PRECOMMIT_SITE/pre_commit/fixture.py" <<'PY'
import os
import re
import sys


HOOK = """#!/usr/bin/env bash
# File generated by pre-commit: https://pre-commit.com
# ID: 138fd403232d2ddd5efb44317e38bf03

# start templated
INSTALL_PYTHON=/definitely/missing/python
ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=@HOOK_TYPE@)
# end templated

HERE="$(cd "$(dirname "$0")" && pwd)"
ARGS+=(--hook-dir "$HERE" -- "$@")

if [ -x "$INSTALL_PYTHON" ]; then
    exec "$INSTALL_PYTHON" -mpre_commit "${ARGS[@]}"
elif command -v pre-commit > /dev/null; then
    exec pre-commit "${ARGS[@]}"
else
    echo '`pre-commit` not found.  Did you forget to activate your virtualenv?' 1>&2
    exit 1
fi
"""


def unexpected(arguments):
    sys.stderr.write("unexpected fixture syntax: {}\n".format(" ".join(arguments)))
    raise SystemExit(76)


def require_clean_environment():
    environment = os.environ
    if (
        "PYTHONPATH" in environment
        or "PYTHONHOME" in environment
        or "ATTACK_MARKER" in environment
        or environment.get("PYTHONNOUSERSITE") != "1"
        or environment.get("GIT_CONFIG_GLOBAL") != "/dev/null"
        or environment.get("GIT_CONFIG_NOSYSTEM") != "1"
        or not os.path.isdir(environment.get("HOME", ""))
        or not os.path.isdir(environment.get("PRE_COMMIT_HOME", ""))
    ):
        sys.stderr.write("fixture received an unsafe environment\n")
        raise SystemExit(72)


def config(path=".pre-commit-config.yaml"):
    try:
        with open(path, "r", encoding="utf-8") as stream:
            text = stream.read()
    except OSError:
        unexpected(("missing configuration", path))
    action_match = re.search(r"(?m)^# fixture-action: ([^\r\n]+)$", text)
    action = action_match.group(1) if action_match else "pass"
    inline = re.search(r"(?m)^default_install_hook_types:\s*\[([^]]*)\]", text)
    if inline:
        hooks = tuple(
            value.strip().strip("'\"")
            for value in inline.group(1).split(",")
            if value.strip()
        )
    else:
        block = re.search(
            r"(?ms)^default_install_hook_types:\s*\n((?:\s+-[^\n]*\n?)+)", text
        )
        hooks = tuple(
            value.strip().strip("'\"")
            for value in re.findall(r"(?m)^\s+-\s*([^\r\n]+)", block.group(1))
        ) if block else ()
    if not hooks:
        unexpected(("missing default_install_hook_types",))
    if action.startswith("fail-"):
        sys.stderr.write("fixture validation failure: {}\n".format(action[5:]))
        raise SystemExit(78)
    if action != "pass":
        sys.stderr.write("invalid fixture action: {}\n".format(action))
        raise SystemExit(75)
    return hooks


def write_hook(hook_type):
    path = os.path.join(".git", "hooks", hook_type)
    with open(path, "w", encoding="utf-8", newline="\n") as stream:
        stream.write(HOOK.replace("@HOOK_TYPE@", hook_type))
    os.chmod(path, 0o755)


def hook_impl(arguments):
    config_path = ""
    hook_type = ""
    hook_dir = ""
    while arguments:
        value = arguments.pop(0)
        if value.startswith("--config="):
            config_path = value.partition("=")[2]
            if config_path != "/odysseus/runtime/config.yaml":
                unexpected((value,))
        elif value.startswith("--hook-type="):
            hook_type = value.partition("=")[2]
        elif value == "--hook-dir" and arguments:
            hook_dir = arguments.pop(0)
        elif value == "--":
            break
        else:
            unexpected((value,))
    if not config_path or not hook_type or not hook_dir:
        unexpected(("incomplete hook invocation",))
    config(config_path)
    legacy = os.path.join(hook_dir, hook_type + ".legacy")
    if os.access(legacy, os.X_OK):
        os.execv(legacy, [legacy, *arguments])
    return 0


def main():
    require_clean_environment()
    arguments = list(sys.argv[1:])
    if arguments == ["--version"]:
        print("pre-commit 3.8.0")
        return 0
    if arguments and arguments[0] == "hook-impl":
        return hook_impl(arguments[1:])
    hooks = config()
    if arguments == ["validate-config", ".pre-commit-config.yaml"]:
        return 0
    if not arguments or arguments.pop(0) != "install":
        unexpected(tuple(sys.argv[1:]))
    install_hooks = False
    requested = []
    while arguments:
        value = arguments.pop(0)
        if value == "--install-hooks":
            install_hooks = True
        elif value == "--hook-type" and arguments:
            hook_type = arguments.pop(0)
            if hook_type.startswith("--"):
                unexpected((hook_type,))
            requested.append(hook_type)
        else:
            unexpected((value,))
    if install_hooks and tuple(requested) != hooks:
        sys.stderr.write("requested hook inventory differs from configured inventory\n")
        return 77
    if not install_hooks and requested:
        sys.stderr.write("discovery received explicit hook types\n")
        return 77
    os.makedirs(os.path.join(".git", "hooks"), exist_ok=True)
    for hook_type in hooks:
        write_hook(hook_type)
    return 0
PY
printf '%s\n' '' > "$PRECOMMIT_SITE/pre_commit/__init__.py"
cat > "$PRECOMMIT_FIXTURE" <<PY
#!$PRECOMMIT_PROVIDER_PYTHON
from pre_commit.fixture import main
raise SystemExit(main())
PY
cat > "$PRECOMMIT_SITE/pre_commit-3.8.0.dist-info/METADATA" <<'EOF'
Name: pre-commit
Version: 3.8.0
EOF
cat > "$PRECOMMIT_SITE/pre_commit-3.8.0.dist-info/RECORD" <<'EOF'
pre_commit/__init__.py,,
pre_commit/fixture.py,,
pre_commit-3.8.0.dist-info/METADATA,,
pre_commit-3.8.0.dist-info/RECORD,,
EOF
cat > "$PRECOMMIT_SITE/yaml/__init__.py" <<'PY'
__version__ = "6.0.3"
PY
cat > "$PRECOMMIT_SITE/PyYAML-6.0.3.dist-info/METADATA" <<'EOF'
Name: PyYAML
Version: 6.0.3
EOF
cat > "$PRECOMMIT_SITE/PyYAML-6.0.3.dist-info/RECORD" <<'EOF'
yaml/__init__.py,,
PyYAML-6.0.3.dist-info/METADATA,,
PyYAML-6.0.3.dist-info/RECORD,,
EOF
chmod +x "$PRECOMMIT_FIXTURE"
ln -s "$(basename "$PRECOMMIT_FIXTURE")" "$INSTALL_BIN/pre-commit"

write_config() {
    local repo=$1 hook_types=$2 tag=$3 action=${4:-pass}
    case "$hook_types" in
        'pre-commit pre-push')
            printf '%s\n' \
                "# fixture: $tag" \
                "# fixture-action: $action" \
                'default_install_hook_types: [pre-commit, pre-push]' \
                'repos: []' > "$repo/.pre-commit-config.yaml"
            ;;
        pre-push)
            printf '%s\n' \
                "# fixture: $tag" \
                "# fixture-action: $action" \
                'default_install_hook_types: [pre-push]' \
                'repos: []' > "$repo/.pre-commit-config.yaml"
            ;;
        commit-msg)
            printf '%s\n' \
                "# fixture: $tag" \
                "# fixture-action: $action" \
                'default_install_hook_types:' \
                '  - "commit-msg"' \
                'repos: []' > "$repo/.pre-commit-config.yaml"
            ;;
        *)
            fail_exit "test fixture requested unsupported hooks: $hook_types"
            ;;
    esac
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
exec /usr/bin/python3 -I -S -c '
import hashlib
import os
import resource
import signal
import sys
arguments = b"".join(os.fsencode(value) + b"\0" for value in sys.argv[1:])
transaction = sys.stdin.buffer.read()
print("ODYSSEUS_TEST_ARGC={}".format(len(sys.argv) - 1))
print("ODYSSEUS_TEST_ARGS_SHA256={}".format(hashlib.sha256(arguments).hexdigest()))
print("ODYSSEUS_TEST_STDIN_SHA256={}".format(hashlib.sha256(transaction).hexdigest()))
' "$@"
SH
    chmod +x "$repo/scripts/check-push-signatures.sh"
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -c init.templateDir= -C "$repo" init -q
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -C "$repo" add scripts/check-push-signatures.sh
    env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        "$SYSTEM_GIT" -C "$repo" \
        -c user.name=Fixture -c user.email=fixture@example.invalid \
        -c commit.gpgsign=false commit -qm verifier-fixture
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

boundary_nonproof() {
    [ "$HOST_KERNEL" != Linux ] || return 1
    local output
    for output in "$@"; do
        grep -Eq \
            'no (trusted )?secure execution boundary|no trusted Python interpreter can execute the sealed provider|immutable (executable|helper) snapshots are unavailable' \
            "$output" || return 1
    done
}

hook_inventory() {
    local repo=$1
    find "$repo/.git/hooks" -maxdepth 1 -type f ! -name '*.sample' \
        -exec basename {} \; | LC_ALL=C sort
}

info "the installer bootstrap does not execute ambient PATH utilities"
BOOTSTRAP_REPO="$TMP/bootstrap-path"
BOOTSTRAP_BIN="$TMP/bootstrap-hostile-bin"
BOOTSTRAP_MARKER="$TMP/bootstrap-hostile-ran"
mkdir -p "$TMP/ambient-home"
make_repo "$BOOTSTRAP_REPO"
write_config "$BOOTSTRAP_REPO" 'pre-commit pre-push' bootstrap-path
mkdir "$BOOTSTRAP_BIN"
for hostile_name in dirname python3 git env pre-commit; do
    cat > "$BOOTSTRAP_BIN/$hostile_name" <<'SH'
#!/bin/bash
printf '%s\n' "$0" >> "${BOOTSTRAP_MARKER:?}"
exit 97
SH
    chmod +x "$BOOTSTRAP_BIN/$hostile_name"
done
env \
    PATH="$BOOTSTRAP_BIN:/usr/bin:/bin" \
    HOME="$TMP/ambient-home" \
    BOOTSTRAP_MARKER="$BOOTSTRAP_MARKER" \
    ODYSSEUS_ROOT="$BOOTSTRAP_REPO" \
    ODYSSEUS_PRECOMMIT_BINARY="$PRECOMMIT_FIXTURE" \
    ODYSSEUS_PRECOMMIT_EXPECTED_VERSION=3.8.0 \
    INSTALL=false \
    /bin/bash "$BOOTSTRAP_REPO/$INSTALL_WRAPPER_REL" \
    > "$TMP/bootstrap-path.out" 2>&1
bootstrap_path_status=$?
if [ ! -e "$BOOTSTRAP_MARKER" ] &&
    { { grep -q 'pre-commit 3.8.0' "$TMP/bootstrap-path.out" &&
        { [ "$bootstrap_path_status" -eq 0 ] ||
            grep -q 'installed managed hook inventory is not exact' \
                "$TMP/bootstrap-path.out"; }; } \
      || boundary_nonproof "$TMP/bootstrap-path.out"; }; then
    pass "bootstrap tools are fixed and the helper is bound before execution"
else
    sed 's/^/    /' "$TMP/bootstrap-path.out" >&2
    fail "ambient PATH code ran before the installer security boundary"
fi

info "the installer bootstrap rejects a helper FIFO without blocking"
BOOTSTRAP_FIFO_REPO="$TMP/bootstrap-fifo"
make_repo "$BOOTSTRAP_FIFO_REPO"
rm "$BOOTSTRAP_FIFO_REPO/$HELPER_REL"
mkfifo "$BOOTSTRAP_FIFO_REPO/$HELPER_REL"
python3 -I -S - \
    "$BOOTSTRAP_FIFO_REPO/$INSTALL_WRAPPER_REL" \
    "$BOOTSTRAP_FIFO_REPO" "$PRECOMMIT_FIXTURE" \
    "$TMP/bootstrap-fifo.out" <<'PY'
import os
import subprocess
import sys

wrapper, root, pre_commit, output = sys.argv[1:]
environment = {
    "HOME": os.path.join(root, "home"),
    "INSTALL": "false",
    "ODYSSEUS_PRECOMMIT_BINARY": pre_commit,
    "ODYSSEUS_PRECOMMIT_EXPECTED_VERSION": "3.8.0",
    "ODYSSEUS_ROOT": root,
    "PATH": "/usr/bin:/bin",
}
os.mkdir(environment["HOME"], 0o700)
try:
    result = subprocess.run(
        ["/bin/bash", wrapper],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        timeout=2,
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
bootstrap_fifo_status=$?
if [ "$bootstrap_fifo_status" -ne 0 ] && \
    [ "$bootstrap_fifo_status" -ne 99 ] && \
    grep -Eq 'cannot bind the pre-commit helper|helper is not one direct regular file|immutable helper snapshots are unavailable' \
        "$TMP/bootstrap-fifo.out"; then
    pass "the helper is opened nonblocking and rejected before execution"
else
    sed 's/^/    /' "$TMP/bootstrap-fifo.out" >&2
    fail "a helper FIFO blocked or entered the installer boundary"
fi

info "the controlled pre-commit fixture has known bytes and a selected version"
FIXTURE_REPO="$TMP/fixture-version"
make_repo "$FIXTURE_REPO"
write_config "$FIXTURE_REPO" 'pre-commit pre-push' fixture-version
actual_fixture_digest=$(python3 -I -S - "$PRECOMMIT_FIXTURE" <<'PY'
import hashlib
import sys
with open(sys.argv[1], "rb") as stream:
    _shebang, separator, body = stream.read().partition(b"\n")
if not separator:
    raise SystemExit(1)
print(hashlib.sha256(body).hexdigest())
PY
)
run_installer "$FIXTURE_REPO" true 3.8.0 "$TMP/version-pass.out"
version_pass_status=$?
run_installer "$FIXTURE_REPO" false 9.9.9 "$TMP/version-mismatch.out"
version_mismatch_status=$?
if [ "$actual_fixture_digest" = "$PRECOMMIT_FIXTURE_BODY_SHA256" ] &&
    [ "$version_pass_status" -eq 0 ] &&
    [ "$version_mismatch_status" -ne 0 ] &&
    grep -q 'expected pre-commit 9.9.9, found 3.8.0' \
        "$TMP/version-mismatch.out"; then
    pass "known fixture bytes and the requested fixture version are enforced"
elif boundary_nonproof "$TMP/version-pass.out" "$TMP/version-mismatch.out"; then
    info "NON_PROOF: fixture installation requires the Linux execution boundary"
else
    sed 's/^/    /' "$TMP/version-pass.out" >&2
    sed 's/^/    /' "$TMP/version-mismatch.out" >&2
    fail "fixture provenance or requested version enforcement failed"
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
installed_stdin_digest=$(sha256_file "$TMP/installed-hook.input")
installed_args_digest=$(sha256_file "$TMP/installed-hook.expected-args")
mkdir -p "$TMP/hook-home" "$TMP/hook-cache"
cat > "$INSTALL_BIN/git" <<'SH'
#!/usr/bin/env bash
: > "${HOOK_AMBIENT_GIT_MARKER:?}"
exit 94
SH
chmod +x "$INSTALL_BIN/git"
(
    cd "$INSTALL_REPO" || exit 90
    env -i \
        PATH="$INSTALL_BIN:/usr/bin:/bin" \
        HOME="$TMP/hook-home" \
        PRE_COMMIT_HOME="$TMP/hook-cache" \
        PYTHONNOUSERSITE=1 \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        HOOK_AMBIENT_GIT_MARKER="$TMP/installed-hook.ambient-git" \
        "$INSTALL_REPO/.git/hooks/pre-push" \
        'upstream remote' 'ssh://upstream.invalid/repo with space'
) < "$TMP/installed-hook.input" > "$TMP/installed-hook.out" 2>&1
hook_status=$?
rm "$INSTALL_BIN/git"
inventory=$(hook_inventory "$INSTALL_REPO")
install_contract_nonproof=false
if boundary_nonproof "$TMP/install-contract.out" "$TMP/check-contract.out"; then
    install_contract_nonproof=true
fi
if [ "$install_status" -eq 0 ] && [ "$check_status" -eq 0 ] &&
    [ "$hook_status" -eq 0 ] &&
    [ "$inventory" = $'pre-commit\npre-push\npre-push.legacy' ] &&
    cmp -s "$INSTALL_REPO/.githooks/pre-push" \
        "$INSTALL_REPO/.git/hooks/pre-push.legacy" &&
    [ ! -e "$TMP/installed-hook.ambient-git" ] &&
    grep -Fqx 'ODYSSEUS_TEST_ARGC=2' "$TMP/installed-hook.out" &&
    grep -Fqx "ODYSSEUS_TEST_ARGS_SHA256=$installed_args_digest" \
        "$TMP/installed-hook.out" &&
    grep -Fqx "ODYSSEUS_TEST_STDIN_SHA256=$installed_stdin_digest" \
        "$TMP/installed-hook.out"; then
    pass "install and check keep the exact hook inventory and full push input"
elif [ "$install_contract_nonproof" = true ]; then
    info "NON_PROOF: managed-hook installation requires the Linux execution boundary"
else
    sed 's/^/    /' "$TMP/install-contract.out" >&2
    sed 's/^/    /' "$TMP/check-contract.out" >&2
    sed 's/^/    /' "$TMP/installed-hook.out" >&2
    fail "installed hooks did not preserve the signed pre-push transaction"
fi

info "installed managed hooks bind the selected executable provenance"
cp "$PRECOMMIT_FIXTURE" "$TMP/pre-commit-fixture.saved"
cat > "$PRECOMMIT_FIXTURE" <<'SH'
#!/bin/bash
: > "${POST_INSTALL_REPLACEMENT_MARKER:?}"
exit 0
SH
chmod +x "$PRECOMMIT_FIXTURE"
(
    cd "$INSTALL_REPO" || exit 90
    env -i \
        PATH="$INSTALL_BIN:/usr/bin:/bin" \
        HOME="$TMP/hook-home" \
        PRE_COMMIT_HOME="$TMP/hook-cache" \
        POST_INSTALL_REPLACEMENT_MARKER="$TMP/post-install-replacement-ran" \
        "$INSTALL_REPO/.git/hooks/pre-commit"
) > "$TMP/post-install-replacement.out" 2>&1
post_install_replacement_status=$?
cp "$TMP/pre-commit-fixture.saved" "$PRECOMMIT_FIXTURE"
chmod +x "$PRECOMMIT_FIXTURE"
if [ "$post_install_replacement_status" -ne 0 ] &&
    [ ! -e "$TMP/post-install-replacement-ran" ] &&
    grep -q 'executable provenance changed' \
        "$TMP/post-install-replacement.out"; then
    pass "post-install executable replacement fails before selected bytes run"
elif [ "$install_contract_nonproof" = true ]; then
    info "NON_PROOF: installed-provider execution requires the Linux boundary"
else
    sed 's/^/    /' "$TMP/post-install-replacement.out" >&2
    fail "an installed hook executed a replaced pre-commit program"
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
elif boundary_nonproof "$TMP/tampered-check.out"; then
    info "NON_PROOF: managed-hook checking requires the Linux execution boundary"
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
elif boundary_nonproof "$TMP/stale-before.out" "$TMP/stale-after.out"; then
    info "NON_PROOF: managed-hook reconciliation requires the Linux boundary"
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
elif boundary_nonproof "$TMP/unmanaged-hook.out" "$TMP/unmanaged-legacy.out"; then
    info "NON_PROOF: unmanaged-hook conflict testing requires the Linux boundary"
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
elif boundary_nonproof "$TMP/poisoned-environment.out"; then
    info "NON_PROOF: managed provider execution requires the Linux boundary"
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
printf '#!%s\n' "$PRECOMMIT_PROVIDER_PYTHON" > "$HUNG_PRECOMMIT"
cat >> "$HUNG_PRECOMMIT" <<'PY'
import signal
import time

signal.signal(signal.SIGTERM, signal.SIG_IGN)
while True:
    time.sleep(1)
PY
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
    "--timeout", "2",
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
elif boundary_nonproof "$TMP/fifo.out" "$TMP/hung.out"; then
    info "NON_PROOF: contained FIFO/timeout execution requires the Linux boundary"
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
elif boundary_nonproof "$TMP/aggregate.out"; then
    info "NON_PROOF: contained repository aggregation requires the Linux boundary"
else
    sed 's/^/    /' "$TMP/aggregate.out" >&2
    fail "the installer stopped before it reported all repository failures"
fi

info "namespace-owned scratch cannot be swapped onto a host route"
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
host_scratch_count=$(find "$SWAP_TMP" -mindepth 1 -print | wc -l | tr -d ' ')
if [ "$swap_status" -ne 0 ] && [ "$replacement_count" -eq 0 ] &&
    [ "$host_scratch_count" -eq 0 ] &&
    grep -q 'no trusted secure execution boundary\|no secure execution boundary' \
        "$TMP/cleanup-swap.out"; then
    pass "an unsupported host fails closed before allocating scratch"
elif [ "$swap_status" -ne 0 ] && [ "$replacement_count" -eq 0 ] &&
    [ "$host_scratch_count" -eq 0 ]; then
    pass "namespace teardown reclaims a private scratch-route replacement"
else
    sed 's/^/    /' "$TMP/cleanup-swap.out" >&2
    fail "a private scratch-route replacement escaped onto the host"
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
        real_stdin_digest=$(sha256_file "$TMP/real-installed-hook.input")
        real_args_digest=$(sha256_file "$TMP/real-installed-hook.expected-args")
        mkdir -p "$TMP/real-hook-home" "$TMP/real-hook-cache"
        (
            cd "$REAL_REPO" || exit 90
            env \
                PATH="$(dirname "$REAL_PRECOMMIT"):/usr/bin:/bin" \
                HOME="$TMP/real-hook-home" \
                PRE_COMMIT_HOME="$TMP/real-hook-cache" \
                GIT_CONFIG_GLOBAL=/dev/null \
                GIT_CONFIG_NOSYSTEM=1 \
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
            grep -Fqx 'ODYSSEUS_TEST_ARGC=2' \
                "$TMP/real-installed-hook.out" &&
            grep -Fqx "ODYSSEUS_TEST_ARGS_SHA256=$real_args_digest" \
                "$TMP/real-installed-hook.out" &&
            grep -Fqx "ODYSSEUS_TEST_STDIN_SHA256=$real_stdin_digest" \
                "$TMP/real-installed-hook.out"; then
            pass "real pre-commit 3.8.0 preserves exact push arguments"
        else
            sed 's/^/    /' "$TMP/real-precommit.out" >&2
            sed 's/^/    /' "$TMP/real-installed-hook.out" >&2
            fail "real pre-commit 3.8.0 lost YAML selection or the push transaction"
        fi

        info "the installed managed pre-commit hook runs the real forbid-or-true policy"
        if [ "$HOST_KERNEL" = Linux ]; then
            POLICY_REPO="$TMP/real-forbid-or-true"
            make_repo "$POLICY_REPO"
            awk '
                /^      - id:/ {
                    hooks += 1
                    if (hooks == 2) exit
                }
                { print }
            ' "$ROOT/.pre-commit-config.yaml" \
                > "$POLICY_REPO/.pre-commit-config.yaml"
            cp "$ROOT/scripts/check_silent_failures.py" \
                "$POLICY_REPO/scripts/check_silent_failures.py"
            printf '#!/bin/sh\nprobe || true\n' \
                > "$POLICY_REPO/scripts/suppressed.sh"
            chmod +x "$POLICY_REPO/scripts/suppressed.sh"
            if grep -Eq '^[[:space:]]*- id: forbid-or-true$' \
                "$POLICY_REPO/.pre-commit-config.yaml"; then
                real_forbid_id_status=0
            else
                real_forbid_id_status=1
            fi
            env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
                "$SYSTEM_GIT" -C "$POLICY_REPO" add \
                .pre-commit-config.yaml scripts/check_silent_failures.py \
                scripts/suppressed.sh
            env \
                PATH="$(dirname "$REAL_PRECOMMIT"):/usr/bin:/bin" \
                HOME="$TMP/real-version-home" \
                GIT_CONFIG_GLOBAL=/dev/null \
                GIT_CONFIG_NOSYSTEM=1 \
                ODYSSEUS_ROOT="$POLICY_REPO" \
                ODYSSEUS_PRECOMMIT_BINARY="$REAL_PRECOMMIT" \
                ODYSSEUS_PRECOMMIT_EXPECTED_VERSION="$real_version" \
                INSTALL=true \
                /bin/bash "$POLICY_REPO/$INSTALL_WRAPPER_REL" \
                > "$TMP/real-forbid-install.out" 2>&1
            real_forbid_install_status=$?
            printf 'default_install_hook_types: [pre-commit]\nrepos: []\n' \
                > "$POLICY_REPO/.pre-commit-config.yaml"
            printf 'raise SystemExit(0)\n' \
                > "$POLICY_REPO/scripts/check_silent_failures.py"
            env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
                "$SYSTEM_GIT" -C "$POLICY_REPO" add \
                .pre-commit-config.yaml scripts/check_silent_failures.py
            real_forbid_restaged_status=$?
            (
                cd "$POLICY_REPO" || exit 90
                env \
                    PATH="$(dirname "$REAL_PRECOMMIT"):/usr/bin:/bin" \
                    HOME="$TMP/real-hook-home" \
                    PRE_COMMIT_HOME="$TMP/real-hook-cache" \
                    GIT_CONFIG_GLOBAL=/dev/null \
                    GIT_CONFIG_NOSYSTEM=1 \
                    ODYSSEUS_TRUSTED_POLICY_ROOT=/hostile/policy \
                    ODYSSEUS_PRE_COMMIT_PROVIDER=/hostile/provider \
                    "$POLICY_REPO/.git/hooks/pre-commit"
            ) > "$TMP/real-forbid-hook.out" 2>&1
            real_forbid_hook_status=$?
            if [ "$real_forbid_install_status" -eq 0 ] && \
                [ "$real_forbid_restaged_status" -eq 0 ] && \
                [ "$real_forbid_id_status" -eq 0 ] && \
                [ "$real_forbid_hook_status" -ne 0 ] && \
                grep -Eq \
                    'scripts/suppressed\.sh:2: forbidden .*failure workaround' \
                    "$TMP/real-forbid-hook.out"; then
                pass "installed managed policy rejects a staged suppression without ambient authority"
            else
                sed 's/^/    /' "$TMP/real-forbid-install.out" >&2
                sed 's/^/    /' "$TMP/real-forbid-hook.out" >&2
                fail "installed forbid-or-true did not execute through the managed boundary"
            fi
        else
            info "SKIP (non-proof): installed managed-policy execution requires Linux"
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

import ctypes
import errno
import hashlib
import importlib.util
import os
import re
import resource
import select
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


def write_provider_shell_fixture(path, body, base):
    """Run a shell scenario through the fixture's declared Python provider."""
    interpreter = os.path.join(base, "install-bin", "provider", "bin", "python3")
    program = (
        "#!{}\n"
        "import subprocess, sys\n"
        "raise SystemExit(subprocess.call(['/bin/sh', '-c', {!r}, sys.argv[0]]))\n"
    ).format(interpreter, body)
    write_file(path, program.encode("utf-8"), 0o755)


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


def candidate_receipt_drift_behavior(subject, base):
    """A rejected candidate is reported from live descriptor-bound bytes."""

    fixture = InstallFixture(subject, base, "native")
    payloads = {"pre-push": b"opaque generated hook bytes\n"}
    replacement = b"concurrent candidate replacement\n"
    state = {"fired": False}

    def replace_candidate_entry():
        if state["fired"]:
            return
        names = [
            name
            for name in os.listdir(fixture.git)
            if name.startswith(".odysseus-hooks-")
        ]
        if len(names) != 1:
            return
        target = os.path.join(fixture.git, names[0], "pre-push")
        if not os.path.isfile(target):
            return
        write_file(target, replacement, 0o755)
        state["fired"] = True

    error = None
    try:
        subject.install(
            fixture.repo,
            {"pre-push"},
            payloads,
            fixture.native,
            fixture.root,
            replace_candidate_entry,
        )
    except (OSError, subject.SetupError) as caught:
        error = caught

    names = [
        name
        for name in os.listdir(fixture.git)
        if name.startswith(".odysseus-hooks-")
    ]
    live_path = os.path.join(fixture.git, names[0]) if len(names) == 1 else None
    live_digest = None
    if live_path is not None:
        directory = subject.BoundDir.open(live_path, safe=True)
        try:
            live_digest = subject.manifest_digest(
                subject.content(subject.inventory(directory))
            )
        finally:
            directory.close()
    message = str(error) if error is not None else ""
    safe = (
        state["fired"]
        and error is not None
        and live_path is not None
        and live_path in message
        and live_digest is not None
        and "digest=sha256:{}".format(live_digest) in message
    )
    if not safe:
        print(
            "rejected candidate receipt did not describe live bytes: "
            "fired={},path={!r},digest={!r},error={!r}".format(
                state["fired"], live_path, live_digest, message
            )
        )
    fixture.close()
    return safe


def publication_commit_window_race_behavior(subject, base):
    """A forward exchange is committed even if a same-UID race changes its input."""

    failures = []
    for race in ("replacement", "mutation"):
        fixture = InstallFixture(subject, base, "native")
        payloads = {"pre-push": fixture.payload}
        malicious = (race + " commit-window bytes\n").encode("utf-8")
        original_rename = subject.atomic_rename
        fired = {"value": False}

        def racing_rename(parent_fd, source, destination, exchange=False):
            candidate_path = os.path.join(fixture.git, source)
            if race == "replacement":
                preserved = source + ".verified-object"
                os.rename(source, preserved, src_dir_fd=parent_fd, dst_dir_fd=parent_fd)
                os.mkdir(source, 0o755, dir_fd=parent_fd)
                write_file(os.path.join(candidate_path, "pre-push"), malicious, 0o755)
                write_file(
                    os.path.join(candidate_path, "pre-push.legacy"),
                    fixture.native_data,
                    0o755,
                )
            else:
                write_file(os.path.join(candidate_path, "pre-push"), malicious, 0o755)
            fired["value"] = True
            return original_rename(parent_fd, source, destination, exchange=exchange)

        subject.atomic_rename = racing_rename
        error = None
        try:
            subject.install(
                fixture.repo,
                {"pre-push"},
                payloads,
                fixture.native,
                fixture.root,
                lambda: None,
            )
        except (OSError, subject.SetupError) as caught:
            error = caught
        finally:
            subject.atomic_rename = original_rename
        active = route_snapshot(fixture.hooks_path)
        active_bytes = active[3].get("pre-push", (None, None, None))[2]
        active_content = {
            name: (item[2], item[1])
            for name, item in active[3].items()
            if item[2] is not None
        }
        active_digest = subject.manifest_digest(active_content)
        desired = {
            "pre-push": (fixture.payload, 0o755),
            "pre-push.legacy": (
                fixture.native_data,
                stat.S_IMODE(os.stat(fixture.native_path).st_mode),
            ),
        }
        expected_digest = subject.manifest_digest(desired)
        message = str(error) if error is not None else ""
        if not (
            fired["value"]
            and error is not None
            and active_bytes == malicious
            and "committed and was not rolled back" in message
            and "did not commit" not in message
            and "live-active" in message
            and "identity={}:{}".format(active[0], active[1]) in message
            and "digest=sha256:{}".format(active_digest) in message
            and "expected-candidate" in message
            and "digest=sha256:{}".format(expected_digest) in message
            and "expected-recovery" in message
            and "live-recovery" in message
        ):
            failures.append(
                "{}(fired={},active={!r},error={!r})".format(
                    race, fired["value"], active_bytes, message
                )
            )
        fixture.close()
    if failures:
        print("commit-window race was misclassified: {}".format(", ".join(failures)))
        return False
    return True


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
    for sig in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT):
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

    if hasattr(signal, "pthread_sigmask"):
        cancellation_signals = (
            signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT
        )
        for sig in cancellation_signals:
            inherited_handler = signal.getsignal(sig)
            inherited_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
            for mode in ("ignored", "blocked"):
                state = {"process": None, "cancelled": False}
                try:
                    signal.pthread_sigmask(signal.SIG_SETMASK, inherited_mask)
                    signal.signal(sig, inherited_handler)
                    if mode == "ignored":
                        signal.signal(sig, signal.SIG_IGN)
                    else:
                        signal.pthread_sigmask(signal.SIG_BLOCK, {sig})
                    expected_handler = signal.getsignal(sig)
                    expected_mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
                    original_popen = subject.subprocess.Popen

                    def signal_with_inherited_state(*args, **kwargs):
                        process = original_popen(*args, **kwargs)
                        state["process"] = process
                        os.kill(os.getpid(), sig)
                        return process

                    subject.subprocess.Popen = signal_with_inherited_state
                    try:
                        try:
                            subject.run(
                                [sys.executable, "-I", "-S", "-c", child_code],
                                base,
                                {},
                                10,
                            )
                        except subject.SetupError as error:
                            state["cancelled"] = (
                                signal.Signals(sig).name in str(error)
                            )
                    finally:
                        subject.subprocess.Popen = original_popen
                    restored = (
                        signal.getsignal(sig) == expected_handler
                        and set(signal.pthread_sigmask(signal.SIG_BLOCK, set()))
                        == set(expected_mask)
                    )
                    process = state["process"]
                    extinct = False
                    if process is not None:
                        try:
                            os.killpg(process.pid, 0)
                        except ProcessLookupError:
                            extinct = True
                    if not state["cancelled"] or not restored or not extinct:
                        broken.append(
                            "{}-{}(cancelled={},restored={},extinct={})".format(
                                signal.Signals(sig).name,
                                mode,
                                state["cancelled"],
                                restored,
                                extinct,
                            )
                        )
                finally:
                    signal.signal(sig, inherited_handler)
                    signal.pthread_sigmask(signal.SIG_SETMASK, inherited_mask)

        original_signal = subject.signal.signal
        original_popen = subject.subprocess.Popen
        installed = {"count": 0, "spawned": False}
        handlers = {
            signum: signal.getsignal(signum) for signum in cancellation_signals
        }
        mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())

        def fail_second_handler(signum, handler):
            if callable(handler):
                installed["count"] += 1
                if installed["count"] == 2:
                    raise ValueError("synthetic handler failure")
            return original_signal(signum, handler)

        def observe_spawn(*args, **kwargs):
            installed["spawned"] = True
            return original_popen(*args, **kwargs)

        subject.signal.signal = fail_second_handler
        subject.subprocess.Popen = observe_spawn
        failed_closed = False
        try:
            try:
                subject.run([sys.executable, "-c", "pass"], base, {}, 1)
            except subject.SetupError:
                failed_closed = True
        finally:
            subject.signal.signal = original_signal
            subject.subprocess.Popen = original_popen
        restored = (
            all(signal.getsignal(signum) == handlers[signum] for signum in handlers)
            and set(signal.pthread_sigmask(signal.SIG_BLOCK, set())) == set(mask)
        )
        if not failed_closed or installed["spawned"] or not restored:
            broken.append(
                "partial-handler-install(failed_closed={},spawned={},restored={})".format(
                    failed_closed, installed["spawned"], restored
                )
            )
    if broken:
        print(
            "spawn-window cancellation returned before teardown: {}".format(
                ", ".join(broken)
            )
        )
        return False
    return True


def parent_death_behavior(subject, base):
    """A child dies when its supervisor exits during preexec setup."""

    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: Linux parent-death contract is not observable here")
        return None
    ready_read, ready_write = os.pipe()
    gate_read, gate_write = os.pipe()
    original_setrlimit = subject.resource.setrlimit
    notified = {"value": False}

    def paused_setrlimit(key, value):
        if not notified["value"]:
            notified["value"] = True
            os.write(ready_write, str(os.getpid()).encode("ascii") + b"\n")
            if os.read(gate_read, 1) != b"x":
                os._exit(98)
        return original_setrlimit(key, value)

    subject.resource.setrlimit = paused_setrlimit
    supervisor = os.fork()
    if supervisor == 0:
        os.close(ready_read)
        os.close(gate_write)
        try:
            subprocess.Popen(
                [sys.executable, "-I", "-S", "-c", "import time; time.sleep(30)"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                close_fds=True,
                pass_fds=(ready_write, gate_read),
                start_new_session=True,
                preexec_fn=subject._child_resource_limits(30),
            )
        finally:
            os._exit(0)
    subject.resource.setrlimit = original_setrlimit
    os.close(ready_write)
    os.close(gate_read)
    try:
        ready, _, _ = select.select([ready_read], [], [], 5)
        raw = os.read(ready_read, 64) if ready else b""
    finally:
        os.close(ready_read)
    if not raw:
        os.close(gate_write)
        os.kill(supervisor, signal.SIGKILL)
        os.waitpid(supervisor, 0)
        print("supervisor did not report its pre-boundary child")
        return False
    child = int(raw.strip().decode("ascii"))
    os.kill(supervisor, signal.SIGKILL)
    os.waitpid(supervisor, 0)
    os.write(gate_write, b"x")
    os.close(gate_write)
    deadline = time.monotonic() + 3
    extinct = False
    while time.monotonic() < deadline:
        try:
            with open("/proc/{}/stat".format(child), "rb") as stream:
                state = stream.read().split()[2]
            if state == b"Z":
                extinct = True
                break
            os.kill(child, 0)
        except (FileNotFoundError, ProcessLookupError):
            extinct = True
            break
        time.sleep(0.02)
    if not extinct:
        try:
            os.killpg(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
        print("pre-bubblewrap child survived its supervisor")
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
    pre_commit = os.path.join(base, "install-bin", "pre-commit-fixture")
    git_tool = os.path.join(root, "terminal-git")
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
    subject.configs_under = lambda _root, _deadline=None: [root_config, child_config]
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
    del base, git
    prefix = b"repos: []\n"
    source = prefix + b"default_install_hook_types: [pre-commit, pre-push]\n"
    original_write = subject.os.write
    state = {"fired": False}

    def short_write(descriptor, data):
        if not state["fired"] and bytes(data) == source:
            state["fired"] = True
            return original_write(descriptor, data[: len(prefix)])
        return original_write(descriptor, data)

    subject.os.write = short_write
    snapshot = None
    rejected = False
    try:
        try:
            snapshot = subject.BoundTool.sealed_bytes(
                os.path.join(
                    subject.SCRATCH_REPO, ".pre-commit-config.yaml"
                ),
                source,
                executable=False,
            )
        except (OSError, subject.SetupError):
            rejected = True
    finally:
        subject.os.write = original_write
    exact = False
    if snapshot is not None:
        try:
            snapshot.verify()
            exact = os.pread(snapshot.descriptor, len(source) + 1, 0) == source
        finally:
            snapshot.close()
    safe = (
        sys.platform.startswith("linux")
        and state["fired"]
        and exact
        and not rejected
    ) or (not sys.platform.startswith("linux") and rejected)
    if not safe:
        print(
            "a short write changed the sealed configuration snapshot: "
            "fired={}, rejected={}, exact={}".format(
                state["fired"], rejected, exact
            )
        )
        return False
    return True


def single_generation_transaction_behavior(subject):
    """Discovery and optional environment install share one namespace run."""

    class FakeConfig:
        data = b"repos: []\n"

        def __init__(self):
            self.verifications = 0

        def verify(self):
            self.verifications += 1

    class FakeInput:
        def __init__(self, path, data, executable):
            self.path = path
            self.data = data
            self.executable = executable
            self.closed = 0

        def close(self):
            self.closed += 1

    class FakeExecution:
        def __init__(self, path):
            self.path = path

    class FakeCommand:
        def __init__(self, path):
            self.execution = FakeExecution(path)
            self.interpreter_source = None

    config = FakeConfig()
    repo = type("FakeRepo", (), {"config": config, "path": "/runtime/repo"})()
    policy = FakeConfig()
    driver = "/runtime/generate-hooks"
    pre_commit = FakeCommand("/runtime/pre-commit")
    git = FakeCommand("/runtime/git")
    created = []
    calls = []
    archive_calls = []
    obsolete_calls = []

    original_sealed = subject.BoundTool.__dict__["sealed_bytes"]
    original_run = subject.run
    original_archive = subject._generated_archive
    original_runtime = subject._hook_runtime
    had_shadow = hasattr(subject, "shadow_repo")
    had_inventory = hasattr(subject, "generated_inventory")
    original_shadow = getattr(subject, "shadow_repo", None)
    original_inventory = getattr(subject, "generated_inventory", None)

    def fake_sealed(_cls, path, data, executable=True):
        item = FakeInput(path, data, executable)
        created.append(item)
        return item

    def fake_run(
        argv, cwd, env, timeout, readonly_paths=(), input_files=()
    ):
        calls.append(
            (
                tuple(argv), cwd, dict(env), timeout,
                tuple(readonly_paths), tuple(input_files),
            )
        )
        return (0, b"archive", b"")

    def fake_archive(data, install_python):
        archive_calls.append((data, install_python))
        return {"pre-push": b"canonical hook\n"}

    def fake_runtime(_pre_commit, _git, _repo, _policy):
        return {
            "source": "/runtime/pre-commit",
            "source_digest": "a" * 64,
            "interpreter": "/usr/bin/python3",
            "interpreter_digest": "b" * 64,
            "boundary": "/usr/bin/bwrap",
            "boundary_digest": "c" * 64,
            "repository": "/runtime/repository",
            "git_directory": "/runtime/repository/.git",
            "git_common": "/runtime/repository/.git",
            "home": "/runtime/home",
        }

    def obsolete(*_args, **_kwargs):
        obsolete_calls.append(True)
        raise AssertionError("obsolete host generation helper was reached")

    error = None
    results = []
    subject.BoundTool.sealed_bytes = classmethod(fake_sealed)
    subject.run = fake_run
    subject._generated_archive = fake_archive
    subject._hook_runtime = fake_runtime
    subject.shadow_repo = obsolete
    subject.generated_inventory = obsolete
    try:
        try:
            for install in (False, True):
                results.append(
                    subject.generate(
                        repo,
                        driver,
                        pre_commit,
                        git,
                        {"LANG": "C"},
                        7,
                        install,
                        policy,
                    )
                )
        except BaseException as caught:
            error = caught
    finally:
        subject.BoundTool.sealed_bytes = original_sealed
        subject.run = original_run
        subject._generated_archive = original_archive
        subject._hook_runtime = original_runtime
        if had_shadow:
            subject.shadow_repo = original_shadow
        else:
            del subject.shadow_repo
        if had_inventory:
            subject.generated_inventory = original_inventory
        else:
            del subject.generated_inventory

    expected_modes = ("check", "install")
    calls_exact = len(calls) == 2 and all(
        call[0] == (
            driver,
            pre_commit.execution.path,
            pre_commit.execution.path,
            git.execution.path,
            git.execution.path,
            mode,
        )
        and call[1] == "/"
        and call[2] == {"LANG": "C"}
        and call[3] == 7
        and call[4] == ()
        and len(call[5]) == 1
        and call[5][0] is created[index]
        for index, (call, mode) in enumerate(zip(calls, expected_modes))
    )
    inputs_exact = len(created) == 2 and all(
        item.path
        == os.path.join(subject.SCRATCH_REPO, ".pre-commit-config.yaml")
        and item.data == config.data
        and item.executable is False
        and item.closed == 1
        for item in created
    )
    results_exact = results == [
        ({"pre-push"}, {"pre-push": b"canonical hook\n"}),
        ({"pre-push"}, {"pre-push": b"canonical hook\n"}),
    ]
    safe = (
        error is None
        and calls_exact
        and inputs_exact
        and results_exact
        and config.verifications == 4
        and archive_calls
        == [
                (
                    b"archive",
                    fake_runtime(
                        pre_commit,
                        git,
                        repo,
                        policy,
                    ),
                ),
            (
                b"archive",
                fake_runtime(
                    pre_commit,
                    git,
                    repo,
                    policy,
                ),
            ),
        ]
        and not obsolete_calls
    )
    if not safe:
        print(
            "generation escaped its one namespace transaction: "
            "error={!r},calls={!r},inputs={!r},results={!r},verifications={},"
            "archives={!r},obsolete={!r}".format(
                error,
                calls,
                [
                    (item.path, item.data, item.executable, item.closed)
                    for item in created
                ],
                results,
                config.verifications,
                archive_calls,
                obsolete_calls,
            )
        )
    return safe


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
    original_mkdir = subject.os.mkdir
    original_open = subject.os.open
    if sys.platform.startswith("linux"):
        original_fsync = subject.os.fsync
        before_fds = descriptor_numbers()
        state = {"fired": False}

        def sealed_fsync_fault(_descriptor):
            state["fired"] = True
            raise OSError(errno.EIO, "injected sealed-input fsync failure")

        subject.os.fsync = sealed_fsync_fault
        error = None
        try:
            try:
                subject.BoundTool.sealed_bytes(
                    os.path.join(subject.SCRATCH_REPO, "input"),
                    b"sealed input\n",
                    executable=False,
                )
            except (OSError, subject.SetupError) as caught:
                error = caught
        finally:
            subject.os.fsync = original_fsync
        after_fds = descriptor_numbers()
        if not state["fired"] or error is None or after_fds != before_fds:
            broken.append(
                "sealed-input(fired={},error={},fds={})".format(
                    state["fired"], error, sorted(after_fds - before_fds)
                )
            )

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

    def controlled_git_value(
        _git, repo, args, _env, _timeout, readonly_paths=()
    ):
        del readonly_paths
        if args == ["rev-parse", "--show-toplevel"]:
            return repo
        if args == ["rev-parse", "--absolute-git-dir"]:
            return os.path.join(repo, ".git")
        if args == ["rev-parse", "--git-common-dir"]:
            return os.path.join(repo, ".git")
        raise AssertionError(args)

    def controlled_run(argv, _cwd, _env, _timeout, readonly_paths=()):
        del readonly_paths
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


def tool_swap_behavior(subject, base, git):
    del git
    broken = []
    exercised = 0
    for swap_target in ("pre-commit", "git"):
        source_root = tempfile.mkdtemp(
            prefix="{}-swap-".format(swap_target), dir=base
        )
        tool = os.path.join(source_root, swap_target)
        replacement = os.path.join(source_root, swap_target + "-replacement")
        original = (
            "#!/bin/sh\nprintf 'original-{}\\n'\n".format(swap_target)
        ).encode("utf-8")
        replacement_data = (
            "#!/bin/sh\nprintf 'replacement-{}\\n'\n".format(swap_target)
        ).encode("utf-8")
        write_file(tool, original, 0o755)
        write_file(replacement, replacement_data, 0o755)
        bound_tools = []
        boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
        descriptors_before = descriptor_count()
        unavailable = False
        source_rejected = False
        snapshot_exact = False
        source = None
        try:
            try:
                boundary.require()
            except subject.SetupError as error:
                unavailable = "secure execution boundary" in str(error)
            if not unavailable:
                source = subject.BoundTool.open(tool)
                bound_tools.append(source)
                bound = subject.bind_executable(
                    source,
                    boundary.tree,
                    "shell-fixture-" + swap_target,
                    bound_tools,
                    boundary,
                )
                os.replace(replacement, tool)
                try:
                    source.verify()
                except subject.SetupError:
                    source_rejected = True
                bound.execution.verify()
                snapshot_exact = (
                    os.pread(bound.execution.descriptor, len(original) + 1, 0)
                    == original
                    and bound.execution.path != tool
                )
        finally:
            for item in reversed(bound_tools):
                item.close()
        descriptor_delta = descriptor_count() - descriptors_before
        shutil.rmtree(source_root, ignore_errors=True)
        if unavailable:
            if sys.platform.startswith("linux"):
                broken.append("{}(boundary-unavailable)".format(swap_target))
            continue
        exercised += 1
        if not source_rejected or not snapshot_exact or descriptor_delta:
            broken.append(
                "{}(source_rejected={},snapshot_exact={},fds={})".format(
                    swap_target,
                    source_rejected,
                    snapshot_exact,
                    descriptor_delta,
                )
            )
    if broken:
        print(
            "verified executable route selected different bytes: {}".format(
                ", ".join(broken)
            )
        )
        return False
    if not exercised:
        print("NON_PROOF_SKIP: immutable tool routing requires Linux containment")
        return None
    return True


def immutable_snapshot_behavior(subject, base):
    """A same-UID writer cannot alter verified execution bytes in place."""

    source_root = tempfile.mkdtemp(prefix="immutable-snapshot-source-", dir=base)
    source_path = os.path.join(source_root, "tool")
    original = b"#!/bin/sh\nprintf original\\n\n"
    replacement = b"#!/bin/sh\nprintf replacement\n"
    write_file(source_path, original, 0o755)
    tree = subject.NamespaceTree(subject.RUNTIME_ROOT)
    source = None
    snapshot = None
    rejected = False
    attacks = []
    immutable = False
    try:
        source = subject.BoundTool.open(source_path)
        try:
            snapshot = source.snapshot(tree, "tool")
        except subject.SetupError:
            rejected = True
        if snapshot is not None:
            for label, mutate in (
                ("write", lambda: os.write(snapshot.descriptor, replacement)),
                (
                    "pwrite",
                    lambda: os.pwrite(snapshot.descriptor, replacement, 0),
                ),
                ("truncate", lambda: os.ftruncate(snapshot.descriptor, 0)),
            ):
                try:
                    mutate()
                except OSError:
                    attacks.append((label, False))
                else:
                    attacks.append((label, True))
            try:
                snapshot.verify()
            except subject.SetupError:
                immutable = False
            else:
                immutable = (
                    os.pread(snapshot.descriptor, len(original) + 1, 0)
                    == original
                )
    finally:
        if snapshot is not None:
            snapshot.close()
        if source is not None:
            source.close()
        shutil.rmtree(source_root, ignore_errors=True)
    safe = (
        sys.platform.startswith("linux")
        and immutable
        and len(attacks) == 3
        and not any(succeeded for _label, succeeded in attacks)
    ) or (not sys.platform.startswith("linux") and rejected)
    if not safe:
        print(
            "same-UID mutation reached a verified execution snapshot: "
            "platform={!r},rejected={},attacks={!r},immutable={}".format(
                sys.platform, rejected, attacks, immutable
            )
        )
        return False
    return True


def trusted_route_snapshot_behavior(subject, base):
    """Even an immutable system route executes from exact sealed bytes."""

    source_path = os.path.join(base, "trusted-route-tool")
    original = b"#!/bin/sh\nprintf trusted-route\\n\n"
    write_file(source_path, original, 0o755)
    source = subject.BoundTool.open(source_path)
    execution = None
    bound_tools = [source]
    boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
    source.trusted_system_route = lambda: True
    unavailable = False
    try:
        try:
            boundary.require()
            execution, dependencies = subject.execution_tool(
                source,
                boundary.tree,
                "trusted-route-tool",
                bound_tools,
                boundary,
            )
        except subject.SetupError as error:
            unavailable = "secure execution boundary" in str(error)
        if unavailable:
            if sys.platform.startswith("linux"):
                print("authoritative Linux boundary is unavailable")
                return False
            print("NON_PROOF_SKIP: trusted-route snapshot requires Linux containment")
            return None
        safe = (
            execution is not source
            and execution.sealed
            and not dependencies
            and execution.path != source.path
            and os.pread(execution.descriptor, len(original) + 1, 0) == original
        )
        if not safe:
            print(
                "trusted route remained pathname-authoritative: "
                "same={},sealed={},path={!r}".format(
                    execution is source,
                    getattr(execution, "sealed", False),
                    getattr(execution, "path", None),
                )
            )
            return False
        return True
    finally:
        for item in reversed(bound_tools):
            item.close()


def interpreter_swap_behavior(subject, base, git):
    del git
    root = tempfile.mkdtemp(prefix="interpreter-swap-", dir=base)
    interpreter = os.path.join(root, "python")
    replacement = os.path.join(root, "python-replacement")
    os.symlink(os.path.realpath("/usr/bin/python3"), interpreter)
    os.symlink("/bin/sh", replacement)
    tool = os.path.join(root, "pre-commit")
    write_file(
        tool,
        (
            "#!{}\n"
            "''':'\n"
            "printf 'replacement-interpreter\\n' >&2\n"
            "printf 'pre-commit 3.8.0\\n'\n"
            "exit 0\n"
            "':'''\n"
            "import sys\n"
            "sys.stderr.write('original-interpreter\\n')\n"
            "print('pre-commit 3.8.0')\n"
        ).format(interpreter).encode("utf-8"),
        0o755,
    )

    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
    original_popen = subject.subprocess.Popen
    state = {"swapped": False}
    result = None
    unavailable = False

    def swap_at_spawn(*args, **kwargs):
        if not state["swapped"]:
            os.replace(replacement, interpreter)
            state["swapped"] = True
        return original_popen(*args, **kwargs)

    try:
        try:
            boundary.require()
            source = subject.BoundTool.open(tool)
            bound_tools.append(source)
            bound = subject.bind_executable(
                source,
                boundary.tree,
                "interpreter-swap-fixture",
                bound_tools,
                boundary,
            )
        except subject.SetupError as error:
            unavailable = any(
                marker in str(error)
                for marker in (
                    "secure execution boundary",
                    "mutable interpreter/runtime closure",
                )
            )
            if not unavailable:
                raise
        if not unavailable:
            subject.subprocess.Popen = swap_at_spawn
            result = subject.run(
                [bound],
                "/",
                {"PATH": "/usr/bin:/bin", "LANG": "C", "LC_ALL": "C"},
                2,
            )
    finally:
        subject.subprocess.Popen = original_popen
        for item in reversed(bound_tools):
            item.close()
        shutil.rmtree(root, ignore_errors=True)
    if unavailable:
        if sys.platform.startswith("linux"):
            print("authoritative Linux boundary is unavailable")
            return False
        print("NON_PROOF_SKIP: interpreter swap requires Linux containment")
        return None
    safe = (
        state["swapped"]
        and result is not None
        and result[0] == 0
        and result[1] == b"pre-commit 3.8.0\n"
        and b"original-interpreter\n" in result[2]
        and b"replacement-interpreter" not in result[2]
    )
    if not safe:
        print(
            "verified shebang selected different interpreter bytes: "
            "swapped={}, result={!r}".format(state["swapped"], result)
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
            "printf '{}\\n' >&2\n"
            "if /bin/chmod u+w \"$0\" 2>/dev/null; then\n"
            "  printf '{}\\n' >&2\n"
            "  exit 91\n"
            "fi\n"
            "printf '{}\\n' >&2\n"
            "printf 'pre-commit 3.8.0\\n'\n"
        ).format(
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
                "printf '{}\\n' >&2\n"
                "printf 'git version original\\n'\n"
            ).format(original_marker).encode("utf-8"),
            0o755,
        )
        tool_body = (
            "#!/bin/sh\n"
            "set -eu\n"
            "git_path=$(command -v git)\n"
            "printf '{}\\n' >&2\n"
            "if /bin/chmod u+w \"$git_path\" 2>/dev/null; then\n"
            "  printf '{}\\n' >&2\n"
            "  exit 91\n"
            "fi\n"
            "git --version >/dev/null\n"
            "printf '{}\\n' >&2\n"
            "printf 'pre-commit 3.8.0\\n'\n"
        ).format(attempted_marker, replacement_marker, original_marker)
    else:
        raise AssertionError(target)
    write_provider_shell_fixture(tool, tool_body, base)

    emitted = []
    captured = []
    original_emit = subject.emit
    original_run = subject.run
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )

    def capture_run(*args, **kwargs):
        result = original_run(*args, **kwargs)
        captured.append(result)
        return result

    subject.run = capture_run
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
        subject.run = original_run
    output = b"".join(result[1] + result[2] for result in captured)
    attempted = attempted_marker.encode("utf-8") in output
    original_ran = original_marker.encode("utf-8") in output
    replacement_ran = replacement_marker.encode("utf-8") in output
    descriptor_delta = descriptor_count() - descriptors_before
    shutil.rmtree(root, ignore_errors=True)
    enforced = attempted and original_ran and not replacement_ran
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
    if unavailable:
        if sys.platform.startswith("linux"):
            print("authoritative Linux boundary is unavailable")
            return False
        print("NON_PROOF_SKIP: execution-copy writes require Linux containment")
        return None
    if not enforced or descriptor_delta:
        print(
            "{} copy was writable during child execution: ".format(target) +
            "status={}, attempted={}, original={}, replacement={}, fds={}, "
            "messages={!r}, output={!r}".format(
                status, attempted, original_ran, replacement_ran,
                descriptor_delta, emitted, output,
            )
        )
        return False
    return True


def boundary_policy_behavior(subject):
    """Require a read-only host plus namespace-owned scratch only."""

    class FakeGuard:
        path = "/usr/bin/bwrap"
        descriptor = 43

        def verify(self):
            return None

        def trusted_system_route(self):
            return True

        def close(self):
            return None

    class FakeSealedFile:
        path = os.path.join(subject.RUNTIME_ROOT, "tool")
        descriptor = 37
        token = (0, 0, 0o100500)

        def verify(self):
            return None

    class FakeBoundDir(subject.BoundDir):
        def __init__(self):
            self.path = "/host-repository"
            self.descriptor = 41
            self.token = (0, 0, 0, 0, 0)
            self.parent_fd = None
            self.name = None

        def verify(self):
            return None

    boundary = subject.ReadOnlyExecutionBoundary([])
    boundary.guard = FakeGuard()
    boundary.kind = "bubblewrap"
    original_lseek = subject.os.lseek
    subject.os.lseek = lambda *_args: 0
    try:
        command, executable = boundary.wrap(
            [FakeSealedFile.path, "arg"],
            readonly_paths=(FakeBoundDir(),),
            sealed_files=(FakeSealedFile(),),
        )
    finally:
        subject.os.lseek = original_lseek

    def has_sequence(values):
        width = len(values)
        return any(
            command[index:index + width] == list(values)
            for index in range(len(command) - width + 1)
        )

    linux_safe = (
        executable == "/proc/self/fd/43"
        and not has_sequence(("--ro-bind", "/", "/"))
        and not has_sequence(("--bind", "/", "/"))
        and has_sequence(("--ro-bind", "/usr", "/usr"))
        and "--bind-fd" not in command
        and has_sequence(("--ro-bind-fd", "41", "/host-repository"))
        and not has_sequence(
            ("--ro-bind", "/proc/self/fd/41", "/host-repository")
        )
        and has_sequence(
            (
                "--perms", "0500", "--ro-bind-data", "37",
                FakeSealedFile.path,
            )
        )
        and has_sequence(("--tmpfs", "/tmp"))
        and command.count("--tmpfs") == 1
        and all(
            has_sequence(("--dir", path))
            for path in (
                subject.SCRATCH_ROOT,
                subject.SCRATCH_HOME,
                subject.SCRATCH_CACHE,
                subject.SCRATCH_REPO,
            )
        )
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
    darwin = subject.ReadOnlyExecutionBoundary([])
    try:
        try:
            darwin.require()
        except subject.SetupError:
            darwin_failed_closed = True
    finally:
        subject.BoundTool.open = original_open
        subject.sys.platform = original_platform

    unavailable = subject.ReadOnlyExecutionBoundary([])
    attempted = []

    def unavailable_guard(_cls, path):
        attempted.append(path)
        raise subject.SetupError("missing")

    linux_failed_closed = False
    subject.sys.platform = "linux"
    subject.BoundTool.open = classmethod(unavailable_guard)
    try:
        try:
            unavailable.require()
        except subject.SetupError:
            linux_failed_closed = True
    finally:
        subject.BoundTool.open = original_open
        subject.sys.platform = original_platform

    if (
        not linux_safe
        or not linux_failed_closed
        or any(path.endswith("/unshare") for path in attempted)
        or not darwin_failed_closed
        or darwin_opened["value"]
    ):
        print(
            "execution policy did not bind a read-only host and PID namespace: "
            "linux_safe={}, linux_failed_closed={}, attempted={!r}, "
            "darwin_failed_closed={}, darwin_opened={}, command={!r}".format(
                linux_safe, linux_failed_closed, attempted,
                darwin_failed_closed, darwin_opened["value"], command,
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
    write_provider_shell_fixture(
        pre_commit,
        (
            "#!/bin/sh\n"
            "if /bin/chmod u+w {!r} 2>/dev/null; then\n"
            "  printf corrupted > {!r}\n"
            "fi\n"
            "printf 'pre-commit 3.8.0\\n'\n"
        ).format(dependency, dependency),
        base,
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
    if unavailable:
        if sys.platform.startswith("linux"):
            print("authoritative Linux boundary is unavailable")
            shutil.rmtree(root, ignore_errors=True)
            return False
        print("NON_PROOF_SKIP: runtime-host writes require Linux containment")
        shutil.rmtree(root, ignore_errors=True)
        return None
    if not safe or status != 0:
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
            "printf '%s' \"$VALUE\"\n"
        ).encode("utf-8"),
        0o755,
    )
    write_file(dependency, b"VALUE=original\n")
    write_file(replacement, b"VALUE=replacement\n")
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
    unavailable = False
    rejected = False
    fired = False
    selected = None
    executed_original = False
    failed_closed = False
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
                boundary.tree,
                "shell-sibling-fixture",
                bound_tools,
                boundary,
            )
            dependency_pair = next(
                (
                    (source_item, execution_item)
                    for source_item, execution_item in bound.dependencies
                    if source_item.path == dependency
                ),
                None,
            )
            if dependency_pair is not None:
                source_dependency, execution_dependency = dependency_pair
                os.replace(replacement, dependency)
                fired = True
                try:
                    result = subject.run(
                        [bound],
                        "/",
                        {
                            "GIT_CONFIG_GLOBAL": "/dev/null",
                            "GIT_CONFIG_NOSYSTEM": "1",
                            "HOME": base,
                            "LANG": "C",
                            "LC_ALL": "C",
                            "PATH": "/usr/bin:/bin",
                        },
                        subject.OperationDeadline(5),
                    )
                except subject.SetupError as error:
                    failed_closed = (
                        source_dependency.path in str(error)
                        and "changed after binding" in str(error)
                    )
                else:
                    executed_original = (
                        result[0] == 0 and result[1] == b"original"
                    )
                execution_dependency.verify()
                selected = os.pread(
                    execution_dependency.descriptor,
                    len(b"VALUE=original\n") + 1,
                    0,
                )
    finally:
        for tool in reversed(bound_tools):
            tool.close()
        shutil.rmtree(source_root, ignore_errors=True)
    if unavailable:
        if sys.platform.startswith("linux"):
            print("authoritative Linux boundary is unavailable")
            return False
        print("NON_PROOF_SKIP: runtime-sibling swaps require Linux containment")
        return None
    rejected = failed_closed or executed_original
    if not fired or not rejected or selected != b"VALUE=original\n":
        print(
            "an imported sibling swap selected mutable bytes: "
            "fired={},failed_closed={},executed_original={},selected={!r}".format(
                fired, failed_closed, executed_original, selected
            )
        )
        return False
    return True


def untrusted_interpreter_behavior(subject, base):
    """A Pixi-style provider is accepted only through its sealed import closure."""

    for version, allowed in (("1.4.5.0", True), ("1.4.5.9", True), ("1.4.6", False), ("1.4.9", False)):
        if subject._provider_version_allows(version, (("~=", "1.4.5.0"),)) != allowed:
            print("incorrect compatible-release dependency result: " + version)
            return False
        environment = {"_version": tuple(int(part) for part in version.split("."))}
        if subject._requires_python_allows("~=1.4.5.0", environment) != allowed:
            print("incorrect compatible-release Python result: " + version)
            return False
    try:
        subject._provider_version_allows("١.٠", (("==", "1.0"),))
    except subject.SetupError:
        pass
    else:
        print("provider metadata accepted a non-ASCII release")
        return False

    source_root = tempfile.mkdtemp(prefix="pixi-provider-", dir=base)
    prefix = os.path.join(source_root, "prefix")
    os.makedirs(os.path.join(prefix, "bin"))
    runtime_version = (sys.version_info.major, sys.version_info.minor)
    route_minor = runtime_version[1] - 1 if runtime_version[1] else 1
    route_version = (runtime_version[0], route_minor)
    interpreter = os.path.join(
        prefix, "bin", "python{}.{}".format(*route_version)
    )
    shutil.copyfile(sys.executable, interpreter)
    os.chmod(interpreter, 0o755)
    script = os.path.join(prefix, "bin", "pre-commit")
    write_file(
        script,
        ("#!{}\nfrom pre_commit import VALUE\nprint(VALUE)\n".format(interpreter)).encode("utf-8"),
        0o755,
    )
    site = os.path.join(
        prefix,
        "lib",
        "python{}.{}".format(*route_version),
        "site-packages",
    )
    os.makedirs(site)

    def distribution(
        name,
        package,
        metadata_name,
        requires=(),
        requires_python=None,
        native_payload=False,
        version="1.0",
    ):
        package_root = os.path.join(site, package)
        os.mkdir(package_root)
        package_file = os.path.join(package_root, "__init__.py")
        write_file(package_file, b"VALUE = 'sealed-provider'\n")
        info = os.path.join(site, name + "-1.0.dist-info")
        os.mkdir(info)
        metadata = "Name: {}\nVersion: {}\n".format(metadata_name, version)
        if requires_python is not None:
            metadata += "Requires-Python: {}\n".format(requires_python)
        metadata += "".join("Requires-Dist: {}\n".format(item) for item in requires)
        metadata_path = os.path.join(info, "METADATA")
        write_file(metadata_path, metadata.encode("utf-8"))
        record_path = os.path.join(info, "RECORD")
        rows = (
            "{}/__init__.py,,\n{}/METADATA,,\n{}/RECORD,,\n".format(
                package, os.path.basename(info), os.path.basename(info)
            )
        )
        native_path = None
        if native_payload:
            native_path = os.path.join(package_root, "_native.abi.so")
            write_file(native_path, b"untrusted-native-extension\n")
            rows += "{}/_native.abi.so,,\n".format(package)
        write_file(record_path, rows.encode("utf-8"))
        result = {
            os.path.realpath(package_file),
            os.path.realpath(metadata_path),
            os.path.realpath(record_path),
        }
        return result, native_path

    expected = set()
    runtime_marker = "{}.{}".format(*runtime_version)
    runtime_spec = ">={}.{},<{}.0".format(
        runtime_version[0], runtime_version[1], runtime_version[0] + 1
    )
    entries, _unused = distribution(
        "pre_commit",
        "pre_commit",
        "pre-commit",
        (
            "cfgv>=1.0,<2",
            "runtime-dep ; python_version == '{}'".format(runtime_marker),
        ),
        runtime_spec,
    )
    expected.update(entries)
    entries, _unused = distribution(
        "cfgv",
        "cfgv",
        "cfgv",
        requires=("extra-dep ; extra == 'feature'",),
        requires_python=runtime_spec,
    )
    expected.update(entries)
    entries, native_path = distribution(
        "PyYAML",
        "yaml",
        "PyYAML",
        requires_python=runtime_spec,
        native_payload=True,
    )
    expected.update(entries)
    entries, _unused = distribution(
        "runtime_dep", "runtime_dep", "runtime-dep", requires_python=runtime_spec
    )
    expected.update(entries)
    extra_entries, _unused = distribution(
        "extra_dep", "extra_dep", "extra-dep", requires_python=runtime_spec
    )
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
    bound = None
    before = descriptor_count()
    try:
        discovered_root, discovered = subject._provider_distribution_closure(
            interpreter
        )
        if discovered_root != os.path.realpath(site) or set(discovered) != expected:
            print("provider distribution closure was incomplete: {!r}".format(discovered))
            return False
        if native_path in discovered:
            print("provider distribution closure admitted a native extension")
            return False
        incompatible_metadata = os.path.join(site, "cfgv-1.0.dist-info", "METADATA")
        with open(incompatible_metadata, "rb") as stream:
            compatible_metadata = stream.read()
        write_file(
            incompatible_metadata,
            compatible_metadata.replace(
                ("Requires-Python: {}".format(runtime_spec)).encode("utf-8"),
                b"Requires-Python: >=99",
            ),
        )
        incompatible_rejected = False
        try:
            subject._provider_distribution_closure(interpreter)
        except subject.SetupError:
            incompatible_rejected = True
        write_file(incompatible_metadata, compatible_metadata)
        if not incompatible_rejected:
            print("provider closure accepted an incompatible execution runtime")
            return False

        pre_commit_metadata = os.path.join(
            site, "pre_commit-1.0.dist-info", "METADATA"
        )
        cfgv_metadata = os.path.join(site, "cfgv-1.0.dist-info", "METADATA")
        with open(pre_commit_metadata, "rb") as stream:
            compatible_pre_commit = stream.read()
        with open(cfgv_metadata, "rb") as stream:
            compatible_cfgv = stream.read()

        folded_metadata = compatible_pre_commit.replace(
            b"Requires-Dist: cfgv>=1.0,<2",
            b"Requires-Dist: cfgv\n >=1.0,<2",
        )
        folded_metadata = (
            b"Description: compatible provider\n continued description\n"
            + folded_metadata
        )
        write_file(pre_commit_metadata, folded_metadata)
        try:
            subject._provider_distribution_closure(interpreter)
        except subject.SetupError as error:
            print("valid folded provider metadata was rejected: {}".format(error))
            return False
        write_file(pre_commit_metadata, compatible_pre_commit)

        requirement_cases = (
            (
                b"Requires-Dist: cfgv>=1.0,<2",
                b"Requires-Dist: cfgv>=2",
                "an unsatisfied dependency version",
            ),
            (
                b"Requires-Dist: cfgv>=1.0,<2",
                b"Requires-Dist: cfgv @ https://example.invalid/cfgv.whl",
                "a direct-reference dependency",
            ),
            (
                b"Requires-Dist: cfgv>=1.0,<2",
                b"Requires-Dist: cfgv\n @ https://example.invalid/cfgv.whl",
                "a folded direct-reference dependency",
            ),
            (
                b"Requires-Dist: cfgv>=1.0,<2",
                b"Requires-Dist: cfgv >= 1.0 trailing-garbage",
                "trailing PEP 508 syntax",
            ),
        )
        for original, replacement, label in requirement_cases:
            write_file(
                pre_commit_metadata,
                compatible_pre_commit.replace(original, replacement),
            )
            rejected = False
            try:
                subject._provider_distribution_closure(interpreter)
            except subject.SetupError:
                rejected = True
            if not rejected:
                print("provider closure accepted {}".format(label))
                return False
        write_file(pre_commit_metadata, compatible_pre_commit)

        write_file(
            pre_commit_metadata,
            compatible_pre_commit.replace(
                b"Requires-Dist: cfgv>=1.0,<2",
                b"Requires-Dist: cfgv[feature]>=1.0,<2",
            ),
        )
        _extra_root, extra_closure = subject._provider_distribution_closure(interpreter)
        if not extra_entries.issubset(set(extra_closure)):
            print("provider extras did not extend the selected dependency closure")
            return False
        write_file(pre_commit_metadata, compatible_pre_commit)

        version_cases = (
            (
                compatible_cfgv.replace(b"Version: 1.0", b"Version: 0.9"),
                "a dependency version outside its selected constraint",
            ),
            (
                compatible_cfgv.replace(b"Version: 1.0\n", b""),
                "missing selected Version metadata",
            ),
            (
                compatible_cfgv.replace(
                    b"Version: 1.0\n", b"Version: 1.0\nVersion: 1.0\n"
                ),
                "duplicate selected Version metadata",
            ),
        )
        for metadata_payload, label in version_cases:
            write_file(cfgv_metadata, metadata_payload)
            rejected = False
            try:
                subject._provider_distribution_closure(interpreter)
            except subject.SetupError:
                rejected = True
            if not rejected:
                print("provider closure accepted {}".format(label))
                return False
        write_file(cfgv_metadata, compatible_cfgv)
        closure_tools = []
        original_sealed_descriptor = subject.BoundTool.__dict__["sealed_bytes"]

        class LocalSealed:
            def __init__(self, path, data, executable):
                self.path = path
                self.data = data
                self.executable = executable
                self.descriptor = os.open(os.devnull, os.O_RDONLY)

            def verify(self):
                os.fstat(self.descriptor)

            def close(self):
                if self.descriptor >= 0:
                    os.close(self.descriptor)
                    self.descriptor = -1

        def local_sealed(_cls, path, data, executable=True):
            return LocalSealed(path, data, executable)

        class LocalBoundary:
            def require(self):
                return None

        subject.BoundTool.sealed_bytes = classmethod(local_sealed)
        closure_dependencies = ()
        closure_before = descriptor_count()
        try:
            closure_dependencies, _roots = subject._snapshot_provider_import_closure(
                interpreter,
                closure_tools,
                LocalBoundary(),
            )
            registered = all(
                execution_item in closure_tools
                for _source_item, execution_item in closure_dependencies
            )
        finally:
            subject.BoundTool.sealed_bytes = original_sealed_descriptor
            for item in reversed(closure_tools):
                item.close()
            for _source_item, execution_item in closure_dependencies:
                if execution_item not in closure_tools:
                    execution_item.close()
        if not registered or descriptor_count() != closure_before:
            print(
                "provider closure descriptors were not registered in one ownership stack"
            )
            return False
        if not sys.platform.startswith("linux"):
            print("NON_PROOF_SKIP: sealed Pixi provider execution requires Linux")
            return None
        try:
            boundary.require()
        except subject.SetupError as error:
            print("authoritative Linux containment provider is unavailable: {}".format(error))
            return False
        source = subject.BoundTool.open(script)
        bound_tools.append(source)
        bound = subject.bind_executable(
            source,
            boundary.tree,
            "pre-commit",
            bound_tools,
            boundary,
        )
        sealed_paths = {
            source_item.path for source_item, _execution in bound.dependencies
        }
        if bound.python_paths != (site,) or not expected.issubset(sealed_paths):
            print("Pixi provider did not retain its complete sealed closure")
            return False
        runtime_env = {
            "HOME": base,
            "LANG": "C",
            "LC_ALL": "C",
            "PATH": "/usr/bin:/bin",
            "PYTHONNOUSERSITE": "1",
            "TMPDIR": base,
        }
        result = subject.run([bound], "/", runtime_env, 5)
        if result[0] != 0 or result[1] != b"sealed-provider\n":
            print("sealed Pixi provider did not execute its authenticated closure")
            return False
        provider_module = os.path.join(site, "pre_commit", "__init__.py")
        with open(provider_module, "rb") as stream:
            original_provider = stream.read()
        write_file(provider_module, b"VALUE = 'mutable-provider'\n")
        replacement_failed_closed = False
        replacement_output = None
        try:
            replacement_result = subject.run([bound], "/", runtime_env, 5)
            replacement_output = replacement_result[1]
        except subject.SetupError:
            replacement_failed_closed = True
        finally:
            write_file(provider_module, original_provider)
        if not replacement_failed_closed and replacement_output != b"sealed-provider\n":
            print("provider replacement selected unauthenticated import bytes")
            return False
        for tool in reversed(bound_tools):
            tool.close()
        bound_tools.clear()
        if descriptor_count() != before:
            print("successful provider closure binding leaked a sibling descriptor")
            return False

        error_tools = []
        error_boundary = subject.ReadOnlyExecutionBoundary(error_tools)
        error_boundary.require()
        original_descriptor = subject.BoundTool.__dict__["sealed_bytes"]
        original_sealed = original_descriptor.__get__(None, subject.BoundTool)
        calls = [0]

        def mutate_after_seal(_cls, path, data, executable=True):
            result = original_sealed(path, data, executable)
            calls[0] += 1
            if calls[0] == 2:
                write_file(path, b"changed-after-seal\n", 0o755 if executable else 0o644)
            return result

        source = subject.BoundTool.open(script)
        error_tools.append(source)
        failed_closed = False
        subject.BoundTool.sealed_bytes = classmethod(mutate_after_seal)
        try:
            subject.bind_executable(
                source,
                error_boundary.tree,
                "pre-commit-error",
                error_tools,
                error_boundary,
            )
        except subject.SetupError:
            failed_closed = True
        finally:
            subject.BoundTool.sealed_bytes = original_descriptor
            for tool in reversed(error_tools):
                tool.close()
        if not failed_closed or descriptor_count() != before:
            print("failed provider closure binding leaked or accepted changed bytes")
            return False
    finally:
        for tool in reversed(bound_tools):
            tool.close()
        shutil.rmtree(source_root, ignore_errors=True)
    if descriptor_count() != before:
        print("provider closure leaked a sibling descriptor")
        return False
    return True


def resource_limit_behavior(subject, base):
    """Host rlimits stop CPU, descriptor, process, and file growth."""

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
        "RLIMIT_CPU": 4,
        "RLIMIT_NOFILE": 128,
        "RLIMIT_FSIZE": 8 * 1024 * 1024,
        "RLIMIT_NPROC": 512,
    }
    if sys.platform.startswith("linux"):
        expected["RLIMIT_AS"] = 512 * 1024 * 1024
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
    """Loopback, host Unix sockets, and host FIFOs stay unreachable."""

    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: external-channel containment requires Linux")
        return None
    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
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
                os.path.realpath("/usr/bin/python3"),
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
            pass_fds=(boundary.guard.descriptor,),
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


def namespace_nested_cleanup_capability_behavior(subject):
    """Nested scratch paths never become host deletion capabilities."""

    calls = []
    originals = {
        "mkdir": subject.os.mkdir,
        "rename": subject.os.rename,
        "rmdir": subject.os.rmdir,
        "unlink": subject.os.unlink,
    }

    def forbidden(operation):
        def record(*args, **kwargs):
            calls.append((operation, args, kwargs))
            raise AssertionError("namespace scratch reached host {}".format(operation))

        return record

    for operation in originals:
        setattr(subject.os, operation, forbidden(operation))
    problem = None
    boundary = None
    nested = None
    try:
        boundary = subject.ReadOnlyExecutionBoundary([])
        nested = boundary.tree.mkdir("nested")
        boundary.verify()
    except BaseException as error:
        problem = error
    finally:
        for operation, original in originals.items():
            setattr(subject.os, operation, original)

    safe = (
        problem is None
        and isinstance(boundary.tree, subject.NamespaceTree)
        and nested == os.path.join(subject.RUNTIME_ROOT, "nested")
        and not calls
    )
    if not safe:
        print(
            "nested namespace scratch retained a host cleanup capability: "
            "problem={!r}, nested={!r}, calls={!r}".format(
                problem, nested, calls
            )
        )
    return safe


def namespace_root_cleanup_capability_behavior(subject):
    """Managed scratch roots are namespace lifetime, not pathname, owned."""

    problem = None
    boundary = None
    try:
        boundary = subject.ReadOnlyExecutionBoundary([])
        boundary.verify()
    except BaseException as error:
        problem = error

    safe = (
        problem is None
        and isinstance(boundary.tree, subject.NamespaceTree)
        and boundary.tree.path == subject.RUNTIME_ROOT
        and not hasattr(boundary, "data_tree")
        and not hasattr(subject, "PrivateTree")
        and not hasattr(boundary.tree, "close")
    )
    if not safe:
        print(
            "managed scratch roots retained a host cleanup capability: "
            "problem={!r}, boundary={!r}, private_tree={}, data_tree={}, "
            "tree_close={}".format(
                problem,
                boundary,
                hasattr(subject, "PrivateTree"),
                hasattr(boundary, "data_tree") if boundary is not None else None,
                hasattr(boundary.tree, "close") if boundary is not None else None,
            )
        )
    return safe


def namespace_only_scratch_behavior(subject, base, git):
    """Live main never allocates or cleans a pathname-selected host scratch tree."""

    fixture = os.path.join(base, "install-bin", "pre-commit-fixture")
    if not os.path.isfile(fixture):
        print("controlled pre-commit fixture is unavailable")
        return False
    root = tempfile.mkdtemp(prefix="namespace-only-main-", dir=base)
    host_tmp = tempfile.mkdtemp(prefix="namespace-only-host-tmp-", dir=base)
    os.makedirs(os.path.join(root, ".githooks"), mode=0o700)
    write_file(
        os.path.join(root, ".githooks", "pre-push"),
        b"#!/bin/sh\nexit 0\n",
        0o755,
    )
    config_path = os.path.join(root, ".pre-commit-config.yaml")
    write_file(
        config_path,
        b"default_install_hook_types: [pre-commit, pre-push]\nrepos: []\n",
    )
    subprocess.run(
        [git, "-c", "init.templateDir=", "-C", root, "init", "-q"],
        env={
            "PATH": "/usr/bin:/bin",
            "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1",
        },
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=True,
    )

    original_tempdir = tempfile.tempdir
    original_mkdir = subject.os.mkdir
    original_unlink = subject.os.unlink
    original_rmdir = subject.os.rmdir
    original_private_tree = getattr(subject, "PrivateTree", None)
    private_tree_called = {"value": False}
    final_name_calls = []
    host_scratch_calls = []
    emitted = []
    original_emit = subject.emit

    def private_tree_forbidden(*_args, **_kwargs):
        private_tree_called["value"] = True
        raise AssertionError("live main reached the host PrivateTree")

    def tracked_mkdir(path, mode=0o777, *, dir_fd=None):
        name = os.path.basename(os.fspath(path))
        if name.startswith(".odysseus-precommit-"):
            host_scratch_calls.append(("mkdir", name, dir_fd))
        return original_mkdir(path, mode, dir_fd=dir_fd)

    def tracked_unlink(path, *args, **kwargs):
        name = os.path.basename(os.fspath(path))
        if name.startswith(".odysseus-quarantine-"):
            final_name_calls.append(("unlink", name, kwargs.get("dir_fd")))
        return original_unlink(path, *args, **kwargs)

    def tracked_rmdir(path, *args, **kwargs):
        name = os.path.basename(os.fspath(path))
        if name.startswith(".odysseus-quarantine-"):
            final_name_calls.append(("rmdir", name, kwargs.get("dir_fd")))
        return original_rmdir(path, *args, **kwargs)

    tempfile.tempdir = host_tmp
    subject.os.mkdir = tracked_mkdir
    subject.os.unlink = tracked_unlink
    subject.os.rmdir = tracked_rmdir
    subject.emit = lambda kind, message: emitted.append(
        "{}\t{}".format(kind, message)
    )
    if original_private_tree is not None:
        subject.PrivateTree = private_tree_forbidden
    try:
        status = subject.main([
            "--root", root,
            "--pre-commit", fixture,
            "--git", git,
            "--mode", "install",
            "--expected-version", "3.8.0",
            "--timeout", "10",
        ])
    finally:
        tempfile.tempdir = original_tempdir
        subject.os.mkdir = original_mkdir
        subject.os.unlink = original_unlink
        subject.os.rmdir = original_rmdir
        subject.emit = original_emit
        if original_private_tree is not None:
            subject.PrivateTree = original_private_tree

    residues = []
    for search_root in (host_tmp, root):
        for directory, names, files in os.walk(search_root):
            for name in names + files:
                if name.startswith(
                    (".odysseus-precommit-", ".odysseus-quarantine-")
                ):
                    residues.append(os.path.join(directory, name))
    unavailable = status != 0 and any(
        marker in line
        for marker in (
            "no trusted secure execution boundary",
            "no secure execution boundary",
            "bwrap:",
        )
        for line in emitted
    )
    host_clean = (
        not private_tree_called["value"]
        and not host_scratch_calls
        and not final_name_calls
        and not residues
    )
    if unavailable and host_clean:
        print("BOUNDARY_UNAVAILABLE: live namespace proof was not exercised")
    safe = host_clean and status == 0 and not unavailable
    if not safe:
        print(
            "live namespace scratch reached a host cleanup route: "
            "status={},private_tree={},scratch_calls={!r},final_calls={!r},"
            "residues={!r},messages={!r}".format(
                status,
                private_tree_called["value"],
                host_scratch_calls,
                final_name_calls,
                residues,
                emitted,
            )
        )
    shutil.rmtree(root, ignore_errors=True)
    shutil.rmtree(host_tmp, ignore_errors=True)
    return safe


def escaped_session_behavior(subject):
    """A setsid plus double-fork descendant cannot outlive containment."""

    bound_tools = []
    boundary = subject.ReadOnlyExecutionBoundary(bound_tools)
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
                "import os,time\n"
                "os.write(1,b'attempted\\n')\n"
                "first = os.fork()\n"
                "if first:\n"
                "    os.waitpid(first, 0)\n"
                "    os._exit(0)\n"
                "os.setsid()\n"
                "second = os.fork()\n"
                "if second:\n"
                "    os._exit(0)\n"
                "time.sleep(0.4)\n"
                "os.write(1,b'escaped\\n')\n"
                "os._exit(0)\n"
            )
            command, executable = boundary.wrap([
                os.path.realpath("/usr/bin/python3"), "-I", "-S", "-c", program,
            ])
            try:
                result = subprocess.run(
                    command,
                    executable=executable,
                    pass_fds=(boundary.guard.descriptor,),
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
            elif result.returncode != 0 and b"attempted\n" not in result.stdout:
                detail = result.stdout + result.stderr
                unavailable = any(
                    marker in detail
                    for marker in (
                        b"Operation not permitted",
                        b"No permissions to creating new namespace",
                        b"Creating new namespace failed",
                    )
                )
        if unavailable:
            print("BOUNDARY_UNAVAILABLE: descendant extinction was not exercised")
        safe = (
            not unavailable
            and result is not None
            and result.returncode == 0
            and b"attempted\n" in result.stdout
            and b"escaped\n" not in result.stdout
        )
        if not safe:
            print(
                "a setsid/double-fork descendant escaped containment: "
                "unavailable={}, result={!r}, detail={!r}".format(
                    unavailable, result, detail,
                )
            )
            return False
        return True
    finally:
        for tool in reversed(bound_tools):
            tool.close()


def generated_install_python_behavior(subject):
    """Generated hook bytes use installer-owned provenance metadata only."""

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
    config_data = b"repos: []\n"
    policy_data = b"raise SystemExit(0)\n"
    runtime = {
        "source": selected,
        "source_digest": "a" * 64,
        "interpreter": "/usr/bin/python3",
        "interpreter_digest": "b" * 64,
        "git": "/usr/bin/git",
        "git_digest": "d" * 64,
        "boundary": "/usr/bin/bwrap",
        "boundary_digest": "c" * 64,
        "repository": "/trusted/repository",
        "git_directory": "/trusted/repository/.git",
        "git_common": "/trusted/repository/.git",
        "home": "/trusted/home",
        "config_hex": config_data.hex(),
        "config_digest": hashlib.sha256(config_data).hexdigest(),
        "policy_hex": policy_data.hex(),
        "policy_digest": hashlib.sha256(policy_data).hexdigest(),
        "pyyaml_manifest_hex": (b"/trusted/yaml.py=" + b"c" * 64).hex(),
        "closure_manifest_hex": subject.zlib.compress(
            b"/trusted/site-packages/yaml/__init__.py\t" + b"c" * 64 + b"\n"
        ).hex(),
    }
    canonicalize = getattr(subject, "canonical_generated_hook", None)
    if canonicalize is None:
        print("generated hook canonicalization is missing")
        return False
    try:
        result = canonicalize(candidate, "pre-push", runtime)
    except (OSError, subject.SetupError, UnicodeError) as error:
        print("metacharacter path was not encoded safely: {}".format(error))
        return False
    lines = result.decode("utf-8").splitlines()
    exact = subject._assignment(lines[6], "PRE_COMMIT_SOURCE") == selected
    candidate_absent = b"/untrusted" not in result and b"touch${IFS}" not in result
    stable = subject.generated(result, "pre-push", runtime) and not subject.generated(
        result + b"printf untrusted-trailer\\n\n", "pre-push", runtime
    )
    if not exact or not candidate_absent or not stable:
        print(
            "generated runtime was not replaced exactly: "
            "source_exact={!r},candidate_absent={},stable={}".format(
                exact, candidate_absent, stable
            )
        )
        return False
    return True


def trusted_hook_payload_behavior(subject, base):
    """Published hooks carry trusted config and policy bytes, not live routes."""

    config_path = os.path.join(base, "trusted-runtime-config")
    policy_path = os.path.join(base, "trusted-runtime-policy.py")
    config_data = b"repos: []\n"
    policy_data = b"raise SystemExit(0)\n"
    write_file(config_path, config_data)
    write_file(policy_path, policy_data)
    candidate = b"\n".join(
        line.encode("utf-8")
        for line in (
            *subject.HEADER,
            "INSTALL_PYTHON=/untrusted",
            "ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-commit)",
            *subject.TAIL,
        )
    ) + b"\n"
    runtime = {
        "source": "/trusted/pre-commit",
        "source_digest": "a" * 64,
        "interpreter": "/usr/bin/python3",
        "interpreter_digest": "b" * 64,
        "git": "/usr/bin/git",
        "git_digest": "d" * 64,
        "boundary": "/usr/bin/bwrap",
        "boundary_digest": "c" * 64,
        "repository": "/trusted/repository",
        "git_directory": "/trusted/repository/.git",
        "git_common": "/trusted/repository/.git",
        "home": "/trusted/home",
        "config_hex": config_data.hex(),
        "config_digest": hashlib.sha256(config_data).hexdigest(),
        "policy_hex": policy_data.hex(),
        "policy_digest": hashlib.sha256(policy_data).hexdigest(),
        "pyyaml_manifest_hex": b"/trusted/yaml.py=".hex() + b"c".hex() * 64,
        "closure_manifest_hex": subject.zlib.compress(
            b"/trusted/site-packages/yaml/__init__.py\t" + b"c" * 64 + b"\n"
        ).hex(),
    }
    try:
        hook = subject.canonical_generated_hook(candidate, "pre-commit", runtime)
    except (OSError, subject.SetupError, UnicodeError) as error:
        print("trusted hook payload was rejected: {}".format(error))
        return False
    write_file(config_path, b"repos:\n- repo: hostile\n")
    write_file(policy_path, b"open('/tmp/hostile', 'w').close()\n")
    lines = hook.decode("utf-8").splitlines()
    values = {}
    for name in (
        "TRUSTED_BOUNDARY",
        "TRUSTED_BOUNDARY_SHA256",
        "TRUSTED_REPOSITORY",
        "TRUSTED_GIT_DIRECTORY",
        "TRUSTED_GIT_COMMON",
        "TRUSTED_HOME",
        "TRUSTED_CONFIG_HEX",
        "TRUSTED_CONFIG_SHA256",
        "TRUSTED_POLICY_HEX",
        "TRUSTED_POLICY_SHA256",
        "TRUSTED_PYYAML_MANIFEST_HEX",
        "TRUSTED_CLOSURE_MANIFEST_HEX",
    ):
        matches = [subject._assignment(line, name) for line in lines]
        matches = [value for value in matches if value is not None]
        values[name] = matches[0] if len(matches) == 1 else None
    safe = (
        values["TRUSTED_BOUNDARY"] == runtime["boundary"]
        and values["TRUSTED_BOUNDARY_SHA256"] == runtime["boundary_digest"]
        and values["TRUSTED_REPOSITORY"] == runtime["repository"]
        and values["TRUSTED_GIT_DIRECTORY"] == runtime["git_directory"]
        and values["TRUSTED_GIT_COMMON"] == runtime["git_common"]
        and values["TRUSTED_HOME"] == runtime["home"]
        and values["TRUSTED_CONFIG_HEX"] == runtime["config_hex"]
        and values["TRUSTED_CONFIG_SHA256"] == runtime["config_digest"]
        and values["TRUSTED_POLICY_HEX"] == runtime["policy_hex"]
        and values["TRUSTED_POLICY_SHA256"] == runtime["policy_digest"]
        and values["TRUSTED_PYYAML_MANIFEST_HEX"]
        == runtime["pyyaml_manifest_hex"]
        and values["TRUSTED_CLOSURE_MANIFEST_HEX"]
        == runtime["closure_manifest_hex"]
        and subject.generated(hook, "pre-commit", runtime)
        and b"--config=.pre-commit-config.yaml" not in hook
    )
    if not safe:
        print(
            "published hook still depends on candidate config/policy routes: "
            "values={!r}, hook={!r}".format(values, hook[:512])
        )
        return False
    return True


def sealed_provider_mutation_behavior(subject, base):
    """A deterministic post-bind mutation cannot change executed provider bytes."""

    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: immutable provider memfds require Linux")
        return None
    provider_bin = os.path.join(base, "sealed-provider", "bin")
    os.makedirs(provider_bin)
    source = os.path.join(provider_bin, "pre-commit")
    original = b"#!/usr/bin/python3\nfrom probe import VALUE\nprint(VALUE)\n"
    replacement = b"#!/usr/bin/python3\nprint('REPLACED')\n"
    write_file(source, original, 0o755)
    interpreter = next(
        candidate
        for candidate in (os.path.realpath("/usr/bin/python3"), os.path.realpath(sys.executable))
        if os.path.isfile(candidate)
        and os.stat(candidate).st_uid == 0
        and not stat.S_IMODE(os.stat(candidate).st_mode) & 0o022
    )
    with open(interpreter, "rb") as stream:
        interpreter_digest = hashlib.sha256(stream.read()).hexdigest()
    boundary = next(
        (
            candidate
            for candidate in ("/usr/bin/bwrap", "/bin/bwrap")
            if os.path.isfile(candidate)
            and os.path.realpath(candidate) == os.path.abspath(candidate)
            and os.stat(candidate).st_uid == 0
            and not stat.S_IMODE(os.stat(candidate).st_mode) & 0o022
        ),
        None,
    )
    if boundary is None:
        print("authoritative Linux containment provider is unavailable")
        return False
    with open(boundary, "rb") as stream:
        boundary_digest = hashlib.sha256(stream.read()).hexdigest()
    config = b"repos: []\n"
    policy = b"raise SystemExit(0)\n"
    git_provider = os.path.realpath(shutil.which("git") or "/usr/bin/git")
    with open(git_provider, "rb") as stream:
        git_digest = hashlib.sha256(stream.read()).hexdigest()
    closure_file = os.path.join(
        base, "sealed-provider", "lib", "python3.11", "site-packages", "probe.py"
    )
    os.makedirs(os.path.dirname(closure_file))
    closure_original = b"VALUE = 'ORIGINAL'\n"
    closure_replacement = b"VALUE = 'REPLACED'\n"
    write_file(closure_file, closure_original)
    yaml_file = os.path.join(os.path.dirname(closure_file), "yaml.py")
    yaml_data = b"# YAML dependency fixture; this provider does not parse YAML.\n"
    write_file(yaml_file, yaml_data)
    yaml_digest = hashlib.sha256(yaml_data).hexdigest()
    manifest = (yaml_file + "=" + yaml_digest + "\n").encode("utf-8")
    closure_manifest = subject.zlib.compress(
        (closure_file + "\t" + hashlib.sha256(closure_original).hexdigest() + "\n"
         + yaml_file + "\t" + yaml_digest + "\n").encode("utf-8")
    ).hex()
    libc = ctypes.CDLL(None, use_errno=True)
    inotify_init1 = getattr(libc, "inotify_init1", None)
    inotify_add_watch = getattr(libc, "inotify_add_watch", None)
    if inotify_init1 is None or inotify_add_watch is None:
        print("Linux inotify is unavailable for the post-bind mutation oracle")
        return False
    inotify_init1.argtypes = (ctypes.c_int,)
    inotify_init1.restype = ctypes.c_int
    inotify_add_watch.argtypes = (ctypes.c_int, ctypes.c_char_p, ctypes.c_uint32)
    inotify_add_watch.restype = ctypes.c_int
    watch = inotify_init1(os.O_CLOEXEC)
    if watch < 0:
        print("Linux inotify could not bind the provider mutation oracle")
        return False
    source_watch = inotify_add_watch(watch, os.fsencode(source), 0x10)
    closure_watch = inotify_add_watch(watch, os.fsencode(closure_file), 0x10)
    if watch < 0 or source_watch < 0 or closure_watch < 0:
        if watch >= 0:
            os.close(watch)
        print("Linux inotify could not bind the provider mutation oracle")
        return False
    command = [
        interpreter,
        "-I",
        "-S",
        "-c",
        subject.MANAGED_RUNTIME_BOOTSTRAP,
        source,
        hashlib.sha256(original).hexdigest(),
        interpreter,
        interpreter_digest,
        git_provider,
        git_digest,
        boundary,
        boundary_digest,
        "pre-commit",
        os.path.join(base, "hook"),
        base,
        base,
        base,
        base,
        config.hex(),
        hashlib.sha256(config).hexdigest(),
        policy.hex(),
        hashlib.sha256(policy).hexdigest(),
        manifest.hex(),
        closure_manifest,
    ]
    process = subprocess.Popen(
        command,
        cwd=base,
        env=dict(os.environ),
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    observed = set()
    try:
        deadline = time.monotonic() + 5
        while len(observed) < 2 and time.monotonic() < deadline:
            ready, _, _ = select.select([watch], [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            payload = os.read(watch, 4096)
            offset = 0
            while offset + 16 <= len(payload):
                descriptor, _mask, _cookie, name_length = __import__("struct").unpack_from("iIII", payload, offset)
                offset += 16 + name_length
                if descriptor == source_watch and "source" not in observed:
                    write_file(source, replacement, 0o755)
                    observed.add("source")
                if descriptor == closure_watch and "closure" not in observed:
                    write_file(closure_file, closure_replacement)
                    observed.add("closure")
        stdout, stderr = process.communicate(timeout=15)
    except subprocess.TimeoutExpired:
        process.kill()
        stdout, stderr = process.communicate()
    finally:
        os.close(watch)
    if observed != {"source", "closure"} or process.returncode != 0 or stdout != b"ORIGINAL\n":
        print(
            "post-bind provider mutation selected mutable bytes: "
            "event={},status={},stdout={!r},stderr={!r}".format(
                observed, process.returncode, stdout, stderr
            )
        )
        return False
    return True


def managed_shell_entry_behavior(subject, base):
    """Managed hooks enter through fixed privileged Bash before verification."""

    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: installed managed shell boundary requires Linux")
        return None

    path_marker = os.path.join(base, "managed-path-shell-ran")
    startup_marker = os.path.join(base, "managed-startup-ran")
    source = os.path.join(base, "managed-entry-source")
    source_data = b"#!/usr/bin/python3\nprint('odysseus-managed-source-ran')\n"
    write_file(source, source_data, 0o755)
    interpreter = next(
        candidate
        for candidate in (
            os.path.realpath("/usr/bin/python3"),
            os.path.realpath(sys.executable),
        )
        if os.path.isfile(candidate)
        and os.stat(candidate).st_uid == 0
        and not stat.S_IMODE(os.stat(candidate).st_mode) & 0o022
    )
    with open(interpreter, "rb") as stream:
        interpreter_digest = hashlib.sha256(stream.read()).hexdigest()
    git_provider = os.path.realpath(shutil.which("git") or "/usr/bin/git")
    with open(git_provider, "rb") as stream:
        git_digest = hashlib.sha256(stream.read()).hexdigest()
    closure_file = os.path.join(
        base, "managed-shell", "lib", "python3.11", "site-packages", "probe.py"
    )
    os.makedirs(os.path.dirname(closure_file))
    write_file(closure_file, b"VALUE = 'sealed'\n")
    yaml_file = os.path.join(os.path.dirname(closure_file), "yaml.py")
    yaml_data = b"# YAML dependency fixture; this provider does not parse YAML.\n"
    write_file(yaml_file, yaml_data)
    yaml_digest = hashlib.sha256(yaml_data).hexdigest()
    closure_manifest = subject.zlib.compress(
        (closure_file + "\t" + hashlib.sha256(b"VALUE = 'sealed'\n").hexdigest() + "\n"
         + yaml_file + "\t" + yaml_digest + "\n").encode("utf-8")
    ).hex()
    boundary = "/usr/bin/bwrap"
    boundary_digest = "c" * 64
    if sys.platform.startswith("linux"):
        boundary = next(
            (
                candidate
                for candidate in ("/usr/bin/bwrap", "/bin/bwrap")
                if os.path.isfile(candidate)
                and os.path.realpath(candidate) == os.path.abspath(candidate)
                and os.stat(candidate).st_uid == 0
                and not stat.S_IMODE(os.stat(candidate).st_mode) & 0o022
            ),
            None,
        )
        if boundary is None:
            print("authoritative Linux containment provider is unavailable")
            return False
        with open(boundary, "rb") as stream:
            boundary_digest = hashlib.sha256(stream.read()).hexdigest()
    runtime = {
        "source": source,
        "source_digest": hashlib.sha256(source_data).hexdigest(),
        "interpreter": interpreter,
        "interpreter_digest": interpreter_digest,
        "git": git_provider,
        "git_digest": git_digest,
        "boundary": boundary,
        "boundary_digest": boundary_digest,
        "repository": base,
        "git_directory": base,
        "git_common": base,
        "home": base,
        "config_hex": b"repos: []\n".hex(),
        "config_digest": hashlib.sha256(b"repos: []\n").hexdigest(),
        "policy_hex": b"raise SystemExit(0)\n".hex(),
        "policy_digest": hashlib.sha256(b"raise SystemExit(0)\n").hexdigest(),
        "pyyaml_manifest_hex": (yaml_file + "=" + yaml_digest + "\n").encode("utf-8").hex(),
        "closure_manifest_hex": closure_manifest,
    }
    candidate = b"\n".join(
        line.encode("utf-8")
        for line in (
            *subject.HEADER,
            "INSTALL_PYTHON=/untrusted",
            "ARGS=(hook-impl --config=.pre-commit-config.yaml --hook-type=pre-commit)",
            *subject.TAIL,
        )
    ) + b"\n"
    hook = os.path.join(base, "managed-entry-hook")
    write_file(
        hook,
        subject.canonical_generated_hook(candidate, "pre-commit", runtime),
        0o755,
    )
    hostile = os.path.join(base, "managed-hostile-bin")
    os.mkdir(hostile, 0o700)
    write_file(
        os.path.join(hostile, "bash"),
        (
            "#!/bin/sh\nprintf hostile > {}\nexit 97\n".format(
                shlex.quote(path_marker)
            )
        ).encode("utf-8"),
        0o755,
    )
    startup = os.path.join(base, "managed-startup")
    write_file(
        startup,
        "printf hostile > {}\n".format(shlex.quote(startup_marker)).encode(
            "utf-8"
        ),
    )
    environment = dict(os.environ)
    environment.update(
        {
            "BASH_ENV": startup,
            "ENV": startup,
            "PATH": hostile + os.pathsep + "/usr/bin:/bin",
        }
    )
    try:
        result = subprocess.run(
            [hook],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=environment,
            timeout=5,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        print("managed hook entry could not be observed: {}".format(error))
        return False
    with open(hook, "rb") as stream:
        first_line = stream.readline().rstrip(b"\n")
    executed_or_closed = (
        result.returncode == 0
        and b"odysseus-managed-source-ran\n" in result.stdout
    ) or (
        result.returncode != 0
        and any(
            marker in result.stderr
            for marker in (
                b"descriptor-bound interpreter execution is unavailable",
                b"immutable provider snapshots are unavailable",
                b"cannot bind /usr/bin/bwrap",
            )
        )
        and b"odysseus-managed-source-ran" not in result.stdout
    )
    safe = (
        first_line == b"#!/bin/bash -p"
        and not os.path.exists(path_marker)
        and not os.path.exists(startup_marker)
        and executed_or_closed
    )
    if not safe:
        print(
            "managed hook retained pre-verification shell authority: "
            "line={!r},status={},path_marker={},startup_marker={},source_ran={},"
            "stderr={!r}".format(
                first_line,
                result.returncode,
                os.path.exists(path_marker),
                os.path.exists(startup_marker),
                b"odysseus-managed-source-ran" in result.stdout,
                result.stderr,
            )
        )
        return False
    return True


def managed_runtime_descriptor_behavior(subject, base):
    """Execute the installed descriptor-bound runtime through real bubblewrap."""

    bootstrap = subject.MANAGED_RUNTIME_BOOTSTRAP
    signal_probe = r'''import signal
import sys

namespace = {}
prefix, separator, _remainder = sys.argv[1].partition("\n(\n    source_path")
if not separator:
    raise SystemExit("cannot isolate managed-runtime definitions")
exec(prefix, namespace)
for signum in namespace["CANCELLATION_SIGNALS"]:
    signal.signal(signum, signal.SIG_IGN)
signal.pthread_sigmask(
    signal.SIG_BLOCK, set(namespace["CANCELLATION_SIGNALS"])
)
limits = {}
def setrlimit(kind, value):
    limits[kind] = value
def getrlimit(kind):
    return limits.get(kind, (0, 0))
namespace["resource"].setrlimit = setrlimit
namespace["resource"].getrlimit = getrlimit
namespace["establish_limits"]()
handlers = all(
    signal.getsignal(signum) is namespace["cancellation_handler"]
    for signum in namespace["CANCELLATION_SIGNALS"]
)
mask = signal.pthread_sigmask(signal.SIG_BLOCK, set())
unblocked = all(
    signum not in mask for signum in namespace["CANCELLATION_SIGNALS"]
)
print("{}|{}".format(handlers, unblocked))
    '''
    signal_result = subprocess.run(
        [sys.executable, "-I", "-S", "-c", signal_probe, bootstrap],
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=5,
        check=False,
    )
    if signal_result.returncode != 0 or signal_result.stdout.strip() != b"True|True":
        print(
            "managed runtime inherited ignored or blocked cancellation signals: "
            "status={},stdout={!r},stderr={!r}".format(
                signal_result.returncode,
                signal_result.stdout,
                signal_result.stderr,
            )
        )
        return False
    if (
        "--ro-bind-fd" not in bootstrap
        or "/proc/self/fd" in bootstrap
        or 'private_site_root = "/odysseus/provider/site-packages"' not in bootstrap
        or '"--remount-ro", private_site_root' not in bootstrap
        or 'trusted_config = "/odysseus/runtime/config.yaml"' not in bootstrap
    ):
        print("managed runtime retained a mutable or pathname-selected authority route")
        return False
    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: managed immutable runtime requires Linux")
        return None

    provider_bin = os.path.join(base, "managed-runtime", "bin")
    os.makedirs(provider_bin)
    repository = os.path.join(base, "managed-runtime-repository")
    os.mkdir(repository, 0o700)
    escape_directory = os.path.join(base, "managed-runtime-escape")
    os.mkdir(escape_directory, 0o700)
    escape_marker = os.path.join(escape_directory, "outside-mounted-tree")
    write_file(escape_marker, b"host-only\n")
    escape_relative = "../{}/{}".format(
        os.path.basename(escape_directory), os.path.basename(escape_marker)
    )
    original_site_root = os.path.join(
        repository,
        ".pixi",
        "envs",
        "default",
        "lib",
        "python3.11",
        "site-packages",
    )
    os.makedirs(os.path.join(original_site_root, "yaml"))
    closure_payloads = {
        os.path.join(original_site_root, "probe.py"): b"VALUE = 'sealed'\n",
        os.path.join(original_site_root, "yaml", "__init__.py"): (
            b"__version__ = '6.0.3'\n"
        ),
    }
    for path, data in closure_payloads.items():
        write_file(path, data)
    hostile_sibling = os.path.join(original_site_root, "unsealed_sibling.py")
    hostile_native = os.path.join(original_site_root, "unsealed_native.so")
    write_file(hostile_sibling, b"VALUE = 'hostile'\n")
    write_file(hostile_native, b"not a trusted native module\n")
    closure_manifest = subject.zlib.compress(
        "".join(
            "{}\t{}\n".format(path, hashlib.sha256(data).hexdigest())
            for path, data in sorted(closure_payloads.items())
        ).encode("utf-8")
    ).hex()
    yaml_path = os.path.join(original_site_root, "yaml", "__init__.py")
    pyyaml_manifest = (
        "{}={}\n".format(
            yaml_path, hashlib.sha256(closure_payloads[yaml_path]).hexdigest()
        ).encode("utf-8").hex()
    )
    source = os.path.join(provider_bin, "pre-commit")
    provider = """#!/usr/bin/python3
import hashlib
import importlib
import os
import resource
import signal
import sys

config = next(value.split("=", 1)[1] for value in sys.argv if value.startswith("--config="))
with open(config, "rb") as stream:
    config_digest = hashlib.sha256(stream.read()).hexdigest()
try:
    with open("/etc/passwd", "rb") as stream:
        etc_visible = "yes"
except OSError:
    etc_visible = "no"
try:
    with open("host-write-probe", "wb") as stream:
        stream.write(b"unsafe")
    repository_writable = "yes"
except OSError:
    repository_writable = "no"
capability_escape = "no"
for value in os.listdir("/proc/self/fd"):
    try:
        descriptor = int(value)
    except ValueError:
        continue
    if descriptor < 3:
        continue
    try:
        escaped = os.open(sys.argv[-2], os.O_RDONLY, dir_fd=descriptor)
    except OSError:
        continue
    else:
        os.close(escaped)
        capability_escape = "yes"
        break
original_site_root = sys.argv[-1]
sibling_visible = "yes" if os.path.exists(
    os.path.join(original_site_root, "unsealed_sibling.py")
) else "no"
native_visible = "yes" if os.path.exists(
    os.path.join(original_site_root, "unsealed_native.so")
) else "no"
sys.path.insert(0, original_site_root)
try:
    importlib.import_module("unsealed_sibling")
except ImportError:
    sibling_imported = "no"
else:
    sibling_imported = "yes"
finally:
    sys.path.pop(0)
import probe
values = (
    config,
    os.environ.get("ODYSSEUS_PRE_COMMIT_INTERPRETER", ""),
    os.environ.get("ODYSSEUS_PRE_COMMIT_PROVIDER", ""),
    os.environ.get("ODYSSEUS_EXECUTABLE_ORIGIN", ""),
    os.environ.get("GIT_CONFIG_GLOBAL", ""),
    os.environ.get("GIT_INDEX_FILE", ""),
    str(bool(os.environ.get("ODYSSEUS_TRUSTED_POLICY_ROOT"))).lower(),
    etc_visible,
    repository_writable,
    capability_escape,
    config_digest,
    probe.VALUE,
    sibling_visible,
    native_visible,
    sibling_imported,
    ",".join(
        str(resource.getrlimit(getattr(resource, name))[0])
        for name in ("RLIMIT_CPU", "RLIMIT_AS", "RLIMIT_NPROC", "RLIMIT_NOFILE", "RLIMIT_FSIZE")
    ),
    str(signal.alarm(0) > 0).lower(),
)
os.write(1, ("|".join(values) + "\\n").encode("utf-8"))
"""
    write_file(source, provider.encode("utf-8"), 0o755)
    interpreter = next(
        candidate
        for candidate in (
            os.path.realpath("/usr/bin/python3"),
            os.path.realpath(sys.executable),
        )
        if os.path.isfile(candidate)
        and os.stat(candidate).st_uid == 0
        and not stat.S_IMODE(os.stat(candidate).st_mode) & 0o022
    )
    with open(source, "rb") as stream:
        source_digest = hashlib.sha256(stream.read()).hexdigest()
    with open(interpreter, "rb") as stream:
        interpreter_digest = hashlib.sha256(stream.read()).hexdigest()
    boundary = next(
        (
            candidate
            for candidate in ("/usr/bin/bwrap", "/bin/bwrap")
            if os.path.isfile(candidate)
            and os.path.realpath(candidate) == os.path.abspath(candidate)
            and os.stat(candidate).st_uid == 0
            and not stat.S_IMODE(os.stat(candidate).st_mode) & 0o022
        ),
        None,
    )
    if boundary is None:
        print("authoritative Linux containment provider is unavailable")
        return False
    with open(boundary, "rb") as stream:
        boundary_digest = hashlib.sha256(stream.read()).hexdigest()

    hostile = {
        "GIT_ALTERNATE_OBJECT_DIRECTORIES": os.path.join(base, "objects"),
        "GIT_CEILING_DIRECTORIES": base,
        "GIT_COMMON_DIR": os.path.join(base, "common"),
        "GIT_CONFIG_COUNT": "1",
        "GIT_CONFIG_KEY_0": "core.hooksPath",
        "GIT_CONFIG_PARAMETERS": "'core.hooksPath'='hostile'",
        "GIT_CONFIG_VALUE_0": os.path.join(base, "hooks"),
        "GIT_CONFIG_GLOBAL": os.path.join(base, "global-config"),
        "GIT_DIR": os.path.join(base, "git-dir"),
        "GIT_EXEC_PATH": os.path.join(base, "exec-path"),
        "GIT_GRAFT_FILE": os.path.join(base, "grafts"),
        "GIT_INDEX_FILE": os.path.join(repository, "alternate-index"),
        "GIT_NAMESPACE": "hostile",
        "GIT_OBJECT_DIRECTORY": os.path.join(base, "object-directory"),
        "GIT_REPLACE_REF_BASE": "refs/hostile/replace/",
        "GIT_SHALLOW_FILE": os.path.join(base, "shallow"),
        "GIT_WORK_TREE": os.path.join(base, "work-tree"),
        "LD_LIBRARY_PATH": os.path.join(base, "loader"),
        "LD_PRELOAD": os.path.join(base, "loader.so"),
        "DYLD_INSERT_LIBRARIES": os.path.join(base, "loader.dylib"),
        "PYTHONINSPECT": "1",
        "PYTHONPYCACHEPREFIX": os.path.join(base, "pycache"),
        "PYTHONSTARTUP": os.path.join(base, "startup.py"),
        "PYTHONWARNINGS": "error::UserWarning:hostile.module",
        "ODYSSEUS_MANAGED_PRE_COMMIT": "hostile",
        "ODYSSEUS_PRE_COMMIT_INTERPRETER": os.path.join(base, "python"),
        "ODYSSEUS_PRE_COMMIT_INTERPRETER_SHA256": "0" * 64,
        "ODYSSEUS_PRE_COMMIT_PROVIDER": os.path.join(base, "pre-commit"),
        "ODYSSEUS_PRE_COMMIT_PROVIDER_SHA256": "0" * 64,
        "ODYSSEUS_PRE_COMMIT_POLICY_HEX": "00",
        "ODYSSEUS_PRE_COMMIT_POLICY_SHA256": "0" * 64,
        "ODYSSEUS_PYYAML_MANIFEST": "hostile",
        "ODYSSEUS_TRUSTED_POLICY_ROOT": os.path.join(base, "hostile-policy"),
    }
    config_data = b"repos: []\n"
    policy_data = b"raise SystemExit(0)\n"
    git_provider = os.path.realpath(shutil.which("git") or "/usr/bin/git")
    with open(git_provider, "rb") as stream:
        git_digest = hashlib.sha256(stream.read()).hexdigest()
    command = [
        interpreter,
        "-I",
        "-S",
        "-c",
        subject.MANAGED_RUNTIME_BOOTSTRAP,
        source,
        source_digest,
        interpreter,
        interpreter_digest,
        git_provider,
        git_digest,
        boundary,
        boundary_digest,
        "pre-commit",
        os.path.join(repository, "hook"),
        repository,
        repository,
        repository,
        base,
        config_data.hex(),
        hashlib.sha256(config_data).hexdigest(),
        policy_data.hex(),
        hashlib.sha256(policy_data).hexdigest(),
        pyyaml_manifest,
        closure_manifest,
        escape_relative,
        original_site_root,
    ]
    environment = dict(os.environ)
    environment.update(hostile)
    result = subprocess.run(
        command,
        cwd=base,
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        timeout=15,
        check=False,
    )
    expected_fields = (
        (
            "/odysseus/runtime/config.yaml",
            "/odysseus/runtime/python",
            "/odysseus/runtime/pre-commit",
            "/odysseus/runtime/pre-commit",
            "/dev/null",
            hostile["GIT_INDEX_FILE"],
            "false",
            "no",
            "no",
            "no",
            hashlib.sha256(config_data).hexdigest(),
            "sealed",
            "no",
            "no",
            "no",
        )
    )
    try:
        actual_fields = result.stdout.decode("utf-8").strip().split("|")
        limits = [int(value) for value in actual_fields[15].split(",")]
    except (UnicodeError, ValueError, IndexError):
        actual_fields = []
        limits = []
    expected_limits = (10, 512 * 1024 * 1024, 128, 2048, 8 * 1024 * 1024)
    safe = (
        result.returncode == 0
        and tuple(actual_fields[:15]) == expected_fields
        and len(limits) == len(expected_limits)
        and all(0 <= actual <= maximum for actual, maximum in zip(limits, expected_limits))
        and actual_fields[16] == "false"
        and not os.path.exists(os.path.join(repository, "host-write-probe"))
    )
    if not safe:
        print(
            "managed runtime did not consume its sealed descriptors inside the "
            "real boundary: status={},stdout={!r},stderr={!r}".format(
                result.returncode, result.stdout, result.stderr
            )
        )
        return False

    hanging_source = os.path.join(provider_bin, "pre-commit-hanging")
    hanging_provider = b"""#!/usr/bin/python3
import os
import signal

if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(1, b'descendant-ready\\n')
    while True:
        signal.pause()
while True:
    signal.pause()
"""
    write_file(hanging_source, hanging_provider, 0o755)
    hanging_digest = hashlib.sha256(hanging_provider).hexdigest()

    def hanging_command(seconds):
        selected = list(command)
        selected[4] = bootstrap.replace(
            "WALL_SECONDS = 30", "WALL_SECONDS = {}".format(seconds)
        )
        selected[5] = hanging_source
        selected[6] = hanging_digest
        return selected

    # The fixture descendant never closes its inherited stdout. Receiving its
    # readiness line and EOF through bounded communicate proves this child no
    # longer holds the pipe. A surviving paused child makes communicate time out.
    # Do not interpret a PID from the sandbox's private /proc as a host PID.
    try:
        deadline_result = subprocess.run(
            hanging_command(1),
            cwd=base,
            env=environment,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=5,
            check=False,
        )
    except subprocess.TimeoutExpired:
        print("managed runtime wall supervisor did not return")
        return False
    if (
        deadline_result.returncode != 124
        or b"wall-clock deadline exceeded" not in deadline_result.stderr
        or deadline_result.stdout != b"descendant-ready\n"
    ):
        print(
            "managed runtime deadline did not extinguish descendants: "
            "status={},stdout={!r},stderr={!r}".format(
                deadline_result.returncode,
                deadline_result.stdout,
                deadline_result.stderr,
            )
        )
        return False

    cancellation_signals = (
        signal.SIGTERM, signal.SIGHUP, signal.SIGINT, signal.SIGQUIT
    )
    for inherited in ("ignored", "blocked"):
        for cancel_signal in cancellation_signals:
            def inherited_state():
                if inherited == "ignored":
                    for signum in cancellation_signals:
                        signal.signal(signum, signal.SIG_IGN)
                else:
                    signal.pthread_sigmask(
                        signal.SIG_BLOCK, set(cancellation_signals)
                    )

            process = subprocess.Popen(
                hanging_command(5),
                cwd=base,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                preexec_fn=inherited_state,
            )
            readable, _writable, _exceptional = select.select(
                [process.stdout], [], [], 3
            )
            if not readable:
                process.kill()
                process.wait(timeout=2)
                print(
                    "managed runtime did not start under {} cancellation state".format(
                        inherited
                    )
                )
                return False
            first_line = process.stdout.readline()
            os.kill(process.pid, cancel_signal)
            try:
                remaining_out, cancel_error = process.communicate(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
                print(
                    "managed runtime retained {} {} cancellation".format(
                        inherited, signal.Signals(cancel_signal).name
                    )
                )
                return False
            cancel_out = first_line + remaining_out
            if (
                process.returncode != 128 + cancel_signal
                or signal.Signals(cancel_signal).name.encode("ascii")
                not in cancel_error
                or cancel_out != b"descendant-ready\n"
            ):
                print(
                    "managed runtime cancellation did not extinguish descendants: "
                    "state={},signal={},status={},stdout={!r},stderr={!r}".format(
                        inherited,
                        signal.Signals(cancel_signal).name,
                        process.returncode,
                        cancel_out,
                        cancel_error,
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

    def forged_git_value(
        _git, _repo, args, _env, _timeout, readonly_paths=()
    ):
        del readonly_paths
        if args == ["rev-parse", "--show-toplevel"]:
            return root
        if args in (
            ["rev-parse", "--absolute-git-dir"],
            ["rev-parse", "--git-common-dir"],
        ):
            return unrelated
        raise AssertionError(args)

    def controlled_run(argv, _cwd, _env, _timeout, readonly_paths=()):
        del readonly_paths
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


def external_worktree_mount_behavior(subject, base, git):
    """Bind an actual external worktree without replacing the run boundary."""

    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: external-worktree containment requires Linux")
        return None

    source = tempfile.mkdtemp(prefix="external-worktree-source-", dir=base)
    root = tempfile.mkdtemp(prefix="external-worktree-checkout-", dir=base)
    os.rmdir(root)
    clean = {
        "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_CONFIG_NOSYSTEM": "1",
        "HOME": base,
        "LANG": "C",
        "LC_ALL": "C",
        "PATH": "/usr/bin:/bin",
        "TMPDIR": base,
    }
    setup_commands = (
        [git, "-c", "init.templateDir=", "init", "-q", source],
        [git, "-C", source, "config", "user.name", "Odysseus Test"],
        [git, "-C", source, "config", "user.email", "test@example.invalid"],
    )
    for command in setup_commands:
        result = subprocess.run(
            command,
            env=clean,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            print("external-worktree fixture failed: {!r}".format(result.stderr))
            return False
    write_file(os.path.join(source, "tracked"), b"tracked\n")
    for command in (
        [git, "-C", source, "add", "tracked"],
        [git, "-C", source, "commit", "-qm", "fixture"],
        [git, "-C", source, "worktree", "add", "-qb", "topic", root],
    ):
        result = subprocess.run(
            command,
            env=clean,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if result.returncode != 0:
            print("external-worktree fixture failed: {!r}".format(result.stderr))
            return False
    config = os.path.join(root, ".pre-commit-config.yaml")
    write_file(config, b"repos: []\n")

    deadline = subject.OperationDeadline(20)
    budget = subject.OperationBudget(deadline)
    bound_tools = []
    repo = None
    error = None
    namespace_only_proven = False
    directory_capabilities_closed = False
    namespace_parent = None
    namespace_route = None
    try:
        try:
            git_source = subject.BoundTool.open(os.path.realpath(git))
            bound_tools.append(git_source)
            boundary = subject.ReadOnlyExecutionBoundary(bound_tools, budget)
            boundary.require()
            git_bound = subject.bind_executable(
                git_source, boundary.tree, "git", bound_tools, boundary
            )
            environment = subject.clean_env(
                git_bound,
                git_bound,
                subject.SCRATCH_HOME,
                subject.SCRATCH_CACHE,
            )
            namespace_path = "/odysseus/descriptor-only-{}".format(
                os.path.basename(root)
            )
            namespace_absent = not os.path.lexists(namespace_path)
            host_direct = subprocess.run(
                [git, "-C", namespace_path, "rev-parse", "--show-toplevel"],
                env=clean,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            namespace_parent = subject.BoundDir.open(
                os.path.dirname(source), safe=True
            )
            namespace_route = subject.BoundDir.open_at(
                namespace_parent.descriptor,
                os.path.basename(source),
                namespace_path,
                safe=True,
            )
            namespace_value = subject.git_value(
                git_bound,
                namespace_path,
                ["rev-parse", "--show-toplevel"],
                environment,
                budget,
                (namespace_route,),
            )
            namespace_only_proven = (
                namespace_absent
                and host_direct.returncode != 0
                and namespace_value == namespace_path
            )
            escape_directory = os.path.join(base, "descriptor-escape-target")
            os.mkdir(escape_directory, 0o700)
            write_file(os.path.join(escape_directory, "marker"), b"host-only\n")
            escape_relative = "../{}/marker".format(
                os.path.basename(escape_directory)
            )
            interpreter = os.path.realpath("/usr/bin/python3")
            probe_path = os.path.join(source, "descriptor-probe.py")
            write_file(
                probe_path,
                (
                    "#!{}\n"
                    "import os, sys\n"
                    "escaped = False\n"
                    "for value in os.listdir('/proc/self/fd'):\n"
                    "    try:\n"
                    "        descriptor = int(value)\n"
                    "    except ValueError:\n"
                    "        continue\n"
                    "    if descriptor < 3:\n"
                    "        continue\n"
                    "    try:\n"
                    "        opened = os.open(sys.argv[1], os.O_RDONLY, "
                    "dir_fd=descriptor)\n"
                    "    except OSError:\n"
                    "        continue\n"
                    "    os.close(opened)\n"
                    "    escaped = True\n"
                    "    break\n"
                    "print('escape' if escaped else 'closed')\n"
                ).format(interpreter).encode("utf-8"),
                0o755,
            )
            probe_source = subject.BoundTool.open(probe_path)
            bound_tools.append(probe_source)
            probe_bound = subject.bind_executable(
                probe_source,
                boundary.tree,
                "descriptor-probe",
                bound_tools,
                boundary,
            )
            probe_result = subject.run(
                [probe_bound, escape_relative],
                namespace_path,
                environment,
                budget,
                readonly_paths=(namespace_route,),
            )
            directory_capabilities_closed = (
                probe_result[0] == 0 and probe_result[1] == b"closed\n"
            )
            repo = subject.bind_repo(root, config, git_bound, environment, budget)
        except (OSError, subject.SetupError, UnicodeError) as caught:
            error = caught
    finally:
        if repo is not None:
            repo.close()
        if namespace_route is not None:
            namespace_route.close()
        if namespace_parent is not None:
            namespace_parent.close()
        for tool in reversed(bound_tools):
            tool.close()
    expected_common = os.path.realpath(os.path.join(source, ".git"))
    complete = (
        repo is not None
        and namespace_only_proven
        and directory_capabilities_closed
        and repo.path == os.path.realpath(root)
        and repo.common.path == expected_common
        and repo.git_dir.path.startswith(expected_common + os.sep + "worktrees" + os.sep)
    )
    if error is not None or not complete:
        print(
            "external worktree metadata was not available through the real "
            "boundary: error={!r},complete={},namespace_only={},fds_closed={}".format(
                error,
                complete,
                namespace_only_proven,
                directory_capabilities_closed,
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


def aggregate_budget_behavior(subject, base, git):
    """Parent-side discovery has aggregate count/byte limits and one deadline."""

    required = (
        "MAX_DIRECTORY_ENTRIES",
        "MAX_CONFIGS",
        "MAX_REPOSITORIES",
        "MAX_CONFIG_BYTES",
        "MAX_HOOK_ENTRIES",
        "MAX_HOOK_BYTES",
        "MAX_RUNTIME_SIBLINGS",
        "MAX_RUNTIME_BYTES",
        "OperationDeadline",
        "OperationBudget",
        "DiscoveryInventory",
        "_bounded_directory_names",
    )
    missing = [name for name in required if not hasattr(subject, name)]
    if missing:
        print("installer aggregate budgets are missing: {!r}".format(missing))
        return False
    if subject.MAX_CONFIGS != subject.MAX_REPOSITORIES:
        print("configuration and repository ceilings disagree")
        return False
    if max(
        subject.MAX_CONFIGS,
        subject.MAX_HOOK_ENTRIES,
        subject.MAX_RUNTIME_SIBLINGS,
    ) > 1024:
        print("testable aggregate ceilings are unexpectedly unbounded")
        return False

    deadline = subject.OperationDeadline(10)
    budget = subject.OperationBudget(deadline)
    config_root = tempfile.mkdtemp(prefix="config-budget-", dir=base)
    for index in range(subject.MAX_CONFIGS):
        repo = os.path.join(config_root, "repo-{:04d}".format(index))
        os.mkdir(repo)
        write_file(os.path.join(repo, ".pre-commit-config.yaml"), b"repos: []\n")
    count_boundary_accepted = (
        len(subject.configs_under(config_root, budget)) == subject.MAX_CONFIGS
    )
    extra_repo = os.path.join(
        config_root, "repo-{:04d}".format(subject.MAX_CONFIGS)
    )
    os.mkdir(extra_repo)
    write_file(os.path.join(extra_repo, ".pre-commit-config.yaml"), b"repos: []\n")
    count_rejected = False
    try:
        subject.configs_under(config_root, budget)
    except subject.SetupError as error:
        count_rejected = "configuration" in str(error) or "repository" in str(error)

    byte_root = tempfile.mkdtemp(prefix="config-bytes-", dir=base)
    oversized = os.path.join(byte_root, ".pre-commit-config.yaml")
    with open(oversized, "wb") as stream:
        stream.truncate(subject.MAX_CONFIG_BYTES)
    byte_boundary_accepted = subject.configs_under(
        byte_root, subject.OperationDeadline(10)
    ) == [oversized]
    with open(oversized, "r+b") as stream:
        stream.truncate(subject.MAX_CONFIG_BYTES + 1)
    bytes_rejected = False
    try:
        subject.configs_under(byte_root, subject.OperationDeadline(10))
    except subject.SetupError as error:
        bytes_rejected = "configuration byte" in str(error)

    hooks_root = tempfile.mkdtemp(prefix="hook-budget-", dir=base)
    for index in range(subject.MAX_HOOK_ENTRIES):
        write_file(os.path.join(hooks_root, "hook-{:04d}".format(index)), b"x")
    hooks = subject.BoundDir.open(hooks_root, safe=True)
    hook_boundary_accepted = (
        len(subject.inventory(hooks, subject.OperationDeadline(10)))
        == subject.MAX_HOOK_ENTRIES
    )
    write_file(
        os.path.join(hooks_root, "hook-{:04d}".format(subject.MAX_HOOK_ENTRIES)),
        b"x",
    )
    hook_rejected = False
    try:
        try:
            subject.inventory(hooks, subject.OperationDeadline(10))
        except subject.SetupError as error:
            hook_rejected = "hook inventory entry budget" in str(error)
    finally:
        hooks.close()

    hook_bytes_root = tempfile.mkdtemp(prefix="hook-bytes-", dir=base)
    chunk = subject.MAX_HOOK_BYTES // 4
    for index in range(4):
        write_file(os.path.join(hook_bytes_root, "part-{}".format(index)), b"x" * chunk)
    byte_hooks = subject.BoundDir.open(hook_bytes_root, safe=True)
    hook_byte_boundary_accepted = False
    hook_bytes_rejected = False
    try:
        hook_byte_boundary_accepted = (
            sum(len(item.data) for item in subject.inventory(
                byte_hooks, subject.OperationDeadline(10)
            ).values()) == subject.MAX_HOOK_BYTES
        )
        write_file(os.path.join(hook_bytes_root, "overflow"), b"x")
        try:
            subject.inventory(byte_hooks, subject.OperationDeadline(10))
        except subject.SetupError as error:
            hook_bytes_rejected = "hook inventory byte budget" in str(error)
    finally:
        byte_hooks.close()

    shared_hooks_root = tempfile.mkdtemp(prefix="shared-hook-budget-", dir=base)
    shared_left = os.path.join(shared_hooks_root, "left")
    shared_right = os.path.join(shared_hooks_root, "right")
    os.mkdir(shared_left)
    os.mkdir(shared_right)
    split = subject.MAX_HOOK_ENTRIES // 2
    for index in range(split):
        write_file(os.path.join(shared_left, "left-{:04d}".format(index)), b"x")
    for index in range(subject.MAX_HOOK_ENTRIES - split):
        write_file(os.path.join(shared_right, "right-{:04d}".format(index)), b"x")
    left = subject.BoundDir.open(shared_left, safe=True)
    right = subject.BoundDir.open(shared_right, safe=True)
    shared_budget = subject.OperationBudget(subject.OperationDeadline(10))
    shared_hook_boundary_accepted = False
    shared_hook_rejected = False
    try:
        subject.inventory(left, shared_budget)
        subject.inventory(right, shared_budget)
        shared_hook_boundary_accepted = True
        write_file(os.path.join(shared_right, "overflow"), b"x")
        try:
            subject.inventory(right, shared_budget)
        except subject.SetupError as error:
            shared_hook_rejected = "hook inventory entry budget" in str(error)
    finally:
        left.close()
        right.close()

    ledger_budget = subject.OperationBudget(subject.OperationDeadline(10))
    repository_boundary_accepted = True
    for index in range(subject.MAX_REPOSITORIES):
        ledger_budget.charge_repository(
            os.path.join(base, "ledger-repo-{:04d}".format(index))
        )
    repository_rejected = False
    try:
        ledger_budget.charge_repository(os.path.join(base, "ledger-repo-overflow"))
    except subject.SetupError as error:
        repository_rejected = "repository count budget" in str(error)
    runtime_budget = subject.OperationBudget(subject.OperationDeadline(10))
    runtime_budget.charge_runtime_file(
        os.path.join(base, "runtime-boundary"),
        (1, 2, 3),
        subject.MAX_RUNTIME_BYTES,
    )
    runtime_byte_boundary_accepted = (
        runtime_budget.runtime_bytes == subject.MAX_RUNTIME_BYTES
    )
    runtime_bytes_rejected = False
    try:
        runtime_budget.charge_runtime_file(
            os.path.join(base, "runtime-overflow"), (4, 5, 6), 1
        )
    except subject.SetupError as error:
        runtime_bytes_rejected = "runtime dependency byte budget" in str(error)

    sibling_root = tempfile.mkdtemp(prefix="sibling-budget-", dir=base)
    for index in range(subject.MAX_RUNTIME_SIBLINGS):
        write_file(os.path.join(sibling_root, "sibling-{:04d}".format(index)), b"x")
    directory = os.open(sibling_root, os.O_RDONLY | os.O_DIRECTORY)
    sibling_boundary_accepted = (
        len(subject._bounded_directory_names(
            directory,
            subject.MAX_RUNTIME_SIBLINGS,
            "runtime sibling",
            subject.OperationDeadline(10),
        )) == subject.MAX_RUNTIME_SIBLINGS
    )
    write_file(
        os.path.join(
            sibling_root,
            "sibling-{:04d}".format(subject.MAX_RUNTIME_SIBLINGS),
        ),
        b"x",
    )
    sibling_rejected = False
    try:
        try:
            subject._bounded_directory_names(
                directory,
                subject.MAX_RUNTIME_SIBLINGS,
                "runtime sibling",
                subject.OperationDeadline(10),
            )
        except subject.SetupError as error:
            sibling_rejected = "runtime sibling entry budget" in str(error)
    finally:
        os.close(directory)

    directory_root = tempfile.mkdtemp(prefix="directory-budget-", dir=base)
    for index in range(subject.MAX_DIRECTORY_ENTRIES - 1):
        write_file(os.path.join(directory_root, "entry-{:04d}".format(index)), b"")
    directory_config = os.path.join(directory_root, ".pre-commit-config.yaml")
    write_file(directory_config, b"repos: []\n")
    directory_boundary_accepted = subject.configs_under(
        directory_root, subject.OperationDeadline(10)
    ) == [directory_config]
    write_file(os.path.join(directory_root, "overflow"), b"")
    directory_rejected = False
    try:
        subject.configs_under(directory_root, subject.OperationDeadline(10))
    except subject.SetupError as error:
        directory_rejected = "discovery entry budget" in str(error)

    receipt_root = tempfile.mkdtemp(prefix="discovery-receipt-", dir=base)
    receipt_config = os.path.join(receipt_root, ".pre-commit-config.yaml")
    write_file(receipt_config, b"repos: []\n")
    receipt = subject.configs_under(
        receipt_root,
        subject.OperationBudget(subject.OperationDeadline(10)),
    )
    receipt_type_safe = isinstance(receipt, subject.DiscoveryInventory)
    receipt.verify()
    write_file(os.path.join(receipt_root, "late-entry"), b"late\n")
    late_insertion_rejected = False
    try:
        receipt.verify()
    except subject.SetupError as error:
        late_insertion_rejected = "configuration discovery changed" in str(error)

    safe = all(
        (
            count_boundary_accepted,
            count_rejected,
            byte_boundary_accepted,
            bytes_rejected,
            hook_boundary_accepted,
            hook_rejected,
            hook_byte_boundary_accepted,
            hook_bytes_rejected,
            shared_hook_boundary_accepted,
            shared_hook_rejected,
            repository_boundary_accepted,
            repository_rejected,
            runtime_byte_boundary_accepted,
            runtime_bytes_rejected,
            sibling_boundary_accepted,
            sibling_rejected,
            directory_boundary_accepted,
            directory_rejected,
            receipt_type_safe,
            late_insertion_rejected,
        )
    )
    if not safe:
        print(
            "installer aggregate bound was not enforced: count=({},{}), "
            "config_bytes=({},{}), hooks=({},{}), hook_bytes=({},{}), "
            "shared_hooks=({},{}), repositories=({},{}), runtime_bytes=({},{}), "
            "siblings=({},{}), directories=({},{}), "
            "receipt=({},{})".format(
                count_boundary_accepted, count_rejected,
                byte_boundary_accepted, bytes_rejected,
                hook_boundary_accepted, hook_rejected,
                hook_byte_boundary_accepted, hook_bytes_rejected,
                shared_hook_boundary_accepted, shared_hook_rejected,
                repository_boundary_accepted, repository_rejected,
                runtime_byte_boundary_accepted, runtime_bytes_rejected,
                sibling_boundary_accepted, sibling_rejected,
                directory_boundary_accepted, directory_rejected,
                receipt_type_safe, late_insertion_rejected,
            )
        )
        return False

    if not sys.platform.startswith("linux"):
        print("NON_PROOF_SKIP: invocation-wide aggregate budgets require Linux")
        return None

    fixture = os.path.join(base, "install-bin", "pre-commit-fixture")

    def graph(tag, marker_size, repositories=3):
        root = tempfile.mkdtemp(prefix="main-budget-{}-".format(tag), dir=base)
        os.makedirs(os.path.join(root, ".githooks"))
        write_file(
            os.path.join(root, ".githooks", "pre-push"),
            b"#!/bin/sh\nexit 0\n",
            0o755,
        )
        for index in range(repositories):
            repo = root if index == 0 else os.path.join(root, "repo-{}".format(index))
            if index:
                os.mkdir(repo, 0o700)
            initialized = subprocess.run(
                [git, "-c", "init.templateDir=", "init", "-q", repo],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            if initialized.returncode != 0:
                raise RuntimeError(
                    "aggregate main fixture Git init failed: {!r}".format(
                        initialized.stderr
                    )
                )
            hook_types = "pre-push" if index == 0 else "commit-msg"
            config = (
                "# aggregate-main: {}-{}\n"
                "default_install_hook_types: [{}]\n"
                "repos: []\n"
            ).format(tag, index, hook_types).encode("utf-8")
            write_file(os.path.join(repo, ".pre-commit-config.yaml"), config)
            # Empty Git templates deliberately omit the hooks directory.
            os.mkdir(os.path.join(repo, ".git", "hooks"), 0o700)
            write_file(
                os.path.join(repo, ".git", "hooks", "budget-marker"),
                bytes([65 + index]) * marker_size,
            )
        return root

    def invoke(root, timeout, hook_entries, hook_bytes):
        original_emit = subject.emit
        original_entries = subject.MAX_HOOK_ENTRIES
        original_bytes = subject.MAX_HOOK_BYTES
        messages = []
        subject.emit = lambda state, message: messages.append(
            "{} {}".format(state, message)
        )
        subject.MAX_HOOK_ENTRIES = hook_entries
        subject.MAX_HOOK_BYTES = hook_bytes
        try:
            status = subject.main(
                [
                    "--root",
                    root,
                    "--pre-commit",
                    fixture,
                    "--git",
                    git,
                    "--mode",
                    "check",
                    "--expected-version",
                    "3.8.0",
                    "--timeout",
                    str(timeout),
                ]
            )
        finally:
            subject.emit = original_emit
            subject.MAX_HOOK_ENTRIES = original_entries
            subject.MAX_HOOK_BYTES = original_bytes
        return status, "\n".join(messages)

    count_root = graph("count", 1)
    count_status, count_messages = invoke(count_root, 20, 2, 1024 * 1024)
    byte_root = graph("bytes", 32)
    byte_status, byte_messages = invoke(byte_root, 20, 128, 64)
    time_root = graph("deadline", 1, repositories=1)
    time_status, time_messages = invoke(
        time_root, 0.000001, 128, 1024 * 1024
    )
    main_safe = (
        count_status != 0
        and "hook inventory entry budget exceeded" in count_messages
        and byte_status != 0
        and "hook inventory byte budget exceeded" in byte_messages
        and time_status != 0
        and (
            "deadline" in time_messages.lower()
            or "timed out" in time_messages.lower()
        )
    )
    if not main_safe:
        print(
            "main invocation did not share aggregate budgets: "
            "count=({}, {!r}), bytes=({}, {!r}), deadline=({}, {!r})".format(
                count_status,
                count_messages,
                byte_status,
                byte_messages,
                time_status,
                time_messages,
            )
        )
    return main_safe


def main(argv):
    if len(argv) != 5:
        raise SystemExit("usage: harness HELPER MODE BASE GIT")
    helper, mode, base, git = argv[1:]
    subject = load_subject(helper)
    checks = {
        "committed-publication": lambda: committed_publication_behavior(
            subject, base
        ),
        "candidate-receipt-drift": lambda: candidate_receipt_drift_behavior(
            subject, base
        ),
        "publication-commit-window": lambda: publication_commit_window_race_behavior(
            subject, base
        ),
        "processes": lambda: process_group_behavior(subject, base),
        "signals": lambda: signal_cancellation_behavior(subject, base),
        "parent-death": lambda: parent_death_behavior(subject, base),
        "terminal-TERM": lambda: terminal_cancellation_behavior(
            helper, base, git, "SIGTERM"
        ),
        "terminal-HUP": lambda: terminal_cancellation_behavior(
            helper, base, git, "SIGHUP"
        ),
        "terminal-QUIT": lambda: terminal_cancellation_behavior(
            helper, base, git, "SIGQUIT"
        ),
        "teardown-TERM": lambda: teardown_cancellation_behavior(
            subject, base, "SIGTERM"
        ),
        "teardown-HUP": lambda: teardown_cancellation_behavior(
            subject, base, "SIGHUP"
        ),
        "teardown-QUIT": lambda: teardown_cancellation_behavior(
            subject, base, "SIGQUIT"
        ),
        "observer-latch": lambda: observer_exit_latch_behavior(subject),
        "preservation": lambda: directory_preservation_behavior(subject, base),
        "short-write": lambda: short_write_behavior(subject, base, git),
        "single-generation": lambda: single_generation_transaction_behavior(
            subject
        ),
        "descriptors": lambda: descriptor_behavior(subject, base),
        "descriptor-lifecycle": lambda: descriptor_lifecycle_behavior(subject, base),
        "acquisition-failures": lambda: acquisition_failure_behavior(
            subject, base
        ),
        "named-route": lambda: named_route_behavior(subject, base),
        "tool-swap": lambda: tool_swap_behavior(subject, base, git),
        "immutable-snapshot": lambda: immutable_snapshot_behavior(
            subject, base
        ),
        "trusted-route-snapshot": lambda: trusted_route_snapshot_behavior(
            subject, base
        ),
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
        "namespace-nested-cleanup": lambda: (
            namespace_nested_cleanup_capability_behavior(subject)
        ),
        "namespace-root-cleanup": lambda: (
            namespace_root_cleanup_capability_behavior(subject)
        ),
        "namespace-only-scratch": lambda: namespace_only_scratch_behavior(
            subject, base, git
        ),
        "escaped-session": lambda: escaped_session_behavior(subject),
        "generated-install-python": lambda: generated_install_python_behavior(
            subject
        ),
        "trusted-hook-payload": lambda: trusted_hook_payload_behavior(subject, base),
        "sealed-provider-mutation": lambda: sealed_provider_mutation_behavior(
            subject, base
        ),
        "managed-shell-entry": lambda: managed_shell_entry_behavior(subject, base),
        "managed-runtime-descriptor": lambda: managed_runtime_descriptor_behavior(
            subject, base
        ),
        "independent-git-metadata": lambda: independent_git_metadata_behavior(
            subject, base
        ),
        "external-worktree-mounts": lambda: external_worktree_mount_behavior(
            subject, base, git
        ),
        "timeout-sigchld-preflight": lambda: timeout_and_sigchld_preflight_behavior(
            subject, base
        ),
        "aggregate-budgets": lambda: aggregate_budget_behavior(subject, base, git),
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
    result = checks[mode]()
    raise SystemExit(77 if result is None else (0 if result else 1))


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

info "rejected candidates report their live descriptor-bound bytes"
run_red_harness candidate-receipt-drift "$TMP/red-candidate-receipt-drift.out"
red_candidate_receipt_drift_status=$?
if [ "$red_candidate_receipt_drift_status" -eq 0 ]; then
    pass "candidate failure receipts match the preserved object"
else
    sed 's/^/    /' "$TMP/red-candidate-receipt-drift.out" >&2
    fail "candidate failure reported stale pre-mutation evidence"
fi

info "successful forward exchanges remain committed across same-UID races"
run_red_harness publication-commit-window \
    "$TMP/red-publication-commit-window.out"
red_publication_commit_window_status=$?
if [ "$red_publication_commit_window_status" -eq 0 ]; then
    pass "replacement and mutation races cannot be reported as uncommitted"
else
    sed 's/^/    /' "$TMP/red-publication-commit-window.out" >&2
    fail "a commit-window race hid a successful forward exchange"
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

info "SIGTERM, SIGHUP, SIGINT, and SIGQUIT cancel the complete in-flight process group"
run_red_harness signals "$TMP/red-signals.out"
red_signal_status=$?
if [ "$red_signal_status" -eq 0 ]; then
    pass "outer cancellation reaps a leader-exited, signal-ignoring descendant"
else
    sed 's/^/    /' "$TMP/red-signals.out" >&2
    fail "outer cancellation left an in-flight process-group member alive"
fi

info "a child-side Linux parent-death contract covers the pre-bubblewrap window"
run_red_harness parent-death "$TMP/red-parent-death.out"
red_parent_death_status=$?
if [ "$red_parent_death_status" -eq 0 ]; then
    pass "a pre-boundary child is extinct when its supervisor exits"
elif [ "$red_parent_death_status" -eq 77 ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-parent-death.out"; then
    info "SKIP (non-proof): Linux parent-death contract is unavailable on this host"
else
    sed 's/^/    /' "$TMP/red-parent-death.out" >&2
    fail "a pre-boundary child survived its supervisor"
fi

for terminal_signal in TERM HUP QUIT; do
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
    elif boundary_nonproof "$TMP/red-terminal-$terminal_signal.out" && \
        { [ "$red_teardown_status" -eq 0 ] || \
            boundary_nonproof "$TMP/red-teardown-$terminal_signal.out"; }; then
        info "NON_PROOF: $signal_name teardown requires the Linux execution boundary"
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
    pass "sealed configuration writes are exact or fail closed"
else
    sed 's/^/    /' "$TMP/red-short-write.out" >&2
    fail "a short write changed configuration semantics without a failure"
fi

info "hook discovery and environment installation share one namespace run"
run_red_harness single-generation "$TMP/red-single-generation.out"
red_single_generation_status=$?
if [ "$red_single_generation_status" -eq 0 ]; then
    pass "each repository generation is one sealed-input namespace transaction"
else
    sed 's/^/    /' "$TMP/red-single-generation.out" >&2
    fail "generation escaped into host shadow helpers or multiple boundary runs"
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
elif [ "$red_tool_swap_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-tool-swap.out"; then
    info "SKIP (non-proof): immutable tool routing requires Linux containment"
else
    sed 's/^/    /' "$TMP/red-tool-swap.out" >&2
    fail "tool execution re-resolved a mutable path after verification"
fi

info "verified execution snapshots are immutable to their owning UID"
run_red_harness immutable-snapshot "$TMP/red-immutable-snapshot.out"
red_immutable_snapshot_status=$?
if [ "$red_immutable_snapshot_status" -eq 0 ]; then
    pass "verified execution bytes are sealed or the platform fails closed"
else
    sed 's/^/    /' "$TMP/red-immutable-snapshot.out" >&2
    fail "a same-UID writer changed verified execution bytes in place"
fi

info "trusted system routes execute from exact sealed bytes"
run_red_harness trusted-route-snapshot "$TMP/red-trusted-route-snapshot.out"
red_trusted_route_snapshot_status=$?
if [ "$red_trusted_route_snapshot_status" -eq 0 ]; then
    pass "root-owned path trust does not replace exact-byte execution"
elif [ "$red_trusted_route_snapshot_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-trusted-route-snapshot.out"; then
    info "SKIP (non-proof): trusted-route snapshots require Linux containment"
else
    sed 's/^/    /' "$TMP/red-trusted-route-snapshot.out" >&2
    fail "a verified system route was reopened by pathname at execution"
fi

info "a verified script cannot select replacement interpreter bytes"
run_red_harness interpreter-swap "$TMP/red-interpreter-swap.out"
red_interpreter_swap_status=$?
if [ "$red_interpreter_swap_status" -eq 0 ]; then
    pass "script execution remains bound to the verified interpreter bytes"
elif [ "$red_interpreter_swap_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-interpreter-swap.out"; then
    info "SKIP (non-proof): interpreter swaps require Linux containment"
else
    sed 's/^/    /' "$TMP/red-interpreter-swap.out" >&2
    fail "script execution re-resolved a mutable shebang after verification"
fi

info "an executing child cannot replace its verified executable copy"
run_red_harness execution-copy-write "$TMP/red-execution-copy-write.out"
red_execution_copy_write_status=$?
if [ "$red_execution_copy_write_status" -eq 0 ]; then
    pass "the executable copy remains read-only for its complete child lifetime"
elif [ "$red_execution_copy_write_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-execution-copy-write.out"; then
    info "SKIP (non-proof): executable-copy writes require Linux containment"
else
    sed 's/^/    /' "$TMP/red-execution-copy-write.out" >&2
    fail "a child changed its executable copy and ran replacement bytes"
fi

info "an executing child cannot replace the verified git copy on PATH"
run_red_harness transitive-copy-write "$TMP/red-transitive-copy-write.out"
red_transitive_copy_write_status=$?
if [ "$red_transitive_copy_write_status" -eq 0 ]; then
    pass "the transitive git copy remains read-only for the child lifetime"
elif [ "$red_transitive_copy_write_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-transitive-copy-write.out"; then
    info "SKIP (non-proof): transitive-copy writes require Linux containment"
else
    sed 's/^/    /' "$TMP/red-transitive-copy-write.out" >&2
    fail "a child changed the git copy on PATH and ran replacement bytes"
fi

info "the execution boundary makes the host read-only and owns all descendants"
run_red_harness boundary-policy "$TMP/red-boundary-policy.out"
red_boundary_policy_status=$?
if [ "$red_boundary_policy_status" -eq 0 ]; then
    pass "the Linux boundary exposes only tmpfs scratch and read-only host bindings"
else
    sed 's/^/    /' "$TMP/red-boundary-policy.out" >&2
    fail "the execution boundary left host writes or session escape available"
fi

info "a configured tool cannot mutate its verified runtime dependency"
run_red_harness runtime-host-write "$TMP/red-runtime-host-write.out"
red_runtime_host_write_status=$?
if [ "$red_runtime_host_write_status" -eq 0 ]; then
    pass "runtime dependencies remain unchanged or execution fails closed"
elif [ "$red_runtime_host_write_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-runtime-host-write.out"; then
    info "SKIP (non-proof): runtime-host writes require Linux containment"
else
    sed 's/^/    /' "$TMP/red-runtime-host-write.out" >&2
    fail "configured execution changed a host runtime dependency"
fi

info "an imported runtime sibling cannot swap after immutable binding"
run_red_harness runtime-sibling-swap "$TMP/red-runtime-sibling-swap.out"
red_runtime_sibling_swap_status=$?
if [ "$red_runtime_sibling_swap_status" -eq 0 ]; then
    pass "runtime siblings execute from immutable copies and source swaps fail closed"
elif [ "$red_runtime_sibling_swap_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-runtime-sibling-swap.out"; then
    info "SKIP (non-proof): runtime-sibling swaps require Linux containment"
else
    sed 's/^/    /' "$TMP/red-runtime-sibling-swap.out" >&2
    fail "an imported runtime sibling selected bytes from a mutable source route"
fi

info "nested scratch has no host-side last-operation cleanup capability"
run_red_harness namespace-nested-cleanup \
    "$TMP/red-namespace-nested-cleanup.out"
red_namespace_nested_cleanup_status=$?
if [ "$red_namespace_nested_cleanup_status" -eq 0 ]; then
    pass "nested cleanup cannot remove a same-UID host replacement"
else
    sed 's/^/    /' "$TMP/red-namespace-nested-cleanup.out" >&2
    fail "nested scratch retained a pathname-selected final cleanup operation"
fi

info "managed scratch roots have no host-side last-operation cleanup capability"
run_red_harness namespace-root-cleanup \
    "$TMP/red-namespace-root-cleanup.out"
red_namespace_root_cleanup_status=$?
if [ "$red_namespace_root_cleanup_status" -eq 0 ]; then
    pass "managed roots are reclaimed only with their private namespace"
else
    sed 's/^/    /' "$TMP/red-namespace-root-cleanup.out" >&2
    fail "managed scratch retained a pathname-selected root cleanup operation"
fi

info "live generation leaves no host scratch or pathname cleanup target"
run_red_harness namespace-only-scratch "$TMP/red-namespace-only-scratch.out"
red_namespace_only_scratch_status=$?
if [ "$red_namespace_only_scratch_status" -eq 0 ]; then
    pass "scratch teardown is kernel-owned and host final-name hooks are unreachable"
elif grep -q '^BOUNDARY_UNAVAILABLE:' "$TMP/red-namespace-only-scratch.out"; then
    if [ "$HOST_KERNEL" = Linux ]; then
        sed 's/^/    /' "$TMP/red-namespace-only-scratch.out" >&2
        fail "authoritative Linux mode lacked its required namespace boundary"
    else
        info "SKIP (non-proof): namespace containment is unavailable on $HOST_KERNEL"
    fi
else
    sed 's/^/    /' "$TMP/red-namespace-only-scratch.out" >&2
    fail "live main allocated host scratch or reached pathname-selected cleanup"
fi

info "setsid and double-fork descendants cannot outlive execution containment"
run_red_harness escaped-session "$TMP/red-escaped-session.out"
red_escaped_session_status=$?
if [ "$red_escaped_session_status" -eq 0 ]; then
    pass "escaped sessions are extinct before the execution boundary returns"
elif grep -q '^BOUNDARY_UNAVAILABLE:' "$TMP/red-escaped-session.out"; then
    if [ "$HOST_KERNEL" = Linux ]; then
        sed 's/^/    /' "$TMP/red-escaped-session.out" >&2
        fail "authoritative Linux mode lacked its required extinction boundary"
    else
        info "SKIP (non-proof): descendant extinction is unavailable on $HOST_KERNEL"
    fi
else
    sed 's/^/    /' "$TMP/red-escaped-session.out" >&2
    fail "a detached session survived the execution boundary"
fi

info "generated hooks publish only installer-owned provenance metadata"
run_red_harness generated-install-python "$TMP/red-generated-install-python.out"
red_generated_install_python_status=$?
if [ "$red_generated_install_python_status" -eq 0 ]; then
    pass "metacharacter paths are encoded and candidate runtime text is discarded"
else
    sed 's/^/    /' "$TMP/red-generated-install-python.out" >&2
    fail "candidate-generated runtime shell text reached publication"
fi

info "installed hooks carry immutable trusted config and policy payloads"
run_red_harness trusted-hook-payload "$TMP/red-trusted-hook-payload.out"
red_trusted_hook_payload_status=$?
if [ "$red_trusted_hook_payload_status" -eq 0 ]; then
    pass "candidate config and policy replacement cannot redirect the installed hook"
else
    sed 's/^/    /' "$TMP/red-trusted-hook-payload.out" >&2
    fail "installed hook retained candidate config or policy authority"
fi

info "post-bind mutation cannot change selected provider bytes"
run_red_harness sealed-provider-mutation \
    "$TMP/red-sealed-provider-mutation.out"
red_sealed_provider_status=$?
if [ "$red_sealed_provider_status" -eq 0 ]; then
    pass "installed runtime executes an immutable provider snapshot"
elif [ "$red_sealed_provider_status" -eq 77 ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-sealed-provider-mutation.out"; then
    info "SKIP (non-proof): immutable provider execution requires Linux"
else
    sed 's/^/    /' "$TMP/red-sealed-provider-mutation.out" >&2
    fail "installed runtime selected mutable provider bytes"
fi

info "installed managed hooks have no ambient pre-verification shell boundary"
run_red_harness managed-shell-entry "$TMP/red-managed-shell-entry.out"
red_managed_shell_entry_status=$?
if [ "$red_managed_shell_entry_status" -eq 0 ]; then
    pass "managed hooks enter through fixed privileged Bash before verification"
elif [ "$red_managed_shell_entry_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-managed-shell-entry.out"; then
    info "SKIP (non-proof): installed managed shell boundary requires Linux"
else
    sed 's/^/    /' "$TMP/red-managed-shell-entry.out" >&2
    fail "managed hooks retained ambient shell authority before verification"
fi

info "installed managed hooks execute the bound interpreter with scrubbed Git state"
run_red_harness managed-runtime-descriptor \
    "$TMP/red-managed-runtime-descriptor.out"
red_managed_runtime_descriptor_status=$?
if [ "$red_managed_runtime_descriptor_status" -eq 0 ]; then
    pass "managed hooks preserve the alternate index without ambient Git authority"
elif [ "$red_managed_runtime_descriptor_status" -eq 77 ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-managed-runtime-descriptor.out"; then
    info "SKIP (non-proof): managed immutable runtime requires Linux"
else
    sed 's/^/    /' "$TMP/red-managed-runtime-descriptor.out" >&2
    fail "managed hooks reopened an interpreter path or retained ambient Git state"
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

info "external worktree metadata is mounted for every selected Git call"
run_red_harness external-worktree-mounts "$TMP/red-external-worktree-mounts.out"
red_external_worktree_mounts_status=$?
if [ "$red_external_worktree_mounts_status" -eq 0 ]; then
    pass "external gitdir and common-dir routes stay visible inside containment"
elif [ "$red_external_worktree_mounts_status" -eq 77 ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-external-worktree-mounts.out"; then
    info "SKIP (non-proof): external-worktree containment requires Linux"
else
    sed 's/^/    /' "$TMP/red-external-worktree-mounts.out" >&2
    fail "selected Git lost the independently bound external worktree metadata"
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

info "installer enumeration shares one deadline and aggregate count/byte bounds"
run_red_harness aggregate-budgets "$TMP/red-aggregate-budgets.out"
red_aggregate_budget_status=$?
if [ "$red_aggregate_budget_status" -eq 0 ]; then
    pass "late boundary+1 entries and bytes fail within one operation deadline"
elif [ "$red_aggregate_budget_status" -eq 77 ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-aggregate-budgets.out" && \
    [ "$HOST_KERNEL" != Linux ]; then
    info "SKIP (non-proof): invocation-wide aggregate budgets require Linux"
else
    sed 's/^/    /' "$TMP/red-aggregate-budgets.out" >&2
    fail "installer parent aggregation remained unbounded"
fi

info "Pixi-owned providers execute only from authenticated immutable closures"
run_red_harness untrusted-interpreter "$TMP/red-untrusted-interpreter.out"
red_untrusted_interpreter_status=$?
if [ "$red_untrusted_interpreter_status" -eq 0 ]; then
    pass "the exact Pixi provider and transitive import closure are sealed"
elif [ "$red_untrusted_interpreter_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-untrusted-interpreter.out"; then
    info "SKIP (non-proof): sealed Pixi provider execution requires Linux"
else
    sed 's/^/    /' "$TMP/red-untrusted-interpreter.out" >&2
    fail "the Pixi provider retained mutable or incomplete import authority"
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
elif [ "$red_external_write_channels_status" -eq 77 ] && \
    [ "$HOST_KERNEL" != Linux ] && \
    grep -q '^NON_PROOF_SKIP:' "$TMP/red-external-write-channels.out"; then
    info "SKIP (non-proof): external-channel containment requires Linux"
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
# The child shell, not this suite, owns these positional expansions.
# shellcheck disable=SC2016
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
# The child shell, not this suite, owns these positional expansions.
# shellcheck disable=SC2016
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
elif boundary_nonproof "$TMP/sourced-prime.out"; then
    info "NON_PROOF: sourced installer execution requires the Linux boundary"
else
    sed 's/^/    /' "$TMP/sourced-success.out" >&2
    sed 's/^/    /' "$TMP/sourced-failure.out" >&2
    fail "sourced installer control flow or failure accounting was lost"
fi

summary
exit_code
