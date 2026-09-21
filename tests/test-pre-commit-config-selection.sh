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
if ! IFS= read -r PRE_COMMIT_SHEBANG < "$PRE_COMMIT_BIN"; then
    printf 'ERROR: could not read the pre-commit provider shebang\n' >&2
    exit 1
fi
case "$PRE_COMMIT_SHEBANG" in
    '#!'/*) PRE_COMMIT_PYTHON=${PRE_COMMIT_SHEBANG#\#!} ;;
    *)
        printf 'ERROR: pre-commit must name one direct Python provider\n' >&2
        exit 1
        ;;
esac
case "$PRE_COMMIT_PYTHON" in
    *' '*|*'\t'*)
        printf 'ERROR: pre-commit provider shebang arguments are unsupported\n' >&2
        exit 1
        ;;
esac
PRE_COMMIT_PROVIDER_PYTHON="$PRE_COMMIT_PYTHON"
if [ ! -x "$PRE_COMMIT_PYTHON" ] || [ -L "$PRE_COMMIT_PYTHON" ]; then
    if ! PRE_COMMIT_PYTHON=$(
        "$PRE_COMMIT_PYTHON" -I -c \
            'import os, sys; print(os.path.realpath(sys.executable))'
    ); then
        printf 'ERROR: could not bind the pre-commit Python provider\n' >&2
        exit 1
    fi
fi
if ! PRE_COMMIT_PROVIDER_SHA256=$(shasum -a 256 "$PRE_COMMIT_BIN"); then
    printf 'ERROR: could not hash the pre-commit provider\n' >&2
    exit 1
fi
PRE_COMMIT_PROVIDER_SHA256=${PRE_COMMIT_PROVIDER_SHA256%% *}
if ! PRE_COMMIT_PYTHON_SHA256=$(shasum -a 256 "$PRE_COMMIT_PYTHON"); then
    printf 'ERROR: could not hash the pre-commit Python provider\n' >&2
    exit 1
fi
PRE_COMMIT_PYTHON_SHA256=${PRE_COMMIT_PYTHON_SHA256%% *}
if ! PYYAML_MANIFEST=$(
    "$PRE_COMMIT_PROVIDER_PYTHON" -I - <<'PY'
import hashlib
import importlib.machinery
import importlib.util
import os

specification = importlib.util.find_spec("yaml")
if specification is None or not specification.origin:
    raise SystemExit("PyYAML is unavailable")
package_root = os.path.dirname(os.path.abspath(specification.origin))
suffixes = (".py", *importlib.machinery.EXTENSION_SUFFIXES)
paths = []
for current, directories, files in os.walk(package_root, followlinks=False):
    directories[:] = sorted(
        name for name in directories
        if not os.path.islink(os.path.join(current, name))
    )
    for name in sorted(files):
        path = os.path.join(current, name)
        if not os.path.islink(path) and path.endswith(suffixes):
            paths.append(path)
for path in sorted(paths):
    with open(path, "rb") as stream:
        print("{}={}".format(path, hashlib.sha256(stream.read()).hexdigest()))
PY
); then
    printf 'ERROR: could not attest the PyYAML dependency closure\n' >&2
    exit 1
fi
TRUSTED_POLICY_PATH="$ROOT/scripts/check_silent_failures.py"
if ! TRUSTED_POLICY_SHA256=$(shasum -a 256 \
    "$ROOT/scripts/check_silent_failures.py"); then
    printf 'ERROR: could not hash the trusted silent-failure policy\n' >&2
    exit 1
fi
TRUSTED_POLICY_SHA256=${TRUSTED_POLICY_SHA256%% *}
if ! REAL_GIT=$(command -v git); then
    printf 'ERROR: git is required for path-selection tests\n' >&2
    exit 1
fi
if ! REAL_GIT=$(
    "$PRE_COMMIT_PYTHON" -I -c \
        'import os,sys; print(os.path.realpath(sys.argv[1]))' "$REAL_GIT"
); then
    printf 'ERROR: could not resolve the Git provider\n' >&2
    exit 1
fi
if ! REAL_GIT_SHA256=$(shasum -a 256 "$REAL_GIT"); then
    printf 'ERROR: could not hash the Git provider\n' >&2
    exit 1
fi
REAL_GIT_SHA256=${REAL_GIT_SHA256%% *}
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
mkdir -p "$REPO_ROOT/scripts"
cp "$ROOT/scripts/check_silent_failures.py" \
    "$REPO_ROOT/scripts/check_silent_failures.py"
fixture_git -C "$REPO_ROOT" add -- \
    .pre-commit-config.yaml scripts/check_silent_failures.py
fixture_git -C "$REPO_ROOT" commit -qm "fixture baseline"

PASS=0
FAIL=0
SILENT_SUPPRESSION='|| true'
pass() { PASS=$((PASS + 1)); printf '  PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL: %s\n' "$1" >&2; }

printf '\n== shell grammar preserves lexical state and scans executed substitutions ==\n'
if "$PRE_COMMIT_PYTHON" -I -S - \
    "$ROOT/scripts/check_silent_failures.py" <<'PY'
import importlib.util
import io
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("odysseus_silent_failure_policy", path)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)


def findings(source):
    return list(policy._shell_findings(io.StringIO(source)))


safe = (
    "message='first\nprobe || true\nlast'\n"
    'other="first\nprobe || true\nlast"\n'
    "value=$((8 << 1))\n"
    "((value <<= 1))\n"
    "cat <<'QUOTED'\n$(probe || true)\n`probe || true`\nQUOTED\n"
    "case value in value) printf '%s\\n' 'probe || true' ;; esac\n"
    "grep -F '::warning::' workflow.yml\n"
    "if [[ value == other || ( value == third && ${flag:-0} == 1 )\n"
    "    || ( value == fourth && ${other_flag:-0} == 1 ) ]]; then printf '%s\\n' safe; fi\n"
)
if findings(safe):
    raise AssertionError("authored multiline or arithmetic data was executable")

executable = (
    "message='safe\ntext'\nprobe || true\n"
    'result="$(probe || true)"\n'
    'legacy="`probe || true`"\n'
    "probe || (false; true)\n"
    "probe || (false && false; true)\n"
    "probe || { false; :; }\n"
    "cat <<UNQUOTED\n$(probe || true)\n`probe || true`\nUNQUOTED\n"
    "probe || true ignored\n"
    "probe || RESULT=ignored true\n"
    "probe || (case value in value) false ;; esac; true)\n"
    "quoted_nested=\"$(\ncat <<'DATA'\n)\nDATA\nprobe || true\n)\"\n"
    "expanded_nested=\"$(\ncat <<DATA\n$(probe || true)\n)\nDATA\nprobe || true\n)\"\n"
)
actual = findings(executable)
if len(actual) != 14:
    raise AssertionError("expected 14 executed suppressions, found {!r}".format(actual))

for prefix in ("printf '%s\\n' '[['", 'printf "%s\\n" "[["',
               r"printf '%s\n' \[\[", "printf '%s\\n' [[", "printf if [["):
    if len(findings(prefix + "; probe || true\n")) != 1:
        raise AssertionError("ordinary bracket word hid a later suppression")
if findings("if [[ value == ']]' || value == true ]]; then echo safe; fi\n"):
    raise AssertionError("quoted closing brackets ended conditional grammar")
if findings("time -p [[ value || true ]]\n"):
    raise AssertionError("time option hid conditional grammar")
for option in ("'-p'", '"-p"', r"\-p"):
    if len(findings("time " + option + " [[ value || true ]]\n")) != 1:
        raise AssertionError("quoted timed command hid executable suppression")


def static_failures(path, source):
    return policy._check_static_source(
        policy.Path(path), io.StringIO(source), policy.Reporter()
    )


safe_static = {
    "Dockerfile.safe": (
        "# RUN probe || true\n"
        "LABEL example=\"probe || true\"\n"
        "RUN printf '%s\\n' 'probe || true'\n"
    ),
    "config.hcl": (
        "description = \"probe || true\"\n"
        "// probe || true\n"
        "/* probe || true */\n"
    ),
    "Justfile": "# probe || true\nmessage := 'probe || true'\n",
}
for path, source in safe_static.items():
    if static_failures(path, source):
        raise AssertionError("authored static data was executable: {}".format(path))

unsafe_static = {
    "Dockerfile.fail": "RUN probe || :\nRUN probe || \\\n  exit 0\n",
    "job.hcl": 'command = "bash"\nargs = ["-c", "probe || true"]\n',
    "justfile": "check:\n    probe || \\\n      exit 0\n",
}
expected_static_failures = {"Dockerfile.fail": 2, "job.hcl": 1, "justfile": 1}
for path, source in unsafe_static.items():
    if static_failures(path, source) != expected_static_failures[path]:
        raise AssertionError("static executable suppression was missed: {}".format(path))

for path, source in (
    ("Dockerfile.test", "RUN [ -f /required ] || true\n"),
    ("Dockerfile.escape", "# escape=`\nRUN probe `\n || true\n"),
    ("Dockerfile.comment", "# escape=`\n# standalone comment `\nRUN probe || true\n"),
    ("justfile", "build: dependency\n    probe || true\n"),
    ("justfile", 'install PREFIX="/usr/local":\n    probe || true\n'),
    ("job.hcl", 'args = ["-c", <<E-OF\nprobe || true\nE-OF\n]\n'),
):
    if static_failures(path, source) != 1:
        raise AssertionError("executable structural form was missed: {}".format(path))
