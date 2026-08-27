#!/usr/bin/env bash
# Regression contract for Odysseus merge-queue readiness and least privilege.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"

for required_command in find git grep jq python3; do
  command -v "$required_command" >/dev/null || {
    echo "ERROR: required test dependency is unavailable: $required_command" >&2
    exit 2
  }
done

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

expected_contexts='["required-checks-gate"]'
ruleset_files=(
  configs/github/repo-ruleset.json
  configs/github/repo-ruleset-active.json
  configs/github/repo-ruleset-evaluate.json
)

policy_file=configs/github/fleet-ruleset-policy.json

expected_fleet=$(
  {
    echo Odysseus
    git config -f .gitmodules --get-regexp '^submodule\..*\.url$' |
      awk '{url=$2; sub(/^.*\//, "", url); sub(/\.git$/, "", url); print url}'
  } | sort -u | jq -Rsc 'split("\n")[:-1]'
)

if [[ -f "$policy_file" ]] && jq -e --argjson expected "$expected_fleet" '
    .schema_version == 1 and
    .organization == "HomericIntelligence" and
    (.repositories | sort) == $expected and
    (.repositories | length) == 16 and
    (.repositories | index("modular-community")) == null
  ' "$policy_file" >/dev/null; then
  pass "fleet policy inventory equals Odysseus plus the declared submodules"
else
  fail "fleet policy inventory must equal Odysseus plus the declared submodules"
fi

if jq -e '
    .schema_version == 1 and
    .organization == "HomericIntelligence" and
    .repository_settings == {
      allow_auto_merge: true,
      allow_merge_commit: false,
      allow_rebase_merge: false,
      allow_squash_merge: true,
      allow_update_branch: true,
      delete_branch_on_merge: true,
      web_commit_signoff_required: true
    } and
    .ruleset == {
      name: "homeric-main-baseline",
      target: "branch",
      conditions: {
        ref_name: {
          include: ["~DEFAULT_BRANCH"],
          exclude: []
        }
      },
      bypass_actors: [],
      rules: [
        {type: "deletion"},
        {type: "required_signatures"},
        {
          type: "pull_request",
          parameters: {
            allowed_merge_methods: ["squash"],
            dismiss_stale_reviews_on_push: false,
            dismissal_restriction: {
              allowed_actors: [],
              enabled: false
            },
            require_code_owner_review: false,
            require_extra_approval_for_unattributed_changes: true,
            require_last_push_approval: false,
            required_approving_review_count: 0,
            required_review_thread_resolution: true,
            required_reviewers: []
          }
        },
        {
          type: "merge_queue",
          parameters: {
            check_response_timeout_minutes: 180,
            grouping_strategy: "HEADGREEN",
            max_entries_to_build: 10,
            max_entries_to_merge: 5,
            merge_method: "SQUASH",
            min_entries_to_merge: 1,
            min_entries_to_merge_wait_minutes: 5
          }
        },
        {
          type: "required_status_checks",
          parameters: {
            strict_required_status_checks_policy: false,
            do_not_enforce_on_create: false,
            required_status_checks: [{
              context: "required-checks-gate",
              integration_id: 15368
            }]
          }
        },
        {type: "required_linear_history"},
        {type: "non_fast_forward"}
      ]
    }
  ' "$policy_file" >/dev/null; then
  pass "fleet policy equals the complete issue #475 final-policy oracle"
else
  fail "fleet policy has drifted from the complete issue #475 final-policy oracle"
fi

if python3 tools/github/render-fleet-ruleset.py --check; then
  pass "tracked repository rulesets are derived from the versioned fleet policy"
else
  fail "tracked repository rulesets have drifted from the versioned fleet policy"
fi

if compgen -G 'configs/github/org-ruleset*.json' >/dev/null &&
    grep -nE '"~ALL"' configs/github/org-ruleset*.json; then
  fail "deprecated organization-wide ruleset artifacts still target ~ALL"
else
  pass "no organization-wide ruleset artifact can target the excluded fork"
fi

declare -A expected_enforcement=(
  [configs/github/repo-ruleset.json]=active
  [configs/github/repo-ruleset-active.json]=active
  [configs/github/repo-ruleset-evaluate.json]=evaluate
)

for ruleset in "${ruleset_files[@]}"; do
  if jq -e '
      .target == "branch" and
      .conditions.ref_name.include == ["~DEFAULT_BRANCH"] and
      .conditions.ref_name.exclude == [] and
      .bypass_actors == []
    ' "$ruleset" >/dev/null; then
    pass "$ruleset targets only the default branch with no bypass actors"
  else
    fail "$ruleset must target only the default branch with no bypass actors"
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
    pass "$ruleset records the sole fleet aggregate required check"
  else
    fail "$ruleset must require only required-checks-gate"
  fi

  if jq -e '
      [.rules[] | select(.type == "merge_queue") | .parameters] == [{
        "check_response_timeout_minutes": 180,
        "grouping_strategy": "HEADGREEN",
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

  if jq -e '
      ([.rules[].type] | sort) == ([
        "deletion",
        "merge_queue",
        "non_fast_forward",
        "pull_request",
        "required_linear_history",
        "required_signatures",
        "required_status_checks"
      ] | sort) and
      ([.rules[] | select(.type == "pull_request") | .parameters] | length) == 1 and
      ([.rules[] | select(.type == "pull_request") | .parameters][0] | {
        required_approving_review_count,
        dismiss_stale_reviews_on_push,
        require_code_owner_review,
        require_last_push_approval,
        required_review_thread_resolution,
        require_extra_approval_for_unattributed_changes,
        allowed_merge_methods
      }) == {
        "required_approving_review_count": 0,
        "dismiss_stale_reviews_on_push": false,
        "require_code_owner_review": false,
        "require_last_push_approval": false,
        "required_review_thread_resolution": true,
        "require_extra_approval_for_unattributed_changes": true,
        "allowed_merge_methods": ["squash"]
      }
    ' "$ruleset" >/dev/null; then
    pass "$ruleset records the complete common branch-policy baseline"
  else
    fail "$ruleset common branch-policy baseline is incomplete or has drifted"
  fi
done

if grep -nE \
    '"grouping_strategy"[[:space:]]*:[[:space:]]*"ALLGREEN"|"check_response_timeout_minutes"[[:space:]]*:[[:space:]]*60' \
    configs/github/repo-ruleset*.json; then
  fail "stale queue parameters remain in repository ruleset artifacts"
else
  pass "repository ruleset artifacts contain no stale queue parameters"
fi

stale_reference_files=(CONTRIBUTING.md justfile)
while IFS= read -r -d '' candidate; do
  [[ "$candidate" == tests/github/merge-queue-readiness.test.sh ]] ||
    stale_reference_files+=("$candidate")
done < <(find configs/github docs tests tools -type f -print0)

if grep -nE 'Argus/(pull|issues)/551|Argus #550/#551|PR #551' \
    "${stale_reference_files[@]}"; then
  fail "stale Argus replacement PR #551 reference remains"
else
  pass "all Argus replacement references use current PR #552"
fi

echo "Results: $((checks - failures))/$checks checks passed"
if ((failures > 0)); then
  exit 1
fi
