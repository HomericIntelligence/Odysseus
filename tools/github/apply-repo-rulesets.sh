#!/usr/bin/env bash
set -euo pipefail

# apply-repo-rulesets.sh [--active|--evaluate] [--repos repo1,repo2,...]
#                         [--all] [--dry-run]
# Adds or updates only the merge-queue rule and enforcement mode in an existing
# homeric-main-baseline ruleset. All other live rules remain repository-owned.
# Usage:
#   ./tools/github/apply-repo-rulesets.sh --active --all     # active mode, eligible fleet repos
#   ./tools/github/apply-repo-rulesets.sh --evaluate --all   # evaluate mode, eligible fleet repos
#   ./tools/github/apply-repo-rulesets.sh --repos Foo,Bar    # canonical mode, specific repos only
#   ./tools/github/apply-repo-rulesets.sh --dry-run --repos Foo

ORG="HomericIntelligence"
RULESET_NAME="homeric-main-baseline"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

ENFORCEMENT=""
REPOS_OVERRIDE=""
DRY_RUN=false
ALL_REPOS=false

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    --active)        ENFORCEMENT="active"; shift ;;
    --evaluate)      ENFORCEMENT="evaluate"; shift ;;
    --repos)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: --repos requires a non-empty comma-separated value" >&2
        exit 2
      fi
      REPOS_OVERRIDE="$2"
      shift 2
      ;;
    --repos=*)
      REPOS_OVERRIDE="${1#--repos=}"
      if [[ -z "$REPOS_OVERRIDE" ]]; then
        echo "ERROR: --repos requires a non-empty comma-separated value" >&2
        exit 2
      fi
      shift
      ;;
    --dry-run)       DRY_RUN=true; shift ;;
    --all)           ALL_REPOS=true; shift ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

if [[ "$ENFORCEMENT" == "active" ]]; then
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset-active.json"
  echo "Applying in ACTIVE (enforcing) mode"
elif [[ "$ENFORCEMENT" == "evaluate" ]]; then
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset-evaluate.json"
  echo "Applying in EVALUATE (shadow) mode"
else
  JSON_FILE="$REPO_ROOT/configs/github/repo-ruleset.json"
  echo "Applying canonical ruleset ($(jq -r .enforcement "$JSON_FILE") mode)"
fi

