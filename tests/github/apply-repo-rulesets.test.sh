#!/usr/bin/env bash
# Safety regressions for repository-authoritative ruleset updates.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
cp tests/fixtures/github/mock-ruleset-gh.sh "$tmp_dir/bin/gh"
chmod +x "$tmp_dir/bin/gh"
REAL_JQ_BIN=$(command -v jq)

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

assert_renderer_rejects_policy() {
  local policy=$1
  local label=$2
  local result=0

  python3 - "$policy" <<'PY' || result=$?
import importlib.util
import pathlib
import sys

module_path = pathlib.Path("tools/github/render-fleet-ruleset.py")
spec = importlib.util.spec_from_file_location("render_fleet_ruleset", module_path)
if spec is None or spec.loader is None:
    raise RuntimeError("could not load ruleset renderer")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.POLICY_PATH = pathlib.Path(sys.argv[1])
try:
    module._load_policy()
except module.PolicyError:
    raise SystemExit(42)
PY
  [[ "$result" -eq 42 ]] ||
    fail "$label was accepted by the renderer schema (exit $result)"
}

assert_renderer_uses_policy_values() {
  local policy=$1
  python3 - "$policy" <<'PY'
import importlib.util
import pathlib
import sys

module_path = pathlib.Path("tools/github/render-fleet-ruleset.py")
spec = importlib.util.spec_from_file_location("render_fleet_ruleset", module_path)
if spec is None or spec.loader is None:
    raise RuntimeError("could not load ruleset renderer")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
module.POLICY_PATH = pathlib.Path(sys.argv[1])
policy = module._load_policy()
rendered = module._render(policy, "active")
assert policy["repository_settings"]["allow_auto_merge"] is False
pull_request = next(rule for rule in rendered["rules"] if rule["type"] == "pull_request")
queue = next(rule for rule in rendered["rules"] if rule["type"] == "merge_queue")
required = next(
    rule for rule in rendered["rules"] if rule["type"] == "required_status_checks"
)
assert pull_request["parameters"]["required_approving_review_count"] == 1
assert queue["parameters"]["check_response_timeout_minutes"] == 179
assert required["parameters"]["required_status_checks"] == [
    {"context": "alternate-gate", "integration_id": 42}
]
PY
}

renderer_alternate_policy="$tmp_dir/renderer-alternate-policy.json"
jq '
  .repository_settings.allow_auto_merge = false
  | (.ruleset.rules[] | select(.type == "pull_request")
      | .parameters.required_approving_review_count) = 1
  | (.ruleset.rules[] | select(.type == "merge_queue")
      | .parameters.check_response_timeout_minutes) = 179
  | (.ruleset.rules[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks) = [{
          context: "alternate-gate",
          integration_id: 42
        }]
' configs/github/fleet-ruleset-policy.json >"$renderer_alternate_policy"
assert_renderer_uses_policy_values "$renderer_alternate_policy"

renderer_unknown_parameterless="$tmp_dir/renderer-unknown-parameterless.json"
jq '(.ruleset.rules[] | select(.type == "deletion")) += {future_guard: true}' \
  configs/github/fleet-ruleset-policy.json >"$renderer_unknown_parameterless"
assert_renderer_rejects_policy \
  "$renderer_unknown_parameterless" "parameterless rule with an unknown key"

renderer_wrong_boolean="$tmp_dir/renderer-wrong-boolean.json"
jq '.repository_settings.allow_auto_merge = 1' \
  configs/github/fleet-ruleset-policy.json >"$renderer_wrong_boolean"
assert_renderer_rejects_policy \
  "$renderer_wrong_boolean" "integer-valued repository boolean"

renderer_wrong_integer="$tmp_dir/renderer-wrong-integer.json"
jq '(.ruleset.rules[] | select(.type == "merge_queue")
      | .parameters.check_response_timeout_minutes) = 180.5' \
  configs/github/fleet-ruleset-policy.json >"$renderer_wrong_integer"
assert_renderer_rejects_policy \
  "$renderer_wrong_integer" "floating-point merge-queue integer"

renderer_bad_merge_method="$tmp_dir/renderer-bad-merge-method.json"
jq '(.ruleset.rules[] | select(.type == "pull_request")
      | .parameters.allowed_merge_methods) = ["bogus"]' \
  configs/github/fleet-ruleset-policy.json >"$renderer_bad_merge_method"
assert_renderer_rejects_policy \
  "$renderer_bad_merge_method" "unsupported pull-request merge method"

renderer_bad_queue_enums="$tmp_dir/renderer-bad-queue-enums.json"
jq '(.ruleset.rules[] | select(.type == "merge_queue")
      | .parameters.grouping_strategy) = "bogus"' \
  configs/github/fleet-ruleset-policy.json >"$renderer_bad_queue_enums"
assert_renderer_rejects_policy \
  "$renderer_bad_queue_enums" "unsupported merge-queue grouping strategy"
jq '(.ruleset.rules[] | select(.type == "merge_queue")
      | .parameters.merge_method) = "bogus"' \
  configs/github/fleet-ruleset-policy.json >"$renderer_bad_queue_enums"
assert_renderer_rejects_policy \
  "$renderer_bad_queue_enums" "unsupported merge-queue method"

renderer_bad_review_count="$tmp_dir/renderer-bad-review-count.json"
jq '(.ruleset.rules[] | select(.type == "pull_request")
      | .parameters.required_approving_review_count) = 7' \
  configs/github/fleet-ruleset-policy.json >"$renderer_bad_review_count"
assert_renderer_rejects_policy \
  "$renderer_bad_review_count" "out-of-range required review count"

renderer_bad_queue_limit="$tmp_dir/renderer-bad-queue-limit.json"
jq '(.ruleset.rules[] | select(.type == "merge_queue")
      | .parameters.check_response_timeout_minutes) = 361' \
  configs/github/fleet-ruleset-policy.json >"$renderer_bad_queue_limit"
assert_renderer_rejects_policy \
  "$renderer_bad_queue_limit" "out-of-range merge-queue timeout"
jq '(.ruleset.rules[] | select(.type == "merge_queue")
      | .parameters.max_entries_to_build) = 101' \
  configs/github/fleet-ruleset-policy.json >"$renderer_bad_queue_limit"
assert_renderer_rejects_policy \
  "$renderer_bad_queue_limit" "out-of-range merge-queue build limit"

renderer_duplicate_context="$tmp_dir/renderer-duplicate-context.json"
jq '(.ruleset.rules[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks) += [
        .ruleset.rules[]
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[0]
      ]' configs/github/fleet-ruleset-policy.json \
  >"$renderer_duplicate_context"
assert_renderer_rejects_policy \
  "$renderer_duplicate_context" "duplicate required status context"

echo "PASS: renderer schema is strict while the policy remains the sole value authority"

if compgen -G 'configs/github/org-ruleset*.json' >/dev/null; then
  fail "retired organization-wide ruleset artifacts remain tracked"
fi

assert_retired_github_script() {
  local script=$1
  shift
  local status=0
  local call_log="$tmp_dir/retired-$(basename "$script").calls"
  local output="$tmp_dir/retired-$(basename "$script").log"
  : >"$call_log"
  if PATH="$tmp_dir/bin:$PATH" GH_CALL_LOG="$call_log" \
      "$script" "$@" >"$output" 2>&1; then
    fail "$script still accepted a legacy invocation"
  else
    status=$?
  fi
  [[ "$status" -eq 2 ]] ||
    fail "$script returned $status instead of the retired-path status 2"
  [[ ! -s "$call_log" ]] ||
    fail "$script invoked GitHub after its mutation/snapshot path was retired"
}

assert_retired_github_script tools/github/apply-org-ruleset.sh ignored.json
assert_retired_github_script \
  tools/github/remove-classic-protection.sh --repo Myrmidons
assert_retired_github_script tools/github/snapshot-protection.sh

for retired_recipe in ruleset-backup protection-snapshot protection-remove-all; do
  if just --summary | tr ' ' '\n' | grep -qx "$retired_recipe"; then
    fail "unsafe legacy recipe remains advertised: $retired_recipe"
  fi
done

render_recipe=$(just --dry-run repo-rulesets-render 2>&1)
grep -qF 'python3 tools/github/render-fleet-ruleset.py --write' \
  <<<"$render_recipe" ||
  fail "repo-rulesets-render does not regenerate through the canonical renderer"

activation_ledger='https://github.com/HomericIntelligence/Odysseus/issues/386#issuecomment-5444607661'
for rollout_doc in \
    configs/github/canonical-checks.md \
    docs/runbooks/branch-protection-rollout.md; do
  grep -qF "$activation_ledger" "$rollout_doc" ||
    fail "$rollout_doc does not link the authoritative revision-2 activation ledger"
done

echo "PASS: retired fleet mutators are inert and the supported entry points are documented"

python3 - <<'PY'
from pathlib import Path

script = Path("tools/github/apply-repo-rulesets.sh").read_text(encoding="utf-8")
handler = script[script.index("handle_mutation_signal() {") : script.index(
    "compensate_current_and_completed() {"
)]
assert handler.index('[[ "$OPERATION_COMMITTED" == true ]]') < handler.index(
    '[[ "$MUTATION_ARMED" == true ]]'
)
commit = script.rindex("OPERATION_COMMITTED=true")
clear = script.rindex("COMPLETED_REPOS=()")
assert commit < clear
PY
echo "PASS: post-commit signals cannot trigger fleet compensation"

write_classic_protection_fixture() {
  jq -n '{
    required_status_checks: {
      strict: true,
      contexts: ["legacy-check"],
      checks: [
        {context: "legacy-check", app_id: 15368},
        {context: "provider-agnostic", app_id: null}
      ]
    },
    enforce_admins: {enabled: true},
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: {enabled: true},
    allow_force_pushes: {enabled: false},
    allow_deletions: {enabled: false},
    block_creations: {enabled: false},
    required_conversation_resolution: {enabled: true},
    lock_branch: {enabled: false},
    allow_fork_syncing: {enabled: false},
    required_signatures: {enabled: true}
  }' >"$1"
}

run_dry_run() {
  local fixture=$1
  local repo=$2
  local output_file=$3
  local mode=${4:---active}
  : >"$tmp_dir/gh-calls.log"
  PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh \
      "$mode" --repos "$repo" --dry-run >"$output_file" 2>&1
}

assert_canonical_ruleset_drift() {
  local output_file=$1
  local repo=$2
  local label=$3
  local drift payload expected

  drift=$(sed -n "s/^DRIFT $repo: //p" "$output_file")
  [[ -n "$drift" ]] || fail "$label did not emit a drift object"
  payload=$(jq -cn --argjson drift "$drift" '$drift.ruleset.after')
  expected=$(python3 tools/github/render-fleet-ruleset.py --enforcement active | jq '{
    name,
    target,
    enforcement,
    bypass_actors: (.bypass_actors
      | sort_by(.actor_type, .actor_id, .bypass_mode)),
    conditions,
    rules: ([.rules[]
      | if .type == "required_status_checks"
        then .parameters.required_status_checks |=
          sort_by(.context, .integration_id)
        else .
        end] | sort_by(.type))
  }')
  jq -en --argjson payload "$payload" --argjson expected "$expected" \
    '$payload == $expected' >/dev/null || \
    fail "$label payload differs from the complete canonical baseline"
  jq -en --argjson payload "$payload" '
    [$payload.rules[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks] == [[{
        "context": "required-checks-gate",
        "integration_id": 15368
      }]]
  ' >/dev/null || fail "$label requires a context other than the aggregate gate"
}

assert_no_mock_mutation() {
  local label=$1
  local log_file=$2
  if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
      "$log_file"; then
    cat "$log_file" >&2
    fail "$label attempted a mutation"
  fi
}

assert_fixture_capture_contract() {
  local fixture=$1
  local repo=$2
  local output_file="$tmp_dir/$repo-output.log"
  local fixture_digest
  local repository_replay="$tmp_dir/$repo-repository-replay.json"
  local branch_replay="$tmp_dir/$repo-branch-replay.json"
  local list_replay="$tmp_dir/$repo-list-replay.json"
  local effective_replay="$tmp_dir/$repo-effective-replay.json"
  local classic_replay="$tmp_dir/$repo-classic-replay.json"
  local replay_error="$tmp_dir/$repo-classic-replay.err"
  local replay_log="$tmp_dir/$repo-fixture-replay-calls.log"
  local classic_status

  fixture_digest=$(jq -cS . "$fixture" | shasum -a 256 | awk '{print $1}')

  jq -e \
    --arg repo "$repo" \
    --arg fixture_path "$fixture" \
    --arg fixture_digest "$fixture_digest" \
    --slurpfile policy configs/github/fleet-ruleset-policy.json \
    --slurpfile provenance tests/fixtures/github/fleet-repository-provenance.json '
      . as $fixture |
      ($provenance[0].repositories[] | select(.name == $repo)) as $record |
      ($fixture.api_captures.rulesets_including_parents.pages
        | map(.response) | flatten) as $listed |
      ($fixture.api_captures.ruleset_details.responses) as $details |
      ($fixture.api_captures.effective_default_branch_rules.pages
        | map(.response) | flatten) as $effective |
      $fixture.schema_version == 2
      and $fixture.repository == ("HomericIntelligence/" + $repo)
      and $fixture.provenance.capture_id == $provenance[0].capture_id
      and $fixture.provenance.capture_started_at ==
        $provenance[0].capture_started_at
      and $fixture.provenance.captured_at == $provenance[0].captured_at
      and $fixture.provenance.api_version == "2022-11-28"
      and ($fixture.provenance.capture_started_at | fromdateiso8601) <=
        ($fixture.provenance.captured_at | fromdateiso8601)
      and (($fixture.provenance.captured_at | fromdateiso8601) -
        ($fixture.provenance.capture_started_at | fromdateiso8601)) <= 300
      and ($fixture.provenance.main_sha | test("^[0-9a-f]{40}$"))
      and $fixture.provenance.main_sha == $record.main_sha
      and $record.fixture == $fixture_path
      and $record.fixture_canonical_json_sha256 == $fixture_digest
      and $fixture.provenance.repository_api == $record.repository_api
      and $fixture.provenance.default_branch_api == $record.default_branch_api
      and $fixture.provenance.capture_source == "live GitHub REST readback"
      and $fixture.provenance.supplemental_capture.capture_id ==
        $provenance[0].supplemental_capture.capture_id
      and $fixture.provenance.supplemental_capture.capture_started_at ==
        $provenance[0].supplemental_capture.capture_started_at
      and $fixture.provenance.supplemental_capture.captured_at ==
        $provenance[0].supplemental_capture.captured_at
      and $fixture.provenance.supplemental_capture.capture_source ==
        "live GitHub REST response projections"
      and $fixture.repository_settings.full_name ==
        ("HomericIntelligence/" + $repo)
      and $fixture.repository_settings.default_branch == "main"
      and ($fixture.repository_settings | del(.full_name, .default_branch)) ==
        $policy[0].repository_settings
      and $fixture.api_captures.repository_policy_projection.method == "GET"
      and $fixture.api_captures.repository_policy_projection.endpoint ==
        $record.repository_api
      and $fixture.api_captures.repository_policy_projection.status == 200
      and $fixture.api_captures.repository_policy_projection.response ==
        $fixture.repository_settings
      and $fixture.api_captures.default_branch_projection.method == "GET"
      and $fixture.api_captures.default_branch_projection.endpoint ==
        $record.default_branch_api
      and $fixture.api_captures.default_branch_projection.status == 200
      and $fixture.api_captures.default_branch_projection.response == {
        name: "main",
        commit: {sha: $fixture.provenance.main_sha}
      }
      and $fixture.api_captures.rulesets_including_parents.method == "GET"
      and ($fixture.api_captures.rulesets_including_parents.pages | length) == 1
      and $fixture.api_captures.rulesets_including_parents.pages[0].endpoint ==
        $record.rulesets_api
      and $fixture.api_captures.rulesets_including_parents.pages[0].status == 200
      and $fixture.api_captures.effective_default_branch_rules.method == "GET"
      and ($fixture.api_captures.effective_default_branch_rules.pages | length) == 1
      and $fixture.api_captures.effective_default_branch_rules.pages[0].endpoint ==
        $record.effective_rules_api
      and $fixture.api_captures.effective_default_branch_rules.pages[0].status == 200
      and $fixture.api_captures.ruleset_details.method == "GET"
      and ($details | map(.status) | all(. == 200))
      and ($details | map(.response)) == $fixture.rulesets
      and ($listed | map(.id)) == ($fixture.rulesets | map(.id))
      and ($details | map(.response.id)) == ($fixture.rulesets | map(.id))
      and $fixture.provenance.ruleset_api == ($details | map(.endpoint))
      and all($details[];
        .endpoint == ("https://api.github.com/repos/HomericIntelligence/" +
          $repo + "/rulesets/" + (.response.id | tostring)))
      and (([$effective[].ruleset_id] | unique) -
        ($fixture.rulesets | map(.id)) | length) == 0
      and ([ $fixture.rulesets[] |
        select(.name == "homeric-main-baseline"
          and .source == ("HomericIntelligence/" + $repo)
          and .source_type == "Repository") ] | length) == 1
      and $fixture.api_captures.classic_branch_protection.method == "GET"
      and $fixture.api_captures.classic_branch_protection.endpoint ==
        $record.classic_protection_api
      and ($fixture.api_captures.classic_branch_protection.status == 200
        or $fixture.api_captures.classic_branch_protection.status == 404)
      and (if $fixture.api_captures.classic_branch_protection.status == 200
        then ($fixture.api_captures.classic_branch_protection.response | type) ==
          "object"
        else $fixture.api_captures.classic_branch_protection.response.message ==
          "Branch not protected"
          and ($fixture.api_captures.classic_branch_protection.response.status |
            tostring) == "404"
        end)
      and all((
        $fixture.api_captures.rulesets_including_parents.pages
        + $details
        + $fixture.api_captures.effective_default_branch_rules.pages
        + [$fixture.api_captures.classic_branch_protection]
      )[];
        (.captured_at | fromdateiso8601) >=
          ($fixture.provenance.capture_started_at | fromdateiso8601)
        and (.captured_at | fromdateiso8601) <=
          ($fixture.provenance.captured_at | fromdateiso8601)
        and (.request_id | type) == "string"
        and (.request_id | length) > 0
        and .api_version == "2022-11-28")
      and all([
        $fixture.api_captures.repository_policy_projection,
        $fixture.api_captures.default_branch_projection
      ][];
        (.captured_at | fromdateiso8601) >=
          ($fixture.provenance.supplemental_capture.capture_started_at |
            fromdateiso8601)
        and (.captured_at | fromdateiso8601) <=
          ($fixture.provenance.supplemental_capture.captured_at |
            fromdateiso8601)
        and (.request_id | type) == "string"
        and (.request_id | length) > 0
        and (.etag | type) == "string"
        and (.etag | length) > 0
        and .api_version == "2022-11-28")
    ' "$fixture" >/dev/null ||
    fail "$repo live policy fixture is incomplete, stale, or not provenance-bound"

  : >"$replay_log"
  GH_RULESET_FIXTURE="$fixture" GH_CALL_LOG="$replay_log" \
    "$tmp_dir/bin/gh" api "repos/HomericIntelligence/$repo" \
      >"$repository_replay"
  jq -e --slurpfile replay "$repository_replay" '
    $replay[0] == .api_captures.repository_policy_projection.response
  ' "$fixture" >/dev/null ||
    fail "$repo mock did not replay the captured repository-policy projection"
  GH_RULESET_FIXTURE="$fixture" GH_CALL_LOG="$replay_log" \
    "$tmp_dir/bin/gh" api "repos/HomericIntelligence/$repo/branches/main" \
      >"$branch_replay"
  jq -e --slurpfile replay "$branch_replay" '
    $replay[0] == .api_captures.default_branch_projection.response
  ' "$fixture" >/dev/null ||
    fail "$repo mock did not replay the captured default-branch projection"
  GH_RULESET_FIXTURE="$fixture" GH_CALL_LOG="$replay_log" \
    "$tmp_dir/bin/gh" api --paginate --slurp \
      "repos/HomericIntelligence/$repo/rulesets?includes_parents=true&per_page=100" \
      >"$list_replay"
  jq -e --slurpfile replay "$list_replay" '
    $replay[0] == [.api_captures.rulesets_including_parents.pages[].response]
  ' "$fixture" >/dev/null || fail "$repo mock did not replay the captured ruleset list"
  GH_RULESET_FIXTURE="$fixture" GH_CALL_LOG="$replay_log" \
    "$tmp_dir/bin/gh" api --paginate --slurp \
      "repos/HomericIntelligence/$repo/rules/branches/main?per_page=100" \
      >"$effective_replay"
  jq -e --slurpfile replay "$effective_replay" '
    $replay[0] ==
      [.api_captures.effective_default_branch_rules.pages[].response]
  ' "$fixture" >/dev/null || fail "$repo mock did not replay captured effective rules"

  classic_status=$(jq -r '.api_captures.classic_branch_protection.status' "$fixture")
  if [[ "$classic_status" == 200 ]]; then
    GH_RULESET_FIXTURE="$fixture" GH_CALL_LOG="$replay_log" \
      "$tmp_dir/bin/gh" api \
        "repos/HomericIntelligence/$repo/branches/main/protection" \
        >"$classic_replay"
    jq -e --slurpfile replay "$classic_replay" '
      $replay[0] == .api_captures.classic_branch_protection.response
    ' "$fixture" >/dev/null || fail "$repo mock did not replay classic protection"
  elif GH_RULESET_FIXTURE="$fixture" GH_CALL_LOG="$replay_log" \
      "$tmp_dir/bin/gh" api \
        "repos/HomericIntelligence/$repo/branches/main/protection" \
        >"$classic_replay" 2>"$replay_error"; then
    fail "$repo mock accepted captured absent classic protection"
  else
    grep -qF 'HTTP 404' "$replay_error" ||
      fail "$repo mock did not replay the captured classic 404"
  fi
  assert_no_mock_mutation "$repo live fixture replay" "$replay_log"

  case "$repo" in
    Agamemnon|Argus|Charybdis|Hermes|Keystone|Mnemosyne|Nestor|Odyssey|Proteus)
      if run_dry_run "$fixture" "$repo" "$output_file"; then
        cat "$output_file" >&2
        fail "$repo accepted its captured active extras ruleset"
      fi
      grep -qF 'overlapping active branch ruleset affects main' "$output_file" || {
        cat "$output_file" >&2
        fail "$repo did not report its captured active extras overlap"
      }
      assert_no_mock_mutation "$repo captured overlap refusal" \
        "$tmp_dir/gh-calls.log"
      ;;
    *)
      run_dry_run "$fixture" "$repo" "$output_file" || {
        cat "$output_file" >&2
        fail "$repo captured-state dry-run failed"
      }
      local inventory expected_classic
      inventory=$(sed -n "s/^PROTECTION-INVENTORY $repo: //p" "$output_file")
      [[ -n "$inventory" ]] || fail "$repo did not emit a protection inventory"
      if [[ "$classic_status" == 200 ]]; then
        expected_classic=true
      else
        expected_classic=false
      fi
      jq -en --argjson inventory "$inventory" \
        --argjson expected "$expected_classic" \
        '$inventory.classic_branch_protection.present == $expected' >/dev/null ||
        fail "$repo dry-run did not expose its captured classic-protection state"
      if grep -qF "DRIFT $repo:" "$output_file"; then
        assert_canonical_ruleset_drift "$output_file" "$repo" "$repo live fixture"
      elif [[ "$classic_status" != 404 ]] ||
          ! grep -qF "NO-DRIFT $repo" "$output_file"; then
        cat "$output_file" >&2
        fail "$repo reported neither captured drift nor an exact no-op"
      fi
      assert_no_mock_mutation "$repo live fixture dry-run" "$tmp_dir/gh-calls.log"
      ;;
  esac

  echo "PASS: $repo fixture replays complete live protection state"
}

