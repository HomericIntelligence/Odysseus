#!/usr/bin/env bash
set -euo pipefail

: "${GH_RULESET_FIXTURE:?GH_RULESET_FIXTURE is required}"
: "${GH_CALL_LOG:?GH_CALL_LOG is required}"

printf '%s\n' "$*" >> "$GH_CALL_LOG"

if [[ "$1" != "api" ]]; then
  echo "unexpected gh command: $*" >&2
  exit 2
fi
shift

case "$1" in
  'repos/HomericIntelligence/Argus/rulesets?includes_parents=false')
    jq '[.rulesets[] | {id, name, target, enforcement}]' "$GH_RULESET_FIXTURE"
    ;;
  repos/HomericIntelligence/Argus/rulesets/15556501)
    jq '.rulesets[] | select(.name == "homeric-main-baseline")' \
      "$GH_RULESET_FIXTURE"
    ;;
  *)
    echo "unexpected gh api endpoint: $1" >&2
    exit 2
    ;;
esac