PY
then
    pass "shell and static grammars distinguish authored data from executable suppressions"
else
    fail "shell/static grammar lost assignment, case, heredoc, continuation, or authored-data state"
fi

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

run_silent_failure_hook() {
    run_silent_failure_hook_with_environment "$1" "$2" "$PATH" __unset__
}

run_silent_failure_hook_with_environment() {
    local git_variable
    local -a hook_environment
    relative_path=$1
    output_path=$2
    hook_path=$3
    policy_root=$4
    shift 4
    hook_environment=(
        GIT_CONFIG_GLOBAL=/dev/null
        GIT_CONFIG_NOSYSTEM=1
        HOME="$TEST_HOME"
        LC_ALL=C
        PATH="$hook_path"
        ODYSSEUS_MANAGED_PRE_COMMIT=1
        ODYSSEUS_PRE_COMMIT_INTERPRETER="$PRE_COMMIT_PYTHON"
        ODYSSEUS_PRE_COMMIT_INTERPRETER_SHA256="$PRE_COMMIT_PYTHON_SHA256"
        ODYSSEUS_PRE_COMMIT_PROVIDER="$PRE_COMMIT_BIN"
        ODYSSEUS_PRE_COMMIT_PROVIDER_SHA256="$PRE_COMMIT_PROVIDER_SHA256"
        ODYSSEUS_PRE_COMMIT_GIT="$REAL_GIT"
        ODYSSEUS_PRE_COMMIT_GIT_SHA256="$REAL_GIT_SHA256"
        ODYSSEUS_PRE_COMMIT_POLICY_PATH="$TRUSTED_POLICY_PATH"
        ODYSSEUS_PRE_COMMIT_POLICY_SHA256="$TRUSTED_POLICY_SHA256"
        ODYSSEUS_PYYAML_MANIFEST="$PYYAML_MANIFEST"
        PRE_COMMIT_HOME="$TMP_ROOT/pre-commit-home"
        TMPDIR="$TMP_ROOT/tmp"
    )
    if [ "$policy_root" != __unset__ ]; then
        hook_environment+=("ODYSSEUS_TRUSTED_POLICY_ROOT=$policy_root")
    fi
    while [ "$#" -gt 0 ]; do
        hook_environment+=("$1")
        shift
    done
    preserve_index=${ODYSSEUS_TEST_PRESERVE_INDEX:-0}
    if [ "$preserve_index" -ne 1 ] \
       && ! fixture_git -C "$REPO_ROOT" add -- "$relative_path"; then
        printf 'ERROR: could not stage silent-failure fixture %s\n' \
            "$relative_path" > "$output_path"
        return 99
    fi
    set +e
    (
        cd "$REPO_ROOT" || exit 99
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        env "${hook_environment[@]}" \
            "$PRE_COMMIT_BIN" run --color never \
            forbid-or-true --files "$relative_path"
    ) > "$output_path" 2>&1
    hook_status=$?
    set -e
    if [ "$preserve_index" -ne 1 ]; then
        fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$relative_path"
    fi
    return "$hook_status"
}

run_root_exact_index_policy() {
    local source_path relative_path
    local exact_root=$TMP_ROOT/root-exact-repository
    local inventory=$TMP_ROOT/root-exact-inventory
    fixture_git -C "$ROOT" ls-files -z --cached --others --exclude-standard > "$inventory" || return 99
    mkdir "$exact_root" || return 99
    while IFS= read -r -d '' relative_path; do
        source_path=$ROOT/$relative_path
        if [ -f "$source_path" ] || [ -L "$source_path" ]; then
            mkdir -p "$exact_root/$(dirname "$relative_path")" || return 99
            /bin/cp -P -- "$source_path" "$exact_root/$relative_path" || return 99
        fi
    done < "$inventory"
    fixture_git -C "$exact_root" init -q || return 99
    fixture_git -C "$exact_root" add -A -- . || return 99
    (
        cd "$exact_root" || exit 99
        env -i \
            GIT_CONFIG_GLOBAL=/dev/null \
            GIT_CONFIG_NOSYSTEM=1 \
            HOME="$TEST_HOME" \
            LC_ALL=C \
            PATH=/usr/bin:/bin \
            ODYSSEUS_MANAGED_PRE_COMMIT=1 \
            ODYSSEUS_PRE_COMMIT_INTERPRETER="$PRE_COMMIT_PYTHON" \
            ODYSSEUS_PRE_COMMIT_INTERPRETER_SHA256="$PRE_COMMIT_PYTHON_SHA256" \
            ODYSSEUS_PRE_COMMIT_PROVIDER="$PRE_COMMIT_BIN" \
            ODYSSEUS_PRE_COMMIT_PROVIDER_SHA256="$PRE_COMMIT_PROVIDER_SHA256" \
            ODYSSEUS_PRE_COMMIT_GIT="$REAL_GIT" \
            ODYSSEUS_PRE_COMMIT_GIT_SHA256="$REAL_GIT_SHA256" \
            ODYSSEUS_PRE_COMMIT_POLICY_PATH="$TRUSTED_POLICY_PATH" \
            ODYSSEUS_PRE_COMMIT_POLICY_SHA256="$TRUSTED_POLICY_SHA256" \
            ODYSSEUS_PYYAML_MANIFEST="$PYYAML_MANIFEST" \
            TMPDIR="$TMP_ROOT/tmp" \
            "$PRE_COMMIT_PYTHON" -I scripts/check_silent_failures.py
    )
}

printf '\n== repository exact index satisfies silent-failure policy ==\n'
if run_root_exact_index_policy > "$TMP_ROOT/root-exact-index.out" 2>&1; then
    pass "the complete exact repository index satisfies the executable policy"
else
    sed -n '1,80p' "$TMP_ROOT/root-exact-index.out" >&2
    fail "the complete exact repository index contains silent-failure controls"
fi

printf '\n== silent-failure hook rejects ambient execution authority ==\n'
mkdir -p "$REPO_ROOT/scripts"
printf '#!/bin/sh\nprobe %s\n' "$SILENT_SUPPRESSION" \
    > "$REPO_ROOT/scripts/suppressed.sh"

HOSTILE_POLICY_ROOT="$TMP_ROOT/hostile-policy"
HOSTILE_ROOT_MARKER="$TMP_ROOT/hostile-policy-ran"
export HOSTILE_ROOT_MARKER
mkdir -p "$HOSTILE_POLICY_ROOT/scripts"
cat > "$HOSTILE_POLICY_ROOT/scripts/check_silent_failures.py" <<'PY'
import os
from pathlib import Path
Path(os.environ["HOSTILE_ROOT_MARKER"]).write_text(
    "hostile policy ran", encoding="utf-8"
)
raise SystemExit(0)
PY
if run_silent_failure_hook_with_environment \
    "scripts/suppressed.sh" "$TMP_ROOT/hostile-root.out" \
    "$PATH" "$HOSTILE_POLICY_ROOT"; then
    fail "ambient policy root redirected the silent-failure hook"
elif [ -e "$HOSTILE_ROOT_MARKER" ]; then
    fail "ambient policy root executed an alternate policy script"
elif grep -Fq "untrusted policy root" "$TMP_ROOT/hostile-root.out"; then
    pass "ambient policy root cannot redirect the policy script"
else
    sed -n '1,20p' "$TMP_ROOT/hostile-root.out" >&2
    fail "ambient policy root rejection lacked its trust diagnostic"
fi

HOSTILE_BIN="$TMP_ROOT/hostile-bin"
HOSTILE_PYTHON_MARKER="$TMP_ROOT/hostile-python-ran"
export HOSTILE_PYTHON_MARKER
mkdir -p "$HOSTILE_BIN"
cat > "$HOSTILE_BIN/python3" <<'SH'
#!/bin/sh
printf hostile > "${HOSTILE_PYTHON_MARKER:?}"
exit 0
SH
chmod +x "$HOSTILE_BIN/python3"
if run_silent_failure_hook_with_environment \
    "scripts/suppressed.sh" "$TMP_ROOT/hostile-python.out" \
    "$HOSTILE_BIN:$PATH" __unset__; then
    fail "ambient PATH selected the silent-failure Python provider"
elif [ -e "$HOSTILE_PYTHON_MARKER" ]; then
    fail "ambient PATH executed a hostile Python provider"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/hostile-python.out"; then
    pass "ambient PATH cannot select the Python provider"
else
    sed -n '1,20p' "$TMP_ROOT/hostile-python.out" >&2
    fail "ambient PATH test did not execute the bound policy"
fi

HOSTILE_PROVIDER_BIN="$TMP_ROOT/hostile-provider-bin"
HOSTILE_PROVIDER_MARKER="$TMP_ROOT/hostile-provider-ran"
export HOSTILE_PROVIDER_MARKER
mkdir -p "$HOSTILE_PROVIDER_BIN"
cat > "$HOSTILE_PROVIDER_BIN/python3" <<'SH'
#!/bin/sh
exec /usr/bin/python3 "$@"
SH
cat > "$HOSTILE_PROVIDER_BIN/provider-python" <<'SH'
#!/bin/sh
printf hostile > "${HOSTILE_PROVIDER_MARKER:?}"
exit 97
SH
cat > "$HOSTILE_PROVIDER_BIN/pre-commit" <<SH
#!$HOSTILE_PROVIDER_BIN/provider-python
SH
chmod +x \
    "$HOSTILE_PROVIDER_BIN/python3" \
    "$HOSTILE_PROVIDER_BIN/provider-python" \
    "$HOSTILE_PROVIDER_BIN/pre-commit"
