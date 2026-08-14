#!/usr/bin/env bash
#
# probe-code-quality.sh — Audit Code Quality / Code Scanning / Dependabot / Secret
# Scanning state across HomericIntelligence repos. Read-only.
#
# The "Code Quality" feature is a public preview that becomes a paid product on
# 2026-07-20. The actual disable path is per-repo UI (Settings → Code security
# and analysis → Code quality). This probe catalogs current state so an org
# owner can decide what to flip; see docs/runbooks/disable-code-quality.md.
#
# Usage:
#   tools/probe-code-quality.sh                  # 16 repos (.gitmodules + Odysseus)
#   tools/probe-code-quality.sh --all            # all 17 org repos
#   tools/probe-code-quality.sh --output PATH    # also write Markdown to PATH
#
# Requires: gh authenticated with read access to HomericIntelligence.

set -uo pipefail

OUTPUT_PATH=""
ALL_ORG=0

while [ $# -gt 0 ]; do
  case "${1:-}" in
    --output)  OUTPUT_PATH="${2:-}"
               [ -z "$OUTPUT_PATH" ] && { printf 'error: --output requires a path\n' >&2; exit 2; }
               shift 2 ;;
    --all)     ALL_ORG=1; shift ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *)         printf 'error: unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

command -v gh >/dev/null 2>&1 || { printf 'error: gh CLI not found\n' >&2; exit 2; }
command -v jq >/dev/null 2>&1 || { printf 'error: jq not found\n'     >&2; exit 2; }

ORG="HomericIntelligence"

# Build the repo list.
if [ "$ALL_ORG" -eq 1 ]; then
  mapfile -t REPOS < <(gh repo list "$ORG" --json name --jq '.[].name' | sort -u)
else
  REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" \
    || { printf 'error: not inside a git repository\n' >&2; exit 2; }
  mapfile -t REPOS < <(
    {
      git config --file "$REPO_ROOT/.gitmodules" --get-regexp 'submodule\..*\.url' \
        | sed -E 's#.*github.com/##; s#git@github.com:##; s#\.git$##' \
        | awk -F/ '{print $NF}'
      echo "Odysseus"
    } | sort -u
  )
fi

[ "${#REPOS[@]}" -gt 0 ] || { printf 'error: no repos resolved\n' >&2; exit 2; }

# Probe a boolean inside security_and_analysis.
sa_bool() {
  local repo="$1" key="$2" v
  v=$(gh api "repos/${ORG}/${repo}" --jq ".security_and_analysis.${key}.enabled // \"off\"" 2>/dev/null) \
    || { echo '?'; return; }
  case "$v" in
    true)             echo "on" ;;
    false|off|null|"") echo "off" ;;
    *)                 echo "$v" ;;
  esac
}

# Code scanning default-setup state. Often "not-configured" on the free tier.
cs_state() {
  local repo="$1" v
  v=$(gh api "repos/${ORG}/${repo}/code-scanning/default-setup" --jq '.state // "404"' 2>/dev/null) \
    || { echo "404"; return; }
  echo "$v"
}

# Code Quality endpoint probe.
cq_state() {
  local repo="$1" body
  body=$(gh api "repos/${ORG}/${repo}/code-quality" 2>/dev/null) \
    || { echo "404"; return; }
  [ -n "$body" ] || { echo "404"; return; }
  jq -r '
    if .enabled    == true  then "on"
    elif .enabled  == false then "off"
    else "404"
    end
  ' <<< "$body" 2>/dev/null || echo "?"
}

# Does a path exist in the repo? 200 → present, 404 → absent.
has_file() {
  local repo="$1" path="$2"
  if gh api "repos/${ORG}/${repo}/contents/${path}" >/dev/null 2>&1; then
    echo "present"
  else
    echo "absent"
  fi
}

# Build the Markdown report.
report=""
append() { report+="$1"$'\n'; }

append "# HomericIntelligence — Code Quality / Code Scanning audit"
append ""
append "> Generated $(date -u +%Y-%m-%dT%H:%M:%SZ) by \`tools/probe-code-quality.sh\`"
append "> Scope: **${#REPOS[@]}** repos (mode: $([ "$ALL_ORG" -eq 1 ] && echo "all 17 in the org" || echo ".gitmodules-derived 16 incl. Odysseus"))"
append ""

append "## Per-repo state"
append ""
append "| Repo | Dependabot sec | Secret scan | Push prot | Code Scanning | Code Quality | CQ config |"
append "|------|----|----|----|----|----|----|"

for repo in "${REPOS[@]}"; do
  d=$(sa_bool  "$repo" "dependabot_security_updates")
  s=$(sa_bool  "$repo" "secret_scanning")
  p=$(sa_bool  "$repo" "secret_scanning_push_protection")
  cs=$(cs_state  "$repo")
  cq=$(cq_state  "$repo")
  cqc=$(has_file "$repo" ".github/codeql/code-quality-config.yml")
  append "| ${repo} | ${d} | ${s} | ${p} | ${cs} | ${cq} | ${cqc} |"
done

append ""
append "## How to read this"
append ""
append "- **Code Quality** column probes \`/repos/{r}/code-quality\`."
append "  - \`on\`  → feature is enabled. UI-disable per \`docs/runbooks/disable-code-quality.md\`."
append "  - \`off\` → feature is explicitly disabled (target state)."
append "  - \`404\` → endpoint not exposed for this org tier (common on free public orgs; verify in repo UI)."
append "  - \`?\`   → API/network failure while probing; re-run the audit."
append "- **Dependabot sec / Secret scan / Push prot** may also show \`?\` on an API failure — same meaning."
append "- **CQ config** = presence of \`.github/codeql/code-quality-config.yml\`."
append "  - \`present\` = custom config file exists."
append "  - \`absent\`  = platform defaults run if the feature is otherwise toggled on."
append "- **Code Scanning** = state of \`/repos/{r}/code-scanning/default-setup\`."
append "  - \`not-configured\` = default CodeQL security workflow is not auto-running."
append "  - \`configured\`     = default CodeQL is active. Distinct from Code Quality."
append "- **Dependabot sec / Secret scan / Push prot**: free public-repo toggles; left untouched by this probe."
append ""
append "## Disable path"
append ""
append "See **\`docs/runbooks/disable-code-quality.md\`** for the per-repo UI procedure."

printf '%s' "$report"

if [ -n "$OUTPUT_PATH" ]; then
  printf '%s' "$report" > "$OUTPUT_PATH"
fi
