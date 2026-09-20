#!/usr/bin/env bash
# Integration tests for Odysseus justfile recipe integrity (issue #198).
# Build-free: no compilation, NATS, podman, or submodules required.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$SCRIPT_DIR")"
if ! JUST_BIN="$(command -v just)" || [ -z "$JUST_BIN" ]; then
    printf '%s\n' 'ERROR: just is required for recipe tests' >&2
    exit 1
fi
HOST_PATH=$PATH
if ! REAL_GIT_BIN=$(command -v git) || [ -z "$REAL_GIT_BIN" ]; then
    printf '%s\n' 'ERROR: git is required for recipe tests' >&2
    exit 1
fi
if ! REAL_GREP_BIN=$(command -v grep) || [ -z "$REAL_GREP_BIN" ]; then
    printf '%s\n' 'ERROR: grep is required for recipe tests' >&2
    exit 1
fi
# shellcheck source=../e2e/lib/common.sh
source "$ROOT/e2e/lib/common.sh"
cd "$ROOT" || exit 1
unset BASH_ENV PYTHONPATH
for git_variable in "${!GIT_@}"; do
    unset "$git_variable"
done

lint_fixture_prefix="${TMPDIR:-/tmp}/odysseus-lint-contract."
alias_fixture_prefix="${TMPDIR:-/tmp}/odysseus-just-alias."
argus_fixture_prefix="${TMPDIR:-/tmp}/odysseus-argus-start."
lint_fixture=""
alias_fixture=""
argus_fixture=""

make_fixture_directory() {
    local prefix="$1" created suffix
    if ! created="$(mktemp -d "${prefix}XXXXXX")"; then
        return 1
    fi
    suffix="${created#"$prefix"}"
    if [ -z "$created" ] || [ "$suffix" = "$created" ] || [ -z "$suffix" ] \
        || [ ! -d "$created" ] || [ -L "$created" ]; then
        return 1
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*) return 1 ;;
    esac
    printf '%s\n' "$created"
}

cleanup_fixture_directory() {
    local directory="$1" prefix="$2" suffix
    [ -n "$directory" ] || return
    suffix="${directory#"$prefix"}"
    if [ "$suffix" = "$directory" ] || [ -z "$suffix" ] \
        || [ ! -d "$directory" ] || [ -L "$directory" ]; then
        printf 'ERROR: refusing unsafe justfile fixture cleanup: %s\n' \
            "$directory" >&2
        return
    fi
    case "$suffix" in
        *[!A-Za-z0-9]*)
            printf 'ERROR: refusing unsafe justfile fixture cleanup: %s\n' \
                "$directory" >&2
            return
            ;;
    esac
    if ! rm -rf -- "$directory"; then
        printf 'ERROR: failed to remove justfile fixture: %s\n' "$directory" >&2
    fi
}

cleanup_fixtures() {
    cleanup_fixture_directory "$argus_fixture" "$argus_fixture_prefix"
    cleanup_fixture_directory "$alias_fixture" "$alias_fixture_prefix"
    cleanup_fixture_directory "$lint_fixture" "$lint_fixture_prefix"
}
trap cleanup_fixtures EXIT

run_clean_shell() {
    local shell_bin="$1"
    local git_variable
    shift
    (
        # Preserve each caller-selected behavior-test variable while removing
        # every ambient Git routing/configuration variable, including indexed
        # GIT_CONFIG_KEY_* and GIT_CONFIG_VALUE_* entries.
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        "$shell_bin" "$@"
    )
}

run_fixture_git() {
    local git_variable
    (
        for git_variable in "${!GIT_@}"; do
            unset "$git_variable"
        done
        unset BASH_ENV PYTHONPATH
        GIT_CONFIG_GLOBAL=/dev/null \
        GIT_CONFIG_NOSYSTEM=1 \
        HOME="$lint_fixture/fixture-home" \
        LC_ALL=C \
        PATH="$HOST_PATH" \
        TMPDIR="$lint_fixture" \
        "$REAL_GIT_BIN" "$@"
    )
}

prepare_decoy_repository() {
    decoy_path=$1
    mkdir -p "$decoy_path"
    run_fixture_git -C "$decoy_path" init -q
    run_fixture_git -C "$decoy_path" config user.email test@example.invalid
    run_fixture_git -C "$decoy_path" config user.name "Git Isolation Test"
    run_fixture_git -C "$decoy_path" config commit.gpgsign false
    printf 'decoy sentinel\n' > "$decoy_path/sentinel.txt"
    run_fixture_git -C "$decoy_path" add sentinel.txt
    run_fixture_git -C "$decoy_path" commit -q -m "Add decoy sentinel"
}

