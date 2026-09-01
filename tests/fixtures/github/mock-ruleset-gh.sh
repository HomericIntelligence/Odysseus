#!/usr/bin/env bash
set -euo pipefail

: "${GH_RULESET_FIXTURE:?GH_RULESET_FIXTURE is required}"
: "${GH_CALL_LOG:?GH_CALL_LOG is required}"

printf '%q ' "$@" >>"$GH_CALL_LOG"
printf '\n' >>"$GH_CALL_LOG"

next_counter() {
  local counter_file=$1
  local value=0
  if [[ -s "$counter_file" ]]; then
    value=$(<"$counter_file")
  fi
  value=$((value + 1))
  printf '%s\n' "$value" >"$counter_file"
  printf '%s\n' "$value"
}

count_selected() {
  local selected=${1:-}
  local count=$2
  [[ ",$selected," == *",$count,"* ]]
}

repo_selected() {
  local selected=${1:-}
  local repo=$2
  [[ ",$selected," == *",$repo,"* ]]
}

fixture_v2_for_repo() {
  local repo=$1
  jq -e --arg repository "HomericIntelligence/$repo" '
    .schema_version == 2
    and .repository == $repository
    and (.api_captures | type) == "object"
  ' "$GH_RULESET_FIXTURE" >/dev/null
}

ruleset_state_path() {
  local repo=$1
  if [[ -n "${GH_RULESET_STATE_DIR:-}" ]]; then
    printf '%s/%s-ruleset.json\n' "$GH_RULESET_STATE_DIR" "$repo"
  else
    printf '%s\n' "${GH_RULESET_STATE:-}"
  fi
}

repository_state_path() {
  local repo=$1
  if [[ -n "${GH_REPOSITORY_STATE_DIR:-}" ]]; then
    printf '%s/%s-settings.json\n' "$GH_REPOSITORY_STATE_DIR" "$repo"
  else
    printf '%s\n' "${GH_REPOSITORY_STATE:-}"
  fi
}

classic_protection_state_path() {
  if [[ -n "${GH_CLASSIC_PROTECTION_STATE_DIR:-}" ]]; then
    printf '%s/%s-classic-protection.json\n' \
      "$GH_CLASSIC_PROTECTION_STATE_DIR" "$1"
  else
    printf '%s\n' "${GH_CLASSIC_PROTECTION_STATE:-}"
  fi
}

default_classic_protection() {
  jq -n '{
    required_status_checks: {
      strict: true,
      contexts: ["legacy-check"],
      checks: [
        {context: "legacy-check", app_id: 15368},
        {context: "provider-agnostic", app_id: null}
      ]
    },
    enforce_admins: {enabled: true},
    required_pull_request_reviews: null,
    restrictions: null,
    required_linear_history: {enabled: true},
    allow_force_pushes: {enabled: false},
    allow_deletions: {enabled: false},
    block_creations: {enabled: false},
    required_conversation_resolution: {enabled: true},
    lock_branch: {enabled: false},
    allow_fork_syncing: {enabled: false},
    required_signatures: {enabled: true}
  }'
}

read_classic_protection_state() {
  local state_file
  state_file=$(classic_protection_state_path "$1")
  if [[ -n "$state_file" && -s "$state_file" ]]; then
    jq -e 'select(. != null)' "$state_file"
  else
    return 1
  fi
}

default_repository_state() {
  local repo=$1
  jq -n --arg full_name "HomericIntelligence/$repo" '{
    full_name: $full_name,
    default_branch: "main",
    allow_auto_merge: false,
    allow_merge_commit: true,
    allow_rebase_merge: true,
    allow_squash_merge: true,
    allow_update_branch: false,
    delete_branch_on_merge: false,
    web_commit_signoff_required: false
  }'
}

read_repository_state() {
  local repo=$1
  local state_file
  state_file=$(repository_state_path "$repo")
  if [[ -n "$state_file" && -s "$state_file" ]]; then
    jq . "$state_file"
  elif fixture_v2_for_repo "$repo"; then
    jq -e '
      .api_captures.repository_policy_projection.response
      | select(type == "object")
    ' \
      "$GH_RULESET_FIXTURE"
  else
    default_repository_state "$repo"
  fi
}

read_ruleset_state() {
  local repo=$1
  local ruleset_id=$2
  local state_file fixture_repo
  fixture_repo=$(jq -r '.repository | split("/")[-1]' "$GH_RULESET_FIXTURE")
  state_file=$(ruleset_state_path "$repo")
  if [[ -n "$state_file" && -s "$state_file" ]]; then
    if [[ "$repo" == "$fixture_repo" ]]; then
      jq --argjson id "$ruleset_id" 'select(.id == $id)' "$state_file"
    else
      jq --arg source "HomericIntelligence/$repo" --argjson id "$ruleset_id" '
        select(.id == $id) | .source = $source | .source_type = "Repository"
      ' "$state_file"
    fi
  else
    if fixture_v2_for_repo "$repo"; then
      jq -e --argjson id "$ruleset_id" '
        [.api_captures.ruleset_details.responses[]
          | select(.status == 200 and .response.id == $id)
          | .response]
        | if length == 1 then .[0]
          else error("captured ruleset detail is missing or ambiguous")
          end
      ' "$GH_RULESET_FIXTURE"
    elif [[ "$repo" == "$fixture_repo" ]]; then
      jq --argjson id "$ruleset_id" '.rulesets[] | select(.id == $id)' \
        "$GH_RULESET_FIXTURE"
    else
      jq --arg source "HomericIntelligence/$repo" --argjson id "$ruleset_id" '
        .rulesets[] | select(.id == $id) | .source = $source
      ' "$GH_RULESET_FIXTURE"
    fi
  fi
}