if run_silent_failure_hook_with_environment \
    "scripts/suppressed.sh" "$TMP_ROOT/hostile-provider.out" \
    "$HOSTILE_PROVIDER_BIN:/usr/bin:/bin" __unset__; then
    fail "ambient pre-commit provider bypassed silent-failure policy"
elif [ -e "$HOSTILE_PROVIDER_MARKER" ]; then
    fail "ambient pre-commit shebang executed a hostile provider"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/hostile-provider.out"; then
    pass "ambient pre-commit shebang cannot redirect the provider"
else
    sed -n '1,20p' "$TMP_ROOT/hostile-provider.out" >&2
    fail "ambient pre-commit test did not execute the bound policy"
fi

HOSTILE_YAML_MODULES="$TMP_ROOT/hostile-yaml-modules"
HOSTILE_YAML_MARKER="$TMP_ROOT/hostile-yaml-ran"
export HOSTILE_YAML_MODULES HOSTILE_YAML_MARKER
mkdir -p "$HOSTILE_YAML_MODULES/yaml"
cat > "$HOSTILE_YAML_MODULES/yaml/__init__.py" <<'PY'
import os
from pathlib import Path
Path(os.environ["HOSTILE_YAML_MARKER"]).write_text(
    "hostile yaml ran", encoding="utf-8"
)
class BaseLoader: pass
class YAMLError(Exception): pass
def compose_all(*args, **kwargs): return ()
PY
cat > "$HOSTILE_YAML_MODULES/yaml/nodes.py" <<'PY'
class MappingNode: pass
class ScalarNode: pass
class SequenceNode: pass
PY
fixture_git -C "$REPO_ROOT" add -- scripts/suppressed.sh
if (
    cd "$REPO_ROOT" || exit 99
    for git_variable in "${!GIT_@}"; do
        unset "$git_variable"
    done
    env \
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        HOME="$TEST_HOME" \
        LC_ALL=C \
        PATH="$PATH" \
        PYTHONPATH="$HOSTILE_YAML_MODULES" \
        ODYSSEUS_MANAGED_PRE_COMMIT=1 \
        ODYSSEUS_PRE_COMMIT_INTERPRETER="$PRE_COMMIT_PYTHON" \
        ODYSSEUS_PRE_COMMIT_INTERPRETER_SHA256="$PRE_COMMIT_PYTHON_SHA256" \
        ODYSSEUS_PRE_COMMIT_PROVIDER="$PRE_COMMIT_BIN" \
        ODYSSEUS_PRE_COMMIT_PROVIDER_SHA256="$PRE_COMMIT_PROVIDER_SHA256" \
        ODYSSEUS_PRE_COMMIT_GIT="$REAL_GIT" \
        ODYSSEUS_PRE_COMMIT_GIT_SHA256="$REAL_GIT_SHA256" \
        ODYSSEUS_PRE_COMMIT_POLICY_PATH="$TRUSTED_POLICY_PATH" \
        ODYSSEUS_PRE_COMMIT_POLICY_SHA256="$TRUSTED_POLICY_SHA256" \
        ODYSSEUS_PYYAML_MANIFEST="$PYYAML_MANIFEST" \
        TMPDIR="$TMP_ROOT/tmp" \
        "$PRE_COMMIT_PYTHON" -I scripts/check_silent_failures.py
) > "$TMP_ROOT/hostile-yaml.out" 2>&1; then
    fail "unbound PyYAML provenance bypassed silent-failure policy"
elif [ -e "$HOSTILE_YAML_MARKER" ]; then
    fail "an unbound PyYAML package executed inside the policy checker"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/hostile-yaml.out"; then
    pass "PyYAML must come from the bound provider environment"
else
    sed -n '1,20p' "$TMP_ROOT/hostile-yaml.out" >&2
    fail "PyYAML provenance test did not execute the bound policy"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- scripts/suppressed.sh

if run_silent_failure_hook_with_environment \
    "scripts/suppressed.sh" "$TMP_ROOT/hostile-provider-digest.out" \
    "$PATH" __unset__ \
    ODYSSEUS_PRE_COMMIT_PROVIDER_SHA256="$(printf '0%.0s' {1..64})"; then
    fail "hook accepted a changed pre-commit provider identity"
elif grep -Fq "pre-commit provider provenance changed" \
    "$TMP_ROOT/hostile-provider-digest.out"; then
    pass "changed pre-commit provider identity fails closed"
else
    sed -n '1,20p' "$TMP_ROOT/hostile-provider-digest.out" >&2
    fail "changed pre-commit provider lacked its provenance diagnostic"
fi

printf '\n== PyYAML closure is authenticated before import ==\n'
if "$PRE_COMMIT_PYTHON" -I - \
    "$ROOT/scripts/check_silent_failures.py" "$TMP_ROOT" <<'PY'
import hashlib
import importlib
import importlib.util
import os
from pathlib import Path
import sys

policy_path, temporary_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "odysseus_silent_failure_policy", policy_path
)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)

prefix = (Path(temporary_root) / "same-prefix-python").resolve()
package = prefix / "yaml"
package.mkdir(parents=True)
files = {
    package / "__init__.py": b'__version__ = "6.0.3"\n',
    package / "events.py": b"class AliasEvent: pass\n",
    package / "nodes.py": (
        b"class MappingNode: pass\n"
        b"class ScalarNode: pass\n"
        b"class SequenceNode: pass\n"
    ),
}
for path, data in files.items():
    path.write_bytes(data)
manifest = "\n".join(
    "{}={}".format(path, hashlib.sha256(data).hexdigest())
    for path, data in sorted(files.items())
)
os.environ["ODYSSEUS_PYYAML_MANIFEST"] = manifest
marker = Path(temporary_root) / "same-prefix-yaml-ran"
(package / "__init__.py").write_text(
    "from pathlib import Path\n"
    "Path({!r}).write_text('ran', encoding='utf-8')\n"
    "__version__ = '6.0.3'\n".format(str(marker)),
    encoding="utf-8",
)
old_prefix = sys.prefix
old_path = list(sys.path)
try:
    sys.prefix = str(prefix)
    sys.path.insert(0, str(prefix))
    importlib.invalidate_caches()
    try:
        policy._load_yaml()
    except policy.PolicyError:
        pass
    else:
        raise AssertionError("mutated same-prefix PyYAML closure was accepted")
finally:
    sys.prefix = old_prefix
    sys.path[:] = old_path
    for name in tuple(sys.modules):
        if name == "yaml" or name.startswith("yaml."):
            sys.modules.pop(name, None)
assert not marker.exists(), "hostile PyYAML bytes executed before authentication"
PY
then
    pass "same-prefix hostile PyYAML bytes are rejected before import"
else
    fail "same-prefix hostile PyYAML bytes executed before closure authentication"
fi

if "$PRE_COMMIT_PYTHON" -I - \
    "$ROOT/scripts/check_silent_failures.py" "$TMP_ROOT" <<'PY'
import hashlib
import importlib
import importlib.util
import os
from pathlib import Path
import sys

policy_path, temporary_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location(
    "odysseus_silent_failure_policy_import_race", policy_path
)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)

prefix = (Path(temporary_root) / "import-race-python").resolve()
package = prefix / "yaml"
package.mkdir(parents=True)
files = {
    package / "__init__.py": b'__version__ = "6.0.3"\n',
    package / "events.py": b"class AliasEvent: pass\n",
    package / "nodes.py": (
        b"class MappingNode: pass\n"
        b"class ScalarNode: pass\n"
        b"class SequenceNode: pass\n"
    ),
}
for path, data in files.items():
    path.write_bytes(data)
os.environ["ODYSSEUS_PYYAML_MANIFEST"] = "\n".join(
    "{}={}".format(path, hashlib.sha256(data).hexdigest())
    for path, data in sorted(files.items())
)
marker = Path(temporary_root) / "import-race-yaml-ran"
original_import = importlib.import_module
armed = {"value": True}

def mutate_after_authentication(name, package_name=None):
    if name == "yaml" and armed["value"]:
        armed["value"] = False
        (package / "__init__.py").write_text(
            "from pathlib import Path\n"
            "Path({!r}).write_text('ran', encoding='utf-8')\n"
            "__version__ = '6.0.3'\n".format(str(marker)),
            encoding="utf-8",
        )
        importlib.invalidate_caches()
    return original_import(name, package_name)

old_prefix = sys.prefix
old_path = list(sys.path)
problem = None
try:
    sys.prefix = str(prefix)
    sys.path.insert(0, str(prefix))
    importlib.invalidate_caches()
    policy.importlib.import_module = mutate_after_authentication
    try:
        policy._load_yaml()
    except policy.PolicyError as error:
        problem = error
