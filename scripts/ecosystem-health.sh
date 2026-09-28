#!/usr/bin/env bash
#
# ecosystem-health.sh — Check the health of all HomericIntelligence repos.
#
# For every repo referenced as a submodule in .gitmodules, this script reports:
#   - default branch name
#   - presence of LICENSE, CLAUDE.md, justfile, pixi.toml, README.md
#   - latest CI run conclusion on the default branch
#   - date of the last commit on the default branch
#
# Output is a Markdown table. Used by both the GitHub Actions workflow and the
# `just ecosystem-health` recipe.
#
# Requires the `gh` CLI authenticated with read access to the org.
#
# Usage:
#   ecosystem-health.sh                       Print the report to stdout.
#   ecosystem-health.sh --output PATH         Also write the report to PATH.
#   ecosystem-health.sh --github-summary      Also append to $GITHUB_STEP_SUMMARY.
#
# Flags may be combined.

set -euo pipefail

OUTPUT_PATH=""
GH_SUMMARY=0

while [ $# -gt 0 ]; do
  case "$1" in
    --output)
      OUTPUT_PATH="${2:-}"
      [ -z "$OUTPUT_PATH" ] && { printf 'error: --output requires a path\n' >&2; exit 2; }
      shift 2
      ;;
    --github-summary)
      GH_SUMMARY=1
      shift
      ;;
    -h|--help)
      sed -n '2,22p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'error: unknown argument: %s\n' "$1" >&2
      exit 2
      ;;
  esac
done

