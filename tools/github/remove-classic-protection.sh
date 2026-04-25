#!/usr/bin/env bash
set -euo pipefail

# remove-classic-protection.sh [--repo REPO | --all]
# Removes classic branch protection from one or all repos.
# Requires confirmation before --all.

ORG="HomericIntelligence"
ALL_REPOS=(Odysseus AchaeanFleet ProjectArgus ProjectHermes ProjectTelemachy ProjectKeystone Myrmidons ProjectProteus ProjectOdyssey ProjectScylla ProjectMnemosyne ProjectHephaestus ProjectAgamemnon ProjectNestor ProjectCharybdis)

if [[ "${1:-}" == "--repo" && -n "${2:-}" ]]; then
  repo="$2"
  echo "Removing classic branch protection from $ORG/$repo/branches/main..."
  gh api -X DELETE "repos/$ORG/$repo/branches/main/protection"
  echo "Done: $repo"
elif [[ "${1:-}" == "--all" ]]; then
  echo "WARNING: This will remove classic branch protection from ALL 15 repos."
  echo "The org-level ruleset must already be active before running this."
  read -r -p "Type 'yes' to confirm: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "Aborted."
    exit 1
  fi
  for repo in "${ALL_REPOS[@]}"; do
    echo "Removing $repo..."
    gh api -X DELETE "repos/$ORG/$repo/branches/main/protection" 2>/dev/null && echo "  Done." || echo "  Already removed or 404."
  done
else
  echo "Usage: $0 --repo REPO | --all"
  exit 1
fi