assert_synthetic_fixture_converges() {
  local fixture=$1
  local repo=$2
  local synthetic="$tmp_dir/$repo-synthetic-baseline.json"
  local output_file="$tmp_dir/$repo-synthetic-output.log"

  jq '{
    repository,
    repository_settings,
    rulesets: [.rulesets[] | select(.name == "homeric-main-baseline")]
  }' "$fixture" >"$synthetic"
  run_dry_run "$synthetic" "$repo" "$output_file" || {
    cat "$output_file" >&2
    fail "$repo synthetic convergence dry-run failed"
  }
  assert_canonical_ruleset_drift "$output_file" "$repo" "$repo synthetic fixture"
  assert_no_mock_mutation "$repo synthetic convergence" "$tmp_dir/gh-calls.log"
  echo "PASS: $repo synthetic fixture converges to the canonical single-gate baseline"
}

assert_fixture_provenance() {
  local fixture=$1
  local repo=$2
  local expected_rulesets=$3
  local expected_issue=$4
  local expected_pr=$5
  local expected_head=$6

  jq -e \
    --arg repo "$repo" \
    --argjson expected_rulesets "$expected_rulesets" \
    --arg expected_issue "$expected_issue" \
    --arg expected_pr "$expected_pr" \
    --arg expected_head "$expected_head" '
      . as $fixture |
      $fixture.repository == ("HomericIntelligence/" + $repo) and
      ($fixture.provenance.captured_at
        | test("^2026-07-17T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      $fixture.provenance.repository_api ==
        ("https://api.github.com/repos/HomericIntelligence/" + $repo) and
      $fixture.provenance.rollout_issue == $expected_issue and
      $fixture.provenance.replacement_pr == $expected_pr and
      $fixture.provenance.replacement_pr_head_at_capture == $expected_head and
      ($fixture.rulesets | length) == $expected_rulesets and
      ($fixture.provenance.ruleset_api | length) == $expected_rulesets and
      all(
        $fixture.rulesets[];
        .id as $id |
        ($fixture.provenance.ruleset_api | index(
          "https://api.github.com/repos/HomericIntelligence/" +
          $repo + "/rulesets/" + ($id | tostring)
        )) != null
      )
    ' "$fixture" >/dev/null || fail "$repo fixture provenance is incomplete or stale"

  echo "PASS: $repo fixture records capture-time API and replacement provenance"
}

contracts=(
  "tests/fixtures/github/fleet-policy/achaeanfleet-baseline.json:AchaeanFleet"
  "tests/fixtures/github/fleet-policy/agamemnon-baseline.json:Agamemnon"
  "tests/fixtures/github/fleet-policy/argus-baseline.json:Argus"
  "tests/fixtures/github/fleet-policy/athena-baseline.json:Athena"
  "tests/fixtures/github/fleet-policy/charybdis-baseline.json:Charybdis"
  "tests/fixtures/github/fleet-policy/hephaestus-baseline.json:Hephaestus"
  "tests/fixtures/github/fleet-policy/hermes-baseline.json:Hermes"
  "tests/fixtures/github/fleet-policy/keystone-baseline.json:Keystone"
  "tests/fixtures/github/fleet-policy/mnemosyne-baseline.json:Mnemosyne"
  "tests/fixtures/github/fleet-policy/myrmidons-baseline.json:Myrmidons"
  "tests/fixtures/github/fleet-policy/nestor-baseline.json:Nestor"
  "tests/fixtures/github/fleet-policy/odysseus-baseline.json:Odysseus"
  "tests/fixtures/github/fleet-policy/odyssey-baseline.json:Odyssey"
  "tests/fixtures/github/fleet-policy/proteus-baseline.json:Proteus"
  "tests/fixtures/github/fleet-policy/scylla-baseline.json:Scylla"
  "tests/fixtures/github/fleet-policy/telemachy-baseline.json:Telemachy"
)

for contract in "${contracts[@]}"; do
  IFS=: read -r fixture repo <<<"$contract"
  assert_fixture_capture_contract "$fixture" "$repo"
  assert_synthetic_fixture_converges "$fixture" "$repo"
done

assert_overlapping_protection_rejected() {
  local name=$1
  local fixture=$2
  local repo=$3
  local inherited_repos=${4:-}
  local classic_repos=${5:-}
  local output_file="$tmp_dir/$name.log"

  if GH_INHERITED_RULESET_REPOS="$inherited_repos" \
      GH_CLASSIC_PROTECTION_REPOS="$classic_repos" \
      run_dry_run "$fixture" "$repo" "$output_file"; then
    cat "$output_file" >&2
    fail "$name accepted overlapping main-branch protection"
  fi
  grep -Eq 'overlapping (active branch ruleset|classic branch protection)' \
    "$output_file" || {
      cat "$output_file" >&2
      fail "$name refusal did not identify overlapping protection"
    }
  grep -qF 'includes_parents=true' "$tmp_dir/gh-calls.log" || \
    fail "$name did not enumerate inherited and repository rulesets"
  grep -qF -- '--paginate' "$tmp_dir/gh-calls.log" || \
    fail "$name did not paginate GitHub list endpoints"
  grep -qF -- '--slurp' "$tmp_dir/gh-calls.log" || \
    fail "$name did not combine every GitHub list page"
  if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
      "$tmp_dir/gh-calls.log"; then
    fail "$name attempted a live mutation"
  fi
  echo "PASS: updater rejects $name"
}

assert_overlapping_protection_rejected \
  extra-repository-ruleset \
  tests/fixtures/github/argus-ruleset-contract.json Argus
assert_overlapping_protection_rejected \
  inherited-organization-ruleset \
  tests/fixtures/github/myrmidons-ruleset-contract.json Myrmidons Myrmidons

classic_preview="$tmp_dir/classic-preview.log"
if ! GH_CLASSIC_PROTECTION_REPOS=Myrmidons run_dry_run \
    tests/fixtures/github/myrmidons-ruleset-contract.json Myrmidons \
    "$classic_preview"; then
  cat "$classic_preview" >&2
  fail "classic branch protection could not be represented as migration drift"
fi
classic_inventory=$(sed -n \
  's/^PROTECTION-INVENTORY Myrmidons: //p' "$classic_preview")
jq -en --argjson inventory "$classic_inventory" \
  '$inventory.classic_branch_protection.present == true
    and ($inventory.classic_branch_protection.restore_payload | type) == "object"
    and ($inventory.classic_branch_protection.restore_payload
      .required_status_checks.checks[]
      | select(.context == "provider-agnostic")
      | .app_id) == -1
    and ($inventory.classic_branch_protection.required_signatures | type) ==
      "boolean"' >/dev/null || \
  fail "classic branch protection is absent from the effective-policy inventory"
if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
    "$tmp_dir/gh-calls.log"; then
  fail "classic branch-protection preview attempted a mutation"
fi
echo "PASS: classic branch protection is explicit no-write migration drift"

assert_incomplete_classic_snapshot_rejected() {
  local name=$1
  local filter=$2
  local fixture="$tmp_dir/classic-$name.json"
  local output_file="$tmp_dir/classic-$name.log"

  write_classic_protection_fixture "$fixture"
  jq '.required_pull_request_reviews = {
      dismissal_restrictions: {
        users: [{login: "review-admin"}],
        teams: [],
        apps: []
      },
      dismiss_stale_reviews: false,
      require_code_owner_reviews: false,
      required_approving_review_count: 0,
      require_last_push_approval: false,
      bypass_pull_request_allowances: {
        users: [],
        teams: [],
        apps: []
      }
    }
    | '"$filter" \
    "$fixture" >"$fixture.tmp"
  mv "$fixture.tmp" "$fixture"
  if GH_CLASSIC_PROTECTION_STATE="$fixture" run_dry_run \
      tests/fixtures/github/myrmidons-ruleset-contract.json Myrmidons \
      "$output_file"; then
    fail "classic snapshot accepted incomplete response: $name"
  fi
  grep -qF 'classic branch-protection response is incomplete' \
    "$output_file" || {
      cat "$output_file" >&2
      fail "$name did not report an incomplete classic snapshot"
    }
  if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
      "$tmp_dir/gh-calls.log"; then
    fail "$name incomplete classic snapshot attempted a mutation"
  fi
  echo "PASS: classic snapshot rejects $name"
}

assert_incomplete_classic_snapshot_rejected malformed-review-actor \
  'del(.required_pull_request_reviews.dismissal_restrictions.users[0].login)'
assert_incomplete_classic_snapshot_rejected missing-review-scalar \
  'del(.required_pull_request_reviews.require_last_push_approval)'
assert_incomplete_classic_snapshot_rejected unknown-top-level-field \
  '.future_guard = true'
assert_incomplete_classic_snapshot_rejected unknown-review-field \
  '.required_pull_request_reviews.future_guard = true'

assert_fixture_provenance \
  tests/fixtures/github/argus-ruleset-contract.json Argus 2 \
  https://github.com/HomericIntelligence/Argus/issues/550 \
  https://github.com/HomericIntelligence/Argus/pull/552 \
  b335eb95a49d8e89b580b52879cc7b0bcffa510a
assert_fixture_provenance \
  tests/fixtures/github/proteus-ruleset-contract.json Proteus 2 \
  https://github.com/HomericIntelligence/Proteus/issues/214 \
  https://github.com/HomericIntelligence/Proteus/pull/216 \
  3ed68db6e77e6c2ffac9baa334807c2fcddb3664
assert_fixture_provenance \
  tests/fixtures/github/myrmidons-ruleset-contract.json Myrmidons 1 \
  https://github.com/HomericIntelligence/Myrmidons/issues/765 \
  https://github.com/HomericIntelligence/Myrmidons/pull/767 \
  0b50f16334c3bf9be66c957c97d338968a38cb83

fleet_provenance=tests/fixtures/github/fleet-repository-provenance.json
[[ -f "$fleet_provenance" ]] || fail "16-repository provenance fixture is missing"
expected_fleet=$(jq -c '.repositories' configs/github/fleet-ruleset-policy.json)
policy_digest=$(jq -cS . configs/github/fleet-ruleset-policy.json | \
  shasum -a 256 | awk '{print $1}')
active_ruleset_digest=$(python3 tools/github/render-fleet-ruleset.py \
  --enforcement active | jq -cS . | shasum -a 256 | awk '{print $1}')
repository_settings_digest=$(jq -cS '.repository_settings' \
  configs/github/fleet-ruleset-policy.json | shasum -a 256 | awk '{print $1}')
jq -e \
  --argjson expected "$expected_fleet" \
  --arg policy_digest "$policy_digest" \
  --arg active_ruleset_digest "$active_ruleset_digest" \
  --arg repository_settings_digest "$repository_settings_digest" '
  .schema_version == 2
  and .organization == "HomericIntelligence"
  and .api_version == "2022-11-28"
  and (.capture_id | test("^fleet-policy-[0-9]{8}T[0-9]{6}Z$"))
  and .policy_binding == {
    source: "configs/github/fleet-ruleset-policy.json",
    canonical_json_sha256: $policy_digest,
    active_ruleset_sha256: $active_ruleset_digest,
    repository_settings_sha256: $repository_settings_digest
  }
  and (.capture_started_at | test("^2026-08-27T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and (.captured_at | test("^2026-08-27T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$"))
  and ((.capture_started_at | fromdateiso8601) <= (.captured_at | fromdateiso8601))
  and (((.captured_at | fromdateiso8601) -
    (.capture_started_at | fromdateiso8601)) <= 300)
  and .supplemental_capture.capture_source ==
    "live GitHub REST response projections"
  and (.supplemental_capture.capture_id |
    test("^fleet-policy-settings-[0-9]{8}T[0-9]{6}Z$"))
  and (.supplemental_capture.capture_started_at | fromdateiso8601) <=
    (.supplemental_capture.captured_at | fromdateiso8601)
  and ((.supplemental_capture.captured_at | fromdateiso8601) -
    (.supplemental_capture.capture_started_at | fromdateiso8601)) <= 300
  and .supplemental_capture.scope == [
    "repository_policy_projection",
    "default_branch_projection"
  ]
  and (.repositories | length) == 16
  and ([.repositories[].name] == $expected)
  and all(.repositories[];
    (.main_sha | test("^[0-9a-f]{40}$"))
    and .repository_api ==
      ("https://api.github.com/repos/HomericIntelligence/" + .name)
    and .default_branch_api ==
      ("https://api.github.com/repos/HomericIntelligence/" + .name +
        "/branches/main")
    and .rulesets_api ==
      ("https://api.github.com/repos/HomericIntelligence/" + .name +
        "/rulesets?includes_parents=true&per_page=100")
    and .effective_rules_api ==
      ("https://api.github.com/repos/HomericIntelligence/" + .name +
        "/rules/branches/main?per_page=100")
    and .classic_protection_api ==
      ("https://api.github.com/repos/HomericIntelligence/" + .name +
        "/branches/main/protection")
    and .fixture ==
      ("tests/fixtures/github/fleet-policy/" + (.name | ascii_downcase) +
        "-baseline.json")
    and (.fixture_canonical_json_sha256 | test("^[0-9a-f]{64}$"))
    and .capture_source == "live GitHub REST readback")
' "$fleet_provenance" >/dev/null || \
  fail "16-repository provenance fixture is incomplete or not policy-bound"
echo "PASS: provenance fixture records a bounded live-API capture for every first-party repository"

argus_fixture="$tmp_dir/argus-baseline-only.json"
jq '.rulesets |= map(select(.name == "homeric-main-baseline"))' \
  tests/fixtures/github/argus-ruleset-contract.json >"$argus_fixture"

assert_incomplete_authority_rejected() {
  local name=$1
  local jq_filter=$2
  local expected_message=$3
  local broken_fixture="$tmp_dir/$name.json"
  local output_file="$tmp_dir/$name.log"

  jq "$jq_filter" "$argus_fixture" >"$broken_fixture"
  if run_dry_run "$broken_fixture" Argus "$output_file"; then
    fail "updater accepted incomplete required-check authority: $name"
  fi
  grep -qF "$expected_message" "$output_file" || {
    cat "$output_file" >&2
    fail "$name refusal did not identify incomplete required-check authority"
  }
  if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
      "$tmp_dir/gh-calls.log"; then
    cat "$tmp_dir/gh-calls.log" >&2
    fail "$name incomplete-authority path attempted a mutation"
  fi
  echo "PASS: updater rejects $name"
}

authority_error="required_status_checks authority is incomplete"
assert_incomplete_authority_rejected \
  missing-required-status-rule \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks"))' \
  "$authority_error"
assert_incomplete_authority_rejected \
  missing-parameters \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters)' \
  "$authority_error"
assert_incomplete_authority_rejected \
  missing-required-status-checks \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks)' \
  "$authority_error"
assert_incomplete_authority_rejected \
  non-object-parameters \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters) = []' \
  "$authority_error"
assert_incomplete_authority_rejected \
  non-array-required-status-checks \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks) = {}' \
  "$authority_error"
assert_incomplete_authority_rejected \
  empty-context-array \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks) = []' \
  "$authority_error"
assert_incomplete_authority_rejected \
  missing-context-string \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0].context)' \
  "$authority_error"
assert_incomplete_authority_rejected \
  blank-context-string \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0].context) = "   "' \
  "$authority_error"