capture_install_plan() {
    local just_bin="$1" role="$2"
    "$just_bin" --dry-run "install-$role" 2>&1
}

info "justfile parse round-trip"
if just --summary >/dev/null 2>&1; then pass "just --summary parses"; else fail "just --summary failed"; fi
if just --list >/dev/null 2>&1; then pass "just --list parses"; else fail "just --list failed"; fi

info "retained root entry points exist"
recipes=$(just --summary | tr ' ' '\n' | sort -u)
for r in bootstrap status argus-start validate-configs ci \
         validate-nats validate-compose test-justfile-recipes \
         test-resource-bounds test-pinned-build-inputs lane-models loop-env \
         check-hierarchy-sync; do
    if printf '%s\n' "$recipes" | grep -qx "$r"; then
        pass "recipe present: $r"
    else
        fail "recipe MISSING: $r"
    fi
done

info "root C++ recipes delegate to the exact-gitlink snapshot helper"
for mapping in \
    '_build-agamemnon:agamemnon' \
    '_build-nestor:nestor' \
    '_build-charybdis:charybdis' \
    '_build-keystone:keystone' \
    '_build-myrmidon:myrmidon'; do
    recipe=${mapping%%:*}
    component=${mapping#*:}
    if build_plan=$("$JUST_BIN" --dry-run "$recipe" 2>&1) \
        && grep -Fqx \
            "BASH_ENV= ENV= /bin/bash -p scripts/build-pinned-submodule.sh $component" \
            <<< "$build_plan"; then
        pass "$recipe uses the pinned-input helper"
    else
        fail "$recipe bypasses the pinned-input helper"
    fi
done

info "retired broken agent-surface recipes stay absent"
for r in mnemosyne-generate-marketplace athena-start apply-all \
         start-console odysseus-console update-submodules \
         start-nats start-agamemnon start-nestor \
         start-agamemnon-native start-nestor-native start-hermes \
         start-myrmidon start-argus hermes-start \
         crosshost-up crosshost-test \
         hermes-hub-up hermes-hub-test hermes-hub-down hermes-hub-logs \
         keystone-start keystone-status telemachy-run scylla-test \
         fleet-build-vessel fleet-build-all fleet-verify fleet-test \
         fleet-push fleet-clean proteus-build proteus-test \
         proteus-pipeline proteus-lint proteus-validate proteus-dispatch \
         proteus-check mnemosyne-validate mnemosyne-test mnemosyne-check \
         hephaestus-test hephaestus-lint hephaestus-format \
         hephaestus-typecheck hephaestus-check hephaestus-audit \
         athena-lint athena-test athena-bootstrap _build-odyssey; do
    if printf '%s\n' "$recipes" | grep -qx "$r"; then
        fail "retired recipe unexpectedly present: $r"
    else
        pass "retired recipe absent: $r"
    fi
done
if "$JUST_BIN" --show _build-odyssey >/dev/null 2>&1; then
    fail "retired private component recipe unexpectedly present: _build-odyssey"
else
    pass "retired private component recipe absent: _build-odyssey"
fi
if grep -Eq \
    '^[[:space:]]*cd (agentic|ci-cd|control|infrastructure|provisioning|research|shared|testing)/[^ ]+ && .*just([[:space:]]|$)' \
    justfile; then
    fail "root justfile still executes a live component justfile"
else
    pass "root justfile has no live component-just proxy"
fi

info "pinned Atlas compatibility recipes remain until consumer migration"
for r in atlas-review-dispatch atlas-review-aggregate atlas-review-status; do
    if printf '%s\n' "$recipes" | grep -qx "$r"; then
        pass "Atlas compatibility recipe present: $r"
    else
        fail "Atlas compatibility recipe missing before consumer migration: $r"
    fi
done

info "lint validates component availability without executing component recipes"
if ! lint_fixture="$(make_fixture_directory "$lint_fixture_prefix")"; then
    printf '%s\n' 'ERROR: could not create a safe lint fixture' >&2
    exit 1
fi
lint_bin="$lint_fixture/bin"
mkdir -p "$lint_bin" "$lint_fixture/clean-home" "$lint_fixture/fixture-home"

info "test helpers isolate fixture Git operations from hostile ambient state"
staged_decoy="$lint_fixture/staged-decoy"
prepare_decoy_repository "$staged_decoy"
staged_decoy_before=$(cksum \
    "$staged_decoy/.git/index" "$staged_decoy/.git/config" \
    "$staged_decoy/sentinel.txt")
if GIT_DIR="$staged_decoy/.git" \
   GIT_WORK_TREE="$staged_decoy" \
   GIT_INDEX_FILE="$staged_decoy/.git/index" \
   GIT_CONFIG_COUNT=1 \
   GIT_CONFIG_KEY_0=core.hooksPath \
   GIT_CONFIG_VALUE_0="$staged_decoy/injected-hooks" \
   "$BASH" tests/test-pre-commit-staged-content.sh \
       > "$lint_fixture/staged-hostile-env.out" 2>&1 \
   && grep -Fqx "PRE_COMMIT_STAGED_CONTENT_TESTS_COMPLETE" \
       "$lint_fixture/staged-hostile-env.out"; then
    staged_hostile_ok=1
else
    staged_hostile_ok=0
fi
staged_decoy_after=$(cksum \
    "$staged_decoy/.git/index" "$staged_decoy/.git/config" \
    "$staged_decoy/sentinel.txt")
if [ "$staged_hostile_ok" -eq 1 ] \
   && [ "$staged_decoy_before" = "$staged_decoy_after" ]; then
    pass "staged-content fixtures ignore hostile Git repository selection"
else
    sed -n '1,80p' "$lint_fixture/staged-hostile-env.out" >&2
    fail "staged-content fixtures used hostile Git repository selection"
fi

config_decoy="$lint_fixture/config-decoy"
prepare_decoy_repository "$config_decoy"
config_decoy_before=$(cksum \
    "$config_decoy/.git/index" "$config_decoy/.git/config" \
    "$config_decoy/sentinel.txt")
if GIT_DIR="$config_decoy/.git" \
   GIT_WORK_TREE="$config_decoy" \
   GIT_INDEX_FILE="$config_decoy/.git/index" \
   GIT_CONFIG_COUNT=1 \
   GIT_CONFIG_KEY_0=core.hooksPath \
   GIT_CONFIG_VALUE_0="$config_decoy/injected-hooks" \
   "$BASH" tests/test-pre-commit-config-selection.sh \
       > "$lint_fixture/config-hostile-env.out" 2>&1 \
   && grep -Fqx "PRE_COMMIT_CONFIG_SELECTION_TESTS_COMPLETE" \
       "$lint_fixture/config-hostile-env.out"; then
    config_hostile_ok=1
else
    config_hostile_ok=0
fi
config_decoy_after=$(cksum \
    "$config_decoy/.git/index" "$config_decoy/.git/config" \
    "$config_decoy/sentinel.txt")
if [ "$config_hostile_ok" -eq 1 ] \
   && [ "$config_decoy_before" = "$config_decoy_after" ]; then
    pass "config-selection fixtures ignore hostile Git repository selection"
else
    sed -n '1,80p' "$lint_fixture/config-hostile-env.out" >&2
    fail "config-selection fixtures used hostile Git repository selection"
fi

runner_decoy="$lint_fixture/runner-decoy"
runner_target="$lint_fixture/runner-target"
prepare_decoy_repository "$runner_decoy"
mkdir -p "$runner_target"
run_fixture_git -C "$runner_target" init -q
runner_decoy_before=$(cksum \
    "$runner_decoy/.git/index" "$runner_decoy/.git/config" \
    "$runner_decoy/sentinel.txt")
runner_probe="$lint_fixture/git-environment-probe.sh"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'set -eu' \
    'git -C "$1" config test.isolation target' \
    > "$runner_probe"
chmod +x "$runner_probe"
if GIT_DIR="$runner_decoy/.git" \
   GIT_WORK_TREE="$runner_decoy" \
   GIT_INDEX_FILE="$runner_decoy/.git/index" \
   GIT_CONFIG_COUNT=1 \
   GIT_CONFIG_KEY_0=core.hooksPath \
   GIT_CONFIG_VALUE_0="$runner_decoy/injected-hooks" \
   run_clean_shell "$BASH" "$runner_probe" "$runner_target"; then
    runner_probe_ok=1
else
    runner_probe_ok=0
fi
runner_target_value=""
if ! runner_target_value=$(run_fixture_git -C "$runner_target" \
    config --get test.isolation); then
    runner_target_value=""
fi
runner_decoy_after=$(cksum \
    "$runner_decoy/.git/index" "$runner_decoy/.git/config" \
    "$runner_decoy/sentinel.txt")
if [ "$runner_probe_ok" -eq 1 ] \
   && [ "$runner_target_value" = "target" ] \
   && [ "$runner_decoy_before" = "$runner_decoy_after" ]; then
    pass "clean-shell runner removes hostile Git repository selection"
else
    fail "clean-shell runner exposed a child to hostile Git repository selection"
fi

setup_sentinel="$lint_fixture/setup-outside-sentinel"
printf 'outside sentinel\n' > "$setup_sentinel"
setup_sentinel_before=$(cksum "$setup_sentinel")
failing_mktemp="$lint_fixture/failing-mktemp"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''invoked\n'\'' > "${ODYSSEUS_TEST_SETUP_LOG:?}"' \
    'exit 72' \
    > "$failing_mktemp"
chmod +x "$failing_mktemp"
if ODYSSEUS_TEST_MKTEMP="$failing_mktemp" \
   ODYSSEUS_TEST_SETUP_LOG="$lint_fixture/mktemp-invoked" \
   "$BASH" tests/test-pre-commit-staged-content.sh \
       > "$lint_fixture/mktemp-failure.out" 2>&1; then
    mktemp_failure_ok=0
elif grep -Fq "could not create a safe pre-commit test fixture" \
    "$lint_fixture/mktemp-failure.out" \
    && grep -Fqx "invoked" "$lint_fixture/mktemp-invoked"; then
    mktemp_failure_ok=1
else
    mktemp_failure_ok=0
fi
setup_sentinel_after=$(cksum "$setup_sentinel")
if [ "$mktemp_failure_ok" -eq 1 ] \
   && [ "$setup_sentinel_before" = "$setup_sentinel_after" ]; then
    pass "failed fixture-root creation stops without outside mutation"
else
    sed -n '1,80p' "$lint_fixture/mktemp-failure.out" >&2
    fail "failed fixture-root creation continued into unsafe setup"
fi

if ODYSSEUS_TEST_MKTEMP="$failing_mktemp" \
   ODYSSEUS_TEST_SETUP_LOG="$lint_fixture/config-mktemp-invoked" \
   "$BASH" tests/test-pre-commit-config-selection.sh \
       > "$lint_fixture/config-mktemp-failure.out" 2>&1; then
    config_mktemp_failure_ok=0
elif grep -Fq "could not create the pre-commit selection fixture" \
    "$lint_fixture/config-mktemp-failure.out" \
    && grep -Fqx "invoked" "$lint_fixture/config-mktemp-invoked"; then
    config_mktemp_failure_ok=1
else
    config_mktemp_failure_ok=0
fi
setup_sentinel_after=$(cksum "$setup_sentinel")
if [ "$config_mktemp_failure_ok" -eq 1 ] \
   && [ "$setup_sentinel_before" = "$setup_sentinel_after" ]; then
    pass "failed selection-fixture creation stops without outside mutation"
else
    sed -n '1,80p' "$lint_fixture/config-mktemp-failure.out" >&2
    fail "failed selection-fixture creation continued into unsafe setup"
fi

failing_git_bin="$lint_fixture/failing-git-bin"
failing_git_log="$lint_fixture/failing-git.log"
mkdir -p "$failing_git_bin"
printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf '\''sentinel=%s args=%s\n'\'' "${ODYSSEUS_TEST_NON_GIT_SENTINEL:-missing}" "$*" >> "${ODYSSEUS_TEST_GIT_LOG:?}"' \
    'exit 73' \
    > "$failing_git_bin/git"
chmod +x "$failing_git_bin/git"
if ODYSSEUS_TEST_GIT_LOG="$failing_git_log" \
   ODYSSEUS_TEST_NON_GIT_SENTINEL=preserved \
   PATH="$failing_git_bin:$HOST_PATH" \
   "$BASH" tests/test-pre-commit-staged-content.sh \
       > "$lint_fixture/git-setup-failure.out" 2>&1; then
    git_setup_failure_ok=0
elif grep -Fq "failed to initialize pre-commit fixture repository" \
    "$lint_fixture/git-setup-failure.out" \
    && grep -Fq "sentinel=preserved" "$failing_git_log" \
    && [ "$(awk 'END { print NR }' "$failing_git_log")" -eq 1 ]; then
    git_setup_failure_ok=1
else
    git_setup_failure_ok=0
fi
setup_sentinel_after=$(cksum "$setup_sentinel")
if [ "$git_setup_failure_ok" -eq 1 ] \
   && [ "$setup_sentinel_before" = "$setup_sentinel_after" ]; then
    pass "failed fixture repository setup stops without outside mutation"
else
    sed -n '1,80p' "$lint_fixture/git-setup-failure.out" >&2
    fail "failed fixture repository setup continued after the first error"
fi

ln -s "$BASH" "$lint_bin/bash"
for tool in sh awk grep tr touch; do
    ln -s "$(command -v "$tool")" "$lint_bin/$tool"
done
ln -s "$JUST_BIN" "$lint_bin/just"
for tool in python python3 shellcheck; do
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$lint_bin/$tool"
    chmod +x "$lint_bin/$tool"
done
cat > "$lint_bin/pixi" <<'EOF'
#!/usr/bin/env bash
set -u
[ "${1:-}" = run ] || exit 64
shift
exec "$@"
EOF
chmod +x "$lint_bin/pixi"
cat > "$lint_bin/git" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
    config)
        printf 'submodule.fixture.path %s\n' \
            "${ODYSSEUS_TEST_SUBMODULE_PATH:-/expected/component}"
        ;;
    ls-files)
        if [ "${ODYSSEUS_TEST_LS_FILES_FAIL:-0}" = "1" ]; then
            exit 46
        fi
        # Return a real first-party shell path.  The unavailable-ShellCheck
        # case must keep a valid non-empty inventory so its only failure is
        # the missing required tool, not an empty-inventory shortcut.
        printf '%s\n' 'tests/test-pre-commit-staged-content.sh'
        ;;
    submodule)
        case "${2:-}" in
            status)
                case "${ODYSSEUS_TEST_SUBMODULE_MODE:-}" in
                    one|incomplete)
                        printf ' %040d %s\n' 0 "${ODYSSEUS_TEST_SUBMODULE_PATH:?}"
                        ;;
                    discovery-error|empty)
                        ;;
                    *)
                        exit 48
                        ;;
                esac
                ;;
            --quiet)
                case "${ODYSSEUS_TEST_SUBMODULE_MODE:-}" in
                    discovery-error)
                        exit 47
                        ;;
                    one)
                        printf '%s\n' "${ODYSSEUS_TEST_SUBMODULE_PATH:?}"
                        ;;
                    incomplete|empty)
                        ;;
                    *)
                        exit 48
                        ;;
                esac
                ;;
            *)
                exit 48
                ;;
        esac
        ;;
    *)
        exit 49
        ;;