if [[ "${1:-}" == repo && "${2:-}" == list ]]; then
  : "${GH_REPO_LIST:?GH_REPO_LIST is required for gh repo list}"
  printf '%s\n' "$GH_REPO_LIST"
  exit 0
fi

if [[ "${1:-}" != api ]]; then
  echo "unexpected gh command: $*" >&2
  exit 2
fi
shift

method=GET
input=""
endpoint=""
slurp=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    -X|--method)
      method=$2
      shift 2
      ;;
    --input)
      input=$2
      shift 2
      ;;
    --jq)
      shift 2
      ;;
    --paginate|--silent)
      shift
      ;;
    --slurp)
      slurp=true
      shift
      ;;
    -H)
      shift 2
      ;;
    -*)
      echo "unexpected gh api option: $1" >&2
      exit 2
      ;;
    *)
      endpoint=$1
      shift
      ;;
  esac
done

if [[ "$endpoint" =~ ^repos/HomericIntelligence/([^/]+)(/.*)?$ ]]; then
  repo=${BASH_REMATCH[1]}
  suffix=${BASH_REMATCH[2]:-}
else
  echo "unexpected gh api endpoint: $endpoint" >&2
  exit 2
fi

if [[ "$method" != GET ]]; then
  [[ "${GH_ALLOW_MUTATION:-false}" == true ]] || {
    echo "mock refuses mutation: method=$method input=$input" >&2
    exit 2
  }
  if [[ "$method" != DELETE && "$method" != POST && -z "$input" ]]; then
    echo "mock refuses mutation without an input payload: method=$method" >&2
    exit 2
  fi

  case "$suffix" in
    /branches/*/protection/required_signatures)
      [[ "$method" == POST ]] || {
        echo "unexpected signature-protection mutation method: $method" >&2
        exit 2
      }
      state_file=$(classic_protection_state_path "$repo")
      [[ -n "$state_file" && -s "$state_file" ]] || {
        echo "mock classic-protection state is required for signature restore" >&2
        exit 2
      }
      signature_count=1
      if [[ -n "${GH_CLASSIC_SIGNATURE_COUNT_FILE:-}" ]]; then
        signature_count=$(next_counter "$GH_CLASSIC_SIGNATURE_COUNT_FILE")
      fi
      if count_selected \
          "${GH_FAIL_CLASSIC_SIGNATURE_POST_BEFORE_WRITE_AT:-}" \
          "$signature_count"; then
        echo "mock classic signature POST failure before write" >&2
        exit 1
      fi
      jq '.required_signatures = {enabled: true}' "$state_file" \
        >"$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
      if count_selected \
          "${GH_FAIL_CLASSIC_SIGNATURE_POST_AFTER_WRITE_AT:-}" \
          "$signature_count"; then
        echo "mock classic signature POST failure after write" >&2
        exit 1
      fi
      jq '.required_signatures' "$state_file"
      ;;
    /branches/*/protection)
      state_file=$(classic_protection_state_path "$repo")
      [[ -n "$state_file" && -s "$state_file" ]] || {
        echo "mock classic-protection state is required for mutation" >&2
        exit 2
      }
      classic_count=1
      if [[ -n "${GH_CLASSIC_MUTATION_COUNT_FILE:-}" ]]; then
        classic_count=$(next_counter "$GH_CLASSIC_MUTATION_COUNT_FILE")
      fi
      if [[ "$method" == DELETE ]]; then
        if count_selected "${GH_FAIL_CLASSIC_DELETE_BEFORE_WRITE_AT:-}" \
            "$classic_count"; then
          echo "mock classic DELETE failure before write" >&2
          exit 1
        fi
        jq -n null >"$state_file"
        if count_selected "${GH_FAIL_CLASSIC_DELETE_AFTER_WRITE_AT:-}" \
            "$classic_count"; then
          echo "mock classic DELETE failure after write" >&2
          exit 1
        fi
      elif [[ "$method" == PUT ]]; then
        if count_selected "${GH_FAIL_CLASSIC_PUT_BEFORE_WRITE_AT:-}" \
            "$classic_count"; then
          echo "mock classic PUT failure before write" >&2
          exit 1
        fi
        jq '{
          required_status_checks: (
            if .required_status_checks == null then null
            else .required_status_checks
              | .checks |= map(
                  if has("app_id") then . else . + {app_id: null} end
                )
            end
          ),
          enforce_admins: {enabled: .enforce_admins},
          required_pull_request_reviews,
          restrictions,
          required_linear_history: {enabled: .required_linear_history},
          allow_force_pushes: {enabled: .allow_force_pushes},
          allow_deletions: {enabled: .allow_deletions},
          block_creations: {enabled: .block_creations},
          required_conversation_resolution:
            {enabled: .required_conversation_resolution},
          lock_branch: {enabled: .lock_branch},
          allow_fork_syncing: {enabled: .allow_fork_syncing},
          required_signatures: {enabled: false}
        }' "$input" >"$state_file.tmp"
        mv "$state_file.tmp" "$state_file"
        if count_selected "${GH_FAIL_CLASSIC_PUT_AFTER_WRITE_AT:-}" \
            "$classic_count"; then
          echo "mock classic PUT failure after write" >&2
          exit 1
        fi
        jq . "$state_file"
      else
        echo "unexpected classic-protection mutation method: $method" >&2
        exit 2
      fi
      ;;
    /rulesets/*)
      [[ "$method" == PUT ]] || {
        echo "unexpected ruleset mutation method: $method" >&2
        exit 2
      }
      put_count=1
      if [[ -n "${GH_PUT_COUNT_FILE:-}" ]]; then
        put_count=$(next_counter "$GH_PUT_COUNT_FILE")
      fi
      if count_selected "${GH_FAIL_PUT_BEFORE_WRITE_AT:-}" "$put_count"; then
        echo "mock PUT failure before write at call $put_count" >&2
        exit 1
      fi

      state_file=$(ruleset_state_path "$repo")
      if [[ -n "$state_file" ]]; then
        [[ -s "$state_file" ]] || {
          echo "mock state file is missing: $state_file" >&2
          exit 2
        }
        state_tmp="$state_file.tmp"
        jq --slurpfile current "$state_file" --arg source "HomericIntelligence/$repo" '
          . + {
            id: $current[0].id,
            source: $source,
            source_type: "Repository"
          }
        ' "$input" >"$state_tmp"
        mv "$state_tmp" "$state_file"
        if count_selected "${GH_CORRUPT_PUT_AT:-}" "$put_count"; then
          state_tmp="$state_file.tmp"
          jq '.conditions.ref_name.include = ["refs/heads/not-main"]' \
            "$state_file" >"$state_tmp"
          mv "$state_tmp" "$state_file"
        fi
        if [[ "${GH_DRIFT_COMPLETED_REPO_ON_PUT_SOURCE:-}" == "$repo" &&
            -n "${GH_DRIFT_COMPLETED_REPO_ON_PUT_TARGET:-}" &&
            -n "${GH_RULESET_STATE_DIR:-}" ]]; then
          drift_target="$GH_RULESET_STATE_DIR/${GH_DRIFT_COMPLETED_REPO_ON_PUT_TARGET}-ruleset.json"
          [[ -s "$drift_target" ]] || {
            echo "mock completed-repository drift target is missing" >&2
            exit 2
          }
          jq '.conditions.ref_name.include = ["refs/heads/concurrent-final-sweep"]' \
            "$drift_target" >"$drift_target.tmp"
          mv "$drift_target.tmp" "$drift_target"
        fi
      fi

      if count_selected "${GH_FAIL_PUT_AFTER_WRITE_AT:-}" "$put_count"; then
        echo "mock PUT failure after write at call $put_count" >&2
        exit 1
      fi
      if [[ -n "$state_file" ]]; then
        jq . "$state_file"
      else
        jq . "$input"
      fi
      ;;
    "")
      [[ "$method" == PATCH ]] || {
        echo "unexpected repository mutation method: $method" >&2
        exit 2
      }
      settings_count=1
      if [[ -n "${GH_SETTINGS_PATCH_COUNT_FILE:-}" ]]; then
        settings_count=$(next_counter "$GH_SETTINGS_PATCH_COUNT_FILE")
      fi
      if count_selected "${GH_FAIL_SETTINGS_PATCH_BEFORE_WRITE_AT:-}" "$settings_count"; then
        echo "mock settings PATCH failure before write at call $settings_count" >&2
        exit 1
      fi
      state_file=$(repository_state_path "$repo")
      [[ -n "$state_file" ]] || {
        echo "mock repository state file is required for PATCH" >&2
        exit 2
      }
      read_repository_state "$repo" >"$state_file.tmp"
      jq --slurpfile patch "$input" '. + $patch[0]' "$state_file.tmp" >"$state_file"
      rm -f "$state_file.tmp"
      if count_selected "${GH_CORRUPT_SETTINGS_PATCH_AT:-}" "$settings_count"; then
        jq '.allow_auto_merge = false' "$state_file" >"$state_file.tmp"
        mv "$state_file.tmp" "$state_file"
      fi
      if count_selected "${GH_FAIL_SETTINGS_PATCH_AFTER_WRITE_AT:-}" "$settings_count"; then
        echo "mock settings PATCH failure after write at call $settings_count" >&2
        exit 1
      fi
      jq . "$state_file"
      ;;
    *)
      echo "unexpected mutating gh api endpoint: $endpoint" >&2
      exit 2
      ;;
  esac
  exit 0
fi

case "$suffix" in
  "")
    repository_get_count=1
    if [[ -n "${GH_REPOSITORY_GET_COUNT_FILE:-}" ]]; then
      repository_get_count=$(next_counter "$GH_REPOSITORY_GET_COUNT_FILE")
    fi
    if count_selected "${GH_FAIL_REPOSITORY_GET_AT:-}" "$repository_get_count"; then
      echo "mock repository GET failure at call $repository_get_count" >&2
      exit 1
    fi
    if count_selected "${GH_CONCURRENT_SETTINGS_CHANGE_AT:-}" \
        "$repository_get_count"; then
      state_file=$(repository_state_path "$repo")
      [[ -n "$state_file" && -s "$state_file" ]] || {
        echo "mock repository state file is required for a concurrent change" >&2
        exit 2
      }
      jq '.allow_squash_merge = false' "$state_file" >"$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
    fi
    if count_selected "${GH_DEFAULT_BRANCH_CHANGE_AT:-}" \
        "$repository_get_count"; then
      state_file=$(repository_state_path "$repo")
      [[ -n "$state_file" && -s "$state_file" ]] || {
        echo "mock repository state file is required for a default-branch change" >&2
        exit 2
      }
      jq '.default_branch = "develop"' "$state_file" >"$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
    fi
    read_repository_state "$repo"
    ;;
  /git/ref/tags/agent-contract-v1.0.0)
    [[ "$repo" == Athena ]] || {
      echo "mock agent-contract tag ref is Athena-only" >&2
      exit 1
    }
    if [[ "${GH_AGENT_CONTRACT_TAG_LOOKUP_FAILURE:-false}" == true ]]; then
      echo "mock agent-contract tag ref lookup failure" >&2
      exit 1
    fi
    tag_ref=${GH_AGENT_CONTRACT_TAG_REF_OVERRIDE:-refs/tags/agent-contract-v1.0.0}
    tag_type=${GH_AGENT_CONTRACT_TAG_OBJECT_TYPE_OVERRIDE:-tag}
    jq -n \
      --arg ref "$tag_ref" \
      --arg type "$tag_type" \
      --arg sha dddddddddddddddddddddddddddddddddddddddd '{
        ref: $ref,
        object: {type: $type, sha: $sha}
      }'
    ;;
  /git/commits/*)
    commit_sha=${suffix#/git/commits/}
    jq -n \
      --arg sha "$commit_sha" \
      --arg tree_sha eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee '{
        sha: $sha,
        tree: {sha: $tree_sha}
      }'
    ;;
  /git/trees/*)
    tree_sha=${suffix#/git/trees/}
    tree_sha=${tree_sha%%\?*}
    git_tree_get_count=1
    if [[ -n "${GH_GIT_TREE_GET_COUNT_FILE:-}" ]]; then
      git_tree_get_count=$(next_counter "$GH_GIT_TREE_GET_COUNT_FILE")
    fi
    smoke_present=${GH_GIT_TREE_SMOKE_PRESENT:-false}
    required_missing=${GH_GIT_TREE_REQUIRED_MISSING:-false}
    required_blob_sha=ffffffffffffffffffffffffffffffffffffffff
    if count_selected "${GH_GIT_TREE_REQUIRED_BLOB_CHANGE_AT:-}" \
        "$git_tree_get_count"; then
      required_blob_sha=8888888888888888888888888888888888888888
    fi
    jq -n \
      --arg sha "$tree_sha" \
      --arg required_blob_sha "$required_blob_sha" \
      --argjson smoke_present "$smoke_present" \
      --argjson required_missing "$required_missing" '
        {
          sha: $sha,
          truncated: false,
          tree: (
            (if $required_missing then [] else [{
              path: ".github/workflows/_required.yml",
              mode: "100644",
              type: "blob",
              sha: $required_blob_sha
            }] end)
            + (if $smoke_present then [{
              path: ".github/workflows/merge-queue-smoke.yml",
              mode: "100644",
              type: "blob",
              sha: "9999999999999999999999999999999999999999"
            }] else [] end)
          )
        }
      '
    ;;
  /git/tags/dddddddddddddddddddddddddddddddddddddddd)
    [[ "$repo" == Athena ]] || {
      echo "mock agent-contract annotated tag is Athena-only" >&2
      exit 1
    }
    tag_verified=${GH_AGENT_CONTRACT_TAG_SIGNATURE_OVERRIDE:-true}
    jq -n \
      --argjson verified "$tag_verified" \
      --arg sha dddddddddddddddddddddddddddddddddddddddd \
      --arg commit_sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '{
        sha: $sha,
        tag: "agent-contract-v1.0.0",
        object: {type: "commit", sha: $commit_sha},
        verification: {verified: $verified}
      }'
    ;;
  /commits/*)
    if [[ "$repo" == Athena &&
        "$suffix" == /commits/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb ]]; then
      commit_verified=${GH_AGENT_CONTRACT_COMMIT_SIGNATURE_OVERRIDE:-true}
      jq -n \
        --argjson verified "$commit_verified" \
        --arg sha bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb '{
          sha: $sha,
          commit: {verification: {verified: $verified}}
        }'
    elif [[ "$repo" == Athena &&
        "$suffix" == /commits/agent-contract-v1.0.0 ]]; then
      if [[ "${GH_AGENT_CONTRACT_TAG_LOOKUP_FAILURE:-false}" == true ]]; then
        echo "mock agent-contract release lookup failure" >&2
        exit 1
      fi
      sha=${GH_AGENT_CONTRACT_TAG_SHA_OVERRIDE:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
      jq -n --arg sha "$sha" '{
        sha: $sha,
        commit: {verification: {verified: true}}
      }'
    else
      sha=${GH_MAIN_SHA_OVERRIDE:-${GH_ACTION_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}
      jq -n --arg sha "$sha" '{sha: $sha}'
    fi
    ;;
  /branches/*/protection)
    protection_get_count=1
    if [[ -n "${GH_PROTECTION_GET_COUNT_FILE:-}" ]]; then
      protection_get_count=$(next_counter "$GH_PROTECTION_GET_COUNT_FILE")
    fi
    classic_state_file=$(classic_protection_state_path "$repo")
    if [[ -n "$classic_state_file" ]]; then
      if count_selected "${GH_CONCURRENT_CLASSIC_DISAPPEAR_AT:-}" \
          "$protection_get_count"; then
        jq -n null >"$classic_state_file"
      elif count_selected "${GH_CONCURRENT_CLASSIC_CONTENT_CHANGE_AT:-}" \
          "$protection_get_count" && [[ -s "$classic_state_file" ]] &&
          ! jq -e 'select(. != null)' "$classic_state_file" >/dev/null; then
        echo "mock cannot mutate absent classic protection" >&2
        exit 2
      elif count_selected "${GH_CONCURRENT_CLASSIC_CONTENT_CHANGE_AT:-}" \
          "$protection_get_count"; then
        jq '.required_status_checks.strict = false' "$classic_state_file" \
          >"$classic_state_file.tmp"
        mv "$classic_state_file.tmp" "$classic_state_file"
      fi
      if ! read_classic_protection_state "$repo"; then
        echo "gh: Branch not protected (HTTP 404)" >&2
        exit 1
      fi
    elif repo_selected "${GH_CLASSIC_PROTECTION_REPOS:-}" "$repo" ||
        count_selected "${GH_CLASSIC_PROTECTION_CHANGE_AT:-}" \
          "$protection_get_count"; then
      default_classic_protection
    elif fixture_v2_for_repo "$repo"; then
      captured_status=$(jq -r \
        '.api_captures.classic_branch_protection.status' \
        "$GH_RULESET_FIXTURE")
      if [[ "$captured_status" == 200 ]]; then
        jq -e '.api_captures.classic_branch_protection.response' \
          "$GH_RULESET_FIXTURE"
      elif [[ "$captured_status" == 404 ]]; then
        echo "gh: Branch not protected (HTTP 404)" >&2
        exit 1
      else
        echo "mock captured an unsupported classic-protection status" >&2
        exit 2
      fi
    else
      echo "gh: Branch not protected (HTTP 404)" >&2
      exit 1
    fi
    ;;
  /branches/*)
    branch=${suffix#/branches/}
    branch_get_count=1
    if [[ -n "${GH_BRANCH_GET_COUNT_FILE:-}" ]]; then
      branch_get_count=$(next_counter "$GH_BRANCH_GET_COUNT_FILE")
    fi
    if count_selected "${GH_MAIN_SHA_CHANGE_AT:-}" "$branch_get_count"; then
      sha=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
    elif [[ -z "${GH_MAIN_SHA_OVERRIDE:-}" && -z "${GH_ACTION_SHA:-}" ]] &&
        fixture_v2_for_repo "$repo"; then
      jq -e '.api_captures.default_branch_projection.response' \
        "$GH_RULESET_FIXTURE"
      exit 0
    else
      sha=${GH_MAIN_SHA_OVERRIDE:-${GH_ACTION_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}
    fi
    jq -n --arg name "$branch" --arg sha "$sha" \
      '{name: $name, commit: {sha: $sha}}'
    ;;
  /actions/runs/*/attempts/*/jobs*)
    run_id=${suffix#/actions/runs/}
    run_id=${run_id%%/*}
    attempt=${suffix#*/attempts/}
    attempt=${attempt%%/*}
    conclusion=${GH_GATE_CONCLUSION_OVERRIDE:-success}
    gate_count=${GH_GATE_TOTAL_COUNT_OVERRIDE:-1}
    non_gate_count=${GH_NON_GATE_JOB_COUNT:-3}
    merge_group_name_override=""
    merge_group_conclusion_override=""
    if [[ "$run_id" == 102 ]]; then
      merge_group_name_override=${GH_MERGE_GROUP_JOB_NAME_OVERRIDE:-}
      merge_group_conclusion_override=${GH_MERGE_GROUP_JOB_CONCLUSION_OVERRIDE:-}
    fi
    total_count=$((gate_count + non_gate_count))
    jobs_file="${TMPDIR:-/tmp}/mock-jobs-$$.json"
    jq -n \
      --arg conclusion "$conclusion" \
      --argjson run_id "$run_id" \
      --argjson attempt "$attempt" \
      --argjson gate_count "$gate_count" \
      --argjson non_gate_count "$non_gate_count" \
      --arg merge_group_name_override "$merge_group_name_override" \
      --arg merge_group_conclusion_override "$merge_group_conclusion_override" \
      --argjson total_count "$total_count" '{
        total_count: $total_count,
        jobs: (
          [range(0; $non_gate_count) | {
            id: ($run_id * 10 + . + 1),
            run_id: $run_id,
            run_attempt: $attempt,
            name: (
              if . == 0 and $merge_group_name_override != ""
              then $merge_group_name_override
              else ("worker-" + (. | tostring))
              end
            ),
            status: "completed",
            conclusion: (
              if . == 0 and $merge_group_conclusion_override != ""
              then $merge_group_conclusion_override
              else "success"
              end
            )
          }]
          + [range(0; $gate_count) | {
            id: ($run_id * 10 + . + 1),
            run_id: $run_id,
            run_attempt: $attempt,
            name: "required-checks-gate",
            status: "completed",
            conclusion: $conclusion
          }]
        )
      }' >"$jobs_file"
    if [[ "$slurp" == true ]]; then
      jq -s . "$jobs_file"
    else
      jq . "$jobs_file"
    fi
    rm -f "$jobs_file"
    ;;
  /actions/runs/*/attempts/*)
    run_id=${suffix#/actions/runs/}
    run_id=${run_id%%/*}
    attempt=${suffix#*/attempts/}
    case "$run_id" in
      101) event=pull_request; head_branch=feature/test ;;
      102) event=merge_group; head_branch=gh-readonly-queue/main/pr-1 ;;
      103) event=push; head_branch=main ;;
      *) event=unknown; head_branch=unknown ;;
    esac
    event=${GH_ACTION_EVENT_OVERRIDE:-$event}
    conclusion=${GH_ACTION_CONCLUSION_OVERRIDE:-success}
    sha=${GH_ACTION_SHA_OVERRIDE:-${GH_ACTION_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}
    full_name=${GH_ACTION_REPO_OVERRIDE:-HomericIntelligence/$repo}
    returned_id=${GH_ACTION_ID_OVERRIDE:-$run_id}
    returned_attempt=${GH_ACTION_ATTEMPT_OVERRIDE:-$attempt}
    head_branch=${GH_ACTION_HEAD_BRANCH_OVERRIDE:-$head_branch}
    html_url=${GH_ACTION_HTML_URL_OVERRIDE:-https://github.com/HomericIntelligence/$repo/actions/runs/$run_id}
    check_suite_id=${GH_CHECK_SUITE_ID_OVERRIDE:-$((run_id * 100))}
    workflow_name=${GH_ACTION_WORKFLOW_NAME_OVERRIDE:-Required Checks}
    workflow_path=${GH_ACTION_WORKFLOW_PATH_OVERRIDE:-.github/workflows/_required.yml}
    workflow_id=${GH_ACTION_WORKFLOW_ID_OVERRIDE:-9001}
    provider_sha=${GH_ACTION_REFERENCED_WORKFLOW_SHA_OVERRIDE:-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb}
    provider_path=${GH_ACTION_REFERENCED_WORKFLOW_PATH_OVERRIDE:-HomericIntelligence/Athena/.github/workflows/_agent-contract.yml@$provider_sha}
    provider_count=${GH_ACTION_REFERENCED_WORKFLOW_COUNT_OVERRIDE:-1}
    run_updated_at=${GH_ACTION_RUN_UPDATED_AT_OVERRIDE:-${GH_EVIDENCE_OBSERVED_AT:-2026-08-27T19:00:00Z}}
    jq -n \
      --argjson id "$returned_id" \
      --argjson run_attempt "$returned_attempt" \
      --argjson check_suite_id "$check_suite_id" \
      --argjson workflow_id "$workflow_id" \
      --argjson provider_count "$provider_count" \
      --arg event "$event" \
      --arg conclusion "$conclusion" \
      --arg sha "$sha" \
      --arg head_branch "$head_branch" \
      --arg full_name "$full_name" \
      --arg html_url "$html_url" \
      --arg workflow_name "$workflow_name" \
      --arg workflow_path "$workflow_path" \
      --arg provider_path "$provider_path" \
      --arg provider_sha "$provider_sha" \
      --arg run_updated_at "$run_updated_at" '{
        id: $id,
        run_attempt: $run_attempt,
        check_suite_id: $check_suite_id,
        workflow_id: $workflow_id,
        name: $workflow_name,
        path: $workflow_path,
        event: $event,
        status: "completed",
        conclusion: $conclusion,
        head_sha: $sha,
        head_branch: $head_branch,
        html_url: $html_url,
        created_at: $run_updated_at,
        updated_at: $run_updated_at,
        referenced_workflows: [range(0; $provider_count) | {
          path: $provider_path,
          sha: $provider_sha
        }],
        repository: {full_name: $full_name}
      }'
    ;;
  /check-suites/*/check-runs*)
    check_suite_id=${suffix#/check-suites/}
    check_suite_id=${check_suite_id%%/*}
    sha=${GH_ACTION_SHA_OVERRIDE:-${GH_ACTION_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}
    conclusion=${GH_GATE_CONCLUSION_OVERRIDE:-success}
    app_id=${GH_GATE_APP_ID_OVERRIDE:-15368}
    total_count=${GH_GATE_TOTAL_COUNT_OVERRIDE:-1}
    checks_file="${TMPDIR:-/tmp}/mock-checks-$$.json"
    jq -n \
      --argjson check_suite_id "$check_suite_id" \
      --argjson app_id "$app_id" \
      --argjson total_count "$total_count" \
      --arg conclusion "$conclusion" \
      --arg sha "$sha" '{
        total_count: $total_count,
        check_runs: ([range(0; $total_count) | {
          id: ($check_suite_id * 10 + . + 1),
          name: "required-checks-gate",
          status: "completed",
          conclusion: $conclusion,
          head_sha: $sha,
          check_suite: {id: $check_suite_id},
          app: {id: $app_id}
        }])
      }' >"$checks_file"
    if [[ "$slurp" == true ]]; then
      jq -s . "$checks_file"
    else
      jq . "$checks_file"
    fi
    rm -f "$checks_file"
    ;;
  /rules/branches/*)
    effective_file="${TMPDIR:-/tmp}/mock-effective-rules-$$.json"
    effective_final="${TMPDIR:-/tmp}/mock-effective-rules-final-$$.json"
    effective_get_count=1
    if [[ -n "${GH_EFFECTIVE_GET_COUNT_FILE:-}" ]]; then
      effective_get_count=$(next_counter "$GH_EFFECTIVE_GET_COUNT_FILE")
    fi
    if fixture_v2_for_repo "$repo"; then
      if [[ "$slurp" == true ]]; then
        jq '[.api_captures.effective_default_branch_rules.pages[].response]' \
          "$GH_RULESET_FIXTURE"
      else
        jq '.api_captures.effective_default_branch_rules.pages[].response' \
          "$GH_RULESET_FIXTURE"
      fi
    else
      effective_state_source=$(ruleset_state_path "$repo")
      effective_state_temp=""
      if [[ -z "$effective_state_source" || ! -s "$effective_state_source" ]]; then
        effective_state_temp="${TMPDIR:-/tmp}/mock-effective-state-$$.json"
        jq -n null >"$effective_state_temp"
        effective_state_source=$effective_state_temp
      fi
      jq --arg source "HomericIntelligence/$repo" \
        --slurpfile current "$effective_state_source" '[
        .rulesets[] as $captured
        | (if (($current[0] | type) == "object" and
              $current[0].id == $captured.id)
            then $current[0]
            else $captured
            end)
        | select(.target == "branch" and .enforcement == "active") as $ruleset
        | $ruleset.rules[]
        | {
            type,
            ruleset_id: $ruleset.id,
            ruleset_source_type: $ruleset.source_type,
            ruleset_source: (
              if $ruleset.source_type == "Repository"
              then $source
              else $ruleset.source
              end
            ),
            parameters: (.parameters // null)
          }
      ]' "$GH_RULESET_FIXTURE" >"$effective_file"
      if [[ -n "$effective_state_temp" ]]; then
        rm -f "$effective_state_temp"
      fi
      if repo_selected "${GH_INHERITED_RULESET_REPOS:-}" "$repo" ||
          count_selected "${GH_EFFECTIVE_OVERLAP_AT:-}" \
            "$effective_get_count"; then
        overlap_id=999999
        if count_selected "${GH_EFFECTIVE_OVERLAP_AT:-}" \
            "$effective_get_count"; then
          overlap_id=999998
        fi
        jq --argjson overlap_id "$overlap_id" '. + [{
          type: "required_status_checks",
          ruleset_id: $overlap_id,
          ruleset_source_type: "Organization",
          ruleset_source: "HomericIntelligence",
          parameters: {
            strict_required_status_checks_policy: false,
            do_not_enforce_on_create: false,
            required_status_checks: [{context: "legacy-check", integration_id: 15368}]
          }
          }]' "$effective_file" >"$effective_final"
      else
        jq . "$effective_file" >"$effective_final"
      fi
      if count_selected "${GH_EFFECTIVE_PARAMETER_MISMATCH_AT:-}" \
          "$effective_get_count"; then
        jq 'map(
          if .type == "required_status_checks"
          then .parameters.required_status_checks = [{
            context: "concurrent-check",
            integration_id: 15368
          }]
          else .
          end
        )' "$effective_final" >"$effective_file"
        mv "$effective_file" "$effective_final"
      fi
      if [[ "$slurp" == true ]]; then
        jq -s . "$effective_final"
      else
        jq . "$effective_final"
      fi
    fi
    rm -f "$effective_file" "$effective_final"
    ;;
  /actions/runs/*/jobs)
    run_id=${suffix#/actions/runs/}
    run_id=${run_id%/jobs}
    conclusion=${GH_GATE_CONCLUSION_OVERRIDE:-success}
    jq -n --arg conclusion "$conclusion" --argjson run_id "$run_id" '{
      total_count: 1,
      jobs: [{
        id: ($run_id * 10 + 1),
        name: "required-checks-gate",
        status: "completed",
        conclusion: $conclusion
      }]
    }'
    ;;
  /actions/runs/*)
    run_id=${suffix#/actions/runs/}
    case "$run_id" in
      101) event=pull_request ;;
      102) event=merge_group ;;
      103) event=push ;;
      *) event=unknown ;;
    esac
    event=${GH_ACTION_EVENT_OVERRIDE:-$event}
    conclusion=${GH_ACTION_CONCLUSION_OVERRIDE:-success}
    sha=${GH_ACTION_SHA_OVERRIDE:-${GH_ACTION_SHA:-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa}}
    full_name=${GH_ACTION_REPO_OVERRIDE:-HomericIntelligence/$repo}
    returned_id=${GH_ACTION_ID_OVERRIDE:-$run_id}
    html_url=${GH_ACTION_HTML_URL_OVERRIDE:-https://github.com/HomericIntelligence/$repo/actions/runs/$run_id}
    jq -n \
      --argjson id "$returned_id" \
      --arg event "$event" \
      --arg conclusion "$conclusion" \
      --arg sha "$sha" \
      --arg full_name "$full_name" \
      --arg html_url "$html_url" '{
        id: $id,
        name: "Required Checks",
        event: $event,
        status: "completed",
        conclusion: $conclusion,
        head_sha: $sha,
        html_url: $html_url,
        repository: {full_name: $full_name}
      }'
    ;;
  /rulesets\?includes_parents=true*|/rulesets\?includes_parents=false*)
    list_count=1
    if [[ -n "${GH_RULESET_LIST_COUNT_FILE:-}" ]]; then
      list_count=$(next_counter "$GH_RULESET_LIST_COUNT_FILE")
    fi
    if count_selected "${GH_FAIL_RULESET_LIST_AT:-}" "$list_count"; then
      echo "mock ruleset list failure at call $list_count" >&2
      exit 1
    fi
    if count_selected "${GH_CORRUPT_POLICY_SOURCE_AT_RULESET_LIST:-}" \
        "$list_count" && [[ -n "${GH_POLICY_SOURCE_PATH:-}" ]]; then
      jq -n '{}' >"$GH_POLICY_SOURCE_PATH.tmp"
      mv "$GH_POLICY_SOURCE_PATH.tmp" "$GH_POLICY_SOURCE_PATH"
    fi
    if count_selected "${GH_CORRUPT_EVIDENCE_SOURCE_AT_RULESET_LIST:-}" \
        "$list_count" && [[ -n "${GH_EVIDENCE_SOURCE_PATH:-}" ]]; then
      jq -n '{}' >"$GH_EVIDENCE_SOURCE_PATH.tmp"
      mv "$GH_EVIDENCE_SOURCE_PATH.tmp" "$GH_EVIDENCE_SOURCE_PATH"
    fi
    include_parents=false
    [[ "$suffix" == *"includes_parents=true"* ]] && include_parents=true
    list_file="${TMPDIR:-/tmp}/mock-rulesets-$$.json"
    list_final="${TMPDIR:-/tmp}/mock-rulesets-final-$$.json"
    if [[ "$include_parents" == true ]] && fixture_v2_for_repo "$repo"; then
      if [[ "$slurp" == true ]]; then
        jq '[.api_captures.rulesets_including_parents.pages[].response]' \
          "$GH_RULESET_FIXTURE"
      else
        jq '.api_captures.rulesets_including_parents.pages[].response' \
          "$GH_RULESET_FIXTURE"
      fi
    else
      list_state_source=$(ruleset_state_path "$repo")
      list_state_temp=""
      if [[ -z "$list_state_source" || ! -s "$list_state_source" ]]; then
        list_state_temp="${TMPDIR:-/tmp}/mock-ruleset-list-state-$$.json"
        jq -n null >"$list_state_temp"
        list_state_source=$list_state_temp
      fi
      jq --arg name_override "${GH_RULESET_LIST_NAME_OVERRIDE:-}" \
        --arg source "HomericIntelligence/$repo" \
        --slurpfile current "$list_state_source" '
        [.rulesets | to_entries[] as $entry
        | (if (($current[0] | type) == "object"
              and $current[0].id == $entry.value.id)
            then $current[0]
            else $entry.value
            end)
        | {
          id,
          name: (
            if $name_override != "" and $entry.key == 0
            then $name_override
            else .name
            end
          ),
          target,
          source: $source,
          source_type,
          enforcement
        }]
      ' "$GH_RULESET_FIXTURE" >"$list_file"
      if [[ -n "$list_state_temp" ]]; then
        rm -f "$list_state_temp"
      fi
      if count_selected "${GH_RULESET_LIST_EXTRA_AT:-}" "$list_count"; then
        jq '. + [{
          id: 999998,
          name: "concurrent-main-policy",
          target: "branch",
          source: "HomericIntelligence",
          source_type: "Organization",
          enforcement: "active"
        }]' "$list_file" >"$list_final"
      elif count_selected "${GH_RULESET_LIST_DUPLICATE_BASELINE_AT:-}" \
          "$list_count"; then
        jq --arg source "HomericIntelligence/$repo" '. + [{
          id: 999997,
          name: "homeric-main-baseline",
          target: "branch",
          source: $source,
          source_type: "Repository",
          enforcement: "disabled"
        }]' "$list_file" >"$list_final"
      elif count_selected "${GH_RULESET_LIST_UNKNOWN_ENFORCEMENT_AT:-}" \
          "$list_count"; then
        jq '.[0].enforcement = "future"' "$list_file" >"$list_final"
      elif [[ "$repo" == Athena &&
          "${GH_AGENT_CONTRACT_TAG_RULESET_MODE:-protected}" != missing ]]; then
        jq '. + [{
          id: 7001,
          name: "immutable-agent-contract-releases",
          target: "tag",
          source: "HomericIntelligence/Athena",
          source_type: "Repository",
          enforcement: "active"
        }]' "$list_file" >"$list_final"
      elif [[ "$include_parents" == true ]] && \
          repo_selected "${GH_INHERITED_RULESET_REPOS:-}" "$repo"; then
        jq '. + [{
          id: 999999,
          name: "inherited-main-policy",
          target: "branch",
          source: "HomericIntelligence",
          source_type: "Organization",
          enforcement: "active"
        }]' "$list_file" >"$list_final"
      else
        jq . "$list_file" >"$list_final"
      fi
      if [[ "$slurp" == true ]]; then
        jq -s . "$list_final"
      else
        jq . "$list_final"
      fi
    fi
    rm -f "$list_file" "$list_final"
    ;;
  /rulesets/7001)
    tag_ruleset_mode=${GH_AGENT_CONTRACT_TAG_RULESET_MODE:-protected}
    jq -n --arg mode "$tag_ruleset_mode" '{
      id: 7001,
      name: "immutable-agent-contract-releases",
      target: "tag",
      source: "HomericIntelligence/Athena",
      source_type: "Repository",
      enforcement: "active",
      conditions: {
        ref_name: {
          include: ["refs/tags/agent-contract-v*"],
          exclude: []
        }
      },
      bypass_actors: (
        if $mode == "bypass"
        then [{actor_id: 5, actor_type: "RepositoryRole", bypass_mode: "always"}]
        else []
        end
      ),
      rules: (
        if $mode == "retargetable"
        then [{type: "deletion"}]
        else [{type: "deletion"}, {type: "update"}]
        end
      )
    }'
    ;;
  /rulesets/999999)
    jq -n '{
      id: 999999,
      name: "inherited-main-policy",
      target: "branch",
      source: "HomericIntelligence",
      source_type: "Organization",
      enforcement: "active",
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
      bypass_actors: [],
      rules: [{type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: [{context: "legacy-check", integration_id: 15368}]
      }}]
    }'
    ;;
  /rulesets/999998)
    jq -n '{
      id: 999998,
      name: "concurrent-main-policy",
      target: "branch",
      source: "HomericIntelligence",
      source_type: "Organization",
      enforcement: "active",
      conditions: {ref_name: {include: ["~DEFAULT_BRANCH"], exclude: []}},
      bypass_actors: [],
      rules: [{type: "required_status_checks", parameters: {
        strict_required_status_checks_policy: false,
        do_not_enforce_on_create: false,
        required_status_checks: [{context: "concurrent-check", integration_id: 15368}]
      }}]
    }'
    ;;
  /rulesets/*)
    ruleset_id=${suffix##*/}
    detail_count=1
    if [[ -n "${GH_DETAIL_GET_COUNT_FILE:-}" ]]; then
      detail_count=$(next_counter "$GH_DETAIL_GET_COUNT_FILE")
    fi
    if count_selected "${GH_FAIL_DETAIL_GET_AT:-}" "$detail_count"; then
      echo "mock detail GET failure at call $detail_count" >&2
      exit 1
    fi
    if count_selected "${GH_SIGNAL_HUP_DETAIL_GET_AT:-}" "$detail_count"; then
      echo "mock sends HUP during detail GET at call $detail_count" >&2
      kill -HUP "$PPID"
      exit 1
    fi
    if count_selected "${GH_CONCURRENT_RULESET_CHANGE_AT:-}" "$detail_count"; then
      state_file=$(ruleset_state_path "$repo")
      [[ -n "$state_file" && -s "$state_file" ]] || {
        echo "mock ruleset state file is required for a concurrent change" >&2
        exit 2
      }
      jq '.conditions.ref_name.include = ["refs/heads/concurrent"]' \
        "$state_file" >"$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
    fi
    if count_selected "${GH_CONCURRENT_RULESET_UNKNOWN_AT:-}" "$detail_count"; then
      state_file=$(ruleset_state_path "$repo")
      [[ -n "$state_file" && -s "$state_file" ]] || {
        echo "mock ruleset state file is required for an unknown-field change" >&2
        exit 2
      }
      jq '.future_guard = true' "$state_file" >"$state_file.tmp"
      mv "$state_file.tmp" "$state_file"
    fi
    read_ruleset_state "$repo" "$ruleset_id"
    ;;
  *)
    echo "unexpected gh api endpoint: $endpoint" >&2
    exit 2
    ;;
esac
