#!/usr/bin/env bash
set -euo pipefail

# snapshot-protection.sh
# Snapshots classic branch protection from all 15 repos to stdout as JSON array.
# Usage: ./tools/github/snapshot-protection.sh > configs/github/backups/branch-protection-$(date +%Y%m%d).json

ORG="HomericIntelligence"
REPOS=(Odysseus AchaeanFleet ProjectArgus ProjectHermes ProjectTelemachy ProjectKeystone Myrmidons ProjectProteus ProjectOdyssey ProjectScylla ProjectMnemosyne ProjectHephaestus ProjectAgamemnon ProjectNestor ProjectCharybdis)

result="[]"
for repo in "${REPOS[@]}"; do
  echo "Snapshotting $repo..." >&2
  protection=$(gh api "repos/$ORG/$repo/branches/main/protection" 2>/dev/null || echo "null")
  result=$(echo "$result" | jq --arg r "$repo" --argjson p "$protection" '. + [{repo: $r, protection: $p}]')
done
echo "$result"
