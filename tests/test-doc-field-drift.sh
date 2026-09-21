#!/usr/bin/env bash
# Behavior test for the first-party documentation field-drift guard.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"

fixture_git() {
    local repository=$1
    shift
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
        HOME=/nonexistent XDG_CONFIG_HOME=/nonexistent \
        GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_SYSTEM=/dev/null \
        GIT_CONFIG_GLOBAL=/dev/null GIT_OPTIONAL_LOCKS=0 \
        GIT_NO_REPLACE_OBJECTS=1 GIT_NO_LAZY_FETCH=1 \
        /usr/bin/git --no-replace-objects \
        -c core.fsmonitor=false -c core.hooksPath=/dev/null \
        -C "$repository" "$@"
}

TMP_PREFIX="${TMPDIR:-/tmp}/odysseus-doc-field-drift."
TMP=""
TMP_VALID=false

make_fixture_directory() {
    local created suffix
    if ! created="$(mktemp -d "${TMP_PREFIX}XXXXXX")"; then
        return 1
    fi
    suffix="${created#"$TMP_PREFIX"}"
    if [ -z "$created" ] || [ "$suffix" = "$created" ] || [ -z "$suffix" ] \
        || [ ! -d "$created" ] || [ -L "$created" ]; then
        return 1
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*) return 1 ;;
    esac
    printf '%s\n' "$created"
}

cleanup_fixture() {
    [ "$TMP_VALID" = true ] || return
    printf 'NOTE: preserving exact test fixture for safe external cleanup: %s\n' \
        "$TMP" >&2
}

if ! TMP="$(make_fixture_directory)"; then
    printf '%s\n' 'ERROR: could not create a safe doc-field fixture' >&2
    exit 1
fi
TMP_VALID=true
trap cleanup_fixture EXIT

cat > "$TMP/no-mapfile.bash" <<'EOF'
if enable -n mapfile 2>/dev/null; then
    :
fi
EOF

info "documentation drift validation works without the Bash 4 mapfile builtin"
CHECKER_SHELL="${ODYSSEUS_TEST_SHELL:-/bin/bash}"
if env BASH_ENV="$TMP/no-mapfile.bash" \
    "$CHECKER_SHELL" -c 'type mapfile >/dev/null 2>&1'; then
    fail "test fixture did not disable the mapfile builtin"
fi

info "the wrapper ignores hostile Python import environment"
mkdir -p "$TMP/pythonpath"
PYTHON_CANARY="$TMP/python-sitecustomize-ran"
cat >"$TMP/pythonpath/sitecustomize.py" <<'PY'
import os
from pathlib import Path
Path(os.environ["ODYSSEUS_PYTHON_CANARY"]).write_text(
    "executed", encoding="utf-8"
)
PY
if env PYTHONPATH="$TMP/pythonpath" ODYSSEUS_PYTHON_CANARY="$PYTHON_CANARY" \
    "$ROOT/scripts/check-doc-field-drift.sh" >"$TMP/python-env.out" 2>&1 \
    && grep -Fq 'check-doc-field-drift: OK' "$TMP/python-env.out" \
    && [ ! -e "$PYTHON_CANARY" ]; then
    pass "hostile Python import state cannot run before the checker"
else
    fail "ambient Python import state influenced the checker"
fi
if env BASH_ENV="$TMP/no-mapfile.bash" \
    "$CHECKER_SHELL" "$ROOT/scripts/check-doc-field-drift.sh" \
    > "$TMP/output" 2>&1; then
    if grep -Fq \
        'check-doc-field-drift: OK — no deprecated workflow field names' \
        "$TMP/output"; then
        pass "clean first-party documentation is checked without mapfile"
    else
        fail "drift checker exited zero without its completion receipt"
    fi
else
    sed -n '1,20p' "$TMP/output" >&2
    fail "drift checker requires a Bash builtin absent from supported hosts"
fi

FIXTURE_REPO="$TMP/exact-repo"
mkdir -p "$TMP/bin" "$FIXTURE_REPO"
FIXTURE_REPO="$(CDPATH='' command cd -P -- "$FIXTURE_REPO" && command pwd -P)"
fixture_git "$FIXTURE_REPO" init -q --object-format=sha1
fixture_git "$FIXTURE_REPO" config user.name 'Odysseus Test'
fixture_git "$FIXTURE_REPO" config user.email 'odysseus-test@example.invalid'
printf '%s\n' '# Safe documentation' 'subject: current' \
    >"$FIXTURE_REPO/safe.md"
fixture_git "$FIXTURE_REPO" add -- safe.md

run_exact_checker() {
    /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
        /usr/bin/python3 -I -S "$ROOT/scripts/check_doc_field_drift.py" \
        --repo-root "$FIXTURE_REPO"
}