esac
EOF
chmod +x "$lint_bin/git"

hostile_component="$lint_fixture/hostile-component"
hostile_parse_marker="$lint_fixture/hostile-parse-ran"
hostile_recipe_marker="$lint_fixture/hostile-recipe-ran"
mkdir -p "$hostile_component"
printf 'probe := `touch "%s"`\nlint:\n    @touch "%s"\n' \
    "$hostile_parse_marker" "$hostile_recipe_marker" \
    > "$hostile_component/justfile"
printf 'lint:\n    @touch "%s"\n' "$hostile_recipe_marker" \
    > "$hostile_component/Justfile"
if ODYSSEUS_TEST_SUBMODULE_MODE=one \
   ODYSSEUS_TEST_SUBMODULE_PATH="$hostile_component" \
   PATH="$lint_bin" "$JUST_BIN" lint > "$lint_fixture/hostile.out" 2>&1 \
   && [ ! -e "$hostile_parse_marker" ] \
   && [ ! -e "$hostile_recipe_marker" ] \
   && grep -Fq -- "--- lint complete ---" "$lint_fixture/hostile.out"; then
    pass "root lint never parses or runs live component recipes"
else
    sed -n '1,80p' "$lint_fixture/hostile.out" >&2
    fail "root lint executed or depended on mutable component recipe bytes"