assert_incomplete_authority_rejected \
  non-string-context \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0].context) = 7' \
  "$authority_error"
assert_incomplete_authority_rejected \
  missing-integration-id \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0].integration_id)' \
  "$authority_error"
assert_incomplete_authority_rejected \
  invalid-integration-id \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0].integration_id) = 0' \
  "$authority_error"
assert_incomplete_authority_rejected \
  non-object-required-check \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0]) = null' \
  "$authority_error"
assert_incomplete_authority_rejected \
  missing-strict-policy \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.strict_required_status_checks_policy)' \
  "$authority_error"
assert_incomplete_authority_rejected \
  non-boolean-strict-policy \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.strict_required_status_checks_policy) = "false"' \
  "$authority_error"
assert_incomplete_authority_rejected \
  missing-enforce-on-create \
  'del(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.do_not_enforce_on_create)' \
  "$authority_error"
assert_incomplete_authority_rejected \
  non-boolean-enforce-on-create \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.do_not_enforce_on_create) = 0' \
  "$authority_error"
assert_incomplete_authority_rejected \
  duplicate-required-status-rule \
  '.rulesets[0].rules += [(.rulesets[0].rules[] | select(.type == "required_status_checks"))]' \
  "$authority_error"
assert_incomplete_authority_rejected \
  duplicate-required-context \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks) += [(.rulesets[0].rules[] | select(.type == "required_status_checks").parameters.required_status_checks[0])]' \
  "$authority_error"

assert_ruleset_shape_rejected() {
  local name=$1
  local jq_filter=$2
  local expected_message=$3
  local broken_fixture="$tmp_dir/$name.json"
  local output_file="$tmp_dir/$name.log"

  jq "$jq_filter" "$argus_fixture" >"$broken_fixture"
  if run_dry_run "$broken_fixture" Argus "$output_file"; then
    fail "updater accepted invalid ruleset shape: $name"
  fi
  grep -qF "$expected_message" "$output_file" || {
    cat "$output_file" >&2
    fail "$name refusal did not identify the invalid ruleset shape"
  }
  echo "PASS: updater rejects $name"
}

assert_ruleset_shape_rejected \
  duplicate-pull-request-rule \
  '.rulesets[0].rules += [(.rulesets[0].rules[] | select(.type == "pull_request"))]' \
  "live ruleset has duplicate rule types"
assert_ruleset_shape_rejected \
  unknown-rule-type \
  '.rulesets[0].rules += [{"type": "future_unreviewed_rule"}]' \
  "live ruleset contains an unknown rule type"
assert_ruleset_shape_rejected \
  unknown-top-level-ruleset-field \
  '.rulesets[0].future_guard = true' \
  "live ruleset identity or main-only branch scope is invalid"
assert_ruleset_shape_rejected \
  unknown-parameterless-rule-field \
  '(.rulesets[0].rules[] | select(.type == "deletion")).future_guard = true' \
  "live ruleset contains unknown mutable fields"
assert_ruleset_shape_rejected \
  unknown-pull-request-parameter \
  '(.rulesets[0].rules[] | select(.type == "pull_request")
    | .parameters.future_guard) = true' \
  "live ruleset contains unknown mutable fields"
assert_ruleset_shape_rejected \
  unknown-required-status-parameter \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks")
    | .parameters.future_guard) = true' \
  "live ruleset contains unknown mutable fields"
assert_ruleset_shape_rejected \
  unknown-required-check-field \
  '(.rulesets[0].rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[0].future_guard) = true' \
  "live ruleset contains unknown mutable fields"
assert_ruleset_shape_rejected \
  unknown-bypass-actor-field \
  '.rulesets[0].bypass_actors[0].future_guard = true' \
  "live ruleset contains unknown mutable fields"
assert_ruleset_shape_rejected \
  incomplete-pull-request-rule \
  'del(.rulesets[0].rules[] | select(.type == "pull_request")
    | .parameters.require_last_push_approval)' \
  "pull_request rule is incomplete"
assert_ruleset_shape_rejected \
  incomplete-merge-queue-rule \
  '.rulesets[0].rules += [{
    "type": "merge_queue",
    "parameters": {
      "grouping_strategy": "HEADGREEN",
      "max_entries_to_build": 10,
      "max_entries_to_merge": 5,
      "merge_method": "SQUASH",
      "min_entries_to_merge": 1,
      "min_entries_to_merge_wait_minutes": 5
    }
  }]' \
  "merge_queue rule is incomplete"
assert_ruleset_shape_rejected \
  incomplete-bypass-actor \
  'del(.rulesets[0].bypass_actors[0].actor_type)' \
  "bypass actor is incomplete"

assert_identity_scope_rejected() {
  local name=$1
  local jq_filter=$2
  local list_name_override=${3:-}
  local broken_fixture="$tmp_dir/$name.json"
  local output_file="$tmp_dir/$name.log"

  jq "$jq_filter" "$argus_fixture" >"$broken_fixture"
  : >"$tmp_dir/gh-calls.log"
  if PATH="$tmp_dir/bin:$PATH" \
      GH_RULESET_FIXTURE="$broken_fixture" \
      GH_CALL_LOG="$tmp_dir/gh-calls.log" \
      GH_RULESET_LIST_NAME_OVERRIDE="$list_name_override" \
      tools/github/apply-repo-rulesets.sh \
        --active --repos Argus --dry-run >"$output_file" 2>&1; then
    fail "updater accepted invalid baseline identity/scope: $name"
  fi
  grep -qF "live ruleset identity or main-only branch scope is invalid" \
    "$output_file" || {
      cat "$output_file" >&2
      fail "$name refusal did not identify invalid identity/scope"
    }
  if grep -qF 'DRIFT Argus:' "$output_file"; then
    cat "$output_file" >&2
    fail "$name derived a payload before rejecting identity/scope"
  fi
  if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
      "$tmp_dir/gh-calls.log"; then
    cat "$tmp_dir/gh-calls.log" >&2
    fail "$name invalid-identity path attempted a mutation"
  fi
  echo "PASS: updater rejects $name before payload derivation"
}

assert_identity_scope_rejected \
  wildcard-main-scope \
  '(.rulesets[0].conditions.ref_name.include) = ["refs/heads/*"]'
assert_identity_scope_rejected \
  missing-main-branch \
  'del(.rulesets[0].conditions.ref_name.include)'
assert_identity_scope_rejected \
  alternate-main-branch \
  '(.rulesets[0].conditions.ref_name.include) = ["refs/heads/develop"]'
assert_identity_scope_rejected \
  nonempty-branch-exclusions \
  '(.rulesets[0].conditions.ref_name.exclude) = ["refs/heads/release"]'
assert_identity_scope_rejected \
  malformed-ref-scope \
  '(.rulesets[0].conditions.ref_name) = []'
assert_identity_scope_rejected \
  non-branch-target \
  '(.rulesets[0].target) = "tag"'
assert_identity_scope_rejected \
  renamed-fetched-ruleset \
  '(.rulesets[0].name) = "renamed-main-baseline"' \
  homeric-main-baseline
assert_identity_scope_rejected \
  wrong-repository-owner \
  '(.rulesets[0].source) = "HomericIntelligence/AnotherRepo"'
jq 'del(.rulesets[] | select(.name == "homeric-main-baseline"))' \
  "$argus_fixture" >"$tmp_dir/no-baseline.json"
if run_dry_run "$tmp_dir/no-baseline.json" Argus "$tmp_dir/no-baseline.log"; then
  fail "updater accepted a repository with no owned baseline"
fi
grep -qF "bootstrap it from repository-owned policy" "$tmp_dir/no-baseline.log" || \
  fail "missing-baseline refusal did not identify repository ownership"
echo "PASS: updater never bootstraps from a generic fixed-context payload"

if PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$argus_fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh --active --repos modular-community --dry-run \
      >"$tmp_dir/out-of-fleet.log" 2>&1; then
  fail "updater accepted the excluded fork"
fi
grep -qF "repository is outside the canonical first-party fleet" \
  "$tmp_dir/out-of-fleet.log" || fail "excluded-fork refusal did not identify scope"
echo "PASS: updater rejects repositories outside the exact first-party fleet"

: >"$tmp_dir/gh-calls.log"
if PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$argus_fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh --active --repos Argus \
      >"$tmp_dir/missing-evidence.log" 2>&1; then
  fail "live mutation accepted missing PR/merge-group/main proof"
fi
grep -qF "live mutation requires --evidence-file" \
  "$tmp_dir/missing-evidence.log" || fail "missing-evidence refusal was not explicit"
if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
    "$tmp_dir/gh-calls.log"; then
  fail "missing-evidence path attempted a live mutation"
fi
echo "PASS: live mutation requires explicit PR, merge-group, and main gate proof"

seed_ruleset_state() {
  local fixture=$1
  local state_file=$2
  jq '.rulesets[] | select(.name == "homeric-main-baseline")' \
    "$fixture" >"$state_file"
}

run_live_update() {
  local fixture=$1
  local repos=$2
  local state_file=$3
  local snapshot_dir=$4
  local output_file=$5
  local put_count_file=$6
  local get_count_file=$7
  local evidence_file="$tmp_dir/evidence-${repos//,/-}.json"
  local repository_state_file=${GH_REPOSITORY_STATE:-"$tmp_dir/repository-${repos//,/-}.json"}
  local repository_state_dir=""
  local settings_count_file=${GH_SETTINGS_PATCH_COUNT_FILE:-"$tmp_dir/settings-${repos//,/-}.count"}
  local list_count_file="$tmp_dir/ruleset-lists-${repos//,/-}.count"
  local repository_get_count_file="$tmp_dir/repository-gets-${repos//,/-}.count"
  local branch_get_count_file="$tmp_dir/branch-gets-${repos//,/-}.count"
  local effective_get_count_file="$tmp_dir/effective-gets-${repos//,/-}.count"
  local git_tree_get_count_file="$tmp_dir/git-tree-gets-${repos//,/-}.count"
  local protection_get_count_file="$tmp_dir/protection-gets-${repos//,/-}.count"
  local classic_mutation_count_file=${GH_CLASSIC_MUTATION_COUNT_FILE:-"$tmp_dir/classic-${repos//,/-}.count"}
  local classic_signature_count_file=${GH_CLASSIC_SIGNATURE_COUNT_FILE:-"$tmp_dir/classic-signatures-${repos//,/-}.count"}
  local observed_at=${GH_EVIDENCE_OBSERVED_AT_OVERRIDE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}

  if [[ "$repos" == *,* ]]; then
    repository_state_dir="$tmp_dir/repository-${repos//,/-}.d"
    mkdir -p "$repository_state_dir"
    IFS=',' read -ra repository_names <<<"$repos"
    for repository_name in "${repository_names[@]}"; do
      jq -n --arg full_name "HomericIntelligence/$repository_name" '{
        full_name: $full_name,
        default_branch: "main",
        allow_auto_merge: false,
        allow_merge_commit: true,
        allow_rebase_merge: true,
        allow_squash_merge: true,
        allow_update_branch: false,
        delete_branch_on_merge: false,
        web_commit_signoff_required: false
      }' >"$repository_state_dir/$repository_name-settings.json"
    done
    repository_state_file=""
  elif [[ ! -s "$repository_state_file" ]]; then
    jq -n --arg full_name "HomericIntelligence/${repos%%,*}" '{
      full_name: $full_name,
      default_branch: "main",
      allow_auto_merge: false,
      allow_merge_commit: true,
      allow_rebase_merge: true,
      allow_squash_merge: true,
      allow_update_branch: false,
      delete_branch_on_merge: false,
      web_commit_signoff_required: false
    }' >"$repository_state_file"
  fi

  jq -n --arg repos "$repos" --arg observed_at "$observed_at" '
    def proof($repo; $run_id; $sha): {
      run_id: $run_id,
      attempt_number: 1,
      sha: $sha,
      run_url: ("https://github.com/HomericIntelligence/" + $repo +
        "/actions/runs/" + ($run_id | tostring)),
      required_checks_gate: "success"
    };
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" as $sha
    | {
        schema_version: 1,
        observed_at: $observed_at,
        repositories: (reduce ($repos | split(",")[]) as $repo ({};
          .[$repo] = {
            main_sha: $sha,
            pull_request: proof($repo; 101; $sha),
            merge_group: proof($repo; 102; $sha),
            main: proof($repo; 103; $sha)
          }))
      }
  ' >"$evidence_file"

  : >"$tmp_dir/gh-calls.log"
  : >"$put_count_file"
  : >"$get_count_file"
  : >"$settings_count_file"
  : >"$list_count_file"
  : >"$repository_get_count_file"
  : >"$branch_get_count_file"
  : >"$effective_get_count_file"
  : >"$git_tree_get_count_file"
  : >"$protection_get_count_file"
  : >"$classic_mutation_count_file"
  : >"$classic_signature_count_file"
  mkdir -p "$snapshot_dir"
  PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    GH_ALLOW_MUTATION=true \
    GH_RULESET_STATE="$state_file" \
    GH_RULESET_STATE_DIR="${GH_RULESET_STATE_DIR:-}" \
    GH_REPOSITORY_STATE="$repository_state_file" \
    GH_REPOSITORY_STATE_DIR="$repository_state_dir" \
    GH_PUT_COUNT_FILE="$put_count_file" \
    GH_SETTINGS_PATCH_COUNT_FILE="$settings_count_file" \
    GH_DETAIL_GET_COUNT_FILE="$get_count_file" \
    GH_RULESET_LIST_COUNT_FILE="$list_count_file" \
    GH_REPOSITORY_GET_COUNT_FILE="$repository_get_count_file" \
    GH_BRANCH_GET_COUNT_FILE="$branch_get_count_file" \
    GH_EFFECTIVE_GET_COUNT_FILE="$effective_get_count_file" \
    GH_GIT_TREE_GET_COUNT_FILE="$git_tree_get_count_file" \
    GH_PROTECTION_GET_COUNT_FILE="$protection_get_count_file" \
    GH_CLASSIC_PROTECTION_STATE="${GH_CLASSIC_PROTECTION_STATE:-}" \
    GH_CLASSIC_PROTECTION_STATE_DIR="${GH_CLASSIC_PROTECTION_STATE_DIR:-}" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_mutation_count_file" \
    GH_CLASSIC_SIGNATURE_COUNT_FILE="$classic_signature_count_file" \
    GH_CORRUPT_PUT_AT="${GH_CORRUPT_PUT_AT:-}" \
    GH_FAIL_PUT_BEFORE_WRITE_AT="${GH_FAIL_PUT_BEFORE_WRITE_AT:-}" \
    GH_FAIL_PUT_AFTER_WRITE_AT="${GH_FAIL_PUT_AFTER_WRITE_AT:-}" \
    GH_FAIL_DETAIL_GET_AT="${GH_FAIL_DETAIL_GET_AT:-}" \
    GH_FAIL_RULESET_LIST_AT="${GH_FAIL_RULESET_LIST_AT:-}" \
    GH_CORRUPT_POLICY_SOURCE_AT_RULESET_LIST="${GH_CORRUPT_POLICY_SOURCE_AT_RULESET_LIST:-}" \
    GH_CORRUPT_EVIDENCE_SOURCE_AT_RULESET_LIST="${GH_CORRUPT_EVIDENCE_SOURCE_AT_RULESET_LIST:-}" \
    GH_POLICY_SOURCE_PATH="${FLEET_RULESET_POLICY_FILE:-}" \
    GH_EVIDENCE_SOURCE_PATH="$evidence_file" \
    GH_RULESET_LIST_EXTRA_AT="${GH_RULESET_LIST_EXTRA_AT:-}" \
    GH_RULESET_LIST_DUPLICATE_BASELINE_AT="${GH_RULESET_LIST_DUPLICATE_BASELINE_AT:-}" \
    GH_RULESET_LIST_UNKNOWN_ENFORCEMENT_AT="${GH_RULESET_LIST_UNKNOWN_ENFORCEMENT_AT:-}" \
    GH_EFFECTIVE_OVERLAP_AT="${GH_EFFECTIVE_OVERLAP_AT:-}" \
    GH_EFFECTIVE_PARAMETER_MISMATCH_AT="${GH_EFFECTIVE_PARAMETER_MISMATCH_AT:-}" \
    GH_CONCURRENT_RULESET_CHANGE_AT="${GH_CONCURRENT_RULESET_CHANGE_AT:-}" \
    GH_CONCURRENT_RULESET_UNKNOWN_AT="${GH_CONCURRENT_RULESET_UNKNOWN_AT:-}" \
    GH_DRIFT_COMPLETED_REPO_ON_PUT_SOURCE="${GH_DRIFT_COMPLETED_REPO_ON_PUT_SOURCE:-}" \
    GH_DRIFT_COMPLETED_REPO_ON_PUT_TARGET="${GH_DRIFT_COMPLETED_REPO_ON_PUT_TARGET:-}" \
    GH_CONCURRENT_SETTINGS_CHANGE_AT="${GH_CONCURRENT_SETTINGS_CHANGE_AT:-}" \
    GH_DEFAULT_BRANCH_CHANGE_AT="${GH_DEFAULT_BRANCH_CHANGE_AT:-}" \
    GH_MAIN_SHA_CHANGE_AT="${GH_MAIN_SHA_CHANGE_AT:-}" \
    GH_CLASSIC_PROTECTION_CHANGE_AT="${GH_CLASSIC_PROTECTION_CHANGE_AT:-}" \
    GH_CONCURRENT_CLASSIC_DISAPPEAR_AT="${GH_CONCURRENT_CLASSIC_DISAPPEAR_AT:-}" \
    GH_CONCURRENT_CLASSIC_CONTENT_CHANGE_AT="${GH_CONCURRENT_CLASSIC_CONTENT_CHANGE_AT:-}" \
    GH_FAIL_CLASSIC_DELETE_BEFORE_WRITE_AT="${GH_FAIL_CLASSIC_DELETE_BEFORE_WRITE_AT:-}" \
    GH_FAIL_CLASSIC_DELETE_AFTER_WRITE_AT="${GH_FAIL_CLASSIC_DELETE_AFTER_WRITE_AT:-}" \
    GH_FAIL_CLASSIC_PUT_BEFORE_WRITE_AT="${GH_FAIL_CLASSIC_PUT_BEFORE_WRITE_AT:-}" \
    GH_FAIL_CLASSIC_PUT_AFTER_WRITE_AT="${GH_FAIL_CLASSIC_PUT_AFTER_WRITE_AT:-}" \
    GH_FAIL_CLASSIC_SIGNATURE_POST_BEFORE_WRITE_AT="${GH_FAIL_CLASSIC_SIGNATURE_POST_BEFORE_WRITE_AT:-}" \
    GH_FAIL_CLASSIC_SIGNATURE_POST_AFTER_WRITE_AT="${GH_FAIL_CLASSIC_SIGNATURE_POST_AFTER_WRITE_AT:-}" \
    GH_SIGNAL_HUP_DETAIL_GET_AT="${GH_SIGNAL_HUP_DETAIL_GET_AT:-}" \
    GH_CORRUPT_SETTINGS_PATCH_AT="${GH_CORRUPT_SETTINGS_PATCH_AT:-}" \
    GH_FAIL_SETTINGS_PATCH_BEFORE_WRITE_AT="${GH_FAIL_SETTINGS_PATCH_BEFORE_WRITE_AT:-}" \
    GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT="${GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT:-}" \
    GH_ACTION_EVENT_OVERRIDE="${GH_ACTION_EVENT_OVERRIDE:-}" \
    GH_ACTION_CONCLUSION_OVERRIDE="${GH_ACTION_CONCLUSION_OVERRIDE:-}" \
    GH_ACTION_REPO_OVERRIDE="${GH_ACTION_REPO_OVERRIDE:-}" \
    GH_ACTION_SHA_OVERRIDE="${GH_ACTION_SHA_OVERRIDE:-}" \
    GH_ACTION_ID_OVERRIDE="${GH_ACTION_ID_OVERRIDE:-}" \
    GH_ACTION_ATTEMPT_OVERRIDE="${GH_ACTION_ATTEMPT_OVERRIDE:-}" \
    GH_ACTION_HTML_URL_OVERRIDE="${GH_ACTION_HTML_URL_OVERRIDE:-}" \
    GH_ACTION_HEAD_BRANCH_OVERRIDE="${GH_ACTION_HEAD_BRANCH_OVERRIDE:-}" \
    GH_ACTION_WORKFLOW_NAME_OVERRIDE="${GH_ACTION_WORKFLOW_NAME_OVERRIDE:-}" \
    GH_ACTION_WORKFLOW_PATH_OVERRIDE="${GH_ACTION_WORKFLOW_PATH_OVERRIDE:-}" \
    GH_ACTION_REFERENCED_WORKFLOW_COUNT_OVERRIDE="${GH_ACTION_REFERENCED_WORKFLOW_COUNT_OVERRIDE:-}" \
    GH_ACTION_REFERENCED_WORKFLOW_PATH_OVERRIDE="${GH_ACTION_REFERENCED_WORKFLOW_PATH_OVERRIDE:-}" \
    GH_ACTION_REFERENCED_WORKFLOW_SHA_OVERRIDE="${GH_ACTION_REFERENCED_WORKFLOW_SHA_OVERRIDE:-}" \
    GH_ACTION_RUN_UPDATED_AT_OVERRIDE="${GH_ACTION_RUN_UPDATED_AT_OVERRIDE:-}" \
    GH_AGENT_CONTRACT_TAG_LOOKUP_FAILURE="${GH_AGENT_CONTRACT_TAG_LOOKUP_FAILURE:-}" \
    GH_AGENT_CONTRACT_TAG_REF_OVERRIDE="${GH_AGENT_CONTRACT_TAG_REF_OVERRIDE:-}" \
    GH_AGENT_CONTRACT_TAG_OBJECT_TYPE_OVERRIDE="${GH_AGENT_CONTRACT_TAG_OBJECT_TYPE_OVERRIDE:-}" \
    GH_AGENT_CONTRACT_TAG_SIGNATURE_OVERRIDE="${GH_AGENT_CONTRACT_TAG_SIGNATURE_OVERRIDE:-}" \
    GH_AGENT_CONTRACT_COMMIT_SIGNATURE_OVERRIDE="${GH_AGENT_CONTRACT_COMMIT_SIGNATURE_OVERRIDE:-}" \
    GH_AGENT_CONTRACT_TAG_RULESET_MODE="${GH_AGENT_CONTRACT_TAG_RULESET_MODE:-}" \
    GH_EVIDENCE_OBSERVED_AT="$observed_at" \
    GH_GATE_CONCLUSION_OVERRIDE="${GH_GATE_CONCLUSION_OVERRIDE:-}" \
    GH_GATE_APP_ID_OVERRIDE="${GH_GATE_APP_ID_OVERRIDE:-}" \
    GH_GATE_TOTAL_COUNT_OVERRIDE="${GH_GATE_TOTAL_COUNT_OVERRIDE:-}" \
    GH_NON_GATE_JOB_COUNT="${GH_NON_GATE_JOB_COUNT:-}" \
    GH_GIT_TREE_SMOKE_PRESENT="${GH_GIT_TREE_SMOKE_PRESENT:-}" \
    GH_GIT_TREE_REQUIRED_MISSING="${GH_GIT_TREE_REQUIRED_MISSING:-}" \
    GH_GIT_TREE_REQUIRED_BLOB_CHANGE_AT="${GH_GIT_TREE_REQUIRED_BLOB_CHANGE_AT:-}" \
    GH_MERGE_GROUP_JOB_NAME_OVERRIDE="${GH_MERGE_GROUP_JOB_NAME_OVERRIDE:-}" \
    GH_MERGE_GROUP_JOB_CONCLUSION_OVERRIDE="${GH_MERGE_GROUP_JOB_CONCLUSION_OVERRIDE:-}" \
    GH_MAIN_SHA_OVERRIDE="${GH_MAIN_SHA_OVERRIDE:-}" \
    REAL_JQ="$REAL_JQ_BIN" \
    JQ_FAIL_PROVENANCE_REPO="${JQ_FAIL_PROVENANCE_REPO:-}" \
    FLEET_RULESET_POLICY_FILE="${FLEET_RULESET_POLICY_FILE:-}" \
    RULESET_SNAPSHOT_DIR="$snapshot_dir" \
    tools/github/apply-repo-rulesets.sh "${RULESET_MODE:---active}" --repos "$repos" \
      --evidence-file "$evidence_file" \
      >"$output_file" 2>&1
}