info "a missing staged object cannot become a successful drift receipt"
MISSING_OID=1111111111111111111111111111111111111111
fixture_git "$FIXTURE_REPO" update-index --info-only --add \
    --cacheinfo "100644,$MISSING_OID,missing.md"
if run_exact_checker >"$TMP/missing-output" 2>&1; then
    fail "a missing staged document was reported as drift-free"
elif grep -Fq \
    'check-doc-field-drift: OK — no deprecated workflow field names' \
    "$TMP/missing-output"; then
    fail "failure output included a false completion receipt"
else
    pass "missing staged document data prevents a successful receipt"
fi
fixture_git "$FIXTURE_REPO" update-index --force-remove -- missing.md

info "a promised missing blob cannot invoke a repository-selected transport"
PROMISOR_REPO="$TMP/promisor-repo"
mkdir -p "$PROMISOR_REPO"
PROMISOR_REPO="$(CDPATH='' command cd -P -- "$PROMISOR_REPO" && command pwd -P)"
fixture_git "$PROMISOR_REPO" init -q --object-format=sha1
PROMISOR_HELPER="$TMP/promisor-helper.sh"
PROMISOR_CANARY="$TMP/promisor-helper-ran"
cat >"$PROMISOR_HELPER" <<EOF
#!/bin/sh
printf executed >'$PROMISOR_CANARY'
exit 1
EOF
chmod +x "$PROMISOR_HELPER"
fixture_git "$PROMISOR_REPO" config extensions.partialClone origin
fixture_git "$PROMISOR_REPO" config remote.origin.promisor true
fixture_git "$PROMISOR_REPO" config remote.origin.partialCloneFilter blob:none
fixture_git "$PROMISOR_REPO" config remote.origin.url "ext::$PROMISOR_HELPER"
fixture_git "$PROMISOR_REPO" config protocol.ext.allow always
fixture_git "$PROMISOR_REPO" update-index --info-only --add \
    --cacheinfo "100644,$MISSING_OID,promised.md"
if /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    /usr/bin/python3 -I -S "$ROOT/scripts/check_doc_field_drift.py" \
    --repo-root "$PROMISOR_REPO" >"$TMP/promisor.out" 2>&1; then
    fail "a missing promised object was reported as drift-free"
elif [ -e "$PROMISOR_CANARY" ]; then
    fail "repository config invoked a transport while reading staged data"
else
    pass "lazy object transport remains disabled during validation"
fi

printf '%s\n' 'tasks:' '  - title: stale-field' > "$FIXTURE_REPO/stale.md"
fixture_git "$FIXTURE_REPO" add -- stale.md
info "a deprecated workflow key remains a hard validation failure"
if run_exact_checker >"$TMP/drift-output" 2>&1; then
    fail "a deprecated workflow key was reported as drift-free"
elif grep -Fq \
    'ERROR: deprecated workflow field name(s) found' \
    "$TMP/drift-output"; then
    pass "deprecated workflow keys fail with the drift diagnostic"
else
    sed -n '1,20p' "$TMP/drift-output" >&2
    fail "deprecated workflow key failed without the drift diagnostic"
fi
fixture_git "$FIXTURE_REPO" reset -q -- stale.md

info "the exact-index checker ignores ambient Git executables"
CANARY="$TMP/ambient-git-ran"
cat >"$TMP/bin/git" <<EOF
#!/usr/bin/env bash
touch '$CANARY'
exit 0
EOF
chmod +x "$TMP/bin/git"
if PATH="$TMP/bin:/usr/bin:/bin" run_exact_checker \
    >"$TMP/exact-clean.out" 2>&1 \
    && grep -Fq 'check-doc-field-drift: OK' "$TMP/exact-clean.out" \
    && [ ! -e "$CANARY" ]; then
    pass "documentation inventory uses the trusted Git executable"
else
    fail "ambient Git influenced the exact documentation inventory"
fi

info "NUL-delimited tracked names cannot split or hide a deprecated field"
NEWLINE_DOC="$(printf 'safe\nstale.md')"
printf '%s\n' '  - title: stale-field' >"$FIXTURE_REPO/$NEWLINE_DOC"
fixture_git "$FIXTURE_REPO" add -- "$NEWLINE_DOC"
if run_exact_checker >"$TMP/newline.out" 2>&1; then
    fail "a newline-bearing tracked path hid deprecated field drift"
elif grep -Fq 'deprecated workflow field name(s) found' "$TMP/newline.out"; then
    pass "newline-bearing tracked paths remain one exact inventory entry"
else
    fail "newline-bearing path failed without the drift diagnostic"
fi
fixture_git "$FIXTURE_REPO" rm -q --cached -- "$NEWLINE_DOC"