fi

if ODYSSEUS_TEST_SUBMODULE_MODE=discovery-error \
   PATH="$lint_bin" "$JUST_BIN" lint > "$lint_fixture/discovery.out" 2>&1; then
    fail "lint accepted failed submodule discovery"
else
    pass "lint rejects failed submodule discovery"
fi

if ODYSSEUS_TEST_SUBMODULE_MODE=one \
   ODYSSEUS_TEST_SUBMODULE_PATH="$hostile_component" \
   ODYSSEUS_TEST_LS_FILES_FAIL=1 \
   PATH="$lint_bin" "$JUST_BIN" lint > "$lint_fixture/shell-inventory.out" 2>&1; then
    fail "lint accepted an unavailable tracked-shell inventory"
elif grep -Fq "no tracked shell scripts to check" "$lint_fixture/shell-inventory.out"; then
    fail "lint converted a failed tracked-shell inventory into an empty success"
else
    pass "lint rejects a failed tracked-shell inventory"
fi

mv "$lint_bin/shellcheck" "$lint_fixture/shellcheck-disabled"
if ODYSSEUS_TEST_SUBMODULE_MODE=one \
   ODYSSEUS_TEST_SUBMODULE_PATH="$hostile_component" \
   PATH="$lint_bin" "$JUST_BIN" lint > "$lint_fixture/no-shellcheck.out" 2>&1; then
    fail "lint accepted an unavailable required shellcheck"
