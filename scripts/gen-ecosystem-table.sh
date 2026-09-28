#!/usr/bin/env bash
#
# gen-ecosystem-table.sh — Generate the 8-category Ecosystem CI Status board.
#
# For every repo referenced as a submodule in .gitmodules (plus Odysseus itself),
# this script reads the check-runs emitted on the default branch, maps each to one
# of the 8 canonical categories, and emits a Markdown table with one shields.io
# per-check-run badge per present category. Categories with no matching check are
# marked as a gap (linking a tracking issue when GAP_ISSUES provides one).
#
# Canonical categories (see docs/ci-naming-convention.md):
#   build · test · lint · package · install · release · security · custom
#
# The table is auto-derived so it never drifts from the repos' real CI.
#
# Requires the `gh` CLI authenticated with org read access.
#
# Usage:
#   gen-ecosystem-table.sh                 Print the table to stdout.
#   gen-ecosystem-table.sh --output PATH   Also write the table to PATH.
#   gen-ecosystem-table.sh --inject README.md
#                                          Replace the block between the
#                                          <!-- ECOSYSTEM-CI-TABLE:START --> and
#                                          <!-- ECOSYSTEM-CI-TABLE:END --> markers
#                                          in README.md with the generated table.
#
set -euo pipefail

ORG="HomericIntelligence"
OUTPUT_PATH=""
INJECT_PATH=""

while [ $# -gt 0 ]; do
  case "$1" in
    --output) OUTPUT_PATH="${2:-}"; [ -z "$OUTPUT_PATH" ] && { echo "error: --output requires a path" >&2; exit 2; }; shift 2 ;;
    --inject) INJECT_PATH="${2:-}"; [ -z "$INJECT_PATH" ] && { echo "error: --inject requires a path" >&2; exit 2; }; shift 2 ;;
    -h|--help) sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { echo "error: gh CLI not found" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "error: python3 not found" >&2; exit 2; }

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || { echo "error: not in a git repo" >&2; exit 2; }
GITMODULES="$REPO_ROOT/.gitmodules"
[ -f "$GITMODULES" ] && [ ! -L "$GITMODULES" ] || {
  echo "error: canonical .gitmodules is missing, nonregular, or a symlink" >&2
  exit 2
}

SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT_PUBLISHER="$SCRIPT_ROOT/safe_report_publish.py"
[ -f "$REPORT_PUBLISHER" ] && [ ! -L "$REPORT_PUBLISHER" ] || {
  echo "error: safe report publisher is missing or unsafe" >&2
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
    echo "error: could not read the canonical submodule path inventory" >&2
    return 2
  fi
  if ! url_rows=$(git config --file "$GITMODULES" \
      --get-regexp '^submodule\..*\.url$' 2>/dev/null); then
    echo "error: could not read the canonical submodule URL inventory" >&2
    return 2
  fi
  [ -n "$path_rows" ] && [ -n "$url_rows" ] || {
    echo "error: canonical submodule inventory is empty" >&2
    return 2
  }

  while IFS= read -r row; do
    if [[ ! "$row" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
      echo "error: malformed submodule path inventory entry" >&2
      return 2
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    name="${key#submodule.}"
    name="${name%.path}"
    if array_contains "$name" "${path_names[@]:+${path_names[@]}}" \
        || [[ ! "$value" =~ ^[A-Za-z0-9._/-]+$ \
        || "$value" = /* || "$value" = */ || "$value" = *//* ]]; then
      echo "error: duplicate or unsafe submodule path: $value" >&2
      return 2
    fi
    IFS='/' read -r -a path_segments <<< "$value"
    for segment in "${path_segments[@]}"; do
      if [ -z "$segment" ] || [ "$segment" = . ] || [ "$segment" = .. ]; then
        echo "error: unsafe submodule path segment in $value" >&2
        return 2
      fi
    done
    [ "$name" = "$value" ] || {
      echo "error: submodule section and path differ: $name / $value" >&2
      return 2
    }
    path_names+=("$name")
  done <<< "$path_rows"

  while IFS= read -r row; do
    if [[ ! "$row" =~ ^([^[:space:]]+)[[:space:]]+(.+)$ ]]; then
      echo "error: malformed submodule URL inventory entry" >&2
      return 2
    fi
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    name="${key#submodule.}"
    name="${name%.url}"
    if array_contains "$name" "${url_names[@]:+${url_names[@]}}"; then
      echo "error: duplicate submodule URL entry: $name" >&2
      return 2
    fi
    case "$value" in
      "https://github.com/$ORG/"*.git) repo_name="${value#"https://github.com/$ORG/"}" ;;
      "git@github.com:$ORG/"*.git) repo_name="${value#"git@github.com:$ORG/"}" ;;
      *)
        echo "error: unsupported canonical submodule URL: $value" >&2
        return 2
        ;;
    esac
    repo_name="${repo_name%.git}"
    if [[ ! "$repo_name" =~ ^[A-Za-z0-9_.-]+$ ]] \
        || array_contains "$repo_name" "${seen_repos[@]:+${seen_repos[@]}}"; then
      echo "error: duplicate or unsafe repository name from $value" >&2
      return 2
    fi
    seen_repos+=("$repo_name")
    url_names+=("$name")
    url_repos+=("$ORG/$repo_name")
  done <<< "$url_rows"

  if [ "${#path_names[@]}" -ne "${#url_names[@]}" ]; then
    echo "error: submodule path and URL inventories have different sizes" >&2
    return 2
  fi
  SUBS=()
  for name in "${path_names[@]}"; do
    matched=""
    for index in "${!url_names[@]}"; do
      if [ "${url_names[$index]}" = "$name" ]; then
        matched="${url_repos[$index]}"
        break
      fi
    done
    if [ -z "$matched" ]; then
      echo "error: submodule path has no matching URL: $name" >&2
      return 2
    fi
    SUBS+=("$matched")
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

parse_commit_sha() {
  python3 -I -S -c '
import json
import re
import sys
value = json.load(sys.stdin)
sha = value.get("sha") if isinstance(value, dict) else None
if not isinstance(sha, str) or re.fullmatch(r"[0-9a-fA-F]{40,64}", sha) is None:
    raise SystemExit(1)
print(sha)
'
}

parse_check_pages() {
  python3 -I -S -c '
import json
import sys
pages = json.load(sys.stdin)
if not isinstance(pages, list) or not pages:
    raise SystemExit(1)
runs = []
expected = None
for page in pages:
    if not isinstance(page, dict):
        raise SystemExit(1)
    total = page.get("total_count")
    page_runs = page.get("check_runs")
    if isinstance(total, bool) or not isinstance(total, int) or total < 0:
        raise SystemExit(1)
    if not isinstance(page_runs, list):
        raise SystemExit(1)
    if expected is None:
        expected = total
    elif total != expected:
        raise SystemExit(1)
    runs.extend(page_runs)
if expected != len(runs):
    raise SystemExit(1)
seen = set()
for run in runs:
    name = run.get("name") if isinstance(run, dict) else None
    if not isinstance(name, str) or not name or any(ord(char) < 32 for char in name):
        raise SystemExit(1)
    if name not in seen:
        seen.add(name)
        print(name)
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

shields_label() {
  python3 -I -S - "$1" <<'PY'
import sys
import urllib.parse
value = sys.argv[1].replace("_", "__").replace("-", "--").replace(" ", "_")
print(urllib.parse.quote(value, safe=""))
PY
}

OUTPUT_BINDING=""
INJECT_BINDING=""
if [ -n "$OUTPUT_PATH" ]; then
  OUTPUT_BINDING=$(bind_report_sink "$OUTPUT_PATH" replace) || exit 2
fi
if [ -n "$INJECT_PATH" ]; then
  INJECT_BINDING=$(bind_report_sink "$INJECT_PATH" inject) || exit 2
fi
if [ -n "$OUTPUT_BINDING" ] && [ -n "$INJECT_BINDING" ]; then
  require_distinct_sinks "$OUTPUT_BINDING" "$INJECT_BINDING" || exit 2
fi

declare -a SUBS=()
load_submodule_repos
REPOS=("$ORG/Odysseus" "${SUBS[@]}")

# Map an emitted check-run name to a canonical category (echoes the category, or
# empty if it belongs to "custom"/unmatched). Order matters: most specific first.
classify() {
  local n="$1"
  shopt -s nocasematch
  case "$n" in
    security/*|*codeql*|*"analyze ("*|*gitleaks*|*trivy*|*semgrep*|*dependency*scan*|*secrets*scan*|*sast*) echo security ;;
    release|release-please|"release please"|*publish*) echo release ;;
    install|install-test|*install*smoke*|*install*verify*) echo install ;;
    package|*sdist*|*wheel*|*sbom*|*container*image*|*"build, scan, and push"*) echo package ;;
    build|idempotent-build|build-test|"build & test"|build*) echo build ;;
    test|unit-tests|integration-tests|bats|*tests|*test) echo test ;;
    lint|markdownlint|hadolint|*lint*|ruff|shellcheck|forbid-suppressions|justfile-check) echo lint ;;
    *) echo "" ;;  # unmatched -> custom
  esac
  shopt -u nocasematch
}

badge() { # repo branch check-run-name label
  local repo="$1" branch="$2" name="$3" label="$4"
  local branch_enc name_enc label_enc display
  branch_enc=$(urlencode "$branch")
  name_enc=$(urlencode "$name")
  label_enc=$(shields_label "$label")
  display=$(markdown_escape "$label")
  printf '[![%s](https://img.shields.io/github/check-runs/%s/%s?nameFilter=%s&label=%s)](https://github.com/%s/actions)' \
    "$display" "$repo" "$branch_enc" "$name_enc" "$label_enc" "$repo"
}

report=""
append() { report+="$1"$'\n'; }

append "## Ecosystem CI Status"
append ""
append "> Auto-generated by \`scripts/gen-ecosystem-table.sh\` — do not edit by hand."
append "> Each cell shows the live status of that repo's canonical CI category (see"
append "> [docs/ci-naming-convention.md](docs/ci-naming-convention.md)). A 🔗 links the tracking"
append "> issue for a category the repo does not yet emit. The **Custom** column shows one live"
append "> status badge per leftover check that does not map to the seven named categories."
append ""
append "| Repository | Build | Test | Lint | Package | Install | Release | Security | Custom |"
append "|------------|-------|------|------|---------|---------|---------|----------|--------|"

for repo in "${REPOS[@]}"; do
  short="${repo#"$ORG"/}"
  if ! branch_json=$(gh repo view "$repo" --json defaultBranchRef 2>/dev/null); then
    echo "error: default-branch read unavailable for $repo" >&2
    exit 2
  fi
  if ! branch=$(printf '%s' "$branch_json" | parse_default_branch); then
    echo "error: default-branch read malformed for $repo" >&2
    exit 2
  fi
  unset branch_json
  branch_endpoint=$(urlencode "$branch")
  if ! commit_json=$(gh api "repos/$repo/commits/$branch_endpoint" 2>/dev/null); then
    echo "error: default-branch commit read unavailable for $repo" >&2
    exit 2
  fi
  if ! sha=$(printf '%s' "$commit_json" | parse_commit_sha); then
    echo "error: default-branch commit read malformed for $repo" >&2
    exit 2
  fi
  unset commit_json
  if ! checks_json=$(gh api --paginate --slurp \
      "repos/$repo/commits/$sha/check-runs?per_page=100" 2>/dev/null); then
    echo "error: check-run read unavailable for $repo at $sha" >&2
    exit 2
  fi
  if ! names_raw=$(printf '%s' "$checks_json" | parse_check_pages); then
    echo "error: check-run read incomplete or malformed for $repo at $sha" >&2
    exit 2
  fi
  unset checks_json
  names=()
  if [ -n "$names_raw" ]; then
    while IFS= read -r n; do
      names+=("$n")
    done <<< "$names_raw"
  fi

  # bucket names by category
  first_build=""
  first_test=""
  first_lint=""
  first_package=""
  first_install=""
  first_release=""
  first_security=""
  customs=()
  for n in "${names[@]:+${names[@]}}"; do
    cat=$(classify "$n")
    if [ -z "$cat" ]; then customs+=("$n"); continue; fi
    case "$cat" in
      build) [ -n "$first_build" ] || first_build="$n" ;;
      test) [ -n "$first_test" ] || first_test="$n" ;;
      lint) [ -n "$first_lint" ] || first_lint="$n" ;;
      package) [ -n "$first_package" ] || first_package="$n" ;;
      install) [ -n "$first_install" ] || first_install="$n" ;;
      release) [ -n "$first_release" ] || first_release="$n" ;;
      security) [ -n "$first_security" ] || first_security="$n" ;;
    esac
  done

  row="| [$short](https://github.com/$repo) |"
  for cat in build test lint package install release security; do
    case "$cat" in
      build) check_name="$first_build" ;;
      test) check_name="$first_test" ;;
      lint) check_name="$first_lint" ;;
      package) check_name="$first_package" ;;
      install) check_name="$first_install" ;;
      release) check_name="$first_release" ;;
      security) check_name="$first_security" ;;
    esac
    if [ -n "$check_name" ]; then
      row+=" $(badge "$repo" "$branch" "$check_name" "$cat") |"
    else
      # gap: link tracking issue if provided via GAP_ISSUES env (repo:cat=url,...)
      url=""
      if [ -n "${GAP_ISSUES:-}" ]; then
        url=$(printf '%s' "$GAP_ISSUES" | tr ',' '\n' | sed -n "s#^${short}:${cat}=##p" | head -1)
      fi
      if [ -n "$url" ]; then row+=" [🔗 planned]($url) |"; else row+=" — |"; fi
    fi
  done
  # custom cell: one shields.io per-check-run badge per leftover check (or em dash)
  if [ "${#customs[@]}" -gt 0 ]; then
    cell=""
    for c in "${customs[@]}"; do
      cell+=" $(badge "$repo" "$branch" "$c" "$c")"
    done
    row+="$cell |"
  else
    row+=" — |"
  fi
  append "$row"
done

append ""
append "> Generated $(date -u +%Y-%m-%dT%H:%M:%SZ)."

if [ -n "$OUTPUT_PATH" ]; then
  printf '%s' "$report" \
    | publish_report "$OUTPUT_PATH" replace "$OUTPUT_BINDING" || exit 2
fi
if [ -n "$INJECT_PATH" ]; then
  printf '%s' "$report" \
    | publish_report "$INJECT_PATH" inject "$INJECT_BINDING" || exit 2
fi
printf '%s' "$report"
