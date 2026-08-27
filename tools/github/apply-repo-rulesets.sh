#!/usr/bin/env bash
set -Eeuo pipefail

# apply-repo-rulesets.sh [--active|--evaluate] [--repos repo1,repo2,...]
#                         [--all] [--dry-run] [--snapshot-dir path]
#                         [--evidence-file path]
# Reconciles an existing repository-owned homeric-main-baseline to the complete
# versioned fleet policy. The script never creates a missing baseline.
# Usage:
#   ./tools/github/apply-repo-rulesets.sh --active --all \
#     --evidence-file audit.json                             # exact fleet activation
#   ./tools/github/apply-repo-rulesets.sh --evaluate --all --dry-run  # no-write fleet preview
#   ./tools/github/apply-repo-rulesets.sh --evaluate --repos Staged \
#     --evidence-file audit.json                             # already-evaluate only
#   ./tools/github/apply-repo-rulesets.sh --repos Foo,Bar    # canonical mode, specific repos only
#   ./tools/github/apply-repo-rulesets.sh --dry-run --repos Foo

AGENT_CONTRACT_TAG="agent-contract-v1.0.0"
AGENT_CONTRACT_PATH="HomericIntelligence/Athena/.github/workflows/_agent-contract.yml"
AGENT_CONTRACT_TAG_SCOPE="refs/tags/agent-contract-v*"
MAX_EVIDENCE_AGE_SECONDS=86400
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
POLICY_FILE="${FLEET_RULESET_POLICY_FILE:-$REPO_ROOT/configs/github/fleet-ruleset-policy.json}"
POLICY_RENDERER="$SCRIPT_DIR/render-fleet-ruleset.py"

ENFORCEMENT=""
REPOS_OVERRIDE=""
DRY_RUN=false
ALL_REPOS=false
SNAPSHOT_DIR_OVERRIDE="${RULESET_SNAPSHOT_DIR:-}"
EVIDENCE_FILE=""

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
    --evidence-file)
      if [[ $# -lt 2 || -z "${2:-}" ]]; then
        echo "ERROR: --evidence-file requires a non-empty path" >&2
        exit 2
      fi
      EVIDENCE_FILE=$2
      shift 2
      ;;
    --evidence-file=*)
      EVIDENCE_FILE="${1#--evidence-file=}"
      if [[ -z "$EVIDENCE_FILE" ]]; then
        echo "ERROR: --evidence-file requires a non-empty path" >&2
        exit 2
      fi
      shift
      ;;
    *) echo "Unknown argument: $1" >&2; exit 2 ;;
  esac
done

tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT
POLICY_SOURCE_FILE=$POLICY_FILE
POLICY_SNAPSHOT_TMP="$tmp_dir/fleet-ruleset-policy.json.tmp"
POLICY_FILE="$tmp_dir/fleet-ruleset-policy.json"
if ! cp "$POLICY_SOURCE_FILE" "$POLICY_SNAPSHOT_TMP" ||
    ! chmod 600 "$POLICY_SNAPSHOT_TMP" ||
    ! mv "$POLICY_SNAPSHOT_TMP" "$POLICY_FILE" ||
    ! sync "$POLICY_FILE"; then
  echo "ERROR: could not seal canonical policy input: $POLICY_SOURCE_FILE" >&2
  exit 1
fi

if ! python3 "$POLICY_RENDERER" --policy-file "$POLICY_FILE" --check; then
  echo "ERROR: tracked ruleset artifacts do not match $POLICY_SOURCE_FILE" >&2
  exit 1
fi
ORG=$(jq -er '.organization | select(type == "string" and length > 0)' \
  "$POLICY_FILE")
RULESET_NAME=$(jq -er '.ruleset.name | select(type == "string" and length > 0)' \
  "$POLICY_FILE")

if [[ "$ENFORCEMENT" == "evaluate" ]]; then
  desired_enforcement=evaluate
  echo "Applying in EVALUATE (shadow) mode"
else
  desired_enforcement=active
  echo "Applying in ACTIVE (enforcing) mode"
fi

desired_ruleset=$(python3 "$POLICY_RENDERER" \
  --policy-file "$POLICY_FILE" --enforcement "$desired_enforcement")
desired_repository_settings=$(jq -c '.repository_settings' "$POLICY_FILE")

declare -a COMPLETED_REPOS=()
RECOVERY_STARTED=false
RECOVERY_VERIFIED=false
OPERATION_COMMITTED=false

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
      and ((keys_unsorted - [
        "_links",
        "bypass_actors",
        "conditions",
        "created_at",
        "current_user_can_bypass",
        "enforcement",
        "id",
        "name",
        "node_id",
        "rules",
        "source",
        "source_type",
        "target",
        "updated_at"
      ]) | length) == 0
      and .target == "branch"
      and .source_type == "Repository"
      and .source == $source
      and (
        .conditions == {
          ref_name: {
            include: ["refs/heads/main"],
            exclude: []
          }
        }
        or .conditions == {
          ref_name: {
            include: ["~DEFAULT_BRANCH"],
            exclude: []
          }
        }
      )
    ' "$ruleset_file" > /dev/null
}

write_mutable_payload() {
  local ruleset_file=$1
  local payload_file=$2
  jq -e '{name, target, enforcement, bypass_actors, conditions, rules}' \
    "$ruleset_file" >"$payload_file"
}

write_normalized_mutable_payload() {
  local ruleset_file=$1
  local payload_file=$2
  jq -e '{
    name,
    target,
    enforcement,
    bypass_actors: (.bypass_actors
      | sort_by(.actor_type, .actor_id, .bypass_mode)),
    conditions,
    rules: ([.rules[]
      | if .type == "required_status_checks"
        then .parameters.required_status_checks |=
          sort_by(.context, .integration_id)
        elif .type == "pull_request"
        then .parameters.allowed_merge_methods |= sort
          | .parameters.dismissal_restriction.allowed_actors |=
            sort_by(.type, .id)
          | .parameters.required_reviewers |= (
              map(.file_patterns |= sort)
              | sort_by(
                  .reviewer.type,
                  .reviewer.id,
                  .minimum_approvals,
                  (.file_patterns | join("\u0000"))
                )
            )
        else .
        end] | sort_by(.type))
  }' "$ruleset_file" >"$payload_file"
}

exact_mutable_state_matches() {
  local expected_payload=$1
  local actual_ruleset=$2
  jq -e --slurpfile expected "$expected_payload" '
    def normalized:
      {
        name,
        target,
        enforcement,
        bypass_actors: (.bypass_actors | sort_by(.actor_type, .actor_id, .bypass_mode)),
        conditions,
        rules: ([.rules[]
          | if .type == "required_status_checks"
            then .parameters.required_status_checks |= sort_by(.context, .integration_id)
            elif .type == "pull_request"
            then .parameters.allowed_merge_methods |= sort
              | .parameters.dismissal_restriction.allowed_actors |=
                sort_by(.type, .id)
              | .parameters.required_reviewers |= (
                  map(.file_patterns |= sort)
                  | sort_by(
                      .reviewer.type,
                      .reviewer.id,
                      .minimum_approvals,
                      (.file_patterns | join("\u0000"))
                    )
                )
            else .
            end] | sort_by(.type))
      };
    normalized == ($expected[0] | normalized)
  ' "$actual_ruleset" > /dev/null
}

write_repository_settings() {
  local repository_file=$1
  local settings_file=$2
  jq -e '{
    allow_auto_merge,
    allow_merge_commit,
    allow_rebase_merge,
    allow_squash_merge,
    allow_update_branch,
    delete_branch_on_merge,
    web_commit_signoff_required
  } | select(all(.[]; type == "boolean"))' "$repository_file" >"$settings_file"
}

exact_repository_settings_match() {
  local expected_file=$1
  local repository_file=$2
  local actual_file="$tmp_dir/repository-settings-actual-$$.json"
  if ! write_repository_settings "$repository_file" "$actual_file"; then
    return 1
  fi
  jq -e --slurpfile expected "$expected_file" '. == $expected[0]' \
    "$actual_file" >/dev/null
}

exact_repository_identity_matches() {
  local repo=$1
  local expected_default_branch=$2
  local repository_file=$3
  jq -e \
    --arg full_name "$ORG/$repo" \
    --arg default_branch "$expected_default_branch" '
      .full_name == $full_name
      and .default_branch == $default_branch
    ' "$repository_file" >/dev/null
}

read_exact_default_branch_sha() {
  local repo=$1
  local encoded_branch=$2
  local expected_branch=$3
  local expected_sha=$4
  local output_file=$5
  gh api "repos/$ORG/$repo/branches/$encoded_branch" >"$output_file" &&
    jq -e --arg branch "$expected_branch" --arg sha "$expected_sha" '
      .name == $branch and .commit.sha == $sha
    ' "$output_file" >/dev/null
}

json_sha256() {
  local json_file=$1
  jq -cS . "$json_file" | shasum -a 256 | awk '{print $1}'
}

write_classic_protection_payload() {
  local protection_file=$1
  local payload_file=$2
  jq -e '
    def reject_unknown($allowed; $label):
      . as $value
      | if ($value | type) != "object"
        then error($label + " is incomplete")
        elif ((($value | keys_unsorted) - $allowed) | length) != 0
        then error($label + " contains unknown fields")
        else $value
        end;
    def wrapped_enabled($label):
      reject_unknown(["enabled", "url"]; $label)
      | if (.enabled | type) == "boolean"
      then .enabled
      else error("classic protection boolean wrapper is incomplete")
      end;
    def actor_names($container; $collection; $field):
      if $container == null then []
      elif ($container | type) != "object"
      then error("classic actor container is incomplete")
      elif (($container
          | reject_unknown([
              "apps", "apps_url", "teams", "teams_url", "url", "users",
              "users_url"
            ]; "classic actor container"))[$collection] | type) != "array"
      then error("classic actor collection is incomplete")
      else [
        $container[$collection][]
        | if type == "object" and
            (.[$field] | type) == "string" and
            (.[$field] | length) > 0
          then .[$field]
          else error("classic actor identifier is incomplete")
          end
      ] | sort
      end;
    def required_boolean($object; $field):
      $object[$field]
      | if type == "boolean" then .
        else error("classic review boolean is incomplete")
        end;
    def required_review_count($object):
      $object.required_approving_review_count
      | if type == "number" and . == floor and . >= 0 and . <= 6 then .
        else error("classic review count is incomplete")
        end;
    def status_contexts:
      if type != "array" then error("classic status contexts are incomplete")
      else [
        .[]
        | if type == "string" and length > 0 then .
          else error("classic status context is incomplete")
          end
      ] | sort
      end;
    def status_checks:
      if type != "array" then error("classic status checks are incomplete")
      else [
        .[]
        | reject_unknown(["app_id", "context"]; "classic status check")
        | if (.context | type) != "string" or (.context | length) == 0
          then error("classic status check context is incomplete")
          elif (has("app_id") | not)
          then error("classic status check app_id is incomplete")
          elif .app_id == null
          then {context, app_id: -1}
          elif (.app_id | type) == "number" and .app_id == (.app_id | floor)
          then {context, app_id}
          else error("classic status check app_id is invalid")
          end
      ] | sort_by(.context, .app_id)
      end;
    reject_unknown([
      "allow_deletions",
      "allow_force_pushes",
      "allow_fork_syncing",
      "block_creations",
      "enforce_admins",
      "lock_branch",
      "required_conversation_resolution",
      "required_linear_history",
      "required_pull_request_reviews",
      "required_signatures",
      "required_status_checks",
      "restrictions",
      "url"
    ]; "classic protection")
    # GitHub omits disabled optional protection sections instead of returning
    # explicit null values. Missing required scalars inside a present section
    # still fail below; an omitted optional section has the documented null
    # restore meaning.
    | {
      required_status_checks: (
        if .required_status_checks == null then null
        else (.required_status_checks
          | reject_unknown([
              "checks", "contexts", "contexts_url", "strict", "url"
            ]; "classic required status checks")) as $status | {
          strict: (
            $status.strict
            | if type == "boolean" then .
              else error("classic status strictness is incomplete")
              end
          ),
          contexts: ($status.contexts | status_contexts),
          checks: ($status.checks | status_checks)
        }
        end
      ),
      enforce_admins: (.enforce_admins | wrapped_enabled("classic enforce_admins")),
      required_pull_request_reviews: (
        if .required_pull_request_reviews == null then null
        else (.required_pull_request_reviews
          | reject_unknown([
              "bypass_pull_request_allowances",
              "dismiss_stale_reviews",
              "dismissal_restrictions",
              "require_code_owner_reviews",
              "require_last_push_approval",
              "required_approving_review_count",
              "url"
            ]; "classic pull-request reviews")) as $reviews | {
          dismissal_restrictions: {
            users: actor_names(
              $reviews.dismissal_restrictions; "users"; "login"),
            teams: actor_names(
              $reviews.dismissal_restrictions; "teams"; "slug"),
            apps: actor_names(
              $reviews.dismissal_restrictions; "apps"; "slug")
          },
          dismiss_stale_reviews: required_boolean(
            $reviews; "dismiss_stale_reviews"),
          require_code_owner_reviews: required_boolean(
            $reviews; "require_code_owner_reviews"),
          required_approving_review_count: required_review_count($reviews),
          require_last_push_approval: required_boolean(
            $reviews; "require_last_push_approval"),
          bypass_pull_request_allowances: {
            users: actor_names(
              $reviews.bypass_pull_request_allowances; "users"; "login"),
            teams: actor_names(
              $reviews.bypass_pull_request_allowances; "teams"; "slug"),
            apps: actor_names(
              $reviews.bypass_pull_request_allowances; "apps"; "slug")
          }
        }
        end
      ),
      restrictions: (
        if .restrictions == null then null
        else {
          users: actor_names(.restrictions; "users"; "login"),
          teams: actor_names(.restrictions; "teams"; "slug"),
          apps: actor_names(.restrictions; "apps"; "slug")
        }
        end
      ),
      required_linear_history: (
        .required_linear_history | wrapped_enabled("classic linear history")),
      allow_force_pushes: (
        .allow_force_pushes | wrapped_enabled("classic force pushes")),
      allow_deletions: (
        .allow_deletions | wrapped_enabled("classic deletions")),
      block_creations: (
        .block_creations | wrapped_enabled("classic branch creation")),
      required_conversation_resolution:
        (.required_conversation_resolution
          | wrapped_enabled("classic conversation resolution")),
      lock_branch: (.lock_branch | wrapped_enabled("classic branch lock")),
      allow_fork_syncing: (
        .allow_fork_syncing | wrapped_enabled("classic fork syncing"))
    }
    | select(
        (.required_status_checks == null or (
          (.required_status_checks.strict | type) == "boolean"
          and (.required_status_checks.contexts | type) == "array"
          and all(.required_status_checks.contexts[];
            type == "string" and length > 0)
          and all(.required_status_checks.checks[];
            (.context | type) == "string"
            and (.context | length) > 0
            and ((has("app_id") | not) or (
              (.app_id | type) == "number"
              and .app_id == (.app_id | floor)
            )))
        ))
        and (.enforce_admins | type) == "boolean"
        and (.required_pull_request_reviews == null or (
          (.required_pull_request_reviews.dismiss_stale_reviews | type) == "boolean"
          and (.required_pull_request_reviews.require_code_owner_reviews | type) == "boolean"
          and (.required_pull_request_reviews.required_approving_review_count | type) == "number"
          and (.required_pull_request_reviews.require_last_push_approval | type) == "boolean"
        ))
        and all([
          .required_linear_history,
          .allow_force_pushes,
          .allow_deletions,
          .block_creations,
          .required_conversation_resolution,
          .lock_branch,
          .allow_fork_syncing
        ][]; type == "boolean")
      )
  ' "$protection_file" >"$payload_file"
}