finally:
    policy.importlib.import_module = original_import
    sys.prefix = old_prefix
    sys.path[:] = old_path
    for name in tuple(sys.modules):
        if name == "yaml" or name.startswith("yaml."):
            sys.modules.pop(name, None)
assert not armed["value"], (
    "the import-race oracle did not reach module loading: {!r}".format(problem)
)
assert not marker.exists(), "post-authentication PyYAML replacement executed"
PY
then
    pass "post-authentication PyYAML replacement cannot execute"
else
    fail "mutable PyYAML bytes executed after closure authentication"
fi

printf '\n== restricted dependency startup ignores site initialization ==\n'
HOSTILE_SITE="$TMP_ROOT/hostile-site"
HOSTILE_SITE_MARKER="$TMP_ROOT/hostile-site-ran"
mkdir -p "$HOSTILE_SITE"
cat > "$HOSTILE_SITE/sitecustomize.py" <<'PY'
import os
from pathlib import Path
Path(os.environ["HOSTILE_SITE_MARKER"]).write_text("ran", encoding="utf-8")
PY
printf 'import sitecustomize\n' > "$HOSTILE_SITE/hostile.pth"
if ! grep -Fq \
    '/run/trusted-policy) exec /usr/local/bin/python3 -I -S' \
    "$ROOT/.pre-commit-config.yaml"; then
    fail "restricted policy entry does not disable site startup"
elif ! env PYTHONPATH="$HOSTILE_SITE" HOSTILE_SITE_MARKER="$HOSTILE_SITE_MARKER" \
    "$PRE_COMMIT_PYTHON" -I -S -c \
    'import sys; assert "sitecustomize" not in sys.modules'; then
    fail "isolated no-site dependency startup failed"
elif [ -e "$HOSTILE_SITE_MARKER" ]; then
    fail "sitecustomize or a .pth payload ran before dependency authentication"
elif "$PRE_COMMIT_PYTHON" -I -S - \
    "$ROOT/scripts/check_silent_failures.py" "$TMP_ROOT" <<'PY'
import importlib.util
from pathlib import Path
import sys

policy_path, temporary_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("restricted_policy", policy_path)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)
prefix = Path(temporary_root) / "restricted-prefix"
origin = prefix / "lib" / "python{}.{}".format(
    sys.version_info.major, sys.version_info.minor
) / "site-packages" / "yaml" / "__init__.py"
origin.parent.mkdir(parents=True)
origin.write_text('__version__ = "6.0.3"\n', encoding="utf-8")
original = policy._root_immutable_route
old_prefix = sys.prefix
old_base_prefix = sys.base_prefix
try:
    policy._root_immutable_route = lambda _path: True
    sys.prefix = str(prefix)
    sys.base_prefix = str(prefix)
    selected = policy._restricted_yaml_origin()
finally:
    policy._root_immutable_route = original
    sys.prefix = old_prefix
    sys.base_prefix = old_base_prefix
assert selected == str(origin.resolve())
PY
then
    pass "restricted dependency bytes are selected without site startup"
else
    fail "restricted dependency loading still depends on site initialization"
fi

printf '\n== staged-index records reject malformed and unsupported entries ==\n'
if "$PRE_COMMIT_PYTHON" -I -S - \
    "$ROOT/scripts/check_silent_failures.py" <<'PY'
import importlib.util
import sys

policy_path = sys.argv[1]
spec = importlib.util.spec_from_file_location("staged_record_policy", policy_path)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)
snapshot = object.__new__(policy.StagedSnapshot)
snapshot.algorithm = "sha1"
for record in (
    b"not-an-index-record\0",
    b"120000 " + b"0" * 40 + b" 0\tscripts/link.sh\0",
    b"160000 " + b"0" * 40 + b" 0\tscripts/gitlink.sh\0",
    b"100644 " + b"0" * 40 + b" 2\tscripts/unmerged.sh\0",
):
    try:
        snapshot._parse_listing(record)
    except policy.PolicyError:
        continue
    raise AssertionError("unsupported staged index record was accepted")
PY
then
    pass "malformed, symlink, gitlink, and unmerged stage entries fail closed"
else
    fail "unsupported staged index records retained policy authority"
fi

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

printf '\n== silent-failure hook ignores authored task prose ==\n'
mkdir -p "$REPO_ROOT/workflows"
cat > "$REPO_ROOT/workflows/m4-example.yaml" <<YAML
name: M4 example
tasks:
  - id: explain-suppression
    description: |
      Explain why this command hides a failure:
      probe $SILENT_SUPPRESSION
YAML
if run_silent_failure_hook \
    "workflows/m4-example.yaml" "$TMP_ROOT/task-prose.out"; then
    pass "silent-failure hook does not parse authored task prose as shell"
else
    sed -n '1,20p' "$TMP_ROOT/task-prose.out" >&2
    fail "silent-failure hook parsed authored task prose as shell"
fi

mkdir -p "$REPO_ROOT/tools/github/milestone-epics.d"
cat > "$REPO_ROOT/tools/github/milestone-epics.d/m4.yaml" <<YAML
milestone: M4
issues:
  - title: Explain command failure handling
    body: |
      Compare an explicit guard with this anti-pattern:
      probe $SILENT_SUPPRESSION
YAML
if run_silent_failure_hook \
    "tools/github/milestone-epics.d/m4.yaml" \
    "$TMP_ROOT/milestone-prose.out"; then
    pass "silent-failure hook does not parse milestone prose as shell"
else
    sed -n '1,20p' "$TMP_ROOT/milestone-prose.out" >&2
    fail "silent-failure hook parsed milestone prose as shell"
fi

printf '\n== silent-failure hook reads the sealed staged blob ==\n'
mixed_stage_path="scripts/mixed-stage.sh"
cat > "$REPO_ROOT/$mixed_stage_path" <<'SH'
#!/bin/sh
probe || true
SH
fixture_git -C "$REPO_ROOT" add -- "$mixed_stage_path"
cat > "$REPO_ROOT/$mixed_stage_path" <<'SH'
#!/bin/sh
printf '%s\n' safe
SH
if ODYSSEUS_TEST_PRESERVE_INDEX=1 run_silent_failure_hook \
    "$mixed_stage_path" "$TMP_ROOT/staged-unsafe-worktree-safe.out"; then
    fail "hook read safe worktree bytes instead of the unsafe staged blob"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/staged-unsafe-worktree-safe.out"; then
    pass "unsafe staged bytes remain authoritative over safe worktree bytes"
else
    sed -n '1,20p' "$TMP_ROOT/staged-unsafe-worktree-safe.out" >&2
    fail "unsafe staged blob rejection lacked its semantic diagnostic"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$mixed_stage_path"

gitlink_path="scripts/staged-gitlink.sh"
gitlink_object=$(fixture_git -C "$REPO_ROOT" rev-parse HEAD)
fixture_git -C "$REPO_ROOT" update-index --add \
    --cacheinfo "160000,$gitlink_object,$gitlink_path"
if ODYSSEUS_TEST_PRESERVE_INDEX=1 run_silent_failure_hook \
    "$gitlink_path" "$TMP_ROOT/staged-gitlink.out"; then
    fail "hook accepted a staged gitlink as executable source"
elif grep -Fq "unsupported staged policy entry" \
    "$TMP_ROOT/staged-gitlink.out"; then
    pass "staged gitlinks fail closed before content parsing"
else
    sed -n '1,20p' "$TMP_ROOT/staged-gitlink.out" >&2
    fail "staged gitlink rejection lacked its structural diagnostic"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$gitlink_path"

missing_path="scripts/missing-object.sh"
missing_object=$(printf '1%.0s' {1..40})
fixture_git -C "$REPO_ROOT" update-index --add --info-only \
    --cacheinfo "100644,$missing_object,$missing_path"
if ODYSSEUS_TEST_PRESERVE_INDEX=1 run_silent_failure_hook \
    "$missing_path" "$TMP_ROOT/staged-missing-object.out"; then
    fail "hook accepted a staged entry whose blob is unavailable"
elif grep -Eq "(wrong staged object|cannot read the staged blob|malformed staged-object)" \
    "$TMP_ROOT/staged-missing-object.out"; then
    pass "missing staged blobs fail closed before validation"
else
    sed -n '1,20p' "$TMP_ROOT/staged-missing-object.out" >&2
    fail "missing staged blob rejection lacked its acquisition diagnostic"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$missing_path"

cat > "$REPO_ROOT/$mixed_stage_path" <<'SH'
#!/bin/sh
printf '%s\n' safe-snapshot
SH
fixture_git -C "$REPO_ROOT" add -- "$mixed_stage_path"
if ODYSSEUS_PRE_COMMIT_GIT="$REAL_GIT" \
    "$PRE_COMMIT_PYTHON" -I -S - \
    "$ROOT/scripts/check_silent_failures.py" "$REPO_ROOT" \
    "$mixed_stage_path" "$REAL_GIT" <<'PY'
import importlib.util
import os
from pathlib import Path
import subprocess
import sys

