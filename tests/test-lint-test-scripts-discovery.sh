#!/usr/bin/env bash
# Behavior tests for exact staged Bash-test discovery and syntax validation.
set -uo pipefail

SCRIPT_DIR="$(CDPATH='' command cd -P -- "${BASH_SOURCE[0]%/*}" && command pwd -P)"
ROOT="$(CDPATH='' command cd -P -- "$SCRIPT_DIR/.." && command pwd -P)"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

TMP_PREFIX="${TMPDIR:-/tmp}/odysseus-test-lint-discovery."
if ! TMP_ROOT="$(mktemp -d "${TMP_PREFIX}XXXXXX")"; then
    printf '%s\n' 'ERROR: could not create the test fixture directory' >&2
    exit 2
fi
TMP_ROOT="$(CDPATH='' command cd -P -- "$TMP_ROOT" && command pwd -P)"
trap 'printf "NOTE: preserving exact test fixture for safe external cleanup: %s\n" "$TMP_ROOT" >&2' EXIT

new_repository() {
    local name=$1
    local repository="$TMP_ROOT/$name"
    mkdir -p "$repository"
    /usr/bin/git -C "$repository" init -q
    printf '%s\n' "$repository"
}

stage_text() {
    local repository=$1 path=$2 body=$3 parent
    parent=${path%/*}
    if [ "$parent" != "$path" ]; then
        mkdir -p "$repository/$parent"
    fi
    printf '%s' "$body" >"$repository/$path"
    /usr/bin/git -C "$repository" add -- "$path"
}

run_checker() {
    local repository=$1
    shift
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
        /usr/bin/python3 -I -S "$ROOT/scripts/lint_test_scripts.py" \
        --repo-root "$repository" "$@"
}

CASE_NUMBER=0
expect_status() {
    local name=$1 repository=$2 expected=$3 diagnostic=$4
    CASE_NUMBER=$((CASE_NUMBER + 1))
    local output="$TMP_ROOT/case-$CASE_NUMBER.out" status=0
    if run_checker "$repository" >"$output" 2>&1; then
        status=0
    else
        status=$?
    fi
    if [ "$status" -ne "$expected" ]; then
        sed -n '1,20p' "$output" >&2
        fail "$name returned $status instead of $expected"
    elif [ "$diagnostic" != - ] && ! grep -Fq "$diagnostic" "$output"; then
        sed -n '1,20p' "$output" >&2
        fail "$name omitted its fail-closed diagnostic"
    else
        pass "$name"
    fi
}

info "exact staged Bash syntax behavior"
repo="$(new_repository valid)"
stage_text "$repo" tests/short-valid.sh $'#!/usr/bin/env bash\n:\n'
expect_status "accepts a short valid Bash test" "$repo" 0 \
    "all 1 test script(s) are well-formed"

repo="$(new_repository bin-bash)"
stage_text "$repo" tests/bin-bash.sh $'#!/bin/bash\n:\n'
expect_status "accepts the supported /bin/bash shebang" "$repo" 0 -

repo="$(new_repository malformed)"
stage_text "$repo" tests/malformed.sh \
    $'#!/usr/bin/env bash\nif true; then\n    :\n'
expect_status "rejects malformed Bash" "$repo" 1 \
    "fails Bash syntax validation"

repo="$(new_repository missing-shebang)"
stage_text "$repo" tests/missing-shebang.sh $':\n'
expect_status "rejects a missing shebang" "$repo" 1 \
    "line 1 is not a supported Bash shebang"

repo="$(new_repository wrong-shebang)"
stage_text "$repo" tests/wrong-shebang.sh $'#!/bin/sh\n:\n'
expect_status "rejects a non-Bash shebang" "$repo" 1 \
    "line 1 is not a supported Bash shebang"

repo="$(new_repository nested-e2e)"
stage_text "$repo" e2e/test-suite/nested.sh $'#!/usr/bin/env bash\nif true; then\n'
expect_status "ignores nested e2e non-candidates" "$repo" 0 \
    "no test scripts discovered"

repo="$(new_repository nested-tests)"
stage_text "$repo" tests/deep/nested/malformed.sh \
    $'#!/usr/bin/env bash\nif true; then\n'
expect_status "checks nested tests paths" "$repo" 1 \
    "fails Bash syntax validation"

info "only exact staged regular blobs are authoritative"
repo="$(new_repository staged)"
stage_text "$repo" tests/staged.sh $'#!/usr/bin/env bash\n:\n'
printf '%s\n' '#!/usr/bin/env bash' 'if true; then' >"$repo/tests/staged.sh"
expect_status "ignores mutable unstaged worktree bytes" "$repo" 0 -

repo="$(new_repository symlink)"
mkdir -p "$repo/tests"
printf '%s\n' '#!/usr/bin/env bash' ':' >"$repo/target"
ln -s ../target "$repo/tests/linked.sh"
/usr/bin/git -C "$repo" add -- tests/linked.sh
expect_status "rejects a tracked symlink" "$repo" 2 \
    "not a regular blob"

repo="$(new_repository newline)"
newline_path="$(printf 'tests/valid\nbroken.sh')"
stage_text "$repo" "$newline_path" $'#!/usr/bin/env bash\nif true; then\n'
expect_status "keeps newline-bearing names as one inventory entry" "$repo" 1 \
    "fails Bash syntax validation"

repo="$(new_repository missing-object)"
missing_oid=1111111111111111111111111111111111111111
/usr/bin/git -C "$repo" update-index --info-only --add \
    --cacheinfo "100755,$missing_oid,tests/missing.sh"
expect_status "rejects a missing staged object" "$repo" 2 \
    "trusted Git command failed"

repo="$(new_repository oversized)"
mkdir -p "$repo/tests"
/usr/bin/python3 -I -S - "$repo/tests/oversized.sh" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"#!/bin/bash\n" + b"#" * 1_048_576)
PY
/usr/bin/git -C "$repo" add -- tests/oversized.sh
expect_status "rejects an oversized staged test" "$repo" 2 \
    "1048576-byte limit"

info "ambient executables cannot influence inventory or syntax parsing"
repo="$(new_repository ambient)"
stage_text "$repo" tests/safe.sh $'#!/usr/bin/env bash\n:\n'
mkdir -p "$TMP_ROOT/bin"
canary="$TMP_ROOT/ambient-tool-ran"
for tool in git bash; do
    cat >"$TMP_ROOT/bin/$tool" <<EOF
#!/bin/sh
printf executed >'$canary'
exit 0
EOF
    chmod +x "$TMP_ROOT/bin/$tool"
done
if PATH="$TMP_ROOT/bin:/usr/bin:/bin" run_checker "$repo" \
    >"$TMP_ROOT/ambient.out" 2>&1 \
    && grep -Fq "all 1 test script(s) are well-formed" \
        "$TMP_ROOT/ambient.out" \
    && [ ! -e "$canary" ]; then
    pass "uses fixed Git and Bash executables"
else
    fail "ambient Git or Bash influenced test-script validation"
fi

summary
exit_code