classic_signatures_enabled() {
  local protection_file=$1
  jq -r '
    .required_signatures as $signatures
    | if ($signatures | type) == "object" and
        ((($signatures | keys_unsorted) - ["enabled", "url"]) | length) == 0 and
        ($signatures.enabled | type) == "boolean"
      then $signatures.enabled
      else error("classic signature response is incomplete")
      end
  ' "$protection_file"
}

exact_classic_protection_matches() {
  local expected_payload=$1
  local expected_signatures=$2
  local protection_file=$3
  local actual_payload="$tmp_dir/classic-protection-actual-$$.json"
  local actual_signatures
  if ! write_classic_protection_payload "$protection_file" "$actual_payload" ||
      ! actual_signatures=$(classic_signatures_enabled "$protection_file"); then
    return 1
  fi
  jq -e --slurpfile expected "$expected_payload" '. == $expected[0]' \
    "$actual_payload" >/dev/null &&
    [[ "$actual_signatures" == "$expected_signatures" ]]
}

classic_protection_payload_matches() {
  local expected_payload=$1
  local protection_file=$2
  local actual_payload="$tmp_dir/classic-protection-payload-actual-$$.json"
  if ! write_classic_protection_payload "$protection_file" "$actual_payload"; then
    return 1
  fi
  jq -e --slurpfile expected "$expected_payload" '. == $expected[0]' \
    "$actual_payload" >/dev/null
}

restore_classic_protection_from_snapshot() {
  local repo=$1
  local encoded_branch=$2
  local rollback_payload=$3
  local signatures_enabled=$4
  local readback="$tmp_dir/$repo-classic-rollback-readback.json"
  local error_file="$tmp_dir/$repo-classic-rollback-readback.err"
  local rollback_put_rc=0
  local signature_post_rc=0
  local live_signatures

  if gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
      >"$readback" 2>"$error_file"; then
    if exact_classic_protection_matches \
        "$rollback_payload" "$signatures_enabled" "$readback"; then
      echo "  Verified that classic-protection pre-state was already intact; no restore PUT was issued." >&2
      return 0
    fi
    echo "  WARNING: classic protection matches neither the absent requested state nor durable pre-state; refusing to overwrite it" >&2
    return 1
  elif ! grep -qF 'HTTP 404' "$error_file"; then
    echo "  WARNING: classic-protection state could not be classified" >&2
    return 1
  fi

  gh api -X PUT \
    "repos/$ORG/$repo/branches/$encoded_branch/protection" \
    --input "$rollback_payload" >/dev/null || rollback_put_rc=$?
  if ((rollback_put_rc != 0)); then
    echo "  WARNING: classic-protection rollback PUT reported exit $rollback_put_rc; verifying live state" >&2
  fi
  if ! gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
      >"$readback" 2>"$error_file" ||
      ! classic_protection_payload_matches "$rollback_payload" "$readback" ||
      ! live_signatures=$(classic_signatures_enabled "$readback"); then
    return 1
  fi
  if [[ "$live_signatures" == "$signatures_enabled" ]]; then
    return 0
  fi
  if [[ "$signatures_enabled" != true || "$live_signatures" != false ]]; then
    echo "  WARNING: classic-protection signature state matches neither the requested restore transition nor durable pre-state" >&2
    return 1
  fi

  gh api -X POST \
    "repos/$ORG/$repo/branches/$encoded_branch/protection/required_signatures" \
    >/dev/null || signature_post_rc=$?
  if ((signature_post_rc != 0)); then
    echo "  WARNING: classic-protection signature rollback POST reported exit $signature_post_rc; verifying live state" >&2
  fi
  gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
      >"$readback" 2>"$error_file" &&
    exact_classic_protection_matches \
      "$rollback_payload" "$signatures_enabled" "$readback"
}

rollback_completed_repositories() {
  local skip_repo=${1:-}
  local index repo existing_id
  local settings_payload settings_rollback ruleset_payload ruleset_rollback
  local default_branch encoded_branch classic_rollback classic_signatures
  local rollback_ok=true

  for ((index = ${#COMPLETED_REPOS[@]} - 1; index >= 0; index--)); do
    repo=${COMPLETED_REPOS[$index]}
    if [[ -n "$skip_repo" && "$repo" == "$skip_repo" ]]; then
      continue
    fi
    existing_id=${PLAN_RULESET_ID[$repo]}
    settings_payload=${PLAN_SETTINGS_PAYLOAD[$repo]}
    settings_rollback=${PLAN_SETTINGS_ROLLBACK[$repo]}
    ruleset_payload=${PLAN_UPDATE_PAYLOAD[$repo]}
    ruleset_rollback=${PLAN_RULESET_ROLLBACK[$repo]}
    default_branch=${PLAN_DEFAULT_BRANCH[$repo]}
    encoded_branch=$(jq -rn --arg value "$default_branch" '$value | @uri')
    classic_rollback=${PLAN_CLASSIC_ROLLBACK[$repo]}
    classic_signatures=${PLAN_CLASSIC_SIGNATURES[$repo]}

    if [[ "${PLAN_CLASSIC_PRESENT[$repo]}" == true ]] &&
        ! restore_classic_protection_from_snapshot "$repo" "$encoded_branch" \
          "$classic_rollback" "$classic_signatures"; then
      echo "  WARNING: fleet rollback could not verify $repo classic protection" >&2
      rollback_ok=false
    fi

    if [[ "${PLAN_SETTINGS_DRIFT[$repo]}" == true ]]; then
      if ! restore_settings_from_snapshot "$repo" "$settings_payload" \
          "$settings_rollback" true "$default_branch"; then
        echo "  WARNING: fleet rollback could not verify $repo repository settings" >&2
        rollback_ok=false
      fi
    fi

    if [[ "${PLAN_RULESET_DRIFT[$repo]}" == true ]]; then
      if ! restore_ruleset_from_snapshot "$repo" "$existing_id" \
          "$ruleset_payload" "$ruleset_rollback" true; then
        echo "  WARNING: fleet rollback could not verify $repo ruleset" >&2
        rollback_ok=false
      fi
    fi
  done

  [[ "$rollback_ok" == true ]]
}

restore_ruleset_from_snapshot() {
  local repo=$1
  local existing_id=$2
  local desired_payload=$3
  local rollback_payload=$4
  local ambiguous_write=$5
  local readback="$tmp_dir/$repo-$existing_id-rollback-readback.json"
  local rollback_put_rc=0

  if [[ "$ambiguous_write" == true ]]; then
    if ! gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$readback" ||
        ! validate_live_identity_scope "$readback" "$repo"; then
      echo "  WARNING: ambiguous ruleset state could not be classified" >&2
      return 1
    fi
    if exact_mutable_state_matches "$rollback_payload" "$readback"; then
      echo "  Verified that the ruleset pre-state was already intact; no rollback PUT was issued." >&2
      return 0
    fi
    if ! exact_mutable_state_matches "$desired_payload" "$readback"; then
      echo "  WARNING: ambiguous ruleset state matches neither the pre-state nor requested state; refusing to overwrite it" >&2
      return 1
    fi
  fi

  gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" \
    --input "$rollback_payload" >/dev/null || rollback_put_rc=$?
  if ((rollback_put_rc != 0)); then
    echo "  WARNING: rollback PUT reported exit $rollback_put_rc; verifying live state" >&2
  fi
  gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$readback" &&
    validate_live_identity_scope "$readback" "$repo" &&
    exact_mutable_state_matches "$rollback_payload" "$readback"
}

restore_settings_from_snapshot() {
  local repo=$1
  local desired_payload=$2
  local rollback_payload=$3
  local ambiguous_write=$4
  local expected_default_branch=${5:-${PLAN_DEFAULT_BRANCH[$repo]:-}}
  local readback="$tmp_dir/$repo-settings-rollback-readback.json"
  local rollback_patch_rc=0

  if [[ -z "$expected_default_branch" ]]; then
    echo "  WARNING: repository-settings rollback lacks a bound default branch" >&2
    return 1
  fi

  if [[ "$ambiguous_write" == true ]]; then
    if ! gh api "repos/$ORG/$repo" >"$readback" ||
        ! exact_repository_identity_matches \
          "$repo" "$expected_default_branch" "$readback"; then
      echo "  WARNING: ambiguous repository-settings state could not be classified" >&2
      return 1
    fi
    if exact_repository_settings_match "$rollback_payload" "$readback"; then
      echo "  Verified that the repository-settings pre-state was already intact; no rollback PATCH was issued." >&2
      return 0
    fi
    if ! exact_repository_settings_match "$desired_payload" "$readback"; then
      echo "  WARNING: ambiguous repository-settings state matches neither the pre-state nor requested state; refusing to overwrite it" >&2
      return 1
    fi
  fi

  gh api -X PATCH "repos/$ORG/$repo" \
    --input "$rollback_payload" >/dev/null || rollback_patch_rc=$?
  if ((rollback_patch_rc != 0)); then
    echo "  WARNING: repository-settings rollback PATCH reported exit $rollback_patch_rc; verifying live state" >&2
  fi
  gh api "repos/$ORG/$repo" >"$readback" &&
    exact_repository_identity_matches \
      "$repo" "$expected_default_branch" "$readback" &&
    exact_repository_settings_match "$rollback_payload" "$readback"
}

abort_on_changed_precondition() {
  local repo=$1
  local resource=$2
  local fleet_rollback_ok=false

  RECOVERY_STARTED=true
  trap '' HUP INT TERM PIPE
  MUTATION_ARMED=false
  echo "  FAILED: $repo $resource precondition changed after fleet preflight; refusing to write" >&2
  if rollback_completed_repositories "$repo"; then
    fleet_rollback_ok=true
    echo "  Fleet rollback verified exactly; aborting this operation." >&2
  fi
  if [[ "$fleet_rollback_ok" != true ]]; then
    echo "  UNCERTAIN MUTATION: earlier completed repositories could not be rolled back exactly." >&2
  fi
  exit 1
}

rollback_and_abort() {
  local repo=$1
  local existing_id=$2
  local desired_payload=$3
  local rollback_payload=$4
  local reason=$5
  local snapshot_file=$6
  local ambiguous_write=$7
  local current_rollback_ok=false
  local fleet_rollback_ok=false

  RECOVERY_STARTED=true
  trap '' HUP INT TERM PIPE
  MUTATION_ARMED=false
  echo "  FAILED: $reason; attempting rollback from durable pre-state" >&2
  if restore_ruleset_from_snapshot "$repo" "$existing_id" \
      "$desired_payload" "$rollback_payload" "$ambiguous_write"; then
    current_rollback_ok=true
    echo "  Rollback verified exactly for $repo ruleset." >&2
  fi
  if rollback_completed_repositories "$repo"; then
    fleet_rollback_ok=true
  fi
  if [[ "$current_rollback_ok" == true && "$fleet_rollback_ok" == true ]]; then
    echo "  Fleet rollback verified exactly; aborting this operation." >&2
    exit 1
  fi

  echo "  UNCERTAIN MUTATION: rollback could not be verified exactly for $repo ruleset $existing_id." >&2
  echo "  Durable recovery snapshot: $snapshot_file" >&2
  exit 1
}

rollback_settings_and_ruleset_abort() {
  local repo=$1
  local settings_desired_payload=$2
  local settings_rollback_payload=$3
  local settings_snapshot=$4
  local settings_write_ambiguous=$5
  local ruleset_changed=$6
  local existing_id=$7
  local ruleset_desired_payload=$8
  local ruleset_rollback_payload=$9
  local ruleset_snapshot=${10}
  local reason=${11}
  local current_rollback_ok=true
  local fleet_rollback_ok=false

  RECOVERY_STARTED=true
  trap '' HUP INT TERM PIPE
  MUTATION_ARMED=false
  echo "  FAILED: $reason; rolling back repository state" >&2
  if ! restore_settings_from_snapshot "$repo" "$settings_desired_payload" \
      "$settings_rollback_payload" "$settings_write_ambiguous"; then
    current_rollback_ok=false
    echo "  WARNING: repository-settings rollback could not be verified" >&2
  fi

  if [[ "$ruleset_changed" == true ]] &&
      ! restore_ruleset_from_snapshot "$repo" "$existing_id" \
        "$ruleset_desired_payload" "$ruleset_rollback_payload" true; then
    current_rollback_ok=false
    echo "  WARNING: ruleset rollback could not be verified" >&2
  fi

  if [[ "$current_rollback_ok" == true ]]; then
    echo "  Rollback verified exactly for $repo repository settings and ruleset." >&2
  fi
  if rollback_completed_repositories "$repo"; then
    fleet_rollback_ok=true
  fi
  if [[ "$current_rollback_ok" == true && "$fleet_rollback_ok" == true ]]; then
    echo "  Fleet rollback verified exactly; aborting this operation." >&2
    exit 1
  fi
  echo "  UNCERTAIN MUTATION: combined rollback could not be verified for $repo." >&2
  echo "  Durable recovery snapshots: $settings_snapshot $ruleset_snapshot" >&2
  exit 1
}

rollback_classic_transaction_abort() {
  local reason=$1
  local current_rollback_ok=true
  local fleet_rollback_ok=false

  RECOVERY_STARTED=true
  trap '' HUP INT TERM PIPE
  MUTATION_ARMED=false
  echo "  FAILED: $reason; rolling back classic protection and earlier repository writes" >&2
  if ! restore_classic_protection_from_snapshot \
      "$MUTATION_REPO" "$MUTATION_ENCODED_BRANCH" \
      "$MUTATION_CLASSIC_ROLLBACK_PAYLOAD" \
      "$MUTATION_CLASSIC_SIGNATURES"; then
    current_rollback_ok=false
    echo "  WARNING: classic-protection rollback could not be verified" >&2
  fi
  if [[ "$MUTATION_SETTINGS_CHANGED" == true ]] &&
      ! restore_settings_from_snapshot \
        "$MUTATION_REPO" "$MUTATION_SETTINGS_PAYLOAD" \
        "$MUTATION_SETTINGS_ROLLBACK_PAYLOAD" true; then
    current_rollback_ok=false
    echo "  WARNING: repository-settings rollback could not be verified" >&2
  fi
  if [[ "$MUTATION_RULESET_CHANGED" == true ]] &&
      ! restore_ruleset_from_snapshot \
        "$MUTATION_REPO" "$MUTATION_RULESET_ID" \
        "$MUTATION_UPDATE_PAYLOAD" "$MUTATION_ROLLBACK_PAYLOAD" true; then
    current_rollback_ok=false
    echo "  WARNING: ruleset rollback could not be verified" >&2
  fi
  if rollback_completed_repositories "$MUTATION_REPO"; then
    fleet_rollback_ok=true
  fi
  if [[ "$current_rollback_ok" == true && "$fleet_rollback_ok" == true ]]; then
    echo "  Fleet rollback verified exactly; aborting this operation." >&2
    exit 1
  fi
  echo "  UNCERTAIN MUTATION: classic-protection transaction rollback could not be verified exactly." >&2
  echo "  Durable recovery snapshots: $MUTATION_SNAPSHOT $MUTATION_SETTINGS_SNAPSHOT $MUTATION_CLASSIC_SNAPSHOT" >&2
  exit 1
}

abort_current_transaction() {
  local reason=$1
  if [[ "$MUTATION_ARMED" != true ]]; then
    abort_on_changed_precondition "$MUTATION_REPO" "$reason"
  fi
  case "$MUTATION_KIND" in
    classic)
      rollback_classic_transaction_abort "$reason"
      ;;
    settings)
      rollback_settings_and_ruleset_abort \
        "$MUTATION_REPO" \
        "$MUTATION_SETTINGS_PAYLOAD" \
        "$MUTATION_SETTINGS_ROLLBACK_PAYLOAD" \
        "$MUTATION_SETTINGS_SNAPSHOT" \
        true \
        "$MUTATION_RULESET_CHANGED" \
        "$MUTATION_RULESET_ID" \
        "$MUTATION_UPDATE_PAYLOAD" \
        "$MUTATION_ROLLBACK_PAYLOAD" \
        "$MUTATION_SNAPSHOT" \
        "$reason"
      ;;
    ruleset)
      rollback_and_abort \
        "$MUTATION_REPO" \
        "$MUTATION_RULESET_ID" \
        "$MUTATION_UPDATE_PAYLOAD" \
        "$MUTATION_ROLLBACK_PAYLOAD" \
        "$reason" \
        "$MUTATION_SNAPSHOT" \
        true
      ;;
    *)
      echo "  UNCERTAIN MUTATION: cannot abort unknown mutation kind: $MUTATION_KIND" >&2
      exit 1
      ;;
  esac
}

