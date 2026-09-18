#!/usr/bin/env bash
# Verify that pre-commit path filters select the intended source files.
set -euo pipefail

if ! ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd); then
    printf 'ERROR: could not resolve the repository root\n' >&2
    exit 1
fi
if ! PRE_COMMIT_BIN=$(command -v pre-commit); then
    printf 'ERROR: pre-commit is required for path-selection tests\n' >&2
    exit 1
fi
if ! REAL_GIT=$(command -v git); then
    printf 'ERROR: git is required for path-selection tests\n' >&2
    exit 1
fi
fixture_prefix="${TMPDIR:-/tmp}/odysseus-precommit-selection."
MKTEMP_BIN="${ODYSSEUS_TEST_MKTEMP:-}"
if [ -z "$MKTEMP_BIN" ]; then
    if ! MKTEMP_BIN=$(command -v mktemp); then
        printf 'ERROR: mktemp is required for path-selection tests\n' >&2
        exit 1
    fi
fi
TMP_ROOT=""
if [ ! -x "$MKTEMP_BIN" ] \
   || ! TMP_ROOT=$("$MKTEMP_BIN" -d "${fixture_prefix}XXXXXX"); then
    printf 'ERROR: could not create the pre-commit selection fixture\n' >&2
    exit 1
fi
fixture_suffix="${TMP_ROOT#"$fixture_prefix"}"
if [ "$fixture_suffix" = "$TMP_ROOT" ] || [ -z "$fixture_suffix" ] \
   || [ ! -d "$TMP_ROOT" ] || [ -L "$TMP_ROOT" ]; then
    printf 'ERROR: mktemp returned an unsafe pre-commit selection fixture: %s\n' \
        "$TMP_ROOT" >&2
    exit 1
fi
case "$fixture_suffix" in
    *[!A-Za-z0-9]*)
        printf 'ERROR: mktemp returned an unsafe pre-commit selection fixture: %s\n' \
            "$TMP_ROOT" >&2
        exit 1
        ;;
esac

cleanup_test_root() {
    cleanup_status=$1
    trap - EXIT
    if ! rm -rf -- "$TMP_ROOT"; then
        printf 'ERROR: failed to remove pre-commit selection fixture: %s\n' \
            "$TMP_ROOT" >&2
        if [ "$cleanup_status" -eq 0 ]; then
            cleanup_status=1
        fi
    fi
    exit "$cleanup_status"
}
trap 'cleanup_test_root "$?"' EXIT

TEST_HOME="$TMP_ROOT/home"
REPO_ROOT="$TMP_ROOT/repo"
mkdir -m 700 "$TEST_HOME" "$TMP_ROOT/tmp"
mkdir "$REPO_ROOT"

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

fixture_git -C "$REPO_ROOT" init -q
fixture_git -C "$REPO_ROOT" config user.email test@example.invalid
fixture_git -C "$REPO_ROOT" config user.name "Pre-commit Selection Test"
cp "$ROOT/.pre-commit-config.yaml" "$REPO_ROOT/.pre-commit-config.yaml"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }

run_marker_hook() {
    local git_variable
    relative_path=$1
    marker=$2
    output_path=$3
    mkdir -p "$REPO_ROOT/$(dirname "$relative_path")"
    printf '%s\n' "$marker" > "$REPO_ROOT/$relative_path"
    (
        cd "$REPO_ROOT" || exit 99
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 \
            HOME="$TEST_HOME" \
            LC_ALL=C \
            PATH="$PATH" \
            PRE_COMMIT_HOME="$TMP_ROOT/pre-commit-home" \
            TMPDIR="$TMP_ROOT/tmp" \
            "$PRE_COMMIT_BIN" run --color never \
            forbid-merge-conflict-markers --files "$relative_path"
    ) > "$output_path" 2>&1
}