policy_path, repository, selected_path, git = sys.argv[1:]
spec = importlib.util.spec_from_file_location("staged_snapshot_policy", policy_path)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)
snapshot = policy.StagedSnapshot(repository)
try:
    entry = next(item for item in snapshot.entries if item.path == selected_path)
    blob = snapshot.open_blob(entry)
    target = Path(repository, selected_path)
    target.write_text("#!/bin/sh\nprobe || true\n", encoding="utf-8")
    environment = policy._git_environment()
    subprocess.run(
        [git, "-C", repository, "add", "--", selected_path],
        env=environment,
        check=True,
    )
    try:
        assert blob.stream is not None
        assert "safe-snapshot" in blob.stream.read()
        blob.verify()
    finally:
        blob.close()
    try:
        snapshot.verify()
    except policy.PolicyError as error:
        assert "index changed" in str(error) or "identity changed" in str(error)
    else:
        raise AssertionError("post-selection index mutation was accepted")
finally:
    snapshot.close()
PY
then
    pass "captured object bytes stay sealed and post-selection index mutation fails closed"
else
    fail "staged snapshot did not bind object bytes and index identity"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$mixed_stage_path"

cat > "$REPO_ROOT/$mixed_stage_path" <<'SH'
#!/bin/sh
printf '%s\n' safe-snapshot
SH
fixture_git -C "$REPO_ROOT" add -- "$mixed_stage_path"
if ODYSSEUS_PRE_COMMIT_GIT="$REAL_GIT" \
    "$PRE_COMMIT_PYTHON" -I -S - \
    "$ROOT/scripts/check_silent_failures.py" "$REPO_ROOT" \
    "$mixed_stage_path" "$REAL_GIT" <<'PY'
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile

policy_path, repository, selected_path, git = sys.argv[1:]
spec = importlib.util.spec_from_file_location("staged_index_race_policy", policy_path)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)

environment = policy._git_environment()
index_path = subprocess.run(
    [git, "-C", repository, "rev-parse", "--path-format=absolute", "--git-path", "index"],
    env=environment,
    check=True,
    stdout=subprocess.PIPE,
).stdout.decode("utf-8").strip()
expected_listing = subprocess.run(
    [git, "-C", repository, "ls-files", "--stage", "-z"],
    env=environment,
    check=True,
    stdout=subprocess.PIPE,
).stdout
with tempfile.NamedTemporaryFile(
    prefix="hostile-index-", dir=os.path.dirname(index_path), delete=False
) as temporary_index:
    malicious = temporary_index.name
os.unlink(malicious)
malicious_environment = dict(environment)
malicious_environment["GIT_INDEX_FILE"] = malicious
subprocess.run(
    [git, "-C", repository, "read-tree", "HEAD"],
    env=malicious_environment,
    check=True,
)
target = Path(repository, selected_path)
safe_worktree = target.read_bytes()
target.write_text("#!/bin/sh\nprobe || true\n", encoding="utf-8")
subprocess.run(
    [git, "-C", repository, "add", "--", selected_path],
    env=malicious_environment,
    check=True,
)
target.write_bytes(safe_worktree)

original_run = policy._run_git_capture
replacement = index_path + ".hostile"
saved = index_path + ".selected"
raced = False

def replace_during_selection(arguments, cwd, *, index_descriptor=None):
    global raced
    if arguments == ["ls-files", "--stage", "-z"]:
        if index_descriptor is None:
            raise AssertionError("Git selection did not receive the sealed index descriptor")
        os.replace(index_path, saved)
        os.replace(malicious, index_path)
        try:
            raced = True
            observed = original_run(
                arguments,
                cwd,
                index_descriptor=index_descriptor,
            )
            assert observed == expected_listing
            return observed
        finally:
            os.replace(index_path, replacement)
            os.replace(saved, index_path)
    if index_descriptor is None:
        return original_run(arguments, cwd)
    return original_run(arguments, cwd, index_descriptor=index_descriptor)

policy._run_git_capture = replace_during_selection
snapshot = None
try:
    try:
        snapshot = policy.StagedSnapshot(repository)
    except policy.PolicyError as error:
        assert raced
        assert "identity changed" in str(error) or "index changed" in str(error)
    else:
        entry = next(item for item in snapshot.entries if item.path == selected_path)
        blob = snapshot.open_blob(entry)
        try:
            assert blob.stream is not None
            assert "safe-snapshot" in blob.stream.read()
            blob.verify()
        finally:
            blob.close()
        assert raced
finally:
    if snapshot is not None:
        snapshot.close()
    policy._run_git_capture = original_run
    for path in (malicious, replacement, saved):
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass
PY
then
    pass "selection uses an anonymous index snapshot or fails closed during pathname replacement"
else
    fail "staged selection reopened the replaceable live index pathname"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$mixed_stage_path"

cat > "$REPO_ROOT/$mixed_stage_path" <<'SH'
#!/bin/sh
printf '%s\n' safe
SH
fixture_git -C "$REPO_ROOT" add -- "$mixed_stage_path"
cat > "$REPO_ROOT/$mixed_stage_path" <<'SH'
#!/bin/sh
probe || true
SH
if ODYSSEUS_TEST_PRESERVE_INDEX=1 run_silent_failure_hook \
    "$mixed_stage_path" "$TMP_ROOT/staged-safe-worktree-unsafe.out"; then
    pass "safe staged bytes remain authoritative over unsafe worktree bytes"
else
    sed -n '1,20p' "$TMP_ROOT/staged-safe-worktree-unsafe.out" >&2
    fail "hook read unsafe worktree bytes instead of the safe staged blob"
fi
fixture_git -C "$REPO_ROOT" reset -q HEAD -- "$mixed_stage_path"

printf '\n== authored shell data is not executable shell syntax ==\n'
cat > "$REPO_ROOT/scripts/authored-shell-data.sh" <<'SH'
#!/bin/sh
printf '%s\n' 'probe || true'
printf '%s\n' safe # probe || true
cat <<'AUTHORED_DATA'
probe || true
echo ::warning::prose
AUTHORED_DATA
SH
if run_silent_failure_hook \
    "scripts/authored-shell-data.sh" "$TMP_ROOT/authored-shell-data.out"; then
    pass "quoted, commented, and heredoc shell data remains authored data"
else
    sed -n '1,30p' "$TMP_ROOT/authored-shell-data.out" >&2
    fail "checker treated quoted, commented, or heredoc data as execution"
fi

printf '#!/bin/sh\ncat <<-AUTHORED_DATA\n\tprobe || true\n\techo ::warning::prose\n\tAUTHORED_DATA\nprintf "%%s\\n" safe\n' \
    > "$REPO_ROOT/scripts/tab-stripped-heredoc.sh"
if run_silent_failure_hook \
    "scripts/tab-stripped-heredoc.sh" "$TMP_ROOT/tab-stripped-heredoc.out"; then
    pass "tab-stripping heredoc data remains authored data"
else
    sed -n '1,20p' "$TMP_ROOT/tab-stripped-heredoc.out" >&2
    fail "hook rejected a valid tab-stripping heredoc"
fi

cat > "$REPO_ROOT/scripts/grouped-suppressions.sh" <<'SH'
#!/bin/sh
probe || (true)
probe || ( command true )
probe || { :; }
SH
if run_silent_failure_hook \
    "scripts/grouped-suppressions.sh" "$TMP_ROOT/grouped-suppressions.out"; then
    fail "hook accepted grouped silent-failure suppressions"
elif [ "$(grep -Fc 'forbidden silent-failure workaround' \
        "$TMP_ROOT/grouped-suppressions.out")" -eq 3 ]; then
    pass "grouped and wrapped no-op suppressions are rejected"
else
    sed -n '1,20p' "$TMP_ROOT/grouped-suppressions.out" >&2
    fail "grouped suppression diagnostics were incomplete"
fi

printf '\n== silent-failure hook checks workflow run commands structurally ==\n'
mkdir -p "$REPO_ROOT/.github/workflows"
for workflow_suffix in yml yaml; do
    cat > "$REPO_ROOT/.github/workflows/prose.$workflow_suffix" <<YAML
name: Prose is data
on: workflow_dispatch
env:
  TASK_DESCRIPTION: |
    Explain these anti-patterns without executing them:
    probe $SILENT_SUPPRESSION
    continue-on-error: true
    echo ::warning::advisory text
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - name: Text outside run can describe probe $SILENT_SUPPRESSION
        env:
          MORE_PROSE: |
            continue-on-error: true
            echo ::warning::advisory text
        run: printf '%s\n' safe
YAML
    if run_silent_failure_hook \
        ".github/workflows/prose.$workflow_suffix" \
        "$TMP_ROOT/workflow-prose-$workflow_suffix.out"; then
        pass "workflow .$workflow_suffix prose outside run commands remains data"
    else
        sed -n '1,20p' \
            "$TMP_ROOT/workflow-prose-$workflow_suffix.out" >&2
        fail "workflow .$workflow_suffix prose was parsed as executable policy"
    fi

    cat > "$REPO_ROOT/.github/workflows/authored-run-data.$workflow_suffix" <<'YAML'
name: Authored run data
on: workflow_dispatch
jobs:
  shell-data:
    runs-on: ubuntu-latest
    steps:
      - shell: bash
        run: |
          printf '%s\n' 'probe || true'
          printf '%s\n' safe # probe || true
          cat <<'AUTHORED_DATA'
          probe || true
          echo ::warning::prose
          AUTHORED_DATA
      - shell: python
        run: |
          message = "probe || true; echo ::warning::prose"
          print(message)
