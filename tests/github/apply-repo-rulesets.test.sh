#!/usr/bin/env bash
# Safety regression for repository-authoritative ruleset updates.
set -euo pipefail

REPO_ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
cd "$REPO_ROOT"

fixture=tests/fixtures/github/argus-ruleset-contract.json
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
mkdir -p "$tmp_dir/bin"
cp tests/fixtures/github/mock-ruleset-gh.sh "$tmp_dir/bin/gh"
chmod +x "$tmp_dir/bin/gh"

output=$(
  PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh \
      --active --repos Argus --dry-run
)

payload=$(sed -n 's/^DRY-RUN Argus payload: //p' <<<"$output")
if [[ -z "$payload" ]]; then
  echo "FAIL: dry-run did not emit an Argus update payload" >&2
  exit 1
fi

expected_contexts=$(jq -c '[
  .rulesets[].rules[]
  | select(.type == "required_status_checks")
  | .parameters.required_status_checks[].context
]' "$fixture")

actual_contexts=$(jq -nc --argjson payload "$payload" '[
  $payload.rules[]
  | select(.type == "required_status_checks")
  | .parameters.required_status_checks[].context
] + ["Validate configs"]')

if [[ "$actual_contexts" != "$expected_contexts" ]]; then
  echo "FAIL: Argus's complete 14-context contract was not preserved" >&2
  printf 'Expected: %s\nActual:   %s\n' "$expected_contexts" "$actual_contexts" >&2
  exit 1
fi

if ! jq -e --argjson payload "$payload" '
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
  ' "$fixture" >/dev/null; then
  echo "FAIL: dry-run changed or lost an unrelated Argus rule" >&2
  exit 1
fi

if ! jq -ne --argjson payload "$payload" '
    [$payload.rules[] | select(.type == "merge_queue") | .parameters] == [{
      "check_response_timeout_minutes": 60,
      "grouping_strategy": "ALLGREEN",
      "max_entries_to_build": 10,
      "max_entries_to_merge": 5,
      "merge_method": "SQUASH",
      "min_entries_to_merge": 1,
      "min_entries_to_merge_wait_minutes": 5
    }]
  ' >/dev/null; then
  echo "FAIL: dry-run payload lacks the approved merge-queue policy" >&2
  exit 1
fi

if grep -Eq -- '(^| )(-X|--method) (PUT|POST)( |$)' "$tmp_dir/gh-calls.log"; then
  echo "FAIL: dry-run attempted to mutate a live ruleset" >&2
  cat "$tmp_dir/gh-calls.log" >&2
  exit 1
fi

echo "PASS: Argus dry-run preserves all 14 contexts and every unrelated rule"

jq 'del(.rulesets[] | select(.name == "homeric-main-baseline").bypass_actors)' \
  "$fixture" > "$tmp_dir/incomplete-argus.json"
if PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$tmp_dir/incomplete-argus.json" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh \
      --active --repos Argus --dry-run \
      >"$tmp_dir/incomplete-response.log" 2>&1; then
  echo "FAIL: updater accepted a live response with hidden bypass actors" >&2
  exit 1
fi

if ! grep -qF "live ruleset response is incomplete" \
    "$tmp_dir/incomplete-response.log"; then
  echo "FAIL: incomplete-response refusal was not explicit" >&2
  cat "$tmp_dir/incomplete-response.log" >&2
  exit 1
fi

echo "PASS: updater fails closed when repository authority fields are hidden"

jq 'del(.rulesets[] | select(.name == "homeric-main-baseline"))' \
  "$fixture" > "$tmp_dir/no-baseline-argus.json"
if PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$tmp_dir/no-baseline-argus.json" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh \
      --active --repos Argus --dry-run \
      >"$tmp_dir/no-baseline.log" 2>&1; then
  echo "FAIL: updater accepted a repository with no owned baseline" >&2
  exit 1
fi

if ! grep -qF "bootstrap it from repository-owned policy" \
    "$tmp_dir/no-baseline.log"; then
  echo "FAIL: missing-baseline refusal did not identify repository authority" >&2
  cat "$tmp_dir/no-baseline.log" >&2
  exit 1
fi

if grep -Eq -- '(^| )(-X|--method) (PUT|POST)( |$)' "$tmp_dir/gh-calls.log"; then
  echo "FAIL: missing-baseline path attempted a live mutation" >&2
  cat "$tmp_dir/gh-calls.log" >&2
  exit 1
fi

echo "PASS: updater never bootstraps a repository from the fixed payload"

if PATH="$tmp_dir/bin:$PATH" \
    GH_RULESET_FIXTURE="$fixture" \
    GH_CALL_LOG="$tmp_dir/gh-calls.log" \
    tools/github/apply-repo-rulesets.sh --active --repos Argus \
      >"$tmp_dir/argus-active.log" 2>&1; then
  echo "FAIL: generic activation did not defer to Argus's dedicated authority" >&2
  exit 1
fi

if ! grep -qF "Argus owns a dedicated merge-queue ruleset path" \
    "$tmp_dir/argus-active.log"; then
  echo "FAIL: Argus refusal did not identify the dedicated authority" >&2
  cat "$tmp_dir/argus-active.log" >&2
  exit 1
fi

if grep -Eq -- '(^| )(-X|--method) (PUT|POST)( |$)' "$tmp_dir/gh-calls.log"; then
  echo "FAIL: generic Argus activation attempted a live mutation" >&2
  cat "$tmp_dir/gh-calls.log" >&2
  exit 1
fi

echo "PASS: generic activation defers Argus to its dedicated ruleset path"
