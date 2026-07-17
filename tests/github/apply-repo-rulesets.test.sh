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
  : >"$tmp_dir/gh-calls.log"
  PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh \
      --active --repos "$repo" --dry-run >"$output_file" 2>&1
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
        | test("^2026-07-16T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$")) and
      $fixture.provenance.repository_api ==
        ("https://api.github.com/repos/HomericIntelligence/" + $repo) and
      $fixture.provenance.rollout_issue == $expected_issue and
      $fixture.provenance.replacement_pr == $expected_pr and
      $fixture.provenance.replacement_pr_head == $expected_head and
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

  echo "PASS: $repo fixture records current API and replacement provenance"
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
  94da0478907c01551a6bae29f3d4645e8e886f30
assert_fixture_provenance \
  tests/fixtures/github/myrmidons-ruleset-contract.json Myrmidons 1 \
  https://github.com/HomericIntelligence/Myrmidons/issues/765 \
  https://github.com/HomericIntelligence/Myrmidons/pull/767 \
  c940de8481fca516794519c3350aa8513f308943

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

: >"$tmp_dir/gh-calls.log"
if ! PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE=tests/fixtures/github/myrmidons-ruleset-contract.json \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    GH_REPO_LIST=$'Argus\nMyrmidons' \
    GH_ALLOW_MUTATION=true \
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