desired_enforcement=$(jq -er '.enforcement' "$JSON_FILE")
desired_merge_queue=$(jq -ec '
  [.rules[] | select(.type == "merge_queue")] as $rules
  | if ($rules | length) != 1
    then error("canonical ruleset must contain exactly one merge_queue rule")
    else $rules[0]
    end
' "$JSON_FILE")

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

if [[ -n "$REPOS_OVERRIDE" && "$ALL_REPOS" == true ]]; then
  echo "ERROR: use either --repos or --all, not both" >&2
  exit 2
elif [[ -n "$REPOS_OVERRIDE" ]]; then
  IFS=',' read -ra REPOS <<< "$REPOS_OVERRIDE"
  echo "Targeting ${#REPOS[@]} repo(s) from --repos override: ${REPOS[*]}"
elif [[ "$ALL_REPOS" == true ]]; then
  mapfile -t REPOS < <(gh repo list "$ORG" --json name,isFork,isArchived --limit 100 \
    --jq '[.[] | select(.isFork == false and .isArchived == false) | .name] | sort | .[]')
  echo "Discovered ${#REPOS[@]} active non-fork repo(s) via gh repo list"
else
  echo "ERROR: target scope is required; pass --repos <names> or explicit --all" >&2
  exit 2
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: no repos resolved (gh API failure or --repos was empty)" >&2
  exit 1
fi

eligible_repos=()
for repo in "${REPOS[@]}"; do
  if [[ "$repo" == "Argus" ]]; then
    if [[ "$ALL_REPOS" == true ]]; then
      echo "Skipping Argus; dedicated rollout is Argus #550/#552"
      continue
    fi
    if [[ "$DRY_RUN" != true ]]; then
      echo "ERROR: Argus owns a dedicated merge-queue ruleset path; see Argus #550/#552" >&2
      exit 1
    fi
  fi
  eligible_repos+=("$repo")
done
REPOS=("${eligible_repos[@]}")

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: no repos remain after applying dedicated-rollout exclusions" >&2
  exit 1
fi

ok=0
fail=0

for repo in "${REPOS[@]}"; do
  echo ""
  echo "--- $repo ---"

  ruleset_list="$tmp_dir/$repo-rulesets.json"
  if ! gh api "repos/$ORG/$repo/rulesets?includes_parents=false" > "$ruleset_list"; then
    echo "  FAILED: could not list repository rulesets" >&2
    fail=$((fail + 1))
    continue
  fi

  mapfile -t existing_ids < <(
    jq -r --arg name "$RULESET_NAME" \
      '.[] | select(.name == $name) | .id' "$ruleset_list"
  )

  if [[ ${#existing_ids[@]} -gt 1 ]]; then
    echo "  FAILED: multiple rulesets named '$RULESET_NAME'; refusing ambiguous update" >&2
    fail=$((fail + 1))
    continue
  fi

  existing_id="${existing_ids[0]:-}"

  if [[ -z "$existing_id" ]]; then
    echo "  FAILED: '$RULESET_NAME' is absent; bootstrap it from repository-owned policy" >&2
    fail=$((fail + 1))
  else
    live_ruleset="$tmp_dir/$repo-$existing_id-live.json"
    update_payload="$tmp_dir/$repo-$existing_id-update.json"

    if ! gh api "repos/$ORG/$repo/rulesets/$existing_id" > "$live_ruleset"; then
      echo "  FAILED: could not read live ruleset id $existing_id" >&2
      fail=$((fail + 1))
      continue
    fi

    if ! jq -e \
        --arg enforcement "$desired_enforcement" \
        --arg source "$ORG/$repo" \
        --argjson merge_queue "$desired_merge_queue" '
      def valid_required_check:
        type == "object"
        and has("context")
        and (.context | type == "string")
        and (.context | test("\\S"))
        and has("integration_id")
        and (
          .integration_id == null
          or (
            (.integration_id | type) == "number"
            and .integration_id > 0
            and .integration_id == (.integration_id | floor)
          )
        );
      def complete_required_status_authority:
        [.rules[] | select(.type == "required_status_checks")] as $status_rules
        | (.rules | type) == "array"
        and all(
          .rules[];
          type == "object"
          and has("type")
          and (.type | type) == "string"
        )
        and ($status_rules | length) == 1
        and ($status_rules[0] | has("parameters"))
        and ($status_rules[0].parameters | type == "object")
        and ($status_rules[0].parameters | has("strict_required_status_checks_policy"))
        and (
          $status_rules[0].parameters.strict_required_status_checks_policy
          | type
        ) == "boolean"
        and ($status_rules[0].parameters | has("do_not_enforce_on_create"))
        and (
          $status_rules[0].parameters.do_not_enforce_on_create
          | type
        ) == "boolean"
        and ($status_rules[0].parameters | has("required_status_checks"))
        and ($status_rules[0].parameters.required_status_checks | type == "array")
        and ($status_rules[0].parameters.required_status_checks | length) > 0
        and all(
          $status_rules[0].parameters.required_status_checks[];
          valid_required_check
        )
        and (
          [
            $status_rules[0].parameters.required_status_checks[]
            | .context
          ]
          | length
        ) == (
          [
            $status_rules[0].parameters.required_status_checks[]
            | .context
          ]
          | unique
          | length
        );
      ([.rules[] | select(.type == "merge_queue")] | length) as $queue_count
      | if .source_type != "Repository" or .source != $source
        then error("ruleset is not owned by the target repository")
        elif (has("name") and has("target") and has("bypass_actors")
          and has("conditions") and has("rules")) | not
        then error("live ruleset response is incomplete")
        elif (complete_required_status_authority | not)
        then error("required_status_checks authority is incomplete")
        elif $queue_count > 1
        then error("live ruleset has multiple merge_queue rules")
        else {
          name,
          target,
          enforcement: $enforcement,
          bypass_actors,
          conditions,
          rules: (
            if $queue_count == 1
            then [.rules[] | if .type == "merge_queue" then $merge_queue else . end]
            else .rules + [$merge_queue]
            end
          )
        }
        end
    ' "$live_ruleset" > "$update_payload"; then
      echo "  FAILED: could not derive a scoped update from the live ruleset" >&2
      fail=$((fail + 1))
      continue
    fi

    if ! jq -e --slurpfile candidate "$update_payload" '
      def unrelated:
        {
          name,
          target,
          bypass_actors,
          conditions,
          rules: [.rules[] | select(.type != "merge_queue")]
        };
      unrelated == ($candidate[0] | unrelated)
    ' "$live_ruleset" > /dev/null; then
      echo "  FAILED: scoped update would change or remove an unrelated live rule" >&2
      fail=$((fail + 1))
      continue
    fi

    if [[ "$DRY_RUN" == true ]]; then
      echo "DRY-RUN $repo payload: $(jq -c . "$update_payload")"
      ok=$((ok + 1))
      continue
    fi

    echo "  Updating only enforcement and merge_queue (id: $existing_id)..."
    if gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" \
        --input "$update_payload" > /dev/null; then
      echo "  Updated; repository-specific contexts and unrelated rules preserved."
      ok=$((ok + 1))
    else
      echo "  FAILED" >&2
      fail=$((fail + 1))
    fi
  fi
done

echo ""
echo "Done: $ok succeeded, $fail failed"
if ((fail > 0)); then
  exit 1
fi