elif grep -Fq "shellcheck not on PATH, skipping" "$lint_fixture/no-shellcheck.out"; then
    fail "lint reported an unavailable required shellcheck as skipped"
elif ! grep -Fqx "ERROR: lint failed in: root:shellcheck-unavailable" \
    "$lint_fixture/no-shellcheck.out"; then
    sed -n '1,80p' "$lint_fixture/no-shellcheck.out" >&2
    fail "shellcheck-unavailable test had another failure cause"
else
    pass "lint rejects shellcheck absence as its sole failure cause"
fi
mv "$lint_fixture/shellcheck-disabled" "$lint_bin/shellcheck"

if ODYSSEUS_TEST_SUBMODULE_MODE=empty \
   PATH="$lint_bin" "$JUST_BIN" lint > "$lint_fixture/empty-inventory.out" 2>&1; then
    fail "lint accepted an empty pinned component inventory"
else
    pass "lint rejects an empty pinned component inventory"
fi

if [ "${ODYSSEUS_TEST_JUSTFILE_LINT_ONLY:-0}" = "1" ]; then
    summary
    exit_code
    exit $?
fi

info "legacy justfile-test alias propagates delegated failures"
if ! alias_fixture="$(make_fixture_directory "$alias_fixture_prefix")"; then
    printf '%s\n' 'ERROR: could not create a safe just-alias fixture' >&2
    exit 1
