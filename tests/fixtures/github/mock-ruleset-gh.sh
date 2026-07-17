#!/usr/bin/env bash
set -euo pipefail

: "${GH_RULESET_FIXTURE:?GH_RULESET_FIXTURE is required}"
: "${GH_CALL_LOG:?GH_CALL_LOG is required}"

printf '%q ' "$@" >> "$GH_CALL_LOG"
printf '\n' >> "$GH_CALL_LOG"

next_counter() {
  local counter_file=$1
  local value=0
  if [[ -s "$counter_file" ]]; then
    value=$(<"$counter_file")
  fi
  value=$((value + 1))
  printf '%s\n' "$value" >"$counter_file"
  printf '%s\n' "$value"
}

count_selected() {
  local selected=${1:-}
  local count=$2
  [[ ",$selected," == *",$count,"* ]]
}

if [[ "${1:-}" == "repo" && "${2:-}" == "list" ]]; then
  : "${GH_REPO_LIST:?GH_REPO_LIST is required for gh repo list}"
  printf '%s\n' "$GH_REPO_LIST"
  exit 0
fi

if [[ "${1:-}" != "api" ]]; then
  echo "unexpected gh command: $*" >&2
  exit 2
fi
shift

for argument in "$@"; do
  case "$argument" in
    PUT|POST|PATCH|DELETE)
      if [[ "${GH_ALLOW_MUTATION:-false}" != true ]]; then
        echo "mock refuses mutation method: $argument" >&2
        exit 2
      fi
      ;;
  esac
done

method=GET
input=""
endpoint=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X|--method)
      method=$2
      shift 2
      ;;
    --input)
      input=$2
      shift 2
      ;;
    --jq)
      shift 2
      ;;
    --paginate)
      shift
      ;;
    -* )
      echo "unexpected gh api option: $1" >&2
      exit 2
      ;;
    *)
      endpoint=$1
      shift
      ;;
  esac
done

if [[ "$method" != GET ]]; then
  [[ "${GH_ALLOW_MUTATION:-false}" == true && -n "$input" ]] || {
    echo "mock refuses mutation: method=$method input=$input" >&2
    exit 2
  }

  put_count=1
  if [[ -n "${GH_PUT_COUNT_FILE:-}" ]]; then
    put_count=$(next_counter "$GH_PUT_COUNT_FILE")
  fi
  if count_selected "${GH_FAIL_PUT_BEFORE_WRITE_AT:-}" "$put_count"; then
    echo "mock PUT failure before write at call $put_count" >&2
    exit 1
  fi

  if [[ -n "${GH_RULESET_STATE:-}" ]]; then
    [[ -s "$GH_RULESET_STATE" ]] || {
      echo "mock state file is missing: $GH_RULESET_STATE" >&2
      exit 2
    }
    state_tmp="$GH_RULESET_STATE.tmp"
    jq --slurpfile current "$GH_RULESET_STATE" '
      . + {
        id: $current[0].id,
        source: $current[0].source,
        source_type: $current[0].source_type
      }
    ' "$input" >"$state_tmp"
    mv "$state_tmp" "$GH_RULESET_STATE"
    if count_selected "${GH_CORRUPT_PUT_AT:-}" "$put_count"; then
      state_tmp="$GH_RULESET_STATE.tmp"
      jq '.conditions.ref_name.include = ["refs/heads/not-main"]' \
        "$GH_RULESET_STATE" >"$state_tmp"
      mv "$state_tmp" "$GH_RULESET_STATE"
    fi
  fi

  if count_selected "${GH_FAIL_PUT_AFTER_WRITE_AT:-}" "$put_count"; then
    echo "mock PUT failure after write at call $put_count" >&2
    exit 1
  fi

  if [[ -n "${GH_RULESET_STATE:-}" ]]; then
    jq . "$GH_RULESET_STATE"
  else
    jq . "$input"
  fi
  exit 0
fi

repository=$(jq -r '.repository' "$GH_RULESET_FIXTURE")
case "$endpoint" in
  "repos/$repository/rulesets?includes_parents=false")
    jq --arg name_override "${GH_RULESET_LIST_NAME_OVERRIDE:-}" '
      [.rulesets | to_entries[] as $entry | $entry.value | {
        id,
        name: (
          if $name_override != "" and $entry.key == 0
          then $name_override
          else .name
          end
        ),
        target,
        enforcement
      }]
    ' \
      "$GH_RULESET_FIXTURE"
    ;;
  "repos/$repository/rulesets/"*)
    ruleset_id="${endpoint##*/}"
    detail_count=1
    if [[ -n "${GH_DETAIL_GET_COUNT_FILE:-}" ]]; then
      detail_count=$(next_counter "$GH_DETAIL_GET_COUNT_FILE")
    fi
    if count_selected "${GH_FAIL_DETAIL_GET_AT:-}" "$detail_count"; then
      echo "mock detail GET failure at call $detail_count" >&2
      exit 1
    fi
    if [[ -n "${GH_RULESET_STATE:-}" ]]; then
      jq --argjson id "$ruleset_id" 'select(.id == $id)' "$GH_RULESET_STATE"
    else
      jq --argjson id "$ruleset_id" \
        '.rulesets[] | select(.id == $id)' "$GH_RULESET_FIXTURE"
    fi
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 2
    ;;
esac