YAML
    if run_silent_failure_hook \
        ".github/workflows/authored-run-data.$workflow_suffix" \
        "$TMP_ROOT/authored-run-data-$workflow_suffix.out"; then
        pass "workflow .$workflow_suffix scans shell execution, not authored data"
    else
        sed -n '1,30p' "$TMP_ROOT/authored-run-data-$workflow_suffix.out" >&2
        fail "workflow .$workflow_suffix treated authored data as shell execution"
    fi

    cat > "$REPO_ROOT/.github/workflows/dynamic-shell.$workflow_suffix" <<YAML
name: Dynamic shell suppression
on: workflow_dispatch
jobs:
  check:
    runs-on: ubuntu-latest
    strategy:
      matrix:
        shell: [bash]
    steps:
      - shell: \${{ matrix.shell }}
        run: probe $SILENT_SUPPRESSION
      - shell: /usr/bin/env bash {0}
        run: probe $SILENT_SUPPRESSION
      - shell: python -c "import os; os.execvp('bash', ['bash', '{0}'])" {0}
        run: probe $SILENT_SUPPRESSION
YAML
    if run_silent_failure_hook \
        ".github/workflows/dynamic-shell.$workflow_suffix" \
        "$TMP_ROOT/dynamic-shell-$workflow_suffix.out"; then
        fail "hook accepted .$workflow_suffix suppressions through custom shell selectors"
    elif [ "$(grep -Fc 'forbidden silent-failure workaround in workflow run command' \
        "$TMP_ROOT/dynamic-shell-$workflow_suffix.out")" -eq 3 ]; then
        pass "workflow .$workflow_suffix scans dynamic, wrapped, and env-selected shells"
    else
        sed -n '1,20p' "$TMP_ROOT/dynamic-shell-$workflow_suffix.out" >&2
        fail "custom .$workflow_suffix shell selectors disabled policy inspection"
    fi

    cat > "$REPO_ROOT/.github/workflows/exact-non-shell.$workflow_suffix" <<'YAML'
name: Exact non-shell selector
on: workflow_dispatch
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - shell: python {0}
        run: |
          message = "probe || true"
          print(message)
YAML
    if run_silent_failure_hook \
        ".github/workflows/exact-non-shell.$workflow_suffix" \
        "$TMP_ROOT/exact-non-shell-$workflow_suffix.out"; then
        pass "workflow .$workflow_suffix exempts only an exact known non-shell selector"
    else
        sed -n '1,20p' "$TMP_ROOT/exact-non-shell-$workflow_suffix.out" >&2
        fail "exact .$workflow_suffix non-shell selector was not preserved"
    fi

    cat > "$REPO_ROOT/.github/workflows/inline-run.$workflow_suffix" <<YAML
name: Inline run suppression
on: workflow_dispatch
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: probe $SILENT_SUPPRESSION
YAML
    if run_silent_failure_hook \
        ".github/workflows/inline-run.$workflow_suffix" \
        "$TMP_ROOT/inline-run-$workflow_suffix.out"; then
        fail "hook accepted inline .$workflow_suffix run suppression"
    elif grep -Fq \
        "forbidden silent-failure workaround in workflow run command" \
        "$TMP_ROOT/inline-run-$workflow_suffix.out"; then
        pass "hook rejects inline .$workflow_suffix run suppression"
    else
        sed -n '1,20p' "$TMP_ROOT/inline-run-$workflow_suffix.out" >&2
        fail "inline .$workflow_suffix suppression lacked its diagnostic"
    fi

    cat > "$REPO_ROOT/.github/workflows/inline-controls.$workflow_suffix" <<YAML
name: Inline workflow controls
on: workflow_dispatch
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - continue-on-error: true
        run: printf '%s\n' safe
      - run: echo ::warning::advisory
YAML
    if run_silent_failure_hook \
        ".github/workflows/inline-controls.$workflow_suffix" \
        "$TMP_ROOT/inline-controls-$workflow_suffix.out"; then
        fail "hook accepted inline .$workflow_suffix workflow opt-outs"
    elif grep -Fq "forbidden continue-on-error true" \
        "$TMP_ROOT/inline-controls-$workflow_suffix.out" \
        && grep -Fq \
        "forbidden advisory warning annotation in workflow run command" \
        "$TMP_ROOT/inline-controls-$workflow_suffix.out"; then
        pass "hook rejects inline .$workflow_suffix workflow opt-outs"
    else
        sed -n '1,20p' \
            "$TMP_ROOT/inline-controls-$workflow_suffix.out" >&2
        fail "inline .$workflow_suffix workflow opt-outs lacked diagnostics"
    fi

    cat > "$REPO_ROOT/.github/workflows/aliased-run.$workflow_suffix" <<YAML
name: Aliased run suppression
on: workflow_dispatch
x-command: &command |
  probe $SILENT_SUPPRESSION
  echo ::warning::advisory
x-continue: &continue true
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - continue-on-error: *continue
        run: *command
YAML
    if run_silent_failure_hook \
        ".github/workflows/aliased-run.$workflow_suffix" \
        "$TMP_ROOT/aliased-run-$workflow_suffix.out"; then
        fail "hook accepted aliased .$workflow_suffix workflow opt-outs"
    elif grep -Fq \
        "forbidden silent-failure workaround in workflow run command" \
        "$TMP_ROOT/aliased-run-$workflow_suffix.out" \
        && grep -Fq "forbidden continue-on-error true" \
        "$TMP_ROOT/aliased-run-$workflow_suffix.out" \
        && grep -Fq \
        "forbidden advisory warning annotation in workflow run command" \
        "$TMP_ROOT/aliased-run-$workflow_suffix.out"; then
        pass "hook rejects aliased .$workflow_suffix workflow opt-outs"
    else
        sed -n '1,20p' "$TMP_ROOT/aliased-run-$workflow_suffix.out" >&2
        fail "aliased .$workflow_suffix workflow opt-outs lacked diagnostics"
    fi

    cat > "$REPO_ROOT/.github/workflows/malformed.$workflow_suffix" <<'YAML'
