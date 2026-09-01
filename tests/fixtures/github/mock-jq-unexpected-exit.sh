#!/usr/bin/env bash
set -euo pipefail

: "${REAL_JQ:?REAL_JQ is required}"

target_repo=${JQ_FAIL_PROVENANCE_REPO:-}
if [[ -n "$target_repo" ]]; then
  joined="$(printf '\037%s' "$@")\037"
  filter_found=false
  for argument in "$@"; do
    if [[ "$argument" == '.repositories[$repo].main_sha' ]]; then
      filter_found=true
      break
    fi
  done
  if [[ "$filter_found" == true &&
      "$joined" == *$'\037--arg\037repo\037'"$target_repo"$'\037'* ]]; then
    echo "mock jq unexpected provenance lookup failure for $target_repo" >&2
    exit 97
  fi
fi

exec "$REAL_JQ" "$@"