fi
cat > "$alias_fixture/just" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' delegated > "${ODYSSEUS_TEST_JUST_MARKER:?}"
exit 37
EOF
chmod +x "$alias_fixture/just"
if ODYSSEUS_TEST_JUST_MARKER="$alias_fixture/delegated" \
   PATH="$alias_fixture:/usr/bin:/bin" \
   "$JUST_BIN" e2e-test-justfiles > "$alias_fixture/output" 2>&1; then
    fail "legacy justfile-test alias swallowed a delegated failure"
elif [ ! -e "$alias_fixture/delegated" ]; then
    fail "legacy justfile-test alias did not delegate"
else
    pass "legacy justfile-test alias propagates delegated failures"
fi

info "host installers stop before an operator selects a deployment path"
for role in worker control; do
    if ! install_plan="$(capture_install_plan "$JUST_BIN" "$role")"; then
        fail "install-$role dry-run failed before its plan could be inspected"
        continue
    fi
    if grep -Eqi 'host ready|just start-(nats|agamemnon|nestor|hermes|myrmidon)' <<< "$install_plan"; then
        fail "install-$role claims deployment readiness"
    elif grep -Fq 'docs/deployment.md' <<< "$install_plan"; then
        pass "install-$role directs deployment verification"
    else
        fail "install-$role omits the deployment verification route"
    fi
    if grep -Fq 'git submodule update --init --recursive' \
        <<< "$install_plan"; then
        fail "install-$role duplicates git submodule update"
    else
        pass "install-$role omits the duplicate git submodule update"
    fi
done

fake_dry_run="$lint_fixture/failing-just-dry-run"
cat > "$fake_dry_run" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'error: could not parse recipe; see docs/deployment.md' >&2
exit 42
EOF
chmod +x "$fake_dry_run"
if failed_install_plan="$(capture_install_plan "$fake_dry_run" worker)"; then
    fail "installer-plan oracle accepted a failed dry run containing documentation text"
elif ! grep -Fq 'docs/deployment.md' <<< "$failed_install_plan"; then
    fail "failed dry-run fixture omitted the text needed to exercise the old false pass"
else
    pass "installer-plan oracle rejects a failed dry run before inspecting its output"
fi

info "pinned Argus activation fails before component or container mutation"
if ! argus_fixture="$(make_fixture_directory "$argus_fixture_prefix")"; then
    printf '%s\n' 'ERROR: could not create a safe Argus fixture' >&2
    exit 1
fi
cat > "$argus_fixture/just" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' invoked > "${ODYSSEUS_TEST_ARGUS_MARKER:?}"
exit 0
EOF
chmod +x "$argus_fixture/just"
if ODYSSEUS_TEST_ARGUS_MARKER="$argus_fixture/child-invoked" \
   PATH="$argus_fixture:/usr/bin:/bin" \
   "$JUST_BIN" argus-start > "$argus_fixture/output" 2>&1; then
    fail "argus-start reported successful activation at the broken pin"
elif [ -e "$argus_fixture/child-invoked" ]; then
    fail "argus-start invoked the broken pinned component recipe"
elif grep -Eqi 'unavailable|cannot.*start' "$argus_fixture/output"; then
    pass "argus-start fails closed before component mutation"
else
    fail "argus-start omitted its unavailable boundary"