info "non-workflow API title fields remain valid"
printf '%s\n' '```json' '{"schema":"hi/nestor/intake-request/v1",' \
    '"intakeId":"example","workRepository":"HomericIntelligence/Odysseus",' \
    '"title": "Valid API title", "body":"Example"}' '```' >"$FIXTURE_REPO/intake.md"
printf '%s\n' '```json' '{"event":"task.created","timestamp":"example","data":{' \
    '"task_id":"example","team_id":"example",' '"title": "Valid event title",' \
    '"description":"Example","status":"backlog","assigned_to":null}}' '```' \
    >"$FIXTURE_REPO/event.md"
fixture_git "$FIXTURE_REPO" add -- intake.md event.md
if run_exact_checker >"$TMP/api-title.out" 2>&1; then
    pass "known non-workflow API title fields are accepted"
else
    fail "valid API title fields were reported as workflow drift"
fi
fixture_git "$FIXTURE_REPO" rm -q --cached -- intake.md event.md

info "quoted deprecated workflow keys remain rejected"
printf '%s\n' '- "title" : stale-field' >"$FIXTURE_REPO/quoted.md"
fixture_git "$FIXTURE_REPO" add -- quoted.md
if run_exact_checker >"$TMP/quoted.out" 2>&1; then
    fail "a quoted deprecated workflow key was accepted"
elif grep -Fq 'ERROR: deprecated workflow field name(s) found' "$TMP/quoted.out"; then
    pass "quoted deprecated workflow keys fail with the drift diagnostic"
else
    fail "quoted workflow drift failed without its diagnostic"
fi
fixture_git "$FIXTURE_REPO" rm -q --cached -- quoted.md

info "Git metadata and index retargeting cannot produce a success receipt"
if /usr/bin/env -i PATH=/usr/bin:/bin LANG=C LC_ALL=C \
    /usr/bin/python3 -I -S - \
    "$ROOT/scripts/check_doc_field_drift.py" "$FIXTURE_REPO" <<'PY'
import importlib.util
import os
from pathlib import Path
import shutil
import sys

module_path = Path(sys.argv[1])
repository = Path(sys.argv[2])
spec = importlib.util.spec_from_file_location("doc_field_gate", module_path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
original_run_git = module._run_git


def expect_retarget_failure(target, replacement):
    moved = target.with_name(target.name + ".bound-test")
    calls = 0

    def racing_run_git(*args, **kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            os.rename(target, moved)
            replacement(target, moved)
        return original_run_git(*args, **kwargs)

    module._run_git = racing_run_git
    try:
        try:
            module.check_repository(repository)
        except module.CheckFailure as error:
            if "changed during validation" not in str(error):
                raise
        else:
            raise AssertionError("metadata retarget produced a success receipt")
    finally:
        module._run_git = original_run_git
        if target.is_dir():
            os.rmdir(target)
        elif target.exists():
            target.unlink()
        os.rename(moved, target)


expect_retarget_failure(repository / ".git", lambda target, _moved: target.mkdir())
expect_retarget_failure(
    repository / ".git" / "index",
    lambda target, moved: shutil.copyfile(moved, target),
)
PY
then
    pass "bound Git metadata rejects directory and index retargeting"
else
    fail "Git metadata retargeting escaped the exact-source binding"
fi

info "deprecated-field diagnostics remain aggregate-bounded"
/usr/bin/python3 -I -S - "$FIXTURE_REPO/many-findings.md" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_text("  - title: stale\n" * 2_000, encoding="utf-8")
PY
fixture_git "$FIXTURE_REPO" add -- many-findings.md
if run_exact_checker >"$TMP/many-findings.out" 2>&1; then
    fail "many deprecated fields were reported as drift-free"
elif [ "$(/usr/bin/wc -c <"$TMP/many-findings.out")" -gt 70000 ]; then
    fail "deprecated-field diagnostics exceeded their aggregate limit"
elif grep -Fq 'additional diagnostics omitted after the output limit' \
    "$TMP/many-findings.out"; then
    pass "diagnostic aggregation stops at the configured byte budget"
else
    fail "bounded diagnostics omitted their truncation receipt"
fi
fixture_git "$FIXTURE_REPO" reset -q -- many-findings.md

info "oversized staged documentation fails before an unbounded read"
/usr/bin/python3 - "$FIXTURE_REPO/oversized.md" <<'PY'
from pathlib import Path
import sys

Path(sys.argv[1]).write_bytes(b"#" + b"x" * 1_048_576)
PY
fixture_git "$FIXTURE_REPO" add -- oversized.md
if run_exact_checker >"$TMP/oversized.out" 2>&1; then
    fail "an oversized staged document was reported as drift-free"
elif grep -Fq '1048576-byte limit' "$TMP/oversized.out"; then
    pass "the exact documentation reader enforces its per-blob limit"
else
    fail "oversized staged documentation failed without its bound diagnostic"
fi

summary
exit_code