MUTATION_ARMED=false
MUTATION_REPO=""
MUTATION_RULESET_ID=""
MUTATION_UPDATE_PAYLOAD=""
MUTATION_ROLLBACK_PAYLOAD=""
MUTATION_SNAPSHOT=""
MUTATION_KIND="ruleset"
MUTATION_SETTINGS_PAYLOAD=""
MUTATION_SETTINGS_ROLLBACK_PAYLOAD=""
MUTATION_SETTINGS_SNAPSHOT=""
MUTATION_RULESET_CHANGED=false
MUTATION_SETTINGS_CHANGED=false
MUTATION_CLASSIC_ROLLBACK_PAYLOAD=""
MUTATION_CLASSIC_SIGNATURES=false
MUTATION_CLASSIC_SNAPSHOT=""
MUTATION_ENCODED_BRANCH=""

handle_mutation_signal() {
  local signal_name=$1
  local exit_status=$2
  if [[ "$OPERATION_COMMITTED" == true ]]; then
    trap '' HUP INT TERM PIPE
    exit "$exit_status"
  fi
  RECOVERY_STARTED=true
  trap '' HUP INT TERM PIPE
  if [[ "$MUTATION_ARMED" == true ]]; then
    echo "  UNCERTAIN MUTATION: received $signal_name during an armed mutation; live state is ambiguous until rollback verification completes." >&2
    if [[ "$MUTATION_KIND" == classic ]]; then
      rollback_classic_transaction_abort \
        "received $signal_name during an armed classic-protection mutation"
    elif [[ "$MUTATION_KIND" == settings ]]; then
      rollback_settings_and_ruleset_abort \
        "$MUTATION_REPO" \
        "$MUTATION_SETTINGS_PAYLOAD" \
        "$MUTATION_SETTINGS_ROLLBACK_PAYLOAD" \
        "$MUTATION_SETTINGS_SNAPSHOT" \
        true \
        "$MUTATION_RULESET_CHANGED" \
        "$MUTATION_RULESET_ID" \
        "$MUTATION_UPDATE_PAYLOAD" \
        "$MUTATION_ROLLBACK_PAYLOAD" \
        "$MUTATION_SNAPSHOT" \
        "received $signal_name during an armed repository-settings mutation"
    else
      rollback_and_abort \
        "$MUTATION_REPO" \
        "$MUTATION_RULESET_ID" \
        "$MUTATION_UPDATE_PAYLOAD" \
        "$MUTATION_ROLLBACK_PAYLOAD" \
        "received $signal_name during an armed mutation" \
        "$MUTATION_SNAPSHOT" \
        true
    fi
  elif (( ${#COMPLETED_REPOS[@]} > 0 )); then
    echo "  UNCERTAIN MUTATION: received $signal_name after completed fleet writes; compensating completed repositories." >&2
    if rollback_completed_repositories; then
      echo "  Fleet rollback verified exactly after $signal_name." >&2
      exit "$exit_status"
    fi
    echo "  UNCERTAIN MUTATION: fleet rollback after $signal_name could not be verified." >&2
  fi
  exit "$exit_status"
}

compensate_current_and_completed() {
  local current_rollback_ok=true
  local fleet_rollback_ok=false
  local skip_repo=""

  RECOVERY_STARTED=true
  trap '' HUP INT TERM PIPE
  if [[ "$MUTATION_ARMED" == true ]]; then
    skip_repo=$MUTATION_REPO
    case "$MUTATION_KIND" in
      classic)
        if ! restore_classic_protection_from_snapshot \
            "$MUTATION_REPO" "$MUTATION_ENCODED_BRANCH" \
            "$MUTATION_CLASSIC_ROLLBACK_PAYLOAD" \
            "$MUTATION_CLASSIC_SIGNATURES"; then
          current_rollback_ok=false
        fi
        if [[ "$MUTATION_SETTINGS_CHANGED" == true ]] &&
            ! restore_settings_from_snapshot \
              "$MUTATION_REPO" "$MUTATION_SETTINGS_PAYLOAD" \
              "$MUTATION_SETTINGS_ROLLBACK_PAYLOAD" true; then
          current_rollback_ok=false
        fi
        if [[ "$MUTATION_RULESET_CHANGED" == true ]] &&
            ! restore_ruleset_from_snapshot \
              "$MUTATION_REPO" "$MUTATION_RULESET_ID" \
              "$MUTATION_UPDATE_PAYLOAD" "$MUTATION_ROLLBACK_PAYLOAD" \
              true; then
          current_rollback_ok=false
        fi
        ;;
      settings)
        if ! restore_settings_from_snapshot \
            "$MUTATION_REPO" "$MUTATION_SETTINGS_PAYLOAD" \
            "$MUTATION_SETTINGS_ROLLBACK_PAYLOAD" true; then
          current_rollback_ok=false
        fi
        if [[ "$MUTATION_RULESET_CHANGED" == true ]] &&
            ! restore_ruleset_from_snapshot \
              "$MUTATION_REPO" "$MUTATION_RULESET_ID" \
              "$MUTATION_UPDATE_PAYLOAD" "$MUTATION_ROLLBACK_PAYLOAD" \
              true; then
          current_rollback_ok=false
        fi
        ;;
      ruleset)
        if ! restore_ruleset_from_snapshot \
            "$MUTATION_REPO" "$MUTATION_RULESET_ID" \
            "$MUTATION_UPDATE_PAYLOAD" "$MUTATION_ROLLBACK_PAYLOAD" true; then
          current_rollback_ok=false
        fi
        ;;
      *)
        echo "  WARNING: unexpected mutation kind cannot be compensated safely: $MUTATION_KIND" >&2
        current_rollback_ok=false
        ;;
    esac
  fi

  if rollback_completed_repositories "$skip_repo"; then
    fleet_rollback_ok=true
  fi
  if [[ "$current_rollback_ok" == true && "$fleet_rollback_ok" == true ]]; then
    RECOVERY_VERIFIED=true
    return 0
  fi
  return 1
}

record_unexpected_error() {
  local exit_status=$1
  local line_number=$2
  if [[ "$RECOVERY_STARTED" != true ]]; then
    echo "  ERROR: unexpected command failure at line $line_number (exit $exit_status); EXIT recovery will classify live state." >&2
  fi
}