assert_durable_snapshot() {
  local snapshot_dir=$1
  local expected_file=$2
  local label=$3
  local expected_count=${4:-3}
  local snapshots=()
  mapfile -t snapshots < <(find "$snapshot_dir" -type f -name '*.json' | sort)
  [[ ${#snapshots[@]} -eq "$expected_count" ]] || \
    fail "$label expected $expected_count durable pre-state snapshots, found ${#snapshots[@]}"
  snapshot_match=false
  for snapshot in "${snapshots[@]}"; do
    if jq -e --slurpfile expected "$expected_file" '. == $expected[0]' \
        "$snapshot" >/dev/null; then
      snapshot_match=true
      break
    fi
  done
  [[ "$snapshot_match" == true ]] || fail "$label does not contain the exact pre-state"
}

myrmidons_fixture=tests/fixtures/github/myrmidons-ruleset-contract.json

drift_first="$tmp_dir/deterministic-drift-first.log"
drift_second="$tmp_dir/deterministic-drift-second.log"
drift_reordered="$tmp_dir/deterministic-drift-reordered.log"
ordered_fixture="$tmp_dir/deterministic-ordered-fixture.json"
reordered_fixture="$tmp_dir/deterministic-reordered-fixture.json"
jq '
  (.rulesets[].rules[] | select(.type == "pull_request")
    | .parameters.dismissal_restriction.allowed_actors) = [
      {id: 11, type: "User"},
      {id: 22, type: "Team"}
    ]
  | (.rulesets[].rules[] | select(.type == "pull_request")
    | .parameters.required_reviewers) = [
      {
        file_patterns: ["src/**", "tests/**"],
        minimum_approvals: 1,
        reviewer: {id: 101, type: "Team"}
      },
      {
        file_patterns: ["docs/**", "*.md"],
        minimum_approvals: 0,
        reviewer: {id: 202, type: "Team"}
      }
    ]
' "$myrmidons_fixture" >"$ordered_fixture"
run_dry_run "$ordered_fixture" Myrmidons "$drift_first" || {
  cat "$drift_first" >&2
  fail "first deterministic drift preview failed"
}
run_dry_run "$ordered_fixture" Myrmidons "$drift_second" || {
  cat "$drift_second" >&2
  fail "second deterministic drift preview failed"
}
jq '
  .rulesets |= reverse
  | .rulesets[].bypass_actors |= reverse
  | .rulesets[].rules |= reverse
  | (.rulesets[].rules[]
      | select(.type == "required_status_checks")
      | .parameters.required_status_checks) |= reverse
  | (.rulesets[].rules[] | select(.type == "pull_request")
      | .parameters.allowed_merge_methods) |= reverse
  | (.rulesets[].rules[] | select(.type == "pull_request")
      | .parameters.dismissal_restriction.allowed_actors) |= reverse
  | (.rulesets[].rules[] | select(.type == "pull_request")
      | .parameters.required_reviewers) |= reverse
  | (.rulesets[].rules[] | select(.type == "pull_request")
      | .parameters.required_reviewers[].file_patterns) |= reverse
' "$ordered_fixture" >"$reordered_fixture"
run_dry_run "$reordered_fixture" Myrmidons "$drift_reordered" || {
  cat "$drift_reordered" >&2
  fail "semantically reordered deterministic drift preview failed"
}
first_drift=$(sed -n 's/^DRIFT Myrmidons: //p' "$drift_first")
second_drift=$(sed -n 's/^DRIFT Myrmidons: //p' "$drift_second")
reordered_drift=$(sed -n 's/^DRIFT Myrmidons: //p' "$drift_reordered")
first_digest=$(sed -n 's/^DIGEST Myrmidons: //p' "$drift_first")
second_digest=$(sed -n 's/^DIGEST Myrmidons: //p' "$drift_second")
reordered_digest=$(sed -n 's/^DIGEST Myrmidons: //p' "$drift_reordered")
first_inventory=$(sed -n 's/^PROTECTION-INVENTORY Myrmidons: //p' "$drift_first")
second_inventory=$(sed -n 's/^PROTECTION-INVENTORY Myrmidons: //p' "$drift_second")
reordered_inventory=$(sed -n \
  's/^PROTECTION-INVENTORY Myrmidons: //p' "$drift_reordered")
[[ -n "$first_drift" ]] || fail "dry-run did not emit a per-repository drift object"
[[ "$first_drift" == "$second_drift" ]] || fail "dry-run drift is not deterministic"
[[ "$first_drift" == "$reordered_drift" ]] || \
  fail "dry-run drift changes when set-like API arrays are reordered"
[[ -n "$first_digest" ]] || fail "dry-run did not emit canonical JSON digests"
[[ "$first_digest" == "$second_digest" ]] || \
  fail "dry-run canonical JSON digests are not deterministic"
[[ "$first_digest" == "$reordered_digest" ]] || \
  fail "dry-run digest changes when set-like API arrays are reordered"
[[ -n "$first_inventory" ]] || \
  fail "dry-run did not enumerate the complete effective protection inventory"
[[ "$first_inventory" == "$second_inventory" ]] || \
  fail "effective protection inventory is not deterministic"
[[ "$first_inventory" == "$reordered_inventory" ]] || \
  fail "effective protection inventory changes when API arrays are reordered"
jq -en --argjson inventory "$first_inventory" '
  $inventory.classic_branch_protection == {
    present: false,
    restore_payload: null,
    required_signatures: false
  }
  and ($inventory.rulesets | type) == "array"
  and ($inventory.effective_rules | type) == "array"
  and ($inventory.rulesets | length) >= 1
' >/dev/null || fail "effective protection inventory is incomplete"
jq -en --argjson digest "$first_digest" '
  all($digest[][]; type == "string" and test("^[0-9a-f]{64}$"))
  and $digest.ruleset.before != $digest.ruleset.after
  and $digest.repository_settings.before !=
    $digest.repository_settings.after
' >/dev/null || fail "dry-run digests do not bind both complete pre/post resources"
jq -en --argjson drift "$first_drift" '
  ($drift | keys | sort) ==
    (["classic_branch_protection", "repository_settings", "ruleset"] | sort)
  and ($drift.classic_branch_protection.before == null)
  and ($drift.classic_branch_protection.after == null)
  and ($drift.ruleset.before | type) == "object"
  and ($drift.ruleset.after | type) == "object"
  and ($drift.repository_settings.before | type) == "object"
  and ($drift.repository_settings.after | type) == "object"
' >/dev/null || fail "dry-run drift does not cover ruleset and repository settings"
echo "PASS: dry-run emits a deterministic per-repository drift object"

no_op_state="$tmp_dir/no-op-ruleset-state.json"
no_op_settings="$tmp_dir/no-op-repository-settings.json"
no_op_snapshots="$tmp_dir/no-op-snapshots"
no_op_put_count="$tmp_dir/no-op-put-count"
no_op_get_count="$tmp_dir/no-op-get-count"
no_op_settings_count="$tmp_dir/no-op-settings-count"
python3 tools/github/render-fleet-ruleset.py --enforcement active | jq '
  . + {
    id: 15556489,
    source: "HomericIntelligence/Myrmidons",
    source_type: "Repository"
  }
  | .rules |= reverse
  | (.rules[] | select(.type == "required_status_checks")
      | .parameters.required_status_checks) |= reverse
  | (.rules[] | select(.type == "pull_request")
      | .parameters.allowed_merge_methods) |= reverse
  | (.rules[] | select(.type == "pull_request")
      | .parameters.dismissal_restriction.allowed_actors) |= reverse
  | (.rules[] | select(.type == "pull_request")
      | .parameters.required_reviewers) |= reverse
' >"$no_op_state"
jq -n --slurpfile policy configs/github/fleet-ruleset-policy.json '
  $policy[0].repository_settings + {
    full_name: "HomericIntelligence/Myrmidons",
    default_branch: "main"
  }
' >"$no_op_settings"
if ! GH_REPOSITORY_STATE="$no_op_settings" \
    GH_SETTINGS_PATCH_COUNT_FILE="$no_op_settings_count" \
    run_live_update "$myrmidons_fixture" Myrmidons "$no_op_state" \
      "$no_op_snapshots" "$tmp_dir/no-op.log" "$no_op_put_count" \
      "$no_op_get_count"; then
  cat "$tmp_dir/no-op.log" >&2
  fail "no-drift live reconciliation failed"
fi
grep -qF 'NO-DRIFT Myrmidons' "$tmp_dir/no-op.log" || \
  fail "no-drift reconciliation did not report its no-op"
[[ ! -s "$no_op_put_count" ]] || fail "no-drift reconciliation issued a ruleset PUT"
[[ ! -s "$no_op_settings_count" ]] || \
  fail "no-drift reconciliation issued a repository PATCH"
echo "PASS: semantically reordered no-drift reconciliation performs no writes"

sealed_policy_source="$tmp_dir/sealed-policy-source.json"
sealed_ruleset_state="$tmp_dir/sealed-input-ruleset.json"
sealed_repository_state="$tmp_dir/sealed-input-repository.json"
cp configs/github/fleet-ruleset-policy.json "$sealed_policy_source"
cp "$no_op_state" "$sealed_ruleset_state"
cp "$no_op_settings" "$sealed_repository_state"
if ! FLEET_RULESET_POLICY_FILE="$sealed_policy_source" \
    GH_REPOSITORY_STATE="$sealed_repository_state" \
    GH_CORRUPT_POLICY_SOURCE_AT_RULESET_LIST=1 \
    GH_CORRUPT_EVIDENCE_SOURCE_AT_RULESET_LIST=2 run_live_update \
      "$myrmidons_fixture" Myrmidons "$sealed_ruleset_state" \
      "$tmp_dir/sealed-input-snapshots" "$tmp_dir/sealed-input.log" \
      "$tmp_dir/sealed-input-put.count" \
      "$tmp_dir/sealed-input-get.count"; then
  cat "$tmp_dir/sealed-input.log" >&2
  fail "sealed policy/evidence inputs changed after source replacement"
fi
jq -e '. == {}' "$sealed_policy_source" >/dev/null ||
  fail "policy replacement hook did not mutate the original source path"
jq -e '. == {}' "$tmp_dir/evidence-Myrmidons.json" >/dev/null ||
  fail "evidence replacement hook did not mutate the original source path"
echo "PASS: policy and evidence bytes are sealed before remote verification"

preflight_state="$tmp_dir/preflight-state.json"
preflight_pre="$tmp_dir/preflight-pre.json"
preflight_snapshots="$tmp_dir/preflight-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$preflight_state"
cp "$preflight_state" "$preflight_pre"
if GH_FAIL_RULESET_LIST_AT=3 run_live_update \
    "$myrmidons_fixture" Myrmidons,Proteus "$preflight_state" \
    "$preflight_snapshots" "$tmp_dir/preflight.log" \
    "$tmp_dir/preflight-put-count" "$tmp_dir/preflight-get-count"; then
  fail "fleet operation accepted a second-repository preflight failure"
fi
jq -e --slurpfile expected "$preflight_pre" '. == $expected[0]' \
  "$preflight_state" >/dev/null || \
  fail "fleet preflight failure changed an earlier repository"
[[ ! -s "$tmp_dir/preflight-put-count" ]] || \
  fail "fleet preflight failure issued a ruleset PUT"
[[ ! -s "$tmp_dir/settings-Myrmidons-Proteus.count" ]] || \
  fail "fleet preflight failure issued a repository PATCH"
grep -qF 'repos/HomericIntelligence/Myrmidons/rulesets\?includes_parents=true' \
  "$tmp_dir/gh-calls.log" || \
  fail "fleet preflight did not enumerate the first target"
grep -qF 'repos/HomericIntelligence/Proteus/rulesets\?includes_parents=true' \
  "$tmp_dir/gh-calls.log" || \
  fail "fleet preflight failure did not reach the second target"
echo "PASS: every target completes preflight before the first fleet write"

jit_ruleset_state="$tmp_dir/jit-ruleset-state.json"
jit_ruleset_snapshots="$tmp_dir/jit-ruleset-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$jit_ruleset_state"
if GH_CONCURRENT_RULESET_CHANGE_AT=2 run_live_update \
    "$myrmidons_fixture" Myrmidons "$jit_ruleset_state" \
    "$jit_ruleset_snapshots" "$tmp_dir/jit-ruleset.log" \
    "$tmp_dir/jit-ruleset-put-count" "$tmp_dir/jit-ruleset-get-count"; then
  fail "fleet mutation accepted ruleset drift after full-fleet preflight"
fi
[[ ! -s "$tmp_dir/jit-ruleset-put-count" ]] || \
  fail "ruleset precondition drift was overwritten by a forward or rollback PUT"
jq -e '.conditions.ref_name.include == ["refs/heads/concurrent"]' \
  "$jit_ruleset_state" >/dev/null || \
  fail "ruleset precondition drift did not preserve the concurrent state"
grep -qF 'precondition changed after fleet preflight' \
  "$tmp_dir/jit-ruleset.log" || \
  fail "ruleset precondition drift was not reported explicitly"
echo "PASS: just-in-time ruleset precondition refuses concurrent drift without writing"

jit_unknown_ruleset="$tmp_dir/jit-unknown-ruleset.json"
seed_ruleset_state "$myrmidons_fixture" "$jit_unknown_ruleset"
if GH_CONCURRENT_RULESET_UNKNOWN_AT=2 run_live_update \
    "$myrmidons_fixture" Myrmidons "$jit_unknown_ruleset" \
    "$tmp_dir/jit-unknown-snapshots" "$tmp_dir/jit-unknown.log" \
    "$tmp_dir/jit-unknown-put-count" \
    "$tmp_dir/jit-unknown-get-count"; then
  fail "JIT precondition accepted an unknown top-level ruleset field"
fi
jq -e '.future_guard == true' "$jit_unknown_ruleset" >/dev/null ||
  fail "JIT unknown-field state was not preserved"
[[ ! -s "$tmp_dir/jit-unknown-put-count" ]] ||
  fail "JIT unknown-field state was overwritten"
echo "PASS: JIT ruleset classification rejects unknown top-level fields"

final_unknown_ruleset="$tmp_dir/final-unknown-ruleset.json"
final_unknown_repository="$tmp_dir/final-unknown-repository.json"
final_unknown_settings_count="$tmp_dir/final-unknown-settings.count"
seed_ruleset_state "$myrmidons_fixture" "$final_unknown_ruleset"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$final_unknown_repository"
if GH_REPOSITORY_STATE="$final_unknown_repository" \
    GH_SETTINGS_PATCH_COUNT_FILE="$final_unknown_settings_count" \
    GH_CONCURRENT_RULESET_UNKNOWN_AT=4 run_live_update \
      "$myrmidons_fixture" Myrmidons "$final_unknown_ruleset" \
      "$tmp_dir/final-unknown-snapshots" "$tmp_dir/final-unknown.log" \
      "$tmp_dir/final-unknown-put-count" \
      "$tmp_dir/final-unknown-get-count"; then
  fail "final classification accepted an unknown top-level ruleset field"
fi
jq -e '.future_guard == true' "$final_unknown_ruleset" >/dev/null ||
  fail "rollback overwrote the unknown top-level ruleset field"
[[ $(<"$tmp_dir/final-unknown-put-count") -eq 1 ]] ||
  fail "rollback wrote across an unknown top-level ruleset state"
[[ $(<"$final_unknown_settings_count") -eq 2 ]] ||
  fail "unknown final ruleset state did not restore repository settings"
grep -qF 'UNCERTAIN MUTATION' "$tmp_dir/final-unknown.log" ||
  fail "unknown rollback state did not report uncertainty"
echo "PASS: final and rollback classifications preserve unknown top-level fields"

jit_settings_ruleset="$tmp_dir/jit-settings-ruleset.json"
jit_settings_state="$tmp_dir/jit-settings-state.json"
jit_settings_snapshots="$tmp_dir/jit-settings-snapshots"
python3 tools/github/render-fleet-ruleset.py --enforcement active | jq '
  . + {
    id: 15556489,
    source: "HomericIntelligence/Myrmidons",
    source_type: "Repository"
  }
' >"$jit_settings_ruleset"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$jit_settings_state"
if GH_REPOSITORY_STATE="$jit_settings_state" \
    GH_CONCURRENT_SETTINGS_CHANGE_AT=2 run_live_update \
      "$myrmidons_fixture" Myrmidons "$jit_settings_ruleset" \
      "$jit_settings_snapshots" "$tmp_dir/jit-settings.log" \
      "$tmp_dir/jit-settings-put-count" "$tmp_dir/jit-settings-get-count"; then
  fail "fleet mutation accepted settings drift after full-fleet preflight"
fi
[[ ! -s "$tmp_dir/settings-Myrmidons.count" ]] || \
  fail "settings precondition drift was overwritten by a forward or rollback PATCH"
jq -e '.allow_squash_merge == false' "$jit_settings_state" >/dev/null || \
  fail "settings precondition drift did not preserve the concurrent state"
grep -qF 'precondition changed after fleet preflight' \
  "$tmp_dir/jit-settings.log" || \
  fail "settings precondition drift was not reported explicitly"
echo "PASS: just-in-time settings precondition refuses concurrent drift without writing"

late_settings_ruleset="$tmp_dir/late-settings-ruleset.json"
late_settings_ruleset_pre="$tmp_dir/late-settings-ruleset-pre.json"
late_settings_repository="$tmp_dir/late-settings-repository.json"
seed_ruleset_state "$myrmidons_fixture" "$late_settings_ruleset"
cp "$late_settings_ruleset" "$late_settings_ruleset_pre"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$late_settings_repository"
if GH_REPOSITORY_STATE="$late_settings_repository" \
    GH_CONCURRENT_SETTINGS_CHANGE_AT=4 run_live_update \
      "$myrmidons_fixture" Myrmidons "$late_settings_ruleset" \
      "$tmp_dir/late-settings-snapshots" "$tmp_dir/late-settings.log" \
      "$tmp_dir/late-settings-put-count" \
      "$tmp_dir/late-settings-get-count"; then
  fail "repository PATCH overwrote a settings change observed immediately before write"
fi
jq -e '.allow_squash_merge == false' "$late_settings_repository" >/dev/null ||
  fail "late concurrent repository-settings change was not preserved"
[[ ! -s "$tmp_dir/settings-Myrmidons.count" ]] ||
  fail "late concurrent repository-settings change was overwritten by PATCH"
jq -e --slurpfile expected "$late_settings_ruleset_pre" \
  '. == $expected[0]' "$late_settings_ruleset" >/dev/null ||
  fail "late repository-settings race did not restore the preceding ruleset write"
[[ $(<"$tmp_dir/late-settings-put-count") -eq 2 ]] ||
  fail "late repository-settings race did not issue one forward and one rollback PUT"
grep -qF 'repository-settings-before-write' "$tmp_dir/late-settings.log" ||
  fail "late repository-settings race was not identified at the write boundary"
echo "PASS: immediate pre-PATCH comparison preserves concurrent settings"

jit_sha_state="$tmp_dir/jit-sha-state.json"
jit_sha_snapshots="$tmp_dir/jit-sha-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$jit_sha_state"
if GH_MAIN_SHA_CHANGE_AT=2 run_live_update \
    "$myrmidons_fixture" Myrmidons "$jit_sha_state" "$jit_sha_snapshots" \
    "$tmp_dir/jit-sha.log" "$tmp_dir/jit-sha-put-count" \
    "$tmp_dir/jit-sha-get-count"; then
  fail "fleet mutation accepted a default-branch advance after evidence verification"
fi
[[ ! -s "$tmp_dir/jit-sha-put-count" ]] || \
  fail "stale default-branch evidence issued a ruleset PUT"
[[ ! -s "$tmp_dir/settings-Myrmidons.count" ]] || \
  fail "stale default-branch evidence issued a repository PATCH"
grep -qF 'default-branch-sha precondition changed after fleet preflight' \
  "$tmp_dir/jit-sha.log" || \
  fail "default-branch advance was not reported as stale evidence"
echo "PASS: just-in-time default-branch SHA check refuses stale evidence"

assert_mid_transaction_sha_advance_rejected() {
  local name=$1
  local branch_get=$2
  local expected_settings_writes=$3
  local ruleset_state="$tmp_dir/$name-ruleset.json"
  local ruleset_pre="$tmp_dir/$name-ruleset-pre.json"
  local repository_state="$tmp_dir/$name-repository.json"
  local settings_count="$tmp_dir/$name-settings.count"
  local put_count="$tmp_dir/$name-put.count"
  local output="$tmp_dir/$name.log"

  seed_ruleset_state "$myrmidons_fixture" "$ruleset_state"
  cp "$ruleset_state" "$ruleset_pre"
  jq -n '{
    full_name: "HomericIntelligence/Myrmidons",
    default_branch: "main",
    allow_auto_merge: false,
    allow_merge_commit: true,
    allow_rebase_merge: true,
    allow_squash_merge: true,
    allow_update_branch: false,
    delete_branch_on_merge: false,
    web_commit_signoff_required: false
  }' >"$repository_state"
  if GH_REPOSITORY_STATE="$repository_state" \
      GH_SETTINGS_PATCH_COUNT_FILE="$settings_count" \
      GH_MAIN_SHA_CHANGE_AT="$branch_get" run_live_update \
        "$myrmidons_fixture" Myrmidons "$ruleset_state" \
        "$tmp_dir/$name-snapshots" "$output" "$put_count" \
        "$tmp_dir/$name-get.count"; then
    fail "$name accepted a main advance after the JIT evidence check"
  fi
  jq -e --slurpfile expected "$ruleset_pre" '. == $expected[0]' \
    "$ruleset_state" >/dev/null ||
    fail "$name did not restore the pre-command ruleset"
  [[ $(<"$put_count") -eq 2 ]] ||
    fail "$name did not issue one forward and one rollback ruleset PUT"
  if [[ "$expected_settings_writes" -eq 0 ]]; then
    [[ ! -s "$settings_count" ]] ||
      fail "$name patched settings after evidence became stale"
  else
    [[ $(<"$settings_count") -eq "$expected_settings_writes" ]] ||
      fail "$name did not restore repository settings after final evidence drift"
  fi
  grep -qF 'default-branch-sha' "$output" ||
    fail "$name did not identify stale exact-main evidence"
  echo "PASS: $name rejects a main advance and compensates prior writes"
}

assert_mid_transaction_sha_advance_rejected \
  main-advance-before-settings 4 0
assert_mid_transaction_sha_advance_rejected \
  main-advance-before-final-success 5 2

jit_default_branch_state="$tmp_dir/jit-default-branch-state.json"
jit_default_branch_settings="$tmp_dir/jit-default-branch-settings.json"
jit_default_branch_snapshots="$tmp_dir/jit-default-branch-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$jit_default_branch_state"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$jit_default_branch_settings"
if GH_REPOSITORY_STATE="$jit_default_branch_settings" \
    GH_DEFAULT_BRANCH_CHANGE_AT=2 run_live_update \
      "$myrmidons_fixture" Myrmidons "$jit_default_branch_state" \
      "$jit_default_branch_snapshots" "$tmp_dir/jit-default-branch.log" \
      "$tmp_dir/jit-default-branch-put-count" \
      "$tmp_dir/jit-default-branch-get-count"; then
  fail "fleet mutation accepted a changed default-branch identity"
fi
[[ ! -s "$tmp_dir/jit-default-branch-put-count" ]] || \
  fail "changed default branch issued a ruleset PUT"
[[ ! -s "$tmp_dir/settings-Myrmidons.count" ]] || \
  fail "changed default branch issued a repository PATCH"
jq -e '.default_branch == "develop"' "$jit_default_branch_settings" \
  >/dev/null || fail "changed default-branch state was not preserved"
grep -qF 'default-branch-identity precondition changed after fleet preflight' \
  "$tmp_dir/jit-default-branch.log" || \
  fail "changed default-branch identity was not reported explicitly"
echo "PASS: just-in-time repository read binds the original default branch"

post_settings_branch_ruleset="$tmp_dir/post-settings-branch-ruleset.json"
post_settings_branch_ruleset_pre="$tmp_dir/post-settings-branch-ruleset-pre.json"
post_settings_branch_state="$tmp_dir/post-settings-branch-state.json"
seed_ruleset_state "$myrmidons_fixture" "$post_settings_branch_ruleset"
cp "$post_settings_branch_ruleset" "$post_settings_branch_ruleset_pre"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$post_settings_branch_state"
if GH_REPOSITORY_STATE="$post_settings_branch_state" \
    GH_DEFAULT_BRANCH_CHANGE_AT=5 run_live_update \
      "$myrmidons_fixture" Myrmidons "$post_settings_branch_ruleset" \
      "$tmp_dir/post-settings-branch-snapshots" \
      "$tmp_dir/post-settings-branch.log" \
      "$tmp_dir/post-settings-branch-put-count" \
      "$tmp_dir/post-settings-branch-get-count"; then
  fail "post-PATCH readback accepted a changed default branch"
fi
jq -e '.default_branch == "develop"' "$post_settings_branch_state" \
  >/dev/null || fail "post-PATCH default-branch race was overwritten"
jq -e --slurpfile expected "$post_settings_branch_ruleset_pre" \
  '. == $expected[0]' "$post_settings_branch_ruleset" >/dev/null || \
  fail "post-PATCH default-branch race did not restore the ruleset"
[[ $(<"$tmp_dir/settings-Myrmidons.count") -eq 1 ]] || \
  fail "post-PATCH default-branch race attempted an unsafe settings rollback"
[[ $(<"$tmp_dir/post-settings-branch-put-count") -eq 2 ]] || \
  fail "post-PATCH default-branch race did not restore the ruleset once"
grep -qF 'UNCERTAIN MUTATION' "$tmp_dir/post-settings-branch.log" || \
  fail "post-PATCH default-branch race did not report uncertainty"
echo "PASS: post-PATCH readback binds repository and default-branch identity"

jit_protection_state="$tmp_dir/jit-protection-state.json"
jit_protection_snapshots="$tmp_dir/jit-protection-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$jit_protection_state"
if GH_CLASSIC_PROTECTION_CHANGE_AT=2 run_live_update \
    "$myrmidons_fixture" Myrmidons "$jit_protection_state" \
    "$jit_protection_snapshots" "$tmp_dir/jit-protection.log" \
    "$tmp_dir/jit-protection-put-count" \
    "$tmp_dir/jit-protection-get-count"; then
  fail "fleet mutation accepted classic protection added after preflight"
fi
[[ ! -s "$tmp_dir/jit-protection-put-count" ]] || \
  fail "changed effective protection inventory issued a ruleset PUT"
[[ ! -s "$tmp_dir/settings-Myrmidons.count" ]] || \
  fail "changed effective protection inventory issued a repository PATCH"
grep -qF 'effective-protection precondition changed after fleet preflight' \
  "$tmp_dir/jit-protection.log" || \
  fail "changed effective protection inventory was not reported"
echo "PASS: just-in-time effective-protection check catches new classic protection"

predelete_sha_ruleset="$tmp_dir/predelete-sha-ruleset.json"
predelete_sha_ruleset_pre="$tmp_dir/predelete-sha-ruleset-pre.json"
predelete_sha_repository="$tmp_dir/predelete-sha-repository.json"
predelete_sha_classic="$tmp_dir/predelete-sha-classic.json"
predelete_sha_classic_pre="$tmp_dir/predelete-sha-classic-pre.json"
predelete_sha_settings_count="$tmp_dir/predelete-sha-settings.count"
predelete_sha_classic_count="$tmp_dir/predelete-sha-classic.count"
seed_ruleset_state "$myrmidons_fixture" "$predelete_sha_ruleset"
cp "$predelete_sha_ruleset" "$predelete_sha_ruleset_pre"
write_classic_protection_fixture "$predelete_sha_classic"
cp "$predelete_sha_classic" "$predelete_sha_classic_pre"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$predelete_sha_repository"
if GH_REPOSITORY_STATE="$predelete_sha_repository" \
    GH_CLASSIC_PROTECTION_STATE="$predelete_sha_classic" \
    GH_SETTINGS_PATCH_COUNT_FILE="$predelete_sha_settings_count" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$predelete_sha_classic_count" \
    GH_MAIN_SHA_CHANGE_AT=5 run_live_update \
      "$myrmidons_fixture" Myrmidons "$predelete_sha_ruleset" \
      "$tmp_dir/predelete-sha-snapshots" "$tmp_dir/predelete-sha.log" \
      "$tmp_dir/predelete-sha-put.count" \
      "$tmp_dir/predelete-sha-get.count"; then
  fail "classic deletion accepted stale exact-main evidence"
fi
[[ ! -s "$predelete_sha_classic_count" ]] ||
  fail "stale exact-main evidence reached classic-protection DELETE"
jq -e --slurpfile expected "$predelete_sha_classic_pre" '. == $expected[0]' \
  "$predelete_sha_classic" >/dev/null ||
  fail "classic protection changed after the pre-delete evidence refusal"
jq -e --slurpfile expected "$predelete_sha_ruleset_pre" '. == $expected[0]' \
  "$predelete_sha_ruleset" >/dev/null ||
  fail "pre-delete SHA race did not restore the ruleset"
[[ $(<"$tmp_dir/predelete-sha-put.count") -eq 2 ]] ||
  fail "pre-delete SHA race did not roll back the ruleset once"
[[ $(<"$predelete_sha_settings_count") -eq 2 ]] ||
  fail "pre-delete SHA race did not roll back repository settings once"
grep -qF 'default-branch-sha-before-classic-delete' \
  "$tmp_dir/predelete-sha.log" ||
  fail "pre-delete SHA race was not identified before destructive removal"
echo "PASS: exact-main evidence is rechecked before classic-protection deletion"

final_overlap_ruleset="$tmp_dir/final-overlap-ruleset.json"
final_overlap_ruleset_pre="$tmp_dir/final-overlap-ruleset-pre.json"
final_overlap_repository="$tmp_dir/final-overlap-repository.json"
final_overlap_repository_pre="$tmp_dir/final-overlap-repository-pre.json"
final_overlap_settings_count="$tmp_dir/final-overlap-settings.count"
seed_ruleset_state "$myrmidons_fixture" "$final_overlap_ruleset"
cp "$final_overlap_ruleset" "$final_overlap_ruleset_pre"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$final_overlap_repository"
cp "$final_overlap_repository" "$final_overlap_repository_pre"
if GH_REPOSITORY_STATE="$final_overlap_repository" \
    GH_SETTINGS_PATCH_COUNT_FILE="$final_overlap_settings_count" \
    GH_RULESET_LIST_EXTRA_AT=4 GH_EFFECTIVE_OVERLAP_AT=3 run_live_update \
      "$myrmidons_fixture" Myrmidons "$final_overlap_ruleset" \
      "$tmp_dir/final-overlap-snapshots" "$tmp_dir/final-overlap.log" \
      "$tmp_dir/final-overlap-put.count" \
      "$tmp_dir/final-overlap-get.count"; then
  fail "final success accepted a newly effective overlapping ruleset"
fi
jq -e --slurpfile expected "$final_overlap_ruleset_pre" \
  '. == $expected[0]' "$final_overlap_ruleset" >/dev/null ||
  fail "final overlap race did not restore the ruleset"
jq -e --slurpfile expected "$final_overlap_repository_pre" \
  '. == $expected[0]' "$final_overlap_repository" >/dev/null ||
  fail "final overlap race did not restore repository settings"
[[ $(<"$tmp_dir/final-overlap-put.count") -eq 2 ]] ||
  fail "final overlap race did not roll back the ruleset once"
[[ $(<"$final_overlap_settings_count") -eq 2 ]] ||
  fail "final overlap race did not roll back repository settings once"
[[ $(<"$tmp_dir/ruleset-lists-Myrmidons.count") -ge 4 ]] ||
  fail "final overlap check did not re-enumerate includes-parents rulesets"
[[ $(<"$tmp_dir/effective-gets-Myrmidons.count") -ge 3 ]] ||
  fail "final overlap check did not re-fetch effective default-branch rules"
grep -qF 'final-effective-protection' "$tmp_dir/final-overlap.log" ||
  fail "final overlap race was not identified by the final postcondition"
echo "PASS: final success rejects a newly effective overlapping ruleset"

final_parameter_ruleset="$tmp_dir/final-parameter-ruleset.json"
final_parameter_ruleset_pre="$tmp_dir/final-parameter-ruleset-pre.json"
final_parameter_repository="$tmp_dir/final-parameter-repository.json"
final_parameter_repository_pre="$tmp_dir/final-parameter-repository-pre.json"
final_parameter_settings_count="$tmp_dir/final-parameter-settings.count"
seed_ruleset_state "$myrmidons_fixture" "$final_parameter_ruleset"
cp "$final_parameter_ruleset" "$final_parameter_ruleset_pre"
cp "$final_overlap_repository_pre" "$final_parameter_repository"
cp "$final_parameter_repository" "$final_parameter_repository_pre"
if GH_REPOSITORY_STATE="$final_parameter_repository" \
    GH_SETTINGS_PATCH_COUNT_FILE="$final_parameter_settings_count" \
    GH_EFFECTIVE_PARAMETER_MISMATCH_AT=3 run_live_update \
      "$myrmidons_fixture" Myrmidons "$final_parameter_ruleset" \
      "$tmp_dir/final-parameter-snapshots" "$tmp_dir/final-parameter.log" \
      "$tmp_dir/final-parameter-put.count" \
      "$tmp_dir/final-parameter-get.count"; then
  fail "final success accepted mismatched effective rule parameters"
fi
jq -e --slurpfile expected "$final_parameter_ruleset_pre" \
  '. == $expected[0]' "$final_parameter_ruleset" >/dev/null ||
  fail "final effective-parameter race did not restore the ruleset"
jq -e --slurpfile expected "$final_parameter_repository_pre" \
  '. == $expected[0]' "$final_parameter_repository" >/dev/null ||
  fail "final effective-parameter race did not restore repository settings"
grep -qF 'final-effective-protection' "$tmp_dir/final-parameter.log" ||
  fail "final effective-parameter mismatch was not identified"
echo "PASS: final success requires exact effective rule parameters"

final_duplicate_ruleset="$tmp_dir/final-duplicate-ruleset.json"
final_duplicate_ruleset_pre="$tmp_dir/final-duplicate-ruleset-pre.json"
final_duplicate_repository="$tmp_dir/final-duplicate-repository.json"
final_duplicate_repository_pre="$tmp_dir/final-duplicate-repository-pre.json"
final_duplicate_settings_count="$tmp_dir/final-duplicate-settings.count"
seed_ruleset_state "$myrmidons_fixture" "$final_duplicate_ruleset"
cp "$final_duplicate_ruleset" "$final_duplicate_ruleset_pre"
cp "$final_overlap_repository_pre" "$final_duplicate_repository"
cp "$final_duplicate_repository" "$final_duplicate_repository_pre"
if GH_REPOSITORY_STATE="$final_duplicate_repository" \
    GH_SETTINGS_PATCH_COUNT_FILE="$final_duplicate_settings_count" \
    GH_RULESET_LIST_DUPLICATE_BASELINE_AT=4 run_live_update \
      "$myrmidons_fixture" Myrmidons "$final_duplicate_ruleset" \
      "$tmp_dir/final-duplicate-snapshots" "$tmp_dir/final-duplicate.log" \
      "$tmp_dir/final-duplicate-put.count" \
      "$tmp_dir/final-duplicate-get.count"; then
  fail "final success accepted a duplicate repository baseline"
fi
jq -e --slurpfile expected "$final_duplicate_ruleset_pre" \
  '. == $expected[0]' "$final_duplicate_ruleset" >/dev/null ||
  fail "final duplicate-baseline race did not restore the ruleset"
jq -e --slurpfile expected "$final_duplicate_repository_pre" \
  '. == $expected[0]' "$final_duplicate_repository" >/dev/null ||
  fail "final duplicate-baseline race did not restore repository settings"
grep -qF 'final-effective-protection' "$tmp_dir/final-duplicate.log" ||
  fail "final duplicate baseline was not identified"
echo "PASS: final success requires exactly one repository baseline"

final_enforcement_ruleset="$tmp_dir/final-enforcement-ruleset.json"
final_enforcement_ruleset_pre="$tmp_dir/final-enforcement-ruleset-pre.json"
final_enforcement_repository="$tmp_dir/final-enforcement-repository.json"
seed_ruleset_state "$myrmidons_fixture" "$final_enforcement_ruleset"
cp "$final_enforcement_ruleset" "$final_enforcement_ruleset_pre"
cp "$final_overlap_repository_pre" "$final_enforcement_repository"
if GH_REPOSITORY_STATE="$final_enforcement_repository" \
    GH_RULESET_LIST_UNKNOWN_ENFORCEMENT_AT=4 run_live_update \
      "$myrmidons_fixture" Myrmidons "$final_enforcement_ruleset" \
      "$tmp_dir/final-enforcement-snapshots" "$tmp_dir/final-enforcement.log" \
      "$tmp_dir/final-enforcement-put.count" \
      "$tmp_dir/final-enforcement-get.count"; then
  fail "final success accepted an unknown ruleset enforcement mode"
fi
jq -e --slurpfile expected "$final_enforcement_ruleset_pre" \
  '. == $expected[0]' "$final_enforcement_ruleset" >/dev/null ||
  fail "unknown final enforcement mode did not trigger exact rollback"
grep -qF 'final-effective-protection' "$tmp_dir/final-enforcement.log" ||
  fail "unknown final enforcement mode was not identified"
echo "PASS: final inventory rejects unknown ruleset enforcement modes"

fleet_ruleset_dir="$tmp_dir/fleet-rulesets"
fleet_snapshots="$tmp_dir/fleet-rollback-snapshots"
mkdir -p "$fleet_ruleset_dir"
for fleet_repo in Myrmidons Proteus; do
  jq --arg source "HomericIntelligence/$fleet_repo" '
    .rulesets[]
    | select(.name == "homeric-main-baseline")
    | .source = $source
  ' "$myrmidons_fixture" >"$fleet_ruleset_dir/$fleet_repo-ruleset.json"
  cp "$fleet_ruleset_dir/$fleet_repo-ruleset.json" \
    "$fleet_ruleset_dir/$fleet_repo-pre.json"
done
if GH_RULESET_STATE_DIR="$fleet_ruleset_dir" \
    GH_FAIL_PUT_AFTER_WRITE_AT=2,4 \
    GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT=2 run_live_update \
      "$myrmidons_fixture" Myrmidons,Proteus \
      "$fleet_ruleset_dir/Myrmidons-ruleset.json" "$fleet_snapshots" \
      "$tmp_dir/fleet-rollback.log" "$tmp_dir/fleet-rollback-put-count" \
      "$tmp_dir/fleet-rollback-get-count"; then
  fail "fleet operation accepted an ambiguous second-repository write"
fi
for fleet_repo in Myrmidons Proteus; do
  jq -e --slurpfile expected "$fleet_ruleset_dir/$fleet_repo-pre.json" \
    '. == $expected[0]' "$fleet_ruleset_dir/$fleet_repo-ruleset.json" \
    >/dev/null || fail "fleet rollback did not restore $fleet_repo ruleset"
done
jq -e '
  .allow_auto_merge == false
  and .allow_merge_commit == true
  and .allow_rebase_merge == true
  and .allow_update_branch == false
  and .delete_branch_on_merge == false
  and .web_commit_signoff_required == false
' "$tmp_dir/repository-Myrmidons-Proteus.d/Myrmidons-settings.json" \
  >/dev/null || fail "fleet rollback did not restore Myrmidons repository settings"
grep -qF 'Fleet rollback verified exactly' "$tmp_dir/fleet-rollback.log" || {
  cat "$tmp_dir/fleet-rollback.log" >&2
  fail "fleet rollback did not report exact verification"
}
[[ $(<"$tmp_dir/fleet-rollback-put-count") -eq 4 ]] || \
  fail "fleet rollback issued an unsafe number of ruleset PUT requests"
[[ $(<"$tmp_dir/settings-Myrmidons-Proteus.count") -eq 2 ]] || \
  fail "fleet rollback issued an unsafe number of repository PATCH requests"
grep -qF 'rollback PUT reported exit' "$tmp_dir/fleet-rollback.log" || \
  fail "fleet rollback did not classify its ambiguous ruleset rollback"
grep -qF 'rollback PATCH reported exit' "$tmp_dir/fleet-rollback.log" || \
  fail "fleet rollback did not classify its ambiguous settings rollback"
echo "PASS: later failure verifies ambiguous rollback writes for every completed repository"

final_sweep_ruleset_dir="$tmp_dir/final-sweep-rulesets"
final_sweep_snapshots="$tmp_dir/final-sweep-snapshots"
mkdir -p "$final_sweep_ruleset_dir"
for final_sweep_repo in Myrmidons Proteus; do
  jq --arg source "HomericIntelligence/$final_sweep_repo" '
    .rulesets[]
    | select(.name == "homeric-main-baseline")
    | .source = $source
  ' "$myrmidons_fixture" \
    >"$final_sweep_ruleset_dir/$final_sweep_repo-ruleset.json"
  cp "$final_sweep_ruleset_dir/$final_sweep_repo-ruleset.json" \
    "$final_sweep_ruleset_dir/$final_sweep_repo-pre.json"
done
if GH_RULESET_STATE_DIR="$final_sweep_ruleset_dir" \
    GH_DRIFT_COMPLETED_REPO_ON_PUT_SOURCE=Proteus \
    GH_DRIFT_COMPLETED_REPO_ON_PUT_TARGET=Myrmidons run_live_update \
      "$myrmidons_fixture" Myrmidons,Proteus \
      "$final_sweep_ruleset_dir/Myrmidons-ruleset.json" \
      "$final_sweep_snapshots" "$tmp_dir/final-sweep.log" \
      "$tmp_dir/final-sweep-put-count" \
      "$tmp_dir/final-sweep-get-count"; then
  fail "fleet commit accepted drift in an earlier completed repository"
fi
jq -e '.conditions.ref_name.include ==
    ["refs/heads/concurrent-final-sweep"]' \
  "$final_sweep_ruleset_dir/Myrmidons-ruleset.json" >/dev/null ||
  fail "final sweep overwrote concurrent third-state drift"
jq -e --slurpfile expected "$final_sweep_ruleset_dir/Proteus-pre.json" \
  '. == $expected[0]' \
  "$final_sweep_ruleset_dir/Proteus-ruleset.json" >/dev/null ||
  fail "final-sweep compensation did not restore the later repository"
grep -qF 'final fleet sweep detected drift in Myrmidons' \
  "$tmp_dir/final-sweep.log" ||
  fail "fleet-wide final sweep did not identify the earlier repository"
grep -qF 'UNCERTAIN MUTATION' "$tmp_dir/final-sweep.log" ||
  fail "third-state final-sweep drift did not report rollback uncertainty"
echo "PASS: final fleet sweep revalidates earlier repositories without overwriting drift"

unexpected_exit_ruleset_dir="$tmp_dir/unexpected-exit-rulesets"
unexpected_exit_snapshots="$tmp_dir/unexpected-exit-snapshots"
mkdir -p "$unexpected_exit_ruleset_dir"
for unexpected_repo in Myrmidons Proteus; do
  jq --arg source "HomericIntelligence/$unexpected_repo" '
    .rulesets[]
    | select(.name == "homeric-main-baseline")
    | .source = $source
  ' "$myrmidons_fixture" \
    >"$unexpected_exit_ruleset_dir/$unexpected_repo-ruleset.json"
  cp "$unexpected_exit_ruleset_dir/$unexpected_repo-ruleset.json" \
    "$unexpected_exit_ruleset_dir/$unexpected_repo-pre.json"
done
cp tests/fixtures/github/mock-jq-unexpected-exit.sh "$tmp_dir/bin/jq"
chmod +x "$tmp_dir/bin/jq"
if GH_RULESET_STATE_DIR="$unexpected_exit_ruleset_dir" \
    JQ_FAIL_PROVENANCE_REPO=Proteus run_live_update \
      "$myrmidons_fixture" Myrmidons,Proteus \
      "$unexpected_exit_ruleset_dir/Myrmidons-ruleset.json" \
      "$unexpected_exit_snapshots" "$tmp_dir/unexpected-exit.log" \
      "$tmp_dir/unexpected-exit-put-count" \
      "$tmp_dir/unexpected-exit-get-count"; then
  fail "unexpected failure between repositories was accepted"
fi
for unexpected_repo in Myrmidons Proteus; do
  jq -e \
    --slurpfile expected "$unexpected_exit_ruleset_dir/$unexpected_repo-pre.json" \
    '. == $expected[0]' \
    "$unexpected_exit_ruleset_dir/$unexpected_repo-ruleset.json" \
    >/dev/null || \
    fail "unexpected exit did not restore $unexpected_repo ruleset pre-state"
done
jq -e '
  .allow_auto_merge == false
  and .allow_merge_commit == true
  and .allow_rebase_merge == true
  and .allow_update_branch == false
  and .delete_branch_on_merge == false
  and .web_commit_signoff_required == false
' "$tmp_dir/repository-Myrmidons-Proteus.d/Myrmidons-settings.json" \
  >/dev/null || \
  fail "unexpected exit did not restore the completed repository settings"
[[ $(<"$tmp_dir/unexpected-exit-put-count") -eq 2 ]] || \
  fail "unexpected exit did not issue exactly one forward and one rollback PUT"
[[ $(<"$tmp_dir/settings-Myrmidons-Proteus.count") -eq 2 ]] || \
  fail "unexpected exit did not issue exactly one forward and one rollback PATCH"
if grep -Eq -- '(-X|--method) (PUT|PATCH) repos/HomericIntelligence/Proteus' \
    "$tmp_dir/gh-calls.log"; then
  fail "unexpected exit mutated the repository whose provenance lookup failed"
fi
[[ $(grep -cF 'Unexpected exit recovery verified exactly' \
  "$tmp_dir/unexpected-exit.log") -eq 1 ]] || \
  fail "unexpected exit recovery was missing or recursive"
rm -f "$tmp_dir/bin/jq"
echo "PASS: unexpected failure between repositories compensates completed writes once"

assert_remote_evidence_rejected() {
  local name=$1
  local variable=$2
  local value=$3
  local state_file="$tmp_dir/evidence-$name-state.json"
  local pre_file="$tmp_dir/evidence-$name-pre.json"
  local snapshots="$tmp_dir/evidence-$name-snapshots"
  local output_file="$tmp_dir/evidence-$name.log"
  local put_count="$tmp_dir/evidence-$name-put-count"
  local get_count="$tmp_dir/evidence-$name-get-count"
  local accepted=false

  seed_ruleset_state "$myrmidons_fixture" "$state_file"
  cp "$state_file" "$pre_file"
  export "$variable=$value"
  if run_live_update "$myrmidons_fixture" Myrmidons "$state_file" \
      "$snapshots" "$output_file" "$put_count" "$get_count"; then
    accepted=true
  fi
  unset "$variable"

  if [[ "$accepted" == true ]]; then
    cat "$output_file" >&2
    fail "GitHub evidence verifier accepted $name"
  fi
  grep -qF 'GitHub evidence verification failed' "$output_file" || {
    cat "$output_file" >&2
    fail "$name did not report an evidence-verification failure"
  }
  jq -e --slurpfile expected "$pre_file" '. == $expected[0]' \
    "$state_file" >/dev/null || fail "$name changed ruleset state"
  [[ ! -s "$put_count" ]] || fail "$name issued a ruleset PUT"
  echo "PASS: GitHub evidence verifier rejects $name"
}

assert_remote_evidence_rejected wrong-run-repository \
  GH_ACTION_REPO_OVERRIDE HomericIntelligence/Argus
assert_remote_evidence_rejected wrong-run-event GH_ACTION_EVENT_OVERRIDE push
assert_remote_evidence_rejected failed-run GH_ACTION_CONCLUSION_OVERRIDE failure
assert_remote_evidence_rejected wrong-run-sha GH_ACTION_SHA_OVERRIDE \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_remote_evidence_rejected wrong-run-identity GH_ACTION_ID_OVERRIDE 999
assert_remote_evidence_rejected wrong-run-attempt GH_ACTION_ATTEMPT_OVERRIDE 2
assert_remote_evidence_rejected wrong-run-url GH_ACTION_HTML_URL_OVERRIDE \
  https://github.com/HomericIntelligence/Myrmidons/actions/runs/999/attempts/1
assert_remote_evidence_rejected wrong-workflow-name \
  GH_ACTION_WORKFLOW_NAME_OVERRIDE Another-Workflow
assert_remote_evidence_rejected wrong-workflow-path \
  GH_ACTION_WORKFLOW_PATH_OVERRIDE .github/workflows/another.yml
assert_remote_evidence_rejected wrong-merge-group-branch \
  GH_ACTION_HEAD_BRANCH_OVERRIDE feature/not-a-merge-group
assert_remote_evidence_rejected failed-aggregate-gate \
  GH_GATE_CONCLUSION_OVERRIDE failure
assert_remote_evidence_rejected wrong-gate-app GH_GATE_APP_ID_OVERRIDE 999
assert_remote_evidence_rejected duplicate-aggregate-gate \
  GH_GATE_TOTAL_COUNT_OVERRIDE 2
assert_remote_evidence_rejected stale-main-sha GH_MAIN_SHA_OVERRIDE \
  bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_remote_evidence_rejected merge-queue-smoke-still-present \
  GH_GIT_TREE_SMOKE_PRESENT true
assert_remote_evidence_rejected missing-required-producer \
  GH_GIT_TREE_REQUIRED_MISSING true
assert_remote_evidence_rejected stale-producer-workflow-blob \
  GH_GIT_TREE_REQUIRED_BLOB_CHANGE_AT 2
assert_remote_evidence_rejected merge-group-job-name-drift \
  GH_MERGE_GROUP_JOB_NAME_OVERRIDE merge-group-only-worker
assert_remote_evidence_rejected merge-group-job-result-drift \
  GH_MERGE_GROUP_JOB_CONCLUSION_OVERRIDE skipped
assert_remote_evidence_rejected missing-agent-contract-reference \
  GH_ACTION_REFERENCED_WORKFLOW_COUNT_OVERRIDE 0
assert_remote_evidence_rejected duplicate-agent-contract-reference \
  GH_ACTION_REFERENCED_WORKFLOW_COUNT_OVERRIDE 2
assert_remote_evidence_rejected wrong-agent-contract-path \
  GH_ACTION_REFERENCED_WORKFLOW_PATH_OVERRIDE \
  HomericIntelligence/Athena/.github/workflows/another.yml@bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
assert_remote_evidence_rejected wrong-agent-contract-sha \
  GH_ACTION_REFERENCED_WORKFLOW_SHA_OVERRIDE \
  cccccccccccccccccccccccccccccccccccccccc
assert_remote_evidence_rejected stale-run-evidence \
  GH_ACTION_RUN_UPDATED_AT_OVERRIDE 2020-01-01T00:00:00Z
assert_remote_evidence_rejected stale-evidence-observation \
  GH_EVIDENCE_OBSERVED_AT_OVERRIDE 2020-01-01T00:00:00Z
assert_remote_evidence_rejected unresolved-agent-contract-release \
  GH_AGENT_CONTRACT_TAG_LOOKUP_FAILURE true
assert_remote_evidence_rejected branch-only-agent-contract-ref \
  GH_AGENT_CONTRACT_TAG_REF_OVERRIDE refs/heads/agent-contract-v1.0.0
assert_remote_evidence_rejected lightweight-agent-contract-tag \
  GH_AGENT_CONTRACT_TAG_OBJECT_TYPE_OVERRIDE commit
assert_remote_evidence_rejected unsigned-agent-contract-tag \
  GH_AGENT_CONTRACT_TAG_SIGNATURE_OVERRIDE false
assert_remote_evidence_rejected unsigned-agent-contract-commit \
  GH_AGENT_CONTRACT_COMMIT_SIGNATURE_OVERRIDE false
assert_remote_evidence_rejected missing-agent-contract-tag-protection \
  GH_AGENT_CONTRACT_TAG_RULESET_MODE missing
assert_remote_evidence_rejected bypassable-agent-contract-tag-protection \
  GH_AGENT_CONTRACT_TAG_RULESET_MODE bypass
assert_remote_evidence_rejected retargetable-agent-contract-tag-protection \
  GH_AGENT_CONTRACT_TAG_RULESET_MODE retargetable

evaluate_preview="$tmp_dir/evaluate-preview.log"
run_dry_run "$myrmidons_fixture" Myrmidons "$evaluate_preview" --evaluate || {
  cat "$evaluate_preview" >&2
  fail "active baseline evaluate dry-run was rejected"
}
evaluate_drift=$(sed -n 's/^DRIFT Myrmidons: //p' "$evaluate_preview")
evaluate_payload=$(jq -cn --argjson drift "$evaluate_drift" '$drift.ruleset.after')
jq -en --argjson payload "$evaluate_payload" \
  '$payload.enforcement == "evaluate"' >/dev/null || \
  fail "evaluate dry-run did not render the staged candidate"
if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
    "$tmp_dir/gh-calls.log"; then
  fail "evaluate dry-run attempted a live mutation"
fi
echo "PASS: active baseline permits an explicit no-write evaluate preview"

evaluate_recipe=$(just --dry-run repo-rulesets-apply 2>&1)
grep -qF 'apply-repo-rulesets.sh --evaluate --all --dry-run' \
  <<<"$evaluate_recipe" || \
  fail "fleet evaluate recipe is not a no-write preview"
pilot_preview_recipe=$(just --dry-run repo-rulesets-preview Myrmidons 2>&1)
grep -qF 'apply-repo-rulesets.sh --active --repos "Myrmidons" --dry-run' \
  <<<"$pilot_preview_recipe" || \
  fail "pilot preview recipe is not a scoped no-write active preview"
pilot_activate_recipe=$(just --dry-run repo-rulesets-activate-repos \
  Myrmidons evidence.json snapshots 2>&1)
grep -qF 'RULESET_SNAPSHOT_DIR="snapshots"' <<<"$pilot_activate_recipe" || \
  fail "pilot activation recipe does not bind an operator snapshot path"
grep -qF -- '--active --repos "Myrmidons" --evidence-file "evidence.json"' \
  <<<"$pilot_activate_recipe" || \
  fail "pilot activation recipe does not bind its reviewed scope and evidence"
echo "PASS: fleet evaluate entry path is dry-run only"

active_downgrade_state="$tmp_dir/active-downgrade-state.json"
active_downgrade_pre="$tmp_dir/active-downgrade-pre.json"
active_downgrade_snapshots="$tmp_dir/active-downgrade-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$active_downgrade_state"
cp "$active_downgrade_state" "$active_downgrade_pre"
if RULESET_MODE=--evaluate run_live_update \
    "$myrmidons_fixture" Myrmidons "$active_downgrade_state" \
    "$active_downgrade_snapshots" "$tmp_dir/active-downgrade.log" \
    "$tmp_dir/active-downgrade-put-count" \
    "$tmp_dir/active-downgrade-get-count"; then
  fail "updater accepted an active-to-evaluate enforcement downgrade"
fi
jq -e --slurpfile expected "$active_downgrade_pre" '. == $expected[0]' \
  "$active_downgrade_state" >/dev/null || \
  fail "active-to-evaluate refusal changed live state"
[[ ! -s "$tmp_dir/active-downgrade-put-count" ]] || \
  fail "active-to-evaluate refusal issued a PUT"
grep -qF 'refusing active-to-evaluate downgrade' \
  "$tmp_dir/active-downgrade.log" || \
  fail "active-to-evaluate refusal did not explain the safety boundary"
echo "PASS: active enforcement cannot be downgraded to evaluate"

staged_state="$tmp_dir/staged-state.json"
staged_snapshots="$tmp_dir/staged-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$staged_state"
jq '.enforcement = "evaluate"' "$staged_state" >"$staged_state.tmp"
mv "$staged_state.tmp" "$staged_state"
if ! RULESET_MODE=--evaluate run_live_update \
    "$myrmidons_fixture" Myrmidons "$staged_state" "$staged_snapshots" \
    "$tmp_dir/staged.log" "$tmp_dir/staged-put-count" \
    "$tmp_dir/staged-get-count"; then
  cat "$tmp_dir/staged.log" >&2
  fail "explicit staged evaluate update was rejected"
fi
jq -e '.enforcement == "evaluate"' "$staged_state" >/dev/null || \
  fail "staged evaluate update changed enforcement unexpectedly"
echo "PASS: an already staged evaluate baseline remains explicitly updateable"

success_state="$tmp_dir/success-state.json"
success_pre="$tmp_dir/success-pre.json"
success_snapshots="$tmp_dir/success-snapshots"
success_settings="$tmp_dir/success-settings.json"
success_settings_count="$tmp_dir/success-settings-count"
seed_ruleset_state "$myrmidons_fixture" "$success_state"
cp "$success_state" "$success_pre"
JQ_FULL_NAME=HomericIntelligence/Myrmidons
jq -n --arg full_name "$JQ_FULL_NAME" '{
  full_name: $full_name,
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$success_settings"
if ! GH_REPOSITORY_STATE="$success_settings" \
    GH_SETTINGS_PATCH_COUNT_FILE="$success_settings_count" run_live_update \
    "$myrmidons_fixture" Myrmidons "$success_state" "$success_snapshots" \
    "$tmp_dir/success.log" "$tmp_dir/success-put-count" \
    "$tmp_dir/success-get-count"; then
  cat "$tmp_dir/success.log" >&2
  fail "verified live update scenario failed"
fi
assert_durable_snapshot "$success_snapshots" "$success_pre" "verified update"
[[ $(<"$tmp_dir/success-put-count") -eq 1 ]] || \
  fail "verified update must issue exactly one PUT"
[[ $(<"$tmp_dir/success-get-count") -eq 5 ]] || \
  fail "verified update must revalidate pre-state and both exact postconditions"
jq -e '
  .conditions.ref_name == {include: ["~DEFAULT_BRANCH"], exclude: []}
  and .bypass_actors == []
  and ([.rules[] | select(.type == "merge_queue")] | length) == 1
  and ([.rules[] | select(.type == "required_status_checks")
    | .parameters.required_status_checks[].context]) == ["required-checks-gate"]
' "$success_state" >/dev/null || fail "verified update state does not match the candidate"
grep -qF "Verified exact postcondition" "$tmp_dir/success.log" || \
  fail "verified update did not report exact postcondition verification"
jq -e --slurpfile policy configs/github/fleet-ruleset-policy.json '
  {
    allow_auto_merge,
    allow_merge_commit,
    allow_rebase_merge,
    allow_squash_merge,
    allow_update_branch,
    delete_branch_on_merge,
    web_commit_signoff_required
  } == $policy[0].repository_settings
' "$success_settings" >/dev/null || \
  fail "verified update did not reconcile repository settings"
[[ $(<"$success_settings_count") -eq 1 ]] || \
  fail "verified update must issue exactly one repository PATCH"
echo "PASS: live update snapshots pre-state and verifies exact post-state"

classic_success_ruleset="$tmp_dir/classic-success-ruleset.json"
classic_success_state="$tmp_dir/classic-success-state.json"
classic_success_pre="$tmp_dir/classic-success-pre.json"
classic_success_snapshots="$tmp_dir/classic-success-snapshots"
classic_success_count="$tmp_dir/classic-success-count"
seed_ruleset_state "$myrmidons_fixture" "$classic_success_ruleset"
write_classic_protection_fixture "$classic_success_state"
cp "$classic_success_state" "$classic_success_pre"
if ! GH_CLASSIC_PROTECTION_STATE="$classic_success_state" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_success_count" run_live_update \
      "$myrmidons_fixture" Myrmidons "$classic_success_ruleset" \
      "$classic_success_snapshots" "$tmp_dir/classic-success.log" \
      "$tmp_dir/classic-success-put-count" \
      "$tmp_dir/classic-success-get-count"; then
  cat "$tmp_dir/classic-success.log" >&2
  fail "verified classic-protection migration failed"
fi
jq -e '. == null' "$classic_success_state" >/dev/null || \
  fail "classic protection remained after a verified migration"
[[ $(<"$classic_success_count") -eq 1 ]] || \
  fail "classic migration did not issue exactly one DELETE"
assert_durable_snapshot "$classic_success_snapshots" \
  "$classic_success_pre" "classic migration" 4
ruleset_put_line=$(grep -n -m1 \
  'PUT repos/HomericIntelligence/Myrmidons/rulesets/' \
  "$tmp_dir/gh-calls.log" | cut -d: -f1)
classic_delete_line=$(grep -n -m1 \
  'DELETE repos/HomericIntelligence/Myrmidons/branches/main/protection' \
  "$tmp_dir/gh-calls.log" | cut -d: -f1)
[[ -n "$ruleset_put_line" && -n "$classic_delete_line" &&
  "$ruleset_put_line" -lt "$classic_delete_line" ]] || \
  fail "classic protection was removed before the equivalent ruleset write"
grep -qF 'Verified exact postcondition' "$tmp_dir/classic-success.log" || \
  fail "classic migration did not report exact final verification"
echo "PASS: classic protection is snapshotted and removed only after active ruleset readback"

classic_stale_effective_ruleset="$tmp_dir/classic-stale-effective-ruleset.json"
classic_stale_effective_ruleset_pre="$tmp_dir/classic-stale-effective-ruleset-pre.json"
classic_stale_effective_state="$tmp_dir/classic-stale-effective-state.json"
classic_stale_effective_state_pre="$tmp_dir/classic-stale-effective-state-pre.json"
classic_stale_effective_count="$tmp_dir/classic-stale-effective-count"
seed_ruleset_state "$myrmidons_fixture" "$classic_stale_effective_ruleset"
cp "$classic_stale_effective_ruleset" "$classic_stale_effective_ruleset_pre"
write_classic_protection_fixture "$classic_stale_effective_state"
cp "$classic_stale_effective_state" "$classic_stale_effective_state_pre"
if GH_CLASSIC_PROTECTION_STATE="$classic_stale_effective_state" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_stale_effective_count" \
    GH_EFFECTIVE_PARAMETER_MISMATCH_AT=3 run_live_update \
      "$myrmidons_fixture" Myrmidons "$classic_stale_effective_ruleset" \
      "$tmp_dir/classic-stale-effective-snapshots" \
      "$tmp_dir/classic-stale-effective.log" \
      "$tmp_dir/classic-stale-effective-put-count" \
      "$tmp_dir/classic-stale-effective-get-count"; then
  fail "classic migration accepted stale effective rules before deletion"
fi
jq -e --slurpfile expected "$classic_stale_effective_ruleset_pre" \
  '. == $expected[0]' "$classic_stale_effective_ruleset" >/dev/null ||
  fail "stale effective-rule refusal did not restore the ruleset"
jq -e --slurpfile expected "$classic_stale_effective_state_pre" \
  '. == $expected[0]' "$classic_stale_effective_state" >/dev/null ||
  fail "stale effective-rule refusal changed classic protection"
[[ ! -s "$classic_stale_effective_count" ||
  $(<"$classic_stale_effective_count") -eq 0 ]] ||
  fail "stale effective-rule refusal reached classic-protection DELETE"
grep -qF 'effective active rules were not exact immediately before classic-protection removal' \
  "$tmp_dir/classic-stale-effective.log" ||
  fail "stale effective-rule refusal did not identify the cutover invariant"
echo "PASS: classic deletion requires exact effective active rules at the cutover boundary"

classic_concurrent_ruleset="$tmp_dir/classic-concurrent-ruleset.json"
classic_concurrent_ruleset_pre="$tmp_dir/classic-concurrent-ruleset-pre.json"
classic_concurrent_state="$tmp_dir/classic-concurrent-state.json"
classic_concurrent_settings="$tmp_dir/classic-concurrent-settings.json"
classic_concurrent_count="$tmp_dir/classic-concurrent-count"
classic_concurrent_settings_count="$tmp_dir/classic-concurrent-settings-count"
seed_ruleset_state "$myrmidons_fixture" "$classic_concurrent_ruleset"
cp "$classic_concurrent_ruleset" "$classic_concurrent_ruleset_pre"
write_classic_protection_fixture "$classic_concurrent_state"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$classic_concurrent_settings"
if GH_CLASSIC_PROTECTION_STATE="$classic_concurrent_state" \
    GH_REPOSITORY_STATE="$classic_concurrent_settings" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_concurrent_count" \
    GH_SETTINGS_PATCH_COUNT_FILE="$classic_concurrent_settings_count" \
    GH_CONCURRENT_CLASSIC_CONTENT_CHANGE_AT=3 run_live_update \
      "$myrmidons_fixture" Myrmidons "$classic_concurrent_ruleset" \
      "$tmp_dir/classic-concurrent-snapshots" \
      "$tmp_dir/classic-concurrent.log" \
      "$tmp_dir/classic-concurrent-put-count" \
      "$tmp_dir/classic-concurrent-get-count"; then
  fail "classic-protection mutation after JIT inventory was overwritten"
fi
jq -e '.required_status_checks.strict == false' \
  "$classic_concurrent_state" >/dev/null || \
  fail "concurrent classic-protection content was not preserved"
[[ ! -s "$classic_concurrent_count" ]] || \
  fail "concurrent classic-protection content was destructively deleted"
jq -e --slurpfile expected "$classic_concurrent_ruleset_pre" \
  '. == $expected[0]' "$classic_concurrent_ruleset" >/dev/null || \
  fail "classic concurrent-change abort did not roll back the ruleset write"
[[ $(<"$classic_concurrent_settings_count") -eq 2 ]] || \
  fail "classic concurrent-change abort did not roll back repository settings"
grep -qF 'classic protection changed after the just-in-time precondition' \
  "$tmp_dir/classic-concurrent.log" || \
  fail "classic concurrent-change abort did not identify the changed resource"
echo "PASS: immediate pre-delete classic fingerprint preserves concurrent policy"

classic_disappear_ruleset="$tmp_dir/classic-disappear-ruleset.json"
classic_disappear_ruleset_pre="$tmp_dir/classic-disappear-ruleset-pre.json"
classic_disappear_state="$tmp_dir/classic-disappear-state.json"
classic_disappear_settings="$tmp_dir/classic-disappear-settings.json"
classic_disappear_count="$tmp_dir/classic-disappear-count"
classic_disappear_settings_count="$tmp_dir/classic-disappear-settings-count"
seed_ruleset_state "$myrmidons_fixture" "$classic_disappear_ruleset"
cp "$classic_disappear_ruleset" "$classic_disappear_ruleset_pre"
write_classic_protection_fixture "$classic_disappear_state"
cp "$classic_concurrent_settings" "$classic_disappear_settings"
if GH_CLASSIC_PROTECTION_STATE="$classic_disappear_state" \
    GH_REPOSITORY_STATE="$classic_disappear_settings" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_disappear_count" \
    GH_SETTINGS_PATCH_COUNT_FILE="$classic_disappear_settings_count" \
    GH_CONCURRENT_CLASSIC_DISAPPEAR_AT=3 run_live_update \
      "$myrmidons_fixture" Myrmidons "$classic_disappear_ruleset" \
      "$tmp_dir/classic-disappear-snapshots" \
      "$tmp_dir/classic-disappear.log" \
      "$tmp_dir/classic-disappear-put-count" \
      "$tmp_dir/classic-disappear-get-count"; then
  fail "concurrent classic-protection removal was overwritten"
fi
jq -e '. == null' "$classic_disappear_state" >/dev/null ||
  fail "concurrent classic-protection absence was not preserved"
[[ ! -s "$classic_disappear_count" ]] ||
  fail "pre-delete disappearance triggered a classic-protection restore"
jq -e --slurpfile expected "$classic_disappear_ruleset_pre" \
  '. == $expected[0]' "$classic_disappear_ruleset" >/dev/null ||
  fail "classic disappearance abort did not restore the earlier ruleset write"
[[ $(<"$classic_disappear_settings_count") -eq 2 ]] ||
  fail "classic disappearance abort did not restore repository settings once"
echo "PASS: pre-delete classic disappearance is preserved as concurrent state"

classic_ambiguous_ruleset="$tmp_dir/classic-ambiguous-ruleset.json"
classic_ambiguous_ruleset_pre="$tmp_dir/classic-ambiguous-ruleset-pre.json"
classic_ambiguous_state="$tmp_dir/classic-ambiguous-state.json"
classic_ambiguous_pre="$tmp_dir/classic-ambiguous-pre.json"
classic_ambiguous_count="$tmp_dir/classic-ambiguous-count"
seed_ruleset_state "$myrmidons_fixture" "$classic_ambiguous_ruleset"
cp "$classic_ambiguous_ruleset" "$classic_ambiguous_ruleset_pre"
write_classic_protection_fixture "$classic_ambiguous_state"
cp "$classic_ambiguous_state" "$classic_ambiguous_pre"
if GH_CLASSIC_PROTECTION_STATE="$classic_ambiguous_state" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_ambiguous_count" \
    GH_FAIL_CLASSIC_DELETE_AFTER_WRITE_AT=1 run_live_update \
      "$myrmidons_fixture" Myrmidons "$classic_ambiguous_ruleset" \
      "$tmp_dir/classic-ambiguous-snapshots" \
      "$tmp_dir/classic-ambiguous.log" \
      "$tmp_dir/classic-ambiguous-put-count" \
      "$tmp_dir/classic-ambiguous-get-count"; then
  fail "ambiguous classic-protection deletion was accepted"
fi
jq -e --slurpfile expected "$classic_ambiguous_pre" '
  def normalized_any_app:
    .required_status_checks.checks |= map(
      if .app_id == null then .app_id = -1 else . end
    );
  normalized_any_app == ($expected[0] | normalized_any_app)
' \
  "$classic_ambiguous_state" >/dev/null || {
  jq -n --slurpfile actual "$classic_ambiguous_state" \
    --slurpfile expected "$classic_ambiguous_pre" \
    '{actual: $actual[0], expected: $expected[0]}' >&2
  cat "$tmp_dir/classic-ambiguous.log" >&2
  fail "ambiguous classic deletion did not restore exact protection and signatures"
}
jq -e --slurpfile expected "$classic_ambiguous_ruleset_pre" '. == $expected[0]' \
  "$classic_ambiguous_ruleset" >/dev/null || \
  fail "ambiguous classic deletion did not restore the ruleset pre-state"
[[ $(<"$classic_ambiguous_count") -eq 2 ]] || \
  fail "ambiguous classic deletion did not issue one DELETE and one restore PUT"
[[ $(<"$tmp_dir/classic-ambiguous-put-count") -eq 2 ]] || \
  fail "ambiguous classic deletion did not roll back the ruleset write"
grep -qF 'Fleet rollback verified exactly' \
  "$tmp_dir/classic-ambiguous.log" || \
  fail "ambiguous classic deletion did not report verified fleet rollback"
echo "PASS: ambiguous classic deletion restores protection, signatures, settings, and ruleset"

assert_classic_rollback_after_write_classified() {
  local name=$1
  local variable=$2
  local value=$3
  local ruleset_state="$tmp_dir/$name-ruleset.json"
  local ruleset_pre="$tmp_dir/$name-ruleset-pre.json"
  local classic_state="$tmp_dir/$name-classic.json"
  local classic_pre="$tmp_dir/$name-classic-pre.json"
  local classic_count="$tmp_dir/$name-classic-count"
  local signature_count="$tmp_dir/$name-signature-count"

  seed_ruleset_state "$myrmidons_fixture" "$ruleset_state"
  cp "$ruleset_state" "$ruleset_pre"
  write_classic_protection_fixture "$classic_state"
  cp "$classic_state" "$classic_pre"
  export "$variable=$value"
  if GH_CLASSIC_PROTECTION_STATE="$classic_state" \
      GH_CLASSIC_MUTATION_COUNT_FILE="$classic_count" \
      GH_CLASSIC_SIGNATURE_COUNT_FILE="$signature_count" \
      GH_FAIL_CLASSIC_DELETE_AFTER_WRITE_AT=1 run_live_update \
        "$myrmidons_fixture" Myrmidons "$ruleset_state" \
        "$tmp_dir/$name-snapshots" "$tmp_dir/$name.log" \
        "$tmp_dir/$name-put-count" "$tmp_dir/$name-get-count"; then
    unset "$variable"
    fail "$name was accepted"
  fi
  unset "$variable"

  jq -e --slurpfile expected "$classic_pre" '
    def normalized_any_app:
      .required_status_checks.checks |= map(
        if .app_id == null then .app_id = -1 else . end
      );
    normalized_any_app == ($expected[0] | normalized_any_app)
  ' "$classic_state" >/dev/null || \
    fail "$name did not restore exact classic protection"
  jq -e --slurpfile expected "$ruleset_pre" '. == $expected[0]' \
    "$ruleset_state" >/dev/null || fail "$name did not restore the ruleset"
  [[ $(<"$classic_count") -eq 2 ]] || \
    fail "$name issued an unsafe number of classic-protection writes"
  [[ $(<"$signature_count") -eq 1 ]] || \
    fail "$name issued an unsafe number of signature writes"
  grep -qF 'Fleet rollback verified exactly' "$tmp_dir/$name.log" || \
    fail "$name did not report exact rollback verification"
  echo "PASS: $name verifies exact pre-state after an ambiguous rollback write"
}

assert_classic_rollback_after_write_classified \
  classic-restore-put-after-write GH_FAIL_CLASSIC_PUT_AFTER_WRITE_AT 2
assert_classic_rollback_after_write_classified \
  classic-signature-post-after-write \
  GH_FAIL_CLASSIC_SIGNATURE_POST_AFTER_WRITE_AT 1

classic_restore_before_ruleset="$tmp_dir/classic-restore-before-ruleset.json"
classic_restore_before_ruleset_pre="$tmp_dir/classic-restore-before-ruleset-pre.json"
classic_restore_before_state="$tmp_dir/classic-restore-before-state.json"
classic_restore_before_count="$tmp_dir/classic-restore-before-count"
seed_ruleset_state "$myrmidons_fixture" "$classic_restore_before_ruleset"
cp "$classic_restore_before_ruleset" "$classic_restore_before_ruleset_pre"
write_classic_protection_fixture "$classic_restore_before_state"
if GH_CLASSIC_PROTECTION_STATE="$classic_restore_before_state" \
    GH_CLASSIC_MUTATION_COUNT_FILE="$classic_restore_before_count" \
    GH_FAIL_CLASSIC_DELETE_AFTER_WRITE_AT=1 \
    GH_FAIL_CLASSIC_PUT_BEFORE_WRITE_AT=2 run_live_update \
      "$myrmidons_fixture" Myrmidons "$classic_restore_before_ruleset" \
      "$tmp_dir/classic-restore-before-snapshots" \
      "$tmp_dir/classic-restore-before.log" \
      "$tmp_dir/classic-restore-before-put-count" \
      "$tmp_dir/classic-restore-before-get-count"; then
  fail "classic rollback failure-before-write was accepted"
fi
jq -e '. == null' "$classic_restore_before_state" >/dev/null || \
  fail "classic rollback failure-before-write overwrote an unclassified state"
jq -e --slurpfile expected "$classic_restore_before_ruleset_pre" \
  '. == $expected[0]' "$classic_restore_before_ruleset" >/dev/null || \
  fail "classic rollback failure-before-write did not restore the ruleset"
[[ $(<"$classic_restore_before_count") -eq 2 ]] || \
  fail "classic rollback failure-before-write retried an ambiguous PUT"
grep -qF 'UNCERTAIN MUTATION' "$tmp_dir/classic-restore-before.log" || \
  fail "classic rollback failure-before-write did not report uncertainty"
echo "PASS: classic rollback failure-before-write is classified without retry"

assert_settings_failure_rolls_back() {
  local name=$1
  local variable=$2
  local value=$3
  local expected_settings_writes=${4:-2}
  local state_file="$tmp_dir/$name-ruleset-state.json"
  local state_pre="$tmp_dir/$name-ruleset-pre.json"
  local settings_file="$tmp_dir/$name-settings-state.json"
  local settings_pre="$tmp_dir/$name-settings-pre.json"
  local settings_count="$tmp_dir/$name-settings-count"
  local put_count="$tmp_dir/$name-put-count"
  local accepted=false

  seed_ruleset_state "$myrmidons_fixture" "$state_file"
  cp "$state_file" "$state_pre"
  jq -n '{
    full_name: "HomericIntelligence/Myrmidons",
    default_branch: "main",
    allow_auto_merge: false,
    allow_merge_commit: true,
    allow_rebase_merge: true,
    allow_squash_merge: true,
    allow_update_branch: false,
    delete_branch_on_merge: false,
    web_commit_signoff_required: false
  }' >"$settings_file"
  cp "$settings_file" "$settings_pre"
  export "$variable=$value"
  if GH_REPOSITORY_STATE="$settings_file" \
      GH_SETTINGS_PATCH_COUNT_FILE="$settings_count" run_live_update \
        "$myrmidons_fixture" Myrmidons "$state_file" \
        "$tmp_dir/$name-snapshots" "$tmp_dir/$name.log" "$put_count" \
        "$tmp_dir/$name-get-count"; then
    accepted=true
  fi
  unset "$variable"

  [[ "$accepted" == false ]] || fail "$name was accepted"
  jq -e --slurpfile expected "$state_pre" '. == $expected[0]' \
    "$state_file" >/dev/null || fail "$name did not restore the ruleset"
  jq -e --slurpfile expected "$settings_pre" '. == $expected[0]' \
    "$settings_file" >/dev/null || fail "$name did not restore repository settings"
  [[ $(<"$settings_count") -eq "$expected_settings_writes" ]] || \
    fail "$name issued an unsafe number of repository PATCH requests"
  [[ $(<"$put_count") -eq 2 ]] || \
    fail "$name must issue one forward and one rollback ruleset PUT"
  grep -qF 'Fleet rollback verified exactly' "$tmp_dir/$name.log" || \
    fail "$name did not report verified rollback"
  echo "PASS: $name restores and verifies repository settings and ruleset"
}

