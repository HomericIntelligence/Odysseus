#!/usr/bin/env bash
# Regression contract for Odysseus merge-queue readiness and least privilege.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"

checks=0
failures=0

pass() {
  checks=$((checks + 1))
  echo "PASS: $1"
}

fail() {
  checks=$((checks + 1))
  failures=$((failures + 1))
  echo "FAIL: $1" >&2
}

expected_required_workflows=(
  .github/workflows/_required.yml
  .github/workflows/build-images.yml
  .github/workflows/install-test.yml
  .github/workflows/release.yml
)

required_context_pattern='^[[:space:]]{4}name: (lint|unit-tests|integration-tests|security/dependency-scan|security/secrets-scan|build|schema-validation|deps/version-sync|test|install|release)$'
mapfile -t required_workflows < <(
  grep -lE "$required_context_pattern" .github/workflows/*.yml | sort
)

if [[ "${required_workflows[*]}" == "${expected_required_workflows[*]}" ]]; then
  pass "required contexts are supplied by the expected four workflows"
else
  fail "required-context workflow inventory has drifted"
  printf 'Expected: %s\nActual:   %s\n' \
    "${expected_required_workflows[*]}" "${required_workflows[*]}" >&2
fi

for workflow in "${required_workflows[@]}"; do
  on_block=$(awk '
    /^on:$/ { in_on = 1; next }
    in_on && /^[^[:space:]#]/ { exit }
    in_on { print }
  ' "$workflow")

  if grep -qE '^  merge_group:$' <<<"$on_block" &&
     grep -A1 -E '^  merge_group:$' <<<"$on_block" |
       grep -qE '^    types: \[checks_requested\]$'; then
    pass "$workflow handles merge_group checks_requested"
  else
    fail "$workflow must handle merge_group checks_requested"
  fi

done

if python3 tests/github/workflow-permissions.test.py workflow-defaults; then
  pass "required workflows default validation to parsed contents:read permissions"
else
  fail "required workflows must not grant write permission at workflow scope"
fi

checkout_count=$(grep -hEc 'uses: actions/checkout@' \
  "${required_workflows[@]}" | awk '{ total += $1 } END { print total + 0 }')
nonpersistent_checkout_count=$(grep -hEc 'persist-credentials: false' \
  "${required_workflows[@]}" | awk '{ total += $1 } END { print total + 0 }')
if [[ "$checkout_count" -eq "$nonpersistent_checkout_count" ]]; then
  pass "required workflows do not persist checkout credentials"
else
  fail "every checkout in a required workflow must disable persisted credentials"
fi

if python3 tests/github/workflow-permissions.test.py build-validation; then
  pass "Build Images PR/merge_group/manual validation job is read-only"
else
  fail "Build Images validation must be read-only for PR/merge_group/manual events"
fi

if python3 tests/github/workflow-permissions.test.py build-publish; then
  pass "Build Images publishing permission is isolated to trusted pushes/tags"
else
  fail "Build Images publishing must retain packages:write only on trusted pushes/tags"
fi

if python3 tests/github/workflow-permissions.test.py release-publish; then
  pass "Release publishing retains contents:write only on trusted tag pushes"
else
  fail "Release publish job must own the only contents:write grant"
fi

if python3 tests/github/workflow-permissions.test.py release-validation; then
  pass "Release PR/merge_group validation job is read-only"
else
  fail "Release validation exposes write permission"
fi

if grep -qE "^[[:space:]]+if: github.event_name != 'merge_group'$" \
    .github/workflows/install-test.yml; then
  pass "Install test excludes its non-required matrix from merge groups"
else
  fail "Install test must exclude its non-required matrix from merge groups"
fi

expected_contexts='["lint","unit-tests","integration-tests","security/dependency-scan","security/secrets-scan","build","schema-validation","deps/version-sync","test","install","release"]'
ruleset_files=(
  configs/github/repo-ruleset.json
  configs/github/repo-ruleset-active.json
  configs/github/repo-ruleset-evaluate.json
)

declare -A expected_enforcement=(
  [configs/github/repo-ruleset.json]=active
  [configs/github/repo-ruleset-active.json]=active
  [configs/github/repo-ruleset-evaluate.json]=evaluate
)

for ruleset in "${ruleset_files[@]}"; do
  if jq -e '
      .target == "branch" and
      .conditions.ref_name.include == ["refs/heads/main"] and
      .conditions.ref_name.exclude == []
    ' "$ruleset" >/dev/null; then
    pass "$ruleset targets only main"
  else
    fail "$ruleset must target only main"
  fi

  if jq -e --arg expected "${expected_enforcement[$ruleset]}" \
      '.enforcement == $expected' "$ruleset" >/dev/null; then
    pass "$ruleset keeps its intended enforcement mode"
  else
    fail "$ruleset enforcement mode has drifted"
  fi

  if jq -e --argjson expected "$expected_contexts" '
      [.rules[] | select(.type == "required_status_checks")
        | .parameters.required_status_checks[].context] == $expected
    ' "$ruleset" >/dev/null; then
    pass "$ruleset records all 11 Odysseus required checks"
  else
    fail "$ruleset does not record the Odysseus required-check contract"
  fi

  if jq -e '
      [.rules[] | select(.type == "merge_queue") | .parameters] == [{
        "check_response_timeout_minutes": 60,
        "grouping_strategy": "ALLGREEN",
        "max_entries_to_build": 10,
        "max_entries_to_merge": 5,
        "merge_method": "SQUASH",
        "min_entries_to_merge": 1,
        "min_entries_to_merge_wait_minutes": 5
      }]
    ' "$ruleset" >/dev/null; then
    pass "$ruleset records the approved merge-queue policy"
  else
    fail "$ruleset merge-queue policy is absent or has drifted"
  fi
done

if grep -qF 'Live complete repository rulesets are authoritative' \
    docs/runbooks/branch-protection-rollout.md &&
   grep -qF 'input and review artifact' docs/runbooks/branch-protection-rollout.md &&
   grep -qF 'staged' docs/runbooks/branch-protection-rollout.md; then
  pass "runbook documents live authority, committed artifacts, and staged activation"
else
  fail "runbook must distinguish live authority from committed input artifacts"
fi

if grep -qF "\`allow_merge_commit: true\`" CONTRIBUTING.md &&
   grep -qF "\`allow_squash_merge: true\`" CONTRIBUTING.md &&
   grep -qF "\`allow_rebase_merge: false\`" CONTRIBUTING.md; then
  pass "CONTRIBUTING records current repository merge-method metadata"
else
  fail "CONTRIBUTING merge-method facts do not match current metadata"
fi

if rg -n 'Argus/(pull|issues)/551|Argus #550/#551|PR #551' \
    CONTRIBUTING.md configs/github docs tests tools justfile \
    --glob '!tests/github/merge-queue-readiness.test.sh'; then
  fail "stale Argus replacement PR #551 reference remains"
else
  pass "all Argus replacement references use current PR #552"
fi

echo "Results: $((checks - failures))/$checks checks passed"
if ((failures > 0)); then
  exit 1
fi
