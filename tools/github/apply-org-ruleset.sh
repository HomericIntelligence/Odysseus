#!/usr/bin/env bash
set -euo pipefail

# apply-org-ruleset.sh <ruleset-json-file>
# Creates the org ruleset if it doesn't exist; updates it if it does.
# Requires: gh with admin:org scope, jq

ORG="HomericIntelligence"
RULESET_NAME="homeric-main-baseline"
JSON_FILE="${1:-configs/github/org-ruleset.json}"

if [[ ! -f "$JSON_FILE" ]]; then
  echo "ERROR: $JSON_FILE not found" >&2
  exit 1
fi

# Check for existing ruleset with this name
existing_id=$(gh api "orgs/$ORG/rulesets" --paginate \
  --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" 2>/dev/null || echo "")

if [[ -z "$existing_id" ]]; then
  echo "Creating new org ruleset '$RULESET_NAME'..."
  gh api -X POST "orgs/$ORG/rulesets" --input "$JSON_FILE"
  echo "Created."
else
  echo "Updating existing org ruleset '$RULESET_NAME' (id: $existing_id)..."
  gh api -X PUT "orgs/$ORG/rulesets/$existing_id" --input "$JSON_FILE"
  echo "Updated."
fi
