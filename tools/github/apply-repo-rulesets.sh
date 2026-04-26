#!/usr/bin/env bash
set -euo pipefail

# apply-repo-rulesets.sh [--active]
# Creates or updates the homeric-main-baseline branch ruleset on every repo.
# Requires: gh with repo scope and GitHub Team/Enterprise plan.
# Usage:
#   ./tools/github/apply-repo-rulesets.sh           # evaluate mode
#   ./tools/github/apply-repo-rulesets.sh --active  # active (enforcing) mode

ORG="HomericIntelligence"
RULESET_NAME="homeric-main-baseline"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

if [[ "${1:-}" == "--active" ]]; then
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset-active.json"
  echo "Applying in ACTIVE (enforcing) mode"
else
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset.json"
  echo "Applying in EVALUATE mode"
fi

REPOS=(
  Odysseus
  AchaeanFleet
  ProjectArgus
  ProjectHermes
  ProjectTelemachy
  ProjectKeystone
  Myrmidons
  ProjectProteus
  ProjectOdyssey
  ProjectScylla
  ProjectMnemosyne
  ProjectHephaestus
  ProjectAgamemnon
  ProjectNestor
  ProjectCharybdis
)

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
      echo "  FAILED (plan restriction?)"
      fail=$((fail + 1))
    fi
  else
    echo "  Updating (id: $existing_id)..."
    if gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" --input "$JSON_FILE" > /dev/null 2>&1; then
      echo "  Updated."
      ok=$((ok + 1))
    else
      echo "  FAILED (plan restriction?)"
      fail=$((fail + 1))
    fi
  fi
done

echo ""
echo "Done: $ok succeeded, $fail failed"
