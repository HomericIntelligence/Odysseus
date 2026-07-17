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

if python3 tests/github/workflow-permissions.test.py workflow-structure; then
  pass "required workflow triggers, contexts, and checkout behavior are structured"
else
  fail "required workflow structure has drifted"
fi

if python3 tests/github/workflow-permissions.test.py workflow-defaults; then
  pass "required workflows default validation to parsed contents:read permissions"
else
  fail "required workflows must not grant write permission at workflow scope"
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
