#!/usr/bin/env bash
set -euo pipefail

# Add or update the merge_queue rule on the live homeric-main-baseline ruleset
# without replacing repository-specific required checks or unrelated rules.
#
# Render a safe PUT payload locally:
#   merge-queue-ruleset.sh --render ruleset.json
#
# Inspect all first-party non-fork repositories:
#   merge-queue-ruleset.sh --dry-run
#
# Apply the approved queue policy (preserving each ruleset's current
# enforcement mode unless --activate/--evaluate is supplied):
#   merge-queue-ruleset.sh --repos Odysseus,Athena

ORG=${HOMERIC_ORG:-HomericIntelligence}
RULESET_NAME=${MERGE_QUEUE_RULESET_NAME:-homeric-main-baseline}
DRY_RUN=false
RENDER_FILE=
REPOS_ARG=
ENFORCEMENT=

usage() {
  cat <<'EOF'
Usage: merge-queue-ruleset.sh [options]

Options:
  --render FILE       Render a PUT payload from a fetched ruleset JSON file.
  --dry-run           Show the repositories and resulting queue policy only.
  --repos LIST        Comma-separated repository names; default discovers all
                      active, non-fork repositories in HOMERIC_ORG.
  --activate          Set enforcement to active while applying the patch.
  --evaluate          Set enforcement to evaluate while applying the patch.
  -h, --help          Show this help.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --render)
      [ "$#" -ge 2 ] || { echo "ERROR: --render requires FILE" >&2; exit 2; }
      RENDER_FILE=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --repos)
      [ "$#" -ge 2 ] || { echo "ERROR: --repos requires LIST" >&2; exit 2; }
      REPOS_ARG=$2
      shift 2
      ;;
    --activate)
      [ -z "$ENFORCEMENT" ] || { echo "ERROR: --activate and --evaluate are mutually exclusive" >&2; exit 2; }
      ENFORCEMENT=active
      shift
      ;;
    --evaluate)
      [ -z "$ENFORCEMENT" ] || { echo "ERROR: --activate and --evaluate are mutually exclusive" >&2; exit 2; }
      ENFORCEMENT=evaluate
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "ERROR: unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

MERGE_QUEUE_JSON='{
  "type": "merge_queue",
  "parameters": {
    "check_response_timeout_minutes": 180,
    "grouping_strategy": "HEADGREEN",
    "max_entries_to_build": 10,
    "max_entries_to_merge": 5,
    "merge_method": "SQUASH",
    "min_entries_to_merge": 1,
    "min_entries_to_merge_wait_minutes": 5
  }
}'

render_ruleset() {
  local input=$1
  jq -S \
    --argjson merge_queue "$MERGE_QUEUE_JSON" \
    --arg enforcement "$ENFORCEMENT" \
    '
      {
        name: .name,
        target: .target,
        enforcement: (.enforcement // "active"),
        conditions: (.conditions // {}),
        rules: ((.rules // []) | map(select(.type != "merge_queue")) + [$merge_queue]),
        bypass_actors: (.bypass_actors // [])
      }
      | if $enforcement != "" then .enforcement = $enforcement else . end
    ' "$input"
}

if [ -n "$RENDER_FILE" ]; then
  [ -f "$RENDER_FILE" ] || { echo "ERROR: ruleset file not found: $RENDER_FILE" >&2; exit 1; }
  render_ruleset "$RENDER_FILE"
  exit 0
fi

command -v gh >/dev/null 2>&1 || { echo "ERROR: gh is required for live ruleset operations" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "ERROR: jq is required for live ruleset operations" >&2; exit 1; }

mapfile -t repos < <(
  if [ -n "$REPOS_ARG" ]; then
    tr ',' '\n' <<<"$REPOS_ARG"
  else
    gh repo list "$ORG" --limit 100 --json name,isFork,isArchived \
      --jq '.[] | select(.isFork == false and .isArchived == false) | .name'
  fi
)
[ "${#repos[@]}" -gt 0 ] || { echo "ERROR: no repositories selected" >&2; exit 1; }

for repo in "${repos[@]}"; do
  repo=${repo//$'\r'/}
  [ -n "$repo" ] || continue
  ruleset_id=$(gh api "repos/$ORG/$repo/rulesets" --paginate \
    --jq ".[] | select(.name == \"$RULESET_NAME\") | .id" | head -n1)
  if [ -z "$ruleset_id" ]; then
    echo "ERROR: $ORG/$repo has no $RULESET_NAME ruleset" >&2
    exit 1
  fi

  tmp=$(mktemp)
  trap 'rm -f "$tmp"' EXIT
  gh api "repos/$ORG/$repo/rulesets/$ruleset_id" >"$tmp"
  payload=$(render_ruleset "$tmp")
  queue_summary=$(jq -c '.rules[] | select(.type == "merge_queue")' <<<"$payload")
  if [ "$DRY_RUN" = true ]; then
    printf '%s/%s ruleset=%s enforcement=%s merge_queue=%s\n' \
      "$ORG" "$repo" "$ruleset_id" "$(jq -r '.enforcement' <<<"$payload")" "$queue_summary"
  else
    gh api -X PUT "repos/$ORG/$repo/rulesets/$ruleset_id" \
      --input <(printf '%s\n' "$payload") >/dev/null
    echo "UPDATED $ORG/$repo ruleset=$ruleset_id"
  fi
  rm -f "$tmp"
  trap - EXIT
done
