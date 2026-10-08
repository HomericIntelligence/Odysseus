#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
SCRIPT="$ROOT/tools/github/merge-queue-ruleset.sh"
FIXTURE="$ROOT/tools/tests/fixtures/merge-queue-ruleset.json"

rendered=$("$SCRIPT" --render "$FIXTURE")

test "$(jq -r '.name' <<<"$rendered")" = "homeric-main-baseline"
test "$(jq -r '.enforcement' <<<"$rendered")" = "active"
test "$(jq -r '.conditions.ref_name.include[0]' <<<"$rendered")" = "refs/heads/main"
test "$(jq -r '[.rules[] | select(.type == "deletion")] | length' <<<"$rendered")" = "1"
test "$(jq -r '[.rules[] | select(.type == "required_status_checks") | .parameters.required_status_checks[] | .context] | join(",")' <<<"$rendered")" = "lint"

merge_queue=$(jq -c '.rules[] | select(.type == "merge_queue")' <<<"$rendered")
test "$(jq -r '.parameters.check_response_timeout_minutes' <<<"$merge_queue")" = "180"
test "$(jq -r '.parameters.grouping_strategy' <<<"$merge_queue")" = "HEADGREEN"
test "$(jq -r '.parameters.max_entries_to_build' <<<"$merge_queue")" = "10"
test "$(jq -r '.parameters.max_entries_to_merge' <<<"$merge_queue")" = "5"
test "$(jq -r '.parameters.merge_method' <<<"$merge_queue")" = "SQUASH"
test "$(jq -r '.parameters.min_entries_to_merge' <<<"$merge_queue")" = "1"
test "$(jq -r '.parameters.min_entries_to_merge_wait_minutes' <<<"$merge_queue")" = "5"

test "$(jq '[.rules[] | select(.type == "merge_queue")] | length' <<<"$rendered")" = "1"
echo "PASS: merge queue ruleset rendering"