assert_settings_failure_rolls_back ambiguous-settings-write \
  GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT 1
assert_settings_failure_rolls_back ambiguous-settings-rollback-after-write \
  GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT 1,2
assert_settings_failure_rolls_back settings-write-failed-before-mutation \
  GH_FAIL_SETTINGS_PATCH_BEFORE_WRITE_AT 1 1

settings_rollback_before_ruleset="$tmp_dir/settings-rollback-before-ruleset.json"
settings_rollback_before_ruleset_pre="$tmp_dir/settings-rollback-before-ruleset-pre.json"
settings_rollback_before_state="$tmp_dir/settings-rollback-before-state.json"
settings_rollback_before_count="$tmp_dir/settings-rollback-before-count"
seed_ruleset_state "$myrmidons_fixture" "$settings_rollback_before_ruleset"
cp "$settings_rollback_before_ruleset" "$settings_rollback_before_ruleset_pre"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$settings_rollback_before_state"
if GH_REPOSITORY_STATE="$settings_rollback_before_state" \
    GH_SETTINGS_PATCH_COUNT_FILE="$settings_rollback_before_count" \
    GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT=1 \
    GH_FAIL_SETTINGS_PATCH_BEFORE_WRITE_AT=2 run_live_update \
      "$myrmidons_fixture" Myrmidons "$settings_rollback_before_ruleset" \
      "$tmp_dir/settings-rollback-before-snapshots" \
      "$tmp_dir/settings-rollback-before.log" \
      "$tmp_dir/settings-rollback-before-put-count" \
      "$tmp_dir/settings-rollback-before-get-count"; then
  fail "settings rollback failure-before-write was accepted"
