#!/usr/bin/env bash
# Regression contract for the repository-owned merge-queue configuration.
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

  for existing_trigger in push pull_request workflow_dispatch; do
    if grep -qE "^  ${existing_trigger}:" <<<"$on_block"; then
      pass "$workflow preserves $existing_trigger"
    else
      fail "$workflow is missing existing trigger $existing_trigger"
    fi
  done

  if grep -qE '^  merge_group:$' <<<"$on_block" &&
     grep -A1 -E '^  merge_group:$' <<<"$on_block" |
       grep -qE '^    types: \[checks_requested\]$'; then
    pass "$workflow handles merge_group checks_requested"
  else
    fail "$workflow must handle merge_group checks_requested"
  fi
done

if [[ $(grep -Fc "github.event_name != 'merge_group'" \
    .github/workflows/build-images.yml) -eq 2 ]]; then
  pass "Build Images never authenticates or publishes for merge groups"
else
  fail "Build Images must be build-only for merge groups"
fi

if grep -qE "^[[:space:]]+if: github.event_name != 'merge_group'$" \
    .github/workflows/install-test.yml; then
  pass "Install test excludes the non-required matrix from merge groups"
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
    pass "$ruleset preserves all required checks"
  else
    fail "$ruleset does not preserve the required-check contract"
  fi

  if jq -e '
      [.rules[] | select(.type == "required_status_checks")
        | .parameters.strict_required_status_checks_policy] == [false]
    ' "$ruleset" >/dev/null; then
    pass "$ruleset preserves non-strict branch checks"
  else
    fail "$ruleset strict required-check policy has drifted"
  fi

  if jq -e '
      [.rules[] | select(.type == "pull_request")
        | .parameters
        | {
            required_approving_review_count,
            required_review_thread_resolution,
            allowed_merge_methods
          }] == [{
            "required_approving_review_count": 0,
            "required_review_thread_resolution": true,
            "allowed_merge_methods": ["squash"]
          }]
    ' "$ruleset" >/dev/null; then
    pass "$ruleset preserves the review gate and remains squash-only"
  else
    fail "$ruleset review or squash-only pull-request policy has drifted"
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
    pass "$ruleset has the approved merge-queue policy"
  else
    fail "$ruleset merge-queue policy is absent or has drifted"
  fi
done

echo "Results: $((checks - failures))/$checks checks passed"
if ((failures > 0)); then
  exit 1
fi
