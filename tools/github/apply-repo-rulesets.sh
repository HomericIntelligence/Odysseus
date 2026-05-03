#!/usr/bin/env bash
set -euo pipefail

# apply-repo-rulesets.sh [--active] [--repos repo1,repo2,...]
# Creates or updates the homeric-main-baseline branch ruleset on every repo.
# Usage:
#   ./tools/github/apply-repo-rulesets.sh                    # evaluate mode, all repos
#   ./tools/github/apply-repo-rulesets.sh --active           # active (enforcing) mode, all repos
#   ./tools/github/apply-repo-rulesets.sh --repos Foo,Bar    # evaluate mode, specific repos only

ORG="HomericIntelligence"
RULESET_NAME="homeric-main-baseline"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENFORCEMENT="evaluate"
REPOS_OVERRIDE=""

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --active)        ENFORCEMENT="active"; shift ;;
    --repos)         REPOS_OVERRIDE="$2"; shift 2 ;;
    --repos=*)       REPOS_OVERRIDE="${1#--repos=}"; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$ENFORCEMENT" == "active" ]]; then
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset-active.json"
  echo "Applying in ACTIVE (enforcing) mode"
else
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset.json"
  echo "Applying in EVALUATE mode"
fi

if [[ -n "$REPOS_OVERRIDE" ]]; then
  IFS=',' read -ra REPOS <<< "$REPOS_OVERRIDE"
  echo "Targeting ${#REPOS[@]} repo(s) from --repos override: ${REPOS[*]}"
else
  mapfile -t REPOS < <(gh repo list "$ORG" --json name,isArchived --limit 100 \
    --jq '[.[] | select(.isArchived == false) | .name] | sort | .[]')
  echo "Discovered ${#REPOS[@]} active repo(s) via gh repo list"
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: no repos resolved (gh API failure or --repos was empty)" >&2
  exit 1
fi

ok=0
fail=0

for repo in "${REPOS[@]}"; do
  echo ""
  echo "--- $repo ---"

  existing_id=$(gh api "repos/$ORG/$repo/rulesets" --paginate \
    --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || echo "")

  if [[ -z "$existing_id" ]]; then
    echo "  Creating..."
    if gh api -X POST "repos/$ORG/$repo/rulesets" --input "$JSON_FILE" > /dev/null 2>&1; then
      echo "  Created."
      ok=$((ok + 1))
    else
      echo "  FAILED"
      fail=$((fail + 1))
    fi
  else
    echo "  Updating (id: $existing_id)..."
    if gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" --input "$JSON_FILE" > /dev/null 2>&1; then
      echo "  Updated."
      ok=$((ok + 1))
    else
      echo "  FAILED"
      fail=$((fail + 1))
    fi
  fi
done

echo ""
echo "Done: $ok succeeded, $fail failed"