fi
jq -e --slurpfile policy configs/github/fleet-ruleset-policy.json '
  {
    allow_auto_merge,
    allow_merge_commit,
    allow_rebase_merge,
    allow_squash_merge,
    allow_update_branch,
    delete_branch_on_merge,
    web_commit_signoff_required
  } == $policy[0].repository_settings
' "$settings_rollback_before_state" >/dev/null || \
  fail "settings rollback failure-before-write did not preserve the classified desired state"
jq -e --slurpfile expected "$settings_rollback_before_ruleset_pre" \
  '. == $expected[0]' "$settings_rollback_before_ruleset" >/dev/null || \
  fail "settings rollback failure-before-write did not restore the ruleset"
[[ $(<"$settings_rollback_before_count") -eq 2 ]] || \
  fail "settings rollback failure-before-write retried an ambiguous PATCH"
grep -qF 'UNCERTAIN MUTATION' "$tmp_dir/settings-rollback-before.log" || \
  fail "settings rollback failure-before-write did not report uncertainty"
echo "PASS: settings rollback failure-before-write is classified without retry"

settings_concurrent_ruleset="$tmp_dir/settings-concurrent-ruleset.json"
settings_concurrent_ruleset_pre="$tmp_dir/settings-concurrent-ruleset-pre.json"
settings_concurrent_state="$tmp_dir/settings-concurrent-state.json"
settings_concurrent_state_pre="$tmp_dir/settings-concurrent-state-pre.json"
seed_ruleset_state "$myrmidons_fixture" "$settings_concurrent_ruleset"
cp "$settings_concurrent_ruleset" "$settings_concurrent_ruleset_pre"
jq -n '{
  full_name: "HomericIntelligence/Myrmidons",
  default_branch: "main",
  allow_auto_merge: false,
  allow_merge_commit: true,
  allow_rebase_merge: true,
  allow_squash_merge: true,
  allow_update_branch: false,
  delete_branch_on_merge: false,
  web_commit_signoff_required: false
}' >"$settings_concurrent_state"
cp "$settings_concurrent_state" "$settings_concurrent_state_pre"
if GH_REPOSITORY_STATE="$settings_concurrent_state" \
    GH_SETTINGS_PATCH_COUNT_FILE="$tmp_dir/settings-concurrent-count" \
    GH_CORRUPT_SETTINGS_PATCH_AT=1 run_live_update \
      "$myrmidons_fixture" Myrmidons "$settings_concurrent_ruleset" \
      "$tmp_dir/settings-concurrent-snapshots" \
      "$tmp_dir/settings-concurrent.log" \
      "$tmp_dir/settings-concurrent-put-count" \
      "$tmp_dir/settings-concurrent-get-count"; then
  fail "settings readback accepted an unrecognized concurrent state"