name: Malformed workflow
jobs: [
YAML
    if run_silent_failure_hook \
        ".github/workflows/malformed.$workflow_suffix" \
        "$TMP_ROOT/malformed-workflow-$workflow_suffix.out"; then
        fail "hook accepted malformed .$workflow_suffix workflow YAML"
    elif grep -Fq "invalid GitHub Actions workflow YAML" \
        "$TMP_ROOT/malformed-workflow-$workflow_suffix.out"; then
        pass "hook fails closed on malformed .$workflow_suffix workflow YAML"
    else
        sed -n '1,20p' \
            "$TMP_ROOT/malformed-workflow-$workflow_suffix.out" >&2
        fail "malformed .$workflow_suffix workflow lacked its diagnostic"
    fi

    cat > "$REPO_ROOT/.github/workflows/dynamic-continue.$workflow_suffix" <<'YAML'
name: Dynamic continue controls
on: workflow_dispatch
jobs:
  check:
    continue-on-error: ${{ true }}
    runs-on: ubuntu-latest
    env:
      FALSE_ALIAS: &false_alias false
    steps:
      - continue-on-error: "false"
        run: printf '%s\n' unsafe-string
      - continue-on-error: 0
        run: printf '%s\n' unsafe-number
      - continue-on-error: !!str false
        run: printf '%s\n' unsafe-string-tag
      - continue-on-error: !!bool false
        run: printf '%s\n' unsafe-explicit-bool-tag
      - continue-on-error: FALSE
        run: printf '%s\n' unsafe-nonliteral-case
      - continue-on-error: *false_alias
        run: printf '%s\n' unsafe-alias
      - continue-on-error: false
        run: printf '%s\n' safe-literal
YAML
    if run_silent_failure_hook \
        ".github/workflows/dynamic-continue.$workflow_suffix" \
        "$TMP_ROOT/dynamic-continue-$workflow_suffix.out"; then
        fail "hook accepted non-literal .$workflow_suffix continue-on-error values"
    elif [ "$(grep -Fc 'continue-on-error must be the literal false' \
        "$TMP_ROOT/dynamic-continue-$workflow_suffix.out")" -eq 7 ]; then
        pass "hook accepts only literal false for .$workflow_suffix continue-on-error"
    else
        sed -n '1,30p' \
            "$TMP_ROOT/dynamic-continue-$workflow_suffix.out" >&2
        fail "dynamic .$workflow_suffix continue-on-error diagnostics were incomplete"
    fi

    cat > "$REPO_ROOT/.github/workflows/continued-run.$workflow_suffix" <<'YAML'
name: Continued run suppression
on: workflow_dispatch
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: |
          probe || \
            true
      - run: |
          probe || :
      - run: |
          probe || command true
      - run: |
          probe || exit 0
      - run: |
          probe || 2>/dev/null true
      - run: |
          probe ||:
      - run: |
          probe || command 2>/dev/null true
      - run: |
          probe || true >/dev/null
      - run: |
          probe || : ignored
      - run: |
          probe || # keep the control operator pending
            true
      - run: |
          probe ||

          # keep the control operator pending across authored comments
            true
YAML
    if run_silent_failure_hook \
        ".github/workflows/continued-run.$workflow_suffix" \
        "$TMP_ROOT/continued-run-$workflow_suffix.out"; then
        fail "hook accepted continued/no-op .$workflow_suffix run suppressions"
    elif [ "$(grep -Fc 'forbidden' \
        "$TMP_ROOT/continued-run-$workflow_suffix.out")" -eq 11 ]; then
        pass "hook rejects continued/no-op .$workflow_suffix run suppressions"
    else
        sed -n '1,20p' "$TMP_ROOT/continued-run-$workflow_suffix.out" >&2
        fail "continued/no-op .$workflow_suffix suppression lacked its diagnostic"
    fi
done

continued_shell="$REPO_ROOT/scripts/continued-suppression.sh"
cat > "$continued_shell" <<'SH'
#!/bin/sh
probe || \
  true
probe || :
probe || command true
probe || exit 0
probe || 2>/dev/null true
probe ||:
probe || command 2>/dev/null true
probe || true >/dev/null
probe || : ignored
probe || # keep the control operator pending
  true
probe ||

# keep the control operator pending across authored comments
  true
SH
if run_silent_failure_hook \
    "scripts/continued-suppression.sh" \
    "$TMP_ROOT/continued-shell.out"; then
    fail "hook accepted continued/no-op shell suppressions"
elif [ "$(grep -Fc 'forbidden' \
    "$TMP_ROOT/continued-shell.out")" -eq 11 ]; then
    pass "hook rejects continued/no-op shell suppressions"
else
    sed -n '1,20p' "$TMP_ROOT/continued-shell.out" >&2
    fail "continued/no-op shell suppressions lacked complete diagnostics"
fi

printf '\n== silent-failure hook rejects split and redirected no-op commands ==\n'
cat > "$REPO_ROOT/scripts/split-no-op.sh" <<'SH'
#!/bin/sh
probe ||
  true
SH
if run_silent_failure_hook \
    "scripts/split-no-op.sh" "$TMP_ROOT/split-no-op.out"; then
    fail "hook accepted a newline-split true suppression"
elif grep -Fq "newline-split true no-op" "$TMP_ROOT/split-no-op.out"; then
    pass "hook rejects probe || newline true"
else
    sed -n '1,20p' "$TMP_ROOT/split-no-op.out" >&2
    fail "newline-split true suppression lacked its distinct diagnostic"
fi

cat > "$REPO_ROOT/scripts/redirected-no-op.sh" <<'SH'
#!/bin/sh
probe || true >/dev/null
SH
if run_silent_failure_hook \
    "scripts/redirected-no-op.sh" "$TMP_ROOT/redirected-no-op.out"; then
    fail "hook accepted a redirected true suppression"
elif grep -Fq "redirected true no-op" "$TMP_ROOT/redirected-no-op.out"; then
    pass "hook rejects redirected true suppression"
else
    sed -n '1,20p' "$TMP_ROOT/redirected-no-op.out" >&2
    fail "redirected true suppression lacked its distinct diagnostic"
fi

cat > "$REPO_ROOT/scripts/colon-arguments.sh" <<'SH'
#!/bin/sh
probe || : ignored
SH
if run_silent_failure_hook \
    "scripts/colon-arguments.sh" "$TMP_ROOT/colon-arguments.out"; then
    fail "hook accepted a colon no-op with arguments"
elif grep -Fq "colon no-op with arguments" \
    "$TMP_ROOT/colon-arguments.out"; then
    pass "hook rejects colon no-op with ignored arguments"
else
    sed -n '1,20p' "$TMP_ROOT/colon-arguments.out" >&2
    fail "colon no-op with arguments lacked its distinct diagnostic"
fi

printf '\n== silent-failure hook accepts and preserves large authored data ==\n'
large_shell="$REPO_ROOT/scripts/large-comments.sh"
{
    printf '#!/bin/sh\n'
    for ((line_number = 0; line_number < 18000; line_number++)); do
        printf '# safe authored comment 0123456789abcdef0123456789abcdef0123456789abcdef\n'
    done
} > "$large_shell"
large_shell_bytes=$(wc -c < "$large_shell")
large_shell_before=$(shasum -a 256 "$large_shell")
if [ "$large_shell_bytes" -le 1048576 ]; then
    fail "large shell fixture did not exceed one MiB"
elif ! run_silent_failure_hook \
    "scripts/large-comments.sh" "$TMP_ROOT/large-shell.out"; then
    sed -n '1,20p' "$TMP_ROOT/large-shell.out" >&2
    fail "hook rejected structurally safe shell comments over one MiB"
elif [ "$(shasum -a 256 "$large_shell")" != "$large_shell_before" ]; then
    fail "hook changed the large shell source while streaming it"
else
    pass "shell comments over one MiB are accepted and preserved"
fi

cp "$large_shell" "$REPO_ROOT/scripts/large-late-suppression.sh"
printf 'probe %s\n' "$SILENT_SUPPRESSION" \
    >> "$REPO_ROOT/scripts/large-late-suppression.sh"
if run_silent_failure_hook \
    "scripts/large-late-suppression.sh" \
    "$TMP_ROOT/large-late-shell.out"; then
    fail "hook ignored executable suppression after one MiB"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/large-late-shell.out"; then
    pass "hook detects executable suppression after one MiB"
else
    sed -n '1,20p' "$TMP_ROOT/large-late-shell.out" >&2
    fail "late shell suppression lacked its diagnostic"
fi

large_workflow="$REPO_ROOT/.github/workflows/large-prose.yaml"
{
    cat <<'YAML'
name: Large authored prose
on: workflow_dispatch
env:
  TASK_DESCRIPTION: |
YAML
    for ((line_number = 0; line_number < 5000; line_number++)); do
        printf '    Safe authored prose 0123456789abcdef0123456789abcdef0123456789abcdef\n'
    done
    cat <<'YAML'
jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - run: printf '%s\n' safe
YAML
} > "$large_workflow"
large_workflow_bytes=$(wc -c < "$large_workflow")
large_workflow_before=$(shasum -a 256 "$large_workflow")
if [ "$large_workflow_bytes" -le 262144 ]; then
    fail "large workflow fixture did not exceed 256 KiB"
elif ! run_silent_failure_hook \
    ".github/workflows/large-prose.yaml" \
    "$TMP_ROOT/large-workflow.out"; then
    sed -n '1,20p' "$TMP_ROOT/large-workflow.out" >&2
    fail "hook rejected a structurally valid authored scalar over 256 KiB"
elif [ "$(shasum -a 256 "$large_workflow")" != "$large_workflow_before" ]; then
    fail "hook changed the large workflow source while streaming it"
else
    pass "authored workflow scalar over 256 KiB is accepted and preserved"
fi

cp "$large_workflow" "$REPO_ROOT/.github/workflows/large-late-run.yaml"
cat >> "$REPO_ROOT/.github/workflows/large-late-run.yaml" <<YAML
      - run: probe $SILENT_SUPPRESSION
YAML
if run_silent_failure_hook \
    ".github/workflows/large-late-run.yaml" \
    "$TMP_ROOT/large-late-workflow.out"; then
    fail "hook ignored an executable workflow payload after 256 KiB"
elif grep -Fq \
    "forbidden silent-failure workaround in workflow run command" \
    "$TMP_ROOT/large-late-workflow.out"; then
    pass "hook detects executable workflow content after 256 KiB"
else
    sed -n '1,20p' "$TMP_ROOT/large-late-workflow.out" >&2
    fail "late workflow suppression lacked its diagnostic"
fi

printf '\n== silent-failure diagnostics are globally bounded ==\n'
diagnostic_budget="$REPO_ROOT/scripts/diagnostic-budget.sh"
{
    printf '#!/bin/sh\n'
    for ((finding = 0; finding < 300; finding++)); do
        printf 'probe || true # finding-%03d\n' "$finding"
    done
} > "$diagnostic_budget"
if run_silent_failure_hook \
    "scripts/diagnostic-budget.sh" \
    "$TMP_ROOT/diagnostic-budget.out"; then
    fail "hook treated exhausted diagnostic capacity as clean"
elif ! grep -Fq "diagnostic budget exceeded; results truncated" \
    "$TMP_ROOT/diagnostic-budget.out"; then
    sed -n '1,20p' "$TMP_ROOT/diagnostic-budget.out" >&2
    fail "diagnostic exhaustion did not report truthful truncation"
elif [ "$(wc -c < "$TMP_ROOT/diagnostic-budget.out")" -gt 65536 ]; then
    fail "diagnostic output exceeded the global byte ceiling"
else
    pass "finding and diagnostic-byte exhaustion is bounded and explicit"
fi

printf '\n== dependency exceptions remain bounded process failures ==\n'
if "$PRE_COMMIT_PYTHON" -I -S - \
    "$ROOT/scripts/check_silent_failures.py" "$TMP_ROOT" \
    > "$TMP_ROOT/dependency-exception.out" 2>&1 <<'PY'
import hashlib
import importlib.util
import os
from pathlib import Path
import sys

policy_path, temporary_root = sys.argv[1:]
spec = importlib.util.spec_from_file_location("dependency_exception_policy", policy_path)
assert spec is not None and spec.loader is not None
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)
sys.dont_write_bytecode = True
prefix = (Path(temporary_root) / "exception-prefix").resolve()
package = prefix / "yaml"
package.mkdir(parents=True)
payload = "raise RuntimeError({!r})\n".format("dependency-parser-failure-" + "x" * 100000)
files = {
    package / "__init__.py": payload.encode("utf-8"),
    package / "events.py": b"class AliasEvent: pass\n",
    package / "nodes.py": (
        b"class MappingNode: pass\n"
        b"class ScalarNode: pass\n"
        b"class SequenceNode: pass\n"
    ),
}
for path, data in files.items():
    path.write_bytes(data)