fi

info "example configuration does not reactivate retired cross-host topology"
if grep -Eq '^(WORKER_HOST_IP|CONTROL_HOST_IP)=' .env.example; then
    fail ".env.example still publishes retired cross-host host variables"
else
    pass ".env.example omits retired cross-host host variables"
fi
if grep -Eq '^NATS_URL=.*nats://' .env.example; then
    fail ".env.example still advertises unauthenticated plain-NATS transport"
elif grep -Eq '^NATS_URL=.*tls://' .env.example; then
    pass ".env.example advertises an identity-bound TLS transport placeholder"
else
    fail ".env.example omits a TLS NATS transport placeholder"
fi
if grep -Fqx 'HOMERIC_LEGACY_SERVICE_UID=""' .env.example; then
    pass ".env.example requires an operator-selected legacy service UID"
else
    fail ".env.example does not leave the legacy service identity unselected"
fi
if (set -a; source .env.example); then
    pass ".env.example remains shell-readable"
else
    fail ".env.example is not shell-readable"
fi

info "Code Quality audit preserves remote readback uncertainty"
if run_clean_shell bash tests/test-probe-code-quality.sh; then
    pass "Code Quality discovery behavior checks pass"
else
    fail "Code Quality discovery behavior checks failed"
fi

if run_clean_shell bash tests/test-hermes-hub-retired.sh; then
    pass "retired remote-topology entry points are no-write"
else
    fail "retired remote-topology entry points made an external call"
fi
for retired_path in \
    docker-compose.crosshost.yml \
    e2e/docker-compose.hermes-hub.yml \
    e2e/prometheus.crosshost.yml \
    e2e/hermes-fleet-preflight-fix.sh \
    e2e/test-task-01b925cd.sh \
    tools/github/rename-repo.sh \
    tools/apply-odysseus-rename.sh \
    scripts/git/safe-merge.sh \
    scripts/migration/hephaestus-split/athena-create.sh \
    scripts/migration/hephaestus-split/hephaestus-meta-repo-pr.sh \
    scripts/migration/hephaestus-split/hephaestus-prune-pr.sh; do
    if [ -e "$retired_path" ] || [ -L "$retired_path" ]; then
        fail "retired executable unexpectedly present: $retired_path"
    else
        pass "retired executable absent: $retired_path"
    fi
done
info "unavailable console paths fail closed before NATS or HTTP side effects"
if python3 tests/test_odysseus_console.py; then
    pass "console availability boundary checks pass"
else
    fail "console availability boundary checks failed"
fi

info "ecosystem discovery and hook propagation fail closed"
if run_clean_shell /bin/bash tests/test-gen-ecosystem-table.sh; then
    pass "ecosystem table behavior checks pass"
else
    fail "ecosystem table behavior checks failed"
fi
if run_clean_shell /bin/bash tests/test-ecosystem-health.sh; then
    pass "ecosystem health behavior checks pass"
else
    fail "ecosystem health behavior checks failed"
fi
if run_clean_shell /bin/bash tests/test-propagate-pre-commit-hooks.sh; then
    pass "hook propagation behavior checks pass"
else
    fail "hook propagation behavior checks failed"
fi

info "retired cross-host launcher is unavailable without external effects"
if run_clean_shell bash tests/test-start-crosshost.sh; then
    pass "retired cross-host launcher is no-write"
else
    fail "retired cross-host launcher made an external call"
fi

info "doctor submodule checks fail closed without mutating pinned components"
if run_clean_shell bash tests/test-doctor-submodule-health.sh; then
    pass "doctor submodule boundary checks pass"
else
    fail "doctor submodule boundary checks failed"
fi
if run_clean_shell /bin/bash tests/test-start-stack-fixture-bootstrap.sh; then
    pass "stack fixture bootstrap fails closed"
else
    fail "stack fixture bootstrap accepted failed temporary allocation"
fi
if run_clean_shell /bin/bash tests/test-start-stack-health.sh; then
    pass "stack readiness behavior checks pass"
else
    fail "stack readiness behavior checks failed"
fi
if run_clean_shell /bin/bash tests/test-run-hello-world.sh; then
    pass "hello-world caller boundary checks pass"
else
    fail "hello-world caller boundary checks failed"
fi
if run_clean_shell /bin/bash tests/test-submodule-drift.sh; then
    pass "submodule drift behavior checks pass"
else
    fail "submodule drift behavior checks failed"
fi

info "resource-bound installer checks are part of the required test entry point"
if run_clean_shell "$JUST_BIN" test-resource-bounds; then
    pass "resource-bound installer checks pass through the canonical recipe"