fi
jq -e --slurpfile expected "$settings_concurrent_ruleset_pre" \
  '. == $expected[0]' "$settings_concurrent_ruleset" >/dev/null || \
  fail "settings uncertainty did not restore the independently verified ruleset write"
jq -e --slurpfile before "$settings_concurrent_state_pre" \
  --slurpfile policy configs/github/fleet-ruleset-policy.json '
    . != $before[0]
    and ({
      allow_auto_merge,
      allow_merge_commit,
      allow_rebase_merge,
      allow_squash_merge,
      allow_update_branch,
      delete_branch_on_merge,
      web_commit_signoff_required
    } != $policy[0].repository_settings)
  ' "$settings_concurrent_state" >/dev/null || \
  fail "settings uncertainty did not preserve the unrecognized third state"
[[ $(<"$tmp_dir/settings-concurrent-count") -eq 1 ]] || \
  fail "settings uncertainty overwrote the unrecognized third state"
[[ $(<"$tmp_dir/settings-concurrent-put-count") -eq 2 ]] || \
  fail "settings uncertainty did not roll back the verified ruleset write"
grep -qF 'UNCERTAIN MUTATION' "$tmp_dir/settings-concurrent.log" || \
  fail "settings third state did not report uncertainty"
echo "PASS: unrecognized settings state is preserved while verified ruleset write rolls back"