command -v gh >/dev/null 2>&1 || { printf 'error: gh CLI not found\n' >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { printf 'error: python3 not found\n' >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 2
}
GITMODULES="$REPO_ROOT/.gitmodules"
[ -f "$GITMODULES" ] && [ ! -L "$GITMODULES" ] || {
  printf 'error: canonical .gitmodules is missing, nonregular, or a symlink\n' >&2
  exit 2
}

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PUBLISHER="$SCRIPT_ROOT/safe_report_publish.py"
[ -f "$REPORT_PUBLISHER" ] && [ ! -L "$REPORT_PUBLISHER" ] || {
  printf 'error: safe report publisher is missing or unsafe\n' >&2
  exit 2
}

bind_report_sink() {
  python3 -I -S "$REPORT_PUBLISHER" bind "$1" "$2"
}

publish_report() {
  python3 -I -S "$REPORT_PUBLISHER" publish "$1" "$2" "$3"
}

require_distinct_sinks() {
  python3 -I -S "$REPORT_PUBLISHER" distinct "$1" "$2"
}

array_contains() {
  local needle="$1" candidate
  shift
  for candidate in "$@"; do
    [ "$candidate" = "$needle" ] && return 0
  done
  return 1
}

load_submodule_repos() {
  local path_rows url_rows row key value name repo_name segment index matched
  local -a path_names=() url_names=() url_repos=() path_segments=() seen_repos=()

  if ! path_rows=$(git config --file "$GITMODULES" \
      --get-regexp '^submodule\..*\.path$' 2>/dev/null); then
    printf 'error: could not read the canonical submodule path inventory\n' >&2
    return 2
  fi
  if ! url_rows=$(git config --file "$GITMODULES" \
      --get-regexp '^submodule\..*\.url$' 2>/dev/null); then
    printf 'error: could not read the canonical submodule URL inventory\n' >&2
    return 2
  fi
  [ -n "$path_rows" ] && [ -n "$url_rows" ] || {
    printf 'error: canonical submodule inventory is empty\n' >&2
    return 2
  }

  while IFS= read -r row; do
    if [[ ! "$row" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
      printf 'error: malformed submodule path inventory entry\n' >&2
      return 2
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    name="${key#submodule.}"
    name="${name%.path}"
    if array_contains "$name" "${path_names[@]:+${path_names[@]}}" \
        || [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ \
        || "$value" = /* || "$value" = */ || "$value" = *//* ]]; then
      printf 'error: duplicate or unsafe submodule path: %s\n' "$value" >&2
      return 2
    fi
    IFS='/' read -r -a path_segments <<< "$value"
    for segment in "${path_segments[@]}"; do
      if [ -z "$segment" ] || [ "$segment" = . ] || [ "$segment" = .. ]; then
        printf 'error: unsafe submodule path segment in %s\n' "$value" >&2
        return 2
      fi
    done
    [ "$name" = "$value" ] || {
      printf 'error: submodule section and path differ: %s / %s\n' "$name" "$value" >&2
      return 2
    }
    path_names+=("$name")
  done <<< "$path_rows"

  while IFS= read -r row; do
    if [[ ! "$row" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
      printf 'error: malformed submodule URL inventory entry\n' >&2
      return 2
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    name="${key#submodule.}"
    name="${name%.url}"
    if array_contains "$name" "${url_names[@]:+${url_names[@]}}"; then
      printf 'error: duplicate submodule URL entry: %s\n' "$name" >&2
      return 2
    fi
    case "$value" in
      https://github.com/HomericIntelligence/*.git)
        repo_name="${value#https://github.com/HomericIntelligence/}"
        ;;
      git@github.com:HomericIntelligence/*.git)
        repo_name="${value#git@github.com:HomericIntelligence/}"
        ;;
      *)
        printf 'error: unsupported canonical submodule URL: %s\n' "$value" >&2
        return 2
        ;;
    esac
    repo_name="${repo_name%.git}"
    if [[ ! "$repo_name" =~ ^[A-Za-z0-9_.-]+$ ]] \
        || array_contains "$repo_name" "${seen_repos[@]:+${seen_repos[@]}}"; then
      printf 'error: duplicate or unsafe repository name from %s\n' "$value" >&2
      return 2
    fi
    seen_repos+=("$repo_name")
    url_names+=("$name")
    url_repos+=("HomericIntelligence/$repo_name")
  done <<< "$url_rows"

  if [ "${#path_names[@]}" -ne "${#url_names[@]}" ]; then
    printf 'error: submodule path and URL inventories have different sizes\n' >&2
    return 2
  fi
  REPOS=()
  for name in "${path_names[@]}"; do
    matched=""
    for index in "${!url_names[@]}"; do
      if [ "${url_names[$index]}" = "$name" ]; then
        matched="${url_repos[$index]}"
        break
      fi
    done
    if [ -z "$matched" ]; then
      printf 'error: submodule path has no matching URL: %s\n' "$name" >&2
      return 2
    fi
    REPOS+=("$matched")
  done
}

parse_default_branch() {
  python3 -I -S -c '
import json
import sys
value = json.load(sys.stdin)
branch = value.get("defaultBranchRef") if isinstance(value, dict) else None
name = branch.get("name") if isinstance(branch, dict) else None
if not isinstance(name, str) or not name or any(ord(char) < 32 for char in name):
    raise SystemExit(1)
print(name)
'
}

parse_commit() {
  python3 -I -S -c '
import datetime
import json
import re
import sys
value = json.load(sys.stdin)
sha = value.get("sha") if isinstance(value, dict) else None
commit = value.get("commit") if isinstance(value, dict) else None
committer = commit.get("committer") if isinstance(commit, dict) else None
date = committer.get("date") if isinstance(committer, dict) else None
if not isinstance(sha, str) or re.fullmatch(r"[0-9a-fA-F]{40,64}", sha) is None:
    raise SystemExit(1)
if not isinstance(date, str):
    raise SystemExit(1)
try:
    parsed = datetime.datetime.fromisoformat(date.replace("Z", "+00:00"))
except ValueError as error:
    raise SystemExit(1) from error
if parsed.tzinfo is None:
    raise SystemExit(1)
print(f"{sha}\t{parsed.date().isoformat()}")
'
}

parse_tree() {
  python3 -I -S -c '
import json
import sys
value = json.load(sys.stdin)
if not isinstance(value, dict) or value.get("truncated") is not False:
    raise SystemExit(1)
tree = value.get("tree")
if not isinstance(tree, list):
    raise SystemExit(1)
seen = set()
for entry in tree:
    if not isinstance(entry, dict):
        raise SystemExit(1)
    path = entry.get("path")
    entry_type = entry.get("type")
    if not isinstance(path, str) or not path or any(ord(char) < 32 for char in path):
        raise SystemExit(1)
    if entry_type not in {"blob", "tree", "commit"} or path in seen:
        raise SystemExit(1)
    seen.add(path)
    if entry_type == "blob":
        print(path)
'
}

parse_ci() {
  python3 -I -S -c '
import json
import sys
value = json.load(sys.stdin)
if not isinstance(value, dict):
    raise SystemExit(1)
total = value.get("total_count")
runs = value.get("workflow_runs")
if isinstance(total, bool) or not isinstance(total, int) or total < 0:
    raise SystemExit(1)
if not isinstance(runs, list) or len(runs) > 1:
    raise SystemExit(1)
if total == 0:
    if runs:
        raise SystemExit(1)
    print("none")
    raise SystemExit(0)
if len(runs) != 1 or not isinstance(runs[0], dict):
    raise SystemExit(1)
status = runs[0].get("status")
conclusion = runs[0].get("conclusion")
if not isinstance(status, str) or not status or any(ord(char) < 32 for char in status):
    raise SystemExit(1)
if status != "completed" or conclusion is None:
    print("pending")
elif not isinstance(conclusion, str) or not conclusion \
        or any(ord(char) < 32 for char in conclusion):
        raise SystemExit(1)
else:
    print(conclusion)
'
}

urlencode() {
  python3 -I -S - "$1" <<'PY'
import sys
import urllib.parse
print(urllib.parse.quote(sys.argv[1], safe=""))
PY
}

markdown_escape() {
  python3 -I -S - "$1" <<'PY'
import sys
value = sys.argv[1]
for old, new in (("\\", "\\\\"), ("[", "\\["), ("]", "\\]"), ("|", "\\|")):
    value = value.replace(old, new)
print(value)
PY
}

check_file() {
  local file="$1" tree_path
  while IFS= read -r tree_path; do
    if [ "$tree_path" = "$file" ]; then
      printf '✅'
      return 0
    fi
  done <<< "${TREE_PATHS:-}"
  printf '❌'
}

format_ci() {
  case "$1" in
    success) printf '✅' ;;
    failure) printf '❌' ;;
    none) printf '⚠️ none' ;;
    pending) printf '⚠️ pending' ;;
    *) printf '⚠️ %s' "$1" ;;
  esac
}

if [ "$GH_SUMMARY" -eq 1 ] && [ -z "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf 'error: --github-summary requires GITHUB_STEP_SUMMARY\n' >&2
  exit 2
fi
OUTPUT_BINDING=""
SUMMARY_BINDING=""
if [ -n "$OUTPUT_PATH" ]; then
  OUTPUT_BINDING=$(bind_report_sink "$OUTPUT_PATH" replace) || exit 2
fi
if [ "$GH_SUMMARY" -eq 1 ]; then
  SUMMARY_BINDING=$(bind_report_sink "$GITHUB_STEP_SUMMARY" append) || exit 2
fi
if [ -n "$OUTPUT_BINDING" ] && [ -n "$SUMMARY_BINDING" ]; then
  require_distinct_sinks "$OUTPUT_BINDING" "$SUMMARY_BINDING" || exit 2
fi

declare -a REPOS=()
load_submodule_repos

# Build the report into a variable so it can be emitted to multiple sinks.
report=""
append() { report+="$1"$'\n'; }

append "# Ecosystem Health Status"
append ""
append "> Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`scripts/ecosystem-health.sh\`."
append ""
append "| Repo | Branch | LICENSE | CLAUDE.md | justfile | pixi.toml | README | CI | Last Commit |"
append "|------|--------|---------|-----------|----------|-----------|--------|----|-------------|"

healthy=0
total=0
for repo in "${REPOS[@]}"; do
  total=$((total + 1))
  if ! branch_json=$(gh repo view "$repo" --json defaultBranchRef 2>/dev/null); then
    printf 'error: default-branch read unavailable for %s\n' "$repo" >&2
    exit 2
  fi
  if ! branch=$(printf '%s' "$branch_json" | parse_default_branch); then
    printf 'error: default-branch read malformed for %s\n' "$repo" >&2
    exit 2
  fi
  unset branch_json
  branch_display=$(markdown_escape "$branch")
  branch_endpoint=$(urlencode "$branch")
  if ! commit_json=$(gh api "repos/${repo}/commits/${branch_endpoint}" 2>/dev/null); then
    printf 'error: default-branch commit read unavailable for %s\n' "$repo" >&2
    exit 2
  fi
  if ! commit_data=$(printf '%s' "$commit_json" | parse_commit); then
    printf 'error: default-branch commit read malformed for %s\n' "$repo" >&2
    exit 2
  fi
  unset commit_json
  IFS=$'\t' read -r sha last <<< "$commit_data"

  if ! tree_json=$(gh api "repos/${repo}/git/trees/${sha}?recursive=1" 2>/dev/null); then
    printf 'error: repository tree read unavailable for %s at %s\n' "$repo" "$sha" >&2
    exit 2
  fi
  if ! tree_paths=$(printf '%s' "$tree_json" | parse_tree); then
    printf 'error: repository tree read incomplete or malformed for %s at %s\n' \
      "$repo" "$sha" >&2
    exit 2
  fi
  unset tree_json
  TREE_PATHS="$tree_paths"

  branch_query=$(urlencode "$branch")
  if ! ci_json=$(gh api \
      "repos/${repo}/actions/runs?branch=${branch_query}&per_page=1" \
      2>/dev/null); then
    printf 'error: CI read unavailable for %s on %s\n' "$repo" "$branch" >&2
    exit 2
  fi
  if ! ci_state=$(printf '%s' "$ci_json" | parse_ci); then
    printf 'error: CI read incomplete or malformed for %s on %s\n' "$repo" "$branch" >&2
    exit 2
  fi
  unset ci_json

  lic=$(check_file "LICENSE")
  cla=$(check_file "CLAUDE.md")
  jf=$(check_file "justfile")
  px=$(check_file "pixi.toml")
  rd=$(check_file "README.md")
  ci=$(format_ci "$ci_state")
  ci_display=$(markdown_escape "$ci")

  # A repo is "fully healthy" when all five standard files are present and CI is green.
  if [ "$lic" = "✅" ] && [ "$cla" = "✅" ] && [ "$jf" = "✅" ] && \
     [ "$px" = "✅" ] && [ "$rd" = "✅" ] && [ "$ci" = "✅" ]; then
    healthy=$((healthy + 1))
  fi

  append "| ${repo} | ${branch_display} | ${lic} | ${cla} | ${jf} | ${px} | ${rd} | ${ci_display} | ${last} |"
done

append ""
append "**${healthy}/${total} repos fully healthy** (all standard files present + CI green)."

if [ -n "$OUTPUT_PATH" ]; then
  printf '%s' "$report" \
    | publish_report "$OUTPUT_PATH" replace "$OUTPUT_BINDING" || exit 2
fi
if [ "$GH_SUMMARY" -eq 1 ]; then
  printf '%s' "$report" \
    | publish_report "$GITHUB_STEP_SUMMARY" append "$SUMMARY_BINDING" || exit 2
fi
printf '%s' "$report"
