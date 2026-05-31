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

set -uo pipefail

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

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || {
  printf 'error: not inside a git repository\n' >&2
  exit 2
}
GITMODULES="$REPO_ROOT/.gitmodules"
[ -f "$GITMODULES" ] || { printf 'error: %s not found\n' "$GITMODULES" >&2; exit 2; }

# Derive {org}/{repo} pairs from the submodule URLs.
mapfile -t REPOS < <(
  git config --file "$GITMODULES" --get-regexp 'submodule\..*\.url' \
    | awk '{print $2}' \
    | sed -E 's#\.git$##; s#^https://github.com/##; s#^git@github.com:##'
)

[ "${#REPOS[@]}" -gt 0 ] || { printf 'error: no submodule repos found\n' >&2; exit 2; }

check_file() {
  # Returns a check or cross mark for whether a file exists in the repo.
  local repo="$1" file="$2"
  if gh api "repos/${repo}/contents/${file}" >/dev/null 2>&1; then
    printf '✅'
  else
    printf '❌'
  fi
}

check_ci() {
  local repo="$1" branch="$2" conclusion
  conclusion=$(gh api "repos/${repo}/actions/runs?branch=${branch}&per_page=1" \
    --jq '.workflow_runs[0].conclusion // "none"' 2>/dev/null || echo "error")
  case "$conclusion" in
    success) printf '✅' ;;
    failure) printf '❌' ;;
    none)    printf '⚠️ none' ;;
    null)    printf '⚠️ pending' ;;
    *)       printf '⚠️ %s' "$conclusion" ;;
  esac
}

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
  branch=$(gh repo view "$repo" --json defaultBranchRef --jq '.defaultBranchRef.name' 2>/dev/null || echo "?")
  [ -z "$branch" ] && branch="?"

  lic=$(check_file "$repo" "LICENSE")
  cla=$(check_file "$repo" "CLAUDE.md")
  jf=$(check_file "$repo" "justfile")
  px=$(check_file "$repo" "pixi.toml")
  rd=$(check_file "$repo" "README.md")
  ci=$(check_ci "$repo" "$branch")
  last=$(gh api "repos/${repo}/commits/${branch}" --jq '.commit.committer.date' 2>/dev/null | cut -dT -f1)
  [ -z "$last" ] && last="?"

  # A repo is "fully healthy" when all five standard files are present and CI is green.
  if [ "$lic" = "✅" ] && [ "$cla" = "✅" ] && [ "$jf" = "✅" ] && \
     [ "$px" = "✅" ] && [ "$rd" = "✅" ] && [ "$ci" = "✅" ]; then
    healthy=$((healthy + 1))
  fi

  append "| ${repo} | ${branch} | ${lic} | ${cla} | ${jf} | ${px} | ${rd} | ${ci} | ${last} |"
done

append ""
append "**${healthy}/${total} repos fully healthy** (all standard files present + CI green)."

printf '%s' "$report"

if [ -n "$OUTPUT_PATH" ]; then
  printf '%s' "$report" > "$OUTPUT_PATH"
fi

if [ "$GH_SUMMARY" -eq 1 ] && [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  printf '%s' "$report" >> "$GITHUB_STEP_SUMMARY"
fi
