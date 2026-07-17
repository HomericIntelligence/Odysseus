#!/usr/bin/env bash
set -euo pipefail

# apply-repo-rulesets.sh [--active|--evaluate] [--repos repo1,repo2,...]
#                         [--all] [--dry-run] [--snapshot-dir path]
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
SNAPSHOT_DIR_OVERRIDE="${RULESET_SNAPSHOT_DIR:-}"

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
    --snapshot-dir)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: --snapshot-dir requires a non-empty path" >&2
        exit 2
      fi
      SNAPSHOT_DIR_OVERRIDE=$2
      shift 2
      ;;
    --snapshot-dir=*)
      SNAPSHOT_DIR_OVERRIDE="${1#--snapshot-dir=}"
      if [[ -z "$SNAPSHOT_DIR_OVERRIDE" ]]; then
        echo "ERROR: --snapshot-dir requires a non-empty path" >&2
        exit 2
      fi
      shift
      ;;
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

if [[ -n "$SNAPSHOT_DIR_OVERRIDE" ]]; then
  SNAPSHOT_ROOT=$SNAPSHOT_DIR_OVERRIDE
else
  operation_id="$(date -u +%Y%m%dT%H%M%SZ)-$$"
  SNAPSHOT_ROOT="$REPO_ROOT/configs/github/backups/ruleset-mutations/$operation_id"
fi

validate_live_identity_scope() {
  local ruleset_file=$1
  local repo=$2
  jq -e \
    --arg name "$RULESET_NAME" \
    --arg source "$ORG/$repo" '
      .name == $name
      and .target == "branch"
      and .source_type == "Repository"
      and .source == $source
      and .conditions == {
        ref_name: {
          include: ["refs/heads/main"],
          exclude: []
        }
      }
    ' "$ruleset_file" > /dev/null
}

write_mutable_payload() {
  local ruleset_file=$1
  local payload_file=$2
  jq -e '{name, target, enforcement, bypass_actors, conditions, rules}' \
    "$ruleset_file" >"$payload_file"
}

exact_mutable_state_matches() {
  local expected_payload=$1
  local actual_ruleset=$2
  jq -e --slurpfile expected "$expected_payload" '
    {name, target, enforcement, bypass_actors, conditions, rules}
      == $expected[0]
  ' "$actual_ruleset" > /dev/null
}

rollback_and_abort() {
  local repo=$1
  local existing_id=$2
  local rollback_payload=$3
  local reason=$4
  local snapshot_file=$5
  local rollback_readback="$tmp_dir/$repo-$existing_id-rollback-readback.json"
  local rollback_put_rc=0

  MUTATION_ARMED=false
  trap '' INT TERM
  echo "  FAILED: $reason; attempting rollback from durable pre-state" >&2
  gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" \
    --input "$rollback_payload" > /dev/null || rollback_put_rc=$?
  if ((rollback_put_rc != 0)); then
    echo "  WARNING: rollback PUT reported exit $rollback_put_rc; verifying live state" >&2
  fi

  if gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$rollback_readback" &&
      validate_live_identity_scope "$rollback_readback" "$repo" &&
      exact_mutable_state_matches "$rollback_payload" "$rollback_readback"; then
    echo "  Rollback verified exactly; aborting this operation before any further repository." >&2
    exit 1
  fi

  echo "  UNCERTAIN MUTATION: rollback could not be verified exactly for $repo ruleset $existing_id." >&2
  echo "  Durable recovery snapshot: $snapshot_file" >&2
  exit 1
}

MUTATION_ARMED=false
MUTATION_REPO=""
MUTATION_RULESET_ID=""
MUTATION_ROLLBACK_PAYLOAD=""
MUTATION_SNAPSHOT=""

handle_mutation_signal() {
  local signal_name=$1
  trap - INT TERM
  if [[ "$MUTATION_ARMED" == true ]]; then
    rollback_and_abort \
      "$MUTATION_REPO" \
      "$MUTATION_RULESET_ID" \
      "$MUTATION_ROLLBACK_PAYLOAD" \
      "received $signal_name during an armed mutation" \
      "$MUTATION_SNAPSHOT"
  fi
  exit 130
}

trap 'handle_mutation_signal INT' INT
trap 'handle_mutation_signal TERM' TERM

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

    # Validate the fetched object itself before constructing any PUT payload.
    # The list endpoint is only discovery data; the detail response must prove
    # exact identity, repository ownership, and an unambiguous main-only branch
    # scope. Equality is intentionally strict so wildcards and extra scope
    # selectors fail closed.
    if ! validate_live_identity_scope "$live_ruleset" "$repo"; then
      echo "  FAILED: live ruleset identity or main-only branch scope is invalid" >&2
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

    snapshot_file="$SNAPSHOT_ROOT/$repo-ruleset-$existing_id-pre.json"
    rollback_payload="$tmp_dir/$repo-$existing_id-rollback.json"
    post_readback="$tmp_dir/$repo-$existing_id-post-readback.json"
    if ! mkdir -p "$SNAPSHOT_ROOT" || [[ -e "$snapshot_file" ]]; then
      echo "  FAILED: durable snapshot path is unavailable or already exists: $snapshot_file" >&2
      fail=$((fail + 1))
      continue
    fi
    snapshot_tmp="$snapshot_file.tmp"
    if ! cp "$live_ruleset" "$snapshot_tmp" ||
        ! chmod 600 "$snapshot_tmp" ||
        ! mv "$snapshot_tmp" "$snapshot_file" ||
        ! sync "$snapshot_file"; then
      echo "  FAILED: could not persist durable pre-state snapshot" >&2
      fail=$((fail + 1))
      continue
    fi
    if ! write_mutable_payload "$snapshot_file" "$rollback_payload"; then
      echo "  FAILED: could not derive rollback payload from durable snapshot" >&2
      fail=$((fail + 1))
      continue
    fi
    echo "  Durable pre-state snapshot: $snapshot_file"

    echo "  Updating only enforcement and merge_queue (id: $existing_id)..."
    MUTATION_REPO=$repo
    MUTATION_RULESET_ID=$existing_id
    MUTATION_ROLLBACK_PAYLOAD=$rollback_payload
    MUTATION_SNAPSHOT=$snapshot_file
    MUTATION_ARMED=true
    if ! gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" \
        --input "$update_payload" > /dev/null; then
      rollback_and_abort "$repo" "$existing_id" "$rollback_payload" \
        "PUT failed or returned an ambiguous result" "$snapshot_file"
    fi

    if ! gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$post_readback"; then
      rollback_and_abort "$repo" "$existing_id" "$rollback_payload" \
        "post-PUT readback failed" "$snapshot_file"
    fi
    if ! validate_live_identity_scope "$post_readback" "$repo" ||
        ! exact_mutable_state_matches "$update_payload" "$post_readback"; then
      rollback_and_abort "$repo" "$existing_id" "$rollback_payload" \
        "post-PUT state did not match the exact requested postcondition" \
        "$snapshot_file"
    fi

    MUTATION_ARMED=false
    echo "  Verified exact postcondition; repository-specific contexts and unrelated rules preserved."
    ok=$((ok + 1))
  fi
done

echo ""
echo "Done: $ok succeeded, $fail failed"
if ((fail > 0)); then
  exit 1
fi