handle_unexpected_exit() {
  local exit_status=$1
  local recovery_needed=false

  trap - EXIT ERR
  trap '' HUP INT TERM PIPE
  set +e
  if [[ "$OPERATION_COMMITTED" != true && "$RECOVERY_STARTED" != true ]] &&
      { [[ "$MUTATION_ARMED" == true ]] ||
        (( ${#COMPLETED_REPOS[@]} > 0 )); }; then
    recovery_needed=true
    echo "  UNCERTAIN MUTATION: unexpected exit before fleet commit; compensating all completed or armed writes." >&2
    if compensate_current_and_completed; then
      echo "  Unexpected exit recovery verified exactly." >&2
    else
      echo "  UNCERTAIN MUTATION: unexpected exit recovery could not be verified exactly." >&2
      exit_status=1
    fi
  fi
  rm -rf "$tmp_dir"
  if [[ "$recovery_needed" == true && "$exit_status" -eq 0 ]]; then
    exit_status=1
  fi
  exit "$exit_status"
}

trap - EXIT
trap 'handle_unexpected_exit $?' EXIT
trap 'record_unexpected_error $? $LINENO' ERR
trap 'handle_mutation_signal HUP 129' HUP
trap 'handle_mutation_signal INT 130' INT
trap 'handle_mutation_signal TERM 143' TERM
trap 'handle_mutation_signal PIPE 141' PIPE

if [[ -n "$REPOS_OVERRIDE" && "$ALL_REPOS" == true ]]; then
  echo "ERROR: use either --repos or --all, not both" >&2
  exit 2
elif [[ -n "$REPOS_OVERRIDE" ]]; then
  IFS=',' read -ra REPOS <<< "$REPOS_OVERRIDE"
  echo "Targeting ${#REPOS[@]} repo(s) from --repos override: ${REPOS[*]}"
elif [[ "$ALL_REPOS" == true ]]; then
  mapfile -t expected_repos < <(jq -r '.repositories[]' "$POLICY_FILE")
  mapfile -t discovered_repos < <(gh repo list "$ORG" --json name,isFork,isArchived --limit 100 \
    --jq '[.[] | select(.isFork == false and .isArchived == false) | .name] | sort | .[]')
  if [[ "${discovered_repos[*]}" != "${expected_repos[*]}" ]]; then
    echo "ERROR: active first-party inventory differs from Odysseus plus .gitmodules" >&2
    printf '  expected: %s\n  actual:   %s\n' \
      "${expected_repos[*]}" "${discovered_repos[*]}" >&2
    exit 1
  fi
  REPOS=("${expected_repos[@]}")
  echo "Verified exact ${#REPOS[@]}-repository fleet inventory"
else
  echo "ERROR: target scope is required; pass --repos <names> or explicit --all" >&2
  exit 2
fi

if [[ ${#REPOS[@]} -eq 0 ]]; then
  echo "ERROR: no repos resolved (gh API failure or --repos was empty)" >&2
  exit 1
fi

declare -A seen_repos=()
for repo in "${REPOS[@]}"; do
  if ! jq -e --arg repo "$repo" '.repositories | index($repo) != null' \
      "$POLICY_FILE" >/dev/null; then
    echo "ERROR: repository is outside the canonical first-party fleet: $repo" >&2
    exit 2
  fi
  if [[ -n "${seen_repos[$repo]:-}" ]]; then
    echo "ERROR: duplicate repository target: $repo" >&2
    exit 2
  fi
  seen_repos[$repo]=1
done

required_producer_blob_at_sha() {
  local repo=$1
  local commit_sha=$2
  local label=$3
  local expected_blob=${4:-}
  local git_commit_file="$tmp_dir/$repo-$label-git-commit.json"
  local git_tree_file="$tmp_dir/$repo-$label-git-tree.json"
  local tree_sha

  if ! gh api "repos/$ORG/$repo/git/commits/$commit_sha" \
      >"$git_commit_file" ||
      ! tree_sha=$(jq -er --arg sha "$commit_sha" '
        select(.sha == $sha)
        | .tree.sha
        | select(type == "string" and test("^[0-9a-f]{40}$"))
      ' "$git_commit_file") ||
      ! gh api "repos/$ORG/$repo/git/trees/$tree_sha?recursive=1" \
        >"$git_tree_file"; then
    return 1
  fi

  jq -er --arg tree_sha "$tree_sha" --arg expected_blob "$expected_blob" '
    [.tree[]
      | select(.path == ".github/workflows/_required.yml")
      | select(.type == "blob")] as $required
    | select(.sha == $tree_sha)
    | select(.truncated == false)
    | select((.tree | type) == "array")
    | select(($required | length) == 1)
    | select([.tree[]
        | select(.path == ".github/workflows/merge-queue-smoke.yml")]
        | length == 0)
    | $required[0].sha
    | select(type == "string" and test("^[0-9a-f]{40}$"))
    | select($expected_blob == "" or . == $expected_blob)
  ' "$git_tree_file"
}

verify_github_evidence() {
  local repo=$1
  local repository_file="$tmp_dir/$repo-repository.json"
  local branch_file="$tmp_dir/$repo-default-branch.json"
  local default_branch encoded_branch current_sha current_producer_blob
  local proof_name expected_event run_id attempt_number evidence_sha run_url
  local proof_producer_blob
  local run_file jobs_file checks_file check_suite_id
  local pull_request_jobs_file=""
  local merge_group_jobs_file=""

  if ! gh api "repos/$ORG/$repo" >"$repository_file"; then
    echo "ERROR: GitHub evidence verification failed for $repo: repository read failed" >&2
    return 1
  fi
  if ! default_branch=$(jq -er --arg full_name "$ORG/$repo" '
      select(.full_name == $full_name)
      | .default_branch
      | select(type == "string" and length > 0)
    ' "$repository_file"); then
    echo "ERROR: GitHub evidence verification failed for $repo: repository identity is incomplete" >&2
    return 1
  fi
  encoded_branch=$(jq -rn --arg value "$default_branch" '$value | @uri')
  if ! gh api "repos/$ORG/$repo/branches/$encoded_branch" >"$branch_file"; then
    echo "ERROR: GitHub evidence verification failed for $repo: default branch read failed" >&2
    return 1
  fi
  if ! current_sha=$(jq -er --arg branch "$default_branch" '
      select(.name == $branch)
      | .commit.sha
      | select(type == "string" and length > 0)
    ' "$branch_file"); then
    echo "ERROR: GitHub evidence verification failed for $repo: default branch response is incomplete" >&2
    return 1
  fi
  if ! jq -e --arg repo "$repo" --arg sha "$current_sha" '
      .repositories[$repo].main_sha == $sha
      and .repositories[$repo].main.sha == $sha
    ' "$EVIDENCE_FILE" >/dev/null; then
    echo "ERROR: GitHub evidence verification failed for $repo: default branch SHA is stale" >&2
    return 1
  fi
  if ! current_producer_blob=$(required_producer_blob_at_sha \
      "$repo" "$current_sha" main); then
    echo "ERROR: GitHub evidence verification failed for $repo: required producer tree or smoke-workflow absence mismatch" >&2
    return 1
  fi

  while IFS=: read -r proof_name expected_event; do
    if ! run_id=$(jq -er --arg repo "$repo" --arg proof "$proof_name" '
        .repositories[$repo][$proof].run_id
        | select(type == "number" and . > 0 and . == floor)
      ' "$EVIDENCE_FILE") ||
        ! attempt_number=$(jq -er --arg repo "$repo" --arg proof "$proof_name" '
          .repositories[$repo][$proof].attempt_number
          | select(type == "number" and . > 0 and . == floor)
        ' "$EVIDENCE_FILE") ||
        ! evidence_sha=$(jq -er --arg repo "$repo" --arg proof "$proof_name" '
          .repositories[$repo][$proof].sha
          | select(type == "string" and length > 0)
        ' "$EVIDENCE_FILE") ||
        ! run_url=$(jq -er --arg repo "$repo" --arg proof "$proof_name" '
          .repositories[$repo][$proof].run_url
          | select(type == "string" and length > 0)
        ' "$EVIDENCE_FILE"); then
      echo "ERROR: GitHub evidence verification failed for $repo: $proof_name proof is incomplete" >&2
      return 1
    fi
    if ! proof_producer_blob=$(required_producer_blob_at_sha \
        "$repo" "$evidence_sha" "$proof_name" "$current_producer_blob"); then
      echo "ERROR: GitHub evidence verification failed for $repo: $proof_name producer blob differs from current main or contains smoke" >&2
      return 1
    fi

    run_file="$tmp_dir/$repo-$proof_name-run.json"
    jobs_file="$tmp_dir/$repo-$proof_name-jobs.json"
    checks_file="$tmp_dir/$repo-$proof_name-checks.json"
    if ! gh api \
        "repos/$ORG/$repo/actions/runs/$run_id/attempts/$attempt_number" \
        >"$run_file"; then
      echo "ERROR: GitHub evidence verification failed for $repo: $proof_name run read failed" >&2
      return 1
    fi
    if ! jq -e \
        --argjson run_id "$run_id" \
        --argjson attempt "$attempt_number" \
        --arg full_name "$ORG/$repo" \
        --arg event "$expected_event" \
        --arg sha "$evidence_sha" \
        --arg url "$run_url" \
        --arg proof "$proof_name" \
        --arg default_branch "$default_branch" \
        --arg agent_contract_path "$AGENT_CONTRACT_PATH" \
        --arg agent_contract_sha "$AGENT_CONTRACT_SHA" \
        --argjson observed_epoch "$EVIDENCE_OBSERVED_EPOCH" \
        --argjson max_age "$MAX_EVIDENCE_AGE_SECONDS" '
      .id == $run_id
      and .run_attempt == $attempt
      and (.workflow_id | type) == "number"
      and .workflow_id > 0
      and .repository.full_name == $full_name
      and .name == "Required Checks"
      and (.path | test("^\\.github/workflows/_required\\.yml(@[^[:cntrl:]]+)?$"))
      and .event == $event
      and .status == "completed"
      and .conclusion == "success"
      and .head_sha == $sha
      and .html_url == $url
      and (.created_at | fromdateiso8601) <=
        (.updated_at | fromdateiso8601)
      and (.updated_at | fromdateiso8601) <= $observed_epoch
      and ($observed_epoch - (.updated_at | fromdateiso8601)) <= $max_age
      and (.check_suite_id | type) == "number"
      and .check_suite_id > 0
      and (.referenced_workflows | type) == "array"
      and ([.referenced_workflows[]
        | select(.path ==
          ($agent_contract_path + "@" + $agent_contract_sha))
        | select(.sha == $agent_contract_sha)
        | select((has("ref") | not) or .ref == null)] | length) == 1
      and (
        if $proof == "main"
        then .head_branch == $default_branch
        elif $proof == "merge_group"
        then (.head_branch | startswith("gh-readonly-queue/" + $default_branch + "/"))
        else (.head_branch | type == "string" and length > 0)
        end
      )
    ' "$run_file" >/dev/null; then
      echo "ERROR: GitHub evidence verification failed for $repo: $proof_name run identity or result mismatch" >&2
      return 1
    fi
    check_suite_id=$(jq -r '.check_suite_id' "$run_file")

    jobs_pages="$jobs_file.pages"
    if ! gh api --paginate --slurp \
        "repos/$ORG/$repo/actions/runs/$run_id/attempts/$attempt_number/jobs?filter=all&per_page=100" \
        >"$jobs_pages" ||
        ! jq -e '
          select(type == "array" and length > 0)
          | select(all(.[];
              type == "object"
              and (.total_count | type) == "number"
              and (.jobs | type) == "array"))
          | {
              total_count: .[0].total_count,
              jobs: [.[].jobs[]]
            }
          | select(.total_count == (.jobs | length))
        ' "$jobs_pages" >"$jobs_file" ||
        ! jq -e --argjson run_id "$run_id" --argjson attempt "$attempt_number" '
          select((.total_count | type) == "number" and .total_count > 0)
          | select((.jobs | type) == "array")
          | [.jobs[] | select(.name == "required-checks-gate")] as $gates
          | all(.jobs[];
              (.name | type) == "string"
              and (.name | test("\\S"))
              and .run_id == $run_id
              and .run_attempt == $attempt
              and .status == "completed"
              and (.conclusion == "success"
                or .conclusion == "failure"
                or .conclusion == "neutral"
                or .conclusion == "cancelled"
                or .conclusion == "skipped"
                or .conclusion == "timed_out"
                or .conclusion == "action_required"
                or .conclusion == "stale"))
          and ($gates | length) == 1
          and $gates[0].run_id == $run_id
          and $gates[0].run_attempt == $attempt
          and $gates[0].status == "completed"
          and $gates[0].conclusion == "success"
        ' "$jobs_file" >/dev/null; then
      echo "ERROR: GitHub evidence verification failed for $repo: $proof_name aggregate job mismatch" >&2
      return 1
    fi

    checks_pages="$checks_file.pages"
    if ! gh api --paginate --slurp \
        "repos/$ORG/$repo/check-suites/$check_suite_id/check-runs?check_name=required-checks-gate&filter=latest&per_page=100" \
        >"$checks_pages" ||
        ! jq -e '
          select(type == "array" and length > 0)
          | select(all(.[];
              type == "object"
              and (.total_count | type) == "number"
              and (.check_runs | type) == "array"))
          | {
              total_count: .[0].total_count,
              check_runs: [.[].check_runs[]]
            }
          | select(.total_count == (.check_runs | length))
        ' "$checks_pages" >"$checks_file" ||
        ! jq -e --argjson check_suite_id "$check_suite_id" --arg sha "$evidence_sha" '
          .total_count == 1
          and (.check_runs | type) == "array"
          and (.check_runs | length) == 1
          and .check_runs[0].name == "required-checks-gate"
          and .check_runs[0].status == "completed"
          and .check_runs[0].conclusion == "success"
          and .check_runs[0].head_sha == $sha
          and .check_runs[0].check_suite.id == $check_suite_id
          and .check_runs[0].app.id == 15368
        ' "$checks_file" >/dev/null; then
      echo "ERROR: GitHub evidence verification failed for $repo: $proof_name aggregate check mismatch" >&2
      return 1
    fi
    if [[ "$proof_name" == pull_request ]]; then
      pull_request_jobs_file=$jobs_file
    elif [[ "$proof_name" == merge_group ]]; then
      merge_group_jobs_file=$jobs_file
    fi
  done <<'EOF'
pull_request:pull_request
merge_group:merge_group
main:push
EOF

  if [[ -z "$pull_request_jobs_file" || -z "$merge_group_jobs_file" ]] ||
      ! jq -e --slurpfile pull_request "$pull_request_jobs_file" '
        def job_results:
          [.jobs[] | {name, status, conclusion}]
          | sort_by(.name, .status, .conclusion);
        .total_count == $pull_request[0].total_count
        and job_results == ($pull_request[0] | job_results)
      ' "$merge_group_jobs_file" >/dev/null; then
    echo "ERROR: GitHub evidence verification failed for $repo: pull-request and merge-group job/result parity mismatch" >&2
    return 1
  fi
}

resolve_protected_agent_contract_release() {
  local tag_ref_file="$tmp_dir/athena-agent-contract-tag-ref.json"
  local tag_file="$tmp_dir/athena-agent-contract-tag.json"
  local commit_file="$tmp_dir/athena-agent-contract-commit.json"
  local ruleset_pages="$tmp_dir/athena-agent-contract-rulesets.pages"
  local ruleset_list="$tmp_dir/athena-agent-contract-rulesets.json"
  local ruleset_detail="$tmp_dir/athena-agent-contract-tag-ruleset.json"
  local tag_object_sha commit_sha
  local tag_ruleset_ids=()

  if ! gh api \
      "repos/$ORG/Athena/git/ref/tags/$AGENT_CONTRACT_TAG" \
      >"$tag_ref_file" ||
      ! tag_object_sha=$(jq -er --arg ref "refs/tags/$AGENT_CONTRACT_TAG" '
        select(.ref == $ref)
        | select(.object.type == "tag")
        | .object.sha
        | select(type == "string" and test("^[0-9a-f]{40}$"))
      ' "$tag_ref_file") ||
      ! gh api "repos/$ORG/Athena/git/tags/$tag_object_sha" >"$tag_file" ||
      ! commit_sha=$(jq -er \
        --arg tag "$AGENT_CONTRACT_TAG" \
        --arg tag_object_sha "$tag_object_sha" '
          select(.sha == $tag_object_sha)
          | select(.tag == $tag)
          | select(.object.type == "commit")
          | select(.verification.verified == true)
          | .object.sha
          | select(type == "string" and test("^[0-9a-f]{40}$"))
        ' "$tag_file") ||
      ! gh api "repos/$ORG/Athena/commits/$commit_sha" >"$commit_file" ||
      ! jq -e --arg sha "$commit_sha" '
        .sha == $sha
        and .commit.verification.verified == true
      ' "$commit_file" >/dev/null; then
    return 1
  fi

  if ! gh api --paginate --slurp \
      "repos/$ORG/Athena/rulesets?includes_parents=true&per_page=100" \
      >"$ruleset_pages" ||
      ! jq -e '
        select(type == "array" and all(.[]; type == "array"))
        | [ .[][] ]
      ' "$ruleset_pages" >"$ruleset_list" ||
      ! jq -e '
        type == "array"
        and all(.[];
          (.id | type) == "number"
          and (.name | type) == "string"
          and (.target | type) == "string"
          and (.source | type) == "string"
          and (.source_type | type) == "string"
          and (.enforcement == "active"
            or .enforcement == "evaluate"
            or .enforcement == "disabled"))
      ' "$ruleset_list" >/dev/null; then
    return 1
  fi

  mapfile -t tag_ruleset_ids < <(
    jq -r --arg source "$ORG/Athena" '
      .[]
      | select(.target == "tag"
          and .source_type == "Repository"
          and .source == $source
          and .enforcement == "active")
      | .id
    ' "$ruleset_list"
  )
  if [[ ${#tag_ruleset_ids[@]} -ne 1 ]] ||
      ! gh api "repos/$ORG/Athena/rulesets/${tag_ruleset_ids[0]}" \
        >"$ruleset_detail" ||
      ! jq -e \
        --argjson id "${tag_ruleset_ids[0]}" \
        --arg source "$ORG/Athena" \
        --arg scope "$AGENT_CONTRACT_TAG_SCOPE" '
          .id == $id
          and .target == "tag"
          and .source_type == "Repository"
          and .source == $source
          and .enforcement == "active"
          and .bypass_actors == []
          and .conditions.ref_name.include == [$scope]
          and .conditions.ref_name.exclude == []
          and (.rules | type) == "array"
          and ([.rules[].type] | length) ==
            ([.rules[].type] | unique | length)
          and ([.rules[].type] | index("update")) != null
          and ([.rules[].type] | index("deletion")) != null
          and all(.rules[]; (keys | sort) == ["type"])
        ' "$ruleset_detail" >/dev/null; then
    return 1
  fi

  printf '%s\n' "$commit_sha"
}

if [[ "$DRY_RUN" != true ]]; then
  if [[ -z "$EVIDENCE_FILE" || ! -f "$EVIDENCE_FILE" ]]; then
    echo "ERROR: live mutation requires --evidence-file with PR, merge-group, and main gate proof" >&2
    exit 2
  fi
  EVIDENCE_SOURCE_FILE=$EVIDENCE_FILE
  EVIDENCE_SNAPSHOT_TMP="$tmp_dir/activation-evidence.json.tmp"
  EVIDENCE_FILE="$tmp_dir/activation-evidence.json"
  if ! cp "$EVIDENCE_SOURCE_FILE" "$EVIDENCE_SNAPSHOT_TMP" ||
      ! chmod 600 "$EVIDENCE_SNAPSHOT_TMP" ||
      ! mv "$EVIDENCE_SNAPSHOT_TMP" "$EVIDENCE_FILE" ||
      ! sync "$EVIDENCE_FILE"; then
    echo "ERROR: could not seal activation evidence input: $EVIDENCE_SOURCE_FILE" >&2
    exit 2
  fi
  if ! EVIDENCE_OBSERVED_EPOCH=$(jq -er '
      .observed_at
      | select(type == "string")
      | fromdateiso8601
    ' "$EVIDENCE_FILE"); then
    echo "ERROR: GitHub evidence verification failed for fleet: observed_at is invalid" >&2
    exit 2
  fi
  current_epoch=$(date -u +%s)
  if ((EVIDENCE_OBSERVED_EPOCH > current_epoch + 300 ||
      current_epoch - EVIDENCE_OBSERVED_EPOCH > MAX_EVIDENCE_AGE_SECONDS)); then
    echo "ERROR: GitHub evidence verification failed for fleet: observed_at is stale or in the future" >&2
    exit 2
  fi
  if ! AGENT_CONTRACT_SHA=$(resolve_protected_agent_contract_release); then
    echo "ERROR: GitHub evidence verification failed for fleet: protected Athena agent-contract release is unresolved" >&2
    exit 2
  fi
  for repo in "${REPOS[@]}"; do
    if ! jq -e --arg repo "$repo" '
      def sha: type == "string" and test("^[0-9a-f]{40}$");
      def positive_integer: type == "number" and . > 0 and . == floor;
      def proof:
        type == "object"
        and (.run_id | positive_integer)
        and (.attempt_number | positive_integer)
        and (.sha | sha)
        and (.run_url | type == "string" and startswith("https://github.com/"))
        and .required_checks_gate == "success";
      .schema_version == 1
      and (.observed_at | type == "string" and test("Z$"))
      and (.repositories[$repo] | type == "object")
      and (.repositories[$repo].main_sha | sha)
      and (.repositories[$repo].pull_request | proof)
      and (.repositories[$repo].merge_group | proof)
      and (.repositories[$repo].main | proof)
      and .repositories[$repo].main.sha == .repositories[$repo].main_sha
    ' "$EVIDENCE_FILE" >/dev/null; then
      echo "ERROR: $EVIDENCE_SOURCE_FILE lacks complete successful gate proof for $repo" >&2
      exit 2
    fi
    if ! verify_github_evidence "$repo"; then
      exit 2
    fi
  done
fi

ok=0
fail=0

declare -A PLAN_RULESET_ID=()
declare -A PLAN_RULESET_DRIFT=()
declare -A PLAN_SETTINGS_DRIFT=()
declare -A PLAN_UPDATE_PAYLOAD=()
declare -A PLAN_SETTINGS_PAYLOAD=()
declare -A PLAN_RULESET_ROLLBACK=()
declare -A PLAN_SETTINGS_ROLLBACK=()
declare -A PLAN_RULESET_SNAPSHOT=()
declare -A PLAN_SETTINGS_SNAPSHOT=()
declare -A PLAN_DEFAULT_BRANCH=()
declare -A PLAN_PROTECTION_INVENTORY=()
declare -A PLAN_CLASSIC_PRESENT=()
declare -A PLAN_CLASSIC_ROLLBACK=()
declare -A PLAN_CLASSIC_SIGNATURES=()
declare -A PLAN_CLASSIC_SNAPSHOT=()

for repo in "${REPOS[@]}"; do
  echo ""
  echo "--- $repo ---"

  repository_file="$tmp_dir/$repo-repository.json"
  if [[ ! -s "$repository_file" ]] &&
      ! gh api "repos/$ORG/$repo" >"$repository_file"; then
    echo "  FAILED: could not read repository settings" >&2
    fail=$((fail + 1))
    continue
  fi
  if ! default_branch=$(jq -er --arg full_name "$ORG/$repo" '
      select(.full_name == $full_name)
      | .default_branch
      | select(type == "string" and length > 0)
    ' "$repository_file"); then
    echo "  FAILED: repository identity or default branch is incomplete" >&2
    fail=$((fail + 1))
    continue
  fi
  encoded_branch=$(jq -rn --arg value "$default_branch" '$value | @uri')

  ruleset_list="$tmp_dir/$repo-rulesets.json"
  ruleset_pages="$ruleset_list.pages"
  if ! gh api --paginate --slurp \
      "repos/$ORG/$repo/rulesets?includes_parents=true&per_page=100" \
      >"$ruleset_pages" ||
      ! jq -e '
        select(type == "array" and all(.[]; type == "array"))
        | [ .[][] ]
      ' "$ruleset_pages" >"$ruleset_list"; then
    echo "  FAILED: could not list repository rulesets" >&2
    fail=$((fail + 1))
    continue
  fi

  if ! jq -e '
      type == "array"
      and all(.[];
        (.id | type) == "number"
        and (.name | type) == "string"
        and (.target | type) == "string"
        and (.source | type) == "string"
        and (.source_type | type) == "string"
        and (.enforcement == "active"
          or .enforcement == "evaluate"
          or .enforcement == "disabled"))
    ' "$ruleset_list" >/dev/null; then
    echo "  FAILED: effective ruleset inventory is incomplete" >&2
    fail=$((fail + 1))
    continue
  fi

  mapfile -t existing_ids < <(
    jq -r --arg name "$RULESET_NAME" --arg source "$ORG/$repo" '
      .[]
      | select(.name == $name
          and .source_type == "Repository"
          and .source == $source)
      | .id
    ' "$ruleset_list"
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
    overlapping_ruleset=false
    while IFS= read -r effective_id; do
      effective_detail="$tmp_dir/$repo-$effective_id-effective.json"
      if ! gh api "repos/$ORG/$repo/rulesets/$effective_id" >"$effective_detail"; then
        echo "  FAILED: could not read effective ruleset id $effective_id" >&2
        overlapping_ruleset=error
        break
      fi
      if ! jq -e --argjson id "$effective_id" '
          .id == $id
          and (.name | type) == "string"
          and (.target | type) == "string"
          and (.source | type) == "string"
          and (.source_type | type) == "string"
          and (.enforcement == "active"
            or .enforcement == "evaluate"
            or .enforcement == "disabled")
        ' "$effective_detail" >/dev/null; then
        echo "  FAILED: effective ruleset detail is incomplete for id $effective_id" >&2
        overlapping_ruleset=error
        break
      fi
    done < <(jq -r '.[].id' "$ruleset_list")
    if [[ "$overlapping_ruleset" != false ]]; then
      fail=$((fail + 1))
      continue
    fi

    effective_rules="$tmp_dir/$repo-effective-main-rules.json"
    effective_pages="$effective_rules.pages"
    if ! gh api --paginate --slurp \
        "repos/$ORG/$repo/rules/branches/$encoded_branch?per_page=100" \
        >"$effective_pages" ||
        ! jq -e '
          select(type == "array" and all(.[]; type == "array"))
          | [ .[][] ]
        ' "$effective_pages" >"$effective_rules" ||
        ! jq -e '
          type == "array"
          and all(.[];
            (.type | type) == "string"
            and (.ruleset_id | type) == "number"
            and (.ruleset_source_type | type) == "string"
            and (.ruleset_source | type) == "string")
        ' "$effective_rules" >/dev/null; then
      echo "  FAILED: could not enumerate effective default-branch rules" >&2
      fail=$((fail + 1))
      continue
    fi
    mapfile -t overlapping_ids < <(
      jq -r --argjson baseline_id "$existing_id" '
        [.[] | select(.ruleset_id != $baseline_id) | .ruleset_id]
        | unique[]
      ' "$effective_rules"
    )
    if [[ ${#overlapping_ids[@]} -gt 0 ]]; then
      echo "  FAILED: overlapping active branch ruleset affects $default_branch: ${overlapping_ids[*]}" >&2
      fail=$((fail + 1))
      continue
    fi

    classic_protection="$tmp_dir/$repo-classic-protection.json"
    classic_error="$tmp_dir/$repo-classic-protection.err"
    classic_protection_present=false
    if gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
        >"$classic_protection" 2>"$classic_error"; then
      classic_protection_present=true
    elif ! grep -qF 'HTTP 404' "$classic_error"; then
      echo "  FAILED: could not determine classic branch protection state" >&2
      fail=$((fail + 1))
      continue
    fi
    classic_rollback_payload="$tmp_dir/$repo-classic-protection-rollback.json"
    classic_before="$tmp_dir/$repo-classic-protection-before.json"
    classic_after="$tmp_dir/$repo-classic-protection-after.json"
    jq -n null >"$classic_after"
    classic_signatures=false
    if [[ "$classic_protection_present" == true ]]; then
      if ! write_classic_protection_payload \
            "$classic_protection" "$classic_rollback_payload" ||
          ! classic_signatures=$(classic_signatures_enabled \
            "$classic_protection") ||
          ! jq -nS \
            --argjson required_signatures "$classic_signatures" \
            --slurpfile restore_payload "$classic_rollback_payload" '{
              restore_payload: $restore_payload[0],
              required_signatures: $required_signatures
            }' >"$classic_before"; then
        echo "  FAILED: classic branch-protection response is incomplete" >&2
        fail=$((fail + 1))
        continue
      fi
    else
      jq -n null >"$classic_before"
      jq -n null >"$classic_rollback_payload"
    fi

    protection_inventory="$tmp_dir/$repo-protection-inventory.json"
    if ! jq -nS \
        --arg default_branch "$default_branch" \
        --argjson classic_branch_protection "$classic_protection_present" \
        --argjson classic_signatures "$classic_signatures" \
        --slurpfile rulesets "$ruleset_list" \
        --slurpfile effective_rules "$effective_rules" \
        --slurpfile classic_restore "$classic_rollback_payload" '{
          default_branch: $default_branch,
          classic_branch_protection: {
            present: $classic_branch_protection,
            restore_payload: (
              if $classic_branch_protection
              then $classic_restore[0]
              else null
              end
            ),
            required_signatures: (
              if $classic_branch_protection
              then $classic_signatures
              else false
              end
            )
          },
          rulesets: (
            [$rulesets[0][] | {
              id,
              name,
              target,
              source,
              source_type,
              enforcement
            }] | sort_by(.source_type, .source, .id)
          ),
          effective_rules: (
            $effective_rules[0]
            | map(
                if .type == "required_status_checks" and
                    (.parameters | type) == "object" and
                    (.parameters.required_status_checks | type) == "array"
                then .parameters.required_status_checks |=
                  sort_by(.context, .integration_id)
                elif .type == "pull_request" and
                    (.parameters | type) == "object"
                then .parameters.allowed_merge_methods |= sort
                  | .parameters.dismissal_restriction.allowed_actors |=
                    sort_by(.type, .id)
                  | .parameters.required_reviewers |= (
                      map(.file_patterns |= sort)
                      | sort_by(
                          .reviewer.type,
                          .reviewer.id,
                          .minimum_approvals,
                          (.file_patterns | join("\u0000"))
                        )
                    )
                else .
                end
              )
            | sort_by(.ruleset_id, .type)
          )
        }' >"$protection_inventory"; then
      echo "  FAILED: could not derive effective protection inventory" >&2
      fail=$((fail + 1))
      continue
    fi

    live_ruleset="$tmp_dir/$repo-$existing_id-live.json"
    update_payload="$tmp_dir/$repo-$existing_id-update.json"

    cp "$tmp_dir/$repo-$existing_id-effective.json" "$live_ruleset"

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

    if ! live_enforcement=$(jq -er '
        .enforcement
        | select(. == "active" or . == "evaluate" or . == "disabled")
      ' "$live_ruleset"); then
      echo "  FAILED: live ruleset enforcement is missing or invalid" >&2
      fail=$((fail + 1))
      continue
    fi
    if [[ "$live_enforcement" == "active" &&
          "$desired_enforcement" == "evaluate" &&
          "$DRY_RUN" != true ]]; then
      echo "  FAILED: refusing active-to-evaluate downgrade; use --dry-run for a no-write preview" >&2
      fail=$((fail + 1))
      continue
    fi

    if ! jq -e \
        --arg source "$ORG/$repo" \
        --argjson desired "$desired_ruleset" '
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
      def positive_integer:
        type == "number" and . > 0 and . == floor;
      def nonnegative_integer:
        type == "number" and . >= 0 and . == floor;
      def valid_bypass_actor:
        type == "object"
        and (.actor_type == "Integration"
          or .actor_type == "OrganizationAdmin"
          or .actor_type == "RepositoryRole"
          or .actor_type == "Team"
          or .actor_type == "DeployKey"
          or .actor_type == "User")
        and (.bypass_mode == "always"
          or .bypass_mode == "pull_request"
          or .bypass_mode == "exempt")
        and has("actor_id")
        and (
          if .actor_type == "DeployKey" then .actor_id == null
          elif .actor_type == "OrganizationAdmin" then
            (.actor_id == null or (.actor_id | positive_integer))
          else (.actor_id | positive_integer)
          end
        );
      def valid_review_actor:
        type == "object"
        and (.id | positive_integer)
        and (.type == "User"
          or .type == "Team"
          or .type == "IntegrationInstallation"
          or .type == "RepositoryRole");
      def valid_required_reviewer:
        type == "object"
        and (.file_patterns | type) == "array"
        and all(.file_patterns[]; type == "string" and length > 0)
        and (.minimum_approvals | nonnegative_integer)
        and (.reviewer | type) == "object"
        and (.reviewer.id | positive_integer)
        and .reviewer.type == "Team";
      def only_keys($allowed):
        type == "object"
        and ((keys_unsorted - $allowed) | length) == 0;
      def no_unknown_mutable_fields:
        ((keys_unsorted - [
          "_links",
          "bypass_actors",
          "conditions",
          "created_at",
          "current_user_can_bypass",
          "enforcement",
          "id",
          "name",
          "node_id",
          "rules",
          "source",
          "source_type",
          "target",
          "updated_at"
        ]) | length) == 0
        and all(
          .bypass_actors[];
          only_keys(["actor_id", "actor_type", "bypass_mode"])
        )
        and all(
          .rules[];
          if (.type == "deletion"
              or .type == "non_fast_forward"
              or .type == "required_linear_history"
              or .type == "required_signatures")
          then only_keys(["type"])
          elif .type == "pull_request"
          then only_keys(["type", "parameters"])
            and (.parameters | only_keys([
              "allowed_merge_methods",
              "dismiss_stale_reviews_on_push",
              "dismissal_restriction",
              "require_code_owner_review",
              "require_extra_approval_for_unattributed_changes",
              "require_last_push_approval",
              "required_approving_review_count",
              "required_review_thread_resolution",
              "required_reviewers"
            ]))
            and (.parameters.dismissal_restriction
              | only_keys(["allowed_actors", "enabled"]))
            and all(
              .parameters.dismissal_restriction.allowed_actors[];
              only_keys(["id", "type"])
            )
            and all(
              .parameters.required_reviewers[];
              only_keys(["file_patterns", "minimum_approvals", "reviewer"])
              and (.reviewer | only_keys(["id", "type"]))
            )
          elif .type == "merge_queue"
          then only_keys(["type", "parameters"])
            and (.parameters | only_keys([
              "check_response_timeout_minutes",
              "grouping_strategy",
              "max_entries_to_build",
              "max_entries_to_merge",
              "merge_method",
              "min_entries_to_merge",
              "min_entries_to_merge_wait_minutes"
            ]))
          elif .type == "required_status_checks"
          then only_keys(["type", "parameters"])
            and (.parameters | only_keys([
              "do_not_enforce_on_create",
              "required_status_checks",
              "strict_required_status_checks_policy"
            ]))
            and all(
              .parameters.required_status_checks[];
              only_keys(["context", "integration_id"])
            )
          else true
          end
        );
      def complete_pull_request_rules:
        all(
          .rules[] | select(.type == "pull_request");
          (.parameters | type) == "object"
          and (.parameters.allowed_merge_methods | type) == "array"
          and (.parameters.allowed_merge_methods | length) > 0
          and all(.parameters.allowed_merge_methods[];
            . == "merge" or . == "squash" or . == "rebase")
          and (.parameters.allowed_merge_methods | length) ==
            (.parameters.allowed_merge_methods | unique | length)
          and (.parameters.dismiss_stale_reviews_on_push | type) == "boolean"
          and (.parameters.dismissal_restriction | type) == "object"
          and (.parameters.dismissal_restriction.enabled | type) == "boolean"
          and (.parameters.dismissal_restriction.allowed_actors | type) == "array"
          and all(.parameters.dismissal_restriction.allowed_actors[];
            valid_review_actor)
          and (.parameters.require_code_owner_review | type) == "boolean"
          and (.parameters.require_last_push_approval | type) == "boolean"
          and (.parameters.required_approving_review_count
            | nonnegative_integer)
          and .parameters.required_approving_review_count <= 6
          and (.parameters.required_review_thread_resolution | type) == "boolean"
          and (.parameters.required_reviewers | type) == "array"
          and all(.parameters.required_reviewers[]; valid_required_reviewer)
          and ((.parameters | has(
            "require_extra_approval_for_unattributed_changes") | not) or
            (.parameters.require_extra_approval_for_unattributed_changes
              | type) == "boolean")
        );
      def complete_merge_queue_rules:
        all(
          .rules[] | select(.type == "merge_queue");
          (.parameters | type) == "object"
          and (.parameters.check_response_timeout_minutes | positive_integer)
          and (.parameters.grouping_strategy == "ALLGREEN"
            or .parameters.grouping_strategy == "HEADGREEN")
          and (.parameters.max_entries_to_build | positive_integer)
          and (.parameters.max_entries_to_merge | positive_integer)
          and (.parameters.merge_method == "MERGE"
            or .parameters.merge_method == "SQUASH"
            or .parameters.merge_method == "REBASE")
          and (.parameters.min_entries_to_merge | positive_integer)
          and (.parameters.min_entries_to_merge_wait_minutes
            | nonnegative_integer)
        );
      def complete_parameterless_rules:
        all(
          .rules[] | select(.type == "deletion"
            or .type == "non_fast_forward"
            or .type == "required_linear_history"
            or .type == "required_signatures");
          (keys | sort) == ["type"]
        );
      def recognized_rule_types:
        [
          "deletion",
          "merge_queue",
          "non_fast_forward",
          "pull_request",
          "required_linear_history",
          "required_signatures",
          "required_status_checks"
        ];
      if .source_type != "Repository" or .source != $source
        then error("ruleset is not owned by the target repository")
        elif (has("name") and has("target") and has("bypass_actors")
          and has("conditions") and has("rules")) | not
        then error("live ruleset response is incomplete")
        elif (.bypass_actors | type) != "array" or
          any(.bypass_actors[]; valid_bypass_actor | not)
        then error("bypass actor is incomplete")
        elif (complete_required_status_authority | not)
        then error("required_status_checks authority is incomplete")
        elif ([.rules[].type] | length) != ([.rules[].type] | unique | length)
        then error("live ruleset has duplicate rule types")
        elif ([.rules[].type] - recognized_rule_types | length) != 0
        then error("live ruleset contains an unknown rule type")
        elif (no_unknown_mutable_fields | not)
        then error("live ruleset contains unknown mutable fields")
        elif (complete_pull_request_rules | not)
        then error("pull_request rule is incomplete")
        elif (complete_merge_queue_rules | not)
        then error("merge_queue rule is incomplete")
        elif (complete_parameterless_rules | not)
        then error("parameterless rule is incomplete")
        else $desired
        end
    ' "$live_ruleset" > "$update_payload"; then
      echo "  FAILED: could not derive a scoped update from the live ruleset" >&2
      fail=$((fail + 1))
      continue
    fi

    if ! jq -e --argjson desired "$desired_ruleset" '. == $desired' \
        "$update_payload" > /dev/null; then
      echo "  FAILED: derived update differs from the canonical fleet baseline" >&2
      fail=$((fail + 1))
      continue
    fi

    repository_file="$tmp_dir/$repo-repository.json"
    if [[ ! -s "$repository_file" ]] &&
        ! gh api "repos/$ORG/$repo" >"$repository_file"; then
      echo "  FAILED: could not read repository settings" >&2
      fail=$((fail + 1))
      continue
    fi
    if ! jq -e --arg full_name "$ORG/$repo" '
        .full_name == $full_name
        and (.default_branch | type == "string" and length > 0)
      ' "$repository_file" >/dev/null; then
      echo "  FAILED: repository identity or default branch is incomplete" >&2
      fail=$((fail + 1))
      continue
    fi
    settings_before="$tmp_dir/$repo-settings-before.json"
    settings_payload="$tmp_dir/$repo-settings-update.json"
    ruleset_before="$tmp_dir/$repo-ruleset-before.json"
    ruleset_after="$tmp_dir/$repo-ruleset-after.json"
    if ! write_repository_settings "$repository_file" "$settings_before"; then
      echo "  FAILED: repository settings response is incomplete" >&2
      fail=$((fail + 1))
      continue
    fi
    jq -n --argjson desired "$desired_repository_settings" '$desired' \
      >"$settings_payload"
    if ! write_normalized_mutable_payload "$live_ruleset" "$ruleset_before"; then
      echo "  FAILED: live ruleset mutable state is incomplete" >&2
      fail=$((fail + 1))
      continue
    fi
    if ! write_normalized_mutable_payload "$update_payload" "$ruleset_after"; then
      echo "  FAILED: desired ruleset mutable state is incomplete" >&2
      fail=$((fail + 1))
      continue
    fi

    ruleset_drift=true
    settings_drift=true
    if exact_mutable_state_matches "$update_payload" "$live_ruleset"; then
      ruleset_drift=false
    fi
    if exact_repository_settings_match "$settings_payload" "$repository_file"; then
      settings_drift=false
    fi

    if ! ruleset_before_digest=$(json_sha256 "$ruleset_before") ||
        ! ruleset_after_digest=$(json_sha256 "$ruleset_after") ||
        ! settings_before_digest=$(json_sha256 "$settings_before") ||
        ! settings_after_digest=$(json_sha256 "$settings_payload") ||
        ! classic_before_digest=$(json_sha256 "$classic_before") ||
        ! classic_after_digest=$(json_sha256 "$classic_after"); then
      echo "  FAILED: could not derive canonical JSON digests" >&2
      fail=$((fail + 1))
      continue
    fi
    digest_object=$(jq -cnS \
      --arg ruleset_before "$ruleset_before_digest" \
      --arg ruleset_after "$ruleset_after_digest" \
      --arg settings_before "$settings_before_digest" \
      --arg settings_after "$settings_after_digest" \
      --arg classic_before "$classic_before_digest" \
      --arg classic_after "$classic_after_digest" '{
        classic_branch_protection: {
          before: $classic_before,
          after: $classic_after
        },
        repository_settings: {
          before: $settings_before,
          after: $settings_after
        },
        ruleset: {
          before: $ruleset_before,
          after: $ruleset_after
        }
      }')
    echo "PROTECTION-INVENTORY $repo: $(jq -cS . "$protection_inventory")"
    echo "DIGEST $repo: $digest_object"

    if [[ "$ruleset_drift" == false && "$settings_drift" == false &&
        "$classic_protection_present" == false ]]; then
      echo "NO-DRIFT $repo"
    else
      drift_object=$(jq -cnS \
        --slurpfile ruleset_before "$ruleset_before" \
        --slurpfile ruleset_after "$ruleset_after" \
        --slurpfile settings_before "$settings_before" \
        --slurpfile settings_after "$settings_payload" \
        --slurpfile classic_before "$classic_before" \
        --slurpfile classic_after "$classic_after" '{
          classic_branch_protection: {
            before: $classic_before[0],
            after: $classic_after[0]
          },
          repository_settings: {
            before: $settings_before[0],
            after: $settings_after[0]
          },
          ruleset: {
            before: $ruleset_before[0],
            after: $ruleset_after[0]
          }
        }')
      echo "DRIFT $repo: $drift_object"
    fi

    if [[ "$DRY_RUN" == true ]]; then
      ok=$((ok + 1))
      continue
    fi

    snapshot_file="$SNAPSHOT_ROOT/$repo-ruleset-$existing_id-pre.json"
    settings_snapshot="$SNAPSHOT_ROOT/$repo-repository-settings-pre.json"
    inventory_snapshot="$SNAPSHOT_ROOT/$repo-effective-protection-pre.json"
    classic_snapshot="$SNAPSHOT_ROOT/$repo-classic-protection-pre.json"
    rollback_payload="$tmp_dir/$repo-$existing_id-rollback.json"
    settings_rollback_payload="$tmp_dir/$repo-settings-rollback.json"
    post_readback="$tmp_dir/$repo-$existing_id-post-readback.json"
    settings_readback="$tmp_dir/$repo-settings-post-readback.json"
    if ! mkdir -p "$SNAPSHOT_ROOT" ||
        [[ -e "$snapshot_file" || -e "$settings_snapshot" ||
          -e "$inventory_snapshot" ||
          ( "$classic_protection_present" == true && -e "$classic_snapshot" ) ]]; then
      echo "  FAILED: durable snapshot path is unavailable or already exists for $repo" >&2
      fail=$((fail + 1))
      continue
    fi
    snapshot_tmp="$snapshot_file.tmp"
    settings_snapshot_tmp="$settings_snapshot.tmp"
    inventory_snapshot_tmp="$inventory_snapshot.tmp"
    if ! cp "$live_ruleset" "$snapshot_tmp" ||
        ! chmod 600 "$snapshot_tmp" ||
        ! mv "$snapshot_tmp" "$snapshot_file" ||
        ! sync "$snapshot_file" ||
        ! cp "$settings_before" "$settings_snapshot_tmp" ||
        ! chmod 600 "$settings_snapshot_tmp" ||
        ! mv "$settings_snapshot_tmp" "$settings_snapshot" ||
        ! sync "$settings_snapshot" ||
        ! cp "$protection_inventory" "$inventory_snapshot_tmp" ||
        ! chmod 600 "$inventory_snapshot_tmp" ||
        ! mv "$inventory_snapshot_tmp" "$inventory_snapshot" ||
        ! sync "$inventory_snapshot"; then
      echo "  FAILED: could not persist durable pre-state snapshot" >&2
      fail=$((fail + 1))
      continue
    fi
    if [[ "$classic_protection_present" == true ]]; then
      classic_snapshot_tmp="$classic_snapshot.tmp"
      if ! cp "$classic_protection" "$classic_snapshot_tmp" ||
          ! chmod 600 "$classic_snapshot_tmp" ||
          ! mv "$classic_snapshot_tmp" "$classic_snapshot" ||
          ! sync "$classic_snapshot"; then
        echo "  FAILED: could not persist durable classic-protection snapshot" >&2
        fail=$((fail + 1))
        continue
      fi
    else
      classic_snapshot=""
    fi
    if [[ "$classic_protection_present" == true &&
        "$desired_enforcement" != active ]]; then
      echo "  FAILED: classic protection can be removed only after an active equivalent ruleset" >&2
      fail=$((fail + 1))
      continue
    fi
    if ! write_mutable_payload "$snapshot_file" "$rollback_payload"; then
      echo "  FAILED: could not derive rollback payload from durable snapshot" >&2
      fail=$((fail + 1))
      continue
    fi
    cp "$settings_snapshot" "$settings_rollback_payload"
    echo "  Durable pre-state snapshots: $snapshot_file $settings_snapshot $inventory_snapshot${classic_snapshot:+ $classic_snapshot}"
    PLAN_RULESET_ID[$repo]=$existing_id
    PLAN_RULESET_DRIFT[$repo]=$ruleset_drift
    PLAN_SETTINGS_DRIFT[$repo]=$settings_drift
    PLAN_UPDATE_PAYLOAD[$repo]=$update_payload
    PLAN_SETTINGS_PAYLOAD[$repo]=$settings_payload
    PLAN_RULESET_ROLLBACK[$repo]=$rollback_payload
    PLAN_SETTINGS_ROLLBACK[$repo]=$settings_rollback_payload
    PLAN_RULESET_SNAPSHOT[$repo]=$snapshot_file
    PLAN_SETTINGS_SNAPSHOT[$repo]=$settings_snapshot
    PLAN_DEFAULT_BRANCH[$repo]=$default_branch
    PLAN_PROTECTION_INVENTORY[$repo]=$protection_inventory
    PLAN_CLASSIC_PRESENT[$repo]=$classic_protection_present
    PLAN_CLASSIC_ROLLBACK[$repo]=$classic_rollback_payload
    PLAN_CLASSIC_SIGNATURES[$repo]=$classic_signatures
    PLAN_CLASSIC_SNAPSHOT[$repo]=$classic_snapshot
  fi
done

echo ""
if ((fail > 0)); then
  echo "Done: $ok succeeded, $fail failed"
  exit 1
fi

if [[ "$DRY_RUN" == true ]]; then
  echo "Done: $ok succeeded, 0 failed"
  exit 0
fi

verify_canonical_effective_inventory() {
  local repo=$1
  local existing_id=$2
  local default_branch=$3
  local update_payload=$4
  local enforcement=$5
  local label=$6
  local encoded_branch prefix
  local ruleset_pages rulesets effective_pages effective_rules

  encoded_branch=$(jq -rn --arg value "$default_branch" '$value | @uri')
  prefix="$tmp_dir/$repo-$label"
  ruleset_pages="$prefix-rulesets.pages"
  rulesets="$prefix-rulesets.json"
  effective_pages="$prefix-effective.pages"
  effective_rules="$prefix-effective.json"

  if ! gh api --paginate --slurp \
      "repos/$ORG/$repo/rulesets?includes_parents=true&per_page=100" \
      >"$ruleset_pages" ||
      ! jq -e '
        select(type == "array" and all(.[]; type == "array"))
        | [ .[][] ]
      ' "$ruleset_pages" >"$rulesets" ||
      ! jq -e \
        --arg name "$RULESET_NAME" \
        --arg source "$ORG/$repo" \
        --arg enforcement "$enforcement" \
        --argjson ruleset_id "$existing_id" '
        type == "array"
        and all(.[];
          type == "object"
          and (.id | type) == "number"
          and (.name | type) == "string"
          and (.target | type) == "string"
          and (.source | type) == "string"
          and (.source_type | type) == "string"
          and (.enforcement == "active"
            or .enforcement == "evaluate"
            or .enforcement == "disabled"))
        and (map(.id) | length) == (map(.id) | unique | length)
        and ([.[] | select(
          .name == $name
          and .source == $source
          and .source_type == "Repository")] | length) == 1
        and ([.[] | select(
          .id == $ruleset_id
          and .name == $name
          and .target == "branch"
          and .source == $source
          and .source_type == "Repository"
          and .enforcement == $enforcement)] | length) == 1
      ' "$rulesets" >/dev/null ||
      ! gh api --paginate --slurp \
        "repos/$ORG/$repo/rules/branches/$encoded_branch?per_page=100" \
        >"$effective_pages" ||
      ! jq -e '
        select(type == "array" and all(.[]; type == "array"))
        | [ .[][] ]
      ' "$effective_pages" >"$effective_rules" ||
      ! jq -e \
        --arg source "$ORG/$repo" \
        --arg enforcement "$enforcement" \
        --argjson ruleset_id "$existing_id" \
        --slurpfile desired "$update_payload" '
        def normalized_rules:
          map({type, parameters: (.parameters // null)})
          | map(
              if .type == "required_status_checks"
              then .parameters.required_status_checks |=
                sort_by(.context, .integration_id)
              elif .type == "pull_request"
              then .parameters.allowed_merge_methods |= sort
                | .parameters.dismissal_restriction.allowed_actors |=
                  sort_by(.type, .id)
                | .parameters.required_reviewers |= (
                    map(.file_patterns |= sort)
                    | sort_by(
                        .reviewer.type,
                        .reviewer.id,
                        .minimum_approvals,
                        (.file_patterns | join("\u0000"))
                      )
                  )
              else .
              end
            )
          | sort_by(.type);
        type == "array"
        and (
          if $enforcement == "evaluate"
          then length == 0
          else length > 0
            and all(.[];
              type == "object"
              and .ruleset_id == $ruleset_id
              and .ruleset_source_type == "Repository"
              and .ruleset_source == $source)
            and (normalized_rules ==
              ($desired[0].rules | normalized_rules))
          end
        )
      ' "$effective_rules" >/dev/null; then
    return 1
  fi
}

verify_repository_postcondition() {
  local repo=$1
  local existing_id=$2
  local default_branch=$3
  local expected_main_sha=$4
  local settings_payload=$5
  local update_payload=$6
  local enforcement=$7
  local label=$8
  local encoded_branch prefix
  local repository_file branch_file ruleset_file classic_file classic_error

  encoded_branch=$(jq -rn --arg value "$default_branch" '$value | @uri')
  prefix="$tmp_dir/$repo-$label"
  repository_file="$prefix-repository.json"
  branch_file="$prefix-branch.json"
  ruleset_file="$prefix-ruleset.json"
  classic_file="$prefix-classic.json"
  classic_error="$prefix-classic.err"

  if ! gh api "repos/$ORG/$repo" >"$repository_file" ||
      ! exact_repository_identity_matches \
        "$repo" "$default_branch" "$repository_file" ||
      ! exact_repository_settings_match \
        "$settings_payload" "$repository_file" ||
      ! read_exact_default_branch_sha \
        "$repo" "$encoded_branch" "$default_branch" "$expected_main_sha" \
        "$branch_file" ||
      ! gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$ruleset_file" ||
      ! validate_live_identity_scope "$ruleset_file" "$repo" ||
      ! exact_mutable_state_matches "$update_payload" "$ruleset_file" ||
      ! jq -e --arg enforcement "$enforcement" \
        '.enforcement == $enforcement' "$ruleset_file" >/dev/null; then
    return 1
  fi
  if gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
      >"$classic_file" 2>"$classic_error" ||
      ! grep -qF 'HTTP 404' "$classic_error"; then
    return 1
  fi
  if ! verify_canonical_effective_inventory \
      "$repo" "$existing_id" "$default_branch" "$update_payload" \
      "$enforcement" "$label"; then
    return 1
  fi
}

for repo in "${REPOS[@]}"; do
  existing_id=${PLAN_RULESET_ID[$repo]}
  ruleset_drift=${PLAN_RULESET_DRIFT[$repo]}
  settings_drift=${PLAN_SETTINGS_DRIFT[$repo]}
  update_payload=${PLAN_UPDATE_PAYLOAD[$repo]}
  settings_payload=${PLAN_SETTINGS_PAYLOAD[$repo]}
  rollback_payload=${PLAN_RULESET_ROLLBACK[$repo]}
  settings_rollback_payload=${PLAN_SETTINGS_ROLLBACK[$repo]}
  snapshot_file=${PLAN_RULESET_SNAPSHOT[$repo]}
  settings_snapshot=${PLAN_SETTINGS_SNAPSHOT[$repo]}
  default_branch=${PLAN_DEFAULT_BRANCH[$repo]}
  protection_inventory=${PLAN_PROTECTION_INVENTORY[$repo]}
  classic_protection_present=${PLAN_CLASSIC_PRESENT[$repo]}
  classic_rollback_payload=${PLAN_CLASSIC_ROLLBACK[$repo]}
  classic_signatures=${PLAN_CLASSIC_SIGNATURES[$repo]}
  classic_snapshot=${PLAN_CLASSIC_SNAPSHOT[$repo]}
  encoded_branch=$(jq -rn --arg value "$default_branch" '$value | @uri')
  expected_main_sha=$(jq -er --arg repo "$repo" \
    '.repositories[$repo].main_sha' "$EVIDENCE_FILE")
  branch_precondition="$tmp_dir/$repo-default-branch-jit-precondition.json"
  post_readback="$tmp_dir/$repo-$existing_id-post-readback.json"
  settings_readback="$tmp_dir/$repo-settings-post-readback.json"
  precondition_ruleset="$tmp_dir/$repo-$existing_id-jit-precondition.json"
  precondition_settings="$tmp_dir/$repo-settings-jit-precondition.json"
  precondition_ruleset_pages="$tmp_dir/$repo-rulesets-jit-precondition.pages"
  precondition_rulesets="$tmp_dir/$repo-rulesets-jit-precondition.json"
  precondition_effective_pages="$tmp_dir/$repo-effective-jit-precondition.pages"
  precondition_effective="$tmp_dir/$repo-effective-jit-precondition.json"
  precondition_classic="$tmp_dir/$repo-classic-jit-precondition.json"
  precondition_classic_error="$tmp_dir/$repo-classic-jit-precondition.err"
  precondition_classic_restore="$tmp_dir/$repo-classic-restore-jit-precondition.json"
  precondition_inventory="$tmp_dir/$repo-protection-inventory-jit-precondition.json"
  classic_delete_readback="$tmp_dir/$repo-classic-delete-readback.json"
  classic_delete_error="$tmp_dir/$repo-classic-delete-readback.err"
  mutation_repository_identity="$tmp_dir/$repo-mutation-repository-identity.json"
  final_ruleset_readback="$tmp_dir/$repo-final-ruleset-readback.json"
  final_branch_readback="$tmp_dir/$repo-final-default-branch.json"
  final_ruleset_pages="$tmp_dir/$repo-final-rulesets.pages"
  final_rulesets="$tmp_dir/$repo-final-rulesets.json"
  final_effective_pages="$tmp_dir/$repo-final-effective.pages"
  final_effective="$tmp_dir/$repo-final-effective.json"
  final_classic_readback="$tmp_dir/$repo-final-classic-readback.json"
  final_classic_error="$tmp_dir/$repo-final-classic-readback.err"
  ruleset_changed=false

  if ! read_exact_default_branch_sha \
      "$repo" "$encoded_branch" "$default_branch" "$expected_main_sha" \
      "$branch_precondition"; then
    abort_on_changed_precondition "$repo" default-branch-sha
  fi
  if ! gh api "repos/$ORG/$repo/rulesets/$existing_id" \
      >"$precondition_ruleset" ||
      ! validate_live_identity_scope "$precondition_ruleset" "$repo" ||
      ! exact_mutable_state_matches \
        "$rollback_payload" "$precondition_ruleset"; then
    abort_on_changed_precondition "$repo" ruleset
  fi
  if ! gh api "repos/$ORG/$repo" >"$precondition_settings" ||
      ! jq -e --arg full_name "$ORG/$repo" \
        --arg default_branch "$default_branch" '
        .full_name == $full_name
        and .default_branch == $default_branch
      ' "$precondition_settings" >/dev/null; then
    abort_on_changed_precondition "$repo" default-branch-identity
  fi
  if ! exact_repository_settings_match \
      "$settings_rollback_payload" "$precondition_settings"; then
    abort_on_changed_precondition "$repo" repository-settings
  fi
  if ! gh api --paginate --slurp \
      "repos/$ORG/$repo/rulesets?includes_parents=true&per_page=100" \
      >"$precondition_ruleset_pages" ||
      ! jq -e '
        select(type == "array" and all(.[]; type == "array"))
        | [ .[][] ]
      ' "$precondition_ruleset_pages" >"$precondition_rulesets" ||
      ! gh api --paginate --slurp \
        "repos/$ORG/$repo/rules/branches/$encoded_branch?per_page=100" \
        >"$precondition_effective_pages" ||
      ! jq -e '
        select(type == "array" and all(.[]; type == "array"))
        | [ .[][] ]
      ' "$precondition_effective_pages" >"$precondition_effective"; then
    abort_on_changed_precondition "$repo" effective-protection
  fi
  precondition_classic_present=false
  precondition_classic_signatures=false
  if gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
      >"$precondition_classic" 2>"$precondition_classic_error"; then
    precondition_classic_present=true
    if ! write_classic_protection_payload \
        "$precondition_classic" "$precondition_classic_restore" ||
        ! precondition_classic_signatures=$(classic_signatures_enabled \
          "$precondition_classic"); then
      abort_on_changed_precondition "$repo" effective-protection
    fi
  elif ! grep -qF 'HTTP 404' "$precondition_classic_error"; then
    abort_on_changed_precondition "$repo" effective-protection
  else
    jq -n null >"$precondition_classic_restore"
  fi
  if ! jq -nS \
      --arg default_branch "$default_branch" \
      --argjson classic_branch_protection "$precondition_classic_present" \
      --argjson classic_signatures "$precondition_classic_signatures" \
      --slurpfile rulesets "$precondition_rulesets" \
      --slurpfile effective_rules "$precondition_effective" \
      --slurpfile classic_restore "$precondition_classic_restore" '{
        default_branch: $default_branch,
        classic_branch_protection: {
          present: $classic_branch_protection,
          restore_payload: (
            if $classic_branch_protection
            then $classic_restore[0]
            else null
            end
          ),
          required_signatures: (
            if $classic_branch_protection
            then $classic_signatures
            else false
            end
          )
        },
        rulesets: (
          [$rulesets[0][] | {
            id,
            name,
            target,
            source,
            source_type,
            enforcement
          }] | sort_by(.source_type, .source, .id)
        ),
        effective_rules: (
          $effective_rules[0]
          | map(
              if .type == "required_status_checks" and
                  (.parameters | type) == "object" and
                  (.parameters.required_status_checks | type) == "array"
              then .parameters.required_status_checks |=
                sort_by(.context, .integration_id)
              elif .type == "pull_request" and
                  (.parameters | type) == "object"
              then .parameters.allowed_merge_methods |= sort
                | .parameters.dismissal_restriction.allowed_actors |=
                  sort_by(.type, .id)
                | .parameters.required_reviewers |= (
                    map(.file_patterns |= sort)
                    | sort_by(
                        .reviewer.type,
                        .reviewer.id,
                        .minimum_approvals,
                        (.file_patterns | join("\u0000"))
                      )
                  )
              else .
              end
            )
          | sort_by(.ruleset_id, .type)
        )
      }' >"$precondition_inventory" ||
      ! jq -e --slurpfile expected "$protection_inventory" \
        '. == $expected[0]' "$precondition_inventory" >/dev/null; then
    abort_on_changed_precondition "$repo" effective-protection
  fi

  MUTATION_REPO=$repo
  MUTATION_RULESET_ID=$existing_id
  MUTATION_UPDATE_PAYLOAD=$update_payload
  MUTATION_ROLLBACK_PAYLOAD=$rollback_payload
  MUTATION_SNAPSHOT=$snapshot_file
  MUTATION_KIND=ruleset
  MUTATION_RULESET_CHANGED=false
  MUTATION_SETTINGS_PAYLOAD=$settings_payload
  MUTATION_SETTINGS_ROLLBACK_PAYLOAD=$settings_rollback_payload
  MUTATION_SETTINGS_SNAPSHOT=$settings_snapshot
  MUTATION_SETTINGS_CHANGED=false
  MUTATION_CLASSIC_ROLLBACK_PAYLOAD=$classic_rollback_payload
  MUTATION_CLASSIC_SIGNATURES=$classic_signatures
  MUTATION_CLASSIC_SNAPSHOT=$classic_snapshot
  MUTATION_ENCODED_BRANCH=$encoded_branch
  if [[ "$ruleset_drift" == true ]]; then
    if ! gh api "repos/$ORG/$repo" >"$mutation_repository_identity" ||
        ! exact_repository_identity_matches \
          "$repo" "$default_branch" "$mutation_repository_identity" ||
        ! read_exact_default_branch_sha \
          "$repo" "$encoded_branch" "$default_branch" "$expected_main_sha" \
          "$branch_precondition"; then
      abort_on_changed_precondition \
        "$repo" default-branch-sha-before-ruleset-write
    fi
    echo "  Reconciling $repo canonical baseline (id: $existing_id)..."
    MUTATION_ARMED=true
    if ! gh api -X PUT "repos/$ORG/$repo/rulesets/$existing_id" \
        --input "$update_payload" >/dev/null; then
      rollback_and_abort "$repo" "$existing_id" "$update_payload" \
        "$rollback_payload" "PUT failed or returned an ambiguous result" \
        "$snapshot_file" true
    fi
    if ! gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$post_readback"; then
      rollback_and_abort "$repo" "$existing_id" "$update_payload" \
        "$rollback_payload" "post-PUT readback failed" "$snapshot_file" true
    fi
    if ! validate_live_identity_scope "$post_readback" "$repo" ||
        ! exact_mutable_state_matches "$update_payload" "$post_readback"; then
      rollback_and_abort "$repo" "$existing_id" "$update_payload" \
        "$rollback_payload" \
        "post-PUT state did not match the exact requested postcondition" \
        "$snapshot_file" true
    fi
    ruleset_changed=true
    MUTATION_RULESET_CHANGED=true
  fi

  if [[ "$settings_drift" == true ]]; then
    if ! read_exact_default_branch_sha \
        "$repo" "$encoded_branch" "$default_branch" "$expected_main_sha" \
        "$branch_precondition"; then
      if [[ "$ruleset_changed" == true ]]; then
        rollback_and_abort "$repo" "$existing_id" "$update_payload" \
          "$rollback_payload" \
          "default-branch-sha changed before repository-settings write" \
          "$snapshot_file" true
      fi
      abort_on_changed_precondition \
        "$repo" default-branch-sha-before-repository-settings-write
    fi
    if ! gh api "repos/$ORG/$repo" >"$mutation_repository_identity" ||
        ! exact_repository_identity_matches \
          "$repo" "$default_branch" "$mutation_repository_identity" ||
        ! exact_repository_settings_match \
          "$settings_rollback_payload" "$mutation_repository_identity"; then
      if [[ "$ruleset_changed" == true ]]; then
        rollback_and_abort "$repo" "$existing_id" "$update_payload" \
          "$rollback_payload" \
          "repository-settings-before-write precondition changed" \
          "$snapshot_file" true
      fi
      abort_on_changed_precondition \
        "$repo" repository-settings-before-write
    fi
    echo "  Reconciling $repo canonical repository settings..."
    MUTATION_KIND=settings
    MUTATION_ARMED=true
    if ! gh api -X PATCH "repos/$ORG/$repo" \
        --input "$settings_payload" >/dev/null; then
      rollback_settings_and_ruleset_abort \
        "$repo" "$settings_payload" "$settings_rollback_payload" \
        "$settings_snapshot" true "$ruleset_changed" "$existing_id" \
        "$update_payload" "$rollback_payload" "$snapshot_file" \
        "repository PATCH failed or returned an ambiguous result"
    fi
    if ! gh api "repos/$ORG/$repo" >"$settings_readback" ||
        ! exact_repository_identity_matches \
          "$repo" "$default_branch" "$settings_readback" ||
        ! exact_repository_settings_match \
          "$settings_payload" "$settings_readback"; then
      rollback_settings_and_ruleset_abort \
        "$repo" "$settings_payload" "$settings_rollback_payload" \
        "$settings_snapshot" true "$ruleset_changed" "$existing_id" \
        "$update_payload" "$rollback_payload" "$snapshot_file" \
        "repository-settings readback did not match"
    fi
    MUTATION_SETTINGS_CHANGED=true
  fi

  if [[ "$classic_protection_present" == true ]]; then
    if ! gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
        >"$precondition_classic" 2>"$precondition_classic_error" ||
        ! exact_classic_protection_matches \
          "$classic_rollback_payload" "$classic_signatures" \
          "$precondition_classic"; then
      abort_current_transaction \
        "classic protection changed after the just-in-time precondition"
    fi
    if ! gh api "repos/$ORG/$repo/rulesets/$existing_id" >"$post_readback" ||
        ! validate_live_identity_scope "$post_readback" "$repo" ||
        ! exact_mutable_state_matches "$update_payload" "$post_readback" ||
        ! jq -e '.enforcement == "active"' "$post_readback" >/dev/null; then
      abort_current_transaction \
        "equivalent active ruleset was not exact immediately before classic-protection removal"
    fi
    if ! verify_canonical_effective_inventory \
        "$repo" "$existing_id" "$default_branch" "$update_payload" active \
        classic-delete-precondition; then
      abort_current_transaction \
        "effective active rules were not exact immediately before classic-protection removal"
    fi
    if ! gh api "repos/$ORG/$repo" >"$mutation_repository_identity" ||
        ! exact_repository_identity_matches \
          "$repo" "$default_branch" "$mutation_repository_identity"; then
      abort_current_transaction \
        "default branch changed immediately before classic-protection removal"
    fi
    if ! read_exact_default_branch_sha \
        "$repo" "$encoded_branch" "$default_branch" "$expected_main_sha" \
        "$branch_precondition"; then
      abort_current_transaction \
        "default-branch-sha-before-classic-delete changed"
    fi
    MUTATION_KIND=classic
    MUTATION_ARMED=true
    if ! gh api -X DELETE \
        "repos/$ORG/$repo/branches/$encoded_branch/protection" >/dev/null; then
      rollback_classic_transaction_abort \
        "classic-protection DELETE failed or returned an ambiguous result"
    fi
    if gh api "repos/$ORG/$repo/branches/$encoded_branch/protection" \
        >"$classic_delete_readback" 2>"$classic_delete_error" ||
        ! grep -qF 'HTTP 404' "$classic_delete_error"; then
      rollback_classic_transaction_abort \
        "classic-protection deletion was not verified by an independent 404 readback"
    fi
  fi

  if ! verify_repository_postcondition \
      "$repo" "$existing_id" "$default_branch" "$expected_main_sha" \
      "$settings_payload" "$update_payload" "$desired_enforcement" \
      transaction-final; then
    abort_current_transaction \
      "final-effective-protection/default-branch-sha postcondition did not match the canonical baseline"
  fi

  echo "  Verified exact postcondition for $repo: canonical fleet baseline and repository settings."
  COMPLETED_REPOS+=("$repo")
  MUTATION_ARMED=false
  ok=$((ok + 1))
done

for repo in "${REPOS[@]}"; do
  expected_main_sha=$(jq -er --arg repo "$repo" \
    '.repositories[$repo].main_sha' "$EVIDENCE_FILE")
  if ! verify_repository_postcondition \
      "$repo" "${PLAN_RULESET_ID[$repo]}" "${PLAN_DEFAULT_BRANCH[$repo]}" \
      "$expected_main_sha" "${PLAN_SETTINGS_PAYLOAD[$repo]}" \
      "${PLAN_UPDATE_PAYLOAD[$repo]}" "$desired_enforcement" fleet-final; then
    RECOVERY_STARTED=true
    MUTATION_ARMED=false
    trap '' HUP INT TERM PIPE
    echo "  FAILED: final fleet sweep detected drift in $repo; compensating all completed repositories" >&2
    if rollback_completed_repositories; then
      echo "  Fleet rollback verified exactly after final-sweep drift." >&2
    else
      echo "  UNCERTAIN MUTATION: final-sweep rollback could not be verified exactly." >&2
    fi
    exit 1
  fi
done
echo "Verified exact fleet-wide postcondition after all repository writes."

if ! echo "Done: $ok succeeded, 0 failed"; then
  exit 1
fi
OPERATION_COMMITTED=true
MUTATION_ARMED=false
COMPLETED_REPOS=()