else
    fail "resource-bound installer checks failed through the canonical recipe"
fi

info "exact-gitlink build-input checks are part of the required test entry point"
if run_clean_shell "$JUST_BIN" test-pinned-build-inputs; then
    pass "exact-gitlink build-input checks pass through the canonical recipe"
else
    fail "exact-gitlink build-input checks failed through the canonical recipe"
fi

info "agent tooling behavior checks are part of the required test entry point"
if run_clean_shell bash tests/test-claude-tooling.sh; then
    pass "agent tooling behavior checks pass"
else
    fail "agent tooling behavior checks failed"
fi
if run_clean_shell bash tests/test-root-install-ownership.sh; then
    pass "privileged ownership-repair boundary checks pass"
else
    fail "privileged ownership-repair boundary checks failed"
fi
if run_clean_shell /bin/bash tests/test-agent-contract.sh; then
    pass "agent entry-point contract checks pass"
else
    fail "agent entry-point contract checks failed"
fi
if run_clean_shell /bin/bash tests/test-doc-field-drift.sh; then
    pass "documentation field-drift checks are Bash 3 compatible"
else
    fail "documentation field-drift checks require an unsupported shell builtin"
fi
if run_clean_shell /bin/bash tests/test-lint-test-scripts-discovery.sh; then
    pass "test-script inventory failure checks pass"
else
    fail "test-script inventory failure checks failed"
fi
if run_clean_shell bash tests/test-hierarchy-sync.sh; then
    pass "hierarchy sync behavior checks pass"
else
    fail "hierarchy sync behavior checks failed"
fi

pre_commit_staged_output="$lint_fixture/pre-commit-staged-content.out"
if run_clean_shell "$BASH" tests/test-pre-commit-staged-content.sh \
    > "$pre_commit_staged_output" 2>&1 \
    && grep -Fqx "PRE_COMMIT_STAGED_CONTENT_TESTS_COMPLETE" \
        "$pre_commit_staged_output"; then
    pass "pre-commit staged-content checks complete through $BASH"
else
    sed -n '1,160p' "$pre_commit_staged_output" >&2
    fail "pre-commit staged-content checks did not complete through $BASH"
fi
pre_commit_selection_output="$lint_fixture/pre-commit-config-selection.out"
if run_clean_shell "$BASH" tests/test-pre-commit-config-selection.sh \
    > "$pre_commit_selection_output" 2>&1 \
    && grep -Fqx "PRE_COMMIT_CONFIG_SELECTION_TESTS_COMPLETE" \
        "$pre_commit_selection_output"; then
    pass "pre-commit path selection checks complete through $BASH"
else
    sed -n '1,160p' "$pre_commit_selection_output" >&2
    fail "pre-commit path selection checks did not complete through $BASH"
fi

info "legacy launch recipes bind live runtime identity explicitly"
if run_clean_shell bash tests/test-legacy-launch-recipes.sh; then
    pass "legacy launch recipe behavior checks pass"
else
    fail "legacy launch recipe behavior checks failed"
fi

info "shared retry behavior remains injection-safe"
if run_clean_shell /bin/bash e2e/test-common-retry.sh; then
    pass "common retry behavior checks pass"
else
    fail "common retry behavior checks failed"
fi

info "new hermetic runtime suites are part of the required test entry point"
if run_clean_shell /bin/bash tests/test-run-ipc-tests.sh; then
    pass "IPC runner behavior checks pass"
else
    fail "IPC runner behavior checks failed"
fi
if run_clean_shell /bin/bash tests/test-teardown.sh; then
    pass "stack teardown behavior checks pass"
else
    fail "stack teardown behavior checks failed"
fi
if run_clean_shell /bin/bash tests/test-process-cleanup.sh; then
    pass "background-process cleanup behavior checks pass"
else
    fail "background-process cleanup behavior checks failed"
fi

info "Nomad rendering is explicit, authorized, and parser-gated"
if run_clean_shell bash tests/test-render-nomad-configs.sh; then
    pass "Nomad render behavior checks pass"
else
    fail "Nomad render behavior checks failed"
fi

info "AlexNet teardown is exact-target and terminal-evidence bound"
if run_clean_shell bash tests/test-alexnet-fleet-operations.sh; then
    pass "AlexNet fleet operation behavior checks pass"
else
    fail "AlexNet fleet operation behavior checks failed"
fi
if run_clean_shell bash tests/test-alexnet-fleet-teardown.sh; then
    pass "AlexNet teardown behavior checks pass"
else
    fail "AlexNet teardown behavior checks failed"
fi

summary
exit_code   # e2e/lib/common.sh:41 -- returns non-zero if any fail
