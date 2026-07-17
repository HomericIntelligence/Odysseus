#!/usr/bin/env bash
set -euo pipefail

: "${GH_RULESET_FIXTURE:?GH_RULESET_FIXTURE is required}"
: "${GH_CALL_LOG:?GH_CALL_LOG is required}"

printf '%q ' "$@" >> "$GH_CALL_LOG"
printf '\n' >> "$GH_CALL_LOG"

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
  jq . "$input"
  exit 0
fi

repository=$(jq -r '.repository' "$GH_RULESET_FIXTURE")
case "$endpoint" in
  "repos/$repository/rulesets?includes_parents=false")
    jq '[.rulesets[] | {id, name, target, enforcement}]' \
      "$GH_RULESET_FIXTURE"
    ;;
  "repos/$repository/rulesets/"*)
    ruleset_id="${endpoint##*/}"
    jq --argjson id "$ruleset_id" \
      '.rulesets[] | select(.id == $id)' "$GH_RULESET_FIXTURE"
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 2
    ;;
esac