os.environ["ODYSSEUS_PYYAML_MANIFEST"] = "\n".join(
    "{}={}".format(path, hashlib.sha256(data).hexdigest())
    for path, data in sorted(files.items())
)
old_prefix = sys.prefix
old_path = list(sys.path)
try:
    sys.prefix = str(prefix)
    sys.path.insert(0, str(prefix))
    policy._establish_resource_limits = lambda: None
    policy._bind_runtime = lambda: []
    status = policy.main([])
finally:
    sys.prefix = old_prefix
    sys.path[:] = old_path
assert status == 2, status
PY
then
    if grep -Fq 'Traceback (most recent call last)' \
        "$TMP_ROOT/dependency-exception.out"; then
        fail "dependency exception escaped as a traceback"
    elif [ "$(wc -c < "$TMP_ROOT/dependency-exception.out")" -gt 65536 ]; then
        fail "dependency exception exceeded the diagnostic byte ceiling"
    elif grep -Fq 'diagnostic budget exceeded; results truncated' \
        "$TMP_ROOT/dependency-exception.out"; then
        pass "ordinary dependency exceptions are bounded without traceback"
    else
        sed -n '1,20p' "$TMP_ROOT/dependency-exception.out" >&2
        fail "bounded dependency failure lacked its truncation diagnostic"
    fi
else
    sed -n '1,20p' "$TMP_ROOT/dependency-exception.out" >&2
    fail "ordinary dependency exception escaped the process boundary"
fi

printf '\n== silent-failure workflow structure budgets fail closed ==\n'
document_budget="$REPO_ROOT/.github/workflows/document-budget.yaml"
: > "$document_budget"
for ((document = 1; document <= 33; document++)); do
    printf '%s\nname: document-%d\n' '---' "$document" >> "$document_budget"
done
if run_silent_failure_hook \
    ".github/workflows/document-budget.yaml" \
    "$TMP_ROOT/document-budget.out"; then
    fail "hook treated an exhausted YAML document budget as clean"
elif grep -Fq "workflow YAML document budget exceeded" \
    "$TMP_ROOT/document-budget.out"; then
    pass "YAML document budget exhaustion is an explicit failure"
else
    sed -n '1,20p' "$TMP_ROOT/document-budget.out" >&2
    fail "YAML document budget exhaustion lacked its diagnostic"
fi

depth_budget="$REPO_ROOT/.github/workflows/depth-budget.yaml"
{
    printf 'name: Excessive depth\nx: '
    for ((depth = 0; depth < 70; depth++)); do
        printf '['
    done
    printf 'safe'
    for ((depth = 0; depth < 70; depth++)); do
        printf ']'
    done
    printf '\n'
} > "$depth_budget"
if run_silent_failure_hook \
    ".github/workflows/depth-budget.yaml" \
    "$TMP_ROOT/depth-budget.out"; then
    fail "hook treated an exhausted YAML depth budget as clean"
elif grep -Fq "workflow YAML depth budget exceeded" \
    "$TMP_ROOT/depth-budget.out"; then
    pass "YAML depth budget exhaustion is an explicit failure"
else
    sed -n '1,20p' "$TMP_ROOT/depth-budget.out" >&2
    fail "YAML depth budget exhaustion lacked its diagnostic"
fi

alias_budget="$REPO_ROOT/.github/workflows/alias-budget.yaml"
{
    printf 'name: Excessive aliases\nx-value: &value safe\nx-list:\n'
    for ((alias = 0; alias < 1001; alias++)); do
        printf '  - *value\n'
    done
} > "$alias_budget"
if run_silent_failure_hook \
    ".github/workflows/alias-budget.yaml" \
    "$TMP_ROOT/alias-budget.out"; then
    fail "hook treated an exhausted YAML alias budget as clean"
elif grep -Fq "workflow YAML alias budget exceeded" \
    "$TMP_ROOT/alias-budget.out"; then
    pass "YAML alias budget exhaustion is an explicit failure"
else
    sed -n '1,20p' "$TMP_ROOT/alias-budget.out" >&2
    fail "YAML alias budget exhaustion lacked its diagnostic"
fi

node_budget="$REPO_ROOT/.github/workflows/node-budget.yaml"
{
    printf 'name: Excessive nodes\nx-list:\n'
    for ((node = 0; node < 100001; node++)); do
        printf '  - safe\n'
    done
} > "$node_budget"
if run_silent_failure_hook \
    ".github/workflows/node-budget.yaml" \
    "$TMP_ROOT/node-budget.out"; then
    fail "hook treated an exhausted YAML node budget as clean"
elif grep -Fq "workflow YAML node budget exceeded" \
    "$TMP_ROOT/node-budget.out"; then
    pass "YAML node budget exhaustion is an explicit failure"
else
    sed -n '1,20p' "$TMP_ROOT/node-budget.out" >&2
    fail "YAML node budget exhaustion lacked its diagnostic"
fi

printf '\n== silent-failure checker establishes process resource bounds ==\n'
if "$PRE_COMMIT_PYTHON" -I - \
    "$ROOT/scripts/check_silent_failures.py" <<'PY'
import importlib.util
import resource
import signal
import sys

path = sys.argv[1]
spec = importlib.util.spec_from_file_location("odysseus_silent_failure_policy", path)
assert spec is not None and spec.loader is not None
module = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = module
spec.loader.exec_module(module)
module._establish_resource_limits()
cpu, _ = resource.getrlimit(resource.RLIMIT_CPU)
fds, _ = resource.getrlimit(resource.RLIMIT_NOFILE)
processes, _ = resource.getrlimit(resource.RLIMIT_NPROC)
wall = signal.alarm(0)
assert 0 < cpu <= module.CPU_SECONDS
assert 0 < fds <= module.FILE_DESCRIPTORS
assert 0 < processes <= module.PROCESSES
assert 0 < wall <= module.WALL_SECONDS
if sys.platform.startswith("linux"):
    address_space, _ = resource.getrlimit(resource.RLIMIT_AS)
    assert 0 < address_space <= module.ADDRESS_SPACE_BYTES
PY
then
    pass "checker establishes CPU, wall, process, and descriptor bounds"
else
    fail "checker did not establish every required process resource bound"
fi

printf '\n== silent-failure hook checks executable shell-like files ==\n'
mkdir -p "$REPO_ROOT/scripts"
cat > "$REPO_ROOT/scripts/suppressed.sh" <<SH
#!/bin/sh
probe $SILENT_SUPPRESSION
SH
if run_silent_failure_hook \
    "scripts/suppressed.sh" "$TMP_ROOT/shell-suppression.out"; then
    fail "silent-failure hook accepted shell failure suppression"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/shell-suppression.out"; then
    pass "silent-failure hook rejects shell failure suppression"
else
    sed -n '1,20p' "$TMP_ROOT/shell-suppression.out" >&2
    fail "shell failure suppression failed without a diagnostic"
fi

for executable_path in \
    images/Dockerfile.test \
    tools/Justfile; do
    mkdir -p "$REPO_ROOT/$(dirname "$executable_path")"
    case "$executable_path" in
        *Dockerfile*)
            printf 'RUN probe %s\n' "$SILENT_SUPPRESSION" \
                > "$REPO_ROOT/$executable_path"
            ;;
        *)
            printf 'check:\n    probe %s\n' "$SILENT_SUPPRESSION" \
                > "$REPO_ROOT/$executable_path"
            ;;
    esac
    case_name=${executable_path//\//-}
    if run_silent_failure_hook \
        "$executable_path" "$TMP_ROOT/$case_name-suppression.out"; then
        fail "silent-failure hook omitted required policy scope for $executable_path"
    elif grep -Fq "forbidden silent-failure workaround" \
        "$TMP_ROOT/$case_name-suppression.out"; then
        pass "silent-failure hook enforces command policy for $executable_path"
    else
        sed -n '1,20p' "$TMP_ROOT/$case_name-suppression.out" >&2
        fail "silent-failure hook rejected $executable_path without its policy diagnostic"
    fi
done

cat > "$REPO_ROOT/configs/task.hcl" <<'HCL'
task "check" {
  driver = "raw_exec"
  config {
    command = "bash"
    args = ["-c", "probe || true"]
  }
}
HCL
if run_silent_failure_hook \
    "configs/task.hcl" "$TMP_ROOT/configs-task-hcl-suppression.out"; then
    fail "silent-failure hook omitted executable HCL command arguments"
elif grep -Fq "forbidden silent-failure workaround" \
    "$TMP_ROOT/configs-task-hcl-suppression.out"; then
    pass "silent-failure hook enforces executable HCL command arguments"
else
    sed -n '1,20p' "$TMP_ROOT/configs-task-hcl-suppression.out" >&2
    fail "executable HCL suppression lacked its policy diagnostic"
fi

printf '\nResult: %d passed, %d failed\n' "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    exit 1
fi
printf 'PRE_COMMIT_CONFIG_SELECTION_TESTS_COMPLETE\n'
