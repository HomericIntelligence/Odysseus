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

fail() {
  echo "FAIL: $*" >&2
  exit 1
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

assert_fixture_contract() {
  local fixture=$1
  local repo=$2
  local expected_count=$3
  local output_file="$tmp_dir/$repo-output.log"

  run_dry_run "$fixture" "$repo" "$output_file" || {
    cat "$output_file" >&2
    fail "$repo dry-run failed"
  }

  local payload
  payload=$(sed -n "s/^DRY-RUN $repo payload: //p" "$output_file")
  [[ -n "$payload" ]] || fail "$repo dry-run did not emit an update payload"

  local expected_contexts actual_contexts
  expected_contexts=$(jq -Sc '.expected_context_union | sort' "$fixture")
  actual_contexts=$(jq -nSc \
    --argjson payload "$payload" \
    --slurpfile fixture "$fixture" '
      ([
        $payload.rules[]
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[].context
      ] + [
        $fixture[0].rulesets[]
        | select(.name != "homeric-main-baseline")
        | .rules[]
        | select(.type == "required_status_checks")
        | .parameters.required_status_checks[].context
      ]) | sort
    ')

  [[ "$actual_contexts" == "$expected_contexts" ]] || {
    printf 'Expected: %s\nActual:   %s\n' \
      "$expected_contexts" "$actual_contexts" >&2
    fail "$repo exact context union changed"
  }

  [[ $(jq 'length' <<<"$actual_contexts") -eq "$expected_count" ]] || \
    fail "$repo context union is not exactly $expected_count entries"

  jq -e --argjson payload "$payload" '
    def unrelated:
      {
        name,
        target,
        conditions,
        bypass_actors,
        rules: [.rules[] | select(.type != "merge_queue")]
      };
    (.rulesets[] | select(.name == "homeric-main-baseline") | unrelated)
      == ($payload | unrelated)
  ' "$fixture" >/dev/null || fail "$repo unrelated baseline policy changed"

  jq -ne --argjson payload "$payload" '
    [$payload.rules[] | select(.type == "merge_queue") | .parameters] == [{
      "check_response_timeout_minutes": 60,
      "grouping_strategy": "ALLGREEN",
      "max_entries_to_build": 10,
      "max_entries_to_merge": 5,
      "merge_method": "SQUASH",
      "min_entries_to_merge": 1,
      "min_entries_to_merge_wait_minutes": 5
    }]
  ' >/dev/null || fail "$repo payload lacks the approved queue policy"

  if grep -Eq -- '(^| )(-X|--method)(=| )(PUT|POST|PATCH|DELETE)( |$)' \
      "$tmp_dir/gh-calls.log"; then
    cat "$tmp_dir/gh-calls.log" >&2
    fail "$repo dry-run attempted a live mutation"
  fi

  echo "PASS: $repo preserves unrelated rules and exact $expected_count-context union"
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
  "tests/fixtures/github/argus-ruleset-contract.json:Argus:14"
  "tests/fixtures/github/proteus-ruleset-contract.json:Proteus:13"
  "tests/fixtures/github/myrmidons-ruleset-contract.json:Myrmidons:7"
)

for contract in "${contracts[@]}"; do
  IFS=: read -r fixture repo expected_count <<<"$contract"
  assert_fixture_contract "$fixture" "$repo" "$expected_count"
done

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

argus_fixture=tests/fixtures/github/argus-ruleset-contract.json

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
  if grep -qF 'DRY-RUN Argus payload:' "$output_file"; then
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
assert_identity_scope_rejected \
  inherited-organization-ruleset \
  '(.rulesets[0].source_type) = "Organization"'

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
    tools/github/apply-repo-rulesets.sh --active --repos Argus \
      >"$tmp_dir/argus-active.log" 2>&1; then
  fail "generic activation did not defer to Argus's dedicated authority"
fi
grep -qF "Argus owns a dedicated merge-queue ruleset path" \
  "$tmp_dir/argus-active.log" || fail "Argus refusal did not identify its authority"
echo "PASS: generic live activation defers Argus to its dedicated ruleset"

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

  : >"$tmp_dir/gh-calls.log"
  : >"$put_count_file"
  : >"$get_count_file"
  mkdir -p "$snapshot_dir"
  PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    GH_ALLOW_MUTATION=true \
    GH_RULESET_STATE="$state_file" \
    GH_PUT_COUNT_FILE="$put_count_file" \
    GH_DETAIL_GET_COUNT_FILE="$get_count_file" \
    GH_CORRUPT_PUT_AT="${GH_CORRUPT_PUT_AT:-}" \
    GH_FAIL_PUT_BEFORE_WRITE_AT="${GH_FAIL_PUT_BEFORE_WRITE_AT:-}" \
    GH_FAIL_PUT_AFTER_WRITE_AT="${GH_FAIL_PUT_AFTER_WRITE_AT:-}" \
    GH_FAIL_DETAIL_GET_AT="${GH_FAIL_DETAIL_GET_AT:-}" \
    GH_SIGNAL_HUP_DETAIL_GET_AT="${GH_SIGNAL_HUP_DETAIL_GET_AT:-}" \
    RULESET_SNAPSHOT_DIR="$snapshot_dir" \
    tools/github/apply-repo-rulesets.sh "${RULESET_MODE:---active}" --repos "$repos" \
      >"$output_file" 2>&1
}

assert_durable_snapshot() {
  local snapshot_dir=$1
  local expected_file=$2
  local label=$3
  local snapshots=()
  mapfile -t snapshots < <(find "$snapshot_dir" -type f -name '*.json' | sort)
  [[ ${#snapshots[@]} -eq 1 ]] || \
    fail "$label expected one durable pre-state snapshot, found ${#snapshots[@]}"
  jq -e --slurpfile expected "$expected_file" '. == $expected[0]' \
    "${snapshots[0]}" >/dev/null || fail "$label snapshot is not the exact pre-state"
}

myrmidons_fixture=tests/fixtures/github/myrmidons-ruleset-contract.json

evaluate_preview="$tmp_dir/evaluate-preview.log"
run_dry_run "$myrmidons_fixture" Myrmidons "$evaluate_preview" --evaluate || {
  cat "$evaluate_preview" >&2
  fail "active baseline evaluate dry-run was rejected"
}
evaluate_payload=$(sed -n 's/^DRY-RUN Myrmidons payload: //p' "$evaluate_preview")
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
seed_ruleset_state "$myrmidons_fixture" "$success_state"
cp "$success_state" "$success_pre"
if ! run_live_update \
    "$myrmidons_fixture" Myrmidons "$success_state" "$success_snapshots" \
    "$tmp_dir/success.log" "$tmp_dir/success-put-count" \
    "$tmp_dir/success-get-count"; then
  cat "$tmp_dir/success.log" >&2
  fail "verified live update scenario failed"
fi
assert_durable_snapshot "$success_snapshots" "$success_pre" "verified update"
[[ $(<"$tmp_dir/success-put-count") -eq 1 ]] || \
  fail "verified update must issue exactly one PUT"
[[ $(<"$tmp_dir/success-get-count") -eq 2 ]] || \
  fail "verified update must read exact post-state after PUT"
jq -e '
  .conditions.ref_name == {include: ["refs/heads/main"], exclude: []}
  and ([.rules[] | select(.type == "merge_queue")] | length) == 1
' "$success_state" >/dev/null || fail "verified update state does not match the candidate"
grep -qF "Verified exact postcondition" "$tmp_dir/success.log" || \
  fail "verified update did not report exact postcondition verification"
echo "PASS: live update snapshots pre-state and verifies exact post-state"

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
assert_durable_snapshot "$mismatch_snapshots" "$mismatch_pre" "mismatch rollback"
jq -e --slurpfile expected "$mismatch_pre" '. == $expected[0]' \
  "$mismatch_state" >/dev/null || fail "mismatched post-state was not rolled back"
[[ $(<"$tmp_dir/mismatch-put-count") -eq 2 ]] || \
  fail "mismatched post-state must trigger one rollback PUT"
[[ $(<"$tmp_dir/mismatch-get-count") -eq 3 ]] || \
  fail "mismatch rollback must be verified by readback"
grep -qF "Rollback verified" "$tmp_dir/mismatch.log" || \
  fail "mismatch rollback was not reported as verified"
echo "PASS: mismatched postcondition triggers verified rollback"

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
[[ $(<"$tmp_dir/ambiguous-get-count") -eq 2 ]] || \
  fail "ambiguous PUT rollback must be verified by readback"
grep -qF "Rollback verified" "$tmp_dir/ambiguous.log" || \
  fail "ambiguous PUT rollback was not reported as verified"
echo "PASS: ambiguous PUT failure triggers verified rollback"

readback_state="$tmp_dir/readback-state.json"
readback_pre="$tmp_dir/readback-pre.json"
readback_snapshots="$tmp_dir/readback-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$readback_state"
cp "$readback_state" "$readback_pre"
if GH_FAIL_DETAIL_GET_AT=2 run_live_update \
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
[[ $(<"$tmp_dir/readback-get-count") -eq 3 ]] || \
  fail "readback-failure rollback must be verified by another GET"
echo "PASS: failed post-PUT readback triggers verified rollback"

hup_state="$tmp_dir/hup-state.json"
hup_pre="$tmp_dir/hup-pre.json"
hup_snapshots="$tmp_dir/hup-snapshots"
seed_ruleset_state "$myrmidons_fixture" "$hup_state"
cp "$hup_state" "$hup_pre"
if GH_SIGNAL_HUP_DETAIL_GET_AT=2 run_live_update \
    "$myrmidons_fixture" Myrmidons,Proteus "$hup_state" "$hup_snapshots" \
    "$tmp_dir/hup.log" "$tmp_dir/hup-put-count" \
    "$tmp_dir/hup-get-count"; then
  fail "updater accepted HUP during ambiguous post-PUT readback"
fi
assert_durable_snapshot "$hup_snapshots" "$hup_pre" "HUP rollback"
jq -e --slurpfile expected "$hup_pre" '. == $expected[0]' \
  "$hup_state" >/dev/null || fail "HUP left live state unverified"
[[ $(<"$tmp_dir/hup-put-count") -eq 2 ]] || \
  fail "HUP must trigger exactly one rollback PUT"
[[ $(<"$tmp_dir/hup-get-count") -eq 3 ]] || \
  fail "HUP rollback must be verified by an exact readback"
grep -qF 'UNCERTAIN MUTATION: received HUP during an armed mutation' \
  "$tmp_dir/hup.log" || {
  cat "$tmp_dir/hup.log" >&2
  fail "HUP ambiguity did not report uncertain mutation"
}
grep -qF 'Rollback verified exactly' "$tmp_dir/hup.log" || \
  fail "HUP rollback was not reported as verified"
if grep -qF 'repos/HomericIntelligence/Proteus/rulesets' \
    "$tmp_dir/gh-calls.log"; then
  fail "fleet processing continued after HUP"
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
if grep -qF 'repos/HomericIntelligence/Proteus/rulesets' \
    "$tmp_dir/gh-calls.log"; then
  cat "$tmp_dir/gh-calls.log" >&2
  fail "fleet processing continued after an uncertain mutation"
fi
echo "PASS: uncertain rollback aborts fleet processing"

: >"$tmp_dir/gh-calls.log"
fleet_state="$tmp_dir/fleet-state.json"
fleet_snapshots="$tmp_dir/fleet-snapshots"
seed_ruleset_state \
  tests/fixtures/github/myrmidons-ruleset-contract.json "$fleet_state"
if ! PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE=tests/fixtures/github/myrmidons-ruleset-contract.json \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    GH_REPO_LIST=$'Argus\nMyrmidons' \
    GH_ALLOW_MUTATION=true \
    GH_RULESET_STATE="$fleet_state" \
    GH_PUT_COUNT_FILE="$tmp_dir/fleet-put-count" \
    GH_DETAIL_GET_COUNT_FILE="$tmp_dir/fleet-get-count" \
    RULESET_SNAPSHOT_DIR="$fleet_snapshots" \
    tools/github/apply-repo-rulesets.sh --active --all \
      >"$tmp_dir/all-active.log" 2>&1; then
  cat "$tmp_dir/all-active.log" >&2
  fail "explicit fleet activation could not continue past dedicated Argus"
fi
grep -qF "Skipping Argus; dedicated rollout is Argus #550/#552" \
  "$tmp_dir/all-active.log" || fail "fleet activation did not audit the Argus skip"
if grep -qF 'repos/HomericIntelligence/Argus/rulesets' \
    "$tmp_dir/gh-calls.log"; then
  cat "$tmp_dir/gh-calls.log" >&2
  fail "fleet activation called an Argus ruleset endpoint"
fi
grep -qF 'repos/HomericIntelligence/Myrmidons/rulesets/15556489' \
  "$tmp_dir/gh-calls.log" || fail "fleet activation did not update Myrmidons"
echo "PASS: explicit fleet activation skips Argus and continues with other repos"