mismatch_state="$tmp_dir/mismatch-state.json"
mismatch_pre="$tmp_dir/mismatch-pre.json"
mismatch_snapshots="$tmp_dir/mismatch-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$mismatch_state"
cp "$mismatch_state" "$mismatch_pre"
if GH_CORRUPT_PUT_AT=1 run_live_update \
    "$myrmidons_fixture" Myrmidons "$mismatch_state" "$mismatch_snapshots" \
    "$tmp_dir/mismatch.log" "$tmp_dir/mismatch-put-count" \
    "$tmp_dir/mismatch-get-count"; then
  fail "updater accepted a mismatched post-PUT readback"
fi
assert_durable_snapshot "$mismatch_snapshots" "$mismatch_pre" "mismatch recovery"
jq -e '.conditions.ref_name.include == ["refs/heads/not-main"]' \
  "$mismatch_state" >/dev/null || \
  fail "mismatched third state was overwritten during recovery"
[[ $(<"$tmp_dir/mismatch-put-count") -eq 1 ]] || \
  fail "mismatched third state triggered an unsafe rollback PUT"
grep -qF "UNCERTAIN MUTATION" "$tmp_dir/mismatch.log" || \
  fail "mismatched third state did not report uncertainty"
echo "PASS: mismatched third state is preserved for operator recovery"

ambiguous_state="$tmp_dir/ambiguous-state.json"
ambiguous_pre="$tmp_dir/ambiguous-pre.json"
ambiguous_snapshots="$tmp_dir/ambiguous-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$ambiguous_state"
cp "$ambiguous_state" "$ambiguous_pre"
if GH_FAIL_PUT_AFTER_WRITE_AT=1 run_live_update \
    "$myrmidons_fixture" Myrmidons "$ambiguous_state" "$ambiguous_snapshots" \
    "$tmp_dir/ambiguous.log" "$tmp_dir/ambiguous-put-count" \
    "$tmp_dir/ambiguous-get-count"; then
  fail "updater accepted an ambiguous PUT result"
fi
assert_durable_snapshot "$ambiguous_snapshots" "$ambiguous_pre" "ambiguous rollback"
jq -e --slurpfile expected "$ambiguous_pre" '. == $expected[0]' \
  "$ambiguous_state" >/dev/null || fail "ambiguous PUT was not rolled back"
[[ $(<"$tmp_dir/ambiguous-put-count") -eq 2 ]] || \
  fail "ambiguous PUT must trigger one rollback PUT"
[[ $(<"$tmp_dir/ambiguous-get-count") -eq 4 ]] || \
  fail "ambiguous PUT must be classified before rollback and verified afterward"
grep -qF "Rollback verified" "$tmp_dir/ambiguous.log" || \
  fail "ambiguous PUT rollback was not reported as verified"
echo "PASS: ambiguous PUT failure triggers verified rollback"

prewrite_state="$tmp_dir/prewrite-state.json"
prewrite_pre="$tmp_dir/prewrite-pre.json"
prewrite_snapshots="$tmp_dir/prewrite-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$prewrite_state"
cp "$prewrite_state" "$prewrite_pre"
if GH_FAIL_PUT_BEFORE_WRITE_AT=1 run_live_update \
    "$myrmidons_fixture" Myrmidons "$prewrite_state" "$prewrite_snapshots" \
    "$tmp_dir/prewrite.log" "$tmp_dir/prewrite-put-count" \
    "$tmp_dir/prewrite-get-count"; then
  fail "updater accepted a ruleset PUT failure before mutation"
fi
jq -e --slurpfile expected "$prewrite_pre" '. == $expected[0]' \
  "$prewrite_state" >/dev/null || fail "pre-write failure changed live state"
[[ $(<"$tmp_dir/prewrite-put-count") -eq 1 ]] || \
  fail "pre-write failure issued an unnecessary rollback PUT"
grep -qF "pre-state was already intact" "$tmp_dir/prewrite.log" || \
  fail "pre-write failure did not verify the unchanged pre-state"
echo "PASS: failed-before-write ruleset mutation verifies pre-state without rewriting"

readback_state="$tmp_dir/readback-state.json"
readback_pre="$tmp_dir/readback-pre.json"
readback_snapshots="$tmp_dir/readback-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$readback_state"
cp "$readback_state" "$readback_pre"
if GH_FAIL_DETAIL_GET_AT=3 run_live_update \
    "$myrmidons_fixture" Myrmidons "$readback_state" "$readback_snapshots" \
    "$tmp_dir/readback.log" "$tmp_dir/readback-put-count" \
    "$tmp_dir/readback-get-count"; then
  fail "updater accepted a failed post-PUT readback"
fi
assert_durable_snapshot "$readback_snapshots" "$readback_pre" "readback rollback"
jq -e --slurpfile expected "$readback_pre" '. == $expected[0]' \
  "$readback_state" >/dev/null || fail "failed post-PUT readback was not rolled back"
[[ $(<"$tmp_dir/readback-put-count") -eq 2 ]] || \
  fail "failed post-PUT readback must trigger one rollback PUT"
[[ $(<"$tmp_dir/readback-get-count") -eq 5 ]] || \
  fail "readback failure must be classified and rollback verified by another GET"
echo "PASS: failed post-PUT readback triggers verified rollback"

hup_state="$tmp_dir/hup-state.json"
hup_pre="$tmp_dir/hup-pre.json"
hup_snapshots="$tmp_dir/hup-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$hup_state"
cp "$hup_state" "$hup_pre"
if GH_SIGNAL_HUP_DETAIL_GET_AT=4 run_live_update \
    "$myrmidons_fixture" Myrmidons,Proteus "$hup_state" "$hup_snapshots" \
    "$tmp_dir/hup.log" "$tmp_dir/hup-put-count" \
    "$tmp_dir/hup-get-count"; then
  fail "updater accepted HUP during ambiguous post-PUT readback"
fi
if [[ ! -d "$hup_snapshots" ]] ||
    ! find "$hup_snapshots" -type f -name '*.json' | grep -q .; then
  cat "$tmp_dir/hup.log" >&2
fi
assert_durable_snapshot "$hup_snapshots" "$hup_pre" "HUP rollback" 6
jq -e --slurpfile expected "$hup_pre" '. == $expected[0]' \
  "$hup_state" >/dev/null || fail "HUP left live state unverified"
[[ $(<"$tmp_dir/hup-put-count") -eq 2 ]] || \
  fail "HUP must trigger exactly one rollback PUT"
[[ $(<"$tmp_dir/hup-get-count") -eq 6 ]] || \
  fail "HUP rollback must be verified by an exact readback"
grep -qF 'UNCERTAIN MUTATION: received HUP during an armed mutation' \
  "$tmp_dir/hup.log" || {
  cat "$tmp_dir/hup.log" >&2
  fail "HUP ambiguity did not report uncertain mutation"
}
grep -qF 'Rollback verified exactly' "$tmp_dir/hup.log" || \
  fail "HUP rollback was not reported as verified"
if grep -Eq -- '(-X|--method) PUT repos/HomericIntelligence/Proteus/rulesets' \
    "$tmp_dir/gh-calls.log"; then
  fail "fleet mutation continued after HUP"
fi
echo "PASS: HUP ambiguity reports uncertainty and restores verified pre-state"

uncertain_state="$tmp_dir/uncertain-state.json"
uncertain_snapshots="$tmp_dir/uncertain-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$uncertain_state"
if GH_CORRUPT_PUT_AT=1 GH_FAIL_PUT_BEFORE_WRITE_AT=2 run_live_update \
    "$myrmidons_fixture" Myrmidons,Proteus "$uncertain_state" \
    "$uncertain_snapshots" "$tmp_dir/uncertain.log" \
    "$tmp_dir/uncertain-put-count" "$tmp_dir/uncertain-get-count"; then
  fail "updater accepted an unverified rollback"
fi
grep -qF "UNCERTAIN MUTATION" "$tmp_dir/uncertain.log" || {
  cat "$tmp_dir/uncertain.log" >&2
  fail "unverified rollback did not report uncertain mutation"
}
if grep -Eq -- '(-X|--method) PUT repos/HomericIntelligence/Proteus/rulesets' \
    "$tmp_dir/gh-calls.log"; then
  cat "$tmp_dir/gh-calls.log" >&2
  fail "fleet mutation continued after an uncertain mutation"
fi
echo "PASS: uncertain rollback aborts fleet processing"

: >"$tmp_dir/gh-calls.log"
if PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE=tests/fixtures/github/myrmidons-ruleset-contract.json \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    GH_REPO_LIST=$'Argus\nMyrmidons' \
    tools/github/apply-repo-rulesets.sh --active --all --dry-run \
      >"$tmp_dir/all-active.log" 2>&1; then
  fail "fleet operation accepted an incomplete organization inventory"
fi
grep -qF "active first-party inventory differs from Odysseus plus .gitmodules" \
  "$tmp_dir/all-active.log" || fail "fleet inventory refusal was not explicit"
if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
    "$tmp_dir/gh-calls.log"; then
  fail "inventory mismatch attempted a live mutation"
fi
echo "PASS: fleet operations fail closed unless organization inventory is exact"