run_binary_marker_hook() {
    local git_variable
    relative_path=$1
    output_path=$2
    mkdir -p "$REPO_ROOT/$(dirname "$relative_path")"
    printf '\000<<<<<<< test-branch\n' > "$REPO_ROOT/$relative_path"
    (
        cd "$REPO_ROOT" || exit 99
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 \
            HOME="$TEST_HOME" \
            LC_ALL=C \
            PATH="$PATH" \
            PRE_COMMIT_HOME="$TMP_ROOT/pre-commit-home" \
            TMPDIR="$TMP_ROOT/tmp" \
            "$PRE_COMMIT_BIN" run --color never \
            forbid-merge-conflict-markers --files "$relative_path"
    ) > "$output_path" 2>&1
}

printf '\n== merge-marker hook selected paths ==\n'
for selected_path in \
    scripts/example.sh \
    scripts/example.bash \
    tools/example.py \
    docs/example.md \
    configs/example.yml \
    configs/example.yaml \
    data/example.json \
    configs/example.hcl \
    justfile \
    tools/Justfile \
    pixi.toml \
    Dockerfile \
    images/Dockerfile.dev \
    .gitmodules \
    Makefile \
    src/example.txt \
    src/main.c \
    src/main.cc \
    src/main.cpp \
    src/main.cxx \
    include/main.h \
    include/main.hpp; do
    case_name=${selected_path//\//-}
    if run_marker_hook "$selected_path" '<<<<<<< test-branch' "$TMP_ROOT/$case_name.out"; then
        fail "merge-marker hook skipped selected path $selected_path"
    elif grep -Fq "forbid unresolved merge-conflict markers" \
        "$TMP_ROOT/$case_name.out" \
        && grep -Fq "Failed" "$TMP_ROOT/$case_name.out"; then
        pass "merge-marker hook selects $selected_path"
    else
        sed -n '1,20p' "$TMP_ROOT/$case_name.out" >&2
        fail "merge-marker hook failed without checking $selected_path"
    fi
done

printf '\n== merge-marker hook rejects each marker form in first-party hooks ==\n'
for marker_form in \
    '<<<<<<< test-branch' \
    '=======' \
    '>>>>>>> main'; do
    case_name=${marker_form//[^A-Za-z0-9]/-}
    if run_marker_hook .githooks/check.sh "$marker_form" "$TMP_ROOT/githooks-$case_name.out"; then
        fail "merge-marker hook skipped $marker_form in .githooks/check.sh"
    elif grep -Fq "forbid unresolved merge-conflict markers" \
        "$TMP_ROOT/githooks-$case_name.out" \
        && grep -Fq "Failed" "$TMP_ROOT/githooks-$case_name.out"; then
        pass "merge-marker hook rejects $marker_form in .githooks/check.sh"
    else
        sed -n '1,20p' "$TMP_ROOT/githooks-$case_name.out" >&2
        fail "merge-marker hook failed without checking $marker_form in .githooks/check.sh"
    fi
done

printf '\n== merge-marker hook rejected paths ==\n'
for rejected_path in \
    agentic/check.py \
    control/check.py \
    infrastructure/check.cpp \
    provisioning/check.toml \
    ci-cd/Dockerfile \
    research/Makefile \
    shared/check.h \
    testing/check.yaml; do
    case_name=${rejected_path//\//-}
    if run_marker_hook "$rejected_path" '<<<<<<< test-branch' "$TMP_ROOT/$case_name.out"; then
        pass "merge-marker hook rejects $rejected_path from its input set"
    else
        sed -n '1,20p' "$TMP_ROOT/$case_name.out" >&2
        fail "merge-marker hook selected rejected path $rejected_path"
    fi
done

if run_binary_marker_hook "assets/example.bin" "$TMP_ROOT/binary.out"; then
    pass "merge-marker hook rejects binary data from its text input set"
else
    sed -n '1,20p' "$TMP_ROOT/binary.out" >&2
    fail "merge-marker hook selected binary data"
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'PRE_COMMIT_CONFIG_SELECTION_TESTS_COMPLETE\n'
